// App start, stop and lifecycle lines for the debug log (see DebugLog in
// app_context_kit).
//
// Moved here from Courier (`lib/diagnostics/app_log.dart`, b9af9d6). Build
// info only: the short git sha, the platform and the build mode, and the app
// version when the app can supply it. Nothing about the account, the
// household or the device.
//
// Two things Courier's version did itself are now the app's to pass in: which
// log to write to (it used the global) and the app version (it called the
// `package_info_plus` plugin, which this Kit does not depend on).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_context_kit/app_context_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The app's short git sha (`--dart-define=GIT_SHA=...`; `dev` locally).
const String kBuildSha = String.fromEnvironment('GIT_SHA', defaultValue: 'dev');

String get _mode => kReleaseMode
    ? 'release'
    : kProfileMode
        ? 'profile'
        : 'debug';

/// Turn the log on or off from the saved preference, and write the start line.
/// Call once, early in `main`.
///
/// [log] is `DebugLog.instance` unless given. [appVersion] returns the
/// `1.2.3+45` style version (from `package_info_plus` or the manifest) for a
/// second line; null, or a throw, means "no platform bundle" and the start
/// line is enough.
void startDebugLog({
  required bool enabled,
  DebugLog? log,
  Future<String?> Function()? appVersion,
}) {
  final target = log ?? DebugLog.instance;
  target.enabled = enabled;
  target.event('app', 'start', fields: {
    'build': kBuildSha,
    'platform': Platform.operatingSystem,
    'mode': _mode,
  });
  if (appVersion == null) return;
  unawaited(() async {
    try {
      final v = await appVersion();
      if (v != null) target.event('app', 'version', fields: {'build': v});
    } on Object {
      // no platform bundle (tests, some desktops): the start line is enough
    }
  }());
}

/// Logs the app's lifecycle, and "stop" when it is detached. Add it with
/// `WidgetsBinding.instance.addObserver`. Writes to [sink], or to the app's
/// `DebugLog.instance` when none is given.
class AppLifecycleLog with WidgetsBindingObserver {
  AppLifecycleLog({LogSink? sink}) : _sink = sink;

  final LogSink? _sink;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    (_sink ?? DebugLog.instance).event(
      'app',
      state == AppLifecycleState.detached ? 'stop' : 'lifecycle',
      fields: {'state': state},
    );
  }
}
