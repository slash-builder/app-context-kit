import 'dart:async';
import 'dart:io';

import 'config_store.dart';
import 'manifest.dart';
import 'resolve.dart';
import 'roster.dart';
import 'venue/transport.dart';
import 'venue/venue_session.dart';

/// How much a [AppNote] matters to the person: [info] (nothing is wrong, for example what Venue is),
/// [warning] (something is degraded but the app works, for example a damaged settings file) or [error] (something failed).
enum NoteSeverity { info, warning, error }

/// Something worth telling the person, in plain words (a damaged settings file, Venue not answering).
class AppNote {
  const AppNote(this.severity, this.text);
  /// How much this note matters.
  final NoteSeverity severity;
  /// The note, in plain words.
  final String text;
  @override
  String toString() => '${severity.name}: $text';
}

/// Thrown by [AppContext.close] after every step has run, when one or more steps failed. A failing `onClose` hook never
/// stops the later hooks or the Venue close (spec section 5 item 4).
class AppCloseError implements Exception {
  AppCloseError(this.errors, this.stackTraces);
  /// Every error thrown by a closing step, in the order the steps ran.
  final List<Object> errors;
  /// The stack trace of each entry in [errors], at the same index.
  final List<StackTrace> stackTraces;
  @override
  String toString() => 'AppCloseError(${errors.length} failed: ${errors.join('; ')})';
}

/// The root namespace for one running app: who it is, where its things live, its settings, its place in the
/// roster and its Venue session. Everything an app's `main()` used to work out for itself.
class AppContext {
  AppContext._(this.manifest, this.resolved, this.env, this.config, this.roster, this.venue, this.notes, this.instance, this._announcement);

  /// The parsed `app.json` this context was opened from.
  final AppManifest manifest;
  /// The result of resolution: prefix, directories, roster directory, scratch flag and mode.
  final Resolved resolved;
  /// The environment this context was opened with: the process environment unless `env:` was passed to [open].
  final Map<String, String> env;
  /// The app's settings file, `<config>/config.json`. See [ConfigStore].
  final ConfigStore config;
  /// The shared roster directory, for listing the apps that are running. This copy's own entry is written by [open] unless `announce` is false.
  final Roster roster;
  /// The Venue session: real, local (no Venue) or fake (mock mode). The same calls work for all three.
  final VenueSession venue;

  /// Things worth telling the person. Each has a severity so a banner can pick its colour.
  final List<AppNote> notes;

  /// The notes' text only, for callers that do not care about severity.
  List<String> get noteTexts => [for (final n in notes) n.text];

  /// This copy's random 8-hex-digit id: the part after `@` in the roster file name.
  final String instance;
  final RosterAnnouncement? _announcement;
  final _onClose = <FutureOr<void> Function()>[];
  Future<void>? _closing;

  /// The app's `data`, `config`, `state`, `cache` and `runtime` directories. All exist once [open] has returned.
  AppDirs get dirs => resolved.dirs;
  /// Whether the app is running for [AppMode.real] or under [AppMode.mock].
  AppMode get mode => resolved.mode;
  /// True in mock mode, where [venue] is an in-memory fake.
  bool get isMock => resolved.mode == AppMode.mock;
  /// True when `APP_CONTEXT_SCRATCH` put every directory under a throwaway root.
  bool get scratch => resolved.scratch;

  /// A file under the app's data directory.
  File dataFile(String name) => File('${dirs.data}${Platform.pathSeparator}$name');

  /// A JSON-able description of this context for a second runtime in the same process (spec section 8): a Rust core that
  /// should work in this app's directories under this app's instance id, without opening a context of its own.
  ///
  /// `{schema: 1, appId, instance, mode, scratch, dirs: {data, config, state, cache, runtime}, roster}`. It holds no
  /// secrets (no Venue token, no environment) and no file handles: it is plain strings and one bool, and it is a copy, not
  /// a live view. A relative directory (a relative `APP_CONTEXT_SCRATCH`) is made absolute against this process's working
  /// directory, which the adopting side shares. Taking a snapshot does not announce anything and writes nothing.
  Map<String, Object?> snapshot() => contextSnapshot(appId: manifest.id, instance: instance, resolved: resolved);

  /// Run [fn] when the context closes (after the roster entry is withdrawn, before Venue closes). Hooks run last-added first.
  void onClose(FutureOr<void> Function() fn) => _onClose.add(fn);

  /// The platform name resolution uses for this host: `macos`, `windows`, or `linux` for every other host (including Android and iOS).
  static String hostPlatform() => Platform.isMacOS ? 'macos' : (Platform.isWindows ? 'windows' : 'linux');

  /// Resolve, create the directories, read settings, open Venue, announce in the roster.
  ///
  /// [fakeCapacity] is how many holds the fake Venue (mock mode) grants at once.
  static Future<AppContext> open(
    AppManifest manifest, {
    Map<String, String>? env,
    String? platform,
    String? home,
    DaemonTransport? transport,
    bool announce = true,
    Duration heartbeat = const Duration(seconds: 5),
    int fakeCapacity = 1,
  }) async {
    final e = env ?? Platform.environment;
    final plat = platform ?? hostPlatform();
    final h = home ?? e['HOME'] ?? e['USERPROFILE'] ?? '/';
    final r = resolve(manifest: manifest, platform: plat, home: h, env: e);
    for (final d in r.dirs.all) {
      Directory(d).createSync(recursive: true);
    }
    final notes = <AppNote>[];
    final config = ConfigStore.open(Directory(r.dirs.config));
    if (config.problem != null) {
      notes.add(AppNote(NoteSeverity.warning, 'Settings: ${config.problem}. They will not be saved until the file is set aside.'));
    }
    // Venue first: if it refuses to open (mode `on`), nothing has been announced yet, so nothing leaks.
    final opened = await _openVenue(manifest, r, e, transport, fakeCapacity);
    final venue = opened.session;
    notes.add(AppNote(opened.severity, venue.description));
    final instance = newInstanceId();
    final roster = Roster(r.roster);
    RosterAnnouncement? ann;
    if (announce) {
      try {
        ann = await roster.announce(id: manifest.id, name: manifest.name, version: manifest.version, instance: instance, every: heartbeat);
      } catch (_) {
        await venue.close();
        rethrow;
      }
    }
    return AppContext._(manifest, r, e, config, roster, venue, notes, instance, ann);
  }

  static Future<({VenueSession session, NoteSeverity severity})> _openVenue(
      AppManifest m, Resolved r, Map<String, String> env, DaemonTransport? transport, int fakeCapacity) async {
    ({VenueSession session, NoteSeverity severity}) info(VenueSession s) => (session: s, severity: NoteSeverity.info);
    if (r.mode == AppMode.mock) return info(FakeVenue(capacity: fakeCapacity));
    final mode = m.venue.mode;
    if (mode == 'off') return info(LocalVenue('Venue is off for this app'));

    final lookup = lookupVenueToken(env, r.dirs.config);
    if (lookup.problem != null) {
      // A configuration error: never fall through to another token source, never pretend all is well.
      if (mode == 'on') throw VenueUnavailable('Venue is required but ${lookup.problem}');
      return (session: LocalVenue(lookup.problem!), severity: NoteSeverity.warning);
    }
    final token = lookup.token;
    if (token == null) {
      if (mode == 'on') throw VenueUnavailable('Venue is required but no token was found');
      return info(LocalVenue('Venue not configured'));
    }
    final base = Uri.parse(_nonEmpty(env['VENUE_DAEMON']) ?? 'http://127.0.0.1:7878');
    final t = transport ?? IoTransport(fingerprint: _nonEmpty(env['VENUE_DAEMON_FINGERPRINT']));
    if (!await RemoteVenue.healthy(t, base)) {
      t.close();
      if (mode == 'on') throw VenueUnavailable('Venue is required but $base did not answer');
      return (session: LocalVenue('Venue did not answer at $base'), severity: NoteSeverity.warning);
    }
    return info(RemoteVenue(base: base, token: token, consumer: m.venue.consumer, transport: t));
  }

  /// Token lookup (spec section 5 item 2): `VENUE_TOKEN`; else the file named by `VENUE_TOKEN_FILE`; else
  /// `<config>/venue-token`. If `VENUE_TOKEN_FILE` is **set** but the file is missing, unreadable or empty, `problem`
  /// says so and the lookup does **not** fall through to `<config>/venue-token`. With nothing configured at all,
  /// both are `null`. Empty variables count as unset.
  static ({String? token, String? problem}) lookupVenueToken(Map<String, String> env, String configDir) {
    final direct = _nonEmpty(env['VENUE_TOKEN'])?.trim();
    if (direct != null && direct.isNotEmpty) return (token: direct, problem: null);

    final named = _nonEmpty(env['VENUE_TOKEN_FILE']);
    if (named != null) {
      final text = _readToken(File(named));
      if (text.problem != null) return (token: null, problem: 'VENUE_TOKEN_FILE is set to $named but ${text.problem}');
      return (token: text.token, problem: null);
    }

    final f = File('$configDir${Platform.pathSeparator}venue-token');
    if (!f.existsSync()) return (token: null, problem: null);
    final text = _readToken(f);
    return (token: text.token, problem: null); // an empty default file is simply "not configured"
  }

  static ({String? token, String? problem}) _readToken(File f) {
    try {
      if (!f.existsSync()) return (token: null, problem: 'the file does not exist');
      final t = f.readAsStringSync().trim();
      if (t.isEmpty) return (token: null, problem: 'the file is empty');
      return (token: t, problem: null);
    } on FileSystemException catch (e) {
      return (token: null, problem: 'the file cannot be read (${e.message})');
    } on FormatException {
      return (token: null, problem: 'the file is not valid text');
    }
  }

  static String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

  /// The whole life of an app: open, run, close (even on error). If [body] throws, its error is what you get; a failure
  /// while closing is then recorded as an error note instead of replacing it.
  static Future<T> run<T>(AppManifest manifest, Future<T> Function(AppContext ctx) body,
      {Map<String, String>? env,
      String? platform,
      String? home,
      DaemonTransport? transport,
      bool announce = true,
      Duration heartbeat = const Duration(seconds: 5),
      int fakeCapacity = 1}) async {
    final ctx = await open(manifest,
        env: env, platform: platform, home: home, transport: transport, announce: announce, heartbeat: heartbeat, fakeCapacity: fakeCapacity);
    final T result;
    try {
      result = await body(ctx);
    } catch (_) {
      try {
        await ctx.close();
      } catch (closeError) {
        ctx.notes.add(AppNote(NoteSeverity.error, 'Closing failed: $closeError'));
      }
      rethrow;
    }
    await ctx.close();
    return result;
  }

  /// Withdraws the roster entry, runs every `onClose` hook (last added first), then closes Venue. Idempotent: a second
  /// call (even a concurrent one) does not run anything again; it waits for the first to finish and returns.
  ///
  /// Every step runs even if an earlier one throws. Afterwards, if any failed, the errors are raised together as one
  /// [AppCloseError] (by the first call only).
  Future<void> close() {
    final first = _closing;
    if (first != null) return first.then((_) {}, onError: (Object _) {});
    return _closing = _closeOnce();
  }

  Future<void> _closeOnce() async {
    final errors = <Object>[];
    final traces = <StackTrace>[];
    Future<void> step(FutureOr<void> Function() f) async {
      try {
        await f();
      } catch (e, st) {
        errors.add(e);
        traces.add(st);
      }
    }

    await step(() => _announcement?.withdraw());
    for (final f in _onClose.reversed) {
      await step(f);
    }
    await step(venue.close); // last
    if (errors.isNotEmpty) throw AppCloseError(errors, traces);
  }
}

/// The snapshot schema number written by [contextSnapshot] (spec section 8). A change to the shape bumps it.
const contextSnapshotSchema = 1;

/// Builds the snapshot map for [appId], [instance] and [resolved] (spec section 8). [AppContext.snapshot] is this applied
/// to the context's own fields; it is public so a test can build the snapshot for a platform shape the host cannot open
/// (`C:\...` paths) without creating directories.
Map<String, Object?> contextSnapshot({required String appId, required String instance, required Resolved resolved}) {
  String abs(String p) => _looksAbsolute(p) ? p : Directory(p).absolute.path;
  return <String, Object?>{
    'schema': contextSnapshotSchema,
    'appId': appId,
    'instance': instance,
    'mode': resolved.mode.name,
    'scratch': resolved.scratch,
    'dirs': <String, Object?>{
      'data': abs(resolved.dirs.data),
      'config': abs(resolved.dirs.config),
      'state': abs(resolved.dirs.state),
      'cache': abs(resolved.dirs.cache),
      'runtime': abs(resolved.dirs.runtime),
    },
    'roster': abs(resolved.roster),
  };
}

/// Absolute by its own syntax, on any host: `/x`, `\\server\share`, `C:\x` or `C:/x`.
bool _looksAbsolute(String p) {
  if (p.startsWith('/') || p.startsWith(r'\\')) return true;
  if (p.length >= 3 && RegExp(r'[A-Za-z]').hasMatch(p[0]) && p[1] == ':' && (p[2] == r'\' || p[2] == '/')) return true;
  return false;
}
