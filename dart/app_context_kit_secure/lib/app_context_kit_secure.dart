/// App Context Kit (platform secret store). See ../README.md.
///
/// Kept out of `app_context_kit_flutter` so an app that stores no secrets does not link the
/// `flutter_secure_storage` plugin. The `SecretStore` interface and `migrateSecret` stay in `app_context_kit`.
library;

export 'src/flutter_secure_secret_store.dart';
