// The App Context Kit's SecretStore over `flutter_secure_storage`.

import 'dart:async';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// [SecretStore] over the platform's secret storage: Keychain on macOS and iOS,
/// Keystore-backed storage on Android, the Secret Service (libsecret) on Linux.
///
/// FAIL CLOSED. Every failure of the plugin (no Secret Service on the bus, a
/// locked keyring, a sandbox that denies the Keychain, a missing plugin) becomes
/// [SecretStoreUnavailable]; a call that does not answer within [timeout] does
/// too, so a locked keyring waiting for a prompt cannot hang start-up forever.
/// This class never writes a secret anywhere else: there is no file, preference
/// or in-memory fallback in it. The plugin's own error text is dropped on
/// purpose (it can name the item).
///
/// On Linux a machine with no Secret Service (a headless box, a minimal window
/// manager without gnome-keyring or KWallet) therefore cannot store secrets at
/// all, by design; the app must say so.
class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore({
    FlutterSecureStorage? storage,
    this.namespace = '',
    this.timeout = const Duration(seconds: 15),
  }) : _storage = storage ?? _defaultStorage;

  /// Prefixed to every key, so two apps (or two uses) sharing one keychain
  /// service cannot collide. Use the app id, e.g. `courier.`.
  final String namespace;

  /// How long one call may take before the store counts as unavailable.
  final Duration timeout;

  // `unlocked_this_device`: readable while the device is unlocked, never synced
  // to iCloud Keychain and not restored to another device from a backup.
  static const _defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );

  final FlutterSecureStorage _storage;

  String _k(String key) => '$namespace$key';

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call().timeout(timeout);
    } on TimeoutException {
      throw SecretStoreUnavailable('The system keyring did not answer.');
    } on Exception {
      throw SecretStoreUnavailable('The system keyring could not be reached.');
    }
  }

  @override
  Future<String?> read(String key) async {
    final v = await _guard(() => _storage.read(key: _k(key)));
    return (v == null || v.isEmpty) ? null : v;
  }

  @override
  Future<void> write(String key, String value) =>
      _guard(() => _storage.write(key: _k(key), value: value));

  @override
  Future<void> delete(String key) =>
      _guard(() => _storage.delete(key: _k(key)));
}
