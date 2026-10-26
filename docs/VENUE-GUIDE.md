# Venue guide

How an app built on the App Context Kit asks Venue for a share of a machine's resources, and what happens when Venue says no, goes away, or the app dies.

Venue is a resource broker: an app asks it for a **hold** (a reservation of some capability, for example "run a container"), and Venue grants it, refuses it, or takes it back when the lease runs out.

This guide covers the Kit's Venue session in Dart and Rust. **The Kit's Rust crate has no remote Venue session**: it has the `local` and `fake` sessions only, so everything below that talks to a daemon (the `venue` session, pinned TLS) is Dart only. The rules behind it are in [`spec/APP-CONTEXT.md`](../spec/APP-CONTEXT.md) (sections 3, 5 and 7). Each snippet below was run: against the mock session, against the local fallback, and against a throwaway Venue daemon (see [Testing against a daemon](#testing-against-a-daemon)). The daemon is not part of the App Context Kit repository.

Contents: [the session](#the-session) · [choosing a session](#how-a-session-is-chosen) · [API](#the-api) · [refusals](#refusals) · [leases and orphans](#leases-crashes-and-orphan-holds) · [pinned TLS](#pinned-tls) · [registering an app](#registering-an-app-with-venue) · [local-only](#running-without-venue) · [testing against a daemon](#testing-against-a-daemon) · [open items](#open-items-and-who-owns-them)

## The session

`ctx.venue` is a `VenueSession`. It has three implementations, and app code calls the same methods on all of them.

| `kind` | When you get it | What a hold means |
|---|---|---|
| `venue` | A daemon answered and a token was found (Dart only: the Rust crate has no remote session) | A real reservation. Other apps on the machine are held to the same limits. |
| `local` | Venue is off, not configured, or not reachable (and the manifest allows that) | A bookkeeping entry inside your process. Nothing stops another app, or another copy of yours, from "holding" the same thing. |
| `fake` | Mock mode (`APP_CONTEXT_MODE=mock`) | An in-memory node with a fixed capacity, for tests. |

`ctx.venue.description` is one sentence saying which you got, for example `Venue: local (Venue not configured)`. The context also puts it in `ctx.notes`, with severity `warning` when Venue was expected but could not be used. Show it somewhere. The `local` session gives no cross-app protection, and the person using the app should be able to tell.

Hiding the difference is the point: the app has one code path. The cost is the `local` row above. The session cannot make a promise only a daemon can keep, so it tells you instead.

## How a session is chosen

The manifest (`app.json`) has an optional `venue` block:

```json
{
  "id": "com.slashbuilder.demo.render-queue",
  "name": "Render Queue",
  "version": "0.1.0",
  "kits": ["venue"],
  "venue": { "mode": "auto", "consumer": "render-queue" }
}
```

`venue.mode` is `auto` (the default), `on` or `off`. `venue.consumer` is the name Venue knows this app by. It defaults to the last segment of `id`, so `dev.a.notepad` and `org.b.notepad` would both default to `notepad`. Set it explicitly if that could clash.

The context decides in this order and stops at the first step that applies.

1. **Mock mode** (`APP_CONTEXT_MODE=mock`, or `<PREFIX>_MODE=mock`): always the `fake` session, whatever `venue.mode` says.
2. **`venue.mode` is `off`**: always `local`, with the description "Venue is off for this app".

Steps 1 and 2 never look at the token or the daemon. Otherwise:

| # | Condition | `venue.mode: auto` | `venue.mode: on` |
|---|---|---|---|
| 3 | `VENUE_TOKEN_FILE` is set but the file is missing, empty or unreadable | `local`; the description names the problem; the note has severity `warning` | open fails with `VenueUnavailable` |
| 4 | No token anywhere | `local` ("Venue not configured") | open fails: "Venue is required but no token was found" |
| 5 | The daemon does not answer `GET /healthz` | `local` ("Venue did not answer at ..."); severity `warning` | open fails: "Venue is required but ... did not answer" |
| 6 | Otherwise | `venue` | `venue` |

Checked against the code and run when this page was written: `off`, `auto` and `on` with no token, `on` and `auto` with a dead daemon, and a missing token file.

### Token lookup

First match wins:

1. `VENUE_TOKEN`: the token itself.
2. `VENUE_TOKEN_FILE`: a path to a file holding the token.
3. `<config>/venue-token`, where `<config>` is the app's config directory (see [Platforms](PLATFORMS.md)).

Whitespace around the token is trimmed. An empty variable counts as unset.

**A named-but-missing token file is an error, not a fall-through.** If `VENUE_TOKEN_FILE` is set and the file is missing, empty or unreadable, the Kit does not go on to try `<config>/venue-token`. It reports the problem (step 3 above). A typo in the variable shows up as an error instead of being hidden by another token source. `VENUE_TOKEN` still wins over a broken `VENUE_TOKEN_FILE`. The default file (item 3 of the lookup) is different: if it is missing or empty, that just means "not configured".

Dart and Rust implement this the same way, with tests in both. In Rust a token that is found cannot connect to anything: with `auto` the session is `local` and its description says the crate has no remote Venue session, and with `on` the context fails to open.

```text
$ APP_CONTEXT_SCRATCH=$(mktemp -d) VENUE_TOKEN_FILE=/tmp/nonexistent-token dart run bin/hold.dart
Venue: local (VENUE_TOKEN_FILE is set to /tmp/nonexistent-token but the file does not exist)
ran under a local hold named job-1
```

### Other variables

| Variable | Meaning |
|---|---|
| `VENUE_DAEMON` | Where the daemon is. Default `http://127.0.0.1:7878`. Write it as `scheme://host[:port]` with no path. Only the Dart core uses it. |
| `VENUE_DAEMON_FINGERPRINT` | SHA-256 fingerprint of the daemon's TLS certificate. See [Pinned TLS](#pinned-tls). |
| `APP_CONTEXT_MODE`, `<PREFIX>_MODE` | `real` or `mock`. Mock gives you the `fake` session. |

The health check waits up to 2 seconds for an answer. Opening a connection to an unreachable address is capped at 5 seconds by the Dart transport, so it can delay startup. In `auto` mode that delay is followed by the local fallback.

The token belongs to one consumer name. Use the token issued for the name in `venue.consumer`. A token used under another name is refused by the daemon with HTTP 403 (`forbidden`, see [Refusals](#refusals)); this was seen with a real daemon.

The health check needs no token, so **a wrong token is not caught when the context opens**. The session connects, and the first call fails with HTTP 401 as `VenueUnavailable` (`status=401: holds: HTTP 401: {"error":{"code":"unauthorized",...}}`, checked when this page was written).

## The API

Dart (`dart/app_context_kit/lib/src/venue/venue_session.dart`) and Rust (`rust/src/venue.rs`) expose the same operations.

| Operation | Dart | Rust | What it does |
|---|---|---|---|
| ask | `hold(need, {leaseSeconds = 300})` | `hold(&need, lease_seconds)` | Reserve. Returns a `VenueHold`. |
| begin | `start(hold)` | `start(&hold)` | Tell Venue the work has begun. |
| keep | `renew(hold)` | `renew(&hold)` | Extend the lease. |
| give back | `release(hold)` | `release(hold)` | Free the hold. Already gone (HTTP 404 or 410) counts as success. |
| list mine | `holds()` | `holds()` | This consumer's own live holds. Other consumers' holds are never listed. |
| nodes | `nodes()` | `nodes()` | What Venue offers, as raw JSON maps. |
| the loop | `withHold(need, body, ...)` | `with_hold(&need, lease, body)` and `with_hold_opts` | `hold`, `start`, renew in the background while `body` runs, then `release`, also on error. |
| the loop, patiently | `withHoldWaiting(need, body, maxWait: ...)` | not built | Like `withHold`, but retries a refusal for a while. |

In Rust the calls block and `release` consumes the hold, so releasing twice does not compile. In Dart everything returns a `Future`.

A `VenueNeed` is a name, a contract class, and optional parameters. The name must be unique among your live holds. The render-queue demo builds it from a run id plus a job number, because a leftover hold with the same name is refused. The Kit cannot choose the contract class for you; only the app knows what kind of work it is asking for. The examples use `container.run.v1`.

### Take a hold

Dart (runs unchanged in `real`, `mock` and with no Venue at all):

```dart
import 'package:app_context_kit/app_context_kit.dart';

Future<void> main() async {
  final manifest = AppManifest.fromJson({
    'id': 'com.slashbuilder.demo.render-queue',
    'name': 'Render Queue',
    'version': '0.1.0',
    'kits': ['venue'],
    'venue': {'mode': 'auto', 'consumer': 'render-queue'},
  });

  await AppContext.run(manifest, (ctx) async {
    print(ctx.venue.description);

    const need = VenueNeed(name: 'job-1', contractClass: 'container.run.v1');
    final result = await ctx.venue.withHold(
      need,
      (hold) async => 'ran under a ${hold.where} hold named ${hold.name}',
      leaseSeconds: 30,
    );
    print(result);
  });
}
```

Output with nothing configured, in mock mode, and against a daemon:

```text
Venue: local (Venue not configured)
ran under a local hold named job-1

Venue: fake (mock mode)
ran under a fake hold named job-1

Venue: connected to http://127.0.0.1:7878 as render-queue
ran under a venue hold named job-1
```

To run it, depend on the package by path (it is not published) and set `APP_CONTEXT_SCRATCH` so the run writes to a temporary directory instead of your real app directories:

```yaml
dependencies:
  app_context_kit:
    path: ../app-context-kit/dart/app_context_kit
```

```sh
APP_CONTEXT_SCRATCH=$(mktemp -d) dart run bin/hold.dart
```

Rust (`app-context-kit = { package = "slashbuilder-app-context-kit", path = "../app-context-kit/rust" }`; the crate has no remote Venue session, so this runs on the `local` session, or on the `fake` one in mock mode):

```rust
use app_context_kit::{
    AppContext, HoldOptions, Manifest, OpenOptions, RefusalKind, VenueError, VenueNeed,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest = Manifest::parse(
        r#"{
            "id": "com.slashbuilder.demo.render-queue",
            "name": "Render Queue",
            "version": "0.1.0",
            "kits": ["venue"],
            "venue": { "mode": "auto", "consumer": "render-queue" }
        }"#,
    )?;
    // Reads the process environment (VENUE_TOKEN_FILE, APP_CONTEXT_MODE, ...).
    let mut ctx = AppContext::open(manifest, OpenOptions::default())?;
    println!("{}", ctx.venue.description());

    // Hold, start, renew in the background, release; also if the body panics.
    let need = VenueNeed::new("job-1", "container.run.v1");
    let outcome = ctx.venue.with_hold_opts(
        &need,
        30,
        &HoldOptions {
            on_lease_lost: Some(&|e: &VenueError| eprintln!("lease lost: {e}")),
        },
        |hold| format!("ran under a {} hold named {}", hold.kind, hold.name),
    )?;
    println!("{}", outcome.value);
    println!("renewals failed: {}", outcome.hold.renewal_failure_count());

    ctx.close()?;
    Ok(())
}
```

`with_hold` is the same without the options and returns only the body's value. `with_hold_opts` also hands back the hold, so you can read after the call whether any renewal failed.

### What `withHold` does

1. `hold`. If Venue refuses, the body never runs and nothing is released.
2. `start`. If that fails, the hold is released and the start error is what you see.
3. Renews every third of the lease (clamped to between 1 second and 1 hour), unless you pass `renewEvery`. Renewals never overlap, and none is sent after release.
4. Runs your body.
5. Releases, whether the body returned, threw, or (in Rust) panicked.

Two things are recorded, not thrown:

* **A failed renewal** sets `hold.leaseLost` (Rust: `lease_lost()`), counts in `renewalFailures`, and calls `onLeaseLost` once, on the first failure. The body keeps running. Stopping the work is your decision. `leaseLost` is latched by a single failed renewal, so one network blip sets it even if most of the lease is still left. Renewing does not update `hold.expiresAt`, so the hold object cannot tell you how much lease remains.
* **A failed release** never replaces your body's result or error. It is kept in `hold.releaseError`.

The render-queue demo treats a lost lease as a failed job: it cancels the work, shows the reason, and offers Retry, because after a failed renewal the app cannot be sure Venue still counts the slot as its own. That is a policy choice for one app, not something the Kit does for you. It is tested with a session whose renewals fail. A daemon that stops answering mid-job was not tested.

The context does not release holds taken with `hold()` directly. `ctx.close()` closes the session and nothing else. Only `withHold` and `withHoldWaiting` release what they took. If you call `hold()` yourself, release it yourself.

### Wait for room

`withHoldWaiting` retries a refused hold until it is granted or `maxWait` is used up.

```dart
import 'dart:async';
import 'package:app_context_kit/app_context_kit.dart';

Future<void> main() async {
  final manifest = AppManifest.fromJson({
    'id': 'com.slashbuilder.demo.render-queue', 'name': 'Render Queue', 'version': '0.1.0',
  });
  // Run with APP_CONTEXT_MODE=mock: the fake node has room for one hold at a time, so the second job has to wait.
  final ctx = await AppContext.open(manifest, fakeCapacity: 1);
  final venue = ctx.venue;

  final first = await venue.hold(const VenueNeed(name: 'first', contractClass: 'container.run.v1'));
  Timer(const Duration(seconds: 2), () => venue.release(first));

  try {
    final answer = await venue.withHoldWaiting(
      const VenueNeed(name: 'second', contractClass: 'container.run.v1'),
      (hold) async => 'got ${hold.name}',
      maxWait: const Duration(seconds: 10),
      retryEvery: const Duration(seconds: 1),
      onWaiting: (refusal, attempt) => print('refused (${refusal.kind.name}), attempt $attempt: ${refusal.plainReason}'),
      onLeaseLost: (hold, error) => print('lease lost on ${hold.name}: $error'),
    );
    print(answer);
  } on VenueRefused catch (e) {
    print('gave up: ${e.kind.name}${e.retryable ? " (could have been retried)" : ""}: ${e.plainReason}');
  } on VenueUnavailable catch (e) {
    print('Venue could not be asked: ${e.reason}');
  } on HoldWaitCancelled {
    print('cancelled');
  } finally {
    await ctx.close();
  }
}
```

```text
$ APP_CONTEXT_MODE=mock APP_CONTEXT_SCRATCH=$(mktemp -d) dart run bin/wait.dart
refused (doesNotFit), attempt 1: the fake node is full
refused (doesNotFit), attempt 2: the fake node is full
got second
```

Rules:

* `maxWait` is required. `Duration.zero` makes it exactly `withHold` (fail fast).
* It retries `doesNotFit` always. It retries `forbidden` only while `holds()` shows this consumer still holds something. See the next section for why, and for when that is wrong.
* It never retries `VenueUnavailable`, and never retries an error thrown by your body.
* Waiting is counted in naps of `retryEvery`, not read from a clock, so it behaves under a test's fake time. It naps at most `maxWait ~/ retryEvery` times and then rethrows the **last** refusal.
* `cancel` (a `Future`) ends the wait at once with `HoldWaitCancelled`. A hold granted in that same instant is released, not leaked.
* `retryEvery` must be positive.

Every waiting consumer polls Venue about once per `retryEvery`. Venue has no queue and no push, so there is no way to be told "there is room now". In one earlier test with five waiting jobs against a real daemon, each job asked 15 to 20 times.

Rust has no `with_hold_waiting`. The refusal kinds are enough to write the loop yourself (see below), but the Kit does not ship it.

## Refusals

Venue's answer to `hold` is one of three things.

| Dart | Rust | HTTP | Meaning | Retry? |
|---|---|---|---|---|
| `VenueRefused(kind: doesNotFit)` | `VenueError::Refused { kind: RefusalKind::DoesNotFit, .. }` | 409 | Nothing fits right now, or the hold name is already held. | Yes. It can clear when someone releases. |
| `VenueRefused(kind: forbidden)` | `VenueError::Refused { kind: RefusalKind::Forbidden, .. }` | 403 | Not allowed: over the consumer's live-hold limit, no grant for that kind of work, an observer token, or a token that does not match the consumer. | Not by itself. See below. |
| `VenueUnavailable` | `VenueError::Unavailable` | anything else, or no answer | Venue could not be asked, or answered with something that is neither success nor a refusal: connection failure, timeout (15 seconds per request), 401, 5xx. | Not by the Kit. Your policy. |

`VenueUnavailable.status` carries the HTTP status when there was one. A hold Venue no longer has shows up this way too, as a failed renewal. Against a real daemon, renewing a hold that had been released gave `renew: HTTP 404` with the code `not_held`. The Kit treats 404 and 410 on **release** as "already gone". What `renew` returns for a lapsed lease was not observed.

`VenueRefused.retryable` is true only for `doesNotFit`. `VenueRefused.reason` is the daemon's raw response body (shortened to 300 characters). `plainReason` unwraps the daemon's `error.message` so you can show a sentence. In Rust the message is `hold: HTTP 403: <raw body>`; there is no `plain_reason`.

Real answers from a daemon (consumer `calc`, live-hold limit 3):

```text
refused: kind=forbidden retryable=false
reason: calc already holds 3 live placements (limit 3); many small holds are how a node gets starved

kind=doesNotFit retryable=true: Placement/clash-doc is already held; renew it, release it, or choose another name

status=401: holds: HTTP 401: {"error":{"code":"unauthorized","message":"a valid token is required"}}
```

### Handling them

Rust, telling the three apart:

```rust
match ctx.venue.hold(&need, 30) {
    Ok(h) => ctx.venue.release(h)?,
    Err(e) => match e.refusal_kind() {
        Some(RefusalKind::DoesNotFit) => println!("full right now, retry later: {e}"),
        Some(RefusalKind::Forbidden) => println!("not allowed, do not retry: {e}"),
        None => println!("Venue could not be asked: {e}"),
    },
}
```

With the fake session at capacity this prints `full right now, retry later: Venue refused (doesNotFit): the fake node is full`.

### The documented limitation: one code for the limit and for everything else

Venue answers its per-consumer live-hold limit with HTTP 403 and the code `forbidden`. It gives the same code for a missing grant, an observer token, and a token that does not match the consumer. There is no machine-readable reason, so the Kit cannot tell "you are over your own limit" (will clear when you release something) from "you may never do this" (will not).

The Kit's current rule: `forbidden` is not retryable. `withHoldWaiting` adds a heuristic: if the daemon says `forbidden` and `holds()` shows this consumer still has live holds of its own, assume it is the limit and wait. If you have none, give up at once.

The heuristic is wrong in one case. A consumer that both holds something and lacks the grant for a new kind of work will wait the full `maxWait` for nothing and then get the real refusal. Checking costs one extra `GET /v1/holds` per retry. Verified against a real daemon: a consumer at its limit waits, is granted when one of its own holds ends, and gives up at `maxWait` with `forbidden` when nothing is released. The case where the heuristic is wrong was reasoned from the code, not run.

The fix belongs to Venue: a distinct reason, or status, for "over the live-hold limit". The Kit would then drop the heuristic. See [Open items](#open-items-and-who-owns-them).

## Leases, crashes and orphan holds

A hold is a lease. Venue frees it when the lease runs out unless you renew it. That is what gives a dead app's reservation back, and it is also why a crash costs you something.

**What happens to a killed app's holds.** They stay live, and keep counting against the consumer's limit, until the lease lapses. A clean exit releases them; `kill -9` does not.

Measured against a real throwaway daemon, three running holds with a 6 second lease, the process killed with `kill -9`, then the app relaunched at once:

| | This run | Earlier run |
|---|---|---|
| Orphans reported by the startup scan | 3, at 0.24 s after the kill, each with 4.4 s left | 3, at 0.23 s, each with about 4.0 s left |
| New job granted | 5.4 s after the kill | 4.3 s after the kill |
| Holds left at the daemon afterwards | 0 | 0 |

The spread is arithmetic. The app renews every third of the lease (2 s here), so the last renewal happened up to 2 s before the kill and the lease ends 4 to 6 s after it. The relaunched job then polled once a second, so it was granted at the next poll after the lapse.

With the Kit's default lease of 300 seconds, the same crash keeps the consumer's quota for up to five minutes. The render-queue demo's 30 second lease (renewed every 10 s) would cost up to about 30 s.

**So keep leases short.** Choose the shortest lease that still survives your renewal being late by a couple of intervals. Tradeoff: a shorter lease means more renewal traffic and a smaller margin for a slow network or a stalled event loop. Do not take the default 300 seconds for work that lasts seconds.

A clean quit of the render-queue demo with three jobs running left no holds within 1.5 seconds. That works because the app's close hook cancels its jobs and waits for each `withHold` to release. This was measured earlier and not re-run for this guide.

### Finding orphans at startup

`holds()` lists this consumer's own live holds. Subtract the ones this run took, and what remains came from a crash, or from another running copy of the same app.

```dart
import 'package:app_context_kit/app_context_kit.dart';

/// Holds this consumer still has that this run did not take: left by a crash, or taken by another copy.
Future<List<VenueHold>> findOrphans(VenueSession venue, String thisRunPrefix) async {
  return [
    for (final h in await venue.holds())
      if (!h.name.startsWith(thisRunPrefix)) h,
  ];
}

Future<void> main() async {
  final manifest = AppManifest.fromJson({'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0'});
  final ctx = await AppContext.open(manifest, fakeCapacity: 3);
  final venue = ctx.venue;

  // Pretend an earlier run died holding this.
  await venue.hold(const VenueNeed(name: 'run-old-1', contractClass: 'container.run.v1'), leaseSeconds: 60);

  final orphans = await findOrphans(venue, 'run-new-');
  for (final h in orphans) {
    final left = h.expiresAt?.difference(DateTime.now()).inSeconds;
    print('orphan ${h.name}, lapses in about ${left}s');
    await venue.release(h);
  }
  print('after release: ${(await venue.holds()).length} holds');
  await ctx.close();
}
```

```text
orphan run-old-1, lapses in about 59s
after release: 0 holds
```

This needs hold names that identify the run. The render-queue demo names holds `rq-<runId>-<n>`, shows "N holds from an earlier run still count against your quota", lists each with its time to lapse, and offers a Release button.

Caveat: two running copies of one app share a consumer, so each sees the other's holds as orphans. Check the roster (`Roster.scan()`) before telling the person a hold is stale; the demo does, and only changes its wording.

### A second liveness clock

The roster (the presence file each app writes) and the Venue lease both answer "is this process still alive?", with separate timers. After `kill -9` they disagreed in an earlier measurement: Venue freed the hold in 6 s, the roster still said "running, stale" for up to 15 s. The Kit has not merged them. Treat the Venue lease as the answer for Venue, and the roster as the answer for "who is on this machine".

## Pinned TLS

By default the daemon is plain HTTP on the loopback interface. The bearer token travels in a header, in the clear. That is acceptable on `127.0.0.1`. For any daemon on another machine, use HTTPS.

A self-signed daemon (`venued --tls`) prints its certificate fingerprint when it starts. Give the app that value:

```sh
VENUE_DAEMON=https://127.0.0.1:17879 \
VENUE_DAEMON_FINGERPRINT=sha256:<the 64 hex digits venued printed> \
VENUE_TOKEN_FILE=/path/to/token \
  dart run bin/hold.dart
```

How the pin works:

* With a fingerprint, **no certificate authority is trusted at all**. Every certificate is shown to a check, and only one whose SHA-256 equals the pin is accepted. There is no hostname check and no expiry check. The pin is the identity.
* Nothing is sent, not even the token, to a server that does not present the pinned certificate.
* These spellings are accepted: with or without `sha256:`, upper or lower case, with or without colons. They are normalised to `sha256:` and 64 lower-case hex digits. (Covered by `dart/app_context_kit/test/transport_pin_test.dart`; the Rust crate has no TLS client.)
* Without a fingerprint, Dart falls back to the system's trusted roots, so a CA-signed daemon should work (not tested).

What a wrong pin looks like depends on how you reach the daemon.

**Through `AppContext.open`**, the health check fails first, and the context reports only that the daemon did not answer. In `auto` mode:

```text
Venue: local (Venue did not answer at https://127.0.0.1:17879)
```

The note has severity `warning`. In `on` mode, open fails with "Venue is required but https://127.0.0.1:17879 did not answer". This is the same text whether the pin is wrong, missing or malformed. The reason is not in the text.

**Through a session you build yourself** (`RemoteVenue` with `IoTransport(fingerprint: ...)`), the reason is in the error. These are the three `VenueUnavailable` messages from a real TLS daemon:

```text
GET /v1/nodes: the daemon's certificate (sha256:0aded5...5974) is not the one that was pinned (sha256:abab...abab)
GET /v1/nodes: the daemon's certificate is not trusted by the system; a self-signed venued needs its fingerprint (VENUE_DAEMON_FINGERPRINT=sha256:...)
GET /v1/nodes: the fingerprint "nonsense" is not 32 bytes of hex (sha256:...)
```

(The first line has the fingerprints shortened here.) If an app shows "did not answer" and you expect TLS, build a `RemoteVenue` by hand as above to see the cause.

Plain `http://` pointed at a TLS port fails quickly rather than hanging (well under 10 s in Dart).

Verification: `dart/app_context_kit/test/venue_tls_test.dart` (14 daemon-backed tests) runs against a daemon that serves a self-signed certificate. It skips unless `VENUE_TLS_DAEMON`, `VENUE_TLS_FINGERPRINT` and `VENUE_TOKEN_FILE` are set, and the case list is in [Testing](TESTING.md#pinned-tls). The 14 passed when this page was written, against a throwaway daemon; they were not re-run for the public release. A further 4 Dart tests that need no daemon (`transport_pin_test.dart`) are part of the normal Dart run (365 passed, 7 skipped).

## Registering an app with Venue

Venue only grants holds to consumers it knows about, and only for the kinds of work they have been granted. Today, introducing an app to a daemon takes four manual steps. These are the four a throwaway registry needed for each demo app, written as the Venue project's own command line (that command line is not part of the App Context Kit repository):

1. Add an entry for the consumer to the registry's `authority.yaml`, with a class, a priority cap and a live-hold limit:
   `- {name: render-queue, class: Consumer, maxPriority: 100, maxLiveHolds: 3}`
2. `venue --as declared principal add render-queue`
3. `venue --as declared grant use container.run.v1 --principal render-queue`
4. `venue --as declared token add render-queue --manager render-queue`, which prints the token.

Steps 2 and 3 need an operator with authority over the registry; the commands pass `--as declared` on steps 2 to 4; what that flag does is described in Venue's own documentation. Grants are authority: they decide what a program may ask the machine to do.

**The Kit cannot do this for the app, and should not.** An app that could grant itself the right to run work would make the limit meaningless. So "Venue wired in from the first launch" cannot be done by the app on its own. The app can only ship its manifest and wait for someone with authority to provision it.

What a provisioning step would need (none of this is built; it is a description of the gap):

* **Input.** The manifest's `venue` block gives the consumer name. It does not say which contract classes the app will ask for. Today that is in the app's code (`container.run.v1` above). The manifest could declare it, so the provisioner can build the grants. The Kit does not.
* **Decisions only an operator can make.** The priority cap and the live-hold limit (3 in the demo registry).
* **Authority.** Something that holds the right to edit the registry and run steps 2 to 4: an installer, an app store, or a person. Which of these runs it is undecided.
* **Delivery.** The token has to reach the app: a file at `<config>/venue-token`, or an environment variable set by whatever launches it. Under the macOS sandbox, a token file outside the app's container cannot be read; see [Platforms](PLATFORMS.md).
* **Repeatability.** Running it twice on upgrade should not fail or duplicate, and uninstalling should remove the grant. Not designed.

## Running without Venue

Venue is optional. An app can run entirely local:

* Set `"venue": { "mode": "off" }` and nothing ever connects. The session is `local` with the description "Venue is off for this app".
* Leave the mode at `auto` and configure nothing. The session is `local` ("Venue not configured"). If a daemon is configured later, the same binary connects.

What `local` does:

* Holds exist only in your process. A second hold with the **same name** in the same process is refused with `doesNotFit`. Different names are all granted, with no limit. In an earlier test, five render jobs ran at once under `local`, where a real daemon with a limit of 3 would have run three.
* `renew` does nothing, `nodes()` is empty, and `holds()` lists this process's holds.
* Nothing protects against another app, or another copy of yours, using the same resource at the same time.

If your app can wait for capacity, the people using it get the right behaviour only on a `venue` session. On `local`, say so (the description already does).

## Testing against a daemon

The App Context Kit repository does not contain a Venue daemon and does not ship a script that starts one. To run the real-daemon tests, start any compatible daemon yourself and give it what the tests expect:

* A consumer named `calc`, granted `container.run.v1`, with a limit of 3 live holds (the limit test relies on it). Introduce it with the four registration steps above.
* A token file for that consumer.
* A node whose heartbeat stays fresh. A daemon whose node was last probed about two minutes ago refuses every hold with 409 `does_not_fit` ("the node's heartbeat has lapsed"); if you write your own setup, keep the node probed (for example every 30 seconds).
* Plain HTTP on the loopback address is fine for these tests. TLS is only for the pinned-TLS tests.
* The `container.run.v1` capability was chosen because the machine the tests were written on has Docker and no GPU. Whether it needs Docker, and any other contract class, was not tested.

Then:

```sh
cd dart/app_context_kit
VENUE_DAEMON=http://127.0.0.1:7878 \
VENUE_TOKEN_FILE=<path to calc's token file> \
  dart test test/venue_real_test.dart
```

Without `VENUE_TOKEN_FILE` the tests skip with a message, and a skipped run proves nothing about the daemon. When this page was written the file passed 5 of 5 tests against a throwaway daemon; that was not re-run for the public release. The Rust crate has no real-daemon test, because it has no remote session.

The pinned-TLS tests are separate; see [Testing](TESTING.md#pinned-tls).

## Open items and who owns them

| Item | Owner |
|---|---|
| A machine-readable reason (or its own status) for "over the live-hold limit", so the Kit can drop the `forbidden` heuristic. | The Venue project |
| A wait queue or event push, so waiting apps stop polling. | The Venue project |
| A small typed client library for Venue in Dart and Rust. The Kit carries its own Dart HTTP client. The Rust crate has no client: the one it used before was a path dependency on the Venue project's own client, which brought the dependency tree from 11 to 115 packages when measured, and could not be built without that project checked out. | The Venue project |
| A provisioning step: who runs the four registration steps, and how the token reaches the app. | Undecided; the Kit's maintainers |
| Manifest declaration of the contract classes an app needs. | The Kit's maintainers (spec decision) |
| The default for `venue.consumer` (last segment of the id) can collide across vendors. | The Kit's maintainers (spec decision) |
| Daemon behaviour not explained: a hold's `startedAt` was seen about 30 seconds after it was granted, later than `expiresAt`. The Kit does not rely on it. | The Venue project |
| A Rust `with_hold_waiting`. | The App Context Kit (not built) |
| A remote Venue session for the Rust crate (needs the small typed client above first). | The App Context Kit (not built) |
| A real-daemon test of a lost lease because the daemon stopped answering (a released hold is tested). | The App Context Kit (not done) |
