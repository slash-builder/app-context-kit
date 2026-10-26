// Pinned TLS against a real Venue daemon that serves a self-signed certificate (no authority). Start any compatible
// daemon with TLS, note the SHA-256 fingerprint of its certificate, then run:
//   VENUE_TLS_DAEMON=https://127.0.0.1:17879 VENUE_TLS_FINGERPRINT=sha256:... VENUE_TOKEN_FILE=<calc token> \
//     dart test test/venue_tls_test.dart
// Without those three the tests skip. The token must be a consumer named `calc` with a grant for container.run.v1.
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  final daemon = env['VENUE_TLS_DAEMON'];
  final pin = env['VENUE_TLS_FINGERPRINT'];
  final tokenFile = env['VENUE_TOKEN_FILE'];
  final skip = (daemon == null || pin == null || tokenFile == null)
      ? 'set VENUE_TLS_DAEMON, VENUE_TLS_FINGERPRINT and VENUE_TOKEN_FILE (a compatible daemon with TLS must be running)'
      : null;
  if (skip != null) {
    test('pinned TLS (skipped)', () {}, skip: skip);
    return;
  }

  final base = Uri.parse(daemon!);
  final token = File(tokenFile!).readAsStringSync().trim();
  final run = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  // A well-formed fingerprint that is not the daemon's.
  final wrong = 'sha256:${'ab' * 32}';
  var n = 0;
  String unique() => 'ak-tls-${n++}-$run';

  IoTransport transport([String? fingerprint]) {
    final t = IoTransport(fingerprint: fingerprint);
    addTearDown(t.close);
    return t;
  }

  RemoteVenue remote({String? fingerprint, Uri? at}) =>
      RemoteVenue(base: at ?? base, token: token, consumer: 'calc', transport: transport(fingerprint));

  AppManifest manifest([String mode = 'auto']) => AppManifest.fromJson({
        'id': 'com.slashbuilder.demo.calc',
        'name': 'Calc',
        'version': '0.1.0',
        'venue': {'mode': mode}
      });

  Map<String, String> appEnv(Directory tmp, {String? fingerprint, Uri? at}) => {
        'HOME': tmp.path,
        'APP_CONTEXT_SCRATCH': tmp.path,
        'VENUE_TOKEN_FILE': tokenFile,
        'VENUE_DAEMON': (at ?? base).toString(),
        if (fingerprint != null) 'VENUE_DAEMON_FINGERPRINT': fingerprint,
      };

  Directory scratch() {
    final d = Directory.systemTemp.createTempSync('app-context-tls-');
    addTearDown(() => d.deleteSync(recursive: true));
    return d;
  }

  group('the right fingerprint', () {
    test('takes, starts and releases a hold over the pinned connection', () async {
      final v = remote(fingerprint: pin);
      expect(await RemoteVenue.healthy(transport(pin), base), isTrue);
      expect((await v.nodes()).first['name'], isNotEmpty);
      final out = await v.withHold(VenueNeed(name: unique(), contractClass: 'container.run.v1'), (h) async => 'started=${h.started}');
      expect(out, 'started=true');
    });

    test('hold, start, holds() and release as separate calls', () async {
      final v = remote(fingerprint: pin);
      final need = VenueNeed(name: unique(), contractClass: 'container.run.v1');
      final h = await v.hold(need);
      addTearDown(() => v.release(h));
      await v.start(h);
      expect((await v.holds()).map((x) => x.name), contains(need.name));
      await v.release(h);
      expect((await v.holds()).map((x) => x.name), isNot(contains(need.name)));
    });

    test('the fingerprint may be written with upper case, without the prefix, or with colons (as Rust accepts)', () async {
      final hex = pin!.substring('sha256:'.length);
      final colons = [for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)].join(':');
      for (final form in [hex, hex.toUpperCase(), 'SHA256:${hex.toUpperCase()}', colons, ' $pin \n']) {
        final v = remote(fingerprint: form);
        expect(await v.nodes(), isNotEmpty, reason: 'form: $form');
      }
    });

    test('AppContext.open honours VENUE_DAEMON_FINGERPRINT and gets a real session', () async {
      final tmp = scratch();
      final ctx = await AppContext.open(manifest(), env: appEnv(tmp, fingerprint: pin), announce: false);
      addTearDown(ctx.close);
      expect(ctx.venue.kind, 'venue', reason: ctx.venue.description);
      final got = await ctx.venue.withHold(VenueNeed(name: unique(), contractClass: 'container.run.v1'), (h) async => h.started);
      expect(got, isTrue);
    });
  });

  group('the wrong fingerprint', () {
    test('every call is VenueUnavailable with a message that says the certificate is not the one pinned', () async {
      final v = remote(fingerprint: wrong);
      final err =
          await v.hold(VenueNeed(name: unique(), contractClass: 'container.run.v1')).then<Object?>((_) => null, onError: (Object e) => e);
      expect(err, isA<VenueUnavailable>(), reason: '$err');
      final msg = (err as VenueUnavailable).reason;
      expect(msg, contains('not the one that was pinned'), reason: msg);
      expect(msg, contains(pin!), reason: 'it names the certificate it actually saw: $msg');
      expect(msg, contains(wrong), reason: 'and the one that was pinned: $msg');
      expect(err.status, isNull);
      await expectLater(v.nodes(), throwsA(isA<VenueUnavailable>()));
      await expectLater(v.holds(), throwsA(isA<VenueUnavailable>()));
    });

    test('healthy() is false', () async {
      expect(await RemoteVenue.healthy(transport(wrong), base), isFalse);
    });

    test('a malformed fingerprint is a clear VenueUnavailable, not a raw exception', () async {
      final v = remote(fingerprint: 'not-a-fingerprint');
      final err = await v.nodes().then<Object?>((_) => null, onError: (Object e) => e);
      expect(err, isA<VenueUnavailable>(), reason: '$err');
      expect((err as VenueUnavailable).reason, contains('fingerprint'));
    });

    test('AppContext.open in auto mode falls back to a local session and says why', () async {
      final tmp = scratch();
      final ctx = await AppContext.open(manifest(), env: appEnv(tmp, fingerprint: wrong), announce: false);
      addTearDown(ctx.close);
      expect(ctx.venue.kind, 'local');
      expect(ctx.venue.description, contains('did not answer'));
      expect(ctx.notes.map((x) => x.severity), contains(NoteSeverity.warning));
    });

    test('AppContext.open with venue mode "on" throws VenueUnavailable', () async {
      final tmp = scratch();
      await expectLater(
          AppContext.open(manifest('on'), env: appEnv(tmp, fingerprint: wrong), announce: false), throwsA(isA<VenueUnavailable>()));
    });
  });

  group('no fingerprint against a self-signed certificate', () {
    test('is refused (the system roots do not know it) as VenueUnavailable', () async {
      final v = remote();
      final err = await v.nodes().then<Object?>((_) => null, onError: (Object e) => e);
      expect(err, isA<VenueUnavailable>(), reason: '$err');
      expect((err as VenueUnavailable).reason, contains('VENUE_DAEMON_FINGERPRINT'), reason: 'it says what to do');
      expect(await RemoteVenue.healthy(transport(), base), isFalse);
    });

    test('AppContext.open without VENUE_DAEMON_FINGERPRINT does not connect (auto: local with a reason)', () async {
      final tmp = scratch();
      final ctx = await AppContext.open(manifest(), env: appEnv(tmp), announce: false);
      addTearDown(ctx.close);
      expect(ctx.venue.kind, 'local');
      expect(ctx.venue.description, contains('did not answer'));
    });
  });

  group('plain http to the TLS port', () {
    test('fails cleanly and quickly as VenueUnavailable', () async {
      final plain = base.replace(scheme: 'http');
      final v = remote(at: plain);
      final sw = Stopwatch()..start();
      final err = await v.nodes().then<Object?>((_) => null, onError: (Object e) => e);
      expect(err, isA<VenueUnavailable>(), reason: '$err');
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)), reason: 'it must not hang until the 15 s timeout');
      expect(await RemoteVenue.healthy(transport(), plain), isFalse);
    });

    test('AppContext.open over http to the TLS port falls back to local', () async {
      final tmp = scratch();
      final ctx = await AppContext.open(manifest(), env: appEnv(tmp, at: base.replace(scheme: 'http')), announce: false);
      addTearDown(ctx.close);
      expect(ctx.venue.kind, 'local');
    });
  });

  test('a pinned connection is not accepted on a different pin after reuse (the pin is per transport)', () async {
    final good = transport(pin);
    final bad = transport(wrong);
    expect(await RemoteVenue.healthy(good, base), isTrue);
    expect(await RemoteVenue.healthy(bad, base), isFalse);
    expect(await RemoteVenue.healthy(good, base), isTrue);
  });
}
