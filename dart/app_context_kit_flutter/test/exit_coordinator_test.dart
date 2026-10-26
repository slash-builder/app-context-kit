import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> events;
  late List<int> exits;
  late List<String> reports;

  setUp(() {
    events = [];
    exits = [];
    reports = [];
  });

  ExitCoordinator make({
    Future<void> Function()? close,
    Map<ProcessSignal, StreamController<ProcessSignal>>? sources,
    List<ProcessSignal> signals = ExitCoordinator.defaultSignals,
    SignalWatcher? watch,
  }) {
    return ExitCoordinator(
      close: close ??
          () async {
            events.add('close');
          },
      exitProcess: (code) {
        events.add('exit');
        exits.add(code);
      },
      report: reports.add,
      signals: signals,
      watch: watch ?? (sources == null ? (s) => const Stream.empty() : (s) => sources[s]!.stream),
    );
  }

  group('once-only close', () {
    test('every path at once still closes exactly once', () async {
      final gate = Completer<void>();
      final c = make(close: () async {
        events.add('close-start');
        await gate.future;
        events.add('close-end');
      });
      final a = c.onExitRequested();
      final b = c.onExitRequested();
      final d = c.onSignal(ProcessSignal.sigterm);
      final e = c.quit();
      final f = c.onDetach();
      gate.complete();
      expect(await a, AppExitResponse.exit);
      expect(await b, AppExitResponse.exit);
      await Future.wait([d, e, f]);
      expect(c.closeCalls, 1);
      expect(events.where((x) => x.startsWith('close')), ['close-start', 'close-end']);
    });

    test('a later request after the close finished does not close again', () async {
      final c = make();
      await c.onExitRequested();
      await c.onExitRequested();
      await c.onSignal(ProcessSignal.sigint);
      expect(c.closeCalls, 1);
      expect(events, ['close', 'exit']);
    });

    test('nothing closes until something asks', () {
      final c = make();
      expect(c.closeCalls, 0);
      expect(c.isShuttingDown, isFalse);
    });
  });

  group('ordering', () {
    test('the lifecycle answer is not given until the close has finished', () async {
      final gate = Completer<void>();
      final c = make(close: () async {
        await gate.future;
        events.add('close');
      });
      var answered = false;
      final f = c.onExitRequested().then((r) {
        answered = true;
        events.add('answer');
        return r;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(answered, isFalse, reason: 'close has not completed, so the engine must not be told to exit');
      gate.complete();
      expect(await f, AppExitResponse.exit);
      expect(events, ['close', 'answer']);
    });

    test('a signal does not end the process until the close has finished', () async {
      final gate = Completer<void>();
      final c = make(close: () async {
        await gate.future;
        events.add('close');
      });
      final f = c.onSignal(ProcessSignal.sigint);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(exits, isEmpty);
      gate.complete();
      await f;
      expect(events, ['close', 'exit']);
    });

    test('with a real context the roster entry is withdrawn before the process exits', () async {
      final tmp = Directory.systemTemp.createTempSync('exit-coord-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final manifest = AppManifest.parse('{"id":"dev.test.exit","name":"Exit","version":"0.0.1"}');
      final ctx = await AppContext.open(manifest,
          env: {'APP_CONTEXT_SCRATCH': tmp.path, 'APP_CONTEXT_MODE': 'mock', 'HOME': tmp.path}, heartbeat: const Duration(milliseconds: 50));
      final rosterDir = Directory(ctx.resolved.roster);
      List<String> entries() => rosterDir.existsSync() ? [for (final f in rosterDir.listSync()) f.path.split('/').last] : [];
      expect(entries(), hasLength(1), reason: 'the context announced itself');
      final hookRan = <String>[];
      ctx.onClose(() => hookRan.add('hook'));

      List<String>? rosterAtExit;
      final c = ExitCoordinator(
        close: ctx.close,
        exitProcess: (code) => rosterAtExit = entries(),
        report: reports.add,
        watch: (s) => const Stream.empty(),
      );
      await c.onSignal(ProcessSignal.sigterm);
      expect(rosterAtExit, isEmpty, reason: 'withdrawn before exit was called');
      expect(hookRan, ['hook']);
      expect(reports, isEmpty);
    });
  });

  group('errors', () {
    test('a failing close is reported in full, and the exit still goes ahead', () async {
      final c = make(close: () async => throw AppCloseError([StateError('hook a'), StateError('hook b')], [StackTrace.empty, StackTrace.empty]));
      expect(await c.onExitRequested(), AppExitResponse.exit);
      expect(reports, hasLength(1));
      expect(reports.single, contains('hook a'));
      expect(reports.single, contains('hook b'));
      expect(c.closeCalls, 1);
    });

    test('a signal after a failed close exits with 1, not the signal code', () async {
      final c = make(close: () async => throw StateError('boom'));
      await c.onSignal(ProcessSignal.sigterm);
      expect(exits, [1]);
      expect(reports.single, contains('boom'));
    });

    test('a close that throws synchronously is handled too', () async {
      final c = make(close: () => throw StateError('sync'));
      await c.quit();
      expect(exits, [1]);
      expect(reports.single, contains('sync'));
    });

    test('the error is reported once even if several paths wait on it', () async {
      final c = make(close: () async => throw StateError('once'));
      await Future.wait([c.onExitRequested(), c.onSignal(ProcessSignal.sigint), c.quit()]);
      expect(reports, hasLength(1));
    });
  });

  group('signals', () {
    test('SIGINT and SIGTERM from the injected sources close once and exit with 130 and 143', () async {
      final sources = {for (final s in ExitCoordinator.defaultSignals) s: StreamController<ProcessSignal>()};
      final c = make(sources: sources);
      expect(c.installSignals(), ExitCoordinator.defaultSignals);
      sources[ProcessSignal.sigint]!.add(ProcessSignal.sigint);
      await pumpEventQueue();
      expect(exits, [130]);
      expect(events, ['close', 'exit']);
      sources[ProcessSignal.sigterm]!.add(ProcessSignal.sigterm);
      await pumpEventQueue();
      expect(exits, [130, 143]);
      expect(c.closeCalls, 1);
      await c.dispose();
    });

    test('a platform that cannot watch a signal is skipped, the others still work', () async {
      final sigint = StreamController<ProcessSignal>();
      final c = make(watch: (s) {
        if (s == ProcessSignal.sigterm) throw const SignalException('unsupported');
        return sigint.stream;
      });
      expect(c.installSignals(), [ProcessSignal.sigint]);
      sigint.add(ProcessSignal.sigint);
      await pumpEventQueue();
      expect(exits, [130]);
    });

    test('UnsupportedError from watch is skipped too', () {
      final c = make(watch: (s) => throw UnsupportedError('no signals here'));
      expect(c.installSignals(), isEmpty);
    });

    test('a signal stream that errors is dropped without taking the app down', () async {
      final sigterm = StreamController<ProcessSignal>();
      final c = make(watch: (s) => s == ProcessSignal.sigterm ? sigterm.stream : const Stream.empty());
      c.installSignals();
      sigterm.addError(const SignalException('gone'));
      await pumpEventQueue();
      expect(c.watched, isNot(contains(ProcessSignal.sigterm)));
      expect(exits, isEmpty);
    });

    test('after dispose, signals no longer do anything', () async {
      final sources = {for (final s in ExitCoordinator.defaultSignals) s: StreamController<ProcessSignal>()};
      final c = make(sources: sources);
      c.installSignals();
      await c.dispose();
      expect(sources[ProcessSignal.sigint]!.hasListener, isFalse);
      expect(c.closeCalls, 0);
    });

    test('exit codes follow the shell convention', () {
      expect(ExitCoordinator.exitCodeFor(ProcessSignal.sigint), 130);
      expect(ExitCoordinator.exitCodeFor(ProcessSignal.sigterm), 143);
      expect(ExitCoordinator.exitCodeFor(ProcessSignal.sighup), 1);
    });
  });

  group('lifecycle and quit', () {
    test('detach closes but does not end the process', () async {
      final c = make();
      await c.onDetach();
      expect(events, ['close']);
      expect(exits, isEmpty);
    });

    test('quit closes then exits 0', () async {
      final c = make();
      await c.quit();
      expect(events, ['close', 'exit']);
      expect(exits, [0]);
    });
  });
}
