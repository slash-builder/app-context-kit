// Spec section 5 item 3: a damaged config.json is reported, never silently overwritten.
import 'dart:convert';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File file;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app-context-config-');
    file = File('${tmp.path}/config.json');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('damaged files', () {
    final cases = <String, List<int>>{
      'not valid UTF-8': [0x7b, 0x22, 0xff, 0xfe, 0x22, 0x7d],
      'not a JSON object (array)': utf8.encode('[1, 2]'),
      'not a JSON object (string)': utf8.encode('"hello"'),
      'not JSON at all': utf8.encode('{not json'),
      'empty': const [],
    };
    cases.forEach((label, bytes) {
      test('$label: open reports a problem and still opens; set and save throw and leave the file alone', () {
        file.writeAsBytesSync(bytes);
        final s = ConfigStore.open(tmp);
        expect(s.problem, isNotNull);
        expect(s.isDamaged, isTrue);
        expect(s.all, isEmpty);
        expect(s.get<int>('a', 7), 7, reason: 'reads still work, on an empty store');

        expect(() => s.set('a', 1), throwsA(isA<DamagedConfigError>().having((e) => e.problem, 'problem', s.problem)));
        expect(s.save, throwsA(isA<DamagedConfigError>()));
        expect(s.all, isEmpty, reason: 'a refused set changes nothing in memory either');
        expect(file.readAsBytesSync(), bytes, reason: 'the damaged file is byte-for-byte untouched');
        expect(File('${file.path}.tmp').existsSync(), isFalse);
      });
    });
  });

  test('setAsideCorrupt renames to config.json.corrupt, clears the problem and allows writing again', () {
    final bytes = [0xff, 0xfe, 0x00];
    file.writeAsBytesSync(bytes);
    final s = ConfigStore.open(tmp);
    final aside = s.setAsideCorrupt();
    expect(aside, isNotNull);
    expect(aside!.path, '${file.path}.corrupt');
    expect(aside.readAsBytesSync(), bytes);
    expect(file.existsSync(), isFalse);
    expect(s.problem, isNull);
    expect(s.isDamaged, isFalse);

    s.set('a', 1);
    expect(jsonDecode(file.readAsStringSync()), {'a': 1});
    expect(aside.readAsBytesSync(), bytes, reason: 'the set-aside copy is kept');
    expect(ConfigStore.open(tmp).get<int>('a', 0), 1);
  });

  test('setAsideCorrupt on a healthy store does nothing', () {
    file.writeAsStringSync('{"a":1}');
    final s = ConfigStore.open(tmp);
    expect(s.setAsideCorrupt(), isNull);
    expect(file.existsSync(), isTrue);
    expect(s.get<int>('a', 0), 1);
  });

  test('a newer damaged file replaces an older .corrupt copy', () {
    File('${file.path}.corrupt').writeAsStringSync('old');
    file.writeAsStringSync('[]');
    ConfigStore.open(tmp).setAsideCorrupt();
    expect(File('${file.path}.corrupt').readAsStringSync(), '[]');
  });

  test('a missing file is not damaged', () {
    final s = ConfigStore.open(tmp);
    expect(s.problem, isNull);
    s.set('a', 'b');
    expect(jsonDecode(file.readAsStringSync()), {'a': 'b'});
  });

  test('AppContext.open reports a damaged config as a warning note and still opens; the app can set it aside', () async {
    file = File('${tmp.path}/com.slashbuilder.demo.calc/config/config.json')..createSync(recursive: true);
    file.writeAsBytesSync([0xc3, 0x28]); // invalid UTF-8
    final m = AppManifest.fromJson({'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0'});
    final ctx = await AppContext.open(m, env: {'APP_CONTEXT_SCRATCH': tmp.path}, platform: 'linux', home: '/x', announce: false);
    expect(ctx.config.problem, contains('UTF-8'));
    expect(ctx.notes.where((n) => n.text.startsWith('Settings:')).single.severity, NoteSeverity.warning);
    expect(() => ctx.config.set('a', 1), throwsA(isA<DamagedConfigError>()));
    ctx.config.setAsideCorrupt();
    ctx.config.set('a', 1);
    expect(ctx.config.get<int>('a', 0), 1);
    await ctx.close();
  });

  group('get', () {
    test('get<double> accepts a whole number (JSON 3 reads as 3.0)', () {
      file.writeAsStringSync('{"n": 3, "f": 2.5, "s": "x", "neg": -4}');
      final s = ConfigStore.open(tmp);
      expect(s.get<double>('n', 0.5), 3.0);
      expect(s.get<double>('n', 0.5), isA<double>());
      expect(s.get<double>('neg', 0.5), -4.0);
      expect(s.get<double>('f', 0.5), 2.5);
      expect(s.get<double?>('n', null), 3.0);
      expect(s.get<num>('n', 0), 3);
    });

    test('get falls back for a missing key or the wrong type', () {
      file.writeAsStringSync('{"s": "x", "f": 2.5}');
      final s = ConfigStore.open(tmp);
      expect(s.get<double>('missing', 1.5), 1.5);
      expect(s.get<double>('s', 1.5), 1.5);
      expect(s.get<int>('f', 9), 9, reason: 'a fraction is not an int');
      expect(s.get<String>('s', ''), 'x');
    });
  });
}
