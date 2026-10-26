# App Context Kit: the app context specification (v0.1)

This is the contract both implementations (Rust in `rust/`, Dart in `dart/app_context_kit/`) must satisfy. It is
checked by the shared fixtures in `conformance/`. If an implementer finds the text ambiguous, that is a **finding**:
write it down (as an issue or a note) and do not silently pick; the fixtures win over the prose.

Everything here is a pure function of its inputs (no I/O), so both languages can be tested without a filesystem.

## 1. The manifest (`app.json`)

JSON, not YAML, on purpose: it avoids choosing a Rust YAML library for now.
Whether the real thing is YAML is an open question.

```json
{
  "id": "com.slashbuilder.demo.calc",
  "name": "Calculator",
  "version": "0.1.0",
  "kits": ["venue"],
  "envPrefix": "CALC",
  "venue": { "mode": "auto", "consumer": "calc" }
}
```

Fields: `id`, `name`, `version` required. `kits` optional (default `[]`). `envPrefix` optional. `venue` optional.

Validation, checked in this order; **report the first failure only**, as these codes. A field that is present as `null` is present and invalid (`kits: null` is `bad-kits`). Every pattern must match the **whole string**: a trailing newline fails (this matters to implementations whose `$` also matches before a final newline).

| order | code | rule |
|---|---|---|
| 0a | `not-json` | the source text is not valid JSON (only for `parse(text)`; a parsed value skips this) |
| 0b | `not-object` | the JSON is not an object (an array, a string, `null`...) |
| 1 | `bad-id` | `id` missing or not matching `^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$` (reverse-DNS, at least two segments) |
| 2 | `bad-name` | `name` missing, `null`, not a string, or empty after removing ASCII whitespace (space, tab, CR, LF). Other characters, including U+FEFF, count as content |
| 3 | `bad-version` | `version` missing or not matching `^\d+\.\d+\.\d+$` |
| 4 | `bad-kits` | `kits` present but not a list of strings, or a name not matching `^[a-z][a-z0-9-]*$` |
| 5 | `duplicate-kit` | the same kit name twice (checked only after every name passed rule 4) |
| 6 | `bad-prefix` | `envPrefix` present and not matching `^[A-Z][A-Z0-9_]*$` |
| 7 | `bad-venue` | `venue` present but not an object, or `venue.mode` not one of `auto`, `on`, `off`, or `venue.consumer` present and not matching `^[a-z][a-z0-9-]*$` |

Defaults after validation: `venue.mode` = `auto`; `venue.consumer` = the last segment of `id`; env prefix (below).

## 2. Resolution

Inputs: `manifest`, `platform` (`linux`, `macos`, `windows`), `home` (string), `env` (string map).
Outputs: `prefix`, `dirs.{data,config,state,cache,runtime}`, `roster` (a shared directory), `scratch` (bool), `mode` (`real`/`mock`).

**Prefix:** `manifest.envPrefix`, else the last segment of `id`, upper-cased, with every character outside `A-Z0-9` replaced by `_`.
(`render-queue` becomes `RENDER_QUEUE`.)

**Path joining:** on `linux` and `macos` join with `/`, on `windows` with `\`, whatever the host is.
Before joining, a trailing separator on an *input base* (for example `TMPDIR=/var/T/`) is dropped; the separators are those of the **target platform only** (`/` on linux and macos; both `/` and `\` on windows), so a trailing `\` on a linux base is kept. A base that is only a separator (`/`) is not reduced to nothing: joining `/` and `ID` gives `/ID`, never `//ID`. Values used verbatim (overrides, below) are never trimmed.

**Platform defaults** (`ID` is the manifest id):

| | linux | macos | windows |
|---|---|---|---|
| data | `$XDG_DATA_HOME` else `home/.local/share`, then `/ID` | `home/Library/Application Support/ID/data` | `%LOCALAPPDATA%\ID\data` |
| config | `$XDG_CONFIG_HOME` else `home/.config`, then `/ID` | `home/Library/Preferences/ID` | `%APPDATA%\ID` |
| state | `$XDG_STATE_HOME` else `home/.local/state`, then `/ID` | `home/Library/Application Support/ID/state` | `%LOCALAPPDATA%\ID\state` |
| cache | `$XDG_CACHE_HOME` else `home/.cache`, then `/ID` | `home/Library/Caches/ID` | `%LOCALAPPDATA%\ID\cache` |
| runtime | `$XDG_RUNTIME_DIR/ID` if set, else the **platform-default state directory** (after `XDG_STATE_HOME`, before any override) plus `/run` | `TMPDIR` (else `/tmp`), then `/ID` | `%TEMP%\ID` |
| roster | `$XDG_RUNTIME_DIR` (else `/tmp`), then `/app-context-roster` | `TMPDIR` (else `/tmp`), then `/app-context-roster` | `%TEMP%\app-context-roster` |

(On `windows`, a missing `LOCALAPPDATA`, `APPDATA` or `TEMP` is the error `missing-env`, but **only if a default that needs it is actually used**: a directory fixed by an override or by scratch needs none.)

**Overrides**, highest priority first, for each directory kind `K` in `DATA`, `CONFIG`, `STATE`, `CACHE`, `RUNTIME`:
1. `<PREFIX>_<K>_DIR`: used exactly as given (no id appended, **no trimming**).
2. Scratch: if `APP_CONTEXT_SCRATCH=S` (non-empty), the directory is `S/ID/<kind>` with `<kind>` lower-case, and `roster` is `S/roster`; `scratch` is true. (Scratch joins with `/` on every platform.)
3. The platform default.

`roster` has one override of its own: `APP_CONTEXT_ROSTER_DIR`, which beats scratch.

**Mode:** `<PREFIX>_MODE`, else `APP_CONTEXT_MODE`, else `real`. Allowed values `real`, `mock`; anything else is the error `bad-mode`. Only the variable that wins is checked: a garbage `APP_CONTEXT_MODE` is ignored when `<PREFIX>_MODE` is set. **Error precedence:** `bad-mode` is reported before `missing-env`.
An empty string counts as unset, for every variable above.

## 3. Venue (not in the fixtures; needs a network or a fake)

*(v0.1 changes to this section are in section 5.)*

Reuse Venue's existing variable names so nothing new is invented: `VENUE_DAEMON` (URL, default `http://127.0.0.1:7878`), `VENUE_TOKEN`,
`VENUE_TOKEN_FILE`, `VENUE_DAEMON_FINGERPRINT`. Token lookup: see section 5, item 2 (a `VENUE_TOKEN_FILE` that is set but missing or empty is an error, never a fall-through). `venue.mode`: `off` never connects; `auto` connects if a token exists and the daemon answers `/healthz`, otherwise
degrades to a **local** session and says so in `description` (the way a larger app words it: "GPU lease: local (Venue not configured)");
`on` fails to open if it cannot connect. In `mock` mode the session is always the in-memory fake. The Rust crate has no remote session: with a token found, `auto` gives a local session that says so (a warning) and `on` fails to open.

## 4. Lifecycle and roster (a minimal first version, not covered by fixtures)

`AppContext.run(body)`: resolve, create the directories, write a presence file `roster/<ID>@<INSTANCE>.json`
(`{"id","name","version","pid","startedAt","heartbeatAt"}`), start a 5-second heartbeat, open Venue, run `body`, then on exit or error
delete the presence file, run the close hooks and close Venue. (Holds are released by `withHold`, which is the only thing that tracks them; a context does not release holds it did not take through `withHold`.) A presence file is stale when `heartbeatAt` is older than 15 seconds. This is the
`BRoster` question: **does it belong here, in Venue, or nowhere?** The Kit ships the smallest version so the answer comes from use.

## 5. v0.1 decisions

Building the second implementation showed that two implementations can pass 41 fixtures and still disagree. These are the decisions that close the gaps it exposed.
Items marked **(fixture)** are covered by `conformance/*.json`; the rest are behaviours each implementation must test itself.

1. **(fixture)** The manifest, resolution and mode rules above, including the new codes and precedences.
2. **Token lookup (replaces section 3's order).** `VENUE_TOKEN`; else the file named by `VENUE_TOKEN_FILE`; else `<config>/venue-token`.
   If `VENUE_TOKEN_FILE` is **set** but the file is missing or empty, that is a configuration error and the lookup does **not** fall through
   to `<config>/venue-token`: `auto` degrades to a local session whose description names the problem; `on` fails to open.
3. **Config is never silently overwritten.** A `config.json` that is not valid UTF-8 or not a JSON object is *damaged*. `open` reports it
   (`problem`) and still opens; `set` and `save` then fail with a damaged-config error until the caller explicitly sets the file aside
   (renamed to `config.json.corrupt`). `get<double>` accepts a whole number (JSON `3` reads as `3.0`).
4. **`close()` is idempotent and isolates hooks.** The second call does nothing. Every `onClose` hook runs even if an earlier one throws;
   after all have run, the errors are raised together. Venue is closed last.
5. **Roster instance id.** Each opened context draws a random 8-hex-digit instance id. The presence file is `roster/<ID>@<INSTANCE>.json` and
   carries an `instance` field; withdrawal removes only the context's own file, so two copies of one app no longer erase each other.
   `running()` hides stale and unreadable entries (as before); `scan()` returns every entry with its status (`live`, `stale`, `unreadable`) so a viewer can tell a crash from "never ran".
6. **Typed Venue answers.** `VenueRefused` carries a `kind`: `doesNotFit` (HTTP 409) or `forbidden` (HTTP 403, including the live-hold limit).
   `VenueUnavailable` is everything else (transport failure, 401, 5xx). Venue gives no machine-readable reason for a 403 (the limit and other
   refusals share the code `forbidden`): **a finding for the Venue project**; until it does, `forbidden` is treated as not retryable.
7. **Holds the app can see.** `VenueSession.holds()` lists this consumer's own live holds (to find orphans after a crash).
   `withHold` no longer swallows renewal failures: the hold records them and the optional `onLeaseLost` callback fires; a failing `release`
   never replaces a successful body result (it is recorded on the hold).
8. **Fake capacity** is a parameter of `AppContext.open` (`fakeCapacity`, default 1), not an environment variable.
9. **Notes carry a severity.** `ctx.notes` is a list of `{severity: info|warning|error, text}`.
10. **Flutter.** The core packages stay free of Flutter. A companion package supplies the pieces a Flutter app needs: loading `app.json` from
    an asset, a single guarded close on exit (window close, quit, SIGINT, SIGTERM), a mode badge and a notes banner.
11. **Coordination.** See section 6.

## 6. Coordination between copies of the same app (the Kit manages, the app defines)

The Kit does not decide what coordination means. The app supplies a hook; the Kit finds, authenticates, connects and routes.

* **Scope key:** `(account, app id)`. A peer is another running copy of the same app id for the same account, identified by `(device, instance)`.
* **Envelope:** a Kit-owned header `{account, app, channel, from:{device,instance}, seq, kind}` and an **opaque** app-owned payload with an app-declared `schema` integer. The Kit never reads the payload.
* **Provider interface** (how peers are found and carried; the Kit ships a fake and a loopback one): `discover()` (a stream of candidate peers), `connect(peer)`, `send(peer, bytes)`, and an inbound stream. Hearth and LAN providers are later work and need the Hearth protocol owners.
* **Hook** (the app's): `channel`; `hello()` (opaque, sent on connect); `admit(peer, theirHello)` returning accept, accept read-only, or reject; `onPeer(peer, change)` for found, ready, lost; `onMessage(from, message)`.
* **Management interface** (the Kit's): a live `peers` view, `send(peer, payload)`, `broadcast(payload)`, `request(peer, payload)` with a timeout, and `close()`.
* **Delivery:** best effort with per-sender ordering by `seq`; anything stronger is the app's.
* **Mock mode** uses the fake provider so apps test coordination with no network.

### 6.1 As built in the Dart core (`dart/app_context_kit/lib/src/peers/`)

The first implementation departs from the sketch above in these ways. They are decisions to keep or reverse, not settled design.

* `admit` may be async (`FutureOr<Admit>`): a pairing prompt or a storage lookup needs it. `AppCoordination.attach(hub)` (default no-op) hands the hook its hub. `hello()` must be JSON-encodable; the hook receives the decoded value.
* **One hub serves one channel**, and `admit` is one answer per peer. An app with several facets (a timer, a notes sync, a game) uses one hub per facet or a mux hook that routes by kind prefix; the Kit has no per-facet admission.
* Providers also have `open(self)` and `close()`; candidates carry `available: false` for withdrawal; `rid` (optional) correlates request and reply, whose reserved kind is `kit.reply`; the `kit.` prefix is reserved.
* **Only the lower `PeerId` dials**, so two copies never open two links. `seq` is per link and restarts at 1 on a new link; a bounded reorder buffer (16 frames, 500 ms) delivers in order and skips a gap that stays open; the app sees loss as a jump in `AppMessage.seq`.
* **A full outbox fails `send` with `PeerOutboxFull`** (256 messages or 8 MiB per peer) instead of dropping: only the app knows what is safe to drop.
* `acceptReadOnly` only tags `peer.readOnly`; the decision is local and the other side is not told. A rejected peer is not redialed until the provider withdraws and re-announces it.
* `send` completing means the transport took the frame, not that the peer applied it. No heartbeat or keepalive yet. No transfer for state over 1 MiB. No replay for a late joiner (use a version in `hello()` and let whoever is ahead push on `ready`).

### 6.2 What the Hearth integration changed (from testing against a local Hearth hub)

* **The app-scoped topic grammar is rejected by the stock hub** (`TOPIC_INVALID`) and needs a one-file hub change (the hub's topic module, about 60 lines). Until the Hearth protocol owners rule on it, carry app traffic on the stock topics with `payload_type = ak.app/<app>` and filter at the receiver.
* **The hub isolates accounts, not apps.** Any device on the account can join any app's topic, so the scope key is hygiene until a per-app credential and grant exist.
* **Provider payload limits differ.** Hearth's effective payload cap is **64 KiB minus the Kit header** (the 1 MiB figure is the whole envelope and above it the hub drops the connection). A provider must declare its maximum payload and `send` must fail before the wire when it is exceeded; the 1 MiB cap in section 6 is the Kit's outer limit only.
* **The Kit must do for itself on Hearth:** Kit-owned correlation ids (the hub's `message_id` is not a safe key) and request deadlines; echo suppression by `from.device` + `from.instance` (the hub echoes to the sender); dedupe by `message_id` across live delivery and catch-up; liveness by a `no_retain` heartbeat no more often than every 30 s (the hub's idle timeout is 90 s and its hourly publish caps are 600 per connection and 6000 per account); reconnect.

### 6.3 Opting in, and who this copy is (`ctx.peerHub`)

* **Peers are an opt-in Kit.** An app lists `"peers"` in `app.json` `kits`; `ctx.peerHub(hook)` throws `KitNotDeclared` otherwise. This is the first place the manifest's `kits` list gates a capability.
* **Account:** `APP_CONTEXT_ACCOUNT`, else config `account`, else `local` (a single-user machine with no household account yet; replaced by the real account when an identity service issues one).
* **Device:** `APP_CONTEXT_DEVICE`, else config `device`; generated once (`d-` plus 8 hex digits) and saved, or ephemeral for the run if the settings file is damaged. **Instance:** the context's instance id.
* **Provider by mode:** an explicit provider; else in `mock` mode a fake network (pass one to share it between copies in a test); else the loopback provider over `APP_CONTEXT_PEERS_DIR` (default: the roster directory plus `-peers`). Hubs are closed with the context.

## 7. Additions (helpers the demo apps each wrote for themselves; additions only, nothing removed or renamed)

Evidence: the apps' `lib/kit_gaps/` files, identical across apps. Each addition below replaces a copy; the apps still compile against their old copies until they are migrated (new names were chosen so they cannot collide with the copies).

* **`ctx.startPeers(hook, {network, options})` -> `PeersHandle`** (core, `peers/context_peers.dart`). Builds AND starts a hub and never throws for a runtime condition. An unwritable peers directory or a provider that fails to open becomes `handle.error` (`"peers unavailable: ..."`), and the app keeps working alone. `KitNotDeclared` is NOT swallowed (a bug in the app). The handle: `hub` (null when unavailable; non-null while still opening; set back to null, and the hub closed, if opening fails, so `handle.hub?.broadcast(...)` is always safe), `started` (completes when open or failed, never with an error), `error`, `isStarting`, `isRunning`, `changes` (`Stream<void>`, broadcast: fires when the hub opens or fails and on every peer found/ready/lost; ends with the context). Closed with the context; a close that fails on a hub that never opened is not reported. Use `ctx.peerHub` for a custom provider or authenticator.
* **`PeerJson`** (core, `peers/peer_json.dart`): `encode`, `decode(bytes, {maxBytes})` (null for malformed, non-UTF-8 or oversized input; never throws), `sizeOf`, `fits(value, maxBytes)`, `encodeWithin(value, maxBytes)` (throws `PeerPayloadTooLarge`, a `PeerError`), `quiet(future)` (a send nobody awaits), `label(PeerId)` ("laptop #3fa2"); and `AppMessage.jsonBody`. The Kit does NOT know a provider's payload cap: the app passes the limit (Hearth: 64 KiB minus the Kit header). **No `JsonMessage {kind, v, body}` envelope was built:** all three apps use the Kit envelope's own `kind` and `schema` and put only the body in the payload, so a second envelope inside the payload has no user.
* **`VenueSession.withHoldWaiting(need, body, {required maxWait, leaseSeconds, retryEvery, renewEvery, cancel, onWaiting, onLeaseLost})`** (core). Retries a `doesNotFit` (409) refusal; retries `forbidden` (403) only while `holds()` shows this consumer still has live holds of its own; gives up after `maxWait` (counted in naps of `retryEvery`, not read from a clock) with the LAST refusal; `maxWait: Duration.zero` is `withHold`. `cancel` (a Future) ends the wait at once with `HoldWaitCancelled`; a hold granted in that instant is released. Only the refusal of the hold is retried, never an error from `body`, never `VenueUnavailable`. `withHold` now shares its post-grant part (`_runHeld`) with it; behaviour unchanged. `FakeVenue.refuseNext(n, {kind})` makes the fake refuse n times. `VenueRefused.plainReason` unwraps the daemon's `error.message`.
  **The 403 rule is a heuristic and has a known failure.** The real daemon answers its per-consumer live-hold limit with 403, and also answers a missing grant or an observer token with 403, with the same code `forbidden`. A consumer that holds something and is refused 403 for lack of a grant waits `maxWait` for nothing before it gets the real refusal. **Finding for the Venue project:** give "over the live-hold limit" a machine-readable reason (or its own status); then drop the heuristic. Verified against the real daemon (consumer `calc`, limit 3): waits while it holds its own, is granted once one hold ends, gives up at `maxWait` with `forbidden`.
* **`PeersIndicator`** (companion, `package:app_context_kit_flutter/peers.dart`): `PeersIndicator.forHandle(handle, {extra})` or `PeersIndicator(hub: hub, offlineReason:, extra:)`. Shows `"This copy: <device> #<instance>"`, "Peers: N", a chip per ready copy, "(K connecting)" and, when peers are unavailable, "Peers: off (peers unavailable: ...)" with an icon. One live-region Semantics sentence; words and an icon, never colour alone. Same keys and texts as the apps' copy. **It is in its own library, not the `app_context_kit_flutter.dart` barrel,** because an app that still has its own `PeersIndicator` imports both and would get an ambiguous name; re-export it from the barrel (additive) once the copies are deleted.
* **`AppJsonFile` / `AppJsonRead` / `ctx.dataJson(name)`** (core): atomic write, read that tells missing from damaged, `quarantine()`. **`SessionSettings(store)`**: a `ConfigStore` wrapper whose `set` keeps the change in memory for the session while `config.json` is damaged (`readOnly` says so). Both are the apps' `JsonFile` / `SessionConfig` under names that cannot collide with them; the migration renames call sites.

### 7.1 Not built, and why

* **Large transfer (`notepad/lib/kit_gaps/blob_pull.dart`): not built: one user.** What a Kit-level chunked transfer would need, if a second app wants it: (1) the provider declares its maximum payload (`maxPayloadBytes`) and the transfer sizes parts from it, instead of the app guessing a constant; (2) a pull protocol over request/reply (the only reliable primitive today): the receiver asks for part 0, 1, 2 ... one reply at a time; (3) an opaque version `tag` on every part, pinned after part 0, and a restart (bounded `attempts`) when it changes mid-way; (4) a hard `maxBytes` enforced before allocating, and a bound on the part count taken from the sender's first reply; (5) base64 accounting: payload bytes become base64 inside the Kit's own base64, about 1.8x on the wire (24 KiB of text is a 44 KB frame); (6) typed outcomes: gone, too large, stale, and malformed-reply (the caller counts those) versus `PeerError` for a lost or silent peer; (7) a serving side (`hub.serveBlob`) that answers parts for bytes at a given tag; (8) progress callbacks, cancel, and request deadlines per part. Also unsolved: no acknowledgement and no replay (6.1).
* **Desktop notifications (`stopwatch/lib/kit_gaps/notifier.dart`):** one user, and not an App Context Kit concern (a UI toolkit or the platform).
* **`launcher` gaps (`manifest_scan.dart`, `pid_alive.dart`):** one user each. A scan of a source tree is not an install registry; `pidAliveViaKill` belongs with the roster (`RosterRecord.processAlive` or a control socket) and is only meaningful on the same machine and user.

## 8. Sharing one context between a Dart UI and a Rust core

A Flutter app with a Rust core is one process with two runtimes. If each side opened its own context, the app would announce itself twice (two roster files, two instance ids) and two code paths would write one `config.json`. So **one side opens the context and the other adopts it.**

* **The rule.** The side that opened the context (normally the Dart UI: `AppContext.open`, or `AppContextKit.run` in Flutter) is the **owner**. It hands the other side a **snapshot**. The other side is the **adopter**: it calls `AppContext::adopt(&snapshot)` (Rust) and does not open a context of its own. An adopter **does not announce**: no roster entry, no heartbeat, no Venue session, no peers.
* **One owner per file.** The owner owns `config.json` and the roster entry. The adopter only *reads* settings (the Rust crate's `ReadOnlySettings` refuses every write) and owns the files it creates under `data` and `state`. It may create directories under those two and under no other. If the Rust core needs a setting changed, it asks the owner; the owner writes it.
* **The snapshot** is JSON, produced by `AppContext.snapshot()` (Dart) or `AppContext::snapshot()` (Rust):

```json
{ "schema": 1, "appId": "com.slashbuilder.demo.notes-rust", "instance": "0a1b2c3d", "mode": "real", "scratch": false,
  "dirs": { "data": "/abs/data", "config": "/abs/config", "state": "/abs/state", "cache": "/abs/cache", "runtime": "/abs/runtime" },
  "roster": "/abs/roster" }
```

  `instance` is the owner's 8-hex-digit instance id; the adopter has none of its own. `mode` is `real` or `mock`. Every path is absolute (a relative `APP_CONTEXT_SCRATCH` is made absolute by the owner). The snapshot has no secrets (no Venue token, no environment) and no file handles; it is a copy taken at one moment, not a live view.
* **Parsing is strict.** First failure only, in this order: `not-json`, `not-object`, `unknown-schema` (any `schema` other than the number 1; a missing `schema` is `missing-field`), `missing-field` (the shape's order; nested ones are dotted, `dirs.data`), `unknown-field` (the schema is the only versioning: an addition bumps it), `bad-field` (wrong type or pattern: `appId` is reverse-DNS, `instance` is `^[0-9a-f]{8}$`, `mode` is `real` or `mock`, `scratch` is a bool, a path is a non-empty string), then `relative-path`. A path is absolute by its own syntax on any host: `/x`, `\\server\share`, `C:\x`, `C:/x`.
* **Fixtures.** `conformance/snapshot_cases.json` holds snapshots written by the Dart test `snapshot_test.dart` (real contexts, except the Windows shape, which the host cannot open), each with the inputs it came from; Rust adopts each and asserts that its own `resolve` over those inputs gives the same directories, and the same instance. `conformance/snapshot_negative_cases.json` lists snapshots that must be refused, with the error code and field. They are separate from the 61 resolution and manifest cases.
