# Coordination guide: copies of one app talking to each other

This guide is for a developer who wants two running copies of the same app to find each other, agree on who is there, and exchange messages. It covers the peer layer of the App Context Kit: what the Kit does, what you write, how to start it, and what it does not do.

**Status, so you know what you are reading.** The peer layer is implemented in the Dart core (`dart/app_context_kit/lib/src/peers/`). Two providers are built: an in-memory fake network (tests and mock mode) and a loopback provider (copies on one machine). No provider for a real network exists yet, and the Rust implementation has no peer code. Every example in this guide that has a file under [`examples/coordination/`](examples/coordination/) runs as a test; the commands are in [Run the examples](#run-the-examples).

Contents: [the model](#1-the-model) · [the scope key](#2-the-scope-key) · [the hook](#3-the-hook-five-jobs) · [starting a hub](#4-starting-a-hub) · [the hub API](#5-the-hub-api) · [providers](#6-providers) · [the envelope](#7-the-envelope) · [ordering and loss](#8-ordering-and-loss) · [delivery](#9-delivery) · [backpressure](#10-backpressure) · [PeerJson and size limits](#11-peerjson-and-size-limits) · [testing](#12-testing-coordination) · [three worked patterns](#13-three-worked-patterns) · [what the hook does not give you](#14-what-the-hook-does-not-give-you) · [real transports](#15-real-transports)

## 1. The model

The Kit finds, authenticates, connects and routes. Your app supplies a hook and decides what the messages mean. The Kit never reads the payload.

| The Kit does | Your app does |
|---|---|
| Finds other copies in the same scope (account and app id) | Names the conversation (`channel`) |
| Opens a link to each one and runs a handshake | Says what to tell a new peer (`hello`) |
| Checks the peer is who it claims to be (through an authenticator) | Decides whether to talk to it (`admit`) |
| Keeps the list of peers and tells you when one is found, ready or lost | Reacts to that list changing (`onPeer`) |
| Delivers each peer's messages to you once, in order, and reports a gap as a jump in `seq` | Decides what a message means, and what to do about a missing one (`onMessage`) |
| Correlates a request with its reply and fails it on timeout or loss | Defines the message kinds, the payload format and its version |
| Bounds the outgoing queue and fails a send instead of dropping | Decides what is safe to drop, coalesce or retry |

"Never reads the payload" is literal. A message carries a `kind` string and a `schema` integer that you choose, and an opaque byte payload. The Kit routes on its own header (see [the envelope](#7-the-envelope)) and hands you the bytes.

You get one hub per channel. A hub is one `PeerHub` object that owns the links to every other copy of your app. An app with several unrelated conversations either starts one hub per conversation or writes one hook that routes by `kind` prefix (a sample is `MuxHook` in [`sample_hooks.dart`](../dart/app_context_kit/test/peers/sample_hooks.dart)).

## 2. The scope key

Two copies are peers only if they have the same **account** and the same **app id**. Anything else is never offered to your hook and never admitted.

| Part | Where it comes from |
|---|---|
| App id | `id` in `app.json` (the manifest) |
| Account | `APP_CONTEXT_ACCOUNT`, else `account` in the app's `config.json`, else `local` |
| Device | `APP_CONTEXT_DEVICE`, else `device` in `config.json`; if neither exists the Kit generates `d-` plus 8 hex digits and saves it |
| Instance | 8 random hex digits, drawn each time the app opens (`ctx.instance`) |

A peer is identified by `(device, instance)`, the `PeerId`. Two copies on one device are two peers. `local` is the account of a machine that has no household account; it is a placeholder until something issues a real one.

Scope is checked in three places, so a bug in one does not open the others:

- The provider does not list candidates from another scope and refuses to dial or accept one. The loopback provider also keeps one directory per account and app, so it never reads another scope's files.
- The hub drops a candidate or an incoming link whose claimed scope differs from its own, and counts it in `hub.stats.scopeViolations`.
- Every frame carries `account` and `app` in its header. A frame with a different scope cuts the link.

[`ping_test.dart`](examples/coordination/test/ping_test.dart) checks this: a copy of the app, a copy with another app id and a copy with another account share one network, and none of the three sees any peer.

**Scope is a name, not a credential.** The default authenticator (`OpenAuthenticator`) accepts every peer in scope, and no per-app credential exists yet. Treat the scope key as a way to keep copies of different apps and accounts apart, not as access control. The authenticator is the seam where a real check goes; see [per-app credentials](#14-what-the-hook-does-not-give-you). A security review is pending; details withheld.

Identifier rules for the loopback provider: account, app, device and instance become directory and file names, so they may contain only letters, digits, `.`, `_` and `-`, may not start with `.`, and may be at most 128 characters. Anything else makes the hub fail to open, which `ctx.startPeers` reports in `handle.error`.

## 3. The hook: five jobs

A hook is a subclass of `AppCoordination` ([`coordination.dart`](../dart/app_context_kit/lib/src/peers/coordination.dart)). It has five jobs and one convenience:

| # | Member | When the Kit calls it | What you return or do |
|---|---|---|---|
| 1 | `String get channel` | Once, when the hub is built | The conversation this hook owns, such as `"default"` or `"game"`. A peer on another channel is rejected at the handshake |
| 2 | `Object? hello()` | Each time a link opens | Anything JSON-encodable, or null. Describe your current state (a version, a digest, a protocol number). The Kit carries it and never reads it |
| 3 | `FutureOr<Admit> admit(Peer, Object? theirHello)` | After the Kit has checked identity, once per link | `Admit.accept()`, `Admit.acceptReadOnly()` or `Admit.reject(reason)`. May be async; the link waits |
| 4 | `void onPeer(Peer, PeerChange)` | A peer is `found`, `ready` or `lost` | React. Runs before the same event appears on `hub.changes` |
| 5 | `void onMessage(Peer from, AppMessage)` | A message arrives from a ready peer | Your meaning lives here. It is synchronous: queue async work yourself |
| | `void attach(PeerHub)` | Once, from `hub.start()` | Keep the hub so you can call `send`, `broadcast`, `request` and `reply`. The default does nothing |

`acceptReadOnly` only sets `peer.readOnly`. The Kit does not filter anything for a read-only peer, and the other side is not told. You decide what read-only means, for example by ignoring that peer's write messages in `onMessage`.

A hook must not throw. If it does, the hub catches the error, counts it in `hub.stats.hookErrors`, passes it to `PeerHubOptions.onHookError` if you set one, and carries on.

### A complete hook: "ping"

This is the whole of a working app's coordination code. Any copy can ping another, and the other answers with its device name. It is [`examples/coordination/lib/ping_hook.dart`](examples/coordination/lib/ping_hook.dart), unchanged.

```dart
import 'dart:async';

import 'package:app_context_kit/app_context_kit.dart';

/// A complete coordination hook: the five jobs, and nothing else.
///
/// "ping": any copy can ask another copy "are you there?", and the other copy answers with its device name.
class PingHook extends AppCoordination {
  PeerHub? hub;

  /// Peer changes as the Kit reported them, e.g. "ready desktop".
  final List<String> events = [];

  /// Messages this hook did not understand. A hook counts these instead of throwing.
  int ignored = 0;

  // 1. Which conversation inside the app this hook owns.
  @override
  String get channel => 'ping';

  // The Kit hands the hook its hub once, from PeerHub.start().
  @override
  void attach(PeerHub hub) => this.hub = hub;

  // 2. What to tell a peer when a link opens. Any JSON-encodable value.
  @override
  Object? hello() => {'proto': 1};

  // 3. Whether to talk to this peer, given what it said in its hello.
  @override
  FutureOr<Admit> admit(Peer peer, Object? theirHello) =>
      theirHello is Map && theirHello['proto'] == 1
          ? const Admit.accept()
          : const Admit.reject('ping protocol 1 only');

  // 4. A peer was found, became ready, or was lost.
  @override
  void onPeer(Peer peer, PeerChange change) =>
      events.add('${change.name} ${peer.id.device}');

  // 5. The app's meaning lives here. Answer a ping; count anything else.
  @override
  void onMessage(Peer from, AppMessage message) {
    if (message.kind == 'ping' && message.schema == 1 && message.requestId != null) {
      PeerJson.quiet(hub!.reply(message, PeerJson.encode({'pong': hub!.device}), schema: 1));
    } else {
      ignored++;
    }
  }

  /// Ask [peer] if it is there. Returns the name it answered with, or null for an answer in the wrong shape.
  /// Throws a PeerError (PeerTimeout, PeerLost, ...) if there is no answer.
  Future<String?> ping(Peer peer) async {
    final reply = await hub!.request(peer, PeerJson.encode({'n': 1}), kind: 'ping', schema: 1);
    final body = reply.jsonBody;
    return body is Map && body['pong'] is String ? body['pong'] as String : null;
  }
}
```

And this is how two copies of it run in one test process. Each copy is an `AppContext` in mock mode; they share one `FakePeerNetwork`. The manifest must list `"peers"` in `kits`, or `ctx.startPeers` throws `KitNotDeclared`. From [`ping_test.dart`](examples/coordination/test/ping_test.dart):

```dart
/// The manifest must list "peers", or ctx.startPeers throws KitNotDeclared.
const manifestJson = {
  'id': 'dev.example.ping',
  'name': 'Ping',
  'version': '0.1.0',
  'kits': ['peers'],
};
```

```dart
/// One copy of the app: its own AppContext, in mock mode, on the shared fake network.
Future<({AppContext ctx, PingHook hook, PeersHandle peers})> copy(
  String device,
  FakePeerNetwork network, {
  Map<String, Object?> manifest = manifestJson,
  String account = 'home',
}) async {
  final ctx = await AppContext.open(
    AppManifest.fromJson(manifest),
    env: {
      'APP_CONTEXT_MODE': 'mock',
      'APP_CONTEXT_SCRATCH': '${scratch.path}/$device',
      'APP_CONTEXT_DEVICE': device,
      'APP_CONTEXT_ACCOUNT': account,
    },
    platform: 'linux',
    home: '/unused',
    announce: false,
  );
  final hook = PingHook();
  final peers = ctx.startPeers(hook, network: network);
  await peers.started;
  return (ctx: ctx, hook: hook, peers: peers);
}
```

```dart
test('two copies of one app find each other, ping, and get a pong', () async {
  final network = FakePeerNetwork();
  final laptop = await copy('laptop', network);
  final desktop = await copy('desktop', network);

  expect(await until(() => laptop.peers.hub!.readyPeers.isNotEmpty && desktop.peers.hub!.readyPeers.isNotEmpty), isTrue);

  final desktopFromLaptop = laptop.peers.hub!.readyPeers.single;
  expect(desktopFromLaptop.id.device, 'desktop');
  expect(await laptop.hook.ping(desktopFromLaptop), 'desktop');

  final laptopFromDesktop = desktop.peers.hub!.readyPeers.single;
  expect(await desktop.hook.ping(laptopFromDesktop), 'laptop');

  // The hook heard found, then ready, in that order, on both sides.
  expect(laptop.hook.events, ['found desktop', 'ready desktop']);
  expect(desktop.hook.events, ['found laptop', 'ready laptop']);
  expect(laptop.hook.ignored + desktop.hook.ignored, 0);

  await laptop.ctx.close();
  await desktop.ctx.close();
});
```

`until(...)` is a small polling helper defined at the top of that file. Discovery and the handshake are asynchronous, so the test waits for `readyPeers` instead of sleeping.

### Run the examples

```sh
cd docs/examples/coordination
dart pub get
dart test
```

The package depends on `app_context_kit` by path and on nothing else except `test`. It contains three test files: `ping_test.dart` (the example above), `hub_behaviour_test.dart` (tests for the behavioural claims in this guide: sequence numbers, loss, outbox, size caps, timeouts, admit and reject, hello) and `loopback_test.dart` (two copies over real TCP and announcement files).

## 4. Starting a hub

Declare the Kit in the manifest, then call `ctx.startPeers` with your hook.

```json
{ "id": "dev.example.ping", "name": "Ping", "version": "0.1.0", "kits": ["peers"] }
```

`ctx.startPeers(hook, {network, options})` builds a hub and starts it. It returns a `PeersHandle` at once, before the hub has opened, and it does not throw for a runtime condition. If the peers directory cannot be created or the provider fails to open, the handle carries the reason and your app keeps working alone.

| `PeersHandle` member | Meaning |
|---|---|
| `hub` | The `PeerHub`, or null when peers are unavailable. Non-null while the hub is still opening; set back to null (and the hub closed) if opening fails. `handle.hub?.broadcast(...)` is always safe |
| `started` | A future that completes when the hub is open or has failed. It never completes with an error |
| `error` | `"peers unavailable: ..."`, or null |
| `isStarting`, `isRunning` | `isRunning` is true when the hub is open and there is no error |
| `changes` | A broadcast `Stream<void>`. Fires when the hub opens or fails and on every peer found, ready or lost. Ends when the context closes |

`KitNotDeclared` is the one exception that `startPeers` does throw: forgetting to list `"peers"` is a bug in the app, not something that happens to a person. The hub is closed with the context (`ctx.onClose`), so you do not close it yourself.

The provider is chosen from the mode, in this order:

1. In mock mode (`<PREFIX>_MODE=mock` or `APP_CONTEXT_MODE=mock`): the `FakePeerNetwork` you pass as `network:`, or a private one if you pass none. A private network contains only your own context, so **to have two contexts find each other in a test, pass the same `FakePeerNetwork` to both.** Apps do this by taking a `network:` parameter in their own production code; the demo apps' constructors show the shape.
2. Otherwise: a `LoopbackProvider` over the peers directory.

| Variable | Effect |
|---|---|
| `APP_CONTEXT_ACCOUNT` | The account half of the scope key |
| `APP_CONTEXT_DEVICE` | The device half of the peer id |
| `APP_CONTEXT_PEERS_DIR` | Where loopback announcements are written. Default: the roster directory with `-peers` appended (for example `/tmp/app-context-roster-peers`) |
| `APP_CONTEXT_MODE`, `<PREFIX>_MODE` | `mock` selects the fake network |
| `APP_CONTEXT_SCRATCH` | Puts every app directory and the roster under one directory. Note that the default peers directory moves with the roster, so two copies with different scratch directories need a shared `APP_CONTEXT_PEERS_DIR` to find each other |

Building a hub writes a generated `device` value into the app's `config.json` the first time, unless `APP_CONTEXT_DEVICE` is set. Two copies that share a config directory therefore share a device id and differ only by instance. Give each copy its own `APP_CONTEXT_DEVICE`, or its own config directory.

In a Flutter app, `PeersIndicator.forHandle(handle)` from `package:app_context_kit_flutter/app_context_kit_flutter.dart` shows "This copy: laptop #3fa2", the number of peers, a chip for each ready copy, and "Peers: off (reason)" when `handle.error` is set. It follows `handle.changes` itself.

`ctx.peerHub(hook, {provider, network, authenticator, options})` is the lower-level call. It builds the hub and registers it for closing with the context, but does not start it: you `await hub.start()` yourself and handle the failure. Use it when you need your own provider, a custom authenticator, or a specific `LoopbackProvider` configuration. It also throws `KitNotDeclared` when `"peers"` is missing.

## 5. The hub API

`PeerHub` ([`hub.dart`](../dart/app_context_kit/lib/src/peers/hub.dart)) is the management interface.

| Member | What it does |
|---|---|
| `start()` | Opens the provider and starts finding peers. Calls `hook.attach(this)` first. `startPeers` calls it for you |
| `peers` | A snapshot list of every peer that is found, connecting or ready. Lost and rejected peers are not in it |
| `readyPeers` | The ready subset of `peers` |
| `changes` | A broadcast `Stream<PeerEvent>`: every found, ready and lost, in order, after your hook's `onPeer` has seen it |
| `send(peer, payload, {kind, schema})` | Queues one message. Completes when the transport has taken the frame. See [delivery](#9-delivery) |
| `broadcast(payload, {kind, schema})` | `send` to every ready peer. Returns a `BroadcastResult` with `sent` and a per-peer `failed` map; one bad peer does not throw |
| `request(peer, payload, {kind, schema, timeout})` | Sends a request and returns the reply as an `AppMessage`. Default timeout 5 s |
| `reply(requestMessage, payload, {schema})` | Answers a message that arrived with a `requestId` |
| `close()` | Sends `kit.bye` to ready peers, closes every link and the provider. Idempotent |
| `id`, `identity`, `device`, `instance`, `stats`, `isClosed` | Who this copy is, and counters (`duplicatesDropped`, `gapsSkipped`, `malformedFrames`, `scopeViolations`, `protocolViolations`, `droppedBeforeReady`, `hookErrors`, `linksOpened`, `dialFailures`) |

`kind` defaults to `"msg"` and `schema` to `0`. `kind` is 1 to 256 characters and may not start with `kit.`; `schema` is `0` to 2,147,483,647. A bad value is an `ArgumentError`.

### Peers and their states

A `Peer` is read-only to you. Its `state` is one of `found`, `connecting`, `ready`, `rejected` or `lost`. `found` means the provider announced it; `connecting` means a link is being opened or the handshake is running; `ready` means both sides admitted each other. `peer.hello` is the decoded hello once received, and `peer.rejectReason` and `peer.lostReason` say why a peer ended (`goodbye`, `link closed`, `hub closed`, `withdrawn`, and others).

**A `Peer` object is never reused.** A copy that goes away and comes back is a new `Peer` with the same `PeerId`. Keep the `PeerId` if you need to find the peer again; calling `send` with a `Peer` that has been replaced throws `PeerNotAvailable`. A rejected peer is not redialed until the provider withdraws it and announces it again.

A rejection shows up as a `lost` event on both sides, with `peer.state == rejected`. [`hub_behaviour_test.dart`](examples/coordination/test/hub_behaviour_test.dart) checks it: one side's `admit` rejects with `"proto 2 only"`, and the other side's peer ends with `rejectReason == 'rejected by peer: proto 2 only'`.

### Errors

All failures in this layer are subclasses of `PeerError`.

| Error | Raised when |
|---|---|
| `PeerNotAvailable` | The peer is unknown, rejected, lost, or a stale `Peer` object |
| `PeerLost` | The link ended while a message or request was outstanding |
| `PeerOutboxFull` | The peer's outgoing queue is full ([backpressure](#10-backpressure)) |
| `PeerTimeout` | A request got no reply in time |
| `PeerClosed` | The hub is closed |
| `EnvelopeError` | The payload is over the 1 MiB cap, or a frame is malformed |
| `PeerPayloadTooLarge` | `PeerJson.encodeWithin` found the value over your limit |
| `PeerLinkClosed`, `PeerConnectError`, `PeerScopeError` | Provider-level: a send on a closed link, a candidate that cannot be reached, a candidate outside the scope |

If you call `send` without awaiting it, attach a handler or use `PeerJson.quiet(...)`. A late failure of an un-awaited future is an uncaught async error.

## 6. Providers

The hub talks to two small interfaces, `PeerProvider` and `PeerLink` ([`provider.dart`](../dart/app_context_kit/lib/src/peers/provider.dart)), so the same hook runs over any provider. A provider announces this copy, reports other copies in the same scope (`discover()`), dials one (`connect`), and hands over links that others dialed (`incoming`). A link is one ordered, message-framed connection: one `send` arrives as one inbound event.

### Fake network: tests and mock mode

`FakePeerNetwork` ([`fake_network.dart`](../dart/app_context_kit/lib/src/peers/fake_network.dart)) is an in-memory network. Several hubs join one network, each through its own provider. It enforces the scope key itself and lets a test change the world while it runs:

| Control | Effect |
|---|---|
| `latency`, `jitter` | Delay every frame; jitter can reorder |
| `dropRate`, `duplicateRate` | Probability that a frame is lost or delivered twice. Seeded, so a run repeats |
| `dropIf` | A function you set, `(from, to, bytes) => bool`. Return true to drop that frame. `Envelope.decode(bytes)` lets you pick a victim by kind or content |
| `partition(a, b)`, `isolate(a)`, `heal(...)`, `healAll()` | Cut peers from each other, and undo it |
| `dropLinks(a, b)` | Break the links but keep discovery: a flaky connection rather than a partition |
| `deliveries` | A record of every frame that reached a link end, so a test can prove what did not arrive |

For deterministic time, build a `PeerHub` directly with a `ManualPeerClock` (see `World` in [`support.dart`](../dart/app_context_kit/test/peers/support.dart)). `ctx.startPeers` and `ctx.peerHub` do not take a clock, so hubs they build run on real time.

### Loopback: copies on one machine

`LoopbackProvider` ([`loopback_provider.dart`](../dart/app_context_kit/lib/src/peers/loopback_provider.dart)) connects copies that run on one machine, as processes. It needs nothing but a shared directory.

**Announcement files.** Each copy listens on a TCP port on `127.0.0.1` (never a routable address; the operating system picks the port) and writes one file:

```text
<peers dir>/<account>/<app id>/<device>@<instance>.json
```

with these fields. This file was written by a run of the stopwatch probe; [`loopback_test.dart`](examples/coordination/test/loopback_test.dart) asserts the key set and the path.

```json
{"account":"local","app":"com.slashbuilder.demo.stopwatch","device":"desktop","instance":"48e784da","port":52367,"pid":63779,"beat":1792850562108}
```

`beat` is a wall-clock time in epoch milliseconds. The file is written to a temporary name and renamed, so a reader never sees half a file.

**Finding each other.** Each provider reads the directory for its own account and app every 100 ms (`pollInterval`). A file naming another scope than its directory is ignored. A candidate is offered if its file is under 4 KiB, parses, has a valid port, and has a recent beat.

**Connecting.** Only the copy with the lower `PeerId` dials, so two copies never open two links. A frame on the wire is a 4-byte big-endian length followed by the envelope bytes. The dialer's first frame is a preface naming who it claims to be; the accepting side closes the socket if the preface names another scope or is garbage, before the hub sees a link. A dial that fails is retried after 0.2 s, doubling to a 5 s ceiling, at most 10 attempts; after that the hub waits for the provider to announce the copy again.

**Beat, staleness and reaping.** This is how a crashed copy disappears.

| Setting | Default | Meaning |
|---|---|---|
| `announceEvery` | 1 s | Each provider rewrites its own file with a fresh `beat` |
| `staleAfter` | 4 s | A file whose last beat is older is not offered, and a peer already known from it is withdrawn |
| `reapAfter` | 60 s | A file whose last beat is older is deleted by whichever copy notices. A paused copy rewrites its file at its next beat |

A file with no `beat` (one made by hand) is aged by its modification time. The provider does not check whether the pid in the file is alive: a pid means nothing across pid namespaces, can be reused, and Dart has no portable check that does not spawn a process. The cost of the beat is one small write per second per process.

**What a crash looks like.** On a clean `close()` the copy sends `kit.bye`, deletes its file, and the other copy sees `lost` with reason `goodbye`; it is not redialed. If the process is killed, the operating system closes its sockets, so the survivor sees the link drop at once. But the file is still there and still has a recent beat, so the dead copy is still announced and the survivor sees it as `found` again. It stays that way until the beat is older than `staleAfter`. One death is therefore three events: `lost`, `found`, `lost`.

Measured today on macOS (Apple silicon) by `dart test test/peers/two_process_test.dart -r expanded` in `dart/app_context_kit`, which starts real operating-system processes over one temporary directory and kills one with `SIGKILL`. Two runs, one for each side of the dial rule:

| Observation after the kill | Survivor that dials | Survivor that waits to be dialed |
|---|---|---|
| `lost` ("link closed") | 6 ms | 7 ms |
| `found` for the same dead copy | at the same instant | at the same instant |
| final `lost` ("withdrawn") | 3564 ms | 3591 ms |
| failed dial attempts | 4 | 0 |
| dead copy in `hub.peers` after 12 s | gone | gone |
| announcement file on disk after 12 s | still present (deleted at 60 s) | still present |

The same test passes in a Linux container (numbers in [Platforms](PLATFORMS.md#macos)). Before the beat was added, the dead copy stayed `found` for ever. The `found` after the first `lost` is a known rough edge: the hub cannot yet tell "link dropped" from "gone" earlier than the beat allows. Make `onPeer` idempotent, and do not assume `found` cannot follow `lost`.

Run as two macOS debug builds of the stopwatch, notepad and minesweeper apps, the second copy's announcement appeared 257 to 439 ms after launch and a TCP link 31 to 35 ms after that. These figures are recorded in the apps' notes; they were not re-run for this guide.

**Tuning.** `ctx.startPeers` and `ctx.peerHub` take `PeerHubOptions` but not the loopback timings. To change `staleAfter` or `announceEvery`, build the provider yourself and pass it: `ctx.peerHub(hook, provider: LoopbackProvider(directory: ..., staleAfter: ...))`.

**Limits.**

- One machine, one user. The loopback provider has no encryption and no authentication. Use it for same-user coordination on one machine and for tests, not across users or trust boundaries.
- On macOS, a sandboxed app has its own container. The peers directory (and the roster) must be reachable by every copy: the default location is inside the container and works for copies of one app; a path outside the container leaves the app working alone. The sandbox entitlements `com.apple.security.network.client` and `com.apple.security.network.server` are both needed to dial and to listen. Flutter's macOS template grants only `network.server` in Debug and neither in Release; the notepad and minesweeper projects add both. With only `server`, the recorded observation was that two sandboxed copies listen but never connect, with nothing in the log. [PLATFORMS.md](PLATFORMS.md#the-app-sandbox) has the full table; the observation was not re-run for this guide.
- Environment variables you set in a shell reach an app you start from that shell. They do not reach one started from Finder or the Dock.

## 7. The envelope

Every frame between two copies is one envelope: a header the Kit reads and a payload it does not ([`envelope.dart`](../dart/app_context_kit/lib/src/peers/envelope.dart)). The wire form is UTF-8 JSON with the keys in a fixed order:

```json
{"v":1,"account":"a","app":"dev.x","channel":"default","from":{"device":"d","instance":"i"},
 "seq":1,"kind":"msg","schema":0,"rid":7,"payload":"<base64>"}
```

| Field | Meaning | Limits |
|---|---|---|
| `v` | Envelope version. A different value is rejected | `1` |
| `account`, `app` | The scope key | 1 to 256 characters, no control characters |
| `channel` | The hook's channel | same |
| `from.device`, `from.instance` | The sender's `PeerId` | same |
| `seq` | Sequence number, per link and direction | 0 to 2^53 - 1 |
| `kind` | Message type. Yours, or a reserved `kit.` kind | 1 to 256 characters |
| `schema` | Your payload version. The Kit carries it and does not look at it | 0 to 2^31 - 1 |
| `rid` | Request id. Present only on requests and replies | 1 to 2^53 - 1 |
| `payload` | Your bytes, base64 | at most 1,048,576 bytes before encoding |

Unknown extra keys are ignored, so a later version can add fields.

**The outer cap is 1 MiB.** A payload over 1,048,576 bytes is an `EnvelopeError` on send. The largest frame the decoder will look at is 1,406,296 bytes (the base64 of a full payload plus 8,192 bytes of header room). That is the Kit's limit. A provider may carry less; see [real transports](#15-real-transports).

**Reserved kinds.** Kinds that start with `kit.` belong to the Kit, and your app cannot send them (`ArgumentError`). The Kit uses these:

| Kind | Purpose |
|---|---|
| `kit.hello` | First frame each way: a nonce and your `hello()` |
| `kit.auth` | The authenticator's proof over the other side's nonce |
| `kit.ready` | "I admitted you" |
| `kit.reject` | "I refuse you", with a reason of at most 256 characters |
| `kit.bye` | Graceful close; the peer is not redialed |
| `kit.reply` | The answer to a request |

An unknown `kit.` kind from a peer is ignored. `kit.reply` is consumed by the hub and completes the `request` future; it never reaches `onMessage`.

**Request and reply.** `request` gives the outgoing frame an `rid` from a per-hub counter that starts at 1. The other side's `onMessage` sees it as `AppMessage.requestId`; `hub.reply(message, payload)` sends a `kit.reply` with the same `rid`. The hub matches replies to waiting requests by `(peer, rid)`, so the Kit's correlation does not depend on a transport's own message ids. A reply that is late or unknown is ignored. A request that times out cancels its frame if the frame has not been written yet.

## 8. Ordering and loss

`seq` numbers the frames in one direction of one link. It starts at 1 on every new link, so a reconnect restarts it. **It counts the Kit's own frames too.** `kit.hello`, `kit.auth` and `kit.ready` take 1, 2 and 3, so the first message your app receives from a peer has `seq` 4. A `kit.reply` or `kit.bye` takes a number as well.

The hub delivers each peer's frames to you in `seq` order, once:

- A frame that arrives early waits in a reorder buffer of 16 frames.
- A gap that is not filled within 500 ms, or a buffer that overflows, is skipped. The hub counts it in `hub.stats.gapsSkipped` and delivers what it has.
- A frame at or below the last delivered `seq` is a duplicate or a late arrival after a skip, and is dropped (`duplicatesDropped`).
- A peer that floods more than 256 undelivered frames on one link has the link dropped.

**You see loss as a jump in `AppMessage.seq`.** [`hub_behaviour_test.dart`](examples/coordination/test/hub_behaviour_test.dart) drops the second of three messages on the fake network. The receiver gets two:

```dart
expect(seqs, [4, 6]);
```

A jump says that one or more frames from that peer were skipped. It cannot say which: the lost frame might have been a reply. If you need to detect a lost message precisely, put your own counter or version in the payload.

Ordering is per sender. The Kit gives you no order between messages from two different peers.

## 9. Delivery

Delivery is best effort.

- `send` completes when the **transport took the frame**, not when the peer received or applied it. [`hub_behaviour_test.dart`](examples/coordination/test/hub_behaviour_test.dart) sets the fake network to drop every frame and shows that `send` still completes without error.
- If the link ends before a queued frame is written, the `send` future fails with `PeerLost`. Queued messages are dropped when the peer is lost.
- There is no retry and no replay. A message sent before a peer exists is not kept for it: a `broadcast` with nobody ready returns an empty `sent` list, and a copy that arrives later never sees it.
- `send` to a peer that is found or connecting is queued and written once the peer is ready. App frames from a peer are not delivered to you before it is ready.
- `request`/`reply` is the one acknowledgement the Kit has: a reply proves the other hook ran. A request that gets no reply fails with `PeerTimeout` (the other hook may still have run).

If you need "it was applied", build it from a reply. The minesweeper and notepad apps did; the stopwatch accepted a possible duplicate instead. See [the patterns](#13-three-worked-patterns).

## 10. Backpressure

Each peer has an outgoing queue of messages not yet handed to the transport. It holds at most 256 messages or 8 MiB of payload (`PeerHubOptions.outboxMessages`, `outboxBytes`). When it is full, `send`, `request` and `reply` fail with `PeerOutboxFull` on the returned future, and `broadcast` reports that peer in `failed`. The Kit does not drop an older message to make room, because only your app knows what is safe to drop.

What to do depends on the message. For state ("the current note", "the timer"), send the newest value and let `PeerOutboxFull` mean "skip this one; the next change carries the state anyway". For events that all matter, await each send before the next. [`hub_behaviour_test.dart`](examples/coordination/test/hub_behaviour_test.dart) sets `outboxMessages: 2`, sends ten messages without awaiting, and counts the `PeerOutboxFull` failures.

## 11. PeerJson and size limits

Apps that speak JSON need the same few helpers, so they are in the Kit (`PeerJson`, [`peer_json.dart`](../dart/app_context_kit/lib/src/peers/peer_json.dart)):

| Helper | What it does |
|---|---|
| `PeerJson.encode(value)` | UTF-8 JSON bytes |
| `PeerJson.decode(bytes, {maxBytes})` | The decoded value, or null for malformed, non-UTF-8 or oversized input. Never throws, so hostile input cannot escape `onMessage` |
| `message.jsonBody` | `decode(message.payload)` |
| `PeerJson.sizeOf(value)`, `fits(value, maxBytes)` | Size checks before sending |
| `PeerJson.encodeWithin(value, maxBytes)` | Encode, or throw `PeerPayloadTooLarge` (a `PeerError`) |
| `PeerJson.quiet(future)` | A send nobody awaits: failures are swallowed. Use it for state you resend anyway |
| `PeerJson.label(peerId)` | `"laptop #3fa2"`: the device and the first four characters of the instance |

`decode` returns null both for malformed input and for the JSON literal `null`. Send an object (`{"v": 1}`) rather than a bare value when you must tell "nothing" from "malformed".

**The Kit does not know your provider's payload limit.** You pass it. The fake and loopback providers carry up to the 1 MiB envelope cap; a Hearth transport would carry 64 KiB minus the Kit's header. If your app may run on a smaller transport, size to the smaller one with `fits` or `encodeWithin`. Keep the hello small as well: it travels in one frame like any other message, so carry a version or a digest, not the data.

There is no second envelope inside the payload. The Kit envelope already has `kind` and `schema`, so switch on `message.kind`, check `message.schema`, then read the body with `message.jsonBody`. The three coordinating demo apps do.

## 12. Testing coordination

Run two copies in one process. Open two `AppContext`s in mock mode (`APP_CONTEXT_MODE=mock`), give each its own `APP_CONTEXT_DEVICE`, call `ctx.startPeers(hook, network: network)` with one shared `FakePeerNetwork`, wait for `readyPeers`, and drive the hooks. The example in [section 3](#3-the-hook-five-jobs) is this setup. The demo apps use it for their hook tests, including a hostile peer that sends malformed JSON, wrong types and an unknown schema, and tests that cut the network with `partition`/`heal`.

For tests that depend on timing (reorder timeout, request timeout, redial backoff), build the `PeerHub` directly with a `ManualPeerClock` so the test controls time. That is how the Kit's own tests in `dart/app_context_kit/test/peers/` work. For a real process boundary, `two_process_test.dart` starts operating-system processes over a shared temporary directory.

Count what your hook ignores. The demo hooks keep an `ignored` counter, and their tests assert it after sending garbage.

## 13. Three worked patterns

The three demo apps that use peers (stopwatch, notepad and minesweeper, in The Kit Book) each used the hook for a different kind of meaning. The snippets below are copied from their code.

### A signal: "the timer finished" (stopwatch)

The stopwatch app shares one countdown between copies. This pattern is only the announcement: when the countdown ends, exactly one copy should say so, and the others should show "finished on laptop #3fa2" instead of announcing it again.

Which copy announces is the app's decision, not the Kit's. Every start, pause or reset bumps a stamp, a pair of a revision number and the id of the copy that made the change (its "writer"). The rule: the writer of the current stamp announces. If the writer is no longer among `hub.readyPeers`, the lowest-numbered live copy announces. Any other copy waits for the `timer.finished` message and, if it has not arrived after a 2-second grace, announces itself. The announcement is a broadcast with a `kind` and `schema` the app chose. A late joiner is not told what it missed; the countdown state rides in its `hello()` instead (see the replay entry in [section 14](#14-what-the-hook-does-not-give-you)).

Delivery is best effort, so the announcement can be lost. The app does not try to prevent that with an acknowledgement; it prevents silence instead. Under a partition two copies may both announce. The app chose "at least once" on purpose, and the comment at the top of the file says so. It accepts a possible duplicate announcement rather than a possible missing one.

The Kit contributes the list of ready peers (`hub.readyPeers`, used to decide who is alive), the broadcast, and the guarantee that one peer's messages arrive in order. The stopwatch also replicates the countdown itself with a last-writer-wins stamp; that is a second use of the same hook, and this section covers only the signal. From the stopwatch demo app's `lib/coordination/shared_timer.dart`:

```dart
/// This copy's countdown ran out. Announce if we are the announcer, else wait for the announcer.
void countdownEnded(CountdownModel done) {
  if (_told == stamp) return;
  if (_isAnnouncer()) return _announce(done);
  final at = stamp;
  _grace = Timer(takeoverGrace, () {
    if (_told != at && stamp == at) _announce(done);
  });
}

bool _isAnnouncer() {
  final h = hub;
  if (h == null || stamp.rev == 0 || stamp.writer == _me) return true;
  final ready = h.readyPeers;
  if (ready.any((p) => p.id.toString() == stamp.writer)) return false; // the owner is alive: it announces
  return ready.every((p) => h.id.compareTo(p.id) < 0); // owner gone: the lowest live copy does
}

void _announce(CountdownModel done) {
  _told = stamp;
  final label = formatMs(done.durationMs, tenths: false);
  onFinished(Finished(label: label, by: hub?.id ?? const PeerId('local', 'local'), local: true));
  final h = hub;
  if (h != null) {
    final ended = _stateJson(done)..['label'] = label;
    PeerJson.quiet(h.broadcast(PeerJson.encode(ended), kind: 'timer.finished', schema: 1));
  }
}
```

### A sync with an app-defined conflict rule (notepad)

The notepad app keeps the same notes on every copy. The Kit carries bytes between copies; it has no store, no merge and no idea what a note is. The hook file is 29 lines and forwards each of the five jobs to a sync engine, about 500 lines in `note_sync.dart`, which is the app's own.

The central choice is what happens when two copies edit the same note while apart. The engine tracks a version vector per note, so it can tell "you are behind" from "we both edited". A timestamp cannot tell those apart: it always orders two edits, and one edit silently loses. When the versions are concurrent, the engine keeps both: the version that sorts later (by `updatedAt`, then device, then a content hash) keeps the note's title and place, and the other becomes a new note titled `<title> (conflict from <device>)`. The rule is symmetric and total, so both copies reach the same decision without talking, and they derive the same id for the new note, so they converge instead of duplicating. The person is told what happened. Edit beats delete: a delete never destroys a concurrent edit. Identical text on both sides is not a conflict.

Content moves by pull. Small `sync.have` messages say "note X is at version V". A copy that is behind asks with `request`, one part at a time, because request/reply is the only acknowledgement the Kit has. A late joiner puts only a digest in its `hello()`; if the digests differ, each side sends its index and the one that is behind pulls.

None of this is in the Kit, by design: the Kit does not interpret payloads. The hook is the right shape for meaning; it is not a sync framework. From the notepad demo app's `lib/coordination/note_sync.dart`:

```dart
void _applyRemote(Note remote, Vv rvv, String rby) {
  final id = remote.id;
  if (host.isDamaged(id)) return;
  host.flushNote(id);
  final local = meta[id];
  final order = local == null ? VvOrder.before : local.vv.compare(rvv);
  try {
    switch (order) {
      case VvOrder.equal || VvOrder.after:
        return;
      case VvOrder.before:
        _put(remote, rvv, rby);
      case VvOrder.concurrent:
        final mine = host.note(id);
        if (local!.deleted || mine == null) {
          _put(remote, local.vv.join(rvv), rby); // edit beats delete
        } else if (hashNote(mine) == hashNote(remote)) {
          meta[id] = Meta(local.vv.join(rvv), by: local.by, hash: local.hash); // same text on both: only the histories merge
          _save();
          _announce([id]);
        } else {
          _conflict(mine, local, remote, rvv, rby);
        }
    }
  } on FileSystemException catch (e) {
    report('Could not store a synced note: ${e.message}. It will be tried again at the next sync.');
  }
}
```

```dart
/// Does A sort after B? Symmetric and total, so both copies pick the same winner with no conversation.
bool _beats(Note a, String aBy, Note b, String bBy) {
  final t = a.updatedAt.compareTo(b.updatedAt);
  if (t != 0) return t > 0;
  final d = aBy.compareTo(bBy);
  return d != 0 ? d > 0 : hashNote(a).compareTo(hashNote(b)) > 0;
}
```

### A handoff with confirmation (minesweeper)

The minesweeper app can hand a game to another copy. "Give the game away" changes state on two sides, and the Kit has no transaction, so the app builds the handoff from request/reply:

1. The sender **offers** (`game.offer`: difficulty, status, seconds, squares open; no board).
2. The receiving **person** says yes or no. An offer never changes a board by itself.
3. The receiver **requests** the board (`game.take`). The reply is the data. The sender serves it only for an offer it made, to the peer it made it to.
4. The receiver applies the board. `Minesweeper.fromJson` is strict: anything inconsistent is refused and nothing changes.
5. The receiver **requests** `game.taken`. Only when that request arrives does the sender release its game.

If the confirmation is lost, both copies keep the game: a duplicate, never zero. The receiver is told "did not confirm". The app accepts one known hole, and says so in its source: moves made on the sender between serving the board and hearing `game.taken` are lost to the receiver. Closing it needs a lock on UI state that the hook cannot own.

The same offer also starts "play together", where each move is sent as a small absolute message plus a checksum of the sender's board, and a receiver whose checksum differs pulls the whole board. Two players who make the first move at the same instant are resolved by an epoch, then the lower `PeerId`. All of that is the app's. The Kit supplied request/reply, the ordered delivery per sender, and `admit`, which the hook uses to refuse a peer with another protocol number. From the minesweeper demo app's `lib/coordination/game_hook.dart`:

```dart
/// The person said yes to [o]: pull the board, apply it, confirm. Returns what happened, in words.
Future<String> accept(Offer o) async {
  final h = hub!;
  final peer = h.readyPeers.where((p) => p.id == o.from).firstOrNull;
  incoming.remove(o.from);
  if (peer == null) return _done('${PeerJson.label(o.from)} is no longer connected.');
  try {
    final reply = await h.request(peer, PeerJson.encode({'offer': o.id}), kind: 'game.take', schema: 1);
    final j = reply.jsonBody;
    if (j is! Map || j['ok'] != true || j['board'] is! Map) return _done('${PeerJson.label(o.from)} no longer has that game to give.');
    try {
      host.adoptBoard((j['board'] as Map).cast<String, Object?>());
    } on FormatException catch (e) {
      return _done('The game from ${PeerJson.label(o.from)} was not accepted: ${e.message}');
    }
    if (o.mode == 'share') sharing = o.from;
    try {
      final ack = (await h.request(peer, PeerJson.encode({'offer': o.id}), kind: 'game.taken', schema: 1)).jsonBody;
      if (ack is Map && ack['ok'] == true) return _done(o.mode == 'share' ? 'Playing together with ${PeerJson.label(o.from)}.' : 'Took over the game from ${PeerJson.label(o.from)}.');
    } on PeerError {
      // fall through
    }
    return _done('Took the game, but ${PeerJson.label(o.from)} did not confirm: it may still show the game too.');
  } on PeerError catch (e) {
    return _done('Could not get the game from ${PeerJson.label(o.from)}: ${e.message}');
  }
}
```

## 14. What the hook does not give you

These are the places where the hook is not enough. Each has the pattern the demo apps used. None is built into the Kit. Section 7.1 of the spec records why large transfer was not built and what it would need.

| Missing | What you get instead | Pattern the demo apps used |
|---|---|---|
| **Acknowledgement** | `send` completes when the transport took the frame | Make the receiver answer. Minesweeper's handoff is a `request` whose reply carries the board, followed by a second `request` as confirmation. Notepad pulls content by `request`. Stopwatch accepts at-least-once delivery of "finished" and adds a takeover after a grace period |
| **Large transfer** | One message is one frame, up to 1 MiB here and 64 KiB on Hearth. Nothing splits or reassembles | Notepad's `lib/kit_gaps/blob_pull.dart` (79 lines) pulls a note part by part over `request`/`reply`: parts are sized under the smaller limit, every part carries a version tag and a changed tag restarts the pull (up to 3 attempts), a size cap and a part-count bound are checked as parts arrive, and the outcomes are kept apart: `null` for gone or changing, `FormatException` for a malformed reply, `PeerError` for a lost or silent peer. Payload bytes become base64 inside the envelope's own base64, about 1.8 times larger on the wire. Not built into the Kit: one app wants it |
| **Replay for late joiners** | A copy that connects later sees nothing that was sent before it was ready | Put a version, digest or the small state itself in `hello()`, and let whoever is ahead push on `ready`. Stopwatch carries the whole countdown state in the hello, a small JSON object. Notepad carries `{proto, digest, count}` and exchanges indexes when digests differ. Minesweeper drops pending offers on `lost` and never replays them |
| **Liveness ticks** | No heartbeat or keepalive runs on a link. Loopback detects a dead process through the dropped TCP connection and a 1 s file beat; a silent but connected copy stays `ready` | Notepad runs its own 30-second `sync.digest` broadcast, which doubles as a repair for a lost message. A real network transport will need a heartbeat; the spec says the Kit must supply one on Hearth |
| **Ordering across senders** | Per-sender order only | Stopwatch orders writes by a Lamport stamp `(rev, writer)` instead of a clock. Minesweeper uses an epoch, then the lower `PeerId`, plus a checksum to notice when the order failed |
| **Atomic exchange** | No transaction. Two parties cannot change state together | Pull, apply, confirm, release. A failure costs a duplicate rather than a loss. See the handoff above |
| **Per-app credentials** | None. See [section 2](#2-the-scope-key) | Every demo hook validates the shape, range and size of each message and counts what it refuses. Offers are shown to the person instead of applied. A security review is pending; details withheld |

Smaller gaps you will meet:

- **`onMessage` is synchronous.** The hub processes one link's frames one at a time. If a message needs async work, queue it in your hook (notepad has a pump with a bound).
- **One hub is one channel, and `admit` is one answer per peer.** "Accept this peer but not its offers" cannot be expressed. Use one hub per facet or a mux hook.
- **No "same device" signal.** Two copies with one device id are one replica to your files. Notepad compares `peer.id.device` itself in `admit` and rejects them.
- **No place for hook state, and no clock.** A stamp or a version that must survive a restart goes in your own file. A timer inside a hook is a plain `Timer`.
- **`hello()` is a snapshot taken at connect.** A command can land between the hello and `ready`; the stopwatch re-checks on `ready` for that reason.

## 15. Real transports

Only the fake network and the loopback provider are built. **There is no provider for a real network, and no Hearth provider for the Dart hub.** What follows is what a provider has to do, and what was learned about Hearth before writing one.

### What every provider must do

The contract is in [`provider.dart`](../dart/app_context_kit/lib/src/peers/provider.dart). In short:

- `open(self)` announces this copy and starts accepting. `discover()` replays what is known, then follows changes, and re-emits a candidate with `available: false` when it goes away. `connect(candidate)` throws `PeerScopeError` outside the scope and `PeerConnectError` when it cannot reach the candidate. `incoming` buffers until listened to. `close()` is idempotent.
- **Never offer, dial or accept another account or app id.** The hub checks too, but a provider that leaks scope is a bug.
- **Discovery must be symmetric.** Only the lower `PeerId` dials, so both copies have to see each other, or neither connects.
- A link delivers one `send` as one inbound event. Framing is the provider's job. `send` completes when the transport has taken the bytes.
- A link's `remote` identity is a claim. The hub checks it against the frame headers and the authenticator's proof and drops the link if the scope differs. Only a real authenticator makes the proof mean anything.

### What Hearth would add

These come from the spec and from tests against a local Hearth hub. They are requirements for a provider, not code that exists in the Dart hub.

- **Payload limit.** Hearth's effective payload cap is **64 KiB minus the Kit's header**. The 1 MiB figure is the whole envelope on the Hearth side, and above it the hub drops the connection. A provider should declare its maximum payload and `send` should fail before the wire when it is exceeded. **This is not built:** `PeerProvider` has no member for a payload maximum today, so the app passes its limit to `PeerJson.fits` and `encodeWithin`.
- **Echo suppression.** The hub delivers a broadcast back to its sender. Drop frames whose `from.device` and `from.instance` are this copy's.
- **Its own correlation ids.** The hub's message id is not a safe key for matching replies. The Kit's `rid` plus `(peer, rid)` matching is already independent of it, and a provider must not rely on the transport's ids.
- **Deduplication** by message id across live delivery and catch-up, **liveness** by a heartbeat sent no more often than every 30 seconds (the hub's idle timeout is 90 seconds, and it caps publishes per hour per connection and per account), and **reconnect**.
- **Topics.** The stock hub's topic grammar rejects app-scoped topics. The Hearth tests carried app traffic on the stock topics, set `payload_type = ak.app/<app>`, and filtered at the receiver. That is a filter, not access control.

### What is built

| Piece | State |
|---|---|
| Dart hub, fake network, loopback provider | Built and tested (`dart test` in `dart/app_context_kit`: 360 passed, 7 skipped on the day of writing; six skips need a running resource-broker daemon and one is a Linux-only test) |
| A provider for a LAN or for Hearth | Not built |
| A real authenticator (keys checked against a paired set of devices, a per-app credential) | Not built. `OpenAuthenticator` accepts everyone; `SharedSecretAuthenticator` is a test fake |

See also: [Architecture](ARCHITECTURE.md#4-the-peer-handshake) for the handshake and the roster versus the peers announcement, [Context guide](CONTEXT-GUIDE.md) for the context the hub is built from, [`spec/APP-CONTEXT.md`](../spec/APP-CONTEXT.md) section 6 for the contract.
