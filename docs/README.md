# App Context Kit documentation

**[Overview](OVERVIEW.md)** · **[Getting started](GETTING-STARTED.md)** · **[Context guide](CONTEXT-GUIDE.md)** · **[Venue guide](VENUE-GUIDE.md)** · **[Coordination](COORDINATION-GUIDE.md)** · **[Architecture](ARCHITECTURE.md)** · **[Platforms](PLATFORMS.md)** · **[Testing](TESTING.md)** · **[Design decisions](DESIGN-DECISIONS.md)** · **[Spec](../spec/APP-CONTEXT.md)** · **[Contributing](../CONTRIBUTING.md)** · **[Repository home](../README.md)**

---

The App Context Kit is the **root namespace for one running app**. It gives an app an identity, a place for its files and settings, test and scratch modes, a presence entry other apps can see, a session with a resource broker, and an opt-in way to find and talk to other copies of itself. It does not decide what any of that means for your app.

It is a piece of a larger platform, it is not published to a package registry yet, and the question behind it is: *does the BeOS idea of an Application Kit still make sense when you build several small apps instead of one big one?* These pages say what was built, how it was checked, and what is not yet known.

## Start here

| I want to... | Read |
|---|---|
| understand what this is in five minutes | [Overview](OVERVIEW.md) |
| build a Flutter app on it | [Getting started](GETTING-STARTED.md), then the [context guide](CONTEXT-GUIDE.md) |
| use it from plain Dart or from Rust | [Getting started: plain Dart](GETTING-STARTED.md#plain-dart), [Rust](GETTING-STARTED.md#rust) and [`examples/dart_cli`](examples/dart_cli/), [`examples/rust_cli`](examples/rust_cli/) |
| have two copies of my app find and talk to each other | [Coordination guide](COORDINATION-GUIDE.md) |
| take machine time from a resource broker | [Venue guide](VENUE-GUIDE.md) |
| write tests that never touch real files | [Testing](TESTING.md) |
| ship on macOS, Linux or Windows | [Platforms](PLATFORMS.md) |
| judge whether the idea holds | [Design decisions](DESIGN-DECISIONS.md), then the results at the foot of this page |
| see how the pieces fit | [Architecture](ARCHITECTURE.md) |
| read the contract itself | [Spec](../spec/APP-CONTEXT.md) and its [fixtures](../spec/conformance/) |

## Every page

### Learn
| Page | What you get |
|---|---|
| [Overview](OVERVIEW.md) | The problem every app re-solves, the idea, the pieces in one table, the rules, what it does not do |
| [Getting started](GETTING-STARTED.md) | Numbered steps from nothing to a running app, plus pure-Dart and Rust versions |
| [Architecture](ARCHITECTURE.md) | Six diagrams: the layers, start-up and shutdown, the peer handshake, the roster versus peer announcements |
| [Design decisions](DESIGN-DECISIONS.md) | Why it is shaped this way, what we chose not to build, and the open questions |

### Build
| Page | What you get |
|---|---|
| [Context guide](CONTEXT-GUIDE.md) | Manifest fields, directories per platform, every environment variable, settings, lifecycle, the roster, the Flutter companion |
| [Venue guide](VENUE-GUIDE.md) | The broker session: modes, holds and leases, typed refusals, orphan holds, pinned TLS, what registering an app costs |
| [Coordination guide](COORDINATION-GUIDE.md) | The five-method hook, the hub, providers, three worked patterns, and what the hook does not give you |
| [Testing](TESTING.md) | Scratch and mock modes, fakes, the shared fixtures, real-daemon runs, Linux and TLS scripts |

### Evidence
| Page | What you get |
|---|---|
| [Platforms](PLATFORMS.md) | What runs where and how it was verified, with the macOS sandbox entitlement table and the crashed-copy numbers |

## Runnable examples

Every code sample in these pages is copied from one of these, or from a passing test or one of the demo apps in The Kit Book. Run them rather than trusting the text.

| Example | What it shows | Run |
|---|---|---|
| [`examples/dart_cli`](examples/dart_cli/) | The Kit from plain Dart: open a context, a setting, a counter, the Venue-off session | `dart test` / `dart run bin/main.dart` |
| [`examples/rust_cli`](examples/rust_cli/) | The same app in Rust; prints the same lines | `cargo run` |
| [`examples/flutter_hello`](examples/flutter_hello/) | A five-line `main.dart`, `app.json` and a widget test | `flutter test` |
| [`examples/coordination`](examples/coordination/) | A two-copy "ping" app on the fake network, plus behaviour tests (scope, ordering, limits) | `dart test` |

## The short version of the results

* **One contract, two implementations.** Dart and Rust pass the same 61 fixtures. The second implementation found about a dozen behaviours the first had decided silently.
* **Less code per app.** Helper code the six apps wrote themselves went from 727 lines to 330, up to 777 after coordination was added, and down to 164 once the repeated parts moved into the Kit. Every `main.dart` is 5 to 11 lines. *Build a Kit piece when the second app copies it, not before.*
* **The hook is the right shape, and not enough on its own.** It carried a shared timer and a game handoff cleanly, and live play only just. For sync it was a small shell around a lot of app code, because the Kit gives no acknowledgement, large transfer, replay or liveness tick.
* **Same-machine coordination works; across machines is not built.** Two copies found each other in under half a second on one machine; a crashed copy disappeared in about 3.5 s.

## What is not verified

A real Linux desktop session (the cores are tested in Linux containers, and the demo apps were built in release mode and launched headless in a Linux container), window close on a real window, signed or packaged release builds, Windows beyond the pure path rules, and the peer code against a real remote hub. Each page marks its own unverified claims. "Verified" in these pages means a test, a command or a measurement in the App Context Kit repository; anything else is labelled as reasoned or reported.

## The demo apps

Several pages quote six small demo apps (a calculator, minesweeper, a notepad, a stopwatch, a render queue and a launcher) and the helper code each one had to write. The apps are not in the App Context Kit repository: they live in The Kit Book (the Kit Book repository), which documents the Kit and holds the demo apps. Paths such as `lib/kit_gaps/` or `lib/coordination/` in these pages are paths inside those apps.

## Conventions

* Page names are stable; sections are linked by their headings.
* Code blocks are checked against the App Context Kit repository. Where a block is illustrative, it says so.
* Some findings about other systems are deliberately not described here: where a review is pending, the page says that and nothing more.
* Numbers come with what they were measured on (macOS debug builds, loopback, a throwaway local broker). They are not benchmarks.

---

[Repository home](../README.md) · [Spec](../spec/APP-CONTEXT.md) · [Contributing](../CONTRIBUTING.md) · [Licence (Apache-2.0)](../LICENSE)
