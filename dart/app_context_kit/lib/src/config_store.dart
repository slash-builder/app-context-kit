import 'dart:convert';
import 'dart:io';

/// Thrown by [ConfigStore.set] and [ConfigStore.save] while the file on disk is damaged. The file is left untouched;
/// call [ConfigStore.setAsideCorrupt] to move it away and start again from empty settings.
class DamagedConfigError implements Exception {
  DamagedConfigError(this.file, this.problem);
  /// The `config.json` that could not be changed.
  final File file;
  /// Why the file is considered damaged.
  final String problem;
  @override
  String toString() => 'DamagedConfigError(${file.path}: $problem)';
}

/// A small JSON settings file in the app's config directory. Writes are atomic (temp file then rename).
///
/// A `config.json` that is not valid UTF-8 or not a JSON object is *damaged* (spec section 5 item 3). [open] reports it in
/// [problem] and still returns a usable, empty store; [set] and [save] then throw [DamagedConfigError] rather than overwrite
/// the file, until the caller explicitly calls [setAsideCorrupt].
class ConfigStore {
  ConfigStore(this.file, [Map<String, Object?>? initial]) : _values = initial ?? {};

  /// The settings file, `<config>/config.json`. It need not exist: a missing file is an empty store.
  final File file;
  final Map<String, Object?> _values;
  String? _problem;

  /// Why the file could not be read, if it could not. While this is non-null the file is damaged and is never replaced.
  String? get problem => _problem;

  /// True while the file on disk is damaged.
  bool get isDamaged => _problem != null;

  /// Reads `config.json` from [configDir] and returns a store over it. Never throws for the file's content: a damaged file
  /// is reported in [problem] and the store starts empty. A missing file is an empty store and not a problem.
  static ConfigStore open(Directory configDir) {
    final f = File('${configDir.path}${Platform.pathSeparator}config.json');
    final store = ConfigStore(f);
    if (f.existsSync()) {
      try {
        final d = jsonDecode(utf8.decode(f.readAsBytesSync())); // strict: malformed UTF-8 throws FormatException
        if (d is Map) {
          store._values.addAll(d.cast<String, Object?>());
        } else {
          store._problem = 'config.json is not a JSON object';
        }
      } on FormatException catch (e) {
        // jsonDecode and utf8.decode both throw FormatException; the message says which.
        store._problem = 'config.json is not valid UTF-8 JSON: ${e.message}';
      } on FileSystemException catch (e) {
        store._problem = 'config.json could not be read: ${e.message}';
      }
    }
    return store;
  }

  /// The value at [key] if it is a [T], else [fallback]. A whole number read as `double` is accepted (JSON `3` is `3.0`).
  T get<T>(String key, T fallback) {
    final v = _values[key];
    if (v is T) return v;
    if (v is int && (T == double || T == _typeOf<double?>())) return v.toDouble() as T;
    return fallback;
  }

  static Type _typeOf<X>() => X;

  /// The raw value stored at [key], or null.
  Object? operator [](String key) => _values[key];

  /// Sets (or, for `null`, removes) [key] and saves. Throws [DamagedConfigError] first, changing nothing, if the file is damaged.
  void set(String key, Object? value) {
    _guard();
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    save();
  }

  /// An unmodifiable copy of every key and value.
  Map<String, Object?> get all => Map.unmodifiable(_values);

  /// Writes the settings atomically. Throws [DamagedConfigError] if the file is damaged.
  void save() {
    _guard();
    final tmp = File('${file.path}.tmp');
    file.parent.createSync(recursive: true);
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(_values));
    tmp.renameSync(file.path);
  }

  /// Renames a damaged file to `config.json.corrupt` (kept, not deleted; an older `.corrupt` copy is replaced), clears
  /// [problem] and leaves the store empty. Returns the new file, or `null` if there was nothing damaged to set aside.
  File? setAsideCorrupt() {
    if (!isDamaged) return null;
    final aside = File('${file.path}.corrupt');
    if (aside.existsSync()) aside.deleteSync(); // rename does not replace an existing file on every platform
    final moved = file.existsSync() ? file.renameSync(aside.path) : null;
    _values.clear();
    _problem = null;
    return moved;
  }

  void _guard() {
    final p = _problem;
    if (p != null) throw DamagedConfigError(file, p);
  }
}
