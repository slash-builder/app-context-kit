// Shared helpers for the peer tests. Not a test file.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:app_context_kit/src/peers/peers.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
String text(Uint8List b) => utf8.decode(b);

/// A hook that records everything and lets a test script `admit`, `hello` and
/// `onMessage`.
class RecordingHook extends AppCoordination {
  RecordingHook({
    this.channelName = 'default',
    this.helloValue,
    this.admitFn,
    this.onMessageFn,
  });

  final String channelName;
  Object? helloValue;
  FutureOr<Admit> Function(Peer peer, Object? theirHello)? admitFn;
  void Function(Peer from, AppMessage m)? onMessageFn;

  PeerHub? hub;
  final List<String> events = []; // "found a@i1", "ready a@i1", "lost a@i1"
  final List<(Peer, PeerChange)> changes = [];
  final List<AppMessage> messages = [];
  final List<Object?> hellosSeen = [];

  @override
  String get channel => channelName;

  @override
  Object? hello() => helloValue;

  @override
  FutureOr<Admit> admit(Peer peer, Object? theirHello) {
    hellosSeen.add(theirHello);
    return admitFn?.call(peer, theirHello) ?? const Admit.accept();
  }

  @override
  void onPeer(Peer peer, PeerChange change) {
    events.add('${change.name} ${peer.id}');
    changes.add((peer, change));
  }

  @override
  void onMessage(Peer from, AppMessage message) {
    messages.add(message);
    onMessageFn?.call(from, message);
  }

  @override
  void attach(PeerHub h) => hub = h;

  List<String> get texts => messages.map((m) => text(m.payload)).toList();
  int count(String prefix) => events.where((e) => e.startsWith(prefix)).length;
}

/// One shared fake world: a manual clock, a seeded network, and a way to make hubs.
class World {
  World({int seed = 1}) : clock = ManualPeerClock() {
    network = FakePeerNetwork(clock: clock, seed: seed);
  }

  final ManualPeerClock clock;
  late final FakePeerNetwork network;
  final List<PeerHub> hubs = [];

  PeerHub hub(
    String device, {
    String instance = 'i1',
    String account = 'acct-1',
    String app = 'com.slashbuilder.demo.app',
    RecordingHook? hook,
    PeerAuthenticator? auth,
    PeerHubOptions options = const PeerHubOptions(),
    PeerProvider? provider,
  }) {
    final h = PeerHub(
      account: account,
      app: app,
      device: device,
      instance: instance,
      provider: provider ?? network.provider(),
      hook: hook ?? RecordingHook(),
      authenticator: auth,
      clock: clock,
      options: options,
      random: math.Random(hubs.length + 1),
    );
    hubs.add(h);
    return h;
  }

  Future<void> settle() => clock.settle();
  Future<void> advance(Duration d) => clock.advance(d);

  Future<void> closeAll() async {
    for (final h in hubs) {
      await h.close();
    }
  }
}

/// A hub and its recording hook.
class Node {
  Node(this.hub, this.hook);
  final PeerHub hub;
  final RecordingHook hook;

  Peer? peerNamed(String device) {
    for (final p in hub.peers) {
      if (p.id.device == device) return p;
    }
    return null;
  }

  Peer ready(String device) {
    final p = peerNamed(device);
    if (p == null || p.state != PeerState.ready) {
      throw StateError('${hub.id} has no ready peer $device (peers: ${hub.peers})');
    }
    return p;
  }
}

extension WorldNodes on World {
  /// Makes a hub with a fresh [RecordingHook]. Call `node.hub.start()` yourself,
  /// or use [startedNode].
  Node node(
    String device, {
    String instance = 'i1',
    String account = 'acct-1',
    String app = 'com.slashbuilder.demo.app',
    RecordingHook? hook,
    PeerAuthenticator? auth,
    PeerHubOptions options = const PeerHubOptions(),
    PeerProvider? provider,
  }) {
    final h = hook ?? RecordingHook();
    final hub = this.hub(device,
        instance: instance, account: account, app: app, hook: h, auth: auth, options: options, provider: provider);
    return Node(hub, h);
  }

  Future<Node> startedNode(
    String device, {
    String instance = 'i1',
    String account = 'acct-1',
    String app = 'com.slashbuilder.demo.app',
    RecordingHook? hook,
    PeerAuthenticator? auth,
    PeerHubOptions options = const PeerHubOptions(),
    PeerProvider? provider,
  }) async {
    final n = node(device,
        instance: instance, account: account, app: app, hook: hook, auth: auth, options: options, provider: provider);
    await n.hub.start();
    await settle();
    return n;
  }
}

/// A provider that fails the first [failures] connects, then delegates. Records
/// the clock time of every attempt.
class FlakyProvider implements PeerProvider {
  FlakyProvider(this.inner, this.clock, {this.failures = 0});
  final PeerProvider inner;
  final PeerClock clock;
  int failures;
  final List<DateTime> attempts = [];

  @override
  Future<void> open(PeerIdentity self) => inner.open(self);
  @override
  Stream<PeerCandidate> discover() => inner.discover();
  @override
  Stream<PeerLink> get incoming => inner.incoming;
  @override
  Future<void> close() => inner.close();

  @override
  Future<PeerLink> connect(PeerCandidate c) async {
    attempts.add(clock.now());
    if (failures > 0) {
      failures--;
      throw PeerConnectError('flaky: refusing');
    }
    return inner.connect(c);
  }
}

/// Wraps a provider so a test can hold every outgoing `send` on the dialed
/// links until [release] (a congested transport).
class GateProvider implements PeerProvider {
  GateProvider(this.inner);
  final PeerProvider inner;
  bool gated = false;
  final List<Completer<void>> _waiting = [];
  int sendsStarted = 0;

  void release() {
    gated = false;
    for (final c in _waiting) {
      if (!c.isCompleted) c.complete();
    }
    _waiting.clear();
  }

  @override
  Future<void> open(PeerIdentity self) => inner.open(self);
  @override
  Stream<PeerCandidate> discover() => inner.discover();
  @override
  Stream<PeerLink> get incoming => inner.incoming.map((l) => _GateLink(this, l));
  @override
  Future<void> close() async {
    release();
    await inner.close();
  }

  @override
  Future<PeerLink> connect(PeerCandidate c) async => _GateLink(this, await inner.connect(c));
}

class _GateLink implements PeerLink {
  _GateLink(this.owner, this.inner);
  final GateProvider owner;
  final PeerLink inner;

  @override
  PeerIdentity get remote => inner.remote;
  @override
  Stream<Uint8List> get inbound => inner.inbound;
  @override
  Future<void> close() => inner.close();

  @override
  Future<void> send(Uint8List bytes) async {
    owner.sendsStarted++;
    if (owner.gated) {
      final c = Completer<void>();
      owner._waiting.add(c);
      await c.future;
    }
    return inner.send(bytes);
  }
}

/// A provider with no network: the test pushes links in and reads what the hub
/// wrote. For proving the hub's own checks without trusting a real provider.
class ScriptedProvider implements PeerProvider {
  final StreamController<PeerLink> _in = StreamController<PeerLink>();
  final StreamController<PeerCandidate> _disc = StreamController<PeerCandidate>();
  PeerIdentity? self;

  @override
  Future<void> open(PeerIdentity s) async => self = s;
  @override
  Stream<PeerCandidate> discover() => _disc.stream;
  @override
  Stream<PeerLink> get incoming => _in.stream;
  @override
  Future<PeerLink> connect(PeerCandidate c) => throw PeerConnectError('scripted');
  @override
  Future<void> close() async {}

  void offer(PeerCandidate c) => _disc.add(c);

  ScriptedLink inject(PeerIdentity remote) {
    final l = ScriptedLink(remote);
    _in.add(l);
    return l;
  }
}

class ScriptedLink implements PeerLink {
  ScriptedLink(this.remote);
  @override
  final PeerIdentity remote;
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  final List<Envelope> sent = [];
  bool closed = false;

  @override
  Stream<Uint8List> get inbound => _in.stream;

  @override
  Future<void> send(Uint8List b) async {
    sent.add(Envelope.decode(b));
  }

  @override
  Future<void> close() async {
    closed = true;
    await _in.close();
  }

  void push(Uint8List frame) => _in.add(frame);
  void pushEnvelope(Envelope e) => _in.add(e.encode());
}
