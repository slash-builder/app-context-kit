// Behaviour that depends on the real operating system, not on the `platform:` the other tests pass in. Written because
// the other tests only ever ran on macOS (see docs/PLATFORMS.md); tools/linux-test.sh runs it in a Linux container.
// Each test checks what the OS convention says for the host it runs on.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

AppManifest manifest() => AppManifest.fromJson({
      'id': 'com.slashbuilder.demo.calc',
      'name': 'Calc',
      'version': '0.1.0',
      'venue': {'mode': 'off'}
    });

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-host-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  bool isRoot() => !Platform.isWindows && Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

  test('the host platform is what the OS says', () {
    expect(AppContext.hostPlatform(), Platform.isLinux ? 'linux' : (Platform.isMacOS ? 'macos' : 'windows'));
  });

  test('open on the real host (no platform override, no scratch) puts the directories where the OS convention says', () async {
    final home = '${tmp.path}/home';
    final xdg = {
      'XDG_DATA_HOME': '${tmp.path}/xdg/data',
      'XDG_CONFIG_HOME': '${tmp.path}/xdg/config',
      'XDG_STATE_HOME': '${tmp.path}/xdg/state',
      'XDG_CACHE_HOME': '${tmp.path}/xdg/cache',
      'XDG_RUNTIME_DIR': '${tmp.path}/xdg/run',
    };
    final ctx = await AppContext.open(manifest(), env: {'HOME': home, ...xdg}, announce: false);
    addTearDown(ctx.close);
    final d = ctx.dirs;
    if (Platform.isLinux) {
      expect(d.data, '${xdg['XDG_DATA_HOME']}/com.slashbuilder.demo.calc');
      expect(d.config, '${xdg['XDG_CONFIG_HOME']}/com.slashbuilder.demo.calc');
      expect(d.state, '${xdg['XDG_STATE_HOME']}/com.slashbuilder.demo.calc');
      expect(d.cache, '${xdg['XDG_CACHE_HOME']}/com.slashbuilder.demo.calc');
      expect(d.runtime, '${xdg['XDG_RUNTIME_DIR']}/com.slashbuilder.demo.calc');
      expect(ctx.resolved.roster, '${xdg['XDG_RUNTIME_DIR']}/app-context-roster');
    } else if (Platform.isMacOS) {
      expect(d.data, startsWith('$home/Library/'));
      expect(d.config, startsWith('$home/Library/'));
    }
    for (final dir in [d.data, d.config, d.state, d.cache, d.runtime]) {
      expect(Directory(dir).existsSync(), isTrue, reason: dir);
    }
  });

  test('without XDG variables, Linux falls back to the home-relative defaults (and the roster to /tmp)', () async {
    final home = '${tmp.path}/home';
    final ctx = await AppContext.open(manifest(), env: {'HOME': home}, announce: false);
    addTearDown(ctx.close);
    if (Platform.isLinux) {
      expect(ctx.dirs.data, '$home/.local/share/com.slashbuilder.demo.calc');
      expect(ctx.dirs.config, '$home/.config/com.slashbuilder.demo.calc');
      expect(ctx.dirs.state, '$home/.local/state/com.slashbuilder.demo.calc');
      expect(ctx.dirs.cache, '$home/.cache/com.slashbuilder.demo.calc');
      expect(ctx.dirs.runtime, '$home/.local/state/com.slashbuilder.demo.calc/run');
      expect(ctx.resolved.roster, '/tmp/app-context-roster');
    }
  }, skip: Platform.isLinux ? null : 'the XDG fallbacks are Linux behaviour (macOS uses ~/Library)');

  test('the default 5 s heartbeat really ticks: the presence file is rewritten, and stays live', () async {
    final roster = Roster('${tmp.path}/roster');
    final ann = await roster.announce(id: 'com.slashbuilder.demo.calc', name: 'Calc', version: '0.1.0'); // default `every`: 5 s
    addTearDown(ann.withdraw);
    DateTime beat() => DateTime.parse((jsonDecode(File(ann.path).readAsStringSync()) as Map)['heartbeatAt'] as String);
    final first = beat();
    await Future<void>.delayed(const Duration(milliseconds: 5600));
    final second = beat();
    expect(second.isAfter(first), isTrue, reason: 'heartbeat did not advance: $first then $second');
    expect(second.difference(first), lessThan(const Duration(seconds: 7)));
    expect(roster.running().map((e) => e.id), ['com.slashbuilder.demo.calc']);
  });

  test('a token file the user cannot read is a clear problem (skipped as root, which reads anything)', () {
    final f = File('${tmp.path}/token')..writeAsStringSync('secret');
    Process.runSync('chmod', ['000', f.path]);
    addTearDown(() => Process.runSync('chmod', ['600', f.path]));
    final r = AppContext.lookupVenueToken({'VENUE_TOKEN_FILE': f.path}, '${tmp.path}/cfg');
    expect(r.token, isNull);
    expect(r.problem, contains('cannot be read'));
  }, skip: isRoot() ? 'running as root: file mode bits do not apply' : null);

  test('a config write is a rename: a reader in another isolate never sees a partial file', () async {
    final dir = Directory('${tmp.path}/cfg')..createSync();
    final store = ConfigStore.open(dir);
    store.set('n', 0);
    final path = store.file.path;
    final port = ReceivePort();
    // The reader polls the file for 2 s in a tight loop; this isolate rewrites it for 1.8 s.
    await Isolate.spawn((List<Object> a) {
      var reads = 0, bad = 0;
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < 2000) {
        try {
          jsonDecode(File(a[1] as String).readAsStringSync());
        } catch (_) {
          bad++;
        }
        reads++;
      }
      (a[0] as SendPort).send([reads, bad]);
    }, [port.sendPort, path]);
    final done = port.first;
    var writes = 0;
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 1800) {
      store.set('n', ++writes);
    }
    final result = (await done) as List;
    expect(result[1], 0, reason: '${result[1]} of ${result[0]} reads saw a half-written config.json');
    expect(result[0], greaterThan(0));
    expect(writes, greaterThan(100), reason: 'the writer must have actually written a lot');
  });
}
