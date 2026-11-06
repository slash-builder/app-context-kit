// migrateSecret: plaintext -> secret store, verified, then removed; never lost.
import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

const _key = 'k';
const _secret = 'S3CRET-VALUE';

void main() {
  late InMemorySecretStore store;
  late Map<String, String> plain;

  Future<SecretMigrationResult> run({bool removeThrows = false}) =>
      migrateSecret(
        store: store,
        key: _key,
        legacyValue: plain[_key],
        removeLegacy: () async {
          if (removeThrows) throw StateError('disk full');
          plain.remove(_key);
        },
      );

  setUp(() {
    store = InMemorySecretStore();
    plain = {};
  });

  test('nothing anywhere: absent, nothing written', () async {
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.absent);
    expect(r.value, isNull);
    expect(r.needsAttention, isFalse);
    expect(store.writes, 0);
  });

  test('plaintext only: written, read back, then removed', () async {
    plain[_key] = _secret;
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.moved);
    expect(r.value, _secret);
    expect(store.values[_key], _secret);
    expect(plain, isEmpty);
    expect(r.needsAttention, isFalse);
  });

  test('the plaintext is removed only AFTER the secure copy is verified',
      () async {
    plain[_key] = _secret;
    var plainAtRemoval = false;
    await migrateSecret(
      store: store,
      key: _key,
      legacyValue: plain[_key],
      removeLegacy: () async {
        plainAtRemoval = store.values[_key] == _secret;
        plain.remove(_key);
      },
    );
    expect(plainAtRemoval, isTrue);
  });

  test('a second run is a no-op', () async {
    plain[_key] = _secret;
    await run();
    final writes = store.writes;
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.alreadySecure);
    expect(r.value, _secret);
    expect(store.writes, writes);
  });

  test('secure store down: the plaintext is KEPT and returned, with a warning',
      () async {
    plain[_key] = _secret;
    store.unavailable = true;
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.keptPlaintextUnavailable);
    expect(r.value, _secret, reason: 'the identity must not be lost');
    expect(plain[_key], _secret);
    expect(r.needsAttention, isTrue);
    expect(r.storeReachable, isFalse);
    expect(store.values, isEmpty);
  });

  test('secure store down and no plaintext: unavailable (nothing is known)',
      () async {
    store.unavailable = true;
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.unavailable);
    expect(r.value, isNull);
    expect(r.storeReachable, isFalse);
    expect(r.needsAttention, isTrue);
  });

  test('a write that does not stick keeps the plaintext', () async {
    plain[_key] = _secret;
    store.dropWrites = true;
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.keptPlaintextUnverified);
    expect(r.value, _secret);
    expect(plain[_key], _secret);
    expect(r.needsAttention, isTrue);
  });

  test('a write that stores something else keeps the plaintext', () async {
    plain[_key] = _secret;
    store.corruptWrites = true;
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.keptPlaintextUnverified);
    expect(plain[_key], _secret);
  });

  test('a write that throws midway keeps the plaintext', () async {
    plain[_key] = _secret;
    // Readable (so step 1 passes) but every write fails.
    final flaky = _WriteFails();
    final r = await migrateSecret(
      store: flaky,
      key: _key,
      legacyValue: plain[_key],
      removeLegacy: () async => plain.remove(_key),
    );
    expect(r.outcome, SecretMigrationOutcome.keptPlaintextUnavailable);
    expect(plain[_key], _secret);
  });

  test('secure value present and plaintext equal: leftover removed', () async {
    plain[_key] = _secret;
    store.values[_key] = _secret;
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.moved);
    expect(plain, isEmpty);
  });

  test('both present and different: the secure store wins, plaintext removed',
      () async {
    plain[_key] = 'older-plaintext';
    store.values[_key] = _secret;
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.secureWins);
    expect(r.value, _secret);
    expect(store.values[_key], _secret);
    expect(plain, isEmpty);
  });

  test('the plaintext cannot be removed: secure copy stands, warning raised',
      () async {
    plain[_key] = _secret;
    final r = await run(removeThrows: true);
    expect(r.outcome, SecretMigrationOutcome.plaintextNotRemoved);
    expect(r.value, _secret);
    expect(store.values[_key], _secret);
    expect(r.needsAttention, isTrue);
    expect(r.storeReachable, isTrue);
  });

  test('an empty plaintext value is treated as absent', () async {
    plain[_key] = '';
    final r = await run();
    expect(r.outcome, SecretMigrationOutcome.absent);
    expect(store.writes, 0);
  });

  test('no result, outcome or exception text carries the secret', () async {
    plain[_key] = _secret;
    store.unavailable = true;
    final r = await run();
    expect('$r', isNot(contains(_secret)));
    expect(SecretStoreUnavailable('The keyring is down.').toString(),
        isNot(contains(_secret)));
    for (final o in SecretMigrationOutcome.values) {
      expect(o.name, isNot(contains(_secret)));
    }
  });
}

class _WriteFails extends InMemorySecretStore {
  @override
  Future<void> write(String key, String value) async =>
      throw SecretStoreUnavailable('The system keyring could not be reached.');
}
