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

AppManifest manifest({List<String> kits = const ['peers']}) =>
    AppManifest.fromJson({'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0', 'kits': kits});

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-peers-ctx-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppContext> open({List<String> kits = const ['peers'], Map<String, String> env = const {}}) =>
      AppContext.open(manifest(kits: kits),
          env: {'APP_CONTEXT_SCRATCH': tmp.path, 'APP_CONTEXT_MODE': 'mock', ...env}, platform: 'linux', home: '/x', announce: false);

  test('an app that does not list "peers" in its kits cannot build a hub', () async {
    final ctx = await open(kits: const []);
    expect(() => ctx.peerHub(_Quiet()), throwsA(isA<KitNotDeclared>()));
    await ctx.close();
  });

  test('account defaults to local, device is generated once and then stable across opens', () async {
    var ctx = await open();
    expect(ctx.peerAccount, 'local');
    final d1 = ctx.peerDevice;
    expect(d1, matches(RegExp(r'^d-[0-9a-f]{8}$')));
    await ctx.close();
    ctx = await open();
    expect(ctx.peerDevice, d1);
    await ctx.close();
  });

  test('environment overrides account and device', () async {
    final ctx = await open(env: {'APP_CONTEXT_ACCOUNT': 'acct-1', 'APP_CONTEXT_DEVICE': 'laptop'});
    expect((ctx.peerAccount, ctx.peerDevice), ('acct-1', 'laptop'));
    await ctx.close();
  });

  test('a damaged settings file gives an ephemeral device id and is not overwritten', () async {
    final probe = await open();
    final cfg = File('${probe.dirs.config}/config.json');
    await probe.close();
    cfg.writeAsStringSync('{broken');
    final ctx = await open();
    expect(ctx.peerDevice, matches(RegExp(r'^d-[0-9a-f]{8}$')));
    expect(cfg.readAsStringSync(), '{broken');
    await ctx.close();
  });

  test('two copies in mock mode on one fake network find and talk to each other, scoped to account and app', () async {
    final net = FakePeerNetwork();
    final a = await open(env: {'APP_CONTEXT_DEVICE': 'one'});
    final b = await open(env: {'APP_CONTEXT_DEVICE': 'two'});
    final got = <String>[];
    final hookB = _Collect(got);
    final hubA = a.peerHub(_Quiet(), network: net);
    final hubB = b.peerHub(hookB, network: net);
    await hubA.start();
    await hubB.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hubA.readyPeers, isNotEmpty);
    await hubA.broadcast(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(got, ['one:3']);
    await a.close();
    await b.close();
  });
}

class _Collect extends _Quiet {
  _Collect(this.out);
  final List<String> out;
  @override
  void onMessage(Peer from, AppMessage message) => out.add('${from.id.device}:${message.payload.length}');
}
