// The loopback provider: two copies on one machine, finding each other through a directory of announcement files.
import 'dart:convert';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:coordination_examples/ping_hook.dart';
import 'package:test/test.dart';

const manifestJson = {
  'id': 'dev.example.ping',
  'name': 'Ping',
  'version': '0.1.0',
  'kits': ['peers'],
  'venue': {'mode': 'off'},
};

Future<bool> until(bool Function() ok, {Duration within = const Duration(seconds: 8)}) async {
  final end = DateTime.now().add(within);
  while (DateTime.now().isBefore(end)) {
    if (ok()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return ok();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('loopback-example-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<(AppContext, PingHook, PeersHandle)> copy(String device) async {
    final ctx = await AppContext.open(
      AppManifest.fromJson(manifestJson),
      env: {
        'APP_CONTEXT_SCRATCH': '${tmp.path}/scratch-$device',
        'APP_CONTEXT_PEERS_DIR': '${tmp.path}/peers',
        'APP_CONTEXT_DEVICE': device,
      },
      platform: 'linux',
      home: '/unused',
      announce: false,
    );
    final hook = PingHook();
    final handle = ctx.startPeers(hook); // real mode, no network passed: the loopback provider
    await handle.started;
    return (ctx, hook, handle);
  }

  File announcementOf(String device) {
    final dir = Directory('${tmp.path}/peers/local/dev.example.ping');
    return dir.listSync().whereType<File>().singleWhere((f) => f.uri.pathSegments.last.startsWith('$device@'));
  }

  test('announcement file: path, fields, ping over TCP, and the file is removed on a clean close', () async {
    final a = await copy('laptop');
    final b = await copy('desktop');
    expect(await until(() => a.$3.hub!.readyPeers.isNotEmpty && b.$3.hub!.readyPeers.isNotEmpty), isTrue);
    expect(await a.$2.ping(a.$3.hub!.readyPeers.single), 'desktop');

    final file = announcementOf('laptop');
    // <peers dir>/<account>/<app id>/<device>@<instance>.json, account "local" because nothing set one.
    expect(file.path, '${tmp.path}/peers/local/dev.example.ping/laptop@${a.$1.instance}.json');
    final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(j.keys.toSet(), {'account', 'app', 'device', 'instance', 'port', 'pid', 'beat'});
    expect(j['port'], isA<int>());
    expect(j['pid'], pid);

    await a.$1.close();
    expect(() => announcementOf('laptop'), throwsStateError, reason: 'the file is deleted on a clean close');
    expect(await until(() => b.$2.events.contains('lost laptop')), isTrue);
    expect(b.$3.hub!.peers, isEmpty);
    await b.$1.close();
  });

  test('a leftover file whose beat is older than 4 seconds is not offered', () async {
    final dir = Directory('${tmp.path}/peers/local/dev.example.ping')..createSync(recursive: true);
    final stale = DateTime.now().subtract(const Duration(seconds: 10)).millisecondsSinceEpoch;
    File('${dir.path}/ghost@deadbeef.json').writeAsStringSync(jsonEncode({
      'account': 'local', 'app': 'dev.example.ping', 'device': 'ghost', 'instance': 'deadbeef', 'port': 9, 'pid': 1, 'beat': stale,
    }));
    final a = await copy('laptop');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(a.$3.hub!.peers, isEmpty);
    expect(a.$3.hub!.stats.dialFailures, 0);
    await a.$1.close();
  });

  test('another app id or account writes to another directory and is never listed', () async {
    final a = await copy('laptop');
    final other = Directory('${tmp.path}/peers/local/dev.example.other')..createSync(recursive: true);
    File('${other.path}/x@1.json').writeAsStringSync(jsonEncode({
      'account': 'local', 'app': 'dev.example.other', 'device': 'x', 'instance': '1', 'port': 9, 'pid': 1,
      'beat': DateTime.now().millisecondsSinceEpoch,
    }));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(a.$3.hub!.peers, isEmpty);
    await a.$1.close();
  });
}
