import 'manifest.dart';

/// Why resolution failed: `missing-env` (a Windows default needed `LOCALAPPDATA`, `APPDATA` or `TEMP`) or `bad-mode`.
class ResolveError implements Exception {
  ResolveError(this.code);
  /// `missing-env` or `bad-mode`.
  final String code; // missing-env | bad-mode
  @override
  String toString() => 'ResolveError($code)';
}

/// The five directories an app owns. All are plain strings; resolution does no I/O and `AppContext.open` creates them.
class AppDirs {
  const AppDirs({required this.data, required this.config, required this.state, required this.cache, required this.runtime});
  /// `data` holds the app's own files, `config` its settings, `state` things worth keeping that are not data (logs, history),
  /// `cache` what can be rebuilt, and `runtime` files that only matter while the app runs.
  final String data, config, state, cache, runtime;
  /// The five directories, in the order data, config, state, cache, runtime.
  List<String> get all => [data, config, state, cache, runtime];
  @override
  bool operator ==(Object other) =>
      other is AppDirs && other.data == data && other.config == config && other.state == state && other.cache == cache && other.runtime == runtime;
  @override
  int get hashCode => Object.hash(data, config, state, cache, runtime);
  @override
  String toString() => 'AppDirs(data: $data, config: $config, state: $state, cache: $cache, runtime: $runtime)';
}

/// [real] runs against the real services; [mock] swaps Venue and peers for in-memory fakes.
enum AppMode { real, mock }

/// The pure result of resolution (spec section 2). No I/O happened to produce it.
class Resolved {
  const Resolved({required this.prefix, required this.dirs, required this.roster, required this.scratch, required this.mode});
  /// The environment-variable prefix: the manifest's `envPrefix`, else the last id segment upper-cased with other characters as `_`.
  final String prefix;
  /// The app's directories.
  final AppDirs dirs;
  /// The roster directory. It is shared by every app, so it has no app id in its path.
  final String roster;
  /// True when `APP_CONTEXT_SCRATCH` was set.
  final bool scratch;
  /// The resolved mode.
  final AppMode mode;
}

/// The environment-variable prefix for [m]: its `envPrefix`, else the last id segment upper-cased with every character outside `A-Z0-9` replaced by `_`.
String envPrefixOf(AppManifest m) =>
    m.envPrefix ?? m.id.split('.').last.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '_');

/// Resolves directories and mode from the manifest, platform, home and environment. Pure.
Resolved resolve({
  required AppManifest manifest,
  required String platform, // linux | macos | windows
  required String home,
  required Map<String, String> env,
}) {
  final sep = platform == 'windows' ? r'\' : '/';
  String? get(String k) {
    final v = env[k];
    return (v == null || v.isEmpty) ? null : v;
  }

  // Only the target platform's separators are trimmed: `/` on linux and macos, `/` and `\` on windows.
  bool isSep(String ch) => ch == '/' || (platform == 'windows' && ch == r'\');

  // A base that is only a separator is kept as it is, so it is never reduced to nothing.
  String trim(String s) {
    var r = s;
    while (r.length > 1 && isSep(r[r.length - 1])) {
      r = r.substring(0, r.length - 1);
    }
    return r;
  }

  // A base that is still a lone separator after trimming (`/`) already ends in one: do not double it.
  String join(String a, String b) {
    final t = trim(a);
    return (t.length == 1 && isSep(t)) ? '$t$b' : '$t$sep$b';
  }
  // Scratch always joins with `/`, on every platform. Returns the base with exactly one trailing `/`.
  String scratchBase(String root) {
    final t = trim(root);
    return t.endsWith('/') ? t : '$t/';
  }

  final id = manifest.id;
  final prefix = envPrefixOf(manifest);

  // mode
  final modeText = get('${prefix}_MODE') ?? get('APP_CONTEXT_MODE') ?? 'real';
  if (modeText != 'real' && modeText != 'mock') throw ResolveError('bad-mode');
  final mode = modeText == 'mock' ? AppMode.mock : AppMode.real;

  final scratchRoot = get('APP_CONTEXT_SCRATCH');

  String need(String k) => get(k) ?? (throw ResolveError('missing-env'));

  String platformDefault(String kind) {
    switch (platform) {
      case 'linux':
        switch (kind) {
          case 'data':
            return join(get('XDG_DATA_HOME') ?? join(home, '.local/share'), id);
          case 'config':
            return join(get('XDG_CONFIG_HOME') ?? join(home, '.config'), id);
          case 'state':
            return join(get('XDG_STATE_HOME') ?? join(home, '.local/state'), id);
          case 'cache':
            return join(get('XDG_CACHE_HOME') ?? join(home, '.cache'), id);
          default:
            final rt = get('XDG_RUNTIME_DIR');
            return rt != null ? join(rt, id) : '${platformDefault('state')}/run';
        }
      case 'macos':
        final support = join(home, 'Library/Application Support');
        switch (kind) {
          case 'data':
            return '${join(support, id)}/data';
          case 'config':
            return join(join(home, 'Library/Preferences'), id);
          case 'state':
            return '${join(support, id)}/state';
          case 'cache':
            return join(join(home, 'Library/Caches'), id);
          default:
            return join(get('TMPDIR') ?? '/tmp', id);
        }
      case 'windows':
        switch (kind) {
          case 'data':
            return '${join(need('LOCALAPPDATA'), id)}\\data';
          case 'config':
            return join(need('APPDATA'), id);
          case 'state':
            return '${join(need('LOCALAPPDATA'), id)}\\state';
          case 'cache':
            return '${join(need('LOCALAPPDATA'), id)}\\cache';
          default:
            return join(need('TEMP'), id);
        }
    }
    throw ArgumentError('unknown platform $platform');
  }

  String dir(String kind) {
    final override = get('${prefix}_${kind.toUpperCase()}_DIR');
    if (override != null) return override;
    if (scratchRoot != null) return '${scratchBase(scratchRoot)}$id/$kind';
    return platformDefault(kind);
  }

  final dirs = AppDirs(data: dir('data'), config: dir('config'), state: dir('state'), cache: dir('cache'), runtime: dir('runtime'));

  String roster() {
    final o = get('APP_CONTEXT_ROSTER_DIR');
    if (o != null) return o;
    if (scratchRoot != null) return '${scratchBase(scratchRoot)}roster';
    switch (platform) {
      case 'linux':
        return join(get('XDG_RUNTIME_DIR') ?? '/tmp', 'app-context-roster');
      case 'macos':
        return join(get('TMPDIR') ?? '/tmp', 'app-context-roster');
      default:
        return join(need('TEMP'), 'app-context-roster');
    }
  }

  return Resolved(prefix: prefix, dirs: dirs, roster: roster(), scratch: scratchRoot != null, mode: mode);
}
