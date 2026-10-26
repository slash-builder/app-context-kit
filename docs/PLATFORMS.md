# Platforms

What runs where, how it was checked, and what was not. If a row says "not verified", nobody has run it.

| Platform | Core packages (Dart, Rust) | Flutter apps | Peers over loopback | Venue |
|---|---|---|---|---|
| macOS (Apple silicon) | Tests pass | Debug builds run; a release build was made for one demo app (notes_rust) only | Real processes tested | Real daemon tested |
| Linux | Tests pass in containers (aarch64) | Built (release) and launched headless in a container (aarch64, virtual display); not tried on a real desktop | Tested in a container | Tests against stubs only; no real daemon |
| Windows | Path-resolution fixtures only | **Not verified** | **Not verified** | **Not verified** |
| iOS, Android | **Not attempted** | **Not attempted** | **Not attempted** | **Not attempted** |

The two cores are `dart/app_context_kit` (pure Dart) and `rust/`. Both read the same 61 conformance fixtures in `spec/conformance/` (25 for path resolution, 36 for the manifest). The rules they implement are in [`spec/APP-CONTEXT.md`](../spec/APP-CONTEXT.md). The Rust crate has no remote Venue session, so the Venue column describes the Dart core.

## Where things go

For an app whose manifest id is `ID`, the Kit resolves five directories and a roster directory. `home` is the user's home directory.

| | Linux | macOS | Windows |
|---|---|---|---|
| data | `$XDG_DATA_HOME/ID`, else `home/.local/share/ID` | `home/Library/Application Support/ID/data` | `%LOCALAPPDATA%\ID\data` |
| config | `$XDG_CONFIG_HOME/ID`, else `home/.config/ID` | `home/Library/Preferences/ID` | `%APPDATA%\ID` |
| state | `$XDG_STATE_HOME/ID`, else `home/.local/state/ID` | `home/Library/Application Support/ID/state` | `%LOCALAPPDATA%\ID\state` |
| cache | `$XDG_CACHE_HOME/ID`, else `home/.cache/ID` | `home/Library/Caches/ID` | `%LOCALAPPDATA%\ID\cache` |
| runtime | `$XDG_RUNTIME_DIR/ID`, else the default state directory plus `/run` | `$TMPDIR/ID`, else `/tmp/ID` | `%TEMP%\ID` |
| roster (shared by all apps) | `$XDG_RUNTIME_DIR/app-context-roster`, else `/tmp/app-context-roster` | `$TMPDIR/app-context-roster`, else `/tmp/app-context-roster` | `%TEMP%\app-context-roster` |

Overrides, from highest priority: `<PREFIX>_<KIND>_DIR` (used exactly as given), then `APP_CONTEXT_SCRATCH` (puts everything under one directory, for tests), then the table. On Windows a missing `LOCALAPPDATA`, `APPDATA` or `TEMP` is the error `missing-env`, but only if a default that needs it is actually used.

`~/Library/Preferences/ID/config.json` is an unusual place for a JSON file on macOS, where that folder is meant for property-list files. No problem was seen. It is an open spec question.

## macOS

**What was checked.**

* Both cores' tests pass natively. Run for this page: Dart 365 passed, 7 skipped by default (the pinned-TLS group and 5 real-daemon tests, which need a daemon, and 1 Linux-only test). Rust: 83 unit, 2 conformance, 5 host-OS and 4 snapshot-conformance tests. The Dart real-daemon tests (5) and TLS tests (14) passed against throwaway daemons when this page was first written; they skip without one, so the run for this page did not exercise them.
* All six demo apps were built with `flutter build macos --debug` and launched during development. Cmd-Q and SIGTERM close the app cleanly (the roster entry is removed and Venue holds are released). Recorded in notes taken at the time; not re-run for this page.
* Two real processes find each other over loopback, exchange messages, and see each other disappear after `kill -9` (the link drop is seen in milliseconds; the peer is withdrawn in about 3.5 seconds). Tested in `dart/app_context_kit/test/peers/two_process_test.dart`; it passed in the full run for this page.
* **A copy killed with `kill -9`.** The surviving copy sees the link drop at once (about 3 ms) and withdraws the dead copy's announcement 3.5 to 3.8 s later (3.5 s on macOS, 3.8 s on Linux). Before the announcement carried a heartbeat the picture was worse: the survivor that had dialled gave up after 10 failed dials (about 31 s) but left the dead copy listed as `found` for ever (watched for 45 s); a survivor that never dials never learned the announcement was dead at all; and a restarted copy with the same device id appeared beside the ghost. The fix is in `dart/app_context_kit/lib/src/peers/loopback_provider.dart`: each provider rewrites its announcement file every second with a wall-clock `beat`; a file whose last beat is older than 4 s is not offered, and a peer already known from it is withdrawn (the hub then reports the final `lost` and stops dialling); a file older than 60 s is deleted by whoever notices. Checking the announcing process id was rejected: it means nothing across process-id namespaces (containers), ids are reused, and Dart has no portable way to ask whether a pid is alive without starting a process. The cost is one small write per second per process. Not fixed: a brief `found` right after the first `lost`, which for a crash lasts up to the 4 s limit (a graceful quit has none), because the hub deliberately re-announces a copy that is still advertised.

**What was not checked.** Release builds of the demo apps on macOS (only one, notes_rust, was built in release mode). Signed or notarized builds. The red window-close button on a real window (Cmd-Q and SIGTERM were). Launching from Finder or the Dock (see below). The text on screen in a real window: the display was off for most of the runs, so UI behaviour was read from the widget tree and from the apps' own code, not seen.

**Environment variables do not reach an app launched from Finder or the Dock.** `APP_CONTEXT_MODE`, `APP_CONTEXT_SCRATCH`, `VENUE_TOKEN_FILE` and the rest are read from the process environment. To use them, start the app's binary from a terminal. For a normal launch, put the Venue token at `<config>/venue-token` and use `config.json` for settings.

### The App Sandbox

Flutter's macOS template turns the App Sandbox on. A sandboxed app sees a private `HOME` and `TMPDIR` inside `~/Library/Containers/<bundle id>/Data`. Apple requires the sandbox for Mac App Store apps (that is Apple's rule, not something verified here).

The sandbox changes what the Kit means:

* Every directory in the table above moves into the container. Data lands under `Data/Library/Application Support/ID/`, and the default roster is `Data/tmp/app-context-roster`. **Each app has its own, so the default roster is no longer shared between apps.**
* `APP_CONTEXT_SCRATCH` and other overrides that point outside the container fail.

Today the demo apps (in The Kit Book) are mixed: the calculator, minesweeper and notepad have the sandbox on; the launcher, render-queue and stopwatch have it off (their entitlement files say `app-sandbox` is `false`). The reason is that no sandbox-on setup was found that works for all of them; see the roster row below.

How these results were obtained: copies of the built debug apps were re-signed ad hoc (no team ID) with the entitlement variants below, launched by running the binary directly, and observed through the container directory, the system log, and the widget tree. No entitlement file in the demo apps was changed by that work. These results come from notes taken at the time and were not re-run for this page.

### Entitlements by capability

| Capability | Sandbox off | Sandbox on: what it needs |
|---|---|---|
| **Talk to a local Venue daemon** (including the health check) | Nothing | `com.apple.security.network.client`. Without it the session is `local` with "Venue did not answer at ...". Only the health check and `GET` calls were exercised in a sandbox; holds that `POST` were not, and are expected (reasoned) to need the same entitlement. |
| **Read a Venue token file** | Any readable path | A path outside the container is not readable ("the file cannot be read"). Use `VENUE_TOKEN`, or `<config>/venue-token` inside the container. |
| **Loopback peers: dial another copy** | Nothing | `network.client`. |
| **Loopback peers: listen for another copy** | Nothing | `network.server`. In the Flutter template, **Debug has `network.server` only**, and then two copies both listen and **never connect, silently** (6 seconds observed; nothing in the log; the UI would read as a peer that is not up yet). Adding `network.client` fixed it: the link came up 35 ms after the announcement. The template's **Release** file has neither, so a Release build needs both added (reasoned; Release was not built). |
| **Peers directory** | Any path | The default (the roster directory plus `-peers`) is inside the container, and two copies of one app linked through it in the notepad run. A directory outside the container leaves the app running alone, with nothing written outside. |
| **Roster shared between different apps** | Works if the apps share a `TMPDIR` | **Not possible with plain entitlements.** Each app writes to its own container. It works with the temporary-exception entitlement `com.apple.security.temporary-exception.files.absolute-path.read-write` for one shared directory (measured: two sandboxed stopwatches and a sandboxed launcher shared it). That entitlement is a review problem for the Mac App Store. A shared **team app group** is the other route; it was **not achieved**, because ad-hoc signing could not create the group container. It needs a team ID and signing that were not available. Not tested with one. |
| **Scratch directory outside the container** (`APP_CONTEXT_SCRATCH=/tmp/...`) | Works | Fails: the companion shows a start-error screen ("The app's folders could not be created or read"). Earlier builds showed an unhandled exception instead. Works with the same temporary exception. |
| **Check another app's process** (`kill -0`) | Works | Reports a running sandboxed app as not existing. The launcher demo showed its rows as stale for live apps. With the sandbox on, the heartbeat is the only liveness signal. |
| **Desktop notification via `osascript`** (stopwatch demo) | Fired when the app was in front; the banner was attributed to "Script Editor" | The child process starts and no sandbox denial was logged; whether the banner appears was **not verified**. |
| **JIT / Dart VM service** (Debug builds only) | `cs.allow-jit`, `network.server` | The template adds these to the Debug file only. |

Entitlements the demo apps carry today, from the files in each demo app's `macos/Runner/` (the demo apps are in The Kit Book):

| App | Sandbox | `network.client` (Debug / Release) | `network.server` (Debug / Release) |
|---|---|---|---|
| calculator | on | no / no | yes / no |
| minesweeper | on | yes / yes | yes / yes |
| notepad | on | yes / yes | yes / yes |
| launcher | off | no / no | yes / no |
| render-queue | off | no / no | yes / no |
| stopwatch | off | no / no | yes / no |

A sandboxed render-queue (talking to Venue) would need `app-sandbox` plus `network.client`. A sandboxed stopwatch alone runs with `app-sandbox` and keeps its data in its container. The files above are what the apps carry now; they are not those minimal sets.

### Identity is declared four times

An app's id appears in `app.json`, the macOS bundle id, the Linux application id, and (name and version) `pubspec.yaml`. Nothing makes them agree. The companion package ships a check:

```sh
cd dart/app_context_kit_flutter
dart tool/check_identity.dart <path to render-queue> <path to calculator>
```

Output for two of the demo apps (exit code 1, because of the first app; the headers repeat the paths that were given):

```text
== render-queue
  MISMATCH  id: app.json says com.slashbuilder.demo.render-queue but the macOS bundle id (PRODUCT_BUNDLE_IDENTIFIER) is com.slashbuilder.demo.renderQueue
  note      name: app.json says "Render Queue" but the macOS PRODUCT_NAME is "render_queue" (same name, different letter case)
  MISMATCH  id: app.json says com.slashbuilder.demo.render-queue but the Linux application id (APPLICATION_ID) is com.slashbuilder.demo.render_queue
  note      name: app.json says "Render Queue" but the Linux window title is "render_queue" (same name, different letter case)
== calculator
  note      name: app.json says "Calculator" but the macOS PRODUCT_NAME is "calculator" (same name, different letter case)
  note      name: app.json says "Calculator" but the Linux window title is "calculator" (same name, different letter case)
  ok: id, name and version agree everywhere they were checked
```

The manifest id grammar allows hyphens, but macOS bundle ids and Linux application ids are written differently on each platform, so a hyphenated id cannot match all three. Whether the manifest may contain hyphens is an open spec decision. The check reports; it never edits. It does not look at Windows, Android or iOS.

## Linux

**What was checked.** Both cores' tests ran in Docker containers, as a non-root user, on a 6.12 `linuxkit` kernel, **aarch64** (so not x86_64), with the images `dart:stable` and `rust:1.94` (override with `DART_IMAGE` and `RUST_IMAGE`). The App Context Kit repository is mounted read-only; each container copies `spec/`, `rust/` and `dart/app_context_kit` into a tmpfs and builds there, so nothing is written back and nothing persists. The command is [`tools/linux-test.sh`](../tools/linux-test.sh):

```sh
tools/linux-test.sh            # both cores
tools/linux-test.sh dart       # one
LINUX_AS_ROOT=1 tools/linux-test.sh
```

Re-run for this page: Dart (SDK 3.13.6) conformance 61 passed and the whole package passed (366 passed, 6 skipped; the Linux-only test runs here, and the real-daemon tests skip); Rust 1.94.1: 2 conformance, 83 unit, 6 host-OS and 4 snapshot-conformance tests passed. No other checkout is needed, because the Rust crate no longer has an optional dependency on a Venue client.

When the suites were first run on Linux, the outcomes of the 306 tests that existed then were compared by name against the macOS run: no test differed. That proves less than it sounds, because almost none of them touch the real operating system (they pass `platform:` in). So `test/host_os_test.dart` and `rust/tests/host_os.rs` were added with no platform override; they check the directory conventions of the host, the rename-based config write, and the default five-second roster heartbeat (a wait of about 5.6 s: the entry is rewritten and stays live).

Directories follow the XDG variables when set and the home-relative defaults when not. This is tested without a platform override in `test/host_os_test.dart` and `rust/tests/host_os.rs`. The roster is in `/tmp/app-context-roster` when `XDG_RUNTIME_DIR` is unset. Config writes are renames, and a reader polling during a rewrite never saw a partial file (tested on Linux and macOS, both languages).

Two real processes found each other over loopback in a container too, including after a `kill -9`.

Things that differ from macOS and are worth knowing:

* Run as **root**, a token file with permissions 000 is read anyway. A container that runs your app as root will use a token file the mode was meant to hide.
* Dart returns file modification times to the microsecond on Linux and truncated to whole seconds on macOS. Nothing in the Kit relies on file times.
* **Reasoned, not tested:** `/tmp/app-context-roster` is created with the first user's umask, so a second user on the same machine probably cannot announce into it.

**What was not checked.** **A real Linux desktop session.** The demo apps (in The Kit Book) were built with `flutter build linux --release` and launched headless under a virtual display (Xvfb) in an aarch64 Ubuntu 24.04 container with Flutter 3.41.9; the test is `make linux-smoke` in The Kit Book. All seven launched, exited with status 143 on SIGTERM, wrote a roster file and withdrew it, and kept their state across a relaunch (minesweeper, notepad, stopwatch and notes_rust). Two copies of the stopwatch and two of the notepad found each other, and the notepad synced a seeded note. There were no uncaught exceptions; the only warnings were the container's missing accessibility bus and missing GPU. Still unchecked: window close by click, a compositor or window manager, a real GPU, `notify-send` (used by the stopwatch demo), other distributions, Wayland, and x86_64. The Linux application id in each runner has to match the manifest; see the identity check above.

## Windows

Verified: the path-resolution rules, as pure functions. Five of the 25 resolution fixtures use `platform: "windows"`; they cover the default locations, the missing-variable error, scratch needing no variable, trimming either kind of trailing separator, and a bad mode being reported before a missing variable. Both cores pass them. The fixtures never touch a filesystem.

**Nothing else is verified.** Neither core was built or tested on Windows. Not run: file I/O, the atomic config write, the roster and its heartbeat, loopback peers, the Flutter companion, any Venue session, the demo apps. Same-machine peers there would use the loopback provider, which has not been run on Windows. There are no Windows runner folders in the demo apps.

## iOS and Android

Not attempted. The Flutter companion's notes say there is no mobile exit story: window close, Quit and signals are desktop events, and the one mobile hook (`onDetach`) closes on a best-effort basis with no guarantee the OS gives it time. Nothing about directories, the roster, peers or Venue was checked on a phone.

## Packaging checklist

For shipping an app that is built on the Kit. Each line says what to do and where it was observed to matter.

1. **Make the ids agree.** Run `dart tool/check_identity.dart <app dir>` (from `dart/app_context_kit_flutter`). It must exit 0. Decide what a hyphenated manifest id does on each platform.
2. **Declare what you use.** `"kits": ["venue"]` for Venue, `"peers"` for the peer layer. `ctx.peerHub` throws `KitNotDeclared` if `peers` is missing.
3. **Choose sandbox on or off per channel**, and add entitlements for every capability you use (table above). Debug and Release are separate files. For peers, `network.client` and `network.server` in both.
4. **Put the Venue token where the app can read it.** Under the sandbox that is `<config>/venue-token` inside the container, or `VENUE_TOKEN`. Not a path outside it.
5. **Provision the app with Venue before it ships.** An app cannot register itself; see the [Venue guide](VENUE-GUIDE.md). Without that, the app runs on the `local` session and says so.
6. **Use short Venue leases.** A killed app keeps its quota until the lease lapses.
7. **Start through `AppContextKit.run`** (the companion package), so window close, Quit, SIGINT and SIGTERM all end in one `ctx.close()`. Test Cmd-Q and SIGTERM on the built app. `kill -9` leaves a stale roster entry (hidden after 15 seconds) and any Venue holds until the lease lapses.
8. **Test in mock and scratch modes** (`APP_CONTEXT_MODE=mock`, `APP_CONTEXT_SCRATCH=<dir>`) from a terminal; they do not reach a Finder or Dock launch.
9. **Do not use the loopback peer provider across a trust boundary.** It has no encryption or authentication. It is for copies of an app on one machine, run by one user.
10. **Run on the real target.** On Linux the Kit has headless container evidence only (see "What was not checked" under Linux above); on Windows and mobile it has none.
