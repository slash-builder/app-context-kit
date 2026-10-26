/// The identity seam: how a hub proves it is a device of the same account, and
/// checks that the other end is.
///
/// NOT CRYPTO. The two implementations here are for tests and for loopback on
/// one machine. The real authenticator (a later step, to be designed with the owners of the
/// identity and security protocols) must:
///
///  * sign `(account, app, device, instance, challenge)` with the device key
///    and verify the signature against the paired roster (Hearth `TRoster`),
///    so "same account" is a fact about keys, not a string a peer claims;
///  * require a per-app credential (a `ServicePrincipal` with a grant to the
///    app's subtree), because an app id in `app.json` is a string anyone can
///    claim;
///  * use the verifier's `challenge`, so a recorded proof cannot be replayed.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'types.dart';

/// An opaque proof of identity. [scheme] names how to read [value].
class Proof {
  const Proof(this.scheme, this.value);
  /// Names how to read [value], for example `open` or `test-shared-secret`.
  final String scheme;
  /// The proof itself, in the scheme's own format.
  final String value;

  /// The JSON sent in the handshake.
  Map<String, Object?> toJson() => {'scheme': scheme, 'value': value};

  /// Reads a proof from JSON. Throws [FormatException] if it is not one, or is over 64 characters of scheme or 4096 of value.
  static Proof fromJson(Object? j) {
    if (j is Map && j['scheme'] is String && j['value'] is String) {
      final scheme = j['scheme'] as String;
      final value = j['value'] as String;
      if (scheme.length <= 64 && value.length <= 4096) return Proof(scheme, value);
    }
    throw const FormatException('not a proof');
  }
}

/// Proves this copy's identity to a peer and checks the peer's proof. The hub uses [OpenAuthenticator] unless you pass another.
abstract interface class PeerAuthenticator {
  /// Prove that [self] is who it says, bound to the verifier's [challenge].
  Future<Proof> prove(PeerIdentity self, String challenge);

  /// Check [proof] from [claimed] against the [challenge] we issued.
  Future<bool> verify(PeerIdentity claimed, String challenge, Proof proof);
}

/// Accepts everyone. Fine for loopback on one machine and for tests that are
/// not about identity; never for a network.
class OpenAuthenticator implements PeerAuthenticator {
  const OpenAuthenticator();

  @override
  Future<Proof> prove(PeerIdentity self, String challenge) async => const Proof('open', '');

  @override
  Future<bool> verify(PeerIdentity claimed, String challenge, Proof proof) async => proof.scheme == 'open';
}

/// Test fake: both ends know one secret; the proof is an HMAC of the identity
/// and the challenge. Stands in for "verify a signature against the roster".
class SharedSecretAuthenticator implements PeerAuthenticator {
  SharedSecretAuthenticator(String secret) : _key = utf8.encode(secret);
  final List<int> _key;

  /// The [Proof.scheme] this authenticator produces and accepts.
  static const scheme = 'test-shared-secret';

  String _mac(PeerIdentity who, String challenge) {
    final data = utf8.encode(jsonEncode([who.account, who.app, who.device, who.instance, challenge]));
    return Hmac(sha256, _key).convert(data).toString();
  }

  @override
  Future<Proof> prove(PeerIdentity self, String challenge) async => Proof(scheme, _mac(self, challenge));

  @override
  Future<bool> verify(PeerIdentity claimed, String challenge, Proof proof) async {
    if (proof.scheme != scheme) return false;
    final expected = _mac(claimed, challenge);
    if (expected.length != proof.value.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ proof.value.codeUnitAt(i);
    }
    return diff == 0;
  }
}
