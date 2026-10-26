import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-session-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('with a healthy file it is the store: set saves, get reads', () {
    final store = ConfigStore.open(tmp);
    final s = SessionSettings(store);
    expect(s.readOnly, isFalse);
    s.set('theme', 'dark');
    expect(s.get<String>('theme', 'light'), 'dark');
    expect(ConfigStore.open(tmp).get<String>('theme', ''), 'dark', reason: 'it reached the file');
  });

  test('with a damaged file a change lives for the session only, and the file is never touched', () {
    final file = File('${tmp.path}/config.json')..writeAsStringSync('{broken');
    final store = ConfigStore.open(tmp);
    final s = SessionSettings(store);
    expect(s.readOnly, isTrue);
    s.set('theme', 'dark'); // does not throw DamagedConfigError
    expect(s.get<String>('theme', 'light'), 'dark');
    expect(s.get<String>('other', 'fallback'), 'fallback');
    expect(file.readAsStringSync(), '{broken');
    expect(() => store.set('x', 1), throwsA(isA<DamagedConfigError>()), reason: 'the store itself still refuses');
  });

  test('a session value of the wrong type falls back, like the store does', () {
    File('${tmp.path}/config.json').writeAsStringSync('[]');
    final s = SessionSettings(ConfigStore.open(tmp));
    s.set('n', 'not a number');
    expect(s.get<int>('n', 7), 7);
  });

  test('once the file is set aside the settings are writable again', () {
    File('${tmp.path}/config.json').writeAsStringSync('{broken');
    final store = ConfigStore.open(tmp);
    final s = SessionSettings(store);
    s.set('a', 1);
    store.setAsideCorrupt();
    expect(s.readOnly, isFalse);
    s.set('a', 2);
    expect(ConfigStore.open(tmp).get<int>('a', 0), 2);
  });
}
