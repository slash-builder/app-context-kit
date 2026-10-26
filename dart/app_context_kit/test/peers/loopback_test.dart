// The loopback provider over real 127.0.0.1 sockets and a real temp directory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_context_kit/src/peers/peers.dart';
import 'package:test/test.dart';

import 'support.dart';

Future<void> until(bool Function() cond, {String? why, Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for ${why ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Fixed implements Backoff {
  _Fixed(this.ms);
  final List<int> ms;
  @override
  Duration? delay(int attempt) => attempt < ms.length ? Duration(milliseconds: ms[attempt]) : null;
}

void main() {
  late Directory tmp;
  final hubs = <PeerHub>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app-context-peers-');
  });

  tearDown(() async {
    for (final h in hubs) {
      await h.close();
    }
    hubs.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  LoopbackProvider provider() => LoopbackProvider(directory: tmp.path, pollInterval: const Duration(milliseconds: 25));

  Node node(
    String device, {
    String instance = 'i1',
    String account = 'acct-1',
    String app = 'com.slashbuilder.demo.app',
    RecordingHook? hook,
    PeerHubOptions options = const PeerHubOptions(),
    PeerAuthenticator? auth,
    LoopbackProvider? withProvider,
  }) {
    final h = hook ?? RecordingHook();
    final hub = PeerHub(
        account: account, app: app, device: device, instance: instance, provider: withProvider ?? provider(), hook: h, options: options, authenticator: auth);
    hubs.add(hub);
    return Node(hub, h);
  }

  Future<Node> started(String device,
      {String instance = 'i1', String account = 'acct-1', String app = 'com.slashbuilder.demo.app', RecordingHook? hook, PeerHubOptions options = const PeerHubOptions()}) async {
    final n = node(device, instance: instance, account: account, app: app, hook: hook, options: options);
    await n.hub.start();
    return n;
  }

  group('frames', () {
    test('round trip, one byte at a time and several frames per chunk', () {
      final f1 = bytes('first');
      final f2 = Uint8List.fromList(List.generate(1000, (i) => i % 251));
      final wire = BytesBuilder()
        ..add(FrameDecoder.encode(f1))
        ..add(FrameDecoder.encode(f2))
        ..add(FrameDecoder.encode(f1));
      final all = wire.toBytes();

      final slow = FrameDecoder();
      final got = <Uint8List>[];
      for (final b in all) {
        got.addAll(slow.add([b]));
      }
      expect(got, [f1, f2, f1]);

      final fast = FrameDecoder();
      expect(fast.add(all), [f1, f2, f1]);
      expect(FrameDecoder().add(all.sublist(0, 3)), isEmpty);
    });

    test('zero-length and oversize frames are refused before any allocation', () {
      expect(() => FrameDecoder().add([0, 0, 0, 0]), throwsFormatException);
      expect(() => FrameDecoder(maxFrame: 10).add([0, 0, 0, 11]), throwsFormatException);
      expect(() => FrameDecoder().add([0xff, 0xff, 0xff, 0xff]), throwsFormatException);
      expect(FrameDecoder(maxFrame: 10).add([0, 0, 0, 1, 7]).single, [7]);
    });
  });

  group('two hubs over real sockets', () {
    test('discover through files, connect over 127.0.0.1, exchange hellos, messages and a request', () async {
      late Node b;
      final a = await started('a', hook: RecordingHook(helloValue: {'who': 'a'}));
      b = await started('b', hook: RecordingHook(
        helloValue: {'who': 'b'},
        onMessageFn: (from, m) {
          if (m.requestId != null) unawaited(b.hub.reply(m, bytes('echo:${text(m.payload)}')));
        },
      ));
      await until(() => a.hook.count('ready') == 1 && b.hook.count('ready') == 1, why: 'both ready');

      expect(a.hub.peers.single.hello, {'who': 'b'});
      expect(b.hub.peers.single.hello, {'who': 'a'});

      final f = File('${tmp.path}/acct-1/com.slashbuilder.demo.app/a@i1.json');
      expect(f.existsSync(), isTrue);
      final j = jsonDecode(f.readAsStringSync()) as Map;
      expect(j['port'], isA<int>());
      expect(j['port'], greaterThan(0));
      expect(Directory('${tmp.path}/acct-1/com.slashbuilder.demo.app').listSync().map((e) => e.uri.pathSegments.last).toSet(), {'a@i1.json', 'b@i1.json'});

      await a.hub.send(a.hub.peers.single, bytes('over tcp'), kind: 'note', schema: 2);
      await until(() => b.hook.messages.isNotEmpty);
      expect(b.hook.texts, ['over tcp']);
      expect(b.hook.messages.single.schema, 2);

      final reply = await a.hub.request(a.hub.peers.single, bytes('ping'), timeout: const Duration(seconds: 5));
      expect(text(reply.payload), 'echo:ping');

      final r = await b.hub.broadcast(bytes('from b'));
      expect(r.sent, [a.hub.id]);
      await until(() => a.hook.messages.isNotEmpty);
      expect(a.hook.texts, ['from b']);
    });

    test('many messages arrive once and in order, and a full 1 MiB payload survives', () async {
      final a = await started('a');
      final b = await started('b');
      await until(() => a.hook.count('ready') == 1 && b.hook.count('ready') == 1);
      final p = a.hub.peers.single;
      // The outbox is bounded (256), so a producer awaits in batches instead of firing 300 at once.
      for (var base = 0; base < 300; base += 100) {
        await Future.wait([for (var i = base; i < base + 100; i++) a.hub.send(p, bytes('m$i'))]);
      }
      final big = Uint8List.fromList(List.generate(Envelope.maxPayloadBytes, (i) => (i * 7) & 0xff));
      await a.hub.send(p, big, kind: 'big');
      await until(() => b.hook.messages.length == 301, why: '301 messages');
      expect(b.hook.messages.take(300).map((m) => text(m.payload)), [for (var i = 0; i < 300; i++) 'm$i']);
      expect(b.hook.messages.last.payload, big);
      expect(b.hub.stats.gapsSkipped, 0);
    });

    test('close says goodbye, removes the announcement, and a new copy with the same ids is found again', () async {
      final a = await started('a');
      final b = await started('b');
      await until(() => a.hook.count('ready') == 1);
      final bFile = File('${tmp.path}/acct-1/com.slashbuilder.demo.app/b@i1.json');
      expect(bFile.existsSync(), isTrue);

      await b.hub.close();
      await until(() => a.hook.count('lost') == 1, why: 'a sees b go');
      expect(a.hook.changes.last.$1.lostReason, 'goodbye');
      expect(bFile.existsSync(), isFalse);
      expect(a.hub.peers, isEmpty);

      final b2 = await started('b');
      await until(() => a.hook.count('ready') == 2 && b2.hook.count('ready') == 1, why: 'b came back');
      expect(a.hub.peers.single.state, PeerState.ready);
    });

    test('a crashed copy (sockets die, announcement stays) is lost without a goodbye; redial gives up on the ghost', () async {
      final a = await started('a', options: PeerHubOptions(backoff: _Fixed([20, 20])));
      final bProvider = provider();
      final b = node('b', withProvider: bProvider);
      await b.hub.start();
      await until(() => a.hook.count('ready') == 1);
      final bFile = File('${tmp.path}/acct-1/com.slashbuilder.demo.app/b@i1.json');
      final announcement = bFile.readAsStringSync();

      await bProvider.close(); // abrupt: no kit.bye, sockets destroyed
      bFile.writeAsStringSync(announcement); // the file a crash would leave behind
      await until(() => a.hook.count('lost') == 1, why: 'a notices');
      expect(a.hook.changes.firstWhere((c) => c.$2 == PeerChange.lost).$1.lostReason, 'link closed');

      await until(() => a.hub.stats.dialFailures >= 2, why: 'redials against the ghost');
      final failures = a.hub.stats.dialFailures;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(a.hub.stats.dialFailures, failures, reason: 'gave up after the schedule');
      expect(a.hub.peers.single.state, PeerState.found, reason: 'still advertised, so still known');
    });

    test('a ghost announcement that was never alive is dialed a few times and then left alone', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      final a = await started('a', options: PeerHubOptions(backoff: _Fixed([10, 10])));
      File('${tmp.path}/acct-1/com.slashbuilder.demo.app/zz@gone.json').writeAsStringSync(jsonEncode({'port': port}));
      await until(() => a.hub.stats.dialFailures >= 3, why: 'three failed dials');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(a.hub.stats.dialFailures, 3);
      expect(a.hook.events, ['found zz@gone']);
    });
  });

  group('scope', () {
    test('another app or account in the same directory root is never offered, connected or sent to', () async {
      final a = await started('a');
      final b = await started('b');
      final otherApp = await started('c', app: 'com.slashbuilder.demo.other');
      final otherAcct = await started('d', account: 'acct-2');
      await until(() => a.hook.count('ready') == 1 && b.hook.count('ready') == 1);
      await Future<void>.delayed(const Duration(milliseconds: 150)); // several poll cycles

      expect(otherApp.hub.peers, isEmpty);
      expect(otherAcct.hub.peers, isEmpty);
      expect(a.hub.peers.map((p) => p.id.device), ['b']);

      await a.hub.broadcast(bytes('app-A only'));
      await until(() => b.hook.messages.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(otherApp.hook.messages, isEmpty);
      expect(otherAcct.hook.messages, isEmpty);
      expect(otherApp.hook.events, isEmpty);
      expect(otherAcct.hook.events, isEmpty);

      // The directory layout itself is the first fence.
      for (final d in ['acct-1/com.slashbuilder.demo.app', 'acct-1/com.slashbuilder.demo.other', 'acct-2/com.slashbuilder.demo.app']) {
        expect(Directory('${tmp.path}/$d').existsSync(), isTrue, reason: d);
      }
    });

    test('a raw socket with another scope\'s preface is dropped before the hub hears of it', () async {
      final a = await started('a');
      final port = (jsonDecode(File('${tmp.path}/acct-1/com.slashbuilder.demo.app/a@i1.json').readAsStringSync()) as Map)['port'] as int;

      Future<void> expectClosed(Uint8List firstBytes) async {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
        s.add(firstBytes);
        await s.flush();
        await s.drain<void>().timeout(const Duration(seconds: 3));
        s.destroy();
      }

      Uint8List framed(Object preface) => FrameDecoder.encode(bytes(jsonEncode(preface)));

      await expectClosed(framed({'account': 'acct-1', 'app': 'com.slashbuilder.demo.other', 'device': 'x', 'instance': 'i'}));
      await expectClosed(framed({'account': 'acct-2', 'app': 'com.slashbuilder.demo.app', 'device': 'x', 'instance': 'i'}));
      await expectClosed(framed({'nonsense': true}));
      await expectClosed(framed({'account': 'acct-1', 'app': 'com.slashbuilder.demo.app', 'device': 'a', 'instance': 'i1'})); // claims to be us
      await expectClosed(Uint8List.fromList([0xff, 0xff, 0xff, 0xff, 1, 2, 3])); // absurd length
      await expectClosed(Uint8List.fromList(utf8.encode('GET / HTTP/1.1\r\n\r\n')));
      expect(a.hook.events, isEmpty);
      expect(a.hub.peers, isEmpty);
    });

    test('a provider refuses to dial a candidate from another scope', () async {
      final p = provider();
      await p.open(const PeerIdentity('acct-1', 'com.slashbuilder.demo.app', PeerId('a', 'i1')));
      await expectLater(p.connect(const PeerCandidate(PeerIdentity('acct-1', 'com.slashbuilder.demo.other', PeerId('x', 'i')), '1234')), throwsA(isA<PeerScopeError>()));
      await expectLater(p.connect(const PeerCandidate(PeerIdentity('acct-2', 'com.slashbuilder.demo.app', PeerId('x', 'i')), '1234')), throwsA(isA<PeerScopeError>()));
      await p.close();
    });

    test('a file in the right folder that names another scope inside is ignored', () async {
      final a = await started('a');
      final dir = Directory('${tmp.path}/acct-1/com.slashbuilder.demo.app');
      File('${dir.path}/liar@i1.json').writeAsStringSync(jsonEncode({'account': 'acct-2', 'app': 'com.slashbuilder.demo.app', 'port': 9}));
      File('${dir.path}/liar2@i1.json').writeAsStringSync(jsonEncode({'account': 'acct-1', 'app': 'com.slashbuilder.demo.other', 'port': 9}));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(a.hub.peers, isEmpty);
      expect(a.hook.events, isEmpty);
    });
  });

  group('robustness', () {
    test('identifiers that would escape the directory are refused, not written', () async {
      for (final bad in ['../evil', 'a/b', '..', '.hidden', 'x@y', '']) {
        final p = provider();
        await expectLater(p.open(PeerIdentity(bad, 'com.slashbuilder.demo.app', const PeerId('a', 'i1'))), throwsArgumentError, reason: 'account "$bad"');
        final p2 = provider();
        await expectLater(p2.open(PeerIdentity('acct-1', bad, const PeerId('a', 'i1'))), throwsArgumentError, reason: 'app "$bad"');
        final p3 = provider();
        await expectLater(p3.open(PeerIdentity('acct-1', 'com.slashbuilder.demo.app', PeerId(bad, 'i1'))), throwsArgumentError, reason: 'device "$bad"');
      }
      expect(tmp.listSync(), isEmpty, reason: 'nothing was created');
    });

    test('junk, unreadable and oversized files in the directory are skipped', () async {
      final a = await started('a');
      final dir = Directory('${tmp.path}/acct-1/com.slashbuilder.demo.app');
      File('${dir.path}/junk@i1.json').writeAsStringSync('not json');
      File('${dir.path}/array@i1.json').writeAsStringSync('[1]');
      File('${dir.path}/noport@i1.json').writeAsStringSync('{}');
      File('${dir.path}/badport@i1.json').writeAsStringSync('{"port": 99999}');
      File('${dir.path}/big@i1.json').writeAsStringSync('{"port": 5, "pad": "${'x' * 5000}"}');
      File('${dir.path}/notes.txt').writeAsStringSync('hi');
      Directory('${dir.path}/subdir@i1.json').createSync();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(a.hub.peers, isEmpty);
      expect(a.hook.events, isEmpty);
    });

    test('two copies on one device (different instances) are two peers', () async {
      final one = await started('mac', instance: 'i1');
      final two = await started('mac', instance: 'i2');
      await until(() => one.hook.count('ready') == 1 && two.hook.count('ready') == 1);
      expect(one.hub.peers.single.id, const PeerId('mac', 'i2'));
    });

    test('close cleans up: files removed, sockets closed, and it is safe to close twice', () async {
      final a = await started('a');
      final dir = Directory('${tmp.path}/acct-1/com.slashbuilder.demo.app');
      expect(dir.listSync().whereType<File>().map((f) => f.path), isNotEmpty);
      await a.hub.close();
      await a.hub.close();
      expect(dir.listSync().whereType<File>(), isEmpty);
      expect(dir.listSync().any((e) => e.path.endsWith('.tmp')), isFalse);
    });

    test('shared-secret authentication works over the loopback transport', () async {
      final a = node('a', auth: SharedSecretAuthenticator('k'));
      final b = node('b', auth: SharedSecretAuthenticator('k'));
      final c = node('c', auth: SharedSecretAuthenticator('other'));
      for (final n in [a, b, c]) {
        await n.hub.start();
      }
      await until(() => a.hook.count('ready') == 1 && b.hook.count('ready') == 1);
      await until(() => c.hook.count('lost') == 2, why: 'c refused by both');
      expect(c.hook.count('ready'), 0);
      expect(a.hub.readyPeers.map((p) => p.id.device), ['b']);
    });
  });
}
