# app_context_kit_flutter

The Flutter companion to `app_context_kit` (spec section 5 item 10). The core package is pure Dart on
purpose, so everything a Flutter app needs that the core cannot do lives here. Plain Material, no design-system dependency.

## What it replaces

All six demo apps wrote the same hand-written shims (each kept its copy under `lib/kit_gaps/`):

| Hand-written in the apps | Now |
|---|---|
| `app_exit.dart` / `close_on_exit.dart` (20 to 56 lines): close the context when the window closes, on Quit, on SIGINT/SIGTERM | `AppContextKit.run` and `ExitCoordinator` |
| `manifest_asset.dart`: read `app.json` from the asset bundle | `AppContextKit.loadManifest` (done by `AppContextKit.run`) |
| the "mock + scratch" chip (3 apps) | `ModeBadge` |
| the notice banner for damaged settings or Venue problems (5 apps) | `NotesBanner` over `ctx.notes` |
| widget-test plumbing: `tester.runAsync`, `announce: false`, temp scratch, relaunch | `package:app_context_kit_flutter/testing.dart` |

## A `main.dart`

```dart
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'src/my_app.dart';

Future<void> main() => AppContextKit.run(
      manifestAsset: 'app.json', // declare it under `flutter: assets:` in pubspec.yaml
      app: (ctx) => MyApp(ctx: ctx), // or read it below with AppContextScope.of(context)
    );
```

`AppContextKit.run` ensures the binding, loads and parses the manifest, opens the `AppContext`, mounts an `AppContextScope` above your
app, and sends window close, Quit, SIGINT and SIGTERM through one `ExitCoordinator` that calls `ctx.close()` once and only then lets
the process end (a failed close is written to stderr, not swallowed, and does not block the exit). If the manifest cannot be loaded
or the context cannot open (for example Venue mode `on` with no token) it shows a small error screen with the error code and what
to do. `AppContextKit.quit()` is the in-app Quit button.

In the widget tree: `ModeBadge.forContext(ctx)` (nothing in real mode; "mock", "scratch" or "mock + scratch" otherwise) and
`NotesBanner.forContext(ctx)` (warnings and errors, each with an icon, a visible word and a semantics label; info notes hidden
unless `showInfo: true`; `dismissible: true` adds a close button). `ctx.notes` is a plain list that notifies nobody, so rebuild the
banner after adding a note.

### Tests

```dart
final kit = await pumpKitApp(tester, manifest: File('app.json').readAsStringSync(), app: (ctx) => const MyApp());
// ... drive the UI ...
await kit.relaunch(); // closes the context (onClose hooks run), reopens on the same scratch dir, mounts again
```

`testAppContext` / `pumpKitApp` make a temp scratch directory, set `APP_CONTEXT_MODE=mock`, open with `announce: false` inside
`tester.runAsync`, never read the host's environment, and delete the directory when the test ends.
`KitTestContext.close`, `reopen`, `quit` and `relaunch` cover "quit and relaunch" tests.

## What it deliberately does not do

* **No window title, bundle id or version sync.** Identity is declared in `app.json`, `pubspec.yaml`, the macOS runner and the Linux
  runner, and the runners are native build files that a running Dart app cannot change. Checking that they agree is cheap, so
  `tool/check_identity.dart` does it instead:

  ```
  dart tool/check_identity.dart <app dir> [<app dir> ...]
  ```

  It compares `app.json` `id` with the macOS `PRODUCT_BUNDLE_IDENTIFIER` and the Linux `APPLICATION_ID`, `version` with the
  `pubspec.yaml` version (ignoring `+build`), and `name` with the macOS `PRODUCT_NAME` and the Linux window title (a difference
  only in letter case is a note, not a failure). Exit 1 on any mismatch, so it can sit in CI. It does not check Windows, Android or
  iOS. It reports; it never edits.
* **No mobile exit story.** Window close, Quit and signals are desktop events. On mobile the only hook is `onDetach`, which closes
  best-effort; there is no guarantee the OS gives it time.
* **No force-exit on a second signal and no close timeout.** A hung `onClose` hook is a bug to fix; `SIGKILL` is the escape.
* **No state management, routing or theming**, and nothing that interprets an app's payload.
* **No window-level test.** The exit paths are tested through injected sources; a real window close needs a built app.
