# Testing

Two things are covered here: how to test an app built on the Kit, and how to run the App Context Kit repository's own test suites.

The Kit is built so that an app's tests need no network, no real home directory and no Venue. Two settings do that, and both are ordinary [environment variables](CONTEXT-GUIDE.md#environment-variables):

- **Scratch** (`APP_CONTEXT_SCRATCH`) puts every directory and the roster under one throwaway folder, so a test never touches real data.
- **Mock** (`APP_CONTEXT_MODE=mock`) replaces Venue with an in-memory fake and peers with an in-memory fake network.

Part 1 is for app authors. Part 2 is for working on the Kit itself.

## Part 1: testing an app

### Pass the environment in; do not read the machine's

`AppContext.open` takes `env:`, `platform:` and `home:`. When you pass `env`, nothing from the real process environment is read, so a developer's own `APP_CONTEXT_*` variables cannot change a test. The Dart test in [`docs/examples/dart_cli/test/kit_test.dart`](examples/dart_cli/test/kit_test.dart) opens every context like this:

```dart
final env = {'APP_CONTEXT_MODE': 'mock'}; // the scratch directory is added per test

Future<AppContext> launch(AppManifest m, [Map<String, String> more = const {}]) =>
    AppContext.open(m, env: {...env, 'APP_CONTEXT_SCRATCH': scratch.path, ...more}, announce: false);
```

`announce: false` keeps the test out of the roster. `scratch` is a temporary directory made in `setUp` and deleted in `tearDown`:

```dart
late Directory scratch;
setUp(() => scratch = Directory.systemTemp.createTempSync('app-context-example-'));
tearDown(() => scratch.deleteSync(recursive: true));
```

Because the scratch directory outlives a context, "quit and launch again" is two opens on the same directory. This test is from the same file:

```dart
test('a setting written by one launch is read by the next, on the same scratch directory', () async {
  var ctx = await launch(manifest);
  ctx.config.set('launches', 1);
  await ctx.close();

  ctx = await launch(manifest);
  expect(ctx.config.get<int>('launches', 0), 1);
  await ctx.close();
});
```

Run it with `dart test` in that directory. Expected: `All tests passed!` (three tests).

To pin a platform for a test about paths, add `platform: 'linux', home: '/x'`. `resolve()` itself is a pure function, so you can also call it directly with a `platform`, `home` and `env` and compare the strings; that is what the conformance fixtures do.

### Flutter: `pumpKitApp` and `testAppContext`

Import `package:app_context_kit_flutter/testing.dart` from `test/` only; it depends on `flutter_test`.

A `testWidgets` body runs in fake async, and `AppContext.open` does real file I/O and starts real timers, so it cannot simply be awaited there. The helpers do that work inside `tester.runAsync` for you.

| Helper | What it does |
|---|---|
| `testAppContext(tester, manifest:)` | Opens a context in a fresh temporary scratch directory, in `mock` mode, with no roster entry. Returns a `KitTestContext` |
| `pumpKitApp(tester, manifest:, app:)` | `testAppContext`, then mounts `app(ctx)` under an `AppContextScope`, exactly as `AppContextKit.run` does |

`manifest` can be an `AppManifest`, the JSON text of `app.json`, or a decoded map. Optional parameters: `env` (added to the isolated environment, and it may override it: `{'APP_CONTEXT_SCRATCH', 'APP_CONTEXT_MODE': 'mock', 'HOME'}`), `scratch` (reuse a directory; it is then not deleted), `announce` (default `false`), `heartbeat`, `platform`, `fakeCapacity`, `transport`, and for `pumpKitApp`, `settle` (also `pumpAndSettle`). The directory it made is deleted when the test ends. The host's environment is never consulted.

The `KitTestContext` it returns:

| Member | Meaning |
|---|---|
| `ctx` | The current `AppContext`. After `close`, the closed one, whose files you can still inspect |
| `scratch` | The directory everything lives under |
| `env` | The environment the context was opened with |
| `close()` | Closes the context as the real app does on exit: roster, `onClose` hooks, Venue. Idempotent |
| `reopen()` | Closes if open, then opens a new context on the same files. Does not touch the widget tree |
| `quit()` | Closes the context while the widgets are still mounted, then unmounts the tree |
| `relaunch()` | `quit()`, then a new context on the same scratch directory, then the same app mounted again. Returns the new context |

This is the test from [`docs/examples/flutter_hello/test/hello_test.dart`](examples/flutter_hello/test/hello_test.dart):

```dart
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
```

Run it with `flutter test` in `docs/examples/flutter_hello`. Expected: `All tests passed!` (one test).

If your test is about something that must have happened before the app ends (a flush on quit, a hook), call `kit.close()` or `kit.quit()` yourself and then assert. The calculator demo app's `test/calculator_screen_test.dart` shows a test that passes `announce: true` to see the real roster entry appear and disappear, and one that asserts every directory the app resolved is under the scratch directory.

To test the real manifest asset bundle, `AppContextKit.loadManifest('app.json')` works in a widget test; the calculator demo app's `test/manifest_asset_test.dart` does exactly that.

### The fake Venue

In `mock` mode, `ctx.venue` is a `FakeVenue`. It has one node and a capacity (the `fakeCapacity` parameter of `AppContext.open`, default 1), refuses a hold with `doesNotFit` when it is full, and logs each call. `refuseNext(n, {kind})` makes the next `n` holds refuse whatever the capacity, so a wait-and-retry loop can be tested without arranging a full node. This test is from `kit_test.dart`:

```dart
test('mock mode gives a fake Venue that can be made to refuse, so a waiting loop is testable', () async {
  final ctx = await launch(manifest);
  final venue = ctx.venue as FakeVenue;
  venue.refuseNext(2); // the next two holds are refused as "does not fit"

  const need = VenueNeed(name: 'job', contractClass: 'container.run.v1');
  final result = await venue.withHoldWaiting(need, (hold) async => 'done',
      maxWait: const Duration(seconds: 5), retryEvery: const Duration(milliseconds: 2));

  expect(result, 'done');
  expect(venue.log, ['hold job', 'hold job', 'hold job', 'start job', 'release job']);
  await ctx.close();
});
```

Use a small `retryEvery` in tests. `withHoldWaiting` counts waiting in naps rather than reading a clock, so it behaves under fake time. To test against a Venue that answers in particular ways without a socket, implement `DaemonTransport` (one `send` method and one `close`) and pass it as `transport:`. The App Context Kit repository's own tests do this in `dart/app_context_kit/test/support/fake_transport.dart`.

### The fake peer network

Peers are off unless the manifest lists `"peers"` in `kits`. In `mock` mode, `ctx.peerHub` and `ctx.startPeers` use an in-memory network. Give two contexts the same `FakePeerNetwork` and they find each other. Nothing touches the real network or the disk. This test is from `kit_test.dart`; `Listener` is a small `AppCoordination` defined in the same file, which records the messages it gets:

```dart
test('two copies of an app find each other on one fake network and exchange a message', () async {
  final peerManifest = AppManifest.fromJson({'id': 'dev.example.hello', 'name': 'Hello', 'version': '0.1.0', 'kits': ['peers']});
  final network = FakePeerNetwork(); // pass the same network to both copies
  final laptop = await launch(peerManifest, {'APP_CONTEXT_DEVICE': 'laptop'});
  final phone = await launch(peerManifest, {'APP_CONTEXT_DEVICE': 'phone'});

  final listener = Listener();
  final laptopHub = laptop.peerHub(Listener(), network: network);
  final phoneHub = phone.peerHub(listener, network: network);
  await laptopHub.start();
  await phoneHub.start();

  for (var i = 0; i < 100 && laptopHub.readyPeers.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(laptopHub.readyPeers, isNotEmpty);

  await laptopHub.broadcast(PeerJson.encode({'text': 'hi'}), kind: 'greeting');
  for (var i = 0; i < 100 && listener.received.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(listener.received, ['laptop: {text: hi}']);

  await laptop.close();
  await phone.close();
});
```

Set `APP_CONTEXT_DEVICE` per copy so the two have different device names; the instance ids are random. In a widget test, run the second copy inside `tester.runAsync` next to the one under `pumpKitApp`, and pass the same network to the app. The notepad demo app's `test/peers_ui_test.dart` does this end to end.

`FakePeerNetwork` can also be made unreliable, to test how your hook copes:

| Control | Effect |
|---|---|
| `partition(a, b)`, `isolate(a)`, `heal(a, [b])`, `healAll()` | Cut copies from each other, or from everyone, and restore them |
| `dropLinks(a, b)` | Break the connections without cutting discovery, like a flaky link |
| `latency`, `jitter` | A fixed delay, and a random extra delay (non-zero jitter can reorder frames) |
| `dropRate`, `duplicateRate` | Probability that a frame is lost, or delivered twice |
| `dropIf` | Drop a frame when your function says so |
| `deliveries`, `connectAttempts` | What arrived where, and how many connections were tried |

`FakePeerNetwork(seed: n)` makes the randomness repeatable, and a `ManualPeerClock` passed as `clock:` makes time repeatable too. A test that checks a hook with `startPeers` should also check the case where peers cannot start: the handle's `error` is set and the app keeps working alone. The demo apps each have such a test (for example the notepad demo app's `test/peers_ui_test.dart`, "when peers cannot start the footer says why and the notes still work").

### The conformance fixtures

The fixtures are the contract in executable form. `spec/conformance/manifest_cases.json` has one case per manifest rule (valid and invalid), and `spec/conformance/context_cases.json` has one per directory or mode rule: given a manifest, a platform, a home directory and an environment, the expected directories, roster, scratch flag and mode. Both implementations load the same files:

- Dart: `dart/app_context_kit/test/conformance_test.dart`
- Rust: `rust/tests/conformance.rs`

The files are generated, not written by hand. `tools/gen_fixtures.py` spells every expectation out from templates, and never asks an implementation what the answer should be. That is deliberate: an implementation that agrees with the fixture has been checked against the prose spec, not against itself.

### Add a case

1. Add one line to the `cases` list (context) or the `mc` list (manifest) in `tools/gen_fixtures.py`. A manifest case is `bad(name, manifest, code)` or `ok(name, manifest, defaults)`:

   ```python
   bad("kit-underscore", man(kits=["my_kit"]), "bad-kits"),
   ```

2. Regenerate:

   ```sh
   python3 tools/gen_fixtures.py
   ```

   It prints `25 context cases, 37 manifest cases` (the counts with the example case added) and rewrites both JSON files.

3. **Update the counts in the Rust test.** `rust/tests/conformance.rs` asserts how many cases each file holds, so that a silently shortened fixture file cannot pass. Change the number in the matching `run_all("manifest_cases.json", 36, ...)` or `run_all("context_cases.json", 25, ...)` line. Without this the Rust run fails with `fixture count changed; update this test`. The Dart test needs no change.

4. Run both languages:

   ```sh
   (cd dart/app_context_kit && dart test test/conformance_test.dart)
   (cd rust && cargo test --test conformance)
   ```

   Expected: `All tests passed!` from Dart (`+62` with the example case) and `test result: ok. 2 passed` from Rust.

If one implementation disagrees, the fixture is right unless the spec text says otherwise, and the prose is then corrected. A failing Dart case looks like this (shortened; here the expected code was wrong on purpose):

```
manifest conformance kit-underscore [E]
  Expected: throws <Instance of 'ManifestError'> with `code`: 'bad-id'
    Which: threw ManifestError:<ManifestError(bad-kits)>
```

This procedure was run on a copy of the App Context Kit repository with the example case; the checked-in fixtures were not changed. Regenerating the committed fixtures produces files identical to the ones in `spec/conformance/`.

## Part 2: running the App Context Kit repository's suites

Every command below was run on macOS (Apple silicon) when this page was written, and the Linux script in Docker. Counts will change as tests are added; what matters is the pass line. Paths are relative to the root of the App Context Kit repository. Nothing here needs anything outside it except the public package registries (pub.dev and crates.io).

| Suite | Command | A pass looks like |
|---|---|---|
| Dart core | `cd dart/app_context_kit && dart pub get && dart test` | `All tests passed!` (365 passed, 7 skipped) |
| Flutter companion | `cd dart/app_context_kit_flutter && flutter test` | `All tests passed!` (82 tests) |
| Rust crate | `cd rust && cargo test` | `test result: ok.` for four targets (83 unit, 2 conformance, 5 host_os, 4 snapshot_conformance) |
| Conformance only | `cd dart/app_context_kit && dart test test/conformance_test.dart`, then `cd rust && cargo test --test conformance` | Dart `All tests passed!` (61 tests); Rust `test result: ok. 2 passed` |
| Snapshot fixtures | `cd dart/app_context_kit && dart test test/snapshot_test.dart`, then `cd rust && cargo test --test snapshot_conformance` | Dart `All tests passed!` (5 tests); Rust `test result: ok. 4 passed` |
| Two processes | `cd dart/app_context_kit && dart test test/peers/two_process_test.dart` | `All tests passed!` (4 tests, about 30 seconds) |
| Real Venue daemon | see below | Dart `All tests passed!` (5 tests); skipped without a daemon |
| Pinned TLS | see below | Dart `All tests passed!` (14 tests); skipped without a daemon |
| Linux | `tools/linux-test.sh` | `-- <step>: exit 0 --` for four steps; the script exits 0 |

The Dart core's skipped tests are the five that need a real Venue daemon, the pinned-TLS group, and one that only applies on Linux. A skip is not a failure, but it means that test proved nothing on this machine.

**The Rust crate builds from the App Context Kit repository alone.** It has no remote Venue session, so it has no real-daemon or TLS tests: the real-daemon and TLS suites below are Dart only.

### The conformance fixtures, again

Both languages must pass every fixture before anything else matters. Run the two conformance commands above first. If a fixture file was edited by hand, `python3 tools/gen_fixtures.py` will overwrite it.

### Tests against a real Venue daemon

`test/venue_real_test.dart` talks to a real Venue daemon. The daemon is not part of the App Context Kit repository, and the Kit does not ship a script that starts one: start any compatible daemon yourself, then set the variables the test reads. The daemon needs a consumer named `calc`, granted `container.run.v1`, with a limit of three live holds (the limit test relies on it), a token file for that consumer, and a node whose heartbeat is kept fresh (without that, the daemon refuses every hold after about two minutes with `does_not_fit`). [The Venue guide](VENUE-GUIDE.md#testing-against-a-daemon) has the details.

```sh
cd dart/app_context_kit
VENUE_DAEMON=http://127.0.0.1:7878 VENUE_TOKEN_FILE=<path to calc's token file> dart test test/venue_real_test.dart
```

Expected: `All tests passed!` (5 tests). Without `VENUE_TOKEN_FILE` the file is skipped, and a skipped run proves nothing about the daemon.

### Pinned TLS

`test/venue_tls_test.dart` checks pinned TLS against a daemon that serves a self-signed certificate. Start any compatible daemon with TLS, note the SHA-256 fingerprint of its certificate, and set three variables; without them the tests skip with a message.

```sh
cd dart/app_context_kit
VENUE_TLS_DAEMON=https://127.0.0.1:17879 VENUE_TLS_FINGERPRINT=sha256:<64 hex digits> VENUE_TOKEN_FILE=<path to calc's token file> \
  dart test test/venue_tls_test.dart
```

Expected: `All tests passed!` (14 tests). They cover:

| Case | Result |
|---|---|
| the right fingerprint: hold, start, `holds()`, release; `withHold` | pass |
| the right fingerprint through `AppContext.open` with `VENUE_DAEMON_FINGERPRINT` | the session `kind` is `venue` |
| a well-formed but wrong fingerprint | `VenueUnavailable`, naming both fingerprints |
| no fingerprint against the self-signed certificate | `VenueUnavailable`, saying to set `VENUE_DAEMON_FINGERPRINT` |
| a malformed fingerprint | `VenueUnavailable`, naming the fingerprint |
| plain `http://` to the TLS port | `VenueUnavailable`, well under 10 s |
| `AppContext.open` with a wrong or missing pin, mode `auto` | a local session ("did not answer") and a warning note |
| `AppContext.open` with a wrong pin, mode `on` | throws `VenueUnavailable` |

Four more tests need no daemon (`test/transport_pin_test.dart`): the fingerprint spellings and a malformed pin. The first run of these cases against a real daemon found three problems around a pin that was itself sound (`SecurityContext(withTrustedRoots: false)` plus the certificate callback accepts exactly the pinned certificate and no other): an upper-case or colon-separated fingerprint was silently refused, and a wrong or malformed pin surfaced as an opaque handshake error. Both are fixed (`parseFingerprint` normalises the spellings; `TlsPinException` says what is wrong and what to do), and these cases keep them fixed.

### Linux

`tools/linux-test.sh [dart|rust|both]` runs the Dart and Rust cores in throwaway Docker containers, as a non-root user, with the App Context Kit repository mounted read-only. It needs Docker running and a network connection, because each container fetches its packages. Set `LINUX_AS_ROOT=1` to run as root, where a few tests behave differently because root ignores file mode bits (for example, a token file with mode 000 is read anyway, so that test is skipped). It uses `dart:stable` and `rust:1.94` unless `DART_IMAGE` and `RUST_IMAGE` say otherwise. It copies `spec/`, `rust/` and `dart/app_context_kit` into a tmpfs and builds there; no other checkout is needed.

It was run with Docker 28.5.2 on an aarch64 Linux VM (kernel 6.12.54), Dart 3.13.6 and Rust 1.94.1. It printed `-- conformance fixtures (Dart): exit 0 --`, `-- whole package (Dart): exit 0 --`, `-- conformance fixtures (Rust): exit 0 --` and `-- whole crate (Rust): exit 0 --`, then exited 0. The Dart package ran 366 tests with 6 skipped (the Linux-only test runs there, so one fewer skip than on macOS); run as root it ran 365 with 7 skipped, because the mode-000 token test is skipped when root can read the file. The Rust crate ran 83 unit tests, 2 conformance tests, 6 `host_os` tests and 4 snapshot-conformance tests (one `host_os` test is Linux-only, so 6 there against 5 on macOS).

### The two-process test

Every peers test except this one runs inside one process. `dart/app_context_kit/test/peers/two_process_test.dart` starts each hub in its own operating-system process (`two_process_worker.dart`), over the loopback provider and one shared temporary directory. Two copies of one app and account find each other, exchange hello and admit (`ready` on both sides), `send`, `broadcast` and `request`/`reply`. A third process with a different app id and a fourth with a different account saw no peer event and no message in over 600 ms, and neither appeared in the others' peer lists. A graceful quit is `lost` with the reason `goodbye`, and the announcement is gone.

It also kills one process with `kill -9` to see what a dying process looks like to its neighbour, and prints the numbers it measures: how long the survivor takes to see the peer lost, and how long the dead copy's announcement file stays behind. Run it with `-r expanded` to read them. `APP_CONTEXT_GHOST_SECONDS` (default 12) sets how long the survivor is watched after the kill. This variable is read by the test only; the Kit does not read it. The numbers and the fix they led to are in [Platforms](PLATFORMS.md#macos); `test/peers/loopback_ghost_test.dart` (6 tests) covers the heartbeat rules without a second process.
