import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-jsonfile-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File f(String n) => File('${tmp.path}/$n');

  test('a missing file reads as not existing and not a problem', () {
    final r = AppJsonFile(f('nope.json')).read();
    expect((r.exists, r.ok, r.value, r.problem), (false, true, null, null));
  });

  test('write creates the directory, is atomic (no temp left) and reads back', () {
    final j = AppJsonFile(f('deep/er/data.json'));
    j.write({'a': [1, 2], 'b': 'x'});
    expect(f('deep/er/data.json.tmp').existsSync(), isFalse);
    final r = j.read();
    expect((r.exists, r.ok), (true, true));
    expect(r.value, {'a': [1, 2], 'b': 'x'});
  });

  test('a damaged file is reported, not thrown, and is left alone until quarantined', () {
    final file = f('d.json')..writeAsStringSync('{broken');
    final j = AppJsonFile(file);
    final r = j.read();
    expect((r.exists, r.ok), (true, false));
    expect(r.problem, startsWith('not valid JSON'));
    expect(file.readAsStringSync(), '{broken');
    final moved = j.quarantine();
    expect(file.existsSync(), isFalse);
    expect(moved.readAsStringSync(), '{broken');
    expect(moved.path, contains('.damaged-'));
    expect(j.read().exists, isFalse);
  });

  test('bytes that are not UTF-8 are a problem too, not an exception', () {
    final file = f('bin.json')..writeAsBytesSync([0xff, 0xfe, 0x00]);
    final r = AppJsonFile(file).read();
    expect((r.exists, r.ok), (true, false));
    expect(r.problem, isNotNull);
  });

  test('delete removes the file and tolerates a missing one', () {
    final j = AppJsonFile(f('x.json'))..write(1);
    j.delete();
    j.delete();
    expect(f('x.json').existsSync(), isFalse);
  });

  test('ctx.dataJson(name) is that file under the data directory', () async {
    final m = AppManifest.fromJson({'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0'});
    final ctx = await AppContext.open(m,
        env: {'APP_CONTEXT_SCRATCH': tmp.path, 'APP_CONTEXT_MODE': 'mock'}, platform: 'linux', home: '/x', announce: false);
    ctx.dataJson('notes.json').write([1]);
    expect(ctx.dataFile('notes.json').readAsStringSync(), '[1]');
    await ctx.close();
  });
}
