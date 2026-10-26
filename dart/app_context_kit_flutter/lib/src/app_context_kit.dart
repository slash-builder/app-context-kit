import 'dart:async';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter/widgets.dart';

import 'app_context_scope.dart';
import 'exit_coordinator.dart';
import 'startup_error.dart';
import 'startup_error_screen.dart';

/// What [AppContextKit.run] set up. An app never needs this; tests do.
class AppContextKitSession {
  AppContextKitSession._({this.ctx, this.error, this.exit, AppLifecycleListener? listener}) : _listener = listener;

  /// The open context, or null when the app could not start.
  final AppContext? ctx;

  /// Why the app could not start (the error screen is showing), or null when it started.
  final AppContextKitStartupError? error;

  /// The single exit path, or null when the app could not start.
  final ExitCoordinator? exit;

  final AppLifecycleListener? _listener;
  var _disposed = false;

  /// Stops listening to the lifecycle and to signals. Does not close the context. Safe to call twice.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _listener?.dispose();
    await exit?.dispose();
  }
}

/// Everything a Flutter app needs around an `AppContext` that the pure-Dart core cannot do: find the manifest in the asset
/// bundle, mount the context, and make sure it is closed once however the app ends.
abstract final class AppContextKit {
  static AppContextKitSession? _session;

  /// Starts the app. Replaces the hand-written `main()` plumbing:
  ///
  /// ```dart
  /// Future<void> main() => AppContextKit.run(
  ///       manifestAsset: 'app.json',
  ///       app: (ctx) => const MyApp(),
  ///     );
  /// ```
  ///
  /// It ensures the binding, loads and parses [manifestAsset] (declare it under `flutter: assets:` in the pubspec), opens the
  /// [AppContext], and runs [app]'s widget under an [AppContextScope]. It closes the context exactly once when the window is
  /// closed, the app is quit, or SIGINT or SIGTERM arrives, and only then lets the process end.
  ///
  /// If the manifest cannot be loaded or parsed, or the context cannot open (for example Venue mode `on` with no token), a
  /// [StartupErrorScreen] naming the error code is shown instead of crashing.
  ///
  /// [env], [platform], [home], [transport], [announce], [heartbeat] and [fakeCapacity] are passed to `AppContext.open`.
  /// [bundle] defaults to `rootBundle`. [handleSignals], [exitProcess] and [report] exist for tests: whether to watch SIGINT
  /// and SIGTERM, what ends the process, and where close errors are written (stderr).
  static Future<AppContextKitSession> run({
    required String manifestAsset,
    required Widget Function(AppContext ctx) app,
    Map<String, String>? env,
    String? platform,
    String? home,
    DaemonTransport? transport,
    bool announce = true,
    Duration heartbeat = const Duration(seconds: 5),
    int fakeCapacity = 1,
    AssetBundle? bundle,
    bool handleSignals = true,
    void Function(int code)? exitProcess,
    void Function(String message)? report,
    String errorTitle = 'This app could not start',
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    await _session?.dispose();
    _session = null;

    final AppContext ctx;
    try {
      ctx = await openContext(
        manifestAsset: manifestAsset,
        bundle: bundle,
        env: env,
        platform: platform,
        home: home,
        transport: transport,
        announce: announce,
        heartbeat: heartbeat,
        fakeCapacity: fakeCapacity,
      );
    } on AppContextKitStartupError catch (e) {
      runApp(StartupErrorScreen(error: e, title: errorTitle));
      return _session = AppContextKitSession._(error: e);
    }

    final Widget root;
    try {
      root = buildRoot(ctx, app);
    } catch (e) {
      // The app's own builder threw: do not leave the roster entry behind.
      try {
        await ctx.close();
      } catch (closeError) {
        (report ?? (m) => debugPrint(m))('app_context_kit: closing the app failed: $closeError');
      }
      final err = AppContextKitStartupError(
        code: 'app-build-failed',
        message: 'The app threw while building its first screen: $e',
        hint: 'This is a bug in the app. Run it from a terminal to see the stack trace, then report it.',
        cause: e,
      );
      runApp(StartupErrorScreen(error: err, title: errorTitle));
      return _session = AppContextKitSession._(error: err);
    }

    final exit = ExitCoordinator(close: ctx.close, exitProcess: exitProcess, report: report);
    final listener = AppLifecycleListener(onExitRequested: exit.onExitRequested, onDetach: exit.onDetach);
    if (handleSignals) exit.installSignals();
    runApp(root);
    return _session = AppContextKitSession._(ctx: ctx, exit: exit, listener: listener);
  }

  /// Quits from inside the running app (a Quit menu item or button): closes the context once, then ends the process.
  /// Does nothing if [run] has not started an app.
  static Future<void> quit() async => _session?.exit?.quit();

  /// Loads and parses the manifest from [asset] in [bundle] (default `rootBundle`).
  /// Throws [AppContextKitStartupError] with code `manifest-asset-missing` or the manifest's own code.
  static Future<AppManifest> loadManifest(String asset, {AssetBundle? bundle}) async {
    final String text;
    try {
      text = await (bundle ?? rootBundle).loadString(asset);
    } catch (e) {
      throw AppContextKitStartupError(
        code: 'manifest-asset-missing',
        message: 'The manifest "$asset" could not be loaded from the app\'s assets.',
        hint: 'Add "$asset" to the pubspec under "flutter: assets:" and rebuild.',
        cause: e,
      );
    }
    try {
      return AppManifest.parse(text);
    } catch (e) {
      throw AppContextKitStartupError.from(e, manifestAsset: asset);
    }
  }

  /// [loadManifest] then `AppContext.open`. Every failure is an [AppContextKitStartupError]. This is the first half of [run], on its
  /// own, for callers (and tests) that want the context without the lifecycle wiring.
  static Future<AppContext> openContext({
    required String manifestAsset,
    AssetBundle? bundle,
    Map<String, String>? env,
    String? platform,
    String? home,
    DaemonTransport? transport,
    bool announce = true,
    Duration heartbeat = const Duration(seconds: 5),
    int fakeCapacity = 1,
  }) async {
    final manifest = await loadManifest(manifestAsset, bundle: bundle);
    try {
      return await AppContext.open(manifest,
          env: env, platform: platform, home: home, transport: transport, announce: announce, heartbeat: heartbeat, fakeCapacity: fakeCapacity);
    } catch (e) {
      throw AppContextKitStartupError.from(e, manifestAsset: manifestAsset);
    }
  }

  /// The widget tree [run] mounts: [AppContextScope] above `app(ctx)`.
  static Widget buildRoot(AppContext ctx, Widget Function(AppContext ctx) app) => AppContextScope(ctx: ctx, child: app(ctx));
}
