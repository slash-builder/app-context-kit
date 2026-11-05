// startDebugLog and AppLifecycleLog: moved from the "app start and stop" group
// of Courier's test/debug_log_wiring_test.dart (b9af9d6), plus the injected
// log and version.

import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recording implements LogSink {
  final lines = <String>[];

  @override
  void event(String component, String name,
      {LogLevel level = LogLevel.info,
      Map<String, Object?> fields = const {}}) {
    lines.add('$component $name ${level.name} $fields');
  }
}

void main() {
  late Directory root;
  late Directory dir;
  late DebugLog log;
  late DebugLog saved;

  setUp(() {
    root = Directory.systemTemp.createTempSync('app-log-test-');
    dir = Directory('${root.path}/logs');
    saved = DebugLog.instance;
    log = DebugLog(directory: () async => dir, enabled: true);
    DebugLog.instance = log;
  });
  tearDown(() {
    DebugLog.instance = saved;
    root.deleteSync(recursive: true);
  });

  Future<String> written() async {
    await log.flush();
    return File('${dir.path}/debug.log').readAsStringSync();
  }

  test('start writes build info only; lifecycle states are enum names',
      () async {
    startDebugLog(enabled: true);
    AppLifecycleLog().didChangeAppLifecycleState(AppLifecycleState.paused);
    AppLifecycleLog().didChangeAppLifecycleState(AppLifecycleState.detached);
    final text = await written();
    expect(text, contains(' app start build='));
    expect(text, contains('platform='));
    expect(text, contains('mode=debug'));
    expect(text, contains('app lifecycle state=paused'));
    expect(text, contains('app stop state=detached'));
  });

  test('start with the log off writes nothing', () async {
    startDebugLog(enabled: false);
    await log.flush();
    expect(dir.existsSync(), isFalse);
    expect(log.enabled, isFalse);
  });

  test('start writes to the log it is given, not the global one', () async {
    final other = DebugLog(
        directory: () async => Directory('${root.path}/other'), enabled: false);
    startDebugLog(enabled: true, log: other);
    await other.flush();
    expect(File('${root.path}/other/debug.log').readAsStringSync(),
        contains(' app start'));
    expect(dir.existsSync(), isFalse, reason: 'the global log was not used');
  });

  test('the app version line is written when the app supplies one', () async {
    startDebugLog(enabled: true, appVersion: () async => '0.1.38+39');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // The log's own value rule turns `+` into `_`, as it did in Courier.
    expect(await written(), contains(' app version build=0.1.38_39'));
  });

  test('an app version that throws, or is null, costs only that line',
      () async {
    startDebugLog(
        enabled: true, appVersion: () async => throw StateError('no bundle'));
    startDebugLog(enabled: true, appVersion: () async => null);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final text = await written();
    expect(text, contains(' app start'));
    expect(text, isNot(contains(' app version')));
  });

  test('AppLifecycleLog takes a sink', () {
    final sink = _Recording();
    AppLifecycleLog(sink: sink)
        .didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(sink.lines, hasLength(1));
    expect(sink.lines.single, startsWith('app lifecycle info'));
  });
}
