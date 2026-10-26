# App Context Kit

**The root namespace for one running app.** It gives an app an identity, a place for its files and settings, test and scratch modes, a presence entry that other apps can see, a session with a resource broker, and an opt-in way to find and talk to other copies of itself. It does not decide what any of that *means* for your app.

> **Status: alpha.** App Context Kit borrows its idea from the BeOS Application Kit; it is not a reimplementation of it and is not affiliated with Haiku. The Rust crate will be published to crates.io as `slashbuilder-app-context-kit`; the Dart packages are not published to pub.dev; and the spec is version 0.1, so behaviour may change before 1.0. It started on 2026-10-21 as a build to answer one question: *does the BeOS idea of an Application Kit make sense for a team that builds several small apps instead of one big one?* The short answer is yes, with a narrower scope than first imagined. Everything below is measured; what is not verified is listed in [Limits](#limits).

## The idea in one screen

Every app needs the same boring things before it does anything interesting: *who am I, where do my files live, where are my settings, how do I run in a test without touching the real ones, who else is running, how do I quit cleanly.* Each app re-solves these. The App Context Kit solves them once, from a short manifest.

`app.json`, the whole description of the app:

```json
{
  "id": "com.slashbuilder.demo.notepad",
  "name": "Notepad",
  "version": "0.1.0",
  "kits": ["peers"],
  "venue": { "mode": "off" }
}
```

`main.dart`, the whole entry point of a Flutter app (this is the whole entry point of the minesweeper demo app, which lives in the Kit Book repository):

```dart
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';

import 'ui/minesweeper_app.dart';

Future<void> main() => AppContextKit.run(manifestAsset: 'app.json', app: (_) => const MinesweeperApp());
```

Anywhere below that, `AppContextScope.of(context)` gives the app its directories, its settings, its notes for the person ("your settings file is damaged"), its Venue session (Venue is a resource broker) and, if it asked for them, its peers. In a test, `APP_CONTEXT_SCRATCH=<dir>` puts every directory under a temporary one and `APP_CONTEXT_MODE=mock` swaps the outside world for fakes.

If the app wants other copies of itself (on this machine or later on other machines), it declares `"peers"` in the manifest and supplies a **hook**, five small methods that say what coordination means *for this app*. This is the real hook from the notepad demo:

```dart
class NoteSyncHook extends AppCoordination {
  NoteSyncHook(this.sync);
  final NoteSync sync;

  @override String get channel => 'notes';
  @override Object? hello() => sync.hello();                       // what to tell a peer on connect
  @override FutureOr<Admit> admit(Peer peer, Object? theirHello) => sync.admit(peer, theirHello);
  @override void onPeer(Peer peer, PeerChange change) { if (change == PeerChange.ready) sync.ready(peer); }
  @override void onMessage(Peer from, AppMessage message) => sync.onMessage(from, message);
}
```

The Kit finds the other copies, checks they belong to the same account and the same app, connects, and routes messages. It never reads a payload. What a "sync" or a "handoff" or a "shared timer" *is* lives entirely in your hook.

## What is in the box

| Piece | What it does | Where |
|---|---|---|
| **Manifest and app id** | A reverse-DNS id (`com.slashbuilder.demo.notepad`) and a few fields, validated with fixed error codes | [`spec/`](spec/APP-CONTEXT.md) |
| **Directories** | `data`, `config`, `state`, `cache`, `runtime` resolved per platform, with one override convention | `dart/app_context_kit` |
| **Settings** | An atomic JSON store that never overwrites a damaged file | `dart/app_context_kit` |
| **Modes** | `mock` and `scratch`, first-class, so tests never touch real directories | `dart/app_context_kit` |
| **Roster** | A presence file per running copy, so apps can see who else is running | `dart/app_context_kit` |
| **Venue session** | One interface to a resource broker that hides "real", "absent" and "fake" | `dart/app_context_kit` |
| **Peers** (opt-in) | Find, connect and route between copies of the same app; the app supplies the hook | `dart/app_context_kit` |
| **Flutter companion** | Clean exit, manifest loading, mode badge, notes banner, peers indicator, test helpers | `dart/app_context_kit_flutter` |
| **Rust implementation** | The same manifest, resolution and settings rules, checked by the same fixtures. No peers, and no remote Venue session in this tree (local and fake sessions only) | `rust/` |

One spec, [`spec/APP-CONTEXT.md`](spec/APP-CONTEXT.md), is the contract. **Two independent implementations (Dart and Rust) must both pass the same 61 fixtures** in [`spec/conformance/`](spec/conformance/). That was not decoration: the second implementation found about a dozen behaviours the first one had silently decided differently.

## Six demo apps

A calculator, minesweeper, a notepad, a stopwatch, a render queue and a launcher, chosen because each asks something different of the Kit. They are not in this repository: they live in the Kit Book repository, and the pages in [`docs/`](docs/README.md) quote them and say what each one showed. The calculator is the floor: it barely needs the Kit and says so. The notepad is the ceiling: it syncs notes between copies and resolves conflicts.

## Results at a glance

These are the numbers from the tests and measurements made while the Kit was built. The test counts below were re-run for this tree; the demo-app figures come from the apps in the Kit Book repository and were not re-run here.

* **Shared code instead of copied code.** Gap code (the helpers each app wrote itself because the Kit lacked them) across the six apps: **727 lines** at the start, **330** after the first migration, **777** after wiring in coordination (it went *up*), and **164** after the repeated parts moved into the Kit. Every app's `main.dart` is 5 to 11 lines. The lesson: *build a Kit piece when the second app copies it, not before.*
* **Coordination between copies** (macOS debug builds, two real copies): found each other in 289 to 470 ms; a 300 KB note converged in about 145 ms; a killed copy was reported lost in about 3.5 s.
* **The hook was enough for a signal and a handoff, and only just enough for live play.** For sync it is a 22-line shell around about 700 lines of app code, because the Kit gives no acknowledgement, large transfer, replay or liveness tick. [Coordination guide](docs/COORDINATION-GUIDE.md) explains what to do instead.
* **Tests (this repository):** Dart core 365 passed (7 skipped: five need a real Venue daemon, one is the pinned-TLS group, one is Linux-only), Flutter companion 82, Rust crate 83 unit + 2 conformance + 5 host-OS + 4 snapshot-conformance. The test counts of the six demo apps are in the Kit Book repository.

## Documentation

The docs have a landing page: **[docs/](docs/README.md)**. The pages:

| Read this | If you want |
|---|---|
| [Overview](docs/OVERVIEW.md) | what this is, what it is not, the rules |
| [Getting started](docs/GETTING-STARTED.md) | a running Flutter app in a few steps (and a pure-Dart and a Rust example) |
| [Context guide](docs/CONTEXT-GUIDE.md) | every setting, directory and environment variable |
| [Venue guide](docs/VENUE-GUIDE.md) | the resource-broker session, leases, refusals, TLS |
| [Coordination guide](docs/COORDINATION-GUIDE.md) | the hook, the hub, providers, three worked patterns |
| [Architecture](docs/ARCHITECTURE.md) | layers, startup and shutdown, the peer handshake (diagrams) |
| [Platforms](docs/PLATFORMS.md) | what runs where, and the macOS sandbox table |
| [Testing](docs/TESTING.md) | scratch, mock, fakes, fixtures, real-daemon runs |
| [Design decisions](docs/DESIGN-DECISIONS.md) | why it is shaped this way, and what is still open |
| [Spec](spec/APP-CONTEXT.md) | the contract itself |
| [Contributing](CONTRIBUTING.md) | how to build, test and change it |

## Try it

```sh
# the core, pure Dart
cd dart/app_context_kit && dart pub get && dart test

# the Flutter companion
cd dart/app_context_kit_flutter && flutter test

# the Rust implementation
cd rust && cargo test
```

To watch two copies find each other, see the [coordination guide](docs/COORDINATION-GUIDE.md) and the runnable [`docs/examples/coordination`](docs/examples/coordination/).

## Limits

Said plainly, because a project that hides these is not worth trusting.

* **Not verified:** a real Linux desktop session (the cores are tested in Linux containers, and the demo apps in the Kit Book repository were built in release mode and launched headless in a Linux container with a virtual display, which says nothing about a compositor, a real GPU or window close by click), window close on a real window (probes drove the apps' own code with the display off), signed or packaged releases (a release build was made of every demo app on Linux and of one on macOS), Windows beyond the pure path-resolution fixtures, and the peers code against a real remote hub.
* **One demo app uses the Rust side.** The six original demo apps (in the Kit Book repository) are Flutter on a Dart core. A seventh, `notes_rust`, is a Flutter UI over a Rust core (through `flutter_rust_bridge`) that adopts the context the Dart side opened ([spec section 8](spec/APP-CONTEXT.md#8-sharing-one-context-between-a-dart-ui-and-a-rust-core)), so the intended shape has been exercised end to end, on macOS and, headless, in a Linux container: it has not been run on a real Linux desktop, and there is no real network. The Rust crate passes the same fixtures; it has no peers and, in this tree, no remote Venue session.
* **Coordination is local only today.** Copies on one machine find each other through announcement files and loopback sockets. A real network transport is not built; the [coordination guide](docs/COORDINATION-GUIDE.md#15-real-transports) says what it must respect.
* **"Same app" is a convention, not a proof.** Until capabilities are signed, an app id is a string any program can type. The Kit scopes by account and app id, but it does not authenticate. Do not treat peers as trusted.
* **macOS sandbox.** Sandboxed apps cannot share a roster directory without a special entitlement. [`docs/PLATFORMS.md`](docs/PLATFORMS.md) has the table.
* **Registering an app with the resource broker is manual** (four steps, by an operator). The Kit deliberately does not do it for the app.
* **The name and the scope are unsettled.** Nothing here is a ruling.

## Community

Taking part means following the [Code of Conduct](CODE_OF_CONDUCT.md) (the Contributor Covenant 2.1). To change the Kit, read [Contributing](CONTRIBUTING.md). To report a vulnerability, follow the [Security policy](SECURITY.md): privately, never in a public issue.

## Licence

Apache-2.0. See [LICENSE](LICENSE). By Douglas Lockamy at Lockamy Studios.
