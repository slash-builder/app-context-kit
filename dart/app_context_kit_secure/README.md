# app_context_kit_secure

The platform secret store for App Context Kit: `FlutterSecureSecretStore`, a `SecretStore` over
[`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) (Keychain on macOS and iOS, Keystore-backed storage on
Android, the Secret Service on Linux).

It is its own package so that only the apps that keep a secret link the plugin. `app_context_kit_flutter` does not depend on it, and
the `SecretStore` interface, `InMemorySecretStore` (the test fake) and `migrateSecret` (plaintext to secret store, verified, then
removed) stay in the pure-Dart core `app_context_kit`.

```yaml
dependencies:
  app_context_kit: {path: ../app-context-kit/dart/app_context_kit}
  app_context_kit_secure: {path: ../app-context-kit/dart/app_context_kit_secure}
```

```dart
import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_secure/app_context_kit_secure.dart';

final SecretStore secrets = FlutterSecureSecretStore(namespace: 'myapp.'); // namespace = your app id
```

## Behaviour

* **Fail closed.** Any plugin failure (no Secret Service, a locked keyring, a sandbox that denies the Keychain, a missing plugin) and
  any call that does not answer within `timeout` (default 15 s) is `SecretStoreUnavailable`. There is no file, preference or
  in-memory fallback. The plugin's own error text is dropped because it can name the item.
* **Namespaced.** `namespace` is prefixed to every key so two apps sharing one keychain service cannot collide.
* **Not synced.** On iOS and macOS items use `unlocked_this_device`: readable while the device is unlocked, never synced to iCloud
  Keychain, not restored to another device from a backup.

## Platform notes

* **macOS uses the legacy (file-based) keychain by default** (`usesDataProtectionKeychain: false`). The data-protection keychain
  that the plugin defaults to needs the `keychain-access-groups` entitlement, a restricted entitlement that needs a provisioning
  profile. A Developer ID build signed with an entitlements file alone gets `errSecMissingEntitlement` (-34018) from it, which would
  read as "keyring unavailable" for every user. This is not verified on a signed build by this package's tests (no native code
  runs there): an app must check once that its signed build stores and reads back a secret.
* **Linux needs a Secret Service** (gnome-keyring or KWallet, through libsecret). A headless machine or a minimal window manager
  without one cannot store secrets at all, by design; the app must say so rather than fall back to a file.
* The tests use the plugin's mock, so they prove the error mapping and the namespacing, not the native Keychain, Keystore or
  libsecret.

## Test

```
cd dart/app_context_kit_secure && flutter pub get && flutter test
```
