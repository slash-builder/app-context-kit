import 'dart:convert';

/// Why a manifest was refused. The code is the first failure in the spec's fixed order.
class ManifestError implements Exception {
  ManifestError(this.code);
  /// The spec's code for the first failing rule: `not-json`, `not-object`, `bad-id`, `bad-name`, `bad-version`, `bad-kits`,
  /// `duplicate-kit`, `bad-prefix` or `bad-venue`.
  final String code;
  @override
  String toString() => 'ManifestError($code)';
}

/// The `venue` object of the manifest, with defaults applied.
class VenueSettings {
  const VenueSettings({this.mode = 'auto', required this.consumer});
  /// `auto`, `on` or `off`. Default `auto`.
  final String mode; // auto | on | off
  /// The name this app presents to Venue. Default: the last segment of the app id.
  final String consumer;
}

/// `app.json`: who the app is and what it asks for. See spec/APP-CONTEXT.md section 1.
class AppManifest {
  AppManifest._(this.id, this.name, this.version, this.kits, this.envPrefix, this.venue);

  /// The reverse-DNS app id, for example `com.slashbuilder.demo.calc`. It names the app's directories and its roster entry.
  final String id;
  /// The display name. Never blank.
  final String name;
  /// `MAJOR.MINOR.PATCH`, digits only.
  final String version;
  /// The kits the app opts into (unmodifiable). Only `peers` has an effect today.
  final List<String> kits;
  /// The `envPrefix` the file declared, or null when it did not. Resolution derives a prefix from the id in that case; see `envPrefixOf`.
  final String? envPrefix;
  /// The `venue` settings, with defaults applied.
  final VenueSettings venue;

  // Dart's `^`/`$` (not multi-line) anchor the whole string: `$` does NOT match before a final newline, and `\d` is ASCII-only.
  // The spec requires whole-string matches, and fixtures such as `id-trailing-newline` pin it.
  static final _id = RegExp(r'^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$');
  static final _ver = RegExp(r'^\d+\.\d+\.\d+$');
  static final _kit = RegExp(r'^[a-z][a-z0-9-]*$');
  static final _prefix = RegExp(r'^[A-Z][A-Z0-9_]*$');

  /// Parses and validates; throws [ManifestError] with the spec's first-failure code.
  static AppManifest fromJson(Object? json) {
    if (json is! Map) throw ManifestError('not-object');
    final id = json['id'];
    if (id is! String || !_id.hasMatch(id)) throw ManifestError('bad-id');
    final name = json['name'];
    if (name is! String || _isBlank(name)) throw ManifestError('bad-name');
    final version = json['version'];
    if (version is! String || !_ver.hasMatch(version)) throw ManifestError('bad-version');

    var kits = <String>[];
    if (json.containsKey('kits')) {
      final k = json['kits'];
      if (k is! List) throw ManifestError('bad-kits');
      for (final e in k) {
        if (e is! String || !_kit.hasMatch(e)) throw ManifestError('bad-kits');
      }
      kits = k.cast<String>();
      if (kits.toSet().length != kits.length) throw ManifestError('duplicate-kit');
    }

    String? prefix;
    if (json.containsKey('envPrefix')) {
      final p = json['envPrefix'];
      if (p is! String || !_prefix.hasMatch(p)) throw ManifestError('bad-prefix');
      prefix = p;
    }

    var mode = 'auto';
    var consumer = id.split('.').last;
    if (json.containsKey('venue')) {
      final v = json['venue'];
      if (v is! Map) throw ManifestError('bad-venue');
      if (v.containsKey('mode')) {
        final m = v['mode'];
        if (m is! String || !const {'auto', 'on', 'off'}.contains(m)) throw ManifestError('bad-venue');
        mode = m;
      }
      if (v.containsKey('consumer')) {
        final c = v['consumer'];
        if (c is! String || !_kit.hasMatch(c)) throw ManifestError('bad-venue');
        consumer = c;
      }
    }
    return AppManifest._(id, name, version, List.unmodifiable(kits), prefix,
        VenueSettings(mode: mode, consumer: consumer));
  }

  /// Blank means only space, tab, CR or LF (spec section 1). `String.trim` also strips U+FEFF, U+00A0 and other
  /// Unicode whitespace, which the spec counts as content.
  static bool _isBlank(String s) => s.runes.every((r) => r == 0x20 || r == 0x09 || r == 0x0D || r == 0x0A);

  /// Parses JSON text then validates it. Text that is not JSON is `not-json`; JSON that is not an object is `not-object`.
  static AppManifest parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw ManifestError('not-json');
    }
    return fromJson(decoded);
  }
}
