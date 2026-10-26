# Context guide

Reference for the `AppContext` and everything it is built from. It describes the Dart core (`app_context_kit`) and the Flutter companion (`app_context_kit_flutter`), and says where the Rust crate differs. The contract these rules come from is [`spec/APP-CONTEXT.md`](../spec/APP-CONTEXT.md); this guide links to its sections instead of repeating them, and adds what the code does that the spec leaves open. If the guide and a fixture in `spec/conformance/` disagree, the fixture is right.

To build something, start with [Getting started](GETTING-STARTED.md).

Contents: [the manifest](#the-manifest) · [directories](#directories) · [environment variables](#environment-variables) · [modes](#modes) · [the config store](#the-config-store) · [`AppJsonFile` and `ctx.dataJson`](#appjsonfile-and-ctxdatajson) · [`SessionSettings`](#sessionsettings) · [notes](#notes) · [the Venue session](#the-venue-session) · [lifecycle](#lifecycle) · [what the Flutter companion adds](#what-the-flutter-companion-adds) · [the roster](#the-roster) · [peers](#peers) · [errors](#errors) · [the Rust crate](#the-rust-crate)

## The manifest

`app.json` is parsed by `AppManifest.parse(text)` (JSON text) or `AppManifest.fromJson(value)` (an already-decoded value). Both throw `ManifestError`, whose `code` is the **first** rule that failed, checked in the order below. A field that is present but `null` is present and invalid. Every pattern must match the whole string, so a trailing newline fails. Spec: [section 1](../spec/APP-CONTEXT.md).

| Field | Type | Rule | Default | Error code |
|---|---|---|---|---|
| (the source) | text | valid JSON (`parse` only) | | `not-json` |
| (the value) | object | a JSON object | | `not-object` |
| `id` | string, required | `^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$` | | `bad-id` |
| `name` | string, required | not empty after removing space, tab, CR and LF. Other characters, including U+FEFF, count as content | | `bad-name` |
| `version` | string, required | `^\d+\.\d+\.\d+$` (ASCII digits; no pre-release suffix) | | `bad-version` |
| `kits` | list of strings | each name matches `^[a-z][a-z0-9-]*$` | `[]` | `bad-kits` |
| `kits` | | no name twice, checked only once every name is valid | | `duplicate-kit` |
| `envPrefix` | string | `^[A-Z][A-Z0-9_]*$` | derived from `id`, see [environment variables](#environment-variables) | `bad-prefix` |
| `venue` | object | an object | `{}` | `bad-venue` |
| `venue.mode` | string | `auto`, `on` or `off` | `auto` | `bad-venue` |
| `venue.consumer` | string | `^[a-z][a-z0-9-]*$` | the last segment of `id` | `bad-venue` |

`AppManifest` exposes `id`, `name`, `version`, `kits` (unmodifiable), `envPrefix` (nullable: only what the file says) and `venue` (`VenueSettings`: `mode`, `consumer`). Unknown fields are ignored.

`kits` is checked in one place today: `ctx.peerHub` and `ctx.startPeers` throw `KitNotDeclared` unless it contains `"peers"`. A Venue session is opened whether or not `kits` lists `"venue"`.

## Directories

`resolve(manifest:, platform:, home:, env:)` is a pure function: it reads no files and touches no disk. `AppContext.open` calls it and then creates every directory with `createSync(recursive: true)`. Spec: [section 2](../spec/APP-CONTEXT.md).

`ID` is the manifest id. Paths are joined with `/` on Linux and macOS and with `\` on Windows, whatever the host is.

| Kind | Linux | macOS | Windows |
|---|---|---|---|
| `data` | `$XDG_DATA_HOME/ID`, else `~/.local/share/ID` | `~/Library/Application Support/ID/data` | `%LOCALAPPDATA%\ID\data` |
| `config` | `$XDG_CONFIG_HOME/ID`, else `~/.config/ID` | `~/Library/Preferences/ID` | `%APPDATA%\ID` |
| `state` | `$XDG_STATE_HOME/ID`, else `~/.local/state/ID` | `~/Library/Application Support/ID/state` | `%LOCALAPPDATA%\ID\state` |
| `cache` | `$XDG_CACHE_HOME/ID`, else `~/.cache/ID` | `~/Library/Caches/ID` | `%LOCALAPPDATA%\ID\cache` |
| `runtime` | `$XDG_RUNTIME_DIR/ID`; if that is unset, the default state directory plus `/run` | `$TMPDIR/ID`, else `/tmp/ID` | `%TEMP%\ID` |
| `roster` | `$XDG_RUNTIME_DIR/app-context-roster`, else `/tmp/app-context-roster` | `$TMPDIR/app-context-roster`, else `/tmp/app-context-roster` | `%TEMP%\app-context-roster` |

The roster is one directory shared by every app for the user, so it has no `ID` in its path.

A trailing separator on a base such as `TMPDIR=/var/T/` is dropped before joining, using the target platform's separators only. A base that is only a separator (`/`) is not reduced to nothing: `/` and `ID` join to `/ID`.

On Windows, a missing `LOCALAPPDATA`, `APPDATA` or `TEMP` is the error `missing-env`, but only if a default that needs it is actually used. A directory fixed by an override or by scratch needs none.

**Overrides**, highest priority first, for each of `data`, `config`, `state`, `cache` and `runtime`:

1. `<PREFIX>_<KIND>_DIR` (for example `HELLO_DATA_DIR`): used exactly as given. No id is appended and nothing is trimmed.
2. Scratch: if `APP_CONTEXT_SCRATCH=S` is set, the directory is `S/ID/<kind>` and the roster is `S/roster`. Scratch always joins with `/`, on every platform.
3. The platform default.

`APP_CONTEXT_ROSTER_DIR` overrides the roster directory and beats scratch.

`AppContext.hostPlatform()` returns `macos` on macOS, `windows` on Windows, and `linux` on every other host, including Android and iOS. The home directory is `HOME`, else `USERPROFILE`, else `/`.

## Environment variables

Every variable the Kit reads. An empty value counts as unset for all of them except `HOME` and `USERPROFILE` in the Dart core, where an empty `HOME` is used as it is (the Rust crate skips an empty one). `<PREFIX>` is `envPrefix`, or the last segment of the id upper-cased with each character outside `A-Z0-9` replaced by `_` (`com.slashbuilder.demo.render-queue` gives `RENDER_QUEUE`).

By default the Kit reads the process environment. `AppContext.open(manifest, env: {...})` replaces it with a map you supply, and then nothing from the real environment is read. That is how the tests in the App Context Kit repository stay isolated.

| Name | Meaning | Default | Example |
|---|---|---|---|
| `APP_CONTEXT_SCRATCH` | Root of a throwaway tree. Every directory becomes `<S>/<id>/<kind>` and the roster `<S>/roster` | unset | `/tmp/app-context-demo` |
| `APP_CONTEXT_MODE` | Mode for every app: `real` or `mock` | `real` | `mock` |
| `<PREFIX>_MODE` | Mode for one app. Wins over `APP_CONTEXT_MODE` | unset | `CALC_MODE=mock` |
| `<PREFIX>_DATA_DIR`, `_CONFIG_DIR`, `_STATE_DIR`, `_CACHE_DIR`, `_RUNTIME_DIR` | Exact directory for one kind. Wins over scratch | unset | `HELLO_DATA_DIR=/srv/hello` |
| `APP_CONTEXT_ROSTER_DIR` | Exact roster directory. Wins over scratch | unset | `/tmp/roster` |
| `HOME`, `USERPROFILE` | The home directory (`AppContext.open` only; `resolve` takes `home` as a parameter) | `/` | `/home/ada` |
| `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` | Base directories on Linux | `~/.local/share`, `~/.config`, `~/.local/state`, `~/.cache` | `/x/data` |
| `XDG_RUNTIME_DIR` | Runtime and roster base on Linux | see [directories](#directories) | `/run/user/1000` |
| `TMPDIR` | Runtime and roster base on macOS | `/tmp` | `/var/folders/ab/T/` |
| `LOCALAPPDATA`, `APPDATA`, `TEMP` | Windows bases. Needed only if a default that uses them is used | none (error `missing-env`) | `C:\Users\ada\AppData\Local` |
| `VENUE_DAEMON` | URL of the Venue daemon | `http://127.0.0.1:7878` | `https://venue.example:7878` |
| `VENUE_TOKEN` | The Venue token itself | unset | |
| `VENUE_TOKEN_FILE` | A file holding the token. If set, a missing, unreadable or empty file is an error and the lookup does not go on to the next source | unset | `/run/secrets/venue-token` |
| `VENUE_DAEMON_FINGERPRINT` | Pin the daemon's TLS certificate by SHA-256. Accepts `sha256:` or not, with or without colons, any case | unset (system trust) | `sha256:ab12...` (64 hex digits) |
| `APP_CONTEXT_ACCOUNT` | Account for [peers](#peers) | config `account`, else `local` | `household-1` |
| `APP_CONTEXT_DEVICE` | Device name for peers | config `device`, else generated once | `laptop` |
| `APP_CONTEXT_PEERS_DIR` | Where the loopback peers provider announces copies | the roster directory plus `-peers` | `/tmp/peers` |

The fake Venue's capacity is not an environment variable. It is the `fakeCapacity` parameter of `AppContext.open` (default 1). The Rust tests confirm that `<PREFIX>_FAKE_CAPACITY`, `APP_CONTEXT_FAKE_CAPACITY` and `VENUE_FAKE_CAPACITY` have no effect.

Token lookup, in order: `VENUE_TOKEN`; the file named by `VENUE_TOKEN_FILE`; `<config>/venue-token`. See spec [section 5, item 2](../spec/APP-CONTEXT.md).

## Modes

| Mode | Set by | Venue session | Notes |
|---|---|---|---|
| `real` | default | local, remote or none, from `venue.mode` and the token | |
| `mock` | `<PREFIX>_MODE=mock` or `APP_CONTEXT_MODE=mock` | always `FakeVenue`, whatever `venue.mode` says | peers use an in-memory fake network |

Any other value is `ResolveError('bad-mode')`. Only the variable that wins is checked: a garbage `APP_CONTEXT_MODE` is ignored when `<PREFIX>_MODE` is set. `bad-mode` is reported before `missing-env`.

**Scratch is separate from mode.** `APP_CONTEXT_SCRATCH` moves the files; `mock` swaps the services. They are independent, and tests normally set both. `ctx.mode`, `ctx.isMock` and `ctx.scratch` report what was resolved; `ModeBadge` shows it.

## The config store

`ctx.config` is a `ConfigStore` over `<config>/config.json`. It is a flat JSON object that you read and write by key.

| Member | Behaviour |
|---|---|
| `get<T>(key, fallback)` | The value if it is a `T`, otherwise `fallback`. A whole JSON number reads as `double` (`3` is `3.0`). Decoded lists are `List<dynamic>`, so `get<List<int>>` always returns the fallback; ask for `List<dynamic>` |
| `ctx.config[key]` | The raw value or `null` |
| `all` | An unmodifiable copy of every key |
| `set(key, value)` | Sets the key and saves at once. `null` removes the key. Throws `DamagedConfigError` first, changing nothing, if the file is damaged |
| `save()` | Writes the whole file. Throws `DamagedConfigError` if damaged |
| `problem`, `isDamaged` | Why the file could not be read, if it could not |
| `setAsideCorrupt()` | See below |

Writes are atomic: the content goes to `config.json.tmp`, which is then renamed over `config.json`. The file is pretty-printed JSON.

**A missing file is an empty store, not a problem.** **A damaged file** is one that is not valid UTF-8, not valid JSON, not a JSON object, or cannot be read. `AppContext.open` still succeeds, `problem` says why, a warning note is added, and every write is refused until you decide what to do. The file is never replaced silently (spec [section 5, item 3](../spec/APP-CONTEXT.md)).

`setAsideCorrupt()` is that decision. It renames the file to `config.json.corrupt` (replacing an older `.corrupt` copy), empties the store, clears `problem` and returns the new `File`. It returns `null` when nothing was damaged. The damaged content is kept, never deleted. If you want the person to choose, show them `problem` and call it from a button.

Each copy of an app keeps its own in-memory values and rewrites the whole file on `set`. Two copies running at once can overwrite each other's keys, and the Kit takes no lock. This follows from reading the code; there is no test for it.

## `AppJsonFile` and `ctx.dataJson`

`ConfigStore` is for the one settings file. `AppJsonFile` does the same careful handling for any JSON file your app owns, usually under `ctx.dirs.data`. `ctx.dataJson('notes.json')` returns the `AppJsonFile` for that name under the data directory, and `AppJsonFile(file)` wraps any `File`.

| Member | Behaviour |
|---|---|
| `read()` | Returns an `AppJsonRead`; never throws for a missing or damaged file |
| `write(json)` | Creates the directory, writes `<name>.tmp` with a flush, renames it over the target. Throws `FileSystemException` if the disk refuses |
| `quarantine()` | Renames a damaged file to `<name>.damaged-<UTC milliseconds>` and returns the new `File`. Never deletes |
| `delete()` | Removes the file; a missing file is fine |

`AppJsonRead` has `exists`, `value`, `problem` and `ok` (true when `problem` is null, which includes the file not existing). The three outcomes:

| Outcome | `exists` | `ok` | `value` | `problem` |
|---|---|---|---|---|
| no such file | `false` | `true` | `null` | `null` |
| read fine | `true` | `true` | the decoded JSON | `null` |
| damaged or unreadable | `true` | `false` | `null` | `not valid JSON: ...` or `could not be read: ...` |

A file that contains the JSON literal `null` is `exists: true, ok: true, value: null`; check `exists` to tell it from a missing file.

## `SessionSettings`

`SessionSettings(ctx.config)` wraps a `ConfigStore` for UI code that should not throw when the file is damaged.

- While the file is healthy it is the store: `set` saves, `get` reads the file's values.
- While the file is damaged, `set` keeps the value in memory for this session only and never touches the file. `get` returns that session value, then the file's value, then the fallback. `readOnly` is `true`, so you can tell the person their change will not be kept.
- After `setAsideCorrupt()` on the store, `readOnly` is `false` and writes reach the file again. Values set during the damage are not written then.

`SessionSettings.set` never throws `DamagedConfigError`. It can still throw `FileSystemException` if the disk refuses a write.

## Notes

`ctx.notes` is a `List<AppNote>`; each has a `severity` (`NoteSeverity.info`, `warning` or `error`) and `text`. `ctx.noteTexts` gives the texts only. Notes are plain data: adding one notifies nobody.

`AppContext.open` adds these:

| When | Severity | Text |
|---|---|---|
| `config.json` is damaged | warning | `Settings: <problem>. They will not be saved until the file is set aside.` |
| Venue, in `mock` mode | info | `Venue: fake (mock mode)` |
| Venue, `venue.mode` is `off` | info | `Venue: local (Venue is off for this app)` |
| Venue, no token anywhere | info | `Venue: local (Venue not configured)` |
| Venue, `VENUE_TOKEN_FILE` set but unusable | warning | `Venue: local (VENUE_TOKEN_FILE is set to <path> but <reason>)` |
| Venue, token found but the daemon did not answer `/healthz` within 2 seconds | warning | `Venue: local (Venue did not answer at <url>)` |
| Venue connected | info | `Venue: connected to <url> as <consumer>` |

`AppContext.run` adds an `error` note if closing fails after your function threw (see [lifecycle](#lifecycle)). Your app can add its own; the notepad demo app adds a warning when a note file is damaged.

## The Venue session

`ctx.venue` is a `VenueSession`. Its `kind` is `local`, `fake` or `venue`; `isConnected` is true only for `venue`; `description` is one sentence. The same calls work for all three, so app code does not branch. The wire details (the daemon's HTTP API) belong to Venue, not to this Kit; spec [section 3](../spec/APP-CONTEXT.md) and [section 5, items 2, 6 and 7](../spec/APP-CONTEXT.md).

| Call | Meaning |
|---|---|
| `hold(need, {leaseSeconds: 300})` | Ask for something. A `VenueNeed` has `name`, `contractClass` and `parameters`. Returns a `VenueHold` |
| `start(hold)`, `renew(hold)`, `release(hold)` | The hold's life cycle |
| `holds()` | This consumer's own live holds, for finding orphans after a crash |
| `nodes()` | The nodes Venue knows about |
| `withHold(need, body, {leaseSeconds, onLeaseLost, renewEvery})` | Hold, start, renew in the background while `body` runs, then release, also on error. `renewEvery` defaults to a third of the lease. A renewal failure sets `hold.leaseLost` and calls `onLeaseLost` once; the body keeps running. A failing release never replaces the body's result: it is recorded in `hold.releaseError` |
| `withHoldWaiting(need, body, {required maxWait, retryEvery, cancel, onWaiting, ...})` | Like `withHold`, but retries a refusal until `maxWait` has been spent in naps of `retryEvery`. `maxWait: Duration.zero` is `withHold`. Completing `cancel` ends the wait with `HoldWaitCancelled` |

Refusals are typed. `VenueRefused` carries a `kind`: `doesNotFit` (HTTP 409; retrying later can succeed) or `forbidden` (HTTP 403). `VenueRefused.retryable` is true only for `doesNotFit`, and `plainReason` unwraps the daemon's JSON error message. `VenueUnavailable` is everything else: a transport failure, a timeout, 401, 5xx. It carries the HTTP `status` when there was an answer.

`withHoldWaiting` retries `forbidden` only while `holds()` shows this consumer still has live holds, because the daemon uses the same status for "over your live-hold limit" and for "no grant". This is a heuristic and the spec records its known failure: a consumer that holds something and lacks a grant waits the full `maxWait` for nothing. See spec [section 7](../spec/APP-CONTEXT.md).

**The three sessions:**

- `LocalVenue(why)`: no Venue. Work still runs. Holds exist in this process only, so two apps can both "hold" the same thing, and a second hold with the same name in one process is refused as `doesNotFit`.
- `FakeVenue({capacity: 1})`: in memory, one node. It refuses a hold when `capacity` holds are live, keeps a `log` of calls (`hold <name>`, `start <name>`, `renew <name>`, `release <name>`), and `refuseNext(n, {kind})` makes the next `n` holds refuse. Use it in tests.
- `RemoteVenue` (Dart only): the daemon over HTTP with a bearer token. `IoTransport` does the HTTP; with `VENUE_DAEMON_FINGERPRINT` it trusts exactly one certificate and no authority. A fingerprint that is not 32 bytes of hex, or a certificate that does not match, is reported as `VenueUnavailable` with an explanation. Pass your own `DaemonTransport` to `AppContext.open(transport: ...)` to supply replies without a socket.

## Lifecycle

### Open

`AppContext.open(manifest, {env, platform, home, transport, announce, heartbeat, fakeCapacity})` does these steps in this order:

1. Resolve (may throw `ResolveError`).
2. Create the five directories (may throw `FileSystemException`).
3. Open the settings; add a warning note if damaged.
4. Open the Venue session; add its note. In `venue.mode: on`, this step throws `VenueUnavailable` if Venue cannot be used. Nothing has been announced yet, so nothing is left behind.
5. Draw this copy's instance id: eight random lower-case hex digits.
6. Write the roster entry and start the heartbeat, unless `announce: false`. If that fails, Venue is closed and the error is rethrown.

`announce: false` is for tests and tools that should not appear in the roster. `heartbeat` (default 5 seconds) is how often the roster entry is refreshed.

### Run

`AppContext.run(manifest, body, {...})` is open, then `body(ctx)`, then close, also when `body` throws. If `body` throws, that error is what you get; a failure while closing is recorded as an `error` note instead of replacing it. If `body` returns and closing fails, `run` throws the `AppCloseError`.

`run` closes the moment `body` returns. That suits a command-line tool. It does not suit a Flutter app, where `runApp` returns at once; use `AppContextKit.run` there.

### Close

`ctx.close()` does these steps in this order and always does all of them:

1. Stop the heartbeat and delete this copy's own roster entry (only that file).
2. Run every `ctx.onClose` hook, **last added first**. A hook may be async; each is awaited. Peer hubs made by `ctx.peerHub` or `ctx.startPeers` are closed by a hook of their own, so they follow the same order.
3. Close Venue, last, so a hook can still use it.

If any step threw, the errors are raised together afterwards as one `AppCloseError` (its `errors` and `stackTraces` lists hold every failure). A failing hook never stops a later hook or the Venue close.

`close()` is idempotent. A second call, even a concurrent one, runs nothing again and returns when the first has finished. Only the first caller sees an `AppCloseError`.

Register hooks with `ctx.onClose(() async { ... })`. Typical uses are flushing unsaved edits and closing your own resources. The notepad demo app registers its flush hook after starting peers, so on quit the last keystrokes are saved and announced while the hub is still open.

## What the Flutter companion adds

`import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';` gives you everything below. Widget-test helpers are in `package:app_context_kit_flutter/testing.dart`, kept apart so a release build does not link `flutter_test`.

### `AppContextKit.run`

```dart
Future<AppContextKitSession> AppContextKit.run({
  required String manifestAsset,
  required Widget Function(AppContext ctx) app,
  // passed to AppContext.open:
  Map<String, String>? env, String? platform, String? home, DaemonTransport? transport,
  bool announce = true, Duration heartbeat = const Duration(seconds: 5), int fakeCapacity = 1,
  // for tests:
  AssetBundle? bundle, bool handleSignals = true, void Function(int code)? exitProcess,
  void Function(String message)? report,
  String errorTitle = 'This app could not start',
})
```

It ensures the Flutter binding, loads and validates the manifest from the bundle, opens the context, mounts `AppContextScope(ctx:, child: app(ctx))` and wires the exit coordinator. If anything before that point fails, it mounts the startup error screen and returns a session whose `error` is set. If your `app` builder throws, the context is closed (so no roster entry is left) and the screen shows `app-build-failed`.

Other static members: `AppContextKit.quit()` (for a Quit button: closes once, then ends the process), `AppContextKit.loadManifest(asset, {bundle})`, `AppContextKit.openContext(...)` (the first half of `run`, without the lifecycle wiring) and `AppContextKit.buildRoot(ctx, app)`.

### `AppContextScope`

An `InheritedWidget` holding the context. `AppContextScope.of(context)` returns it or throws a `FlutterError` saying how to fix it; `maybeOf` returns `null`. Dependents rebuild only if a different context is swapped in, which happens in tests that relaunch.

### The exit coordinator

`ExitCoordinator` funnels every way an app can end into one shutdown that calls `ctx.close()` at most once.

| Event | What happens | Process exit code |
|---|---|---|
| Window close, or quit from the menu (the lifecycle's exit request) | closes, then agrees to exit | by the platform |
| Quit through `AppContextKit.quit()` | closes, then ends the process | 0, or 1 if the close failed |
| SIGINT | closes, then ends the process | 130, or 1 if the close failed |
| SIGTERM | closes, then ends the process | 143, or 1 if the close failed |
| `onDetach` (the only event mobile platforms give) | closes; does not exit | |

Nothing exits before the close has finished. A failing close never blocks the exit: the error is written to stderr, in full. There is no timeout and no "second signal forces it"; a hung `onClose` hook is a bug, and `SIGKILL` is the way out. A platform that cannot watch a signal (Windows has no SIGTERM) is skipped. On mobile, the `onDetach` close is best effort; the OS may not give it time. With SIGTERM and SIGINT sent to a built macOS app, the roster entry was gone afterwards. The exit paths are otherwise tested through injected sources, not through a real window close.

### Widgets

| Widget | What it shows |
|---|---|
| `ModeBadge.forContext(ctx)` (or `ModeBadge(isMock:, scratch:)`) | Nothing in `real` mode with no scratch; otherwise a chip: `mock`, `scratch` or `mock + scratch`, with a tooltip and a semantics label |
| `NotesBanner.forContext(ctx)` (or `NotesBanner(notes:)`) | Warnings and errors, each with an icon, the word "Warning" or "Error", and its own colours. Info notes are hidden unless `showInfo: true`. `dismissible: true` adds a close button; `onDismissed` is told which note, and the list is not edited. `NotesBanner.visibleOf(notes)` returns what would be shown. It reads the list when built, so rebuild it after adding a note |
| `PeersIndicator.forHandle(handle)` (or `PeersIndicator(hub:, offlineReason:)`) | "This copy: laptop #3fa2", "Peers: N", a chip per connected copy, "(K connecting)", or "Peers: off (peers unavailable: ...)". One live region for screen readers. `extra:` adds a line of your own. It is exported from the main library and from `package:app_context_kit_flutter/peers.dart` |
| `StartupErrorScreen(error:)` | A full `MaterialApp` showing the failure: a title, what happened, what to do, and `Error code: <code>` |
| `StartupErrorBody(error:)` | The same content without the `MaterialApp`, for an app that has its own |

### The startup error screen and its codes

`AppContextKitStartupError` has a stable `code`, a `message` (what happened), a `hint` (what to do) and the original `cause`. `AppContextKitStartupError.from(error)` sorts any failure into one:

| Code | Cause | What to do |
|---|---|---|
| `manifest-asset-missing` | the asset could not be loaded from the bundle | list `app.json` under `flutter: assets:` in `pubspec.yaml` and rebuild |
| `not-json`, `not-object`, `bad-id`, `bad-name`, `bad-version`, `bad-kits`, `duplicate-kit`, `bad-prefix`, `bad-venue` | the manifest's own code, from [the table above](#the-manifest) | fix `app.json` and rebuild |
| `bad-mode` | `APP_CONTEXT_MODE` or `<PREFIX>_MODE` is not `real` or `mock` | set it to `real` or `mock`, or unset it |
| `missing-env` | a Windows directory default needed `LOCALAPPDATA`, `APPDATA` or `TEMP` | set it, or set `APP_CONTEXT_SCRATCH` |
| `venue-required` | `venue.mode` is `on` and Venue could not be used (no token, or no answer from the daemon) | provide a token and start Venue, or run with `APP_CONTEXT_MODE=mock` |
| `open-failed` | a `FileSystemException` creating or reading the folders, or any other error from `open` | check the folder is writable, or set `APP_CONTEXT_SCRATCH` |
| `app-build-failed` | your `app` builder threw | a bug in the app; run from a terminal for the stack trace |

## Sharing one context with a Rust core

A Flutter app with a Rust core must not open the context twice: it would be in the roster twice, under two instance ids, and two code paths would write one `config.json`. The Dart side opens the context (`AppContextKit.run`) and hands the Rust side a snapshot; the Rust side adopts it. The full rule is [spec section 8](../spec/APP-CONTEXT.md#8-sharing-one-context-between-a-dart-ui-and-a-rust-core).

**Dart, the owner.** `ctx.snapshot()` returns a map `{schema, appId, instance, mode, scratch, dirs: {data, config, state, cache, runtime}, roster}` you can `jsonEncode` and pass over the bridge. It has no secrets and no handles, and asking for it announces nothing.

**Rust, the adopter.**

```rust
let snapshot = ContextSnapshot::parse(&json_from_dart)?;   // strict: unknown schema, missing field, relative path are errors
let ctx = AppContext::adopt(&snapshot);                    // no roster entry, no heartbeat, no config.json written
let blocks = ctx.create_data_dir("blocks")?;               // directories under data and state only
let file = ctx.data_file("heads.json")?;                   // a path under data (no `..`, nothing created)
let theme: String = ctx.settings().get_or("theme", "light".into());  // read-only: `set` and `save` return Err(ReadOnly)
```

**One owner per file.** The owner (the side that opened the context) owns `config.json` and the roster entry. The adopter reads settings, never writes them, and owns the files it creates under `data` and `state`. A setting the Rust core wants changed is a request to the Dart side. After the owner changes a setting, `ReadOnlySettings::reload()` shows it.

| Dart | Rust |
|---|---|
| `ctx.snapshot()`, `contextSnapshot(...)` | `ContextSnapshot::parse`, `from_value`, `to_json`; `AppContext::snapshot()` |
| (the owner) | `AppContext::adopt(&snapshot)` gives an `AdoptedContext`: `app_id()`, `instance()`, `mode()`, `dirs()`, `roster_dir()`, `data_file`, `state_file`, `create_data_dir`, `create_state_dir`, `settings()` |
| `ctx.config` (read and write) | `ReadOnlySettings` (read only) |

## The roster

The roster answers "who is running?". Each running copy writes one JSON file into the shared roster directory (see [directories](#directories)) and refreshes it.

- **File name:** `<ID>@<INSTANCE>.json`, for example `com.slashbuilder.demo.calc@1a2b3c4d.json`. The instance is eight lower-case hex digits, drawn at random per opened context.
- **Content:** `id`, `instance`, `name`, `version`, `pid`, `startedAt` and `heartbeatAt` (UTC, ISO 8601). `ctx.instance` is this copy's instance id.
- **Heartbeat:** the file is rewritten every 5 seconds (`heartbeat:`), through a temporary file and a rename. A failed heartbeat is recorded in `RosterAnnouncement.lastError` and does not stop the app.
- **Two copies of one app** are two files. Withdrawing one removes only its own.
- **Stale:** an entry whose `heartbeatAt` is more than 15 seconds old (`staleAfter:`) is stale. A copy that exited cleanly deletes its file. A copy that crashed leaves it behind, and the Kit never deletes it.

Reading it, on `ctx.roster` (or `Roster(dir)`):

| Call | Returns |
|---|---|
| `running()` | `RosterEntry` for every live entry. Stale and unreadable files are skipped, not deleted |
| `scan()` | A `RosterRecord` for every `*.json` file, sorted by id then instance, with a `status`: `live`, `stale` or `unreadable` |

A `RosterRecord` has `file`, `status`, `entry` (null when unreadable), `id` and `instance`. For an unreadable file, `id` and `instance` come from the file name, so it can still be attributed. Use `scan()` to tell a crash (`stale`) from "never ran" (no record) from a damaged file (`unreadable`). A file named `<ID>.json` with no instance part, from before instance ids existed, has a `null` instance. `parseRosterFileName(name)` splits a name; the id contains dots, so it splits at the last `@`.

The PID in an entry means something only on the same machine and for the same user. The roster does not check that the process is alive; it trusts the heartbeat.

Spec: [section 4](../spec/APP-CONTEXT.md) and [section 5, item 5](../spec/APP-CONTEXT.md). The spec asks whether the roster belongs in the Kit, in Venue or nowhere; the Kit keeps the smallest version so that use can answer.

## Peers

Peers are other running copies of the same app for the same account. They are opt-in: list `"peers"` in `kits`, or `ctx.peerHub` and `ctx.startPeers` throw `KitNotDeclared`. This guide covers only how the context supplies them; the design is in spec [sections 6 and 7](../spec/APP-CONTEXT.md).

- **Who this copy is:** `ctx.peerAccount` (`APP_CONTEXT_ACCOUNT`, else config `account`, else `local`), `ctx.peerDevice` (`APP_CONTEXT_DEVICE`, else config `device`; generated once as `d-` and eight hex digits and saved, or kept for this run only if the settings file is damaged) and `ctx.instance`. The first call to `ctx.peerDevice` writes `device` to the config file.
- **Provider by mode:** an explicit provider if you pass one to `peerHub`; in `mock` mode, an in-memory fake network (pass one `FakePeerNetwork` to several contexts to make them see each other); otherwise the loopback provider over `ctx.peersDirectory` (`APP_CONTEXT_PEERS_DIR`), which finds copies on one machine.
- **`ctx.startPeers(hook, {network, options})`** builds and starts a hub and never throws for a runtime condition. It returns a `PeersHandle` at once: `hub` (null when peers are unavailable), `started` (a future that completes when the hub is open or has failed, never with an error), `error` (a sentence starting `peers unavailable: `), `isStarting`, `isRunning` and `changes` (a broadcast `Stream<void>` that fires when the hub opens or fails and on every peer change). `handle.hub?.broadcast(...)` is always safe. `KitNotDeclared` is not swallowed: that is a bug in the app.
- **`ctx.peerHub(hook, {provider, network, authenticator, options})`** builds a hub without starting it; call `hub.start()`. Use it for a custom provider or authenticator.
- **The hook** is an `AppCoordination` that you write: `channel`, `hello()`, `admit(peer, theirHello)`, `onPeer(peer, change)`, `onMessage(from, message)` and an optional `attach(hub)`. The Kit never reads a payload; it carries bytes and an app-declared `schema` integer.
- **`PeerJson`** has helpers for JSON payloads: `encode`, `decode` (null on malformed input, never throws), `fits`, `encodeWithin` (throws `PeerPayloadTooLarge`), `quiet` and `label`. `AppMessage.jsonBody` decodes a message body.

Hubs are closed with the context. The default authenticator accepts every peer.

## Errors

| Type | Thrown by | Carries |
|---|---|---|
| `ManifestError` | `AppManifest.parse`, `fromJson` | `code`: the [manifest code](#the-manifest) |
| `ResolveError` | `resolve`, `AppContext.open` | `code`: `missing-env` or `bad-mode` |
| `FileSystemException` | `AppContext.open` | the folder that could not be made. The core does not wrap it; the companion turns it into `open-failed` |
| `DamagedConfigError` | `ConfigStore.set`, `save` | `file`, `problem` |
| `AppCloseError` | `ctx.close`, `AppContext.run` | `errors`, `stackTraces`: every failed step |
| `VenueRefused` | `hold`, `withHold` | `kind` (`doesNotFit`, `forbidden`), `reason`, `plainReason`, `retryable` |
| `VenueUnavailable` | `AppContext.open` (mode `on`), Venue calls | `reason`, `status` |
| `HoldWaitCancelled` | `withHoldWaiting` | |
| `TlsPinException` | the transport (surfaced as `VenueUnavailable`) | `message` |
| `KitNotDeclared` | `ctx.peerHub`, `ctx.startPeers` | `kit`, `appId` |
| `PeerError` and its subclasses | the peer hub | `message`. Subclasses: `EnvelopeError`, `PeerNotAvailable`, `PeerLost`, `PeerOutboxFull`, `PeerTimeout`, `PeerClosed`, `PeerScopeError`, `PeerConnectError`, `PeerLinkClosed`, `PeerPayloadTooLarge` |
| `AppContextKitStartupError` | the Flutter companion | `code`, `message`, `hint`, `cause` |

## The Rust crate

`rust/` implements spec sections 1, 2, 5 and 8 and passes the same conformance fixtures. Names differ by language convention.

| Dart | Rust |
|---|---|
| `AppManifest`, `ManifestError` | `Manifest`, `ManifestError` (with `.code()`) |
| `resolve`, `Resolved`, `AppDirs` | `resolve`, `Resolved`, `Dirs` |
| `AppContext.open`, `.run`, `.close` | `AppContext::open`, `::run`, `.close()` (also on drop, errors lost) |
| `ctx.onClose(fn)` | `ctx.on_close(fn)`, `ctx.on_close_fallible(fn)` |
| `ConfigStore.get<T>`, `set`, `setAsideCorrupt` | `ConfigStore::get_or`, `set` (returns `Result`), `set_aside_corrupt` |
| `AppCloseError` | `CloseErrors`, each a `CloseError { what: "roster" \| "hook" \| "venue", message }`. A panic in a hook is caught and reported |
| `Roster.running`, `.scan` | `Roster::running(now, stale_after)`, `::scan(now, stale_after)` with `EntryStatus` |

Not in Rust: peers, `SessionSettings`, `AppJsonFile` and `ctx.dataJson`, `withHoldWaiting` and `FakeVenue.refuseNext` (Rust has `with_hold` and `with_hold_opts`), a remote Venue session, and everything in the Flutter companion.

**The Kit's Rust crate has no remote Venue session.** It has `LocalVenue` and `FakeVenue` only. It still looks for a token (the lookup order and its errors are the same as in Dart), but a token that is found cannot connect to anything: with `venue.mode` `auto` the session is `local` and its description says the crate has no remote Venue session (a warning note), and with `on` the context fails to open. `VENUE_DAEMON` and `VENUE_DAEMON_FINGERPRINT` are not read.
