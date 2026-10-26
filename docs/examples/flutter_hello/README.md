# flutter_hello (package name: hello)

A small Flutter desktop app on the App Context Kit: a button that counts taps, saves the count as a setting and writes it to a file under the data directory. It is the app built step by step in [Getting started](../../GETTING-STARTED.md).

This directory holds the Dart code, the manifest and a widget test. It has no platform runner folders (`macos/`, `linux/`, `windows/`). The test needs none:

```sh
flutter pub get
flutter test
```

Expected: `All tests passed!` (one test).

To run it as a desktop app, generate the runners once, then run:

```sh
flutter create --platforms=macos,linux,windows --project-name hello --org dev.example .
flutter run -d macos     # or -d linux, -d windows
```

`flutter create .` leaves `lib/main.dart`, `pubspec.yaml` and `test/hello_test.dart` as they are, but it adds the template's `test/widget_test.dart`, which does not fit this app: delete it. On macOS the generated runner is sandboxed; see [the macOS note](../../GETTING-STARTED.md#macos-sandbox) in the guide before pointing `APP_CONTEXT_SCRATCH` anywhere.
