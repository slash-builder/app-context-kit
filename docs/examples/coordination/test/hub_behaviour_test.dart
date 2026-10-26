// Each test checks one claim that docs/COORDINATION-GUIDE.md makes about the hub. All run on the fake network in mock mode.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

/// A hook that records what it is told and replies to nothing.
class Recorder extends AppCoordination {
  Recorder({this.helloValue, this.admitFn});
  final Object? helloValue;
  final FutureOr<Admit> Function(Peer, Object?)? admitFn;
  PeerHub? hub;
  final messages = <AppMessage>[];
  final changes = <String>[];
  Object? helloAtReady;
  Peer? lastPeer;

  @override
  String get channel => 'rec';
  @override
  void attach(PeerHub hub) => this.hub = hub;
  @override
  Object? hello() => helloValue;
  @override
  FutureOr<Admit> admit(Peer peer, Object? theirHello) => admitFn?.call(peer, theirHello) ?? const Admit.accept();
  @override
  void onPeer(Peer peer, PeerChange change) {
    changes.add('${change.name} ${peer.id.device}');
    lastPeer = peer;
    if (change == PeerChange.ready) helloAtReady = peer.hello;
  }

  @override
  void onMessage(Peer from, AppMessage message) => messages.add(message);
}

Uint8List bytes(String s) => PeerJson.encode(s);

Future<bool> until(bool Function() ok, {Duration within = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(within);
  while (DateTime.now().isBefore(end)) {
    if (ok()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return ok();
}

void main() {
  late Directory scratch;
  setUp(() => scratch = Directory.systemTemp.createTempSync('hub-behaviour-'));
  tearDown(() => scratch.deleteSync(recursive: true));

  Future<(AppContext, PeersHandle, Recorder)> copy(String device, FakePeerNetwork net,
      {Recorder? hook, PeerHubOptions options = const PeerHubOptions()}) async {
    final ctx = await AppContext.open(
      AppManifest.fromJson({'id': 'dev.example.rec', 'name': 'Rec', 'version': '0.1.0', 'kits': ['peers']}),
      env: {'APP_CONTEXT_MODE': 'mock', 'APP_CONTEXT_SCRATCH': '${scratch.path}/$device', 'APP_CONTEXT_DEVICE': device},
      platform: 'linux',
      home: '/unused',
      announce: false,
    );
    final h = hook ?? Recorder();
    final handle = ctx.startPeers(h, network: net, options: options);
    await handle.started;
    return (ctx, handle, h);
  }

  Future<(Peer, Peer)> connect((AppContext, PeersHandle, Recorder) a, (AppContext, PeersHandle, Recorder) b) async {
    expect(await until(() => a.$2.hub!.readyPeers.isNotEmpty && b.$2.hub!.readyPeers.isNotEmpty), isTrue);
    return (a.$2.hub!.readyPeers.single, b.$2.hub!.readyPeers.single);
  }

  test('seq is per link and counts the Kit handshake frames; a lost frame shows as a jump', () async {
    final net = FakePeerNetwork();
    // Drop the second app message on the way to "b".
    net.dropIf = (from, to, frame) {
      final e = Envelope.decode(frame);
      return e.header.kind == 'msg' && String.fromCharCodes(e.payload) == '"two"';
    };
    final a = await copy('a', net);
    final b = await copy('b', net);
    final (toB, _) = await connect(a, b);

    for (final word in ['one', 'two', 'three']) {
      await a.$2.hub!.send(toB, bytes(word)); // completes even for the frame the network drops
    }
    expect(await until(() => b.$3.messages.length == 2), isTrue);
    final seqs = b.$3.messages.map((m) => m.seq).toList();
    // hello, auth and ready took seq 1 to 3, so the first app message is 4. "two" (5) never arrived, so the app sees 4 then 6.
    expect(seqs, [4, 6]);

    await a.$1.close();
    await b.$1.close();
  });

  test('send completing is not "applied": the frame the network drops still completes the future', () async {
    final net = FakePeerNetwork()..dropRate = 0;
    final a = await copy('a', net);
    final b = await copy('b', net);
    final (toB, _) = await connect(a, b);
    net.dropRate = 1; // from now on every frame is lost
    await a.$2.hub!.send(toB, bytes('into the void')); // does not throw
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(b.$3.messages, isEmpty);
    await a.$1.close();
    await b.$1.close();
  });

  test('broadcast reports who it was queued for', () async {
    final net = FakePeerNetwork();
    final a = await copy('a', net);
    final b = await copy('b', net);
    final c = await copy('c', net);
    expect(await until(() => a.$2.hub!.readyPeers.length == 2), isTrue);
    final result = await a.$2.hub!.broadcast(bytes('hi'));
    expect(result.sent.map((p) => p.device).toSet(), {'b', 'c'});
    expect(result.failed, isEmpty);
    expect(await until(() => b.$3.messages.length == 1 && c.$3.messages.length == 1), isTrue);
    for (final x in [a, b, c]) {
      await x.$1.close();
    }
  });

  test('a full outbox fails send with PeerOutboxFull', () async {
    final net = FakePeerNetwork();
    final a = await copy('a', net, options: const PeerHubOptions(outboxMessages: 2));
    final b = await copy('b', net);
    final (toB, _) = await connect(a, b);
    // Ten sends in a row without awaiting: the outbox holds two, so some of them fail at once.
    var full = 0;
    final all = <Future<void>>[
      for (var i = 0; i < 10; i++)
        a.$2.hub!.send(toB, bytes('$i')).catchError((Object e) {
          if (e is PeerOutboxFull) full++;
        }),
    ];
    await Future.wait(all);
    expect(full, greaterThan(0));
    await a.$1.close();
    await b.$1.close();
  });

  test('size and name limits: 1 MiB payload cap, the kit. prefix is reserved, PeerJson.encodeWithin', () async {
    final net = FakePeerNetwork();
    final a = await copy('a', net);
    final b = await copy('b', net);
    final (toB, _) = await connect(a, b);
    final hub = a.$2.hub!;

    await expectLater(hub.send(toB, Uint8List(Envelope.maxPayloadBytes + 1)), throwsA(isA<EnvelopeError>()));
    await expectLater(hub.send(toB, Uint8List(0), kind: 'kit.hello'), throwsA(isA<ArgumentError>()));
    expect(Envelope.maxPayloadBytes, 1024 * 1024);

    expect(PeerJson.fits({'a': 'x' * 100}, 64), isFalse);
    expect(() => PeerJson.encodeWithin({'a': 'x' * 100}, 64), throwsA(isA<PeerPayloadTooLarge>()));
    expect(PeerJson.decode(Uint8List.fromList([0xff, 0xfe])), isNull); // not UTF-8: null, never a throw
    expect(PeerJson.decode(bytes('x' * 10), maxBytes: 5), isNull);
    expect(PeerJson.label(hub.id), startsWith('a #'));

    await a.$1.close();
    await b.$1.close();
  });

  test('request times out with PeerTimeout when the other hook never replies', () async {
    final net = FakePeerNetwork();
    final a = await copy('a', net);
    final b = await copy('b', net);
    final (toB, _) = await connect(a, b);
    await expectLater(
      a.$2.hub!.request(toB, bytes('anyone?'), timeout: const Duration(milliseconds: 150)),
      throwsA(isA<PeerTimeout>()),
    );
    // The request still arrived, carrying a request id; nobody answered it.
    expect(b.$3.messages.single.requestId, isNotNull);
    await a.$1.close();
    await b.$1.close();
  });

  test('admit can reject; the other side sees the reason and the peer is never ready', () async {
    final net = FakePeerNetwork();
    final a = await copy('a', net, hook: Recorder(helloValue: {'proto': 1}));
    final b = await copy('b', net,
        hook: Recorder(
          helloValue: {'proto': 2},
          admitFn: (peer, hello) => hello is Map && hello['proto'] == 2 ? const Admit.accept() : const Admit.reject('proto 2 only'),
        ));
    expect(await until(() => a.$3.changes.contains('lost b')), isTrue);
    expect(a.$3.changes, isNot(contains('ready b')));
    expect(b.$3.changes, isNot(contains('ready a')));
    expect(a.$2.hub!.peers, isEmpty);
    expect(a.$3.lastPeer!.state, PeerState.rejected);
    expect(a.$3.lastPeer!.rejectReason, 'rejected by peer: proto 2 only');
    expect(b.$3.lastPeer!.rejectReason, 'proto 2 only');
    await a.$1.close();
    await b.$1.close();
  });

  test('the hello is a snapshot the peer can read in onPeer(ready)', () async {
    final net = FakePeerNetwork();
    final a = await copy('a', net, hook: Recorder(helloValue: {'version': 7}));
    final b = await copy('b', net, hook: Recorder(helloValue: {'version': 3}));
    await connect(a, b);
    expect(a.$3.helloAtReady, {'version': 3});
    expect(b.$3.helloAtReady, {'version': 7});
    await a.$1.close();
    await b.$1.close();
  });

  test('a message sent before the other side is ready is not delivered (no replay for late joiners)', () async {
    final net = FakePeerNetwork();
    final a = await copy('a', net);
    final lateMessages = <AppMessage>[];
    // Nobody is there yet: broadcast has no one to send to, and nothing is kept for a copy that arrives later.
    final result = await a.$2.hub!.broadcast(bytes('anyone home?'));
    expect(result.sent, isEmpty);
    final b = await copy('b', net, hook: Recorder());
    await until(() => b.$2.hub!.readyPeers.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    lateMessages.addAll(b.$3.messages);
    expect(lateMessages, isEmpty);
    await a.$1.close();
    await b.$1.close();
  });
}
