// Edges of spec section 1 and 2 that the shared fixtures do not spell out; they must still hold in every implementation.
import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

Map<String, Object?> base([Map<String, Object?> extra = const {}]) =>
    {'id': 'com.slashbuilder.demo.calc', 'name': 'Demo', 'version': '0.1.0', ...extra};

Matcher code(String c) => throwsA(isA<ManifestError>().having((e) => e.code, 'code', c));

void main() {
  group('name: only space, tab, CR, LF are blank', () {
    for (final (label, name) in [
      ('no-break space', ' '),
      ('line separator', ' '),
      ('ideographic space', '　'),
      ('vertical tab', '\u000b'),
      ('form feed', '\u000c'),
      ('BOM', '﻿'),
      ('text with spaces around', ' a '),
    ]) {
      test('$label is content', () => expect(AppManifest.fromJson(base({'name': name})).name, name));
    }
    test('empty is blank', () => expect(() => AppManifest.fromJson(base({'name': ''})), code('bad-name')));
    test('mixed ASCII whitespace is blank', () => expect(() => AppManifest.fromJson(base({'name': ' \t\r\n \t'})), code('bad-name')));
  });

  group('whole-string patterns', () {
    test('trailing newline on every pattern is refused', () {
      expect(() => AppManifest.fromJson(base({'id': 'com.slashbuilder.demo.calc\n'})), code('bad-id'));
      expect(() => AppManifest.fromJson(base({'version': '0.1.0\n'})), code('bad-version'));
      expect(() => AppManifest.fromJson(base({'kits': ['venue\n']})), code('bad-kits'));
      expect(() => AppManifest.fromJson(base({'envPrefix': 'CALC\n'})), code('bad-prefix'));
      expect(() => AppManifest.fromJson(base({'venue': {'consumer': 'calc\n'}})), code('bad-venue'));
    });
    test('a leading newline and non-ASCII digits are refused', () {
      expect(() => AppManifest.fromJson(base({'id': '\ncom.slashbuilder.demo.calc'})), code('bad-id'));
      expect(() => AppManifest.fromJson(base({'version': '١.0.0'})), code('bad-version'));
    });
  });

  group('parse', () {
    test('empty text is not-json', () => expect(() => AppManifest.parse(''), code('not-json')));
    test('a string, a number and true are not-object', () {
      for (final s in ['"x"', '5', 'true']) {
        expect(() => AppManifest.parse(s), code('not-object'));
      }
    });
    test('a valid document is validated like a parsed value', () {
      expect(() => AppManifest.parse('{"id":"x","name":"n","version":"1.0.0"}'), code('bad-id'));
    });
  });

  group('resolve edges', () {
    final m = AppManifest.fromJson(base());
    Resolved go(String platform, Map<String, String> env, {String home = '/home/user'}) =>
        resolve(manifest: m, platform: platform, home: home, env: env);

    test('a scratch root of "/" is not doubled', () {
      final r = go('linux', {'APP_CONTEXT_SCRATCH': '/'});
      expect(r.dirs.data, '/com.slashbuilder.demo.calc/data');
      expect(r.roster, '/roster');
    });
    test('several trailing separators collapse, but a lone root stays', () {
      expect(go('linux', {'XDG_DATA_HOME': '/x//'}).dirs.data, '/x/com.slashbuilder.demo.calc');
      expect(go('linux', {'XDG_DATA_HOME': '//'}).dirs.data, '/com.slashbuilder.demo.calc');
    });
    test('a windows base that is only a separator is not doubled', () {
      expect(go('windows', {'LOCALAPPDATA': r'\', 'APPDATA': 'A', 'TEMP': 'T'}).dirs.data, r'\com.slashbuilder.demo.calc\data');
    });
    test('runtime default follows a state override only through XDG_STATE_HOME, not through the override', () {
      final r = go('linux', {'CALC_STATE_DIR': '/s'});
      expect(r.dirs.state, '/s');
      expect(r.dirs.runtime, '/home/user/.local/state/com.slashbuilder.demo.calc/run');
    });
    test('only the winning mode variable is checked, and bad-mode precedes missing-env', () {
      expect(go('linux', {'CALC_MODE': 'real', 'APP_CONTEXT_MODE': '???'}).mode, AppMode.real);
      expect(() => go('linux', {'APP_CONTEXT_MODE': '???'}), throwsA(isA<ResolveError>().having((e) => e.code, 'code', 'bad-mode')));
      expect(() => go('windows', {'APP_CONTEXT_MODE': 'x'}), throwsA(isA<ResolveError>().having((e) => e.code, 'code', 'bad-mode')));
      expect(() => go('windows', {}), throwsA(isA<ResolveError>().having((e) => e.code, 'code', 'missing-env')));
    });
  });
}
