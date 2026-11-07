# Changelog (Dart packages)

Changes to `app_context_kit`, `app_context_kit_flutter` and `app_context_kit_secure`. The Dart packages are not published to pub.dev and
are not versioned yet; the Rust crate has its own [changelog](../rust/CHANGELOG.md). Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

* `app_context_kit`: the `SecretStore` interface, `InMemorySecretStore` (test fake) and `migrateSecret` (moves a plaintext secret into
  a secret store, verified, then removes the plaintext; never loses the value). Pure Dart.
* `app_context_kit_secure` (new package): `FlutterSecureSecretStore`, a `SecretStore` over `flutter_secure_storage`, with the macOS
  legacy-keychain default and the Linux Secret Service behaviour documented in its README.

### Changed

* **Breaking (alpha):** `FlutterSecureSecretStore` moved from `app_context_kit_flutter` to `app_context_kit_secure`, and
  `app_context_kit_flutter` no longer depends on `flutter_secure_storage`, so an app that stores no secrets does not link the plugin.
  An app that uses the store adds `app_context_kit_secure` to its pubspec and imports
  `package:app_context_kit_secure/app_context_kit_secure.dart`.
