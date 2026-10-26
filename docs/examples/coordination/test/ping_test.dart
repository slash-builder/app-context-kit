import 'dart:async';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:coordination_examples/ping_hook.dart';
import 'package:test/test.dart';

/// The manifest must list "peers", or ctx.startPeers throws KitNotDeclared.
const manifestJson = {
  'id': 'dev.example.ping',
  'name': 'Ping',
  'version': '0.1.0',
  'kits': ['peers'],
};

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
  setUp(() => scratch = Directory.systemTemp.createTempSync('ping-example-'));
  tearDown(() => scratch.deleteSync(recursive: true));

  /// One copy of the app: its own AppContext, in mock mode, on the shared fake network.
  Future<({AppContext ctx, PingHook hook, PeersHandle peers})> copy(
    String device,
    FakePeerNetwork network, {
    Map<String, Object?> manifest = manifestJson,
    String account = 'home',
  }) async {
    final ctx = await AppContext.open(
      AppManifest.fromJson(manifest),
      env: {
        'APP_CONTEXT_MODE': 'mock',
        'APP_CONTEXT_SCRATCH': '${scratch.path}/$device',
        'APP_CONTEXT_DEVICE': device,
        'APP_CONTEXT_ACCOUNT': account,
      },
      platform: 'linux',
      home: '/unused',
      announce: false,
    );
    final hook = PingHook();
    final peers = ctx.startPeers(hook, network: network);
    await peers.started;
    return (ctx: ctx, hook: hook, peers: peers);
  }

  test('two copies of one app find each other, ping, and get a pong', () async {
    final network = FakePeerNetwork();
    final laptop = await copy('laptop', network);
    final desktop = await copy('desktop', network);

    expect(await until(() => laptop.peers.hub!.readyPeers.isNotEmpty && desktop.peers.hub!.readyPeers.isNotEmpty), isTrue);

    final desktopFromLaptop = laptop.peers.hub!.readyPeers.single;
    expect(desktopFromLaptop.id.device, 'desktop');
    expect(await laptop.hook.ping(desktopFromLaptop), 'desktop');

    final laptopFromDesktop = desktop.peers.hub!.readyPeers.single;
    expect(await desktop.hook.ping(laptopFromDesktop), 'laptop');

    // The hook heard found, then ready, in that order, on both sides.
    expect(laptop.hook.events, ['found desktop', 'ready desktop']);
    expect(desktop.hook.events, ['found laptop', 'ready laptop']);
    expect(laptop.hook.ignored + desktop.hook.ignored, 0);

    await laptop.ctx.close();
    await desktop.ctx.close();
  });

  test('a copy that closes says goodbye, and the other copy sees it lost', () async {
    final network = FakePeerNetwork();
    final laptop = await copy('laptop', network);
    final desktop = await copy('desktop', network);
    expect(await until(() => laptop.peers.hub!.readyPeers.isNotEmpty), isTrue);
    final seen = laptop.peers.hub!.readyPeers.single;

    await desktop.ctx.close();
    expect(await until(() => laptop.hook.events.contains('lost desktop')), isTrue);
    expect(seen.state, PeerState.lost);
    expect(seen.lostReason, 'goodbye');
    expect(laptop.peers.hub!.peers, isEmpty);

    await laptop.ctx.close();
  });

  test('another app id or another account on the same network is never offered', () async {
    final network = FakePeerNetwork();
    final laptop = await copy('laptop', network);
    final otherApp = await copy('desktop', network, manifest: {...manifestJson, 'id': 'dev.example.other'});
    final otherAccount = await copy('tablet', network, account: 'someone-else');

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(laptop.peers.hub!.peers, isEmpty);
    expect(otherApp.peers.hub!.peers, isEmpty);
    expect(otherAccount.peers.hub!.peers, isEmpty);
    expect(laptop.hook.events, isEmpty);

    for (final c in [laptop, otherApp, otherAccount]) {
      await c.ctx.close();
    }
  });

  test('a manifest without "peers" in kits throws KitNotDeclared', () async {
    final network = FakePeerNetwork();
    final ctx = await AppContext.open(
      AppManifest.fromJson({...manifestJson, 'kits': <String>[]}),
      env: {'APP_CONTEXT_MODE': 'mock', 'APP_CONTEXT_SCRATCH': '${scratch.path}/x'},
      platform: 'linux',
      home: '/unused',
      announce: false,
    );
    expect(() => ctx.startPeers(PingHook(), network: network), throwsA(isA<KitNotDeclared>()));
    await ctx.close();
  });
}
