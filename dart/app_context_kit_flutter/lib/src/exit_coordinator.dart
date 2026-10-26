import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

/// Gives a stream of one signal. The default is `ProcessSignal.watch`; tests pass their own.
typedef SignalWatcher = Stream<ProcessSignal> Function(ProcessSignal signal);

/// Funnels every way an app can be told to end (window close or quit through the Flutter lifecycle, SIGINT, SIGTERM, an
/// in-app quit) into ONE shutdown that calls `AppContext.close()` at most once.
///
/// Why this exists: `AppContext.run` closes when its body returns, but `runApp` returns at once and the OS ends a desktop app,
/// so without this the roster withdrawal, the `onClose` hooks and the Venue close never run.
///
/// Rules it keeps:
///  * [close] is called at most once, however many exit paths fire and in whatever order.
///  * Nothing exits before the close has completed (the lifecycle path returns its [AppExitResponse] only afterwards; the
///    signal and [quit] paths call [exitProcess] only afterwards).
///  * A failing close never blocks the exit: the error is handed to [report] (stderr by default) and the exit goes ahead.
///    `AppCloseError` carries every failed step, so it is printed whole.
///
/// There is deliberately no timeout and no "second Ctrl-C forces it": a close that hangs is a bug in an `onClose` hook, and
/// two signals can legitimately arrive together (a terminal and its parent process both forwarding one Ctrl-C). `SIGKILL`
/// remains the escape.
///
/// The coordinator touches neither a window nor the engine, so it is fully testable: inject [close], [exitProcess], [report]
/// and [watch].
class ExitCoordinator {
  /// [close] is what a shutdown runs (normally `ctx.close`). [exitProcess] ends the process (default: `exit`), [report] receives
  /// the message when a close fails (default: stderr), and [watch] gives the stream for one signal (default: `ProcessSignal.watch`).
  /// [signals] are the ones [installSignals] listens to.
  ExitCoordinator({
    required Future<void> Function() close,
    void Function(int code)? exitProcess,
    void Function(String message)? report,
    SignalWatcher? watch,
    this.signals = defaultSignals,
  })  : _close = close,
        _exitProcess = exitProcess ?? exit,
        _report = report ?? _toStderr,
        _watch = watch ?? _defaultWatch;

  /// The signals this coordinator listens to once [installSignals] is called.
  final List<ProcessSignal> signals;

  /// The usual pair for a desktop app.
  static const defaultSignals = [ProcessSignal.sigint, ProcessSignal.sigterm];

  final Future<void> Function() _close;
  final void Function(int code) _exitProcess;
  final void Function(String message) _report;
  final SignalWatcher _watch;
  final _subscriptions = <StreamSubscription<ProcessSignal>>[];
  Future<bool>? _shutdown;
  var _closeCalls = 0;

  /// How many times [close] was invoked. Always 0 or 1; exposed so a test can say so.
  int get closeCalls => _closeCalls;

  /// True once a shutdown has started.
  bool get isShuttingDown => _shutdown != null;

  /// The signals that are actually being watched (those a platform refused are not in here).
  final watched = <ProcessSignal>[];

  static void _toStderr(String message) => stderr.writeln(message);
  static Stream<ProcessSignal> _defaultWatch(ProcessSignal s) => s.watch();

  /// Runs the shutdown once; every caller gets the same future. Completes with whether the close succeeded. Never throws.
  Future<bool> shutdown() => _shutdown ??= _runShutdown();

  Future<bool> _runShutdown() async {
    _closeCalls++;
    try {
      await _close();
      return true;
    } catch (error) {
      _report('app_context_kit: closing the app failed: $error');
      return false;
    }
  }

  /// The `AppLifecycleListener.onExitRequested` handler: closes, then agrees to exit.
  Future<AppExitResponse> onExitRequested() async {
    await shutdown();
    return AppExitResponse.exit;
  }

  /// The `AppLifecycleListener.onDetach` handler (the only exit signal mobile platforms give). Closes; does not exit.
  Future<void> onDetach() async {
    await shutdown();
  }

  /// A signal arrived: close, then end the process with the conventional code (128 + the signal number), or 1 if the close failed.
  Future<void> onSignal(ProcessSignal signal) async {
    final ok = await shutdown();
    _exitProcess(ok ? exitCodeFor(signal) : 1);
  }

  /// Quit from inside the app (a Quit menu item or button): close, then end the process with code 0 (1 if the close failed).
  Future<void> quit() async {
    final ok = await shutdown();
    _exitProcess(ok ? 0 : 1);
  }

  /// 130 for SIGINT, 143 for SIGTERM, 1 for anything else.
  static int exitCodeFor(ProcessSignal signal) {
    if (signal == ProcessSignal.sigint) return 130;
    if (signal == ProcessSignal.sigterm) return 143;
    return 1;
  }

  /// Starts listening to [signals]. A platform that cannot watch a signal (Windows has no SIGTERM; some embedders have none)
  /// is skipped, not fatal. Returns the signals that are being watched.
  List<ProcessSignal> installSignals() {
    for (final signal in signals) {
      try {
        final sub = _watch(signal).listen(
          (s) => unawaited(onSignal(s)),
          // An error on the stream means the platform cannot deliver this signal: drop it, keep the others.
          onError: (Object _) => watched.remove(signal),
          cancelOnError: true,
        );
        _subscriptions.add(sub);
        watched.add(signal);
      } on SignalException {
        // unsupported here
      } on UnsupportedError {
        // unsupported here
      }
    }
    return List.unmodifiable(watched);
  }

  /// Stops listening to signals. Does not close anything.
  Future<void> dispose() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    watched.clear();
  }
}
