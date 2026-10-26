import 'dart:convert';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

List<dynamic> load(String name) =>
    jsonDecode(File('../../spec/conformance/$name').readAsStringSync()) as List<dynamic>;

void main() {
  group('manifest conformance', () {
    for (final c in load('manifest_cases.json')) {
      test(c['name'] as String, () {
        // A case carries either a parsed `manifest` value or a raw `source` string (which exercises `parse`).
        AppManifest build() =>
            c.containsKey('source') ? AppManifest.parse(c['source'] as String) : AppManifest.fromJson(c['manifest']);
        if (c['valid'] == true) {
          final m = build();
          final d = c['defaults'] as Map<String, dynamic>;
          expect(m.kits, d['kits']);
          expect(m.venue.mode, d['venueMode']);
          expect(m.venue.consumer, d['venueConsumer']);
        } else {
          expect(build,
              throwsA(isA<ManifestError>().having((e) => e.code, 'code', c['error'])));
        }
      });
    }
  });

  group('context conformance', () {
    for (final c in load('context_cases.json')) {
      test(c['name'] as String, () {
        final m = AppManifest.fromJson(c['manifest']);
        Resolved run() => resolve(
            manifest: m,
            platform: c['platform'] as String,
            home: c['home'] as String,
            env: (c['env'] as Map).cast<String, String>());
        if (c.containsKey('error')) {
          expect(run, throwsA(isA<ResolveError>().having((e) => e.code, 'code', c['error'])));
          return;
        }
        final r = run();
        final e = c['expect'] as Map<String, dynamic>;
        final d = e['dirs'] as Map<String, dynamic>;
        expect(r.prefix, e['prefix']);
        expect(r.dirs.data, d['data'], reason: 'data');
        expect(r.dirs.config, d['config'], reason: 'config');
        expect(r.dirs.state, d['state'], reason: 'state');
        expect(r.dirs.cache, d['cache'], reason: 'cache');
        expect(r.dirs.runtime, d['runtime'], reason: 'runtime');
        expect(r.roster, e['roster'], reason: 'roster');
        expect(r.scratch, e['scratch']);
        expect(r.mode.name, e['mode']);
      });
    }
  });
}
