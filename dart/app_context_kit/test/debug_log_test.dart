// The app-wide debug log: off by default, live toggle, an allow-list of
// fields, scrubbing, permissions, rotation, and no corruption under
// concurrent writes. Moved from Courier's test/debug_log_test.dart (b9af9d6);
// the Flutter test harness became package:test, the ValueListenable became a
// Stream, and "Courier debug log" became the injected app name.

import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

enum _Phase { running, failed }

const _canaries = [
  'sk-ant-oat01-CANARYCANARYCANARY0123456789abcdef',
  'ghp_CANARYCANARYCANARY0123456789abcdefghij',
  'Bearer CANARYbearer0123456789',
  'https://claude.com/cai/oauth/authorize?code=CANARYCODE123&state=CANARYSTATE456&code_challenge=CANARYCHAL789',
  'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJDQU5BUlkifQ.CANARYSIGNATURE0123',
  '0123456789abcdef0123456789abcdef0123456789abcdef',
  'Ab3dEf6hIj9LmNo2Q#xY-z_k.~%+/=',
  '4676 6357 9654 9797 ede7',
];

Directory _tmp() => Directory.systemTemp.createTempSync('debug-log-test-');
int _mode(FileSystemEntity e) => e.statSync().mode & 0x1ff;

void main() {
  late Directory root;
  late Directory dir;
  var providerCalls = 0;
  setUp(() {
    root = _tmp();
    dir = Directory('${root.path}/nested/logs');
    providerCalls = 0;
  });
  tearDown(() => root.deleteSync(recursive: true));

  DebugLog make({
    bool enabled = true,
    int maxBytes = 1024 * 1024,
    int keep = 3,
  }) =>
      DebugLog(
        directory: () async {
          providerCalls++;
          return dir;
        },
        enabled: enabled,
        maxBytes: maxBytes,
        keep: keep,
        now: () => DateTime.utc(2026, 10, 11, 19, 5, 9),
      );

  String file([String name = 'debug.log']) =>
      File('${dir.path}/$name').readAsStringSync();

  group('off by default, live toggle', () {
    test('a new log is off, and writes nothing, creates nothing', () async {
      final log = make(enabled: false);
      expect(log.enabled, isFalse);
      log.event('chat_setup', 'signin.start',
          fields: {'phase': _Phase.running, 'count': 1});
      await log.flush();
      expect(dir.existsSync(), isFalse);
      expect(root.listSync(), isEmpty);
      expect(providerCalls, 0, reason: 'the folder was not even looked up');
    });

    test('the app\'s own log is off until something turns it on', () {
      expect(DebugLog.instance.enabled, isFalse);
    });

    test('on, then off, then on: effective at once, no restart', () async {
      final log = make(enabled: false);
      final seen = <bool>[];
      final sub = log.enabledChanges.listen((_) => seen.add(log.enabled));
      addTearDown(sub.cancel);
      log.event('t', 'one');
      log.enabled = true;
      log.event('t', 'two');
      await log.flush();
      log.enabled = false;
      log.event('t', 'three');
      await log.flush();
      log.enabled = true;
      log.event('t', 'four');
      await log.flush();
      final text = file();
      expect(text, isNot(contains(' one')));
      expect(text, contains(' t two'));
      expect(text, isNot(contains(' three')));
      expect(text, contains(' t four'));
      expect(seen, [true, false, true]);
    });
  });

  group('a line', () {
    test('time, level, component, event, then allow-listed fields', () async {
      final log = make();
      log.event('chat_setup', 'signin.end', level: LogLevel.warn, fields: {
        'phase': _Phase.failed,
        'exit': 3,
        'ms': const Duration(milliseconds: 1500),
        'ok': false,
        'count': 2,
        'class': 'StateError',
      });
      await log.flush();
      expect(file(),
          '2026-10-11T19:05:09.000Z warn chat_setup signin.end phase=failed exit=3 ms=1500 ok=false count=2 class=StateError\n');
    });

    test('a field that is not on the list is dropped', () async {
      final log = make();
      log.event('t', 'e', fields: {
        'body': 'SECRETBODY',
        'token': 'SECRETTOKEN',
        'url': 'https://x',
        'result': 7,
        'password': 'x',
      });
      await log.flush();
      final text = file();
      expect(text, contains('result=7'));
      for (final bad in ['body', 'token', 'url', 'password', 'SECRET']) {
        expect(text, isNot(contains(bad)));
      }
    });

    test('values that are not numbers, bools, enums or strings are dropped',
        () async {
      final log = make();
      log.event('t', 'e', fields: {
        'count': [1, 2, 3],
        'kind': {'a': 'b'},
        'len': Object(),
        'ms': null,
        'ok': true,
      });
      await log.flush();
      expect(file().trim().split(' ').sublist(2), ['t', 'e', 'ok=true']);
    });

    test('component and event names are fixed lowercase words', () async {
      final log = make();
      log.event('Chat Setup', 'sign in');
      log.event('chat_setup', 'sk-ant-oat01-CANARYCANARYCANARY');
      log.event('x' * 40, 'e' * 80);
      await log.flush();
      final text = file();
      expect(text, isNot(contains('sk-ant')));
      expect(text, isNot(contains('Chat Setup')));
      expect('invalid'.allMatches(text).length, 5);
    });
  });

  group('canaries never reach the file', () {
    test('as the value of every allowed field', () async {
      final log = make();
      for (final c in _canaries) {
        log.event('t', 'e', fields: {for (final f in kLogFields) f: c});
        log.event('t', c, fields: {'class': c});
        log.event(c, 'e');
      }
      await log.flush();
      final bytes = File('${dir.path}/debug.log').readAsBytesSync();
      final text = String.fromCharCodes(bytes);
      for (final needle in [
        'CANARY',
        'sk-ant',
        'ghp_',
        'Bearer',
        'eyJ',
        '0123456789abcdef',
        'Ab3dEf',
        '4676',
        'oauth',
        'code_challenge',
        '://',
        '?',
      ]) {
        expect(text, isNot(contains(needle)), reason: needle);
      }
    });

    test('inside an error: only its class and numbers get out', () {
      final f = errorFields(StateError(
          'HTTP 404 code 24 failed for https://x/y?token=CANARYTOKEN123 '
          'sk-ant-oat01-CANARY'));
      expect(f, {'class': 'StateError', 'status': 404, 'result': 24});
      expect(errorFields(const FormatException('boom')),
          {'class': 'FormatException'});
    });

    test('scrubForLog removes the shapes', () {
      for (final c in _canaries) {
        final t = scrubForLog('before $c after');
        expect(t, isNot(contains('CANARY')), reason: c);
      }
      expect(scrubForLog('a normal sentence'), 'a normal sentence');
      expect(safeLogString('DispatcherTransportException'),
          'DispatcherTransportException');
      expect(safeLogString('word ' * 40).length, 64);
      expect(safeLogString('x' * 200), 'X',
          reason: 'a long unbroken run is a key');
      expect(safeLogString('a b/c?d=e'), 'a_b_cX');
    });

    test('a poisoned file is scrubbed again on the way out', () async {
      final log = make();
      log.event('t', 'e');
      await log.flush();
      File('${dir.path}/debug.log')
          .writeAsStringSync('x ${'A1' * 30} tail\n', mode: FileMode.append);
      final text = await log.tail();
      expect(text, isNot(contains('A1A1A1A1A1A1')));
      expect(text, contains('[x]'));
    });
  });

  group('permissions and rotation', () {
    test('the folder is 0700 and the file 0600', () async {
      final log = make();
      log.event('t', 'e');
      await log.flush();
      expect(_mode(dir), 0x1c0);
      expect(_mode(File('${dir.path}/debug.log')), 0x180);
    });

    test('a folder and files that already existed are tightened', () async {
      dir.createSync(recursive: true);
      Process.runSync('chmod', ['755', dir.path]);
      final a = File('${dir.path}/debug.log')..writeAsStringSync('x\n');
      final b = File('${dir.path}/debug.log.1')..writeAsStringSync('y\n');
      Process.runSync('chmod', ['644', a.path, b.path]);
      final log = make();
      log.event('t', 'e');
      await log.flush();
      expect(_mode(dir), 0x1c0);
      expect(_mode(a), 0x180);
      expect(_mode(b), 0x180);
    });

    test('three files at most, each under the cap, all 0600', () async {
      final log = make(maxBytes: 500);
      for (var i = 0; i < 200; i++) {
        log.event('t', 'step', fields: {'count': i});
      }
      await log.flush();
      final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList()
        ..sort();
      expect(names, ['debug.log', 'debug.log.1', 'debug.log.2']);
      for (final n in names) {
        expect(File('${dir.path}/$n').lengthSync(), lessThanOrEqualTo(500));
        expect(_mode(File('${dir.path}/$n')), 0x180, reason: n);
      }
      final all = await log.tail();
      expect(all, contains('count=199'));
      expect(all, isNot(contains('count=0\n')));
      final ns = RegExp(r'count=(\d+)')
          .allMatches(all)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      expect(ns, [...ns]..sort(), reason: 'oldest first');
    });

    test('the defaults are 1 MiB and three files', () {
      final log = DebugLog(directory: () async => dir);
      expect(log.maxBytes, 1024 * 1024);
      expect(log.keep, 3);
    });
  });

  group('concurrent writes', () {
    test('many tasks at once: every line whole, none lost', () async {
      final log = make();
      await Future.wait([
        for (var t = 0; t < 20; t++)
          () async {
            for (var i = 0; i < 25; i++) {
              await Future<void>.delayed(Duration.zero);
              log.event('task$t', 'step',
                  fields: {'count': i, 'ms': t * 100 + i});
            }
          }(),
      ]);
      await log.flush();
      final lines = file().trim().split('\n');
      expect(lines, hasLength(500));
      final shape = RegExp(
          r'^\d{4}-\d\d-\d\dT[\d:.]+Z info task\d+ step count=\d+ ms=\d+$');
      for (final l in lines) {
        expect(l, matches(shape));
      }
    });

    test('rotation under concurrent writes keeps lines whole', () async {
      final log = make(maxBytes: 2000);
      await Future.wait([
        for (var t = 0; t < 10; t++)
          () async {
            for (var i = 0; i < 40; i++) {
              await Future<void>.delayed(Duration.zero);
              log.event('t$t', 'step', fields: {'count': i});
            }
          }(),
      ]);
      await log.flush();
      final text = await log.tail();
      final shape =
          RegExp(r'^\d{4}-\d\d-\d\dT[\d:.]+Z info t\d+ step count=\d+$');
      for (final l in text.trim().split('\n').skip(1)) {
        expect(l, matches(shape));
      }
    });
  });

  group('the controls', () {
    test('clear deletes the files', () async {
      final log = make();
      log.event('t', 'e');
      await log.flush();
      await log.clear();
      expect(Directory(dir.path).listSync(), isEmpty);
      log.event('t', 'again');
      await log.flush();
      expect(file(), contains('again'));
    });

    test('the folder path is known without creating it', () async {
      final log = make(enabled: false);
      expect(await log.folderPath(), dir.path);
      expect(dir.existsSync(), isFalse);
    });

    test('tail has a header, also when nothing was recorded', () async {
      final log = make(enabled: false);
      expect(await log.tail(), contains('App debug log'));
      expect(await log.tail(), contains('nothing recorded'));
    });

    test('it never throws: a folder that cannot be made', () async {
      final blocker = File('${root.path}/file')..writeAsStringSync('x');
      final log = DebugLog(
          directory: () async => Directory('${blocker.path}/sub'),
          enabled: true);
      log.event('t', 'e');
      await log.flush();
      expect(await log.tail(), contains('App debug log'));
    });
  });

  group('links and permissions (security review)', () {
    test('L1: a folder that is a link is neither written to nor changed',
        () async {
      final target = Directory('${root.path}/elsewhere')..createSync();
      Process.runSync('chmod', ['755', target.path]);
      Link('${root.path}/logs').createSync(target.path);
      final log = DebugLog(
          directory: () async => Directory('${root.path}/logs'), enabled: true);
      log.event('app', 'start', fields: {'ok': true});
      log.event('app', 'start', fields: {'ok': true});
      await log.flush();
      expect(target.listSync(), isEmpty);
      expect(_mode(target), 0x1ed, reason: 'still 0755: no chmod through it');
      expect(await log.tail(), contains('nothing recorded'));
    });

    test(
        'L2: debug.log that is a link: not appended to, not chmodded, not read',
        () async {
      dir.createSync(recursive: true);
      final victim = File('${root.path}/victim.txt')
        ..writeAsStringSync('VICTIM short secret hunter2\n');
      Process.runSync('chmod', ['644', victim.path]);
      Link('${dir.path}/debug.log').createSync(victim.path);
      final log = make();
      log.event('app', 'start', fields: {'ok': true});
      await log.flush();
      expect(victim.readAsStringSync(), 'VICTIM short secret hunter2\n');
      expect(_mode(victim), 0x1a4, reason: 'still 0644');
      expect(await log.tail(), isNot(contains('hunter2')));
      // Clear logs removes the link itself, never the file behind it, and
      // logging starts over.
      await log.clear();
      expect(victim.existsSync(), isTrue);
      log.event('app', 'again');
      await log.flush();
      expect(File('${dir.path}/debug.log').readAsStringSync(),
          contains('app again'));
      expect(victim.readAsStringSync(), isNot(contains('again')));
    });

    test('L3: a rotated file that is a link: refused, the target untouched',
        () async {
      dir.createSync(recursive: true);
      final victim = File('${root.path}/v2')..writeAsStringSync('x');
      Process.runSync('chmod', ['644', victim.path]);
      Link('${dir.path}/debug.log.1').createSync(victim.path);
      final log = make(maxBytes: 200);
      for (var i = 0; i < 10; i++) {
        log.event('app', 'start', fields: {'count': i});
      }
      await log.flush();
      expect(_mode(victim), 0x1a4);
      expect(victim.readAsStringSync(), 'x');
    });

    test('a folder or file of another kind in the way is refused', () async {
      dir.createSync(recursive: true);
      Directory('${dir.path}/debug.log').createSync();
      final log = make();
      log.event('app', 'start');
      await log.flush();
      expect(Directory('${dir.path}/debug.log').listSync(), isEmpty);
    });

    test('L4: permissions are checked at every write, not once', () async {
      final log = make();
      log.event('app', 'start');
      await log.flush();
      // loosened (or recreated) by someone else after the first write
      Process.runSync('chmod', ['644', '${dir.path}/debug.log']);
      log.event('app', 'start');
      await log.flush();
      expect(_mode(File('${dir.path}/debug.log')), 0x180);
      expect(File('${dir.path}/debug.log').readAsStringSync().split('\n'),
          hasLength(3));
    });

    test('L13: rotated files are locked down too', () async {
      final log = make(maxBytes: 300);
      log.event('app', 'start');
      await log.flush();
      Process.runSync('chmod', ['644', '${dir.path}/debug.log']);
      for (var i = 0; i < 12; i++) {
        log.event('app', 'start', fields: {'count': i});
      }
      await log.flush();
      for (final n in ['debug.log', 'debug.log.1', 'debug.log.2']) {
        expect(File('${dir.path}/$n').existsSync(), isTrue, reason: n);
        expect(_mode(File('${dir.path}/$n')), 0x180, reason: n);
      }
    });

    test(
        'a rotated file loosened after the first write is locked down when '
        'it moves', () async {
      final log = make(maxBytes: 300);
      log.event('app', 'start');
      await log.flush();
      final older = File('${dir.path}/debug.log.1')..writeAsStringSync('old\n');
      Process.runSync('chmod', ['644', older.path]);
      for (var i = 0; i < 6; i++) {
        log.event('app', 'start', fields: {'count': i});
      }
      await log.flush();
      expect(File('${dir.path}/debug.log.2').readAsStringSync(), 'old\n');
      expect(_mode(File('${dir.path}/debug.log.2')), 0x180);
    });

    test('L3b: the log file is created exclusively and empty first', () async {
      final log = make();
      log.event('app', 'start');
      await log.flush();
      expect(_mode(File('${dir.path}/debug.log')), 0x180);
    });

    test('clear runs in the write queue: lines before it go, lines after stay',
        () async {
      final log = make();
      log.event('app', 'before');
      final cleared = log.clear();
      log.event('app', 'after');
      await cleared;
      await log.flush();
      final text = File('${dir.path}/debug.log').readAsStringSync();
      expect(text, isNot(contains('before')));
      expect(text, contains('after'));
    });

    test('tail reads only plain files, and only the end of a big one',
        () async {
      final log = make();
      log.event('app', 'start');
      await log.flush();
      // a directory where an older file belongs, and a very big current file
      Directory('${dir.path}/debug.log.1').createSync();
      final big = File('${dir.path}/debug.log');
      const line = '2026-10-11T19:05:09.000Z info t e count=1\n';
      big.writeAsStringSync(line * 150000, mode: FileMode.append); // ~6 MB
      final sw = Stopwatch()..start();
      final text = await log.tail(maxChars: 4000);
      expect(sw.elapsedMilliseconds, lessThan(1500));
      expect(text.length, lessThan(4200));
      expect(text, contains('count=1'));
      // even asked for everything, only the end of a file is read
      File('${dir.path}/debug.log')
          .writeAsStringSync('OLDMARK-FIRST-LINE\n${line * 150000}');
      final all = await log.tail(maxChars: 100 * 1024 * 1024);
      expect(all, isNot(contains('OLDMARK')));
      expect(all.length, lessThan(70 * 1024));
    });
  });

  group('a chmod that does not tighten stops the writing', () {
    DebugLog stubborn(bool Function(String mode, String path) ok) => DebugLog(
        directory: () async => dir,
        enabled: true,
        lockDown: (mode, path) async => ok(mode, path));

    test('D3: the file cannot be tightened: not one line is written', () async {
      final log = stubborn((mode, path) => mode != '600');
      log.event('app', 'start');
      log.event('app', 'start');
      await log.flush();
      final f = File('${dir.path}/debug.log');
      expect(!f.existsSync() || f.readAsStringSync().isEmpty, isTrue,
          reason: 'nothing was written to an open file');
      expect(await log.tail(), isNot(contains('app start')));
    });

    test('D3: chmod that does nothing is noticed by the check afterwards',
        () async {
      // a default umask leaves group or other bits on a new file and folder
      final log = DebugLog(
          directory: () async => dir,
          enabled: true,
          chmod: (mode, path) async {});
      log.event('app', 'start');
      log.event('app', 'start');
      await log.flush();
      final f = File('${dir.path}/debug.log');
      expect(!f.existsSync() || f.readAsStringSync().isEmpty, isTrue);
    });

    test('the folder cannot be tightened: nothing is created in it', () async {
      final log = stubborn((mode, path) => mode != '700');
      log.event('app', 'start');
      await log.flush();
      expect(dir.listSync(), isEmpty);
    });

    test('a file loosened later that cannot be tightened again stops it',
        () async {
      var tighten = true;
      final log = stubborn((mode, path) {
        if (tighten) {
          Process.runSync('chmod', [mode, path]);
          return true;
        }
        return false;
      });
      log.event('app', 'first');
      await log.flush();
      tighten = false;
      log.event('app', 'second');
      log.event('app', 'third');
      await log.flush();
      final text = File('${dir.path}/debug.log').readAsStringSync();
      expect(text, contains('app first'));
      expect(text, isNot(contains('second')));
      expect(text, isNot(contains('third')));
      // Clear logs starts over once permissions allow
      tighten = true;
      await log.clear();
      log.event('app', 'again');
      await log.flush();
      expect(File('${dir.path}/debug.log').readAsStringSync(),
          contains('app again'));
    });
  });

  group('values and text (security review)', () {
    test('L5: a long value is cut before it is cleaned (cost is bounded)', () {
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        safeLogString('a' * 50000);
        safeLogString('${'a' * 25000}://${'b' * 25000}');
        errorFields(Exception('x' * 100000));
      }
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });

    test('string values are fixed words or nothing', () async {
      final log = make();
      final cases = <String, bool>{
        'StateError': true,
        '_Exception': true,
        'this_computer': true,
        '1.2.3+4': true,
        '48213': false,
        'abcd1234': true,
        'ABCDEFGHIJKLMNOPQRSTUVWXYZ': false,
        'hunter2 hunter3': false,
        'sk ant oat01 abcdefghij': false,
        'ｓｋ－ａｎｔ': false,
        '4676 6357 9654 9797 ede7': false,
        'ok\n2026-01-01T00:00:00Z error app forged ok=true': false,
        '\x1b[31mred\x1b[0m': false,
        'abcdefghijABCDEFGHIJabcdefghijABCDEFGHIJ': false,
        'x' * 33: false,
      };
      var i = 0;
      for (final e in cases.entries) {
        log.event('t', 'e$i'.replaceAll(RegExp(r'\d'), 'x'),
            fields: {'kind': e.key});
        i++;
      }
      await log.flush();
      final lines =
          File('${dir.path}/debug.log').readAsStringSync().trim().split('\n');
      expect(lines, hasLength(cases.length));
      var n = 0;
      for (final e in cases.entries) {
        expect(lines[n].contains('kind='), e.value, reason: e.key);
        n++;
      }
      expect(lines.join('\n'), isNot(contains('forged')));
    });

    test('L6: the field is called result, not code', () async {
      expect(kLogFields, contains('result'));
      expect(kLogFields, isNot(contains('code')));
      final log = make();
      log.event('t', 'e', fields: {'code': 7, 'result': 7});
      await log.flush();
      final text = File('${dir.path}/debug.log').readAsStringSync();
      expect(text, contains('result=7'));
      expect(text, isNot(contains('code=')));
    });

    test('L7: no long number from an error text', () {
      expect(errorFields(Exception('callback ?code=48213 HTTP 401')),
          {'class': '_Exception', 'status': 401});
      expect(errorFields(Exception('error 12345 code 24')),
          {'class': '_Exception', 'result': 24});
      expect(errorFields(Exception('code 24')),
          {'class': '_Exception', 'result': 24});
    });
  });

  group('the pieces a Kit needs', () {
    test('LogSink: DebugLog is one, and a Kit can be handed it', () async {
      final log = make();
      final LogSink sink = log;
      sink.event('t', 'via_sink', fields: {'count': 2});
      await log.flush();
      expect(file(), contains(' t via_sink count=2'));
    });

    test('NullLogSink takes everything and records nothing', () {
      const LogSink sink = NullLogSink();
      sink.event('t', 'e', level: LogLevel.error, fields: {'count': 1});
    });

    test('logProcess writes to the sink it is given, not to the app log',
        () async {
      final log = make();
      final took = Stopwatch()..start();
      logProcess(log, 'gateway', 'systemctl', kind: 'start', took: took, exit: 0);
      logProcess(log, 'gateway', 'systemctl',
          kind: 'start', took: took, error: StateError('secret text'));
      await log.flush();
      final text = file();
      expect(text, contains(' debug gateway systemctl kind=start'));
      expect(text, contains('exit=0 ok=true'));
      expect(text, contains(' warn gateway systemctl'));
      expect(text, contains('class=StateError'));
      expect(text, isNot(contains('secret')));
    });

    test('an app can give its own field allow-list', () async {
      final log = DebugLog(
        directory: () async => dir,
        enabled: true,
        allowedFields: const {'lane'},
      );
      log.event('t', 'e', fields: {'lane': 'left', 'count': 3});
      await log.flush();
      final text = file();
      expect(text, contains('lane=left'));
      expect(text, isNot(contains('count=')), reason: 'not on this allow-list');
    });

    test('forContext: a log in <state>/logs, named after the app', () async {
      final ctx = await AppContext.open(
        AppManifest.fromJson(
            {'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0'}),
        env: {'APP_CONTEXT_SCRATCH': root.path},
        platform: 'linux',
        home: '/nonexistent',
        announce: false,
      );
      addTearDown(ctx.close);
      final log = DebugLog.forContext(ctx, enabled: true);
      log.event('t', 'hello', fields: {'count': 1});
      await log.flush();
      final written = File('${ctx.dirs.state}/logs/debug.log');
      expect(written.existsSync(), isTrue);
      expect(written.readAsStringSync(), contains(' t hello count=1'));
      expect(await log.tail(), startsWith('Calc debug log'));
    });

    test('the app name heads the tail', () async {
      final log = DebugLog(
          directory: () async => dir, appName: 'Courier', enabled: false);
      expect(await log.tail(), startsWith('Courier debug log'));
    });

    test('enabledChanges reports changes, not repeated assignments', () async {
      final log = make(enabled: false);
      final seen = <bool>[];
      final sub = log.enabledChanges.listen(seen.add);
      addTearDown(sub.cancel);
      log.enabled = false;
      log.enabled = true;
      log.enabled = true;
      log.enabled = false;
      expect(seen, [true, false]);
    });

    test('the default instance has no folder: on, it writes nothing and says nothing',
        () async {
      final saved = DebugLog.instance;
      addTearDown(() => DebugLog.instance = saved);
      DebugLog.instance = DebugLog(
          directory: () async => throw StateError('no folder'), enabled: true);
      dlog('t', 'e'); // must not throw
      await DebugLog.instance.flush();
    });
  });
}
