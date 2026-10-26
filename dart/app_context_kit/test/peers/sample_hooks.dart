// App-side sample hooks for the three kinds of coordination. The hub is the
// same class in all three and does not know which is which: it sees a channel
// name, a hello, an admit decision, peers coming and going, and opaque bytes.
//
// Test-only: these show the shape of what an app writes (the line counts are the
// measurement), they are not Kit API.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_context_kit/src/peers/peers.dart';

Uint8List _enc(Object? v) => Uint8List.fromList(utf8.encode(jsonEncode(v)));
Object? _dec(Uint8List b) => jsonDecode(utf8.decode(b));

/// Fire and forget without an uncaught async error when the peer vanishes.
void _quiet(Future<Object?> f) => unawaited(f.then((_) {}, onError: (_) {}));

/// When a hook is one facet of a bigger app (see [MuxHook]), the peer's hello is
/// a map keyed by facet name; standalone, the hello is the facet's own.
Object? _theirs(Peer p, String? facet) {
  final h = p.hello;
  if (facet == null) return h;
  return h is Map ? h[facet] : null;
}

// ---------------------------------------------------------------------------
// 1. A live signal: "the timer finished". No state, no merge, no admission policy.
// ---------------------------------------------------------------------------

class TimerSignalHook extends AppCoordination {
  TimerSignalHook({this.facet, this.onFinished});
  final String? facet;
  void Function(String label, PeerId from)? onFinished;
  PeerHub? hub;
  String? lastFinished; // told to late joiners through hello, never replayed

  @override
  String get channel => 'stopwatch';
  @override
  void attach(PeerHub h) => hub = h;
  @override
  Object? hello() => {'lastFinished': lastFinished};
  @override
  FutureOr<Admit> admit(Peer peer, Object? theirHello) => const Admit.accept();
  @override
  void onPeer(Peer peer, PeerChange change) {}

  void finish(String label) {
    lastFinished = label;
    _quiet(hub!.broadcast(_enc({'label': label}), kind: 'timer.finished', schema: 1));
  }

  @override
  void onMessage(Peer from, AppMessage m) {
    if (m.kind == 'timer.finished' && m.schema == 1) {
      onFinished?.call((_dec(m.payload) as Map)['label'] as String, from.id);
    }
  }

  /// What a late joiner learns from the hello alone.
  String? lastFinishedOf(Peer p) => ((_theirs(p, facet)) as Map?)?['lastFinished'] as String?;
}

// ---------------------------------------------------------------------------
// 2. Sync: "the note changed, here is the new version". The MERGE RULE is the
//    app's: last writer wins on a stamp, ties broken by writer id. The Kit
//    carries bytes; it has no idea this is a merge.
// ---------------------------------------------------------------------------

class NoteVersion {
  NoteVersion(this.text, this.stamp, this.writer);
  final String text;
  final int stamp; // app-chosen: here, milliseconds
  final String writer;

  /// The app's conflict rule.
  bool beats(NoteVersion other) => stamp != other.stamp ? stamp > other.stamp : writer.compareTo(other.writer) > 0;

  Map<String, Object?> toJson() => {'text': text, 'stamp': stamp, 'writer': writer};
  static NoteVersion fromJson(Map j) => NoteVersion(j['text'] as String, j['stamp'] as int, j['writer'] as String);
  Map<String, Object?> versionOnly() => {'stamp': stamp, 'writer': writer};
}

class NoteSyncHook extends AppCoordination {
  NoteSyncHook(this.device, {this.facet, this.onChanged});
  final String device;
  final String? facet;
  void Function(NoteVersion)? onChanged;
  PeerHub? hub;
  NoteVersion note = NoteVersion('', 0, '');

  @override
  String get channel => 'notes';
  @override
  void attach(PeerHub h) => hub = h;

  /// Only the version goes in the hello, so connecting is cheap and the text
  /// moves only if someone is behind.
  @override
  Object? hello() => note.versionOnly();

  @override
  FutureOr<Admit> admit(Peer peer, Object? theirHello) => const Admit.accept();

  /// The decision to push is the app's: whoever is ahead sends, so a healed
  /// partition converges without anyone asking.
  @override
  void onPeer(Peer peer, PeerChange change) {
    if (change != PeerChange.ready) return;
    final theirs = _theirs(peer, facet);
    if (theirs is! Map) return;
    final theirVersion = NoteVersion(note.text, theirs['stamp'] as int, theirs['writer'] as String);
    if (note.beats(theirVersion) && note.stamp > 0) {
      _quiet(hub!.send(peer, _enc(note.toJson()), kind: 'note.full', schema: 1));
    }
  }

  void edit(String text, int stamp) {
    final v = NoteVersion(text, stamp, device);
    if (!v.beats(note)) return; // the rule applies to local writes too (a skewed clock loses)
    note = v;
    onChanged?.call(note);
    _quiet(hub!.broadcast(_enc(note.toJson()), kind: 'note.changed', schema: 1));
  }

  @override
  void onMessage(Peer from, AppMessage m) {
    if (m.kind != 'note.changed' && m.kind != 'note.full') return;
    if (m.schema != 1) return; // a newer app version wrote this; we cannot read it
    final incoming = NoteVersion.fromJson(_dec(m.payload) as Map);
    if (incoming.beats(note)) {
      note = incoming;
      onChanged?.call(note);
    }
  }
}

// ---------------------------------------------------------------------------
// 3. Handoff: "send me your current game state". A request/reply the app
//    defines; admit enforces the app's own version policy.
// ---------------------------------------------------------------------------

class GameHandoffHook extends AppCoordination {
  GameHandoffHook({this.proto = 3, this.facet});
  final int proto;
  final String? facet;
  PeerHub? hub;
  Map<String, Object?> game = {};
  bool released = false;

  @override
  String get channel => 'game';
  @override
  void attach(PeerHub h) => hub = h;
  @override
  Object? hello() => {'proto': proto, 'moves': game['moves'], 'inProgress': game.isNotEmpty && !released};

  @override
  FutureOr<Admit> admit(Peer peer, Object? theirHello) {
    final h = _theirs(peer, facet);
    if (h is! Map || h['proto'] != proto) return Admit.reject('game protocol $proto only');
    return const Admit.accept();
  }

  @override
  void onPeer(Peer peer, PeerChange change) {}

  /// Ask [peer] for its state, adopt it, then tell it to stand down.
  Future<void> pullFrom(Peer peer, {Duration timeout = const Duration(seconds: 5)}) async {
    final reply = await hub!.request(peer, _enc({'want': 'state'}), kind: 'game.pull', schema: 1, timeout: timeout);
    game = (_dec(reply.payload) as Map).cast<String, Object?>();
    released = false;
    await hub!.send(peer, Uint8List(0), kind: 'game.done', schema: 1);
  }

  @override
  void onMessage(Peer from, AppMessage m) {
    switch (m.kind) {
      case 'game.pull':
        if (m.requestId != null && !released) _quiet(hub!.reply(m, _enc(game), schema: 1));
      case 'game.done':
        released = true; // the other copy owns the game now
    }
  }
}

// ---------------------------------------------------------------------------
// One app, three kinds of coordination, ONE hub: the app muxes by kind prefix.
// This is the cost of "one hub = one channel" and "admit is per peer".
// ---------------------------------------------------------------------------

class MuxHook extends AppCoordination {
  MuxHook(this.channelName, this.facets);
  final String channelName;

  /// facet name -> hook; kinds are routed by the `name.` prefix.
  final Map<String, AppCoordination> facets;

  @override
  String get channel => channelName;

  @override
  void attach(PeerHub hub) {
    for (final f in facets.values) {
      f.attach(hub);
    }
  }

  @override
  Object? hello() => {for (final e in facets.entries) e.key: e.value.hello()};

  @override
  Future<Admit> admit(Peer peer, Object? theirHello) async {
    // One answer per peer: any facet that refuses refuses the whole peer.
    for (final f in facets.values) {
      final d = await f.admit(peer, theirHello);
      if (!d.accepted) return d;
    }
    return const Admit.accept();
  }

  @override
  void onPeer(Peer peer, PeerChange change) {
    for (final f in facets.values) {
      f.onPeer(peer, change);
    }
  }

  @override
  void onMessage(Peer from, AppMessage m) {
    facets[m.kind.split('.').first]?.onMessage(from, m);
  }
}
