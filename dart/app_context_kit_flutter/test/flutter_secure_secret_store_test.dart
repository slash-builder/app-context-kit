// FlutterSecureSecretStore: round trip, namespacing, and that every way the
// plugin fails (or hangs) is SecretStoreUnavailable with no secret in it.
import 'dart:async';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _secret = 'S3CRET-VALUE';

/// Every call fails (or never answers), like a machine with no Secret Service or
/// a locked keyring waiting for a prompt.
class _BrokenStorage extends FlutterSecureStorage {
  _BrokenStorage({this.hang = false, this.error});
  final bool hang;
  final Object? error;

  Future<T> _fail<T>() {
    if (hang) return Completer<T>().future;
    throw error ?? PlatformException(code: 'Libsecret error', message: _secret);
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      _fail();

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      _fail();

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      _fail();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('round trip, with the namespace prefixed in the plugin', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = FlutterSecureSecretStore(namespace: 'courier.');
    expect(await store.read('a'), isNull);
    await store.write('a', _secret);
    expect(await store.read('a'), _secret);
    expect(await const FlutterSecureStorage().read(key: 'courier.a'), _secret);
    expect(await const FlutterSecureStorage().read(key: 'a'), isNull);
    await store.delete('a');
    expect(await store.read('a'), isNull);
  });

  test('an empty stored value reads as none', () async {
    FlutterSecureStorage.setMockInitialValues({'x': ''});
    expect(await FlutterSecureSecretStore().read('x'), isNull);
  });

  for (final op in <String, Future<void> Function(SecretStore)>{
    'read': (s) => s.read('a'),
    'write': (s) => s.write('a', _secret),
    'delete': (s) => s.delete('a'),
  }.entries) {
    test('${op.key}: a plugin error is SecretStoreUnavailable, no secret in it',
        () async {
      final store = FlutterSecureSecretStore(storage: _BrokenStorage());
      await expectLater(
        op.value(store),
        throwsA(isA<SecretStoreUnavailable>()
            .having((e) => e.toString(), 'text', isNot(contains(_secret)))),
      );
    });
  }

  test('a missing plugin is SecretStoreUnavailable', () async {
    final store = FlutterSecureSecretStore(
        storage: _BrokenStorage(error: MissingPluginException('no plugin')));
    await expectLater(store.read('a'), throwsA(isA<SecretStoreUnavailable>()));
  });

  test('a call that never answers is SecretStoreUnavailable after the timeout',
      () async {
    final store = FlutterSecureSecretStore(
      storage: _BrokenStorage(hang: true),
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(store.read('a'), throwsA(isA<SecretStoreUnavailable>()));
  });

  test('a failed write leaves nothing behind (no fallback copy)', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final broken = FlutterSecureSecretStore(storage: _BrokenStorage());
    await expectLater(
        broken.write('a', _secret), throwsA(isA<SecretStoreUnavailable>()));
    expect(await FlutterSecureSecretStore().read('a'), isNull);
  });
}
