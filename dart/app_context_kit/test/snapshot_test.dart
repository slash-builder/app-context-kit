import 'dart:convert';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

// Spec section 8. `AppContext.snapshot()` and the committed fixture `spec/conformance/snapshot_cases.json` that the Rust
// crate adopts case by case (rust/tests/snapshot_conformance.rs).
//
// The fixture is written by THIS file, not by hand: `SNAPSHOT_FIXTURE_WRITE=1 dart test test/snapshot_test.dart`. A plain
// run does not touch it (the instance ids of real contexts are random, so rewriting on every run would dirty the tree);
// it checks that the committed file still says what the code produces.

const fixturePath = '../../spec/conformance/snapshot_cases.json';
const root = '/tmp/app-context-snapshot-fixture';

AppManifest manifest() => AppManifest.fromJson({'id': 'com.slashbuilder.demo.notes-rust', 'name': 'Notes', 'version': '0.1.0'});

class Case {
  Case(this.name, this.platform, this.home, this.env, {this.fixedInstance});
  final String name, platform, home;
  final Map<String, String> env;

  /// Null: open a real context and take its random instance id. Non-null: the host cannot open this shape (Windows paths
  /// would become odd directory names on macOS and Linux), so the snapshot is built by the same function over resolve().
  final String? fixedInstance;
}

final cases = <Case>[
  Case('linux-xdg', 'linux', '$root/home-linux', {'XDG_RUNTIME_DIR': '$root/run-linux'}),
  Case('macos', 'macos', '$root/home-macos', {'TMPDIR': '$root/tmp-macos'}),
  Case('windows-shaped', 'windows', r'C:\Users\alice', {
    'LOCALAPPDATA': r'C:\Users\alice\AppData\Local',
    'APPDATA': r'C:\Users\alice\AppData\Roaming',
    'TEMP': r'C:\Users\alice\AppData\Local\Temp',
  }, fixedInstance: 'c0ffee01'),
  Case('mock', 'linux', '$root/home-mock', {'APP_CONTEXT_MODE': 'mock', 'XDG_RUNTIME_DIR': '$root/run-mock'}),
  Case('scratch', 'linux', '/nonexistent', {'APP_CONTEXT_SCRATCH': '$root/scratch'}),
  Case('scratch-with-dir-override', 'linux', '/nonexistent',
      {'APP_CONTEXT_SCRATCH': '$root/scratch2', 'NOTES_RUST_DATA_DIR': '$root/elsewhere/data'}),
];

Future<Map<String, Object?>> produce(Case c) async {
  if (c.fixedInstance != null) {
    final r = resolve(manifest: manifest(), platform: c.platform, home: c.home, env: c.env);
    return contextSnapshot(appId: manifest().id, instance: c.fixedInstance!, resolved: r);
  }
  final ctx = await AppContext.open(manifest(), env: c.env, platform: c.platform, home: c.home);
  try {
    return ctx.snapshot();
  } finally {
    await ctx.close();
  }
}

void main() {
  tearDownAll(() {
    final d = Directory(root);
    if (d.existsSync()) d.deleteSync(recursive: true);
  });

  test('the snapshot has the documented shape and no secrets', () async {
    final ctx = await AppContext.open(manifest(),
        env: {'APP_CONTEXT_SCRATCH': '$root/shape', 'VENUE_TOKEN': 'sekrit-token'}, platform: 'linux', home: '/x');
    final s = ctx.snapshot();
    expect(s.keys.toList(), ['schema', 'appId', 'instance', 'mode', 'scratch', 'dirs', 'roster']);
    expect(s['schema'], 1);
    expect(s['appId'], 'com.slashbuilder.demo.notes-rust');
    expect(s['instance'], ctx.instance);
    expect(s['instance'], matches(RegExp(r'^[0-9a-f]{8}$')));
    expect(s['mode'], 'real');
    expect(s['scratch'], true);
    expect((s['dirs'] as Map).keys.toList(), ['data', 'config', 'state', 'cache', 'runtime']);
    expect(s['dirs'], {
      'data': ctx.dirs.data, 'config': ctx.dirs.config, 'state': ctx.dirs.state, 'cache': ctx.dirs.cache, 'runtime': ctx.dirs.runtime,
    });
    expect(s['roster'], ctx.resolved.roster);
    // JSON-able, a copy, and without the environment
    final text = jsonEncode(s);
    expect(jsonDecode(text), s);
    expect(text, isNot(contains('sekrit-token')));
    // asking changes nothing: the roster has this one entry, and a second snapshot is identical
    expect(ctx.roster.running().length, 1);
    expect(ctx.snapshot(), s);
    await ctx.close();
  });

  test('a relative scratch directory is made absolute so the Rust side can be strict', () async {
    final ctx = await AppContext.open(manifest(),
        env: {'APP_CONTEXT_SCRATCH': 'relative-scratch-for-snapshot-test'}, platform: 'linux', home: '/x', announce: false);
    try {
      final dirs = (ctx.snapshot()['dirs'] as Map).values.cast<String>();
      for (final d in dirs) {
        expect(d, startsWith('/'));
      }
      expect(ctx.snapshot()['roster'], startsWith('/'));
    } finally {
      await ctx.close();
      Directory('relative-scratch-for-snapshot-test').deleteSync(recursive: true);
    }
  });

  test('a mock context says so', () async {
    final ctx = await AppContext.open(manifest(),
        env: {'APP_CONTEXT_SCRATCH': '$root/mockshape', 'APP_CONTEXT_MODE': 'mock'}, platform: 'linux', home: '/x', announce: false);
    expect(ctx.snapshot()['mode'], 'mock');
    await ctx.close();
  });

  group('fixture snapshot_cases.json', () {
    final write = Platform.environment['SNAPSHOT_FIXTURE_WRITE'] == '1';

    test('is written when SNAPSHOT_FIXTURE_WRITE=1', () async {
      if (!write) return;
      final out = <Map<String, Object?>>[];
      for (final c in cases) {
        out.add({
          'name': c.name,
          'kind': c.fixedInstance == null ? 'real-context' : 'built-from-resolve',
          'inputs': {'platform': c.platform, 'home': c.home, 'env': c.env},
          'snapshot': await produce(c),
        });
      }
      File(fixturePath).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(out)}\n');
    });

    test('still says what the code produces', () async {
      final committed = jsonDecode(File(fixturePath).readAsStringSync()) as List<dynamic>;
      expect(committed.map((c) => c['name']).toList(), cases.map((c) => c.name).toList());
      for (var i = 0; i < cases.length; i++) {
        final c = cases[i];
        final snap = (committed[i]['snapshot'] as Map).cast<String, Object?>();
        final fresh = await produce(c);
        // Real contexts draw a new random instance each run; everything else must be identical.
        expect(snap['instance'], matches(RegExp(r'^[0-9a-f]{8}$')), reason: c.name);
        if (c.fixedInstance != null) {
          expect(snap, fresh, reason: c.name);
        } else {
          expect({...snap, 'instance': 'x'}, {...fresh, 'instance': 'x'}, reason: c.name);
        }
        expect(committed[i]['inputs'], {'platform': c.platform, 'home': c.home, 'env': c.env}, reason: c.name);
      }
    });
  });
}
