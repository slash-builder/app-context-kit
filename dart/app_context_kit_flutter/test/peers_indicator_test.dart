import 'dart:async';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/peers.dart';
import 'package:app_context_kit_flutter/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _manifest = '{"id":"dev.test.peers","name":"Peers","version":"0.0.1","kits":["peers"]}';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

class _Hook extends AppCoordination {
  _Hook({this.gate});

  /// When set, `admit` waits for it: the other copy stays "connecting".
  final Future<void>? gate;
  @override
  String get channel => 'default';
  @override
  Object? hello() => null;
  @override
  FutureOr<Admit> admit(Peer peer, Object? theirHello) async {
    await gate;
    return const Admit.accept();
  }

  @override
  void onPeer(Peer peer, PeerChange change) {}
  @override
  void onMessage(Peer from, AppMessage message) {}
}

/// Real async work (sockets, timers) cannot finish under the test's fake clock: let it run, then pump.
Future<void> _until(WidgetTester t, bool Function() ok, {String what = 'condition'}) async {
  for (var i = 0; i < 100; i++) {
    if (ok()) return;
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }
  fail('timed out waiting for $what');
}

/// Starts peers inside `runAsync`: the hub's timers and sockets must be created in the real zone, not under the test's fake clock.
Future<PeersHandle> _start(WidgetTester t, KitTestContext kit, AppCoordination hook, {FakePeerNetwork? network}) async =>
    (await t.runAsync(() async => kit.ctx.startPeers(hook, network: network)))!;

void main() {
  testWidgets('no hub: says peers are off, with the reason, in words and an icon', (t) async {
    final sem = t.ensureSemantics();
    await t.pumpWidget(_host(const PeersIndicator(hub: null, offlineReason: 'peers unavailable: disk full')));
    expect(find.byKey(const ValueKey('peers-offline')), findsOneWidget);
    expect(find.text('Peers: off (peers unavailable: disk full)'), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Peers are off.*disk full')), findsOneWidget);
    sem.dispose();
  });

  testWidgets('no hub and no reason: just "Peers: off"', (t) async {
    await t.pumpWidget(_host(const PeersIndicator(hub: null)));
    expect(find.text('Peers: off'), findsOneWidget);
  });

  testWidgets('a handle whose directory is unwritable shows why, and the app around it is fine', (t) async {
    final blocker = Directory.systemTemp.createTempSync('peers-ind-')..createSync();
    addTearDown(() => blocker.deleteSync(recursive: true));
    final file = File('${blocker.path}/plain')..writeAsStringSync('x');
    final kit = await testAppContext(t, manifest: _manifest, env: {'APP_CONTEXT_MODE': 'real', 'APP_CONTEXT_PEERS_DIR': '${file.path}/peers'});
    final handle = await _start(t, kit, _Hook());
    await t.pumpWidget(_host(PeersIndicator.forHandle(handle)));
    expect(handle.hub, isNull);
    expect(find.byKey(const ValueKey('peers-offline')), findsOneWidget);
    expect(find.textContaining('Peers: off (peers unavailable:'), findsOneWidget);
    await kit.close();
  });

  testWidgets('a handle for a provider that fails to open ends up showing the error', (t) async {
    final kit = await testAppContext(t, manifest: _manifest, env: {'APP_CONTEXT_MODE': 'real', 'APP_CONTEXT_DEVICE': 'bad/device'});
    final handle = await _start(t, kit, _Hook());
    await t.pumpWidget(_host(PeersIndicator.forHandle(handle)));
    await _until(t, () => handle.error != null, what: 'the open to fail');
    await t.pump();
    expect(find.byKey(const ValueKey('peers-offline')), findsOneWidget);
    expect(find.textContaining('peers unavailable:'), findsOneWidget);
    await kit.close();
  });

  testWidgets('two copies: the count, the chip and the semantics follow peers arriving and leaving', (t) async {
    final net = (await t.runAsync(() async => FakePeerNetwork()))!;
    final a = await testAppContext(t, manifest: _manifest, env: {'APP_CONTEXT_DEVICE': 'laptop'});
    final b = await testAppContext(t, manifest: _manifest, env: {'APP_CONTEXT_DEVICE': 'phone'});
    final sem = t.ensureSemantics();
    final ha = await _start(t, a, _Hook(), network: net);
    await t.pumpWidget(_host(PeersIndicator.forHandle(ha, extra: 'Hello from the app')));
    await _until(t, () => ha.isRunning, what: 'copy A to open');
    expect(find.text('Peers: 0'), findsOneWidget);
    expect(find.textContaining('This copy: laptop #'), findsOneWidget);
    expect(find.text('Hello from the app'), findsOneWidget);

    final hb = await _start(t, b, _Hook(), network: net);
    await _until(t, () => find.text('Peers: 1').evaluate().isNotEmpty, what: 'copy B to appear');
    final phone = PeerJson.label(hb.hub!.id);
    expect(find.text(phone), findsOneWidget, reason: 'a chip with the other copy by device and instance');
    expect(find.bySemanticsLabel(RegExp('1 peer connected: ${RegExp.escape(phone)}')), findsOneWidget);
    expect(find.byKey(const ValueKey('peers-connecting')), findsNothing);

    await b.close();
    await _until(t, () => find.text('Peers: 0').evaluate().isNotEmpty, what: 'copy B to leave');
    expect(find.text(phone), findsNothing);
    expect(find.bySemanticsLabel(RegExp('No peers connected')), findsOneWidget);
    sem.dispose();
    await a.close();
  });

  testWidgets('a copy that is found but not yet admitted counts as "connecting", not as a peer', (t) async {
    final net = (await t.runAsync(() async => FakePeerNetwork()))!;
    final a = await testAppContext(t, manifest: _manifest, env: {'APP_CONTEXT_DEVICE': 'laptop'});
    final b = await testAppContext(t, manifest: _manifest, env: {'APP_CONTEXT_DEVICE': 'phone'});
    final gate = Completer<void>();
    final ha = await _start(t, a, _Hook(gate: gate.future), network: net);
    await _start(t, b, _Hook(), network: net);
    await t.pumpWidget(_host(PeersIndicator.forHandle(ha)));
    await _until(t, () => find.byKey(const ValueKey('peers-connecting')).evaluate().isNotEmpty, what: 'the connecting count');
    expect(find.text('(1 connecting)'), findsOneWidget);
    expect(find.text('Peers: 0'), findsOneWidget);
    gate.complete();
    await _until(t, () => find.text('Peers: 1').evaluate().isNotEmpty, what: 'the peer to become ready');
    expect(find.byKey(const ValueKey('peers-connecting')), findsNothing);
    await b.close();
    await a.close();
  });

  testWidgets('given a hub directly it follows that hub; swapping the hub for a handle re-subscribes', (t) async {
    final net = (await t.runAsync(() async => FakePeerNetwork()))!;
    final a = await testAppContext(t, manifest: _manifest, env: {'APP_CONTEXT_DEVICE': 'laptop'});
    final b = await testAppContext(t, manifest: _manifest, env: {'APP_CONTEXT_DEVICE': 'phone'});
    final hubA = (await t.runAsync(() async => a.ctx.peerHub(_Hook(), network: net)))!;
    await t.runAsync(hubA.start);
    await t.pumpWidget(_host(PeersIndicator(hub: hubA)));
    expect(find.text('Peers: 0'), findsOneWidget);
    final hb = await _start(t, b, _Hook(), network: net);
    await _until(t, () => find.text('Peers: 1').evaluate().isNotEmpty, what: 'the peer, seen through a bare hub');

    await t.pumpWidget(_host(PeersIndicator.forHandle(hb)));
    await _until(t, () => find.text('Peers: 1').evaluate().isNotEmpty, what: 'B seeing A through its handle');
    await a.close();
    await _until(t, () => find.text('Peers: 0').evaluate().isNotEmpty, what: 'A to leave, seen by the swapped-in handle');
    await b.close();
  });

  testWidgets('a hub that was closed reads as off, not as a stale count', (t) async {
    final net = (await t.runAsync(() async => FakePeerNetwork()))!;
    final a = await testAppContext(t, manifest: _manifest);
    final hub = (await t.runAsync(() async => a.ctx.peerHub(_Hook(), network: net)))!;
    await t.runAsync(hub.start);
    await t.pumpWidget(_host(PeersIndicator(hub: hub, offlineReason: 'closed')));
    await t.runAsync(hub.close);
    await t.pumpWidget(_host(PeersIndicator(hub: hub, offlineReason: 'closed')));
    expect(find.text('Peers: off (closed)'), findsOneWidget);
    await a.close();
  });
}
