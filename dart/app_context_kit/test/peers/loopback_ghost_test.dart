// Ghost announcements (the file a crashed copy leaves behind) and the loopback provider's heartbeat, in one process with
// real sockets and a real directory. The same thing with real processes and kill -9 is in two_process_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

void main() {
  late Directory tmp;
  final hubs = <PeerHub>[];
  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-ghost-'));
  tearDown(() async {
    for (final h in hubs) {
      await h.close();
    }
    hubs.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // Fast settings: a beat every 50 ms, a file is a ghost after 300 ms and reaped after 2 s.
  LoopbackProvider provider({Duration reapAfter = const Duration(seconds: 2)}) => LoopbackProvider(
      directory: tmp.path,
      pollInterval: const Duration(milliseconds: 25),
      announceEvery: const Duration(milliseconds: 50),
      staleAfter: const Duration(milliseconds: 300),
      reapAfter: reapAfter);

  Future<(PeerHub, RecordingHook, LoopbackProvider)> started(String device,
      {String instance = 'i1', PeerHubOptions options = const PeerHubOptions()}) async {
    final p = provider();
    final hook = RecordingHook();
    final hub =
        PeerHub(account: 'acct', app: 'com.slashbuilder.demo.app', device: device, instance: instance, provider: p, hook: hook, options: options);
    hubs.add(hub);
    await hub.start();
    return (hub, hook, p);
  }

  int ago(Duration d) => DateTime.now().subtract(d).millisecondsSinceEpoch;
  Directory scope() => Directory('${tmp.path}/acct/com.slashbuilder.demo.app');
  File fileOf(String name) => File('${scope().path}/$name.json');

  test('a live copy keeps beating in its announcement, so it is never taken for a ghost', () async {
    final a = await started('a');
    final b = await started('b');
    await until(() => a.$2.count('ready') == 1);
    int beat() => (jsonDecode(fileOf('b@i1').readAsStringSync()) as Map)['beat'] as int;
    final first = beat();
    // Well past staleAfter (300 ms): still connected, still listed, and the file's beat is fresh.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(beat(), greaterThan(first), reason: 'the heartbeat did not rewrite the file');
    expect(DateTime.now().millisecondsSinceEpoch - beat(), lessThan(300));
    expect(a.$1.peers.single.state, PeerState.ready);
    expect(b.$1.peers.single.state, PeerState.ready);
    expect(a.$2.count('lost'), 0);
  });

  test('an announcement nobody beats in any more (a crashed copy) is withdrawn from a hub that knew it, and dialing stops', () async {
    final a = await started('a',
        options: const PeerHubOptions(backoff: ExponentialBackoff(initial: Duration(milliseconds: 20), maxAttempts: 100)));
    final b = await started('b');
    await until(() => a.$2.count('ready') == 1);
    final content = fileOf('b@i1').readAsStringSync();
    await b.$3.close(); // abrupt: no goodbye
    fileOf('b@i1').writeAsStringSync(content); // what a crash leaves behind, with nobody refreshing it
    await until(() => a.$2.count('lost') == 1, why: 'a notices the sockets die');
    // The ghost looks advertised for a moment, then its age passes staleAfter and it is withdrawn: a final `lost`.
    await until(() => a.$1.peers.isEmpty, why: 'the ghost to be dropped');
    expect(a.$2.changes.last.$2, PeerChange.lost);
    expect(a.$2.changes.last.$1.lostReason, 'withdrawn');
    final failures = a.$1.stats.dialFailures;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(a.$1.stats.dialFailures, failures, reason: 'redial storm: still dialing a withdrawn ghost');
  });

  test('a ghost that is already stale when a hub starts is never offered', () async {
    scope().createSync(recursive: true);
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();
    fileOf('zz@old').writeAsStringSync(jsonEncode({'port': port, 'pid': 1, 'beat': ago(const Duration(seconds: 1))}));
    // A file without a beat (a hand-made ghost, an older writer) is aged by its modification time instead.
    fileOf('yy@nobeat')
      ..writeAsStringSync(jsonEncode({'port': port}))
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
    final a = await started('a');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(a.$2.events, isEmpty, reason: 'a stale file was offered');
    expect(a.$1.stats.dialFailures, 0);
  });

  test('a ghost that has been dead for reapAfter is deleted, a recent one is left alone', () async {
    scope().createSync(recursive: true);
    final old = fileOf('zz@old')..writeAsStringSync(jsonEncode({'port': 9, 'beat': ago(const Duration(seconds: 30))}));
    final recent = fileOf('yy@recent')..writeAsStringSync(jsonEncode({'port': 9, 'beat': ago(const Duration(seconds: 1))}));
    await started('a');
    await until(() => !old.existsSync(), why: 'the old ghost to be reaped');
    expect(recent.existsSync(), isTrue, reason: 'stale but not yet reapAfter old');
  });

  test('a copy that was paused past staleAfter and then resumes comes back (it rewrites its file if it was reaped)', () async {
    final a = await started('a');
    final scopeProvider = provider(reapAfter: const Duration(milliseconds: 400));
    final hook = RecordingHook();
    final b = PeerHub(account: 'acct', app: 'com.slashbuilder.demo.app', device: 'b', instance: 'i1', provider: scopeProvider, hook: hook);
    hubs.add(b);
    await b.start();
    await until(() => a.$2.count('ready') == 1);
    // Someone reaps b's file while b is "paused".
    fileOf('b@i1').deleteSync();
    await until(() => a.$2.count('lost') >= 1 || a.$1.peers.isNotEmpty, why: 'a to react');
    // b's next beat writes the announcement again, so it stays or becomes listed and connected.
    await until(() => fileOf('b@i1').existsSync(), why: 'the file to be written again');
    await until(() => a.$1.peers.any((p) => p.state == PeerState.ready), why: 'b ready again');
  });

  test('close withdraws the announcement and stops the beat', () async {
    final a = await started('a');
    expect(fileOf('a@i1').existsSync(), isTrue);
    await a.$1.close();
    expect(fileOf('a@i1').existsSync(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(fileOf('a@i1').existsSync(), isFalse, reason: 'a late beat re-created the file after close');
  });
}
