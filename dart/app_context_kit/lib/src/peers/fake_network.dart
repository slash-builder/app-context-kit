/// An in-memory network for tests and for mock mode: several hubs join one
/// [FakePeerNetwork] through one [FakePeerProvider] each, and the test controls
/// partitions, latency, jitter, drops and duplicates.
///
/// Deterministic: all randomness comes from one seeded [math.Random], drawn
/// only when a fault knob is non-zero, and all delays go through the injected
/// [PeerClock] (use a [ManualPeerClock] and the run is exactly repeatable).
///
/// Scope is enforced here, not trusted to the hub: a provider only ever
/// *discovers* peers with the same account AND app id, refuses to *connect* to
/// any other, and refuses an *incoming* link from any other.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'clock.dart';
import 'provider.dart';
import 'types.dart';

/// One frame that reached a link end, kept so tests can prove what did (and did
/// not) arrive where.
class FakeDelivery {
  FakeDelivery(this.from, this.to, this.bytes, this.at);
  /// The sending end.
  final PeerIdentity from;
  /// The receiving end.
  final PeerIdentity to;
  /// The whole frame, as the hub wrote it. `Envelope.decode` reads it.
  final Uint8List bytes;
  /// When it was delivered, by the network's clock.
  final DateTime at;
}

/// One shared in-memory world. Give the same network to every hub that should see the others.
class FakePeerNetwork {
  FakePeerNetwork({PeerClock? clock, int seed = 0, this.maxRecordedDeliveries = 10000})
      : clock = clock ?? const SystemPeerClock(),
        _random = math.Random(seed);

  /// The clock every delay goes through.
  final PeerClock clock;
  final math.Random _random;
  /// How many entries [deliveries] keeps before dropping the oldest.
  final int maxRecordedDeliveries;

  // --- fault knobs (change at any time) ---

  /// Fixed delay for every frame. Zero delivers immediately (in event-loop order).
  Duration latency = Duration.zero;

  /// Extra random delay of 0 to `jitter` per frame; non-zero jitter can reorder frames.
  Duration jitter = Duration.zero;

  /// Probability (0..1) that a frame is silently lost.
  double dropRate = 0;

  /// Probability (0..1) that a frame is delivered twice.
  double duplicateRate = 0;

  /// Drop a frame when this returns true (applied before [dropRate]). The bytes
  /// are the whole frame, so a test can `Envelope.decode` it and pick a victim.
  bool Function(PeerIdentity from, PeerIdentity to, Uint8List bytes)? dropIf;

  /// Every frame delivered to a link end (oldest dropped past the cap).
  final List<FakeDelivery> deliveries = [];

  /// How many times any provider asked to connect (successful or not).
  int connectAttempts = 0;

  final Map<PeerId, FakePeerProvider> _open = {};
  final Set<PeerId> _isolated = {};
  final Set<String> _cuts = {};
  final Set<_FakeLink> _links = {};

  /// A new provider for one hub. Hand it to `PeerHub(provider: ...)`.
  FakePeerProvider provider() => FakePeerProvider._(this);

  /// Number of link ends currently open (two per connection).
  int get openLinkEnds => _links.length;

  // --- topology controls ---

  String _pairKey(PeerId a, PeerId b) => a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  bool _cut(PeerId a, PeerId b) => _isolated.contains(a) || _isolated.contains(b) || _cuts.contains(_pairKey(a, b));

  /// Cuts [a] from [b]: they stop seeing each other, and links between them die.
  void partition(PeerId a, PeerId b) {
    _cuts.add(_pairKey(a, b));
    _refresh(); // withdraw first, then cut: hubs see "gone" before "link closed"
    _killLinks((x, y) => (x == a && y == b) || (x == b && y == a));
  }

  /// Cuts [a] from everyone.
  void isolate(PeerId a) {
    _isolated.add(a);
    _refresh();
    _killLinks((x, y) => x == a || y == a);
  }

  /// Undoes [partition] ([b] given) or [isolate] and every cut involving [a] ([b] null).
  void heal(PeerId a, [PeerId? b]) {
    if (b != null) {
      _cuts.remove(_pairKey(a, b));
    } else {
      _isolated.remove(a);
      _cuts.removeWhere((k) => k.split('|').contains(a.toString()));
    }
    _refresh();
  }

  /// Undoes every [partition] and [isolate].
  void healAll() {
    _isolated.clear();
    _cuts.clear();
    _refresh();
  }

  /// Drops the links between [a] and [b] without cutting discovery: a flaky
  /// connection rather than a partition. Hubs should notice and redial.
  void dropLinks(PeerId a, PeerId b) => _killLinks((x, y) => (x == a && y == b) || (x == b && y == a));

  void _killLinks(bool Function(PeerId, PeerId) match) {
    for (final l in _links.toList()) {
      if (match(l.owner._self!.id, l.peerEnd.owner._self!.id)) {
        l._breakNow();
        l.peerEnd._breakNow();
      }
    }
  }

  /// Recomputes who can see whom and tells each provider what changed.
  void _refresh() {
    for (final p in _open.values.toList()) {
      p._reconcile();
    }
  }

  Iterable<FakePeerProvider> _visibleTo(FakePeerProvider p) sync* {
    final me = p._self!;
    for (final q in _open.values) {
      if (identical(q, p)) continue;
      final them = q._self!;
      if (!me.sameScope(them)) continue; // the scope key: same account AND same app
      if (_cut(me.id, them.id)) continue;
      yield q;
    }
  }

  // --- transport ---

  void _transmit(_FakeLink from, Uint8List bytes) {
    final to = from.peerEnd;
    final a = from.owner._self!;
    final b = to.owner._self!;
    if (_cut(a.id, b.id)) return;
    if (dropIf?.call(a, b, bytes) ?? false) return;
    if (dropRate > 0 && _random.nextDouble() < dropRate) return;
    final copies = (duplicateRate > 0 && _random.nextDouble() < duplicateRate) ? 2 : 1;
    for (var i = 0; i < copies; i++) {
      final extra = jitter > Duration.zero ? Duration(microseconds: _random.nextInt(jitter.inMicroseconds + 1)) : Duration.zero;
      final delay = latency + extra;
      final copy = Uint8List.fromList(bytes);
      if (delay == Duration.zero) {
        _deliver(a, b, to, copy);
      } else {
        clock.schedule(delay, () => _deliver(a, b, to, copy));
      }
    }
  }

  void _deliver(PeerIdentity from, PeerIdentity toId, _FakeLink to, Uint8List bytes) {
    if (to.closed) return;
    deliveries.add(FakeDelivery(from, toId, bytes, clock.now()));
    if (deliveries.length > maxRecordedDeliveries) deliveries.removeAt(0);
    to._in.add(bytes);
  }
}

/// A hub's view of a [FakePeerNetwork]. Made by [FakePeerNetwork.provider].
class FakePeerProvider implements PeerProvider {
  FakePeerProvider._(this._net);

  final FakePeerNetwork _net;
  PeerIdentity? _self;
  bool _closed = false;
  final Map<PeerId, PeerCandidate> _known = {};
  final StreamController<PeerCandidate> _events = StreamController<PeerCandidate>.broadcast(sync: true);
  final StreamController<PeerLink> _incoming = StreamController<PeerLink>();
  final Set<_FakeLink> _myLinks = {};

  /// Who this provider announced, or null before [open].
  PeerIdentity? get self => _self;

  @override
  Future<void> open(PeerIdentity self) async {
    if (_self != null) throw StateError('provider already opened');
    if (_closed) throw StateError('provider is closed');
    if (_net._open.containsKey(self.id)) throw StateError('${self.id} is already on this network');
    _self = self;
    _net._open[self.id] = this;
    _net._refresh();
  }

  void _reconcile() {
    final visible = <PeerId, PeerCandidate>{
      for (final q in _net._visibleTo(this)) q._self!.id: PeerCandidate(q._self!, q._self!.id.toString()),
    };
    for (final id in _known.keys.toList()) {
      if (!visible.containsKey(id)) {
        final gone = _known.remove(id)!;
        if (!_events.isClosed) _events.add(gone.withdrawn());
      }
    }
    for (final e in visible.entries) {
      if (!_known.containsKey(e.key)) {
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
    _net.connectAttempts++;
    if (_closed) throw PeerConnectError('provider is closed');
    if (!me.sameScope(c.identity)) {
      throw PeerScopeError('${c.identity} is not in scope ${me.account}/${me.app}');
    }
    final target = _net._open[c.id];
    if (target == null || target._closed || _net._cut(me.id, c.id)) {
      throw PeerConnectError('${c.id} is unreachable');
    }
    final mine = _FakeLink(this, target._self!);
    final theirs = _FakeLink(target, me);
    mine.peerEnd = theirs;
    theirs.peerEnd = mine;
    _net._links
      ..add(mine)
      ..add(theirs);
    _myLinks.add(mine);
    target._myLinks.add(theirs);
    target._accept(theirs);
    return mine;
  }

  void _accept(_FakeLink link) {
    // Defense in depth: even if a caller bypassed connect's check.
    if (!_self!.sameScope(link.remote) || _incoming.isClosed) {
      link._breakNow();
      link.peerEnd._breakNow();
      return;
    }
    _incoming.add(link);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final me = _self;
    if (me != null && identical(_net._open[me.id], this)) {
      _net._open.remove(me.id);
      _net._refresh();
      for (final l in _myLinks.toList()) {
        l._breakNow();
        l.peerEnd._breakNow();
      }
    }
    await _events.close();
    unawaited(_incoming.close());
  }
}

class _FakeLink implements PeerLink {
  _FakeLink(this.owner, this.remote);

  final FakePeerProvider owner;
  late _FakeLink peerEnd;
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  bool closed = false;

  @override
  final PeerIdentity remote;

  @override
  Stream<Uint8List> get inbound => _in.stream;

  FakePeerNetwork get _net => owner._net;

  @override
  Future<void> send(Uint8List bytes) async {
    if (closed) throw PeerLinkClosed('link to ${remote.id} is closed');
    _net._transmit(this, bytes);
  }

  /// Orderly close: our inbound ends now; the other end's ends after the
  /// longest in-flight delay, so a goodbye sent just before still arrives.
  @override
  Future<void> close() async {
    if (closed) return;
    _endLocal();
    final delay = _net.latency + _net.jitter;
    if (delay == Duration.zero) {
      peerEnd._endLocal();
    } else {
      _net.clock.schedule(delay, peerEnd._endLocal);
    }
  }

  /// Abrupt: this end goes away immediately (a cut cable).
  void _breakNow() => _endLocal();

  void _endLocal() {
    if (closed) return;
    closed = true;
    _net._links.remove(this);
    owner._myLinks.remove(this);
    unawaited(_in.close());
  }
}
