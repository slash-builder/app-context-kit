import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// The status code and body of one HTTP exchange.
class DaemonReply {
  const DaemonReply(this.status, this.body);
  /// The HTTP status code.
  final int status;
  /// The response body as text.
  final String body;
}

/// One HTTP exchange. A parameter so tests can supply replies without a socket.
abstract class DaemonTransport {
  /// Sends one request and returns the reply. Throws if no reply arrives (socket, TLS or timeout).
  Future<DaemonReply> send(String method, Uri uri, {required Map<String, String> headers, String? body, Duration timeout});
  /// Releases the connection pool. Called when the Venue session closes.
  void close();
}

/// The SHA-256 fingerprint of a DER-encoded certificate, as `sha256:` and 64 lower-case hex digits.
String fingerprintOf(List<int> der) => 'sha256:${crypto.sha256.convert(der).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

/// A fingerprint as a person might paste it: with or without the `sha256:` prefix, with colons, in any case.
/// `null` if it is not 32 bytes of hex. The result is `sha256:` and 64 lower-case hex digits, like [fingerprintOf].
String? parseFingerprint(String text) {
  var t = text.trim();
  if (t.length >= 7 && t.substring(0, 7).toLowerCase() == 'sha256:') t = t.substring(7);
  final hex = t.replaceAll(':', '').toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? 'sha256:$hex' : null;
}

/// The TLS handshake was refused for a reason the app can act on: the daemon's certificate is not the pinned one,
/// the pin is malformed, or there is no pin and the certificate is not trusted. [RemoteVenue] turns it into
/// `VenueUnavailable` with this message.
class TlsPinException implements IOException {
  TlsPinException(this.message);
  /// What is wrong with the certificate or the pin, in a sentence.
  final String message;
  @override
  String toString() => message;
}

/// Plain HTTP, HTTPS with system roots, or (with [fingerprint]) HTTPS that accepts exactly one certificate.
/// This is the piece every Dart app would otherwise copy.
///
/// With a fingerprint no authority is trusted at all (`withTrustedRoots: false`), so every certificate reaches the
/// callback and only one with the pinned SHA-256 is accepted: no name or date check, by design.
class IoTransport implements DaemonTransport {
  IoTransport({String? fingerprint})
      : given = fingerprint,
        pinned = fingerprint == null ? null : parseFingerprint(fingerprint),
        _client = fingerprint == null
            ? (HttpClient()..connectionTimeout = const Duration(seconds: 5))
            : (HttpClient(context: SecurityContext(withTrustedRoots: false))..connectionTimeout = const Duration(seconds: 5));

  /// What the caller passed, and the normalised form (`null` when none was given or it was malformed).
  final String? given;
  /// The normalised fingerprint (`sha256:` and 64 hex digits), or null when none was given or it was malformed.
  final String? pinned;
  final HttpClient _client;
  String? _mismatch;

  @override
  Future<DaemonReply> send(String method, Uri uri,
      {required Map<String, String> headers, String? body, Duration timeout = const Duration(seconds: 15)}) async {
    if (given != null) {
      if (pinned == null) {
        throw TlsPinException('the fingerprint "$given" is not 32 bytes of hex (sha256:...)');
      }
      // Nothing is sent, not even a token, to a server that does not present the pinned certificate.
      _client.badCertificateCallback = (cert, host, port) {
        final seen = fingerprintOf(cert.der);
        if (seen == pinned) return true;
        _mismatch = seen;
        return false;
      };
    }
    try {
      final req = await _client.openUrl(method, uri).timeout(timeout);
      headers.forEach(req.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        req.headers.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      return DaemonReply(res.statusCode, text);
    } on HandshakeException {
      final seen = _mismatch;
      _mismatch = null;
      if (pinned != null && seen != null) {
        throw TlsPinException('the daemon\'s certificate ($seen) is not the one that was pinned ($pinned)');
      }
      if (pinned == null && uri.scheme == 'https') {
        throw TlsPinException('the daemon\'s certificate is not trusted by the system; a self-signed venued needs its '
            'fingerprint (VENUE_DAEMON_FINGERPRINT=sha256:...)');
      }
      rethrow;
    }
  }

  @override
  void close() => _client.close(force: true);
}
