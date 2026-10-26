# Design decisions

Why the App Context Kit is shaped the way it is, what we tried instead, and what is still undecided. Each entry says what the evidence was, so you can disagree with the right thing.

## Decisions that held

### 1. One written contract, two implementations, shared fixtures
The behaviour lives in [`spec/APP-CONTEXT.md`](../spec/APP-CONTEXT.md). Dart and Rust both implement it, and both must pass the same fixtures in [`spec/conformance/`](../spec/conformance/).
**Why.** The first implementation passed its own 41 fixtures on the first run, which proved almost nothing because the same author wrote the spec, the fixtures and the code. The Rust implementation, written from the spec text, passed the same 41 and *still disagreed with Dart on about a dozen behaviours no fixture covered* (what happens to `/` as a base path, which separator gets trimmed, what a name made only of a byte-order mark is, what happens when a named token file is missing...). Closing them took 20 more fixtures. The suite is the product; the prose is commentary.
**Cost.** About twice the code in Rust as in Dart for the same behaviour, and a spec that must be kept honest.

### 2. The core is pure Dart; Flutter lives in a companion
The core package has no Flutter import, so it runs in a command-line tool, a server, or a test with no engine. Everything that needs Flutter (loading the manifest from an asset, exiting cleanly on window close or a signal, a mode badge, a notes banner, test helpers) is in `app_context_kit_flutter`.
**Why.** In all six demo apps the same shims were written by hand (a 20 to 56 line exit hook was rewritten six times out of six). They are Flutter-shaped, so they belong in a Flutter package, and the rest should not pay for them.

### 3. The Kit never interprets an app's payload
The Kit finds peers, checks scope, connects and routes. Meaning is the app's, supplied through a five-method hook (`channel`, `hello`, `admit`, `onPeer`, `onMessage`).
**Why.** The same hook expressed a live signal, a handoff and a conflict-resolving sync without the Kit knowing which was which. A Kit that knew about "notes" or "games" would have to be changed for every app.
**Cost.** The hook is only just enough for live play, and for sync it is a small shell around a lot of app code. See [what the hook does not give you](COORDINATION-GUIDE.md).

### 4. Test modes are part of the Kit, not a test helper
`APP_CONTEXT_SCRATCH=<dir>` puts every directory (and the roster) under one temporary root. `<PREFIX>_MODE=mock` swaps Venue and peers for in-memory fakes. Both are in the contract and in the fixtures.
**Why.** It was the part the demo apps liked most, and building them showed each app inventing its own way (two lookups for one override in one app, three different mock switches across three).

### 5. A damaged settings file is reported and never overwritten
Opening still works; `set` fails with a typed error until the app explicitly sets the damaged file aside.
**Why.** An early defect: the first `set()` after a damaged file silently destroyed it, and a file that was not valid UTF-8 stopped the app starting. The rule is simple enough to be a fixture-level promise.

### 6. The roster has one file per running copy
`roster/<id>@<instance>.json`, with a heartbeat. Withdrawal removes only your own file.
**Why.** With one file per app id, the first of two copies to exit erased the other's presence. A viewer also needs to tell "crashed" (stale) from "never ran" (absent), so there is a scan that returns status, and a `running()` that hides the dead.

### 7. The Venue session hides "real", "absent" and "fake"
App code calls the same methods against a real broker, no broker (a local session that says so in plain words), and a fake. Refusals are typed (`doesNotFit`, `forbidden`; everything else is `unavailable`), and a lease that is lost is reported, not swallowed.
**Why.** It let render-queue run in all three modes with no branches in app code, and it made the real daemon's behaviour (a refusal that arrives as a different HTTP code than expected) testable.
**Not hidden on purpose:** registering an app with the broker. That needs an operator with authority (four manual steps today) and an app must not be able to grant itself access. The Kit documents the steps and stays out of them.

### 8. Peers are opt-in through the manifest
An app that wants peers lists `"peers"` in `kits`; asking for a hub without it is an error (`KitNotDeclared`).
**Why.** It keeps the core small and gives the manifest's `kits` list a real job. It was the only piece of evidence for "load Kits as needed" that the demo apps produced; none of them wanted runtime loading.

### 9. Several small rules in the peer layer, each from a failure
* **Scope is `(account, app id)`.** A peer of another app or account is never offered, never admitted, and a test proves an app B peer cannot receive app A traffic.
* **Only the lower peer id dials.** Otherwise two copies open two links to each other.
* **`seq` is per link and restarts at 1.** A gap is visible to the app as a jump; a bounded reorder buffer delivers in order and skips a gap that stays open.
* **A full outbox fails `send`; it never silently drops.** Only the app knows what is safe to lose.
* **Announcements carry a heartbeat.** A crashed copy's announcement used to stay for 45+ seconds and cost ten failed dials; with a one-second beat, a beat older than four seconds is ignored and the copy is gone in about 3.5 seconds. (Process-id checks were rejected: they are unreliable across containers.)

### 10. Build a Kit piece when the second app copies it
The ledger: shim code across the six apps was 727 lines, 330 after the first migration, **777 after coordination was added** (it rose, because every app wrote the same peers helpers), and **164** after those helpers moved into the Kit. Calculator, minesweeper and render-queue ended with none. The remaining four helpers (a notification helper, a large-blob transfer, a manifest scan, a process check) each have exactly one user and stay in their apps.

## What we deliberately did not build

* **Runtime Kit loading** (BeOS add-ons). No demo app wanted it; Flutter builds are static anyway. Selection happens at build time and opt-in happens in the manifest.
* **A looper/handler message model** like BeOS's. Dart and Rust each have an event loop; a third one would not map onto both.
* **A sync engine.** The notepad's sync is about 700 lines of app code because *what to do on a conflict* is a product decision. A shared engine would have to make it for you.
* **Launch, quit and focus from the launcher.** A file roster can say who is running; it cannot ask an app to quit. A control socket per app is one possible design; it is not built.
* **Authentication.** The Kit scopes by account and app id and says so loudly; it does not prove either. See below.

## Still open

These need a decision, and some need an owner other than the Kit's maintainers.

| Question | Why it is open |
|---|---|
| Is `seq` per link (restarts at 1; shows loss as a jump) or one counter per sender (orders, cannot show loss)? | The Dart core does the first; a Rust prototype of the envelope did the second. The first is the better semantics, but it is a contract decision. |
| Is `kind` a closed set or a free string with a reserved `kit.` prefix? | Same split between the two prototypes. |
| What should the default resource-broker consumer name be? | Today it is the last segment of the app id, so `dev.a.notepad` and `org.b.notepad` collide. A derived `<last>-<8 hex>` works but changes a fixture. |
| May an app id contain a hyphen? | The pattern allows it (`render-queue`), but Linux application ids cannot contain one, so runner ids have to be derived. One demo app's bundle and manifest ids disagree today. |
| How does "the same app" become a proof and not a string? | Needs a per-app credential and a signed capability. Today an app id is whatever a program types. |
| What is a transport's maximum payload? | The spec's 1 MiB is only the outer bound; one real transport allows about 64 KiB minus the header. Providers need to declare their own limit and fail before the wire. |
| How should acknowledgement, large transfer, replay for a late joiner and liveness work? | Every demo app that needed them built its own. They are the next candidates to move into the Kit once a second app copies one. |
| How do a Dart context and a Rust core in one app share one context? | Mostly answered, in [spec section 8](../spec/APP-CONTEXT.md#8-sharing-one-context-between-a-dart-ui-and-a-rust-core): if both sides opened a context they would announce twice and write one settings file twice, so one side (the owner) opens it and hands the resolved directories and instance id to the other, which adopts them. One demo app (in The Kit Book) exercises this, on macOS and, headless, in a Linux container; it has not been run on a real Linux desktop. |
| Account and device identity | Peers use `local` as the account and a generated device id until a real household identity exists. |
| Should sandboxed apps share a roster? | Needs a platform answer (an app group or an exception), not a Kit one. See [Platforms](PLATFORMS.md). |
