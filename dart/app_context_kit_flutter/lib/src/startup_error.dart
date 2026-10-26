import 'dart:io' show FileSystemException;

import 'package:app_context_kit/app_context_kit.dart';

/// Why an app could not start, in a form the error screen can show: a stable [code], what happened and what to do about it.
class AppContextKitStartupError implements Exception {
  const AppContextKitStartupError({required this.code, required this.message, required this.hint, this.cause});

  /// A stable short code: a manifest code (`bad-id`, `not-json`...), a resolution code (`missing-env`, `bad-mode`), or one of
  /// `manifest-asset-missing`, `venue-required`, `open-failed`, `app-build-failed`.
  final String code;

  /// One plain sentence on what went wrong.
  final String message;

  /// What the person (or the developer) should do next.
  final String hint;

  /// The original exception, if there was one.
  final Object? cause;

  /// Sorts any error thrown while loading the manifest or opening the context into an [AppContextKitStartupError].
  /// [manifestAsset] names the asset in the messages.
  static AppContextKitStartupError from(Object error, {String manifestAsset = 'app.json'}) {
    if (error is AppContextKitStartupError) return error;
    if (error is ManifestError) {
      return AppContextKitStartupError(
        code: error.code,
        message: 'The manifest "$manifestAsset" is not valid: ${_manifestReason(error.code)}.',
        hint: 'Fix "$manifestAsset" in the app source (see spec/APP-CONTEXT.md section 1) and rebuild.',
        cause: error,
      );
    }
    if (error is ResolveError) {
      switch (error.code) {
        case 'bad-mode':
          return AppContextKitStartupError(
            code: 'bad-mode',
            message: 'The mode set in the environment is not "real" or "mock".',
            hint: 'Set APP_CONTEXT_MODE (and the app\'s own <PREFIX>_MODE) to "real" or "mock", or unset it.',
            cause: error,
          );
        case 'missing-env':
          return AppContextKitStartupError(
            code: 'missing-env',
            message: 'A folder the app needs could not be worked out because an environment variable is missing.',
            hint: 'On Windows LOCALAPPDATA and APPDATA must be set; or set APP_CONTEXT_SCRATCH to use a scratch folder.',
            cause: error,
          );
      }
    }
    if (error is VenueUnavailable) {
      return AppContextKitStartupError(
        code: 'venue-required',
        message: error.reason,
        hint: 'This app requires Venue. Provide a token (VENUE_TOKEN, VENUE_TOKEN_FILE or <config>/venue-token) and start the '
            'Venue daemon, or run with APP_CONTEXT_MODE=mock.',
        cause: error,
      );
    }
    if (error is FileSystemException) {
      return AppContextKitStartupError(
        code: 'open-failed',
        message: 'The app\'s folders could not be created or read: ${error.message} (${error.path ?? 'no path'}).',
        hint: 'Check the folder exists and the app may write to it, or point APP_CONTEXT_SCRATCH at a writable folder.',
        cause: error,
      );
    }
    return AppContextKitStartupError(
      code: 'open-failed',
      message: 'The app could not start: $error',
      hint: 'Run the app from a terminal to see the full error, then report it.',
      cause: error,
    );
  }

  static String _manifestReason(String code) => switch (code) {
        'not-json' => 'the file is not JSON',
        'not-object' => 'the JSON is not an object',
        'bad-id' => '"id" is missing or not a reverse-DNS id such as dev.example.app',
        'bad-name' => '"name" is missing or blank',
        'bad-version' => '"version" is missing or not like 1.2.3',
        'bad-kits' => '"kits" is not a list of kit names',
        'duplicate-kit' => '"kits" names the same kit twice',
        'bad-prefix' => '"envPrefix" is not UPPER_SNAKE_CASE',
        'bad-venue' => '"venue" is malformed (mode must be auto, on or off)',
        _ => 'it was refused with code $code',
      };

  @override
  String toString() => 'AppContextKitStartupError($code: $message)';
}
