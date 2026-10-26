/// The management interface: finds, authenticates, connects and routes between
/// copies of one app, and tells the app's hook what happened. It never reads a
/// payload.
///
/// ## Protocol on one link (every frame is an [Envelope], sequenced per direction from 1)
///
/// ```text
/// dialer / acceptor                      both sides send immediately on attach
///   kit.hello  {nonce, hello}            -> peer learns who we are and what the app says
///   kit.auth   {proof over their nonce}  -> sent after their hello arrives
///   (verify proof, then hook.admit)
///   kit.ready  | kit.reject {reason}     -> "I admitted you" | "I refuse you"
/// ready  = we admitted them AND their kit.ready arrived  -> onPeer(ready)
/// ...app frames, kit.reply...
///   kit.bye                              -> graceful close (peer is not redialed)
/// ```
///
/// ## Decisions
///
///  * Only the lower [PeerId] dials. The higher side waits for the incoming
///    link, so two copies never open two links to each other. Discovery must be
///    symmetric for this (it is for both shipped providers).
///  * Sequence numbers are per link and restart at 1 on every link. Out of
///    order frames wait in a small reorder buffer; a gap that does not fill
///    within `reorderTimeout` (or overflows the buffer) is skipped, so the app
///    sees loss as a jump in `AppMessage.seq`. Anything at or below the last
///    delivered `seq` is a duplicate and is dropped.
///  * Outbox: bounded per peer by message count and bytes. When full, `send`
///    FAILS with [PeerOutboxFull] instead of dropping an older message: only
///    the app knows what is safe to drop. Queued messages are dropped (their
///    futures fail with [PeerLost]) when the peer is lost.
///  * A rejected peer (by us, or by them) is not redialed until the provider
///    withdraws and re-announces it.
///  * Hooks must not throw. If they do, the hub counts it ([PeerHubStats]),
///    reports it to `onHookError`, and carries on.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'auth.dart';
import 'clock.dart';
import 'coordination.dart';
import 'envelope.dart';
import 'provider.dart';
import 'types.dart';

/// Knobs with safe defaults. Everything time-related runs on the injected [PeerClock].
class PeerHubOptions {
  const PeerHubOptions({
    this.outboxMessages = 256,
    this.outboxBytes = 8 * 1024 * 1024,
    this.handshakeTimeout = const Duration(seconds: 5),
    this.reorderTimeout = const Duration(milliseconds: 500),
    this.reorderBuffer = 16,
    this.inboxFrames = 256,
    this.requestTimeout = const Duration(seconds: 5),
    this.closeGrace = const Duration(seconds: 1),
    this.backoff = const ExponentialBackoff(),
    this.onHookError,
  });

  /// Max queued (not yet written) messages per peer.
  final int outboxMessages;

  /// Max queued payload bytes per peer.
  final int outboxBytes;

  /// A link that is not ready after this long is dropped.
  final Duration handshakeTimeout;

  /// How long a sequence gap may stay open before it is skipped.
  final Duration reorderTimeout;

  /// Max out-of-order frames held per link (worst case this many MiB).
  final int reorderBuffer;

  /// Max undelivered inbound frames per link; a peer that floods past this is dropped.
  final int inboxFrames;
  /// How long [PeerHub.request] waits for a reply when no timeout is given.
  final Duration requestTimeout;

  /// How long `close()` waits for goodbyes to flush before closing links anyway.
  final Duration closeGrace;
  /// How long to wait before redialing a peer that could not be reached.
  final Backoff backoff;
  /// Called when the app's hook or the authenticator throws. The hub keeps running; the error is counted in [PeerHubStats.hookErrors].
  final void Function(String where, Object error, StackTrace stack)? onHookError;
}

/// Counters, for tests and for diagnostics screens.
class PeerHubStats {
  /// Frames at or below the last delivered `seq`: true duplicates, and late
  /// frames that arrived after their gap was skipped.
  int duplicatesDropped = 0;
  /// Sequence numbers skipped because a gap stayed open longer than `reorderTimeout`.
  int gapsSkipped = 0;
  /// Frames that did not decode as an envelope, or did not match their link. The link is dropped.
  int malformedFrames = 0;
  /// Links or frames from another account or app. They are cut off and never answered.
  int scopeViolations = 0;
  /// Handshake or flow-control breaches, such as an inbound flood past `inboxFrames`. The link is dropped.
  int protocolViolations = 0;
  /// App messages that arrived on a link before it was ready.
  int droppedBeforeReady = 0;
  /// Exceptions thrown by the app's hook or the authenticator.
  int hookErrors = 0;
  /// Links that were opened, in either direction.
  int linksOpened = 0;
  /// Dials that failed.
  int dialFailures = 0;

  @override
  String toString() => 'PeerHubStats(dup=$duplicatesDropped gaps=$gapsSkipped malformed=$malformedFrames '
      'scope=$scopeViolations protocol=$protocolViolations beforeReady=$droppedBeforeReady hookErrors=$hookErrors dialFailures=$dialFailures)';
}

/// Result of [PeerHub.broadcast]: who it was queued for and who it could not be.
class BroadcastResult {
  BroadcastResult(this.sent, this.failed);
  /// Peers the message was queued for and handed to the link.
  final List<PeerId> sent;
  /// Peers it could not be sent to, with the error for each.
  final Map<PeerId, Object> failed;
}

class _PeerImpl implements Peer {
  _PeerImpl(this.id, this.account, this.app);
  @override
  final PeerId id;
  @override
  final String account;
  @override
  final String app;
  @override
  Object? hello;
  @override
  PeerState state = PeerState.found;
  @override
  bool readOnly = false;
  @override
  String? rejectReason;
  @override
  String? lostReason;

  @override
  String toString() => 'Peer($id ${state.name})';
}

class _Out {
  _Out(this.kind, this.schema, this.rid, this.payload);
  final String kind;
  final int schema;
  final int? rid;
  final Uint8List payload;
  final Completer<void> done = Completer<void>();
  bool cancelled = false;
}

class _Pending {
  _Pending(this.peer, this.completer, this.timer, this.out);
  final PeerId peer;
  final Completer<AppMessage> completer;
  final PeerTimer timer;
  final _Out out;
}

class _Entry {
  _Entry(this.id, this.peer);
  final PeerId id;
  _PeerImpl peer;
  PeerCandidate? candidate;
  _Conn? conn;
  bool dialing = false;
  int attempt = 0;
  PeerTimer? redial;
  final Queue<_Out> outbox = Queue<_Out>();
  int outboxBytes = 0;
}

class _Gap {
  const _Gap();
}

class _Conn {
  _Conn(this.link, this.dialer, this.entry, this.myNonce);
  final PeerLink link;
  final bool dialer;
  _Entry? entry;
  final String myNonce;
  StreamSubscription<Uint8List>? sub;
  PeerTimer? handshakeTimer;
  PeerTimer? reorderTimer;

  bool dead = false;
  bool gotHello = false;
  bool gotAuth = false;
  bool admitted = false;
  bool remoteReady = false;
  bool ready = false;
  bool goodbye = false;
  bool pumping = false;
  bool draining = false;
  Object? theirHello;

  int outSeq = 0;
  int expected = 1;
  final Map<int, Envelope> reorder = {};
  final Queue<Object> inbox = Queue<Object>();
  Future<void> sendChain = Future<void>.value();
  Future<void> closing = Future<void>.value();

  PeerId get remoteId => link.remote.id;
}

/// One copy's connection to the other copies of its app, on one channel. Find peers, connect, [send], [broadcast], [request] and [reply]; the app's [AppCoordination] hook decides what the messages mean. Build one with `ctx.peerHub` or `ctx.startPeers`.
class PeerHub {
  PeerHub({
    required this.account,
    required this.app,
    required this.device,
    required this.instance,
    required PeerProvider provider,
    required AppCoordination hook,
    PeerAuthenticator? authenticator,
    PeerClock? clock,
    this.options = const PeerHubOptions(),
    math.Random? random,
  })  : _provider = provider,
        _hook = hook,
        channel = hook.channel,
        _auth = authenticator ?? const OpenAuthenticator(),
        _clock = clock ?? const SystemPeerClock(),
        _random = random ?? math.Random.secure();

  /// The account this copy belongs to. Peers of any other account are never connected.
  final String account;
  /// The app id. Peers of any other app are never connected.
  final String app;
  /// This copy's device name.
  final String device;
  /// This copy's instance id.
  final String instance;
  /// The hook's channel. Peers on another channel are rejected at the handshake.
  final String channel;
  /// Limits and timeouts.
  final PeerHubOptions options;
  /// Counters for diagnostics and tests.
  final PeerHubStats stats = PeerHubStats();

  final PeerProvider _provider;
  final AppCoordination _hook;
  final PeerAuthenticator _auth;
  final PeerClock _clock;
  final math.Random _random;

  final Map<PeerId, _Entry> _entries = {};
  final Set<_Conn> _conns = {};
  final Map<String, _Pending> _pending = {};
  final StreamController<PeerEvent> _changes = StreamController<PeerEvent>.broadcast();
  StreamSubscription<PeerCandidate>? _discoverSub;
  StreamSubscription<PeerLink>? _incomingSub;
  int _nextRid = 0;
  bool _started = false;
  bool _closed = false;
  Future<void>? _closing;

  /// This copy's [PeerId].
  PeerId get id => PeerId(device, instance);
  /// This copy's full identity: account, app, device and instance.
  PeerIdentity get identity => PeerIdentity(account, app, id);
  /// True once [close] has been called.
  bool get isClosed => _closed;

  /// Live view: every peer that is found, connecting or ready (not lost or
  /// rejected). A snapshot list; the [Peer] objects update in place until they
  /// reach `lost` or `rejected`.
  List<Peer> get peers => List.unmodifiable(_entries.values
      .map((e) => e.peer)
      .where((p) => p.state == PeerState.found || p.state == PeerState.connecting || p.state == PeerState.ready));

  /// Only the ready ones.
  List<Peer> get readyPeers => List.unmodifiable(peers.where((p) => p.state == PeerState.ready));

  /// Every found / ready / lost, in order, after the hook has seen it.
  Stream<PeerEvent> get changes => _changes.stream;

  // ---------------------------------------------------------------- lifecycle

  /// Opens the provider and starts finding and accepting peers.
  Future<void> start() async {
    if (_closed) throw PeerClosed('hub is closed');
    if (_started) return;
    _started = true;
    _guard('attach', () => _hook.attach(this));
    await _provider.open(identity);
    _incomingSub = _provider.incoming.listen(_onIncoming, onError: (Object e, StackTrace s) => _hookError('provider.incoming', e, s));
    _discoverSub = _provider.discover().listen(_onCandidate, onError: (Object e, StackTrace s) => _hookError('provider.discover', e, s));
  }

  /// Tells ready peers goodbye, closes every link and the provider. Idempotent:
  /// later calls return the same future.
  Future<void> close() => _closing ??= _doClose();

  Future<void> _doClose() async {
    _closed = true;
    await _discoverSub?.cancel();
    await _incomingSub?.cancel();
    final byes = <Future<void>>[];
    for (final c in _conns.toList()) {
      if (c.ready && !c.dead) {
        byes.add(_write(c, PeerKinds.bye, Uint8List(0)).catchError((Object _) {}));
      }
    }
    if (byes.isNotEmpty) await _withGrace(Future.wait(byes));
    final closes = <Future<void>>[];
    for (final c in _conns.toList()) {
      _closeConn(c, flush: true);
      closes.add(c.closing);
    }
    for (final e in _entries.values.toList()) {
      e.redial?.cancel();
      e.redial = null;
      _failPending(e, PeerClosed('hub closed'));
      final st = e.peer.state;
      if (st == PeerState.found || st == PeerState.connecting || st == PeerState.ready) {
        e.peer
          ..state = PeerState.lost
          ..lostReason = 'hub closed';
        _fire(e.peer, PeerChange.lost);
      }
    }
    _entries.clear();
    await _withGrace(Future.wait(closes));
    await _provider.close();
    await _changes.close();
  }

  Future<void> _withGrace(Future<void> f) {
    final done = Completer<void>();
    final t = _clock.schedule(options.closeGrace, () {
      if (!done.isCompleted) done.complete();
    });
    f.then((_) {}, onError: (Object _) {}).whenComplete(() {
      t.cancel();
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  // ---------------------------------------------------------------- discovery and dialing

  void _onCandidate(PeerCandidate c) {
    if (_closed) return;
    if (c.identity.account != account || c.identity.app != app) {
      stats.scopeViolations++;
      return;
    }
    if (c.id == id) return;
    if (!c.available) {
      _withdrawn(c.id);
      return;
    }
    var e = _entries[c.id];
    if (e == null) {
      e = _newEntry(c.id);
      e.candidate = c;
      _fire(e.peer, PeerChange.found);
    } else {
      if (e.candidate?.address != c.address) e.attempt = 0;
      e.candidate = c;
    }
    _maybeDial(e);
  }

  _Entry _newEntry(PeerId pid) {
    final e = _Entry(pid, _PeerImpl(pid, account, app));
    _entries[pid] = e;
    return e;
  }

  void _withdrawn(PeerId pid) {
    final e = _entries[pid];
    if (e == null) return;
    e.candidate = null;
    e.redial?.cancel();
    e.redial = null;
    if (e.conn == null && !e.dialing) _removeEntry(e);
    // A live link keeps going; when it ends, the entry goes with it (no candidate).
  }

  /// Takes the entry out of the view; fires `lost` if the peer was never lost/rejected.
  void _removeEntry(_Entry e) {
    e.redial?.cancel();
    e.redial = null;
    if (_entries[e.id] == e) _entries.remove(e.id);
    final st = e.peer.state;
    if (st == PeerState.found || st == PeerState.connecting || st == PeerState.ready) {
      _failPending(e, PeerLost('peer went away'));
      e.peer
        ..state = PeerState.lost
        ..lostReason ??= 'withdrawn';
      _fire(e.peer, PeerChange.lost);
    }
  }

  void _maybeDial(_Entry e) {
    if (!_started || _closed) return;
    final cand = e.candidate;
    if (cand == null || !cand.available) return;
    if (e.peer.state == PeerState.rejected || e.conn != null || e.dialing || e.redial != null) return;
    if (id.compareTo(e.id) >= 0) return; // only the lower id dials
    _dial(e, cand);
  }

  Future<void> _dial(_Entry e, PeerCandidate cand) async {
    e.dialing = true;
    if (e.peer.state == PeerState.found) e.peer.state = PeerState.connecting;
    final PeerLink link;
    try {
      link = await _provider.connect(cand);
    } catch (_) {
      e.dialing = false;
      stats.dialFailures++;
      if (_closed) return;
      if (e.peer.state == PeerState.connecting) e.peer.state = PeerState.found;
      if (e.candidate == null) {
        _removeEntry(e);
      } else {
        _scheduleRedial(e);
      }
      return;
    }
    e.dialing = false;
    if (_closed || _entries[e.id] != e) {
      unawaited(link.close().catchError((Object _) {}));
      return;
    }
    _attach(link, dialer: true, entry: e);
  }

  void _scheduleRedial(_Entry e) {
    if (_closed || e.redial != null || e.candidate == null) return;
    if (id.compareTo(e.id) >= 0) return; // only the lower id dials; the other waits
    final d = options.backoff.delay(e.attempt);
    e.attempt++;
    if (d == null) return; // gave up; waits for the provider to re-announce
    e.redial = _clock.schedule(d, () {
      e.redial = null;
      _maybeDial(e);
    });
  }

  // ---------------------------------------------------------------- links

  void _onIncoming(PeerLink link) {
    if (_closed) {
      unawaited(link.close().catchError((Object _) {}));
      return;
    }
    final r = link.remote;
    if (r.account != account || r.app != app) {
      stats.scopeViolations++;
      unawaited(link.close().catchError((Object _) {}));
      return;
    }
    if (r.id == id) {
      unawaited(link.close().catchError((Object _) {}));
      return;
    }
    final e = _entries[r.id];
    if (e != null && e.peer.state == PeerState.rejected) {
      unawaited(link.close().catchError((Object _) {}));
      return;
    }
    _attach(link, dialer: false, entry: null);
  }

  String _nonce() {
    final b = StringBuffer();
    for (var i = 0; i < 16; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  void _attach(PeerLink link, {required bool dialer, required _Entry? entry}) {
    stats.linksOpened++;
    final c = _Conn(link, dialer, entry, _nonce());
    _conns.add(c);
    if (entry != null) {
      entry.conn = c;
      if (entry.peer.state == PeerState.found) entry.peer.state = PeerState.connecting;
    }
    c.sub = link.inbound.listen(
      (b) => _enqueueFrame(c, b),
      onError: (Object _) => _linkDown(c, 'link error'),
      onDone: () => _linkDown(c, 'link closed'),
      cancelOnError: true,
    );
    c.handshakeTimer = _clock.schedule(options.handshakeTimeout, () {
      if (!c.ready) _linkDown(c, 'handshake timeout');
    });
    Object? hello;
    try {
      hello = _hook.hello();
    } catch (err, st) {
      _hookError('hello', err, st);
    }
    try {
      _writeControl(c, PeerKinds.hello, _json({'nonce': c.myNonce, 'hello': hello}));
    } catch (err, st) {
      _hookError('hello (not encodable)', err, st);
      _writeControl(c, PeerKinds.hello, _json({'nonce': c.myNonce, 'hello': null}));
    }
  }

  Uint8List _json(Object? v) => Uint8List.fromList(utf8.encode(jsonEncode(v)));

  /// Sequence, encode and queue one frame on [c]'s ordered send chain.
  Future<void> _write(_Conn c, String kind, Uint8List payload, {int schema = 0, int? rid}) {
    if (c.dead) return Future<void>.error(PeerLinkClosed('link is closed'));
    final Uint8List bytes;
    try {
      bytes = Envelope(
        header: EnvelopeHeader(
          account: account,
          app: app,
          channel: channel,
          from: id,
          seq: c.outSeq + 1,
          kind: kind,
          requestId: rid,
        ),
        schema: schema,
        payload: payload,
      ).encode();
    } on EnvelopeError catch (e) {
      return Future<void>.error(e);
    }
    c.outSeq++;
    final f = c.sendChain.then((_) => c.link.send(bytes));
    c.sendChain = f.then((_) {}, onError: (Object _) {});
    return f;
  }

  /// A control frame nobody awaits: a failed send drops the link.
  void _writeControl(_Conn c, String kind, Uint8List payload) {
    _write(c, kind, payload).catchError((Object _) => _linkDown(c, 'send failed'));
  }

  void _closeConn(_Conn c, {bool flush = false}) {
    if (c.dead) return;
    c.dead = true;
    c.handshakeTimer?.cancel();
    c.reorderTimer?.cancel();
    unawaited(c.sub?.cancel());
    c.inbox.clear();
    c.reorder.clear();
    _conns.remove(c);
    final before = flush ? c.sendChain : Future<void>.value();
    c.closing = before.then((_) => c.link.close()).then((_) {}, onError: (Object _) {});
  }

  /// The link ended (or was cut): fire `lost` if it was ready, then either
  /// remove the peer or schedule a redial.
  void _linkDown(_Conn c, String reason) {
    if (c.dead) return;
    _closeConn(c);
    final e = c.entry;
    if (e == null || e.conn != c) return;
    e.conn = null;
    if (e.peer.state == PeerState.rejected) return;
    _failPending(e, PeerLost(reason));
    final gone = c.goodbye || e.candidate == null;
    if (c.ready || gone) {
      // A ready peer, or one that left for good: `lost` (unless it already is).
      final p = e.peer;
      if (p.state != PeerState.lost) {
        p
          ..state = PeerState.lost
          ..lostReason = reason;
        _fire(p, PeerChange.lost);
      }
      if (gone) {
        e.redial?.cancel();
        e.redial = null;
        if (_entries[e.id] == e) _entries.remove(e.id);
        return;
      }
      if (_closed) return;
      // Still advertised: the same copy may come back. A new Peer, found again.
      e.peer = _PeerImpl(e.id, account, app);
      _fire(e.peer, PeerChange.found);
    } else {
      // Not ready yet and still advertised: back to found, retry later.
      e.peer.state = PeerState.found;
    }
    _scheduleRedial(e);
  }

  /// Connect the incoming link to its entry, creating the peer if discovery
  /// has not seen it. Returns null (after closing) if the peer is blocked.
  _Entry? _bind(_Conn c) {
    if (c.entry != null) return c.entry;
    final rid = c.remoteId;
    var e = _entries[rid];
    if (e != null && e.peer.state == PeerState.rejected) {
      _closeConn(c);
      return null;
    }
    if (e != null && e.conn != null && e.conn != c) {
      _linkDown(e.conn!, 'replaced by a newer link');
      e = _entries[rid];
    }
    if (e == null) {
      e = _newEntry(rid);
      _fire(e.peer, PeerChange.found);
    }
    e.redial?.cancel();
    e.redial = null;
    e.conn = c;
    c.entry = e;
    if (e.peer.state == PeerState.found) e.peer.state = PeerState.connecting;
    return e;
  }

  // ---------------------------------------------------------------- inbound frames

  void _enqueueFrame(_Conn c, Object item) {
    if (c.dead) return;
    if (c.inbox.length >= options.inboxFrames) {
      stats.protocolViolations++;
      _linkDown(c, 'inbound flood');
      return;
    }
    c.inbox.add(item);
    if (!c.draining) unawaited(_drain(c));
  }

  Future<void> _drain(_Conn c) async {
    c.draining = true;
    try {
      while (!c.dead && c.inbox.isNotEmpty) {
        final item = c.inbox.removeFirst();
        try {
          if (item is _Gap) {
            _skipGap(c);
            await _drainOrdered(c);
          } else {
            await _handleBytes(c, item as Uint8List);
          }
        } catch (err, st) {
          _hookError('frame handler', err, st);
          _linkDown(c, 'internal error');
        }
      }
    } finally {
      c.draining = false;
    }
  }

  void _violation(_Conn c, String why) {
    stats.protocolViolations++;
    _linkDown(c, 'protocol violation: $why');
  }

  Future<void> _handleBytes(_Conn c, Uint8List bytes) async {
    final Envelope env;
    try {
      env = Envelope.decode(bytes);
    } on EnvelopeError {
      stats.malformedFrames++;
      _linkDown(c, 'malformed frame');
      return;
    }
    final h = env.header;
    if (h.account != account || h.app != app) {
      // Never answer a frame from another scope; just cut it off.
      stats.scopeViolations++;
      _linkDown(c, 'scope violation');
      return;
    }
    if (h.from != c.remoteId || h.seq < 1) {
      stats.malformedFrames++;
      _linkDown(c, 'frame does not match the link');
      return;
    }
    final s = h.seq;
    if (s < c.expected || c.reorder.containsKey(s)) {
      stats.duplicatesDropped++;
      return;
    }
    c.reorder[s] = env;
    if (c.reorder.length > options.reorderBuffer) _skipGap(c);
    await _drainOrdered(c);
  }

  void _skipGap(_Conn c) {
    if (c.reorder.isEmpty) return;
    final lowest = c.reorder.keys.reduce(math.min);
    if (lowest > c.expected) {
      stats.gapsSkipped += lowest - c.expected;
      c.expected = lowest;
    }
  }

  Future<void> _drainOrdered(_Conn c) async {
    var progressed = false;
    while (!c.dead) {
      final next = c.reorder.remove(c.expected);
      if (next == null) break;
      c.expected++;
      progressed = true;
      await _dispatch(c, next);
    }
    if (c.dead) return;
    if (c.reorder.isEmpty) {
      c.reorderTimer?.cancel();
      c.reorderTimer = null;
    } else if (progressed || c.reorderTimer == null) {
      c.reorderTimer?.cancel();
      c.reorderTimer = _clock.schedule(options.reorderTimeout, () {
        c.reorderTimer = null;
        _enqueueFrame(c, const _Gap());
      });
    }
  }

  Future<void> _dispatch(_Conn c, Envelope env) async {
    final kind = env.header.kind;
    if (!c.gotHello && kind != PeerKinds.hello) {
      _violation(c, '$kind before hello');
      return;
    }
    switch (kind) {
      case PeerKinds.hello:
        await _onHello(c, env);
      case PeerKinds.auth:
        await _onAuth(c, env);
      case PeerKinds.ready:
        if (!c.gotAuth || c.remoteReady) return _violation(c, 'unexpected ready');
        c.remoteReady = true;
        _checkReady(c);
      case PeerKinds.reject:
        _onRejectedByPeer(c, env);
      case PeerKinds.bye:
        c.goodbye = true;
        c.entry?.candidate = null; // treated as withdrawn until the provider announces it again
        _linkDown(c, 'goodbye');
      case PeerKinds.reply:
        _onReply(c, env);
      default:
        if (kind.startsWith(PeerKinds.reservedPrefix)) return; // unknown reserved kind: ignore
        _onApp(c, env);
    }
  }

  Future<void> _onHello(_Conn c, Envelope env) async {
    if (c.gotHello) return _violation(c, 'second hello');
    if (env.header.channel != channel) {
      c.gotHello = true;
      if (_bind(c) != null) _rejectLocal(c, 'channel mismatch: this side is on "$channel"');
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(env.payload));
    } catch (_) {
      return _violation(c, 'hello is not JSON');
    }
    if (decoded is! Map || decoded['nonce'] is! String || (decoded['nonce'] as String).isEmpty || (decoded['nonce'] as String).length > 128) {
      return _violation(c, 'hello has no nonce');
    }
    final theirNonce = decoded['nonce'] as String;
    c.gotHello = true;
    c.theirHello = decoded['hello'];
    final e = _bind(c);
    if (e == null) return;
    e.peer.hello = c.theirHello;
    final Proof proof;
    try {
      proof = await _auth.prove(identity, theirNonce);
    } catch (err, st) {
      _hookError('authenticator.prove', err, st);
      _linkDown(c, 'could not prove identity');
      return;
    }
    if (c.dead) return;
    _writeControl(c, PeerKinds.auth, _json(proof.toJson()));
  }

  Future<void> _onAuth(_Conn c, Envelope env) async {
    if (c.gotAuth) return _violation(c, 'second auth');
    final Proof proof;
    try {
      proof = Proof.fromJson(jsonDecode(utf8.decode(env.payload)));
    } catch (_) {
      return _violation(c, 'auth is not a proof');
    }
    c.gotAuth = true;
    final e = c.entry;
    if (e == null) return; // channel-mismatch path already rejected
    var ok = false;
    try {
      ok = await _auth.verify(c.link.remote, c.myNonce, proof);
    } catch (err, st) {
      _hookError('authenticator.verify', err, st);
    }
    if (c.dead) return;
    if (!ok) return _rejectLocal(c, 'authentication failed');
    Admit decision;
    try {
      decision = await _hook.admit(e.peer, c.theirHello);
    } catch (err, st) {
      _hookError('admit', err, st);
      decision = Admit.reject('admit failed');
    }
    if (c.dead) return;
    if (!decision.accepted) return _rejectLocal(c, decision.reason ?? 'rejected');
    e.peer.readOnly = decision.kind == AdmitKind.acceptReadOnly;
    c.admitted = true;
    _writeControl(c, PeerKinds.ready, Uint8List(0));
    _checkReady(c);
  }

  String _clip(String s) => s.length <= 256 ? s : s.substring(0, 256);

  /// We refuse this peer: tell it why, close, and do not redial it.
  void _rejectLocal(_Conn c, String reason) {
    final e = c.entry;
    if (e == null || c.dead) return;
    final r = _clip(reason);
    _writeControl(c, PeerKinds.reject, _json({'reason': r}));
    _finishRejected(c, e, r);
    _closeConn(c, flush: true);
  }

  void _onRejectedByPeer(_Conn c, Envelope env) {
    final e = c.entry;
    if (e == null) return _violation(c, 'reject before hello');
    var reason = 'no reason given';
    try {
      final m = jsonDecode(utf8.decode(env.payload));
      if (m is Map && m['reason'] is String) reason = _clip(m['reason'] as String);
    } catch (_) {}
    _finishRejected(c, e, 'rejected by peer: $reason');
    _closeConn(c);
  }

  void _finishRejected(_Conn c, _Entry e, String reason) {
    e.conn = null;
    e.redial?.cancel();
    e.redial = null;
    _failPending(e, PeerLost('rejected: $reason'));
    e.peer
      ..state = PeerState.rejected
      ..rejectReason = reason;
    // Blocked until the provider withdraws it; an undiscovered peer has nothing to withdraw it.
    if (e.candidate == null && _entries[e.id] == e) _entries.remove(e.id);
    _fire(e.peer, PeerChange.lost);
  }

  void _checkReady(_Conn c) {
    if (c.ready || c.dead || !c.admitted || !c.remoteReady) return;
    final e = c.entry;
    if (e == null) return;
    c.ready = true;
    c.handshakeTimer?.cancel();
    e.attempt = 0;
    e.peer.state = PeerState.ready;
    _fire(e.peer, PeerChange.ready);
    unawaited(_pump(e));
  }

  void _onApp(_Conn c, Envelope env) {
    final e = c.entry;
    if (!c.ready || e == null) {
      stats.droppedBeforeReady++;
      return;
    }
    if (env.header.channel != channel) return;
    final msg = AppMessage(
      from: env.header.from,
      channel: env.header.channel,
      seq: env.header.seq,
      kind: env.header.kind,
      schema: env.schema,
      payload: env.payload,
      requestId: env.header.requestId,
    );
    _guard('onMessage', () => _hook.onMessage(e.peer, msg));
  }

  void _onReply(_Conn c, Envelope env) {
    final e = c.entry;
    final rid = env.header.requestId;
    if (!c.ready || e == null || rid == null) return;
    final p = _pending.remove(_key(e.id, rid));
    if (p == null) return; // late or unknown: ignored
    p.timer.cancel();
    p.completer.complete(AppMessage(
      from: env.header.from,
      channel: env.header.channel,
      seq: env.header.seq,
      kind: env.header.kind,
      schema: env.schema,
      payload: env.payload,
      requestId: rid,
    ));
  }

  // ---------------------------------------------------------------- outbound API

  void _checkKind(String kind, int schema, Uint8List payload) {
    if (kind.isEmpty || kind.length > Envelope.maxFieldChars) {
      throw ArgumentError.value(kind, 'kind', 'must be 1..${Envelope.maxFieldChars} characters');
    }
    if (kind.startsWith(PeerKinds.reservedPrefix)) {
      throw ArgumentError.value(kind, 'kind', 'the "${PeerKinds.reservedPrefix}" prefix is reserved for the Kit');
    }
    if (schema < 0 || schema > 2147483647) throw ArgumentError.value(schema, 'schema', 'out of range');
    if (payload.length > Envelope.maxPayloadBytes) {
      throw EnvelopeError('payload is ${payload.length} bytes; the cap is ${Envelope.maxPayloadBytes}');
    }
  }

  _Entry _entryFor(Peer peer) {
    if (_closed) throw PeerClosed('hub is closed');
    final e = _entries[peer.id];
    if (e == null || !identical(e.peer, peer)) {
      throw PeerNotAvailable('${peer.id} is not a current peer (it was lost, rejected or replaced)');
    }
    final st = e.peer.state;
    if (st != PeerState.found && st != PeerState.connecting && st != PeerState.ready) {
      throw PeerNotAvailable('${peer.id} is ${st.name}');
    }
    return e;
  }

  _Out _queue(_Entry e, String kind, int schema, int? rid, Uint8List payload) {
    if (e.outbox.length >= options.outboxMessages || e.outboxBytes + payload.length > options.outboxBytes) {
      throw PeerOutboxFull('outbox for ${e.id} is full (${e.outbox.length} messages, ${e.outboxBytes} bytes)');
    }
    final o = _Out(kind, schema, rid, payload);
    e.outbox.add(o);
    e.outboxBytes += payload.length;
    unawaited(_pump(e));
    return o;
  }

  Future<void> _pump(_Entry e) async {
    final c = e.conn;
    if (c == null || !c.ready || c.dead || c.pumping) return;
    c.pumping = true;
    try {
      while (e.conn == c && c.ready && !c.dead && e.outbox.isNotEmpty) {
        final o = e.outbox.removeFirst();
        e.outboxBytes -= o.payload.length;
        if (o.cancelled) {
          if (!o.done.isCompleted) o.done.complete();
          continue;
        }
        try {
          await _write(c, o.kind, o.payload, schema: o.schema, rid: o.rid);
          if (!o.done.isCompleted) o.done.complete();
        } catch (err) {
          if (!o.done.isCompleted) o.done.completeError(err is PeerError ? err : PeerLost('send failed: $err'));
          _linkDown(c, 'send failed');
          break;
        }
      }
    } finally {
      c.pumping = false;
    }
  }

  /// Queues [payload] for [peer]. The future completes when the transport has
  /// accepted the frame (not when the peer processed it: delivery is best
  /// effort). It fails with [PeerOutboxFull] right away if the peer's outbox is
  /// full, and with [PeerLost] later if the peer is lost first. If you do not
  /// await it, attach a handler or the late failure is an uncaught async error.
  ///
  /// Do not mutate [payload] after calling.
  Future<void> send(Peer peer, Uint8List payload, {String kind = PeerKinds.defaultKind, int schema = 0}) async {
    _checkKind(kind, schema, payload);
    final e = _entryFor(peer);
    await _queue(e, kind, schema, null, payload).done.future;
  }

  /// [send] to every ready peer. Never throws for one bad peer: failures are
  /// reported per peer in the result, and the future completes once every
  /// accepted frame has been handed to its link (or failed).
  Future<BroadcastResult> broadcast(Uint8List payload, {String kind = PeerKinds.defaultKind, int schema = 0}) async {
    _checkKind(kind, schema, payload);
    if (_closed) throw PeerClosed('hub is closed');
    final sent = <PeerId>[];
    final failed = <PeerId, Object>{};
    final waits = <Future<void>>[];
    for (final p in readyPeers) {
      try {
        final e = _entryFor(p);
        final o = _queue(e, kind, schema, null, payload);
        waits.add(o.done.future.then((_) => sent.add(p.id), onError: (Object err) => failed[p.id] = err));
      } catch (err) {
        failed[p.id] = err;
      }
    }
    await Future.wait(waits);
    return BroadcastResult(sent, failed);
  }

  /// Sends a request and returns the peer's reply (an [AppMessage] of the
  /// reserved reply kind; the payload is whatever the other app replied with).
  /// Fails with [PeerTimeout] after [timeout] (default `options.requestTimeout`),
  /// [PeerLost] if the peer goes away, [PeerOutboxFull], [PeerNotAvailable].
  Future<AppMessage> request(Peer peer, Uint8List payload,
      {String kind = PeerKinds.defaultKind, int schema = 0, Duration? timeout}) {
    try {
      _checkKind(kind, schema, payload);
      final e = _entryFor(peer);
      final rid = ++_nextRid;
      final key = _key(peer.id, rid);
      final completer = Completer<AppMessage>();
      final out = _queue(e, kind, schema, rid, payload);
      final timer = _clock.schedule(timeout ?? options.requestTimeout, () {
        final p = _pending.remove(key);
        if (p == null) return;
        p.out.cancelled = true;
        p.completer.completeError(PeerTimeout('no reply from ${peer.id} to request $rid'));
      });
      _pending[key] = _Pending(peer.id, completer, timer, out);
      out.done.future.then((_) {}, onError: (Object err) {
        final p = _pending.remove(key);
        if (p != null) {
          p.timer.cancel();
          p.completer.completeError(err);
        }
      });
      return completer.future;
    } catch (err) {
      return Future<AppMessage>.error(err);
    }
  }

  /// Answers [request] (an incoming [AppMessage] with a `requestId`). Replies
  /// ride the same ordered stream as everything else.
  Future<void> reply(AppMessage request, Uint8List payload, {int schema = 0}) async {
    final rid = request.requestId;
    if (rid == null) throw ArgumentError('that message is not a request');
    if (payload.length > Envelope.maxPayloadBytes) {
      throw EnvelopeError('payload is ${payload.length} bytes; the cap is ${Envelope.maxPayloadBytes}');
    }
    if (_closed) throw PeerClosed('hub is closed');
    final e = _entries[request.from];
    if (e == null) throw PeerNotAvailable('${request.from} is not a current peer');
    await _queue(e, PeerKinds.reply, schema, rid, payload).done.future;
  }

  String _key(PeerId p, int rid) => '$p#$rid';

  void _failPending(_Entry e, PeerError err) {
    while (e.outbox.isNotEmpty) {
      final o = e.outbox.removeFirst();
      if (!o.done.isCompleted) o.done.completeError(err);
    }
    e.outboxBytes = 0;
    final mine = _pending.entries.where((p) => p.value.peer == e.id).toList();
    for (final p in mine) {
      _pending.remove(p.key);
      p.value.timer.cancel();
      p.value.completer.completeError(err);
    }
  }

  // ---------------------------------------------------------------- hook plumbing

  void _fire(Peer p, PeerChange change) {
    _guard('onPeer', () => _hook.onPeer(p, change));
    if (!_changes.isClosed) _changes.add(PeerEvent(p, change));
  }

  void _guard(String where, void Function() f) {
    try {
      f();
    } catch (err, st) {
      _hookError(where, err, st);
    }
  }

  void _hookError(String where, Object err, StackTrace st) {
    stats.hookErrors++;
    options.onHookError?.call(where, err, st);
  }
}
