// The fingerprint forms IoTransport accepts. No daemon needed (the daemon-backed checks are in venue_tls_test.dart).
import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

void main() {
  final hex = '0123456789abcdef' * 4;

  test('parseFingerprint normalises prefix, case, colons and spaces', () {
    final want = 'sha256:$hex';
    final colons = [for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)].join(':');
    for (final form in [want, hex, hex.toUpperCase(), 'SHA256:${hex.toUpperCase()}', colons, ' $want\n', 'sha256:$colons']) {
      expect(parseFingerprint(form), want, reason: form);
    }
  });

  test('parseFingerprint rejects anything that is not 32 bytes of hex', () {
    for (final bad in ['', 'sha256:', 'abc', 'sha256:${hex}0', hex.substring(1), 'sha256:${'zz' * 32}', 'md5:$hex']) {
      expect(parseFingerprint(bad), isNull, reason: bad);
    }
  });

  test('a malformed pin fails every send with a clear error and sends nothing', () async {
    final t = IoTransport(fingerprint: 'not-a-fingerprint');
    addTearDown(t.close);
    await expectLater(t.send('GET', Uri.parse('https://127.0.0.1:1/healthz'), headers: const {}),
        throwsA(isA<TlsPinException>().having((e) => e.message, 'message', contains('not 32 bytes of hex'))));
  });

  test('RemoteVenue reports a malformed pin as VenueUnavailable naming the fingerprint', () async {
    final t = IoTransport(fingerprint: 'nope');
    addTearDown(t.close);
    final v = RemoteVenue(base: Uri.parse('https://127.0.0.1:1'), token: 't', consumer: 'calc', transport: t);
    await expectLater(v.nodes(), throwsA(isA<VenueUnavailable>().having((e) => e.reason, 'reason', contains('fingerprint'))));
  });
}
