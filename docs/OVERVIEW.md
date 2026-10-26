# Overview

The App Context Kit is a small library that gives one running application its root namespace: who it is, where its files live, where its settings are, whether it is running for real or under test, who else is running, and how it shuts down. You describe the app in a short `app.json`, open an `AppContext`, and the rest of your code asks that object instead of working these things out itself.

It is a work in progress. App Context Kit borrows its idea from the BeOS Application Kit; it is not a reimplementation of it and is not affiliated with Haiku. Nothing here is published to a package registry. See [Status](#status).

## The problem

Every desktop or mobile app starts `main()` by answering the same questions, and most answer them differently:

- **Identity.** What is this app called, what version is it, and what is its reverse-DNS id? The answer ends up in four places that can disagree: the `pubspec.yaml`, the macOS bundle, the Linux runner and a string in the code.
- **Where files live.** Data, settings, cache and runtime files each have a conventional home on macOS, Linux and Windows. Apps hard-code one of them, or copy a path helper from the last project.
- **Settings.** Reading and writing a small JSON file safely: atomically, and without overwriting a file you could not read.
- **Test modes.** A way to run the app against fakes, in a throwaway folder, without touching the developer's real data. Each app grows its own `--mock` switch.
- **Who else is running.** Is another copy of this app already open? Which apps are running at all?
- **Quitting cleanly.** Window close, Quit and Ctrl-C are different events. Cleanup that runs on one of them is often skipped on the others.

None of this is hard. It is the same code, written again for each app, and it is where small bugs live: a settings file that is silently replaced after one bad byte, a lock file left behind after a crash, a test that wrote into the real home directory.

## The idea

Put all of it in one place, under one object, driven by one file.

```
app.json  ->  AppManifest  ->  resolve (pure function)  ->  AppContext.open  ->  your app
```

Resolution (which directory, which mode) is a pure function of the manifest, the platform, the home directory and the environment. It does no I/O, so it can be specified exactly and tested with fixtures. Opening a context then creates the directories, reads the settings, opens a Venue session and announces the app in the roster. Closing it undoes that, in a fixed order, once.

### Where it comes from

The idea and the shape come from the BeOS Application Kit. In BeOS every program had a `BApplication` object that was the program's root, and a `BRoster` that knew which programs were running. This Kit keeps those two ideas: one root object per running app, and a roster of running apps.

It differs on purpose in three ways:

- **No looper or handler model.** BeOS built the Kit around message loops (`BLooper`, `BHandler`). This Kit does not own your event loop or your threads. Flutter already has one. The Kit gives you a context object, and the only messaging it provides is the opt-in [peers](#the-pieces) piece, between copies of the same app.
- **Cross-language.** The contract is a written spec plus shared test fixtures, not one implementation. A Dart implementation and a Rust implementation both pass every fixture.
- **Flutter on top of a Rust-or-Dart core.** The intended shape is a Flutter UI over a core that may be written in either language. Today six of the demo apps (in The Kit Book) use the Dart core, and a seventh puts a Rust core under a Flutter UI. The Rust crate implements the same spec and passes the same fixtures, and the two sides share one context: the Dart side opens it and the Rust side adopts it (see [Sharing one context with a Rust core](CONTEXT-GUIDE.md#sharing-one-context-with-a-rust-core)).

## The pieces

| Piece | What your app gets | In the Dart core | In the Rust crate |
|---|---|---|---|
| Manifest and app id | `app.json` parsed and validated; a reverse-DNS id, name, version | `AppManifest` | `Manifest` |
| Directories | `data`, `config`, `state`, `cache` and `runtime`, resolved per platform, created for you | `ctx.dirs` | `ctx.resolved.dirs` |
| Settings | A JSON settings file with atomic writes that is never overwritten when damaged | `ctx.config` (`ConfigStore`), `SessionSettings`, `AppJsonFile` | `ctx.config` (`ConfigStore`) |
| Modes | `real` or `mock`, and a scratch root that puts every directory in one throwaway folder | `ctx.mode`, `ctx.isMock`, `ctx.scratch` | `ctx.mode()`, `ctx.is_mock()`, `ctx.is_scratch()` |
| Roster | A presence file per running copy, refreshed every 5 seconds; a way to list who is running | `ctx.roster` | `ctx.roster` |
| Venue session | One object for "ask the resource broker for something", the same whether Venue is real, absent or faked | `ctx.venue` | `ctx.venue` (local and fake sessions only) |
| Peers (opt-in) | Find, connect to and exchange messages with other running copies of the same app | `ctx.startPeers`, `ctx.peerHub` | not implemented |

Venue is a resource broker. An app asks it for a lease on something, such as a slot to run a job, holds it while it works and releases it. The Kit does not implement Venue; it provides the client side and hides whether a Venue is configured. With no Venue the session is local and says so, and in `mock` mode it is an in-memory fake. The client for a real daemon exists in the Dart core only: the Rust crate has local and fake sessions and no remote Venue session.

Peers are off unless the manifest lists `"peers"` in its `kits`. The Kit ships two providers: an in-memory fake network for mock mode and tests, and a loopback provider for copies on one machine. Peers between machines are not part of the Dart core.

A Flutter companion package, `app_context_kit_flutter`, adds what the pure-Dart core cannot do: load `app.json` from the asset bundle, close the context exactly once however the app ends, and a few small widgets (a mode badge, a notes banner, a peers indicator, a startup error screen). It also provides widget-test helpers.

## Design rules

1. **The spec is the contract.** [`spec/APP-CONTEXT.md`](../spec/APP-CONTEXT.md) and the fixtures in [`spec/conformance/`](../spec/conformance) define behaviour. Both implementations must pass every fixture. If the prose and a fixture disagree, the fixture wins and the prose is corrected.
2. **Apps compose the Kit and never fork it.** An app that needs something the Kit lacks writes it in the app (the demo apps keep these under `lib/kit_gaps/`) and marks it `// KIT GAP:`. That code is the record of what is missing.
3. **The Kit never interprets an app's payload.** It finds peers, connects to them and carries bytes. What a message means is the app's decision.
4. **The core stays pure Dart.** `app_context_kit` has no Flutter import. Anything that needs Flutter goes in `app_context_kit_flutter`.
5. **Build a piece when the second app copies it.** Code only one app needs stays in that app. A helper moves into the Kit once a second app has written the same thing.

## What it does not do

- **No UI toolkit.** The companion package has a handful of plain Material widgets for the Kit's own state. It has no design system, theming, routing or state management.
- **No sync engine.** Peers gives you discovery, a connection and best-effort ordered delivery. Reconciling data between copies is your code. Large transfers are not built.
- **No installer or updater.** The Kit does not install, update or launch apps. The roster reports which apps are running, not which are installed.
- **No authentication or accounts.** The peers scope key is `(account, app id)`, and the account defaults to the string `local`. The default authenticator, `OpenAuthenticator`, accepts every peer, so an account or app id is a claim, not a proof. The only other authenticator in the code is a test fake. The Kit does not issue accounts or credentials.
- **No window title, bundle id or version sync.** Those live in native build files that a running app cannot change. A script, `dart/app_context_kit_flutter/tool/check_identity.dart`, checks that they agree with `app.json`.

## Repository map

| Path | What it is |
|---|---|
| [`spec/APP-CONTEXT.md`](../spec/APP-CONTEXT.md) | The contract: manifest, resolution, lifecycle, roster, peers |
| `spec/conformance/` | Shared fixtures, generated by `tools/gen_fixtures.py`; both languages must pass them |
| `dart/app_context_kit/` | The Dart core (pure Dart) |
| `dart/app_context_kit_flutter/` | The Flutter companion package |
| `rust/` | The Rust crate (`slashbuilder-app-context-kit`); builds from the App Context Kit repository alone |
| `tools/` | `gen_fixtures.py`, `linux-test.sh` |
| `docs/` | This documentation. `docs/examples/` holds code that was compiled and run |

Documentation:

- [Getting started](GETTING-STARTED.md): a running app, step by step
- [Context guide](CONTEXT-GUIDE.md): reference for fields, directories, environment variables and lifecycle
- [Testing](TESTING.md): testing an app built on the Kit, and running the App Context Kit repository's suites
- [Contributing](../CONTRIBUTING.md): building and changing the Kit itself

## Status

- The Dart packages are marked `publish_to: none`; none is on pub.dev. The Rust crate `slashbuilder-app-context-kit` is not published to crates.io yet.
- The spec is version 0.1. Behaviour may change, including in breaking ways.
- Verified for this documentation: the Dart core and companion test suites, the Rust test suite and the conformance fixtures in both languages, run on macOS; the Linux runs of the cores in Docker; and the demo apps built in release mode and launched headless in a Linux container (see [Platforms](PLATFORMS.md#linux)). No Windows test run is recorded in the App Context Kit repository, although the fixtures cover Windows path resolution.
