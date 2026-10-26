import 'config_store.dart';

/// Settings that keep working while `config.json` is damaged.
///
/// [ConfigStore.set] throws [DamagedConfigError] and leaves a damaged file alone, which is right for the file but leaves the
/// UI deciding what a settings change means meanwhile. Both demo apps that keep settings decided the same thing, so it
/// lives here: while the file is damaged a change is kept in memory for this session only, the file is never touched, and
/// the app shows [readOnly] to tell the person their change will not be saved.
class SessionSettings {
  /// Wraps the context's `ctx.config`.
  SessionSettings(this._store);
  final ConfigStore _store;
  final _session = <String, Object?>{};

  /// True while the settings file on disk is damaged and is being left alone (changes last for this session only).
  bool get readOnly => _store.isDamaged;

  /// The session's value for [key] if one was set while the file was damaged, else the file's, else [fallback].
  T get<T>(String key, T fallback) {
    if (readOnly && _session.containsKey(key)) {
      final v = _session[key];
      return v is T ? v : fallback;
    }
    return _store.get<T>(key, fallback);
  }

  /// Saves to the file, or, while it is damaged, keeps [value] in memory only. Never throws [DamagedConfigError].
  void set(String key, Object? value) {
    if (readOnly) {
      _session[key] = value;
    } else {
      _store.set(key, value);
    }
  }
}
