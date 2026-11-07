/// A place for an app's secrets (tokens, key material), apart from its settings.
///
/// `ConfigStore` is a plain JSON file with the default file mode: it is for
/// preferences. A bearer token, a seed or a content key does not belong there or in
/// `shared_preferences` (a plain XML/JSON file on every desktop platform). It belongs
/// in the platform's secret store: Keychain on macOS and iOS, Keystore on Android,
/// the Secret Service (libsecret) on Linux. This file is the seam an app programs
/// against; `app_context_kit_secure` ships the `flutter_secure_storage` backend
/// (`FlutterSecureSecretStore`) and [InMemorySecretStore] is the fake for tests.
///
/// THE RULES a [SecretStore] follows, and that [migrateSecret] relies on:
///   * It either stores a value in the platform's secret store or it throws
///     [SecretStoreUnavailable]. It never falls back to a file, a preference or a
///     log line. "No keyring" is an error the app must show, not a reason to write
///     the secret somewhere weaker.
///   * [SecretStoreUnavailable.reason] never contains a secret.
///   * A secret is never dual-written: it has exactly one home. (Preferences may be
///     written to two stores during a rollback window; secrets may not, because a
///     second copy is a second place to steal it from.)
library;

/// The secret store cannot be reached or refused the call: no daemon on the bus,
/// a locked keyring, a call that never answered, a missing plugin. The [reason] is
/// safe to show and to log. Nothing was stored (or deleted) by the failed call.
class SecretStoreUnavailable implements Exception {
  SecretStoreUnavailable(this.reason);

  /// A plain sentence for the person. Contains no secret and no key name.
  final String reason;

  @override
  String toString() => 'SecretStoreUnavailable: $reason';
}

/// Platform secret storage, one string per key.
abstract interface class SecretStore {
  /// The stored value, or null when there is none. Throws [SecretStoreUnavailable].
  Future<String?> read(String key);

  /// Stores [value]. Throws [SecretStoreUnavailable]; then nothing was stored.
  Future<void> write(String key, String value);

  /// Removes the value (a no-op when none). Throws [SecretStoreUnavailable]; then
  /// the value may still be there.
  Future<void> delete(String key);
}

/// An in-memory [SecretStore] for tests and for a run that must touch nothing real
/// (scratch/mock mode). The three switches let a test play every way a real keyring
/// fails.
class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, String>? initial]) : values = {...?initial};

  /// What is "in the keyring". Tests read this to prove where a secret ended up.
  final Map<String, String> values;

  /// Every call throws [SecretStoreUnavailable] (no daemon, locked keyring).
  bool unavailable = false;

  /// Writes succeed but store nothing (a broken backend). Read-back verification
  /// is what catches this.
  bool dropWrites = false;

  /// Writes store a different value (a corrupting backend).
  bool corruptWrites = false;

  /// Reads that throw only for the keys listed (a keyring that fails per item).
  final Set<String> failReadsFor = {};

  /// Counts, so a test can prove a call did or did not reach the store.
  int reads = 0;
  int writes = 0;
  int deletes = 0;

  void _guard() {
    if (unavailable) {
      throw SecretStoreUnavailable('The system keyring could not be reached.');
    }
  }

  @override
  Future<String?> read(String key) async {
    reads++;
    _guard();
    if (failReadsFor.contains(key)) {
      throw SecretStoreUnavailable('The system keyring could not be reached.');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    _guard();
    if (dropWrites) return;
    values[key] = corruptWrites ? '$value~' : value;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    _guard();
    values.remove(key);
  }
}

/// What [migrateSecret] did with one secret. The names are safe to log; none
/// carries a value.
enum SecretMigrationOutcome {
  /// There was no secret anywhere. Nothing to do.
  absent,

  /// The secret is in the secret store and no plaintext copy exists.
  alreadySecure,

  /// The plaintext copy was written to the secret store, read back equal, and then
  /// removed from the plaintext store.
  moved,

  /// Both stores held a value and they differed. The secret store's value won (it
  /// is the store of record) and the plaintext copy was removed. Happens after a
  /// downgrade, an edit by an older version, and an upgrade again.
  secureWins,

  /// The secret store is unavailable and there is no plaintext copy either:
  /// nothing is known about this secret. The caller must not write to the store
  /// this run (it cannot see what is in there) and must tell the person.
  unavailable,

  /// The secret store is unavailable. The plaintext value is KEPT (so the identity
  /// is not lost) and returned for this run; the caller must tell the person.
  keptPlaintextUnavailable,

  /// The write did not read back equal. The plaintext value is KEPT and returned;
  /// the caller must tell the person.
  keptPlaintextUnverified,

  /// The secret is safe in the secret store but the plaintext copy could not be
  /// removed. The caller must tell the person.
  plaintextNotRemoved,
}

/// The result of [migrateSecret].
class SecretMigrationResult {
  const SecretMigrationResult(this.outcome, this._value);

  final SecretMigrationOutcome outcome;
  final String? _value;

  /// The value to use for this run: the secret store's, else the kept plaintext
  /// one, else null. (Kept out of [toString] on purpose.)
  String? get value => _value;

  /// True when a secret still sits in plaintext, or could not be secured: the app
  /// must warn the person visibly.
  bool get needsAttention =>
      outcome == SecretMigrationOutcome.unavailable ||
      outcome == SecretMigrationOutcome.keptPlaintextUnavailable ||
      outcome == SecretMigrationOutcome.keptPlaintextUnverified ||
      outcome == SecretMigrationOutcome.plaintextNotRemoved;

  /// False only when the secret store could not be reached.
  bool get storeReachable =>
      outcome != SecretMigrationOutcome.unavailable &&
      outcome != SecretMigrationOutcome.keptPlaintextUnavailable;

  @override
  String toString() => 'SecretMigrationResult(${outcome.name})';
}

/// Moves one secret from a plaintext home into [store].
///
/// Order, and why:
///  1. Read [store]. If it cannot be reached and [legacyValue] exists, KEEP the
///     plaintext and report it ([SecretMigrationOutcome.keptPlaintextUnavailable]):
///     losing the identity because the keyring is down would be worse than a
///     warning. With no plaintext either the outcome is
///     [SecretMigrationOutcome.unavailable]: nothing is known, and the caller
///     must not write to a store it could not read.
///  2. If [store] already holds a value it is the store of record: a leftover
///     plaintext copy is removed (and counted as [SecretMigrationOutcome.moved] when
///     equal, [SecretMigrationOutcome.secureWins] when different).
///  3. Otherwise write [legacyValue] to [store], READ IT BACK, and only when the
///     read-back equals the value call [removeLegacy]. A failed or lossy write
///     leaves the plaintext untouched.
///
/// Safe to run on every start: a second run finds nothing to move.
/// Never logs, never throws a value; a thrown [removeLegacy] becomes
/// [SecretMigrationOutcome.plaintextNotRemoved].
Future<SecretMigrationResult> migrateSecret({
  required SecretStore store,
  required String key,
  required String? legacyValue,
  required Future<void> Function() removeLegacy,
}) async {
  final legacy =
      (legacyValue == null || legacyValue.isEmpty) ? null : legacyValue;

  String? current;
  try {
    current = await store.read(key);
  } on SecretStoreUnavailable {
    return legacy == null
        ? const SecretMigrationResult(SecretMigrationOutcome.unavailable, null)
        : SecretMigrationResult(
            SecretMigrationOutcome.keptPlaintextUnavailable, legacy);
  }
  if (current != null && current.isEmpty) current = null;

  Future<SecretMigrationOutcome> dropLegacy(SecretMigrationOutcome ok) async {
    try {
      await removeLegacy();
      return ok;
    } on Object {
      return SecretMigrationOutcome.plaintextNotRemoved;
    }
  }

  if (current != null) {
    if (legacy == null) {
      return SecretMigrationResult(
          SecretMigrationOutcome.alreadySecure, current);
    }
    final o = await dropLegacy(legacy == current
        ? SecretMigrationOutcome.moved
        : SecretMigrationOutcome.secureWins);
    return SecretMigrationResult(o, current);
  }
  if (legacy == null) {
    return const SecretMigrationResult(SecretMigrationOutcome.absent, null);
  }

  try {
    await store.write(key, legacy);
    final back = await store.read(key);
    if (back != legacy) {
      return SecretMigrationResult(
          SecretMigrationOutcome.keptPlaintextUnverified, legacy);
    }
  } on SecretStoreUnavailable {
    return SecretMigrationResult(
        SecretMigrationOutcome.keptPlaintextUnavailable, legacy);
  }
  return SecretMigrationResult(
      await dropLegacy(SecretMigrationOutcome.moved), legacy);
}
