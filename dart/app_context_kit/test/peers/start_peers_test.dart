import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

class _Quiet extends AppCoordination {
  @override
  String get channel => 'default';
  @override
  Object? hello() => null;
  @override
  Admit admit(Peer peer, Object? theirHello) => const Admit.accept();
  @override
  void onPeer(Peer peer, PeerChange change) {}
  @override
  void onMessage(Peer from, AppMessage message) {}
}

class _Collect extends _Quiet {
  _Collect(this.out);
  final List<String> out;
  @override
  void onMessage(Peer from, AppMessage message) =>
      out.add('${from.id.device}:${message.payload.length}');
}

AppManifest manifest({List<String> kits = const ['peers']}) =>
    AppManifest.fromJson({
      'id': 'com.slashbuilder.demo.calc',
      'name': 'Calc',
      'version': '0.1.0',
      'kits': kits
    });

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-start-peers-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppContext> open(
          {List<String> kits = const ['peers'],
          Map<String, String> env = const {},
          bool mock = true}) =>
      AppContext.open(manifest(kits: kits),
          env: {
            'APP_CONTEXT_SCRATCH': tmp.path,
            'APP_CONTEXT_MODE': mock ? 'mock' : 'real',
            ...env
          },
          platform: 'linux',
          home: '/x',
          announce: false);

  test('KitNotDeclared is not swallowed: it is a bug in the app', () async {
    final ctx = await open(kits: const []);
    expect(() => ctx.startPeers(_Quiet()), throwsA(isA<KitNotDeclared>()));
    await ctx.close();
  });

  test(
      'two copies on one fake network start, find each other and talk; changes fires; no error',
      () async {
    final net = FakePeerNetwork();
    final a = await open(env: {'APP_CONTEXT_DEVICE': 'one'});
    final b = await open(env: {'APP_CONTEXT_DEVICE': 'two'});
    final got = <String>[];
    final pa = a.startPeers(_Quiet(), network: net);
    final pb = b.startPeers(_Collect(got), network: net);
    expect(pa.hub, isNotNull,
        reason: 'the hub is there at once, even while it opens');
    var fired = 0;
    final sub = pa.changes.listen((_) => fired++);
    await Future.wait([pa.started, pb.started]);
    expect((pa.error, pa.isRunning, pa.isStarting), (null, true, false));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(pa.hub!.readyPeers, isNotEmpty);
    expect(fired, greaterThan(0), reason: 'the open and the peer both notify');
    await pa.hub!.broadcast(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(got, ['one:3']);
    await sub.cancel();
    await a.close();
    await b.close();
  });

  test('started completes after the open and changes fires once for it',
      () async {
    final ctx = await open();
    final p = ctx.startPeers(_Quiet());
    expect(p.isStarting, isTrue);
    final fired = <int>[];
    p.changes.listen((_) => fired.add(1));
    await p.started;
    await Future<void>.delayed(Duration.zero);
    expect(p.isStarting, isFalse);
    expect(fired, [1]);
    await ctx.close();
  });

  test(
      'an unwritable peers directory is an error on the handle, not an exception; the app keeps working',
      () async {
    final blocker = File('${tmp.path}/not-a-dir')..writeAsStringSync('x');
    final ctx = await open(
        mock: false, env: {'APP_CONTEXT_PEERS_DIR': '${blocker.path}/peers'});
    final p = ctx.startPeers(_Quiet());
    expect(p.hub, isNull);
    expect(p.error, startsWith('peers unavailable: '));
    expect(p.error, contains('not-a-dir'));
    expect(p.isRunning, isFalse);
    await p.started; // completes normally
    await ctx.close(); // and closing the context has nothing to complain about
  });

  test(
      'a provider that fails to open: error set, hub dropped, started completes without an error, changes fires',
      () async {
    // The loopback provider only accepts [A-Za-z0-9._-] in a device id; a slash makes open() throw.
    final ctx = await open(mock: false, env: {'APP_CONTEXT_DEVICE': 'bad/device'});
    final p = ctx.startPeers(_Quiet());
    final fired = <String?>[];
    p.changes.listen((_) => fired.add(p.error));
    await p.started;
    await Future<void>.delayed(Duration.zero);
    expect(p.hub, isNull);
    expect(p.error, startsWith('peers unavailable: '));
    expect(p.isRunning, isFalse);
    expect(fired, [p.error]);
    await ctx
        .close(); // closing a hub that never opened does not fail the context
  });

  test('the hub and the change stream close with the context', () async {
    final ctx = await open();
    final p = ctx.startPeers(_Quiet());
    await p.started;
    final hub = p.hub!;
    final done = Completer<void>();
    p.changes.listen((_) {}, onDone: done.complete);
    await ctx.close();
    expect(hub.isClosed, isTrue);
    await done.future.timeout(const Duration(seconds: 2));
  });
}
