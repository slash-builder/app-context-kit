/// Widget-test helpers for apps built on the App Context Kit.
///
/// Import `package:app_context_kit_flutter/testing.dart` from `test/` only: it depends on `flutter_test`.
///
/// `AppContext.open` does real file I/O and starts real timers, which a `testWidgets` body (running in fake async) cannot
/// await. These helpers do that work inside `tester.runAsync`, in a throwaway scratch directory, in mock mode, without a
/// roster entry, and clean up afterwards, so a test is just:
///
/// ```dart
/// testWidgets('counts', (tester) async {
///   final kit = await pumpKitApp(tester, manifest: File('app.json').readAsStringSync(), app: (ctx) => const MyApp());
///   ...
///   await kit.relaunch(); // quit and start again on the same files
/// });
/// ```
library;

import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'src/app_context_kit.dart';

/// An [AppContext] opened for a test, plus what a "quit and relaunch" test needs: the same scratch directory, a way to close
/// the context, and a way to open another one on it. Made by [testAppContext] or [pumpKitApp].
class KitTestContext {
  KitTestContext._(this.tester, this.manifest, this.scratch, this._env, this._ownsScratch, this._announce, this._heartbeat,
      this._platform, this._fakeCapacity, this._transport);

  /// The tester this context belongs to; used to run the real file I/O under `runAsync`.
  final WidgetTester tester;
  /// The manifest every context opened by this helper uses.
  final AppManifest manifest;

  /// The directory every app directory lives under (`APP_CONTEXT_SCRATCH`). Survives [close] and [reopen]; deleted at the end of the
  /// test when the helper created it.
  final Directory scratch;

  final Map<String, String> _env;
  final bool _ownsScratch;
  final bool _announce;
  final Duration _heartbeat;
  final String? _platform;
  final int _fakeCapacity;
  final DaemonTransport? _transport;

  AppContext? _ctx;
  Widget Function(AppContext ctx)? _app;
  bool _mounted = false;

  /// The current context. After [close] it is the closed one (its files can still be inspected).
  AppContext get ctx => _ctx!;

  /// The environment the context was opened with (without the host's).
  Map<String, String> get env => Map.unmodifiable(_env);

  Future<void> _open() async {
    _ctx = await tester.runAsync(() => AppContext.open(manifest,
        env: _env,
        platform: _platform,
        announce: _announce,
        heartbeat: _heartbeat,
        fakeCapacity: _fakeCapacity,
        transport: _transport));
  }

  /// Closes the context (roster withdrawal, `onClose` hooks, Venue), as the real app does when it is told to exit.
  /// Idempotent. A failing close is thrown as `AppCloseError`.
  Future<void> close() async {
    final c = _ctx;
    if (c == null) return;
    await tester.runAsync(c.close);
  }

  /// Closes the context if it is still open, then opens a new one on the same scratch directory (so settings and data are
  /// still there). Does not touch the widget tree; use [relaunch] when an app is mounted.
  Future<AppContext> reopen() async {
    await close();
    await _open();
    return ctx;
  }

  /// Quits the way a person does: closes the context first (while the widgets are still mounted, as in the real app), then
  /// unmounts the tree.
  Future<void> quit() async {
    await close();
    if (_mounted) {
      await tester.pumpWidget(const SizedBox.shrink());
      _mounted = false;
    }
  }

  /// [quit], then a new context on the same scratch directory, then the same app builder mounted again. Returns the new context.
  Future<AppContext> relaunch() async {
    final app = _app;
    await quit();
    await _open();
    if (app != null) await mount(app);
    return ctx;
  }

  /// Mounts `app(ctx)` under an `AppContextScope`, exactly as `AppContextKit.run` does.
  Future<void> mount(Widget Function(AppContext ctx) app, {bool settle = false}) async {
    _app = app;
    await tester.pumpWidget(AppContextKit.buildRoot(ctx, app));
    _mounted = true;
    if (settle) await tester.pumpAndSettle();
  }

  Future<void> _dispose() async {
    // Best effort and synchronous-safe: the test is over, so no more awaiting under fake async.
    if (_ownsScratch && scratch.existsSync()) {
      try {
        scratch.deleteSync(recursive: true);
      } on FileSystemException {
        // a still-running writer; the OS temp directory will be cleaned eventually
      }
    }
  }
}

AppManifest _manifestOf(Object manifest) {
  if (manifest is AppManifest) return manifest;
  if (manifest is String) return AppManifest.parse(manifest);
  if (manifest is Map) return AppManifest.fromJson(manifest);
  throw ArgumentError.value(manifest, 'manifest', 'must be an AppManifest, the JSON text of app.json, or a decoded Map');
}

/// Opens an [AppContext] for a widget test: [manifest] (an `AppManifest`, the JSON text of `app.json`, or a decoded map) in a
/// fresh temporary scratch directory, with `APP_CONTEXT_MODE=mock`, no roster entry ([announce] false), via `tester.runAsync`.
///
/// [env] is added to (and may override) the isolated environment `{APP_CONTEXT_SCRATCH, APP_CONTEXT_MODE: mock, HOME}`. The host's own
/// environment is never consulted, so a developer's `APP_CONTEXT_*` variables cannot change a test. Pass [scratch] to reuse a
/// directory; it is then not deleted.
///
/// The directory is deleted when the test ends. Close the context yourself ([KitTestContext.close] or `quit`) when the test
/// is about hooks that must have run by then.
Future<KitTestContext> testAppContext(
  WidgetTester tester, {
  required Object manifest,
  Map<String, String> env = const {},
  Directory? scratch,
  bool announce = false,
  Duration heartbeat = const Duration(seconds: 5),
  String? platform,
  int fakeCapacity = 1,
  DaemonTransport? transport,
}) async {
  final dir = scratch ?? Directory.systemTemp.createTempSync('app-context-test-');
  final fullEnv = <String, String>{'APP_CONTEXT_SCRATCH': dir.path, 'APP_CONTEXT_MODE': 'mock', 'HOME': dir.path, ...env};
  final kit = KitTestContext._(
      tester, _manifestOf(manifest), dir, fullEnv, scratch == null, announce, heartbeat, platform, fakeCapacity, transport);
  addTearDown(kit._dispose);
  await kit._open();
  return kit;
}

/// [testAppContext] plus mounting: pumps `app(ctx)` under an `AppContextScope` (what `AppContextKit.run` mounts) and returns the
/// handle. Set [settle] to also `pumpAndSettle`.
Future<KitTestContext> pumpKitApp(
  WidgetTester tester, {
  required Object manifest,
  required Widget Function(AppContext ctx) app,
  Map<String, String> env = const {},
  Directory? scratch,
  bool announce = false,
  Duration heartbeat = const Duration(seconds: 5),
  String? platform,
  int fakeCapacity = 1,
  DaemonTransport? transport,
  bool settle = false,
}) async {
  final kit = await testAppContext(tester,
      manifest: manifest,
      env: env,
      scratch: scratch,
      announce: announce,
      heartbeat: heartbeat,
      platform: platform,
      fakeCapacity: fakeCapacity,
      transport: transport);
  await kit.mount(app, settle: settle);
  return kit;
}
