import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

/// Records what it is sent. A hook is the app's side of peer coordination; this one only listens.
class Listener extends AppCoordination {
  final received = <String>[];

  @override
  String get channel => 'default';
  @override
  Object? hello() => null;
  @override
  Admit admit(Peer peer, Object? theirHello) => const Admit.accept();
  @override
  void onPeer(Peer peer, PeerChange change) {}
  @override
  void onMessage(Peer from, AppMessage message) => received.add('${from.id.device}: ${message.jsonBody}');
}

void main() {
  late Directory scratch;
  setUp(() => scratch = Directory.systemTemp.createTempSync('app-context-example-'));
  tearDown(() => scratch.deleteSync(recursive: true));

  final manifest = AppManifest.parse(File('app.json').readAsStringSync());
  final env = {'APP_CONTEXT_MODE': 'mock'}; // the scratch directory is added per test

  Future<AppContext> launch(AppManifest m, [Map<String, String> more = const {}]) =>
      AppContext.open(m, env: {...env, 'APP_CONTEXT_SCRATCH': scratch.path, ...more}, announce: false);

  test('a setting written by one launch is read by the next, on the same scratch directory', () async {
    var ctx = await launch(manifest);
    ctx.config.set('launches', 1);
    await ctx.close();

    ctx = await launch(manifest);
    expect(ctx.config.get<int>('launches', 0), 1);
    await ctx.close();
  });

  test('mock mode gives a fake Venue that can be made to refuse, so a waiting loop is testable', () async {
    final ctx = await launch(manifest);
    final venue = ctx.venue as FakeVenue;
    venue.refuseNext(2); // the next two holds are refused as "does not fit"

    const need = VenueNeed(name: 'job', contractClass: 'container.run.v1');
    final result = await venue.withHoldWaiting(need, (hold) async => 'done',
        maxWait: const Duration(seconds: 5), retryEvery: const Duration(milliseconds: 2));

    expect(result, 'done');
    expect(venue.log, ['hold job', 'hold job', 'hold job', 'start job', 'release job']);
    await ctx.close();
  });

  test('two copies of an app find each other on one fake network and exchange a message', () async {
    final peerManifest = AppManifest.fromJson({'id': 'dev.example.hello', 'name': 'Hello', 'version': '0.1.0', 'kits': ['peers']});
    final network = FakePeerNetwork(); // pass the same network to both copies
    final laptop = await launch(peerManifest, {'APP_CONTEXT_DEVICE': 'laptop'});
    final phone = await launch(peerManifest, {'APP_CONTEXT_DEVICE': 'phone'});

    final listener = Listener();
    final laptopHub = laptop.peerHub(Listener(), network: network);
    final phoneHub = phone.peerHub(listener, network: network);
    await laptopHub.start();
    await phoneHub.start();

    for (var i = 0; i < 100 && laptopHub.readyPeers.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(laptopHub.readyPeers, isNotEmpty);

    await laptopHub.broadcast(PeerJson.encode({'text': 'hi'}), kind: 'greeting');
    for (var i = 0; i < 100 && listener.received.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(listener.received, ['laptop: {text: hi}']);

    await laptop.close();
    await phone.close();
  });
}
