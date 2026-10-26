// Spec section 5 items 6 and 7: typed Venue answers, VenueSession.holds(), and an honest withHold. No socket involved.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

import 'support/fake_transport.dart';

const need = VenueNeed(name: 'job-1', contractClass: 'container.run.v1');

RemoteVenue remote(FakeTransport t, {String consumer = 'calc'}) =>
    RemoteVenue(base: Uri.parse('http://venue.test:7878'), token: 'tok', consumer: consumer, transport: t);

Matcher refused(VenueRefusalKind kind) => isA<VenueRefused>().having((e) => e.kind, 'kind', kind);

void main() {
  group('RemoteVenue.hold maps HTTP status to a typed answer', () {
    test('201 is a hold, with the daemon-given name and expiry', () async {
      final t = FakeTransport((m, p) => reply(201, jsonEncode({'name': 'job-1', 'expiresAt': '2030-01-02T03:04:05Z'})));
      final h = await remote(t).hold(need);
      expect((h.name, h.where), ('job-1', 'venue'));
      expect(h.expiresAt, DateTime.utc(2030, 1, 2, 3, 4, 5));
      expect(t.requests, ['POST /v1/holds']);
    });

    test('409 is VenueRefused(doesNotFit), retryable, and keeps the reason text', () async {
      final t = FakeTransport((m, p) => reply(409, '{"error":{"code":"does_not_fit","message":"7Gi does not fit"}}'));
      final e = await remote(t).hold(need).then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, refused(VenueRefusalKind.doesNotFit));
      expect((e as VenueRefused).retryable, isTrue);
      expect(e.reason, contains('7Gi does not fit'));
    });

    test('403 is VenueRefused(forbidden), not retryable, and keeps the reason text', () async {
      final t = FakeTransport((m, p) => reply(403, '{"error":{"code":"forbidden","message":"live-hold limit reached"}}'));
      final e = await remote(t).hold(need).then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, refused(VenueRefusalKind.forbidden));
      expect((e as VenueRefused).retryable, isFalse);
      expect(e.reason, contains('live-hold limit reached'));
    });

    for (final status in [400, 401, 404, 422, 500, 503]) {
      test('$status is VenueUnavailable carrying the status and the text', () async {
        final t = FakeTransport((m, p) => reply(status, 'body-$status'));
        final e = await remote(t).hold(need).then<Object?>((_) => null, onError: (Object e) => e);
        expect(e, isA<VenueUnavailable>());
        expect((e as VenueUnavailable).status, status);
        expect(e.reason, allOf(contains('HTTP $status'), contains('body-$status')));
      });
    }

    test('a transport failure and a timeout are VenueUnavailable, not raw socket errors', () async {
      for (final boom in <Object>[const SocketException('down'), TimeoutException('slow'), const HttpException('bad')]) {
        final t = FakeTransport((m, p) => throw boom);
        await expectLater(remote(t).hold(need), throwsA(isA<VenueUnavailable>().having((e) => e.status, 'status', isNull)));
        await expectLater(remote(t).holds(), throwsA(isA<VenueUnavailable>()));
        await expectLater(remote(t).nodes(), throwsA(isA<VenueUnavailable>()));
      }
    });

    test('a long reason is shortened', () async {
      final t = FakeTransport((m, p) => reply(409, 'x' * 1000));
      final e = await remote(t).hold(need).then<Object?>((_) => null, onError: (Object e) => e);
      expect((e as VenueRefused).reason.length, lessThan(310));
    });
  });

  group('RemoteVenue.start / renew / release', () {
    test('403 and 409 are typed refusals, other failures are VenueUnavailable, with the operation in the text', () async {
      final h = VenueHold('job-1', 'venue', null);
      Future<Object?> err(int status, Future<void> Function(RemoteVenue) f) =>
          f(remote(FakeTransport((m, p) => reply(status, 'nope')))).then<Object?>((_) => null, onError: (Object e) => e);
      expect(await err(403, (v) => v.start(h)), refused(VenueRefusalKind.forbidden));
      expect(await err(409, (v) => v.renew(h)), refused(VenueRefusalKind.doesNotFit));
      expect(await err(500, (v) => v.release(VenueHold('job-1', 'venue', null))), isA<VenueUnavailable>());
      expect(((await err(410, (v) => v.renew(h))) as VenueUnavailable).reason, allOf(contains('renew'), contains('410')));
      expect(((await err(401, (v) => v.start(h))) as VenueUnavailable).reason, contains('start'));
    });

    test('start marks the hold started; release treats 404 and 410 as already gone, and is only sent once', () async {
      for (final gone in [200, 204, 404, 410]) {
        final t = FakeTransport((m, p) => m == 'DELETE' ? reply(gone) : reply(200));
        final v = remote(t);
        final h = VenueHold('job-1', 'venue', null);
        await v.start(h);
        expect(h.started, isTrue);
        await v.release(h);
        await v.release(h);
        expect(h.released, isTrue);
        expect(t.requests, ['POST /v1/holds/job-1/start', 'DELETE /v1/holds/job-1'], reason: 'status $gone');
      }
    });

    test('hold names are escaped as one path segment', () async {
      final t = FakeTransport((m, p) => reply(200));
      final v = remote(t);
      final h = VenueHold('a/b?c', 'venue', null);
      await v.renew(h);
      expect(t.requests.single, 'POST /v1/holds/a%2Fb%3Fc/renew');
    });
  });

  group('holds()', () {
    test('Remote lists GET /v1/holds and keeps only this consumer\'s live ones', () async {
      final t = FakeTransport((m, p) => reply(
          200,
          jsonEncode({
            'items': [
              {'name': 'mine-1', 'holder': 'calc', 'expiresAt': '2030-01-02T03:04:05Z'},
              {'name': 'theirs', 'holder': 'notepad'},
              {'name': 'mine-2', 'holder': 'calc', 'live': true, 'startedAt': '2030-01-01T00:00:00Z'},
              {'name': 'lapsed', 'holder': 'calc', 'live': false},
              {'holder': 'calc'},
              'junk',
            ]
          })));
      final hs = await remote(t).holds();
      expect(t.requests, ['GET /v1/holds']);
      expect(hs.map((h) => h.name), ['mine-1', 'mine-2']);
      expect(hs.first.expiresAt, DateTime.utc(2030, 1, 2, 3, 4, 5));
      expect(hs.map((h) => h.started), [false, true]);
      expect(hs.every((h) => h.where == 'venue'), isTrue);
    });

    test('Remote: a non-200 is typed, and an odd 200 body is VenueUnavailable', () async {
      await expectLater(remote(FakeTransport((m, p) => reply(403))).holds(), throwsA(refused(VenueRefusalKind.forbidden)));
      await expectLater(remote(FakeTransport((m, p) => reply(502))).holds(), throwsA(isA<VenueUnavailable>()));
      await expectLater(remote(FakeTransport((m, p) => reply(200, 'not json'))).holds(), throwsA(isA<VenueUnavailable>()));
      await expectLater(remote(FakeTransport((m, p) => reply(200, '[]'))).holds(), throwsA(isA<VenueUnavailable>()));
    });

    for (final make in <String, VenueSession Function()>{
      'LocalVenue': () => LocalVenue('test'),
      'FakeVenue': () => FakeVenue(capacity: 5),
    }.entries) {
      test('${make.key} tracks its own live holds and forgets released ones', () async {
        final v = make.value();
        expect(await v.holds(), isEmpty);
        final a = await v.hold(const VenueNeed(name: 'a', contractClass: 'x'));
        final b = await v.hold(const VenueNeed(name: 'b', contractClass: 'x'));
        expect((await v.holds()).map((h) => h.name).toSet(), {'a', 'b'});
        await v.release(a);
        expect((await v.holds()).map((h) => h.name), ['b']);
        await v.release(b);
        expect(await v.holds(), isEmpty);
      });

      test('${make.key} holds() is empty inside no hold and live inside withHold', () async {
        final v = make.value();
        final inside = await v.withHold(need, (h) async => (await v.holds()).map((x) => x.name).toList());
        expect(inside, ['job-1']);
        expect(await v.holds(), isEmpty);
      });
    }

    test('LocalVenue refuses the same name twice with doesNotFit', () async {
      final v = LocalVenue('test');
      await v.hold(need);
      await expectLater(v.hold(need), throwsA(refused(VenueRefusalKind.doesNotFit)));
    });
  });

  group('withHold', () {
    test('a renewal failure is recorded on the hold and fires onLeaseLost once; the body still completes', () async {
      final v = _ScriptedVenue()..renewFails = true;
      final lost = <Object>[];
      final result = await v.withHold(need, (h) async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(h.renewalFailures, greaterThanOrEqualTo(2), reason: 'every failure is counted');
        expect(h.leaseLost, isTrue);
        expect(h.lastRenewalError, isA<VenueUnavailable>());
        return 'done';
      }, onLeaseLost: (h, e) => lost.add(e), renewEvery: const Duration(milliseconds: 20));
      expect(result, 'done');
      expect(lost, hasLength(1), reason: 'fired once, not on every failure');
      expect(lost.single, isA<VenueUnavailable>());
      expect(v.calls.last, 'release');
    });

    test('renewal failures are recorded even without a callback', () async {
      final v = _ScriptedVenue()..renewFails = true;
      late VenueHold seen;
      await v.withHold(need, (h) async {
        seen = h;
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }, renewEvery: const Duration(milliseconds: 20));
      expect(seen.leaseLost, isTrue);
      expect(seen.renewalFailures, greaterThan(0));
    });

    test('healthy renewals leave the hold clean and never fire onLeaseLost', () async {
      final v = _ScriptedVenue();
      var fired = false;
      late VenueHold seen;
      await v.withHold(need, (h) async {
        seen = h;
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }, onLeaseLost: (h, e) => fired = true, renewEvery: const Duration(milliseconds: 20));
      expect(v.calls.where((c) => c == 'renew'), isNotEmpty);
      expect(fired, isFalse);
      expect((seen.leaseLost, seen.renewalFailures, seen.lastRenewalError, seen.releaseError), (false, 0, null, null));
    });

    test('an onLeaseLost callback that throws is reported to the zone, not swallowed and not fatal to the hold', () async {
      final v = _ScriptedVenue()..renewFails = true;
      final uncaught = <Object>[];
      String? result;
      await runZonedGuarded(() async {
        result = await v.withHold(need, (h) async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return 'ok';
        }, onLeaseLost: (h, e) => throw StateError('callback'), renewEvery: const Duration(milliseconds: 20));
      }, (e, st) => uncaught.add(e));
      expect(result, 'ok');
      expect(uncaught.single, isA<StateError>());
    });

    test('a failing release does not replace a successful result; it is recorded on the hold', () async {
      final v = _ScriptedVenue()..releaseFails = true;
      late VenueHold seen;
      final r = await v.withHold(need, (h) async {
        seen = h;
        return 42;
      });
      expect(r, 42);
      expect(seen.releaseError, isA<VenueUnavailable>());
    });

    test('a failing release does not replace the body\'s error either', () async {
      final v = _ScriptedVenue()..releaseFails = true;
      late VenueHold seen;
      await expectLater(
          v.withHold(need, (h) async {
            seen = h;
            throw ArgumentError('body');
          }),
          throwsArgumentError);
      expect(seen.releaseError, isNotNull);
    });

    test('release still runs when start fails, and the start error is what you get', () async {
      final v = _ScriptedVenue()..startFails = true;
      await expectLater(v.withHold(need, (h) async => 1), throwsA(isA<VenueRefused>()));
      expect(v.calls, ['hold', 'start', 'release']);
    });

    test('a refused hold throws before anything is released', () async {
      final v = _ScriptedVenue()..holdFails = true;
      await expectLater(v.withHold(need, (h) async => 1), throwsA(refused(VenueRefusalKind.forbidden)));
      expect(v.calls, ['hold']);
    });

    test('no renewal is sent after release', () async {
      final v = _ScriptedVenue();
      await v.withHold(need, (h) async => Future<void>.delayed(const Duration(milliseconds: 50)), renewEvery: const Duration(milliseconds: 20));
      final n = v.calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(v.calls.length, n);
    });
  });
}

/// A VenueSession whose calls can be made to fail, and which logs them.
class _ScriptedVenue extends VenueSession {
  bool holdFails = false, startFails = false, renewFails = false, releaseFails = false;
  final calls = <String>[];
  @override
  String get kind => 'fake';
  @override
  String get description => 'scripted';
  @override
  Future<VenueHold> hold(VenueNeed need, {int leaseSeconds = 300}) async {
    calls.add('hold');
    if (holdFails) throw VenueRefused('limit', kind: VenueRefusalKind.forbidden);
    return VenueHold(need.name, 'fake', null);
  }

  @override
  Future<void> start(VenueHold h) async {
    calls.add('start');
    if (startFails) throw VenueRefused('no', kind: VenueRefusalKind.doesNotFit);
    h.started = true;
  }

  @override
  Future<void> renew(VenueHold h) async {
    calls.add('renew');
    if (renewFails) throw VenueUnavailable('renew: HTTP 410');
  }

  @override
  Future<void> release(VenueHold h) async {
    calls.add('release');
    h.released = true;
    if (releaseFails) throw VenueUnavailable('release: HTTP 500');
  }

  @override
  Future<List<VenueHold>> holds() async => const [];
  @override
  Future<List<Map<String, Object?>>> nodes() async => const [];
  @override
  Future<void> close() async {}
}
