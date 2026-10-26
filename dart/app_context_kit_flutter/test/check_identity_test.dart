import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/check_identity.dart';

void main() {
  late Directory app;
  setUp(() => app = Directory.systemTemp.createTempSync('identity-'));
  tearDown(() => app.deleteSync(recursive: true));

  void write(String rel, String text) {
    final f = File('${app.path}/$rel')..createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  void agreeing({String id = 'com.slashbuilder.demo.calc', String name = 'Calc', String version = '1.2.3'}) {
    write('app.json', '{"id":"$id","name":"$name","version":"$version"}');
    write('pubspec.yaml', 'name: calc\nversion: $version+7\n');
    write('macos/Runner/Configs/AppInfo.xcconfig', 'PRODUCT_NAME = $name\n\nPRODUCT_BUNDLE_IDENTIFIER = $id\n');
    write('linux/CMakeLists.txt', 'set(BINARY_NAME "calc")\nset(APPLICATION_ID "$id")\n');
    write('linux/runner/my_application.cc', 'gtk_header_bar_set_title(header_bar, "$name");\n');
  }

  test('everything agreeing gives no findings (the +build suffix is ignored)', () {
    agreeing();
    expect(checkIdentity(app), isEmpty);
  });

  test('a different pubspec version is a mismatch', () {
    agreeing();
    write('pubspec.yaml', 'name: calc\nversion: 1.0.0+1\n');
    final f = checkIdentity(app).single;
    expect(f.mismatch, isTrue);
    expect(f.message, contains('1.2.3'));
    expect(f.message, contains('1.0.0'));
  });

  test('a different macOS bundle id and Linux application id are each a mismatch', () {
    agreeing();
    write('macos/Runner/Configs/AppInfo.xcconfig', 'PRODUCT_NAME = Calc\nPRODUCT_BUNDLE_IDENTIFIER = com.example.calc\n');
    write('linux/CMakeLists.txt', 'set(APPLICATION_ID "com.example.other")\n');
    final msgs = [for (final f in checkIdentity(app)) if (f.mismatch) f.message];
    expect(msgs, hasLength(2));
    expect(msgs.join('\n'), allOf(contains('com.example.calc'), contains('com.example.other')));
  });

  test('a name that differs only in case is a note, a different name is a mismatch', () {
    agreeing();
    write('macos/Runner/Configs/AppInfo.xcconfig', 'PRODUCT_NAME = calc\nPRODUCT_BUNDLE_IDENTIFIER = com.slashbuilder.demo.calc\n');
    var f = checkIdentity(app).single;
    expect(f.mismatch, isFalse);
    write('linux/runner/my_application.cc', 'gtk_window_set_title(window, "Totally Different");\n');
    f = checkIdentity(app).where((f) => f.mismatch).single;
    expect(f.message, contains('Totally Different'));
  });

  test('a missing platform folder is a note, not a mismatch', () {
    agreeing();
    Directory('${app.path}/linux').deleteSync(recursive: true);
    final f = checkIdentity(app).single;
    expect(f.mismatch, isFalse);
    expect(f.message, contains('linux'));
  });

  test('no app.json or a broken one throws FormatException', () {
    expect(() => checkIdentity(app), throwsFormatException);
    write('app.json', '{nope');
    expect(() => checkIdentity(app), throwsFormatException);
    write('app.json', '{"id":"a.b"}');
    expect(() => checkIdentity(app), throwsFormatException);
  });
}
