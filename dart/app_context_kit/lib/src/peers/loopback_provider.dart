/// Two (or more) processes on ONE machine finding and talking to each other.
///
/// * **Discovery:** each hub writes `<dir>/<account>/<app>/<device>@<instance>.json`
///   containing its loopback TCP port (plus its identity and pid), and watches
///   that same directory by polling. Because the directory is keyed by account
///   and app, a hub never even lists another app's or account's files. A file
///   left behind by a crash is a ghost. Every live provider rewrites its own
///   file every `announceEvery` with a `beat` time in it; a file whose last beat
///   is older than `staleAfter` is not offered (a peer already known is
///   withdrawn), and one older than `reapAfter` is deleted. Pids are deliberately
///   not checked: a pid means nothing in another pid namespace and can be reused.
/// * **Transport:** TCP on 127.0.0.1 only (never a routable address), one frame
///   = a 4-byte big-endian length then the bytes. The dialer's first frame is a
///   preface naming who it claims to be; the acceptor refuses a preface from
///   another scope before the hub ever sees the link.
///
/// No encryption and no authentication: anything on this machine can write the
/// directory or connect to the port. That is acceptable only for same-user,
/// same-machine coordination and for tests. The hub's authenticator is the
/// place where that gets fixed for anything else.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'clock.dart';
import 'envelope.dart';
import 'provider.dart';
import 'types.dart';

/// Splits a TCP byte stream into length-prefixed frames, refusing oversize
/// frames before allocating for them.
class FrameDecoder {
  FrameDecoder({this.maxFrame = Envelope.maxEncodedBytes});
  /// The largest frame accepted; a longer one is refused before anything is allocated for it.
  final int maxFrame;

  final Uint8List _hdr = Uint8List(4);
  int _hdrFill = 0;
  Uint8List? _body;
  int _bodyFill = 0;

  /// Feeds a chunk, returns the frames it completed. Throws [FormatException]
  /// for a zero-length or oversize frame (the caller must drop the connection).
  List<Uint8List> add(List<int> chunk) {
    final out = <Uint8List>[];
    var i = 0;
    while (i < chunk.length) {
      final body = _body;
      if (body == null) {
        while (i < chunk.length && _hdrFill < 4) {
          _hdr[_hdrFill++] = chunk[i++];
        }
        if (_hdrFill < 4) break;
        final len = ByteData.sublistView(_hdr).getUint32(0);
        _hdrFill = 0;
        if (len == 0 || len > maxFrame) throw FormatException('bad frame length $len (max $maxFrame)');
        _body = Uint8List(len);
        _bodyFill = 0;
      } else {
        final n = math.min(body.length - _bodyFill, chunk.length - i);
        body.setRange(_bodyFill, _bodyFill + n, chunk, i);
        _bodyFill += n;
        i += n;
        if (_bodyFill == body.length) {
          out.add(body);
          _body = null;
        }
      }
    }
    return out;
  }

  /// Prefixes [frame] with its length (four bytes, big-endian), ready to write to the socket.
  static Uint8List encode(Uint8List frame) {
    final out = Uint8List(4 + frame.length);
    ByteData.sublistView(out).setUint32(0, frame.length);
    out.setRange(4, out.length, frame);
    return out;
  }
}

/// Identifier parts become directory and file names, so they are held to
/// `[A-Za-z0-9._-]` (not `.` or `..`, no `@`). Anything else is an [ArgumentError]
/// rather than a path-traversal bug.
final RegExp _safePart = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$');

String _checkPart(String what, String s) {
  if (s.length > 128 || !_safePart.hasMatch(s)) {
    throw ArgumentError.value(s, what, 'the loopback provider only accepts [A-Za-z0-9._-], not starting with "."');
  }
  return s;
}

/// Finds copies of the same app on one machine and connects them over local TCP. Each copy writes an announcement file under [directory] and listens on a port; the others read the files.
class LoopbackProvider implements PeerProvider {
  LoopbackProvider({
    required this.directory,
    this.pollInterval = const Duration(milliseconds: 100),
    this.prefaceTimeout = const Duration(seconds: 5),
    this.connectTimeout = const Duration(seconds: 2),
    this.announceEvery = const Duration(seconds: 1),
    this.staleAfter = const Duration(seconds: 4),
    this.reapAfter = const Duration(minutes: 1),
    PeerClock? clock,
  }) : _clock = clock ?? const SystemPeerClock();

  /// The shared root (e.g. `<tmp>/app-context-peers`). Per-app files live under `<account>/<app>/`.
  final String directory;
  /// How often the directory is read for announcements.
  final Duration pollInterval;
  /// How long an incoming connection may take to say who it is.
  final Duration prefaceTimeout;
  /// How long a dial may take.
  final Duration connectTimeout;

  /// How often this provider rewrites its own announcement file (with a fresh `beat` time), so that others can tell it is alive.
  final Duration announceEvery;

  /// A file whose last beat is older than this belongs to a copy that crashed (or is frozen): it is not offered, and a peer
  /// already known from it is withdrawn. Keep it a few times [announceEvery]. The beat is a wall-clock time written in the
  /// file (a file without one, such as a hand-made ghost, is aged by its modification time, which on some systems is only
  /// accurate to a second), so this is measured against `DateTime.now()`, not the injected [PeerClock].
  final Duration staleAfter;

  /// A file whose last beat is older than this is deleted by whoever notices. A copy that is merely paused rewrites it at its next beat.
  final Duration reapAfter;
  final PeerClock _clock;

  PeerIdentity? _self;
  Directory? _dir;
  File? _ownFile;
  Map<String, Object?>? _ownAnnouncement;
  PeerTimer? _beat;
  ServerSocket? _server;
  PeerTimer? _poll;
  bool _closed = false;
  final Map<String, PeerCandidate> _known = {};
  final StreamController<PeerCandidate> _events = StreamController<PeerCandidate>.broadcast(sync: true);
  final StreamController<PeerLink> _incoming = StreamController<PeerLink>();
  final Set<Socket> _sockets = {};

  /// The port this provider listens on (after [open]).
  int? get port => _server?.port;

  /// The directory this provider announces in and watches.
  Directory? get scopeDirectory => _dir;

  @override
  Future<void> open(PeerIdentity self) async {
    if (_self != null) throw StateError('provider already opened');
    final account = _checkPart('account', self.account);
    final app = _checkPart('app', self.app);
    final device = _checkPart('device', self.device);
    final instance = _checkPart('instance', self.instance);
    _self = self;
    final sep = Platform.pathSeparator;
    final dir = Directory('$directory$sep$account$sep$app')..createSync(recursive: true);
    _dir = dir;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_accept, onError: (Object _) {});
    final file = File('${dir.path}$sep$device@$instance.json');
    _ownFile = file;
    _ownAnnouncement = {
      'account': account,
      'app': app,
      'device': device,
      'instance': instance,
      'port': server.port,
      'pid': pid,
    };
    _writeOwn();
    _scan();
    _schedulePoll();
    _scheduleBeat();
  }

  void _writeOwn() {
    final file = _ownFile;
    final announcement = _ownAnnouncement;
    if (file == null || announcement == null) return;
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({...announcement, 'beat': DateTime.now().millisecondsSinceEpoch}));
    tmp.renameSync(file.path); // atomic: readers never see half a file
  }

  /// The heartbeat: write the announcement again with a fresh beat time (which also restores it if someone reaped it while
  /// this copy was paused).
  void _scheduleBeat() {
    if (_closed) return;
    _beat = _clock.schedule(announceEvery, () {
      try {
        _writeOwn();
      } on FileSystemException {
        // The directory may be gone for a moment; the next beat tries again.
      }
      _scheduleBeat();
    });
  }

  void _schedulePoll() {
    if (_closed) return;
    _poll = _clock.schedule(pollInterval, () {
      _scan();
      _schedulePoll();
    });
  }

  static final RegExp _fileName = RegExp(r'^([^@]+)@([^@]+)\.json$');

  void _scan() {
    final dir = _dir;
    final me = _self;
    if (dir == null || me == null || _closed) return;
    final seen = <String, PeerCandidate>{};
    List<FileSystemEntity> items;
    try {
      items = dir.listSync(followLinks: false);
    } on FileSystemException {
      items = const [];
    }
    for (final f in items.whereType<File>()) {
      final name = f.uri.pathSegments.last;
      final m = _fileName.firstMatch(name);
      if (m == null) continue;
      final device = m.group(1)!;
      final instance = m.group(2)!;
      if (!_safePart.hasMatch(device) || !_safePart.hasMatch(instance)) continue;
      if (device == me.device && instance == me.instance) continue;
      try {
        if (f.lengthSync() > 4096) continue;
        final j = jsonDecode(f.readAsStringSync());
        if (j is! Map) continue;
        final beat = j['beat'];
        final lastAlive = beat is int ? DateTime.fromMillisecondsSinceEpoch(beat) : f.lastModifiedSync();
        final age = DateTime.now().difference(lastAlive);
        if (age > staleAfter) {
          // A ghost: its owner stopped beating. Not offered; deleted once it has been dead for long enough.
          if (age > reapAfter) {
            try {
              f.deleteSync();
            } on FileSystemException {
              // someone else reaped it first
            }
          }
          continue;
        }
        final port = j['port'];
        if (port is! int || port < 1 || port > 65535) continue;
        // A file that names another scope than its directory is ignored, never offered.
        if (j.containsKey('account') && j['account'] != me.account) continue;
        if (j.containsKey('app') && j['app'] != me.app) continue;
        seen[name] = PeerCandidate(PeerIdentity(me.account, me.app, PeerId(device, instance)), port.toString());
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    for (final name in _known.keys.toList()) {
      if (!seen.containsKey(name)) {
        final gone = _known.remove(name)!;
        if (!_events.isClosed) _events.add(gone.withdrawn());
      }
    }
    for (final e in seen.entries) {
      final old = _known[e.key];
      if (old == null || old.address != e.value.address) {
        _known[e.key] = e.value;
        if (!_events.isClosed) _events.add(e.value);
      }
    }
  }

  @override
  Stream<PeerCandidate> discover() => Stream<PeerCandidate>.multi((c) {
        for (final k in _known.values) {
          c.add(k);
        }
        final sub = _events.stream.listen(c.add);
        c.onCancel = sub.cancel;
      });

  @override
  Stream<PeerLink> get incoming => _incoming.stream;

  @override
  Future<PeerLink> connect(PeerCandidate c) async {
    final me = _self ?? (throw StateError('provider is not open'));
    if (_closed) throw PeerConnectError('provider is closed');
    if (!me.sameScope(c.identity)) {
      throw PeerScopeError('${c.identity} is not in scope ${me.account}/${me.app}');
    }
    final port = int.tryParse(c.address);
    if (port == null || port < 1 || port > 65535) throw PeerConnectError('bad loopback address "${c.address}"');
    final Socket socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: connectTimeout);
    } on SocketException catch (e) {
      throw PeerConnectError('cannot connect to ${c.id} on 127.0.0.1:$port: ${e.message}');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _sockets.add(socket);
    final link = _LoopbackLink(socket, c.identity, this);
    _listen(socket, link.feed, link.remoteGone);
    // The preface: who we claim to be. The acceptor checks the scope before emitting a link.
    await link.send(Uint8List.fromList(utf8.encode(jsonEncode({
      'account': me.account,
      'app': me.app,
      'device': me.device,
      'instance': me.instance,
    }))));
    return link;
  }

  void _listen(Socket s, void Function(Uint8List frame) onFrame, void Function() onEnd) {
    final decoder = FrameDecoder();
    s.listen(
      (chunk) {
        try {
          for (final f in decoder.add(chunk)) {
            onFrame(f);
          }
        } on FormatException {
          s.destroy();
          onEnd();
        }
      },
      onError: (Object _) {
        s.destroy();
        onEnd();
      },
      onDone: () {
        s.destroy();
        onEnd();
      },
      cancelOnError: true,
    );
  }

  void _accept(Socket s) {
    final me = _self;
    if (me == null || _closed) {
      s.destroy();
      return;
    }
    s.setOption(SocketOption.tcpNoDelay, true);
    _sockets.add(s);
    _LoopbackLink? link;
    final timer = _clock.schedule(prefaceTimeout, () {
      if (link == null) s.destroy();
    });
    _listen(s, (frame) {
      final l = link;
      if (l != null) {
        l.feed(frame);
        return;
      }
      timer.cancel();
      PeerIdentity? claim;
      try {
        final j = jsonDecode(utf8.decode(frame));
        if (j is Map && j['account'] is String && j['app'] is String && j['device'] is String && j['instance'] is String) {
          claim = PeerIdentity(j['account'] as String, j['app'] as String, PeerId(j['device'] as String, j['instance'] as String));
        }
      } on FormatException {
        claim = null;
      }
      if (claim == null || !claim.sameScope(me) || claim.id == me.id) {
        s.destroy(); // wrong scope or garbage: the hub never hears about it
        return;
      }
      link = _LoopbackLink(s, claim, this);
      if (!_incoming.isClosed) {
        _incoming.add(link!);
      } else {
        s.destroy();
      }
    }, () {
      timer.cancel();
      link?.remoteGone();
      _sockets.remove(s);
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    _beat?.cancel();
    final file = _ownFile;
    if (file != null) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // already gone
      }
    }
    await _server?.close();
    for (final s in _sockets.toList()) {
      s.destroy();
    }
    _sockets.clear();
    await _events.close();
    unawaited(_incoming.close());
  }
}

class _LoopbackLink implements PeerLink {
  _LoopbackLink(this._socket, this.remote, this._owner);

  final Socket _socket;
  final LoopbackProvider _owner;
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  Future<void> _chain = Future<void>.value();
  bool _closed = false;

  @override
  final PeerIdentity remote;

  @override
  Stream<Uint8List> get inbound => _in.stream;

  void feed(Uint8List frame) {
    if (!_in.isClosed) _in.add(frame);
  }

  void remoteGone() {
    _closed = true;
    _owner._sockets.remove(_socket);
    if (!_in.isClosed) unawaited(_in.close());
  }

  @override
  Future<void> send(Uint8List bytes) {
    if (_closed) return Future<void>.error(PeerLinkClosed('link to ${remote.id} is closed'));
    if (bytes.isEmpty || bytes.length > Envelope.maxEncodedBytes) {
      return Future<void>.error(ArgumentError.value(bytes.length, 'bytes', 'frame size out of range'));
    }
    final framed = FrameDecoder.encode(bytes);
    final f = _chain.then((_) async {
      if (_closed) throw PeerLinkClosed('link to ${remote.id} is closed');
      _socket.add(framed);
      await _socket.flush();
    });
    _chain = f.then((_) {}, onError: (Object _) {});
    return f;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    final pending = _chain;
    _closed = true;
    try {
      await pending.timeout(const Duration(seconds: 1));
      await _socket.flush();
    } catch (_) {
      // best effort
    }
    _socket.destroy();
    _owner._sockets.remove(_socket);
    if (!_in.isClosed) unawaited(_in.close());
  }
}
