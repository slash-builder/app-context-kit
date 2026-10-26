# Getting started

This guide takes you from an empty folder to a Flutter desktop app that runs on the App Context Kit, then shows the same thing in plain Dart and in Rust. For what the Kit is, read the [overview](OVERVIEW.md). For every field and rule, see the [context guide](CONTEXT-GUIDE.md).

The app you build is a window with a button. Each tap is counted, saved as a setting and written to a file. The finished project is in [`docs/examples/flutter_hello/`](examples/flutter_hello). Every code block below is a file from that directory, or a file from `docs/examples/dart_cli/` or `docs/examples/rust_cli/`.

You need Flutter 3.24 or later with desktop support enabled. The steps were walked through with Flutter 3.41.9 and Dart 3.11.5 on macOS. The demo apps built on the Kit were also built in release mode and launched on Linux, headless in a container (see [Platforms](PLATFORMS.md#linux)). Where a step differs on Linux or Windows and was not run there, the text says so.

## 1. Create the project

The app id you choose in `app.json` should match the bundle id Flutter generates, so create the project with a package name and organisation that join up. Package `hello` with organisation `dev.example` gives the id `dev.example.hello`:

```sh
flutter create --platforms=macos,linux,windows --org dev.example hello
cd hello
rm test/widget_test.dart   # the template's counter test; it does not fit this app
```

## 2. Add the dependencies

The two Kit packages are not published. They are `publish_to: none`, so you point at them by path or by git.

**By path** (what the demo apps use). Check out the App Context Kit repository somewhere and point at it. Add to `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  app_context_kit:
    path: ../app-context-kit/dart/app_context_kit
  app_context_kit_flutter:
    path: ../app-context-kit/dart/app_context_kit_flutter
```

Adjust the relative path to wherever your checkout is. List both packages: `app_context_kit_flutter` depends on `app_context_kit`, and your code imports both.

**By git**, once the App Context Kit repository is reachable by URL. Pin both entries to the same full 40-character commit hash in `ref`:

```yaml
  app_context_kit:
    git:
      url: <repository-url>
      path: dart/app_context_kit
      ref: <full-commit-sha>
  app_context_kit_flutter:
    git:
      url: <repository-url>
      path: dart/app_context_kit_flutter
      ref: <full-commit-sha>
```

This form was tested against a local clone of the App Context Kit repository. With the default branch instead of a pinned hash, or with an abbreviated hash, `pub get` failed with a version-solving error, because the companion's own dependency on the core resolved to a different reference than yours. I have not tested it against a public URL, because there is none yet.

Then declare the manifest as an asset, and make the `pubspec.yaml` version match the manifest:

```yaml
version: 0.1.0+1

flutter:
  uses-material-design: true
  assets:
    - app.json
```

The template's version is `1.0.0+1`. The Kit does not read the `pubspec.yaml`, but `app.json` and the `pubspec.yaml` should say the same thing, and the check in [step 9](#9-check-that-the-identity-agrees) fails if they do not.

## 3. Write `app.json`

Create `app.json` next to `pubspec.yaml`. This is [`docs/examples/flutter_hello/app.json`](examples/flutter_hello/app.json):

```json
{
  "id": "dev.example.hello",
  "name": "Hello",
  "version": "0.1.0",
  "kits": [],
  "envPrefix": "HELLO",
  "venue": { "mode": "off" }
}
```

| Field | Required | What it is | Default |
|---|---|---|---|
| `id` | yes | Reverse-DNS id under a domain you control (the examples use `com.slashbuilder.demo.*`), at least two dot-separated segments. Each segment starts with a lower-case letter and then has lower-case letters, digits or `-`. It names your directories and your roster entry. | none |
| `name` | yes | Display name. Must not be blank. | none |
| `version` | yes | `MAJOR.MINOR.PATCH`, digits only. A pre-release suffix such as `-beta` is refused. | none |
| `kits` | no | List of lower-case kit names, no duplicates. Today only `"peers"` has an effect: it allows `ctx.startPeers` and `ctx.peerHub`. Other names are accepted and ignored. | `[]` |
| `envPrefix` | no | `UPPER_SNAKE_CASE` prefix for this app's environment variables (`HELLO_MODE`, `HELLO_DATA_DIR`). | the last segment of `id`, upper-cased, with anything outside `A-Z0-9` replaced by `_` (`render-queue` becomes `RENDER_QUEUE`) |
| `venue.mode` | no | `auto`, `on` or `off`. See [Venue](#7-venue-and-the-default). | `auto` |
| `venue.consumer` | no | The name this app presents to Venue. Lower-case letters, digits and `-`, starting with a letter. | the last segment of `id` |

If the manifest is wrong, the app shows an error screen with a code such as `bad-id`. The [context guide](CONTEXT-GUIDE.md#the-manifest) lists every code. The rules are in [spec section 1](../spec/APP-CONTEXT.md).

## 4. Write `main.dart`

Replace `lib/main.dart` with this. It is [`docs/examples/flutter_hello/lib/main.dart`](examples/flutter_hello/lib/main.dart), and apart from the import it is the same line as the calculator demo app's `lib/main.dart` (the demo apps are in The Kit Book):

```dart
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';

import 'hello_app.dart';

Future<void> main() => AppContextKit.run(manifestAsset: 'app.json', app: (_) => const HelloApp());
```

`AppContextKit.run` does the work a hand-written `main()` would: it initialises Flutter's binding, loads and validates `app.json` from the asset bundle, opens the `AppContext`, mounts an `AppContextScope` above your widget, and makes window close, Quit, SIGINT and SIGTERM all close the context exactly once before the process ends. If it cannot start, it shows an error screen instead of crashing.

## 5. Read the context, save a setting, write a file

Create `lib/hello_app.dart`. This is [`docs/examples/flutter_hello/lib/hello_app.dart`](examples/flutter_hello/lib/hello_app.dart):

```dart
import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:flutter/material.dart';

class HelloApp extends StatefulWidget {
  const HelloApp({super.key});

  @override
  State<HelloApp> createState() => _HelloAppState();
}

class _HelloAppState extends State<HelloApp> {
  late final AppContext ctx;
  late final SessionSettings settings;
  late int taps;
  var _started = false;

  // An InheritedWidget cannot be read in initState, so read the context on the first didChangeDependencies.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    ctx = AppContextScope.of(context);
    settings = SessionSettings(ctx.config);
    taps = settings.get<int>('taps', 0);
  }

  void _tap() {
    setState(() => taps++);
    settings.set('taps', taps); // a setting, in <config>/config.json
    ctx.dataFile('taps.log').writeAsStringSync('$taps\n'); // a file, under <data>
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: ctx.manifest.name,
        home: Scaffold(
          appBar: AppBar(title: Text(ctx.manifest.name), actions: [ModeBadge.forContext(ctx)]),
          body: Column(children: [
            NotesBanner.forContext(ctx),
            Text('Taps: $taps'),
            FilledButton(onPressed: _tap, child: const Text('Tap')),
          ]),
        ),
      );
}
```

What this uses:

- **`AppContextScope.of(context)`** returns the `AppContext` that `AppContextKit.run` mounted. It throws a `FlutterError` that says how to fix it if there is no scope above the widget. There is also `maybeOf`, which returns `null`.
- **`ctx.manifest`** is the parsed `app.json`.
- **A setting.** `ctx.config` is a `ConfigStore` over `<config>/config.json`. `ctx.config.set('taps', 3)` saves at once, atomically. If `config.json` is damaged, `set` throws `DamagedConfigError` rather than overwrite a file it could not read. This example wraps the store in `SessionSettings`, whose `set` never throws: while the file is damaged it keeps the change in memory for the session, and `settings.readOnly` tells you so. See [settings](CONTEXT-GUIDE.md#the-config-store).
- **A file under data.** `ctx.dataFile('taps.log')` is a `File` under `ctx.dirs.data`. The directory already exists. For a JSON file with an atomic write and a read that tells "missing" from "damaged", use `ctx.dataJson('name.json')`.
- **`ModeBadge.forContext(ctx)`** shows nothing in a normal run and a chip reading `mock`, `scratch` or `mock + scratch` otherwise.
- **`NotesBanner.forContext(ctx)`** shows warnings and errors the Kit recorded in `ctx.notes`, such as a damaged settings file. It hides information-level notes.

`ctx.notes` is a plain list that notifies nobody. If your app adds a note, rebuild the banner yourself.

## 6. Run it

```sh
flutter run -d macos     # or -d linux, -d windows
```

On macOS the app wrote its folders here (checked by running a fresh project built as above):

| Kind | Where on macOS |
|---|---|
| data | `~/Library/Application Support/dev.example.hello/data` |
| config | `~/Library/Preferences/dev.example.hello` |
| state | `~/Library/Application Support/dev.example.hello/state` |
| cache | `~/Library/Caches/dev.example.hello` |

`flutter create` turns the macOS App Sandbox on, so the `~` above is the app's container, `~/Library/Containers/dev.example.hello/Data`. See [the macOS sandbox](#macos-sandbox). The [context guide](CONTEXT-GUIDE.md#directories) has the table for Linux and Windows.

### Scratch and mock

Two environment variables let you run the app without touching real data:

- `APP_CONTEXT_SCRATCH=<folder>` puts every directory, and the roster, under that folder.
- `APP_CONTEXT_MODE=mock` swaps Venue for an in-memory fake. `HELLO_MODE=mock` does the same for this app only.

`flutter run` passes your shell's environment to the app (checked with `APP_CONTEXT_SCRATCH` on macOS). On Linux:

```sh
APP_CONTEXT_SCRATCH="$(mktemp -d)" APP_CONTEXT_MODE=mock flutter run -d linux
```

That exact command was not run on Linux (the demo apps were built there with `flutter build linux --release` and launched headless in a container; see [Platforms](PLATFORMS.md#linux)). With both variables set, the app bar shows the chip `mock + scratch`. On macOS the scratch folder has to be inside the sandbox container, so the command is different there; see [the macOS sandbox](#macos-sandbox).

## 7. Venue, and the default

Venue is a resource broker. `ctx.venue` is the one object an app uses to ask it for something. The manifest's `venue.mode` decides how the Kit opens it:

| `venue.mode` | Behaviour |
|---|---|
| `off` | Never looks for a token or a daemon. The session is local, with the description `Venue: local (Venue is off for this app)`. |
| `auto` (the default) | Looks for a token. With none, the session is local: `Venue: local (Venue not configured)`. With a token, it connects if the daemon answers; if not, it degrades to local and records a warning. |
| `on` | The app needs Venue. With no token, or no answer, opening the context fails, and the Flutter companion shows the error screen with the code `venue-required`. |

So an app does not need a Venue to run, and does not need `"mode": "off"` for that: `auto` already degrades to a local session when nothing is configured. This example sets `off` to say plainly that it does not use Venue. In a normal run the Kit records one information-level note carrying the Venue description. `NotesBanner` hides it unless you pass `showInfo: true`.

In `mock` mode the session is always the in-memory `FakeVenue`, whatever `venue.mode` says. The environment variables that configure a real Venue are in the [context guide](CONTEXT-GUIDE.md#environment-variables).

## 8. Write the first widget test

Create `test/hello_test.dart`. This is [`docs/examples/flutter_hello/test/hello_test.dart`](examples/flutter_hello/test/hello_test.dart):

```dart
import 'dart:io';

import 'package:app_context_kit_flutter/testing.dart';
import 'package:hello/hello_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('taps are saved and survive a quit and relaunch', (tester) async {
    final kit = await pumpKitApp(
      tester,
      manifest: File('app.json').readAsStringSync(),
      app: (ctx) => const HelloApp(),
    );
    expect(find.text('Taps: 0'), findsOneWidget);
    expect(find.text('mock + scratch'), findsOneWidget);

    await tester.tap(find.text('Tap'));
    await tester.pump();
    expect(find.text('Taps: 1'), findsOneWidget);
    expect(kit.ctx.dataFile('taps.log').readAsStringSync(), '1\n');

    await kit.relaunch(); // close, open again on the same scratch directory, mount again
    expect(find.text('Taps: 1'), findsOneWidget);
  });
}
```

```sh
flutter test
```

Expected: `All tests passed!`.

`pumpKitApp` makes a temporary scratch folder, sets `APP_CONTEXT_MODE=mock`, opens the context without a roster entry, mounts your widget under an `AppContextScope`, and deletes the folder when the test ends. It never reads the environment of the machine running the tests. `kit.relaunch()` closes the context, so your `onClose` hooks run, opens a new one on the same files and mounts the app again. [Testing](TESTING.md) has the rest.

## 9. Check that the identity agrees

An app's identity lives in `app.json`, in `pubspec.yaml`, in the macOS runner and in the Linux runner. The Kit cannot change native build files, so a script compares them. From a checkout of the App Context Kit repository:

```sh
cd dart/app_context_kit_flutter
dart tool/check_identity.dart /path/to/hello
```

For the project above it printed:

```
== /path/to/hello
  note      name: app.json says "Hello" but the macOS PRODUCT_NAME is "hello" (same name, different letter case)
  note      name: app.json says "Hello" but the Linux window title is "hello" (same name, different letter case)
  ok: id, name and version agree everywhere they were checked
```

With the template's `version: 1.0.0+1` it reported `MISMATCH version` and exited 1. It does not check Windows, Android or iOS, and it never edits a file.

## macOS sandbox

The macOS runner that `flutter create` generates has the App Sandbox on. Three things follow, each checked on macOS with a project built as above.

**Files go in the app's container.** Inside the sandbox, `HOME` and `TMPDIR` point into `~/Library/Containers/<bundle id>/Data`, so the default directories and the roster all land there. You do not need to do anything.

**A scratch folder must be inside the container too.** The sandbox refuses writes elsewhere. With `APP_CONTEXT_SCRATCH=/tmp/somewhere`, the app created nothing and showed its start-up error screen: "This app could not start. The app's folders could not be created or read: Creation failed (/tmp/somewhere)", with `Error code: open-failed`. A path under the container works:

```sh
APP_CONTEXT_SCRATCH="$HOME/Library/Containers/dev.example.hello/Data/tmp/scratch" flutter run -d macos
```

The container folder only exists after the app has run once.

**Network access needs an entitlement.** `flutter create` writes these files in `macos/Runner/`: `DebugProfile.entitlements` (sandbox, JIT and `network.server`) and `Release.entitlements` (sandbox only). A Venue daemon is reached over HTTP, and peers connect to each other, so an app that does either is likely to need outgoing connections allowed. Add this to both files:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

For reference, in release builds the calculator demo app (Venue off, no peers) declares the sandbox and nothing else, and the notepad demo app (peers on) declares `network.server` and `network.client`. What happens to an app that uses peers or Venue without these entitlements was not tested. Two of the demo apps, `launcher` and `render-queue`, turn the sandbox off.

## Plain Dart

The core package has no Flutter dependency, so a command-line tool or server can use it. The program is [`docs/examples/dart_cli/`](examples/dart_cli). It reads the same kind of `app.json`:

```json
{
  "id": "dev.example.hello",
  "name": "Hello",
  "version": "0.1.0",
  "envPrefix": "HELLO",
  "venue": { "mode": "off" }
}
```

`pubspec.yaml` depends on the core only:

```yaml
name: dart_cli
description: A command-line program built on the App Context Kit core. Example from docs/GETTING-STARTED.md.
publish_to: none

environment:
  sdk: ^3.0.0

dependencies:
  app_context_kit:
    path: ../../../dart/app_context_kit

dev_dependencies:
  test: ^1.24.0
```

`bin/main.dart`:

```dart
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';

Future<void> main() async {
  final manifest = AppManifest.parse(File('app.json').readAsStringSync());

  await AppContext.run(manifest, (ctx) async {
    // A setting: kept in <config>/config.json, written atomically.
    final launches = ctx.config.get<int>('launches', 0) + 1;
    ctx.config.set('launches', launches);

    // A file of the app's own: under <data>.
    ctx.dataFile('hello.txt').writeAsStringSync('launch $launches\n');

    print('app      ${ctx.manifest.id} ${ctx.manifest.version}');
    print('mode     ${ctx.mode.name}${ctx.scratch ? ' (scratch)' : ''}');
    print('data     ${ctx.dirs.data}');
    print('config   ${ctx.dirs.config}');
    print('launches $launches');
    print('venue    ${ctx.venue.description}');
  });
}
```

```sh
cd docs/examples/dart_cli
dart pub get
APP_CONTEXT_SCRATCH=/tmp/app-context-demo dart run bin/main.dart
```

```
app      dev.example.hello 0.1.0
mode     real (scratch)
data     /tmp/app-context-demo/dev.example.hello/data
config   /tmp/app-context-demo/dev.example.hello/config
launches 1
venue    Venue: local (Venue is off for this app)
```

Run it again and `launches` is 2. `AppContext.run` opens the context, runs your function and closes the context afterwards, also when your function throws. A bad manifest throws `ManifestError` with the code; a bad `HELLO_MODE` throws `ResolveError(bad-mode)`.

`AppContext.run` closes as soon as your function returns. That is right for a command-line tool. It is wrong for a Flutter app, where `runApp` returns at once, which is why Flutter apps use `AppContextKit.run`.

## Rust

The crate in `rust/` implements the same manifest, the same directory rules and the same settings file. It does not have peers, `SessionSettings`, `AppJsonFile` or a remote Venue session. The program is [`docs/examples/rust_cli/`](examples/rust_cli), with the same `app.json`.

`Cargo.toml`:

```toml
[package]
name = "rust_cli"
version = "0.1.0"
edition = "2021"
publish = false

[dependencies]
app-context-kit = { package = "slashbuilder-app-context-kit", path = "../../../rust" }
serde_json = "1"

[workspace]
```

`src/main.rs`:

```rust
use app_context_kit::{AppContext, Manifest, OpenOptions};
use serde_json::json;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest = Manifest::parse(&std::fs::read_to_string("app.json")?)?;

    AppContext::run(manifest, OpenOptions::default(), |ctx| {
        // A setting: kept in <config>/config.json, written atomically.
        let launches = ctx.config.get_or::<i64>("launches", 0) + 1;
        ctx.config.set("launches", json!(launches)).expect("settings are writable");

        // A file of the app's own: under <data>.
        std::fs::write(ctx.data_file("hello.txt"), format!("launch {launches}\n")).expect("data dir is writable");

        println!("app      {} {}", ctx.manifest.id, ctx.manifest.version);
        println!("mode     {}{}", ctx.mode().as_str(), if ctx.is_scratch() { " (scratch)" } else { "" });
        println!("data     {}", ctx.resolved.dirs.data);
        println!("config   {}", ctx.resolved.dirs.config);
        println!("launches {launches}");
        println!("venue    {}", ctx.venue.description());
    })?;
    Ok(())
}
```

```sh
cd docs/examples/rust_cli
APP_CONTEXT_SCRATCH=/tmp/app-context-demo-rs cargo run
```

It prints the same six lines as the Dart program, with `/tmp/app-context-demo-rs` in the paths.

**The Kit's Rust crate has no remote Venue session.** Its Venue sessions are `local` and `fake` only, so the last line above always reports a `local` session. A token that is found cannot connect to a daemon: with `venue.mode` `auto` the session is `local` and says so, and with `on` the context fails to open. The crate builds from the App Context Kit repository alone; its dependencies (`serde`, `serde_json` and `chrono`) come from crates.io.

## Next

- [Context guide](CONTEXT-GUIDE.md): every manifest code, directory rule, environment variable and lifecycle detail
- [Testing](TESTING.md): scratch and mock modes, the fakes, the conformance fixtures and every test suite in the App Context Kit repository
- The demo apps in The Kit Book run from a calculator (the smallest app) to a notepad (the largest: settings, files, peers and tests).
