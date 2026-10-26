// VenueSession.withHoldWaiting: wait for capacity. FakeVenue.refuseNext makes the refusals, naps are a few milliseconds.
import 'dart:async';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

const need = VenueNeed(name: 'job', contractClass: 'container.run.v1');
const nap = Duration(milliseconds: 2);

Matcher refused(VenueRefusalKind kind) =>
    isA<VenueRefused>().having((e) => e.kind, 'kind', kind);

void main() {
  plainReasonTests();
  group('withHoldWaiting on a FakeVenue', () {
    test('no refusal: runs the body once, like withHold', () async {
      final v = FakeVenue();
      final r = await v.withHoldWaiting(need, (h) async => h.name,
          maxWait: const Duration(seconds: 1), retryEvery: nap);
      expect(r, 'job');
      expect(v.log, ['hold job', 'start job', 'release job']);
    });

    test(
        'retries a doesNotFit refusal until room appears, telling onWaiting each time',
        () async {
      final v = FakeVenue()..refuseNext(3);
      final seen = <(String, int)>[];
      final r = await v.withHoldWaiting(need, (h) async => 'ran',
          maxWait: const Duration(seconds: 5),
          retryEvery: nap,
          onWaiting: (e, n) => seen.add((e.kind.name, n)));
      expect(r, 'ran');
      expect(seen, [('doesNotFit', 1), ('doesNotFit', 2), ('doesNotFit', 3)]);
      expect(v.log.where((l) => l.startsWith('hold')), hasLength(4));
      expect(v.log.last, 'release job');
    });

    test(
        'gives up after maxWait with the LAST refusal; naps at most maxWait / retryEvery times',
        () async {
      final v = FakeVenue()..refuseNext(100);
      var waits = 0;
      await expectLater(
          v.withHoldWaiting(need, (h) async => 1,
              maxWait: nap * 3,
              retryEvery: nap,
              onWaiting: (e, n) => waits = n),
          throwsA(refused(VenueRefusalKind.doesNotFit)));
      expect(waits, 3);
      expect(v.log.where((l) => l.startsWith('hold')), hasLength(4),
          reason: 'one try, then one per nap');
    });

    test('maxWait of zero fails fast, exactly like withHold', () async {
      final v = FakeVenue()..refuseNext(1);
      var waited = false;
      await expectLater(
          v.withHoldWaiting(need, (h) async => 1,
              maxWait: Duration.zero, onWaiting: (_, __) => waited = true),
          throwsA(refused(VenueRefusalKind.doesNotFit)));
      expect(waited, isFalse);
      expect(v.log, ['hold job']);
    });

    test(
        'a forbidden refusal with no holds of its own is permanent: no waiting',
        () async {
      final v = FakeVenue()..refuseNext(1, kind: VenueRefusalKind.forbidden);
      var waited = false;
      await expectLater(
          v.withHoldWaiting(need, (h) async => 1,
              maxWait: const Duration(seconds: 5),
              retryEvery: nap,
              onWaiting: (_, __) => waited = true),
          throwsA(refused(VenueRefusalKind.forbidden)));
      expect(waited, isFalse);
    });

    test(
        'a forbidden refusal while this consumer holds something is read as its own limit and waited out',
        () async {
      final v = FakeVenue(capacity: 5);
      final mine = await v.hold(
          const VenueNeed(name: 'other', contractClass: 'container.run.v1'));
      v.refuseNext(2, kind: VenueRefusalKind.forbidden);
      var waits = 0;
      final r = await v.withHoldWaiting(need, (h) async => 'ran',
          maxWait: const Duration(seconds: 5),
          retryEvery: nap,
          onWaiting: (e, n) => waits = n);
      expect((r, waits), ('ran', 2));
      await v.release(mine);
    });

    test('the forbidden wait still ends at maxWait with the forbidden refusal',
        () async {
      final v = FakeVenue(capacity: 5);
      await v.hold(
          const VenueNeed(name: 'other', contractClass: 'container.run.v1'));
      v.refuseNext(100, kind: VenueRefusalKind.forbidden);
      await expectLater(
          v.withHoldWaiting(need, (h) async => 1,
              maxWait: nap * 2, retryEvery: nap),
          throwsA(refused(VenueRefusalKind.forbidden)));
    });

    test('a forbidden refusal is permanent when holds() itself fails',
        () async {
      final v = _HoldsFail()..refuseNext(1, kind: VenueRefusalKind.forbidden);
      await expectLater(
          v.withHoldWaiting(need, (h) async => 1,
              maxWait: const Duration(seconds: 5), retryEvery: nap),
          throwsA(refused(VenueRefusalKind.forbidden)));
    });

    test('VenueUnavailable is never retried', () async {
      final v = _Unavailable();
      await expectLater(
          v.withHoldWaiting(need, (h) async => 1,
              maxWait: const Duration(seconds: 5), retryEvery: nap),
          throwsA(isA<VenueUnavailable>()));
      expect(v.tries, 1);
    });

    test(
        'a VenueRefused thrown by the BODY is rethrown, not mistaken for a refused hold',
        () async {
      final v = FakeVenue();
      var waited = false;
      await expectLater(
          v.withHoldWaiting(
              need,
              (h) async => throw VenueRefused('body says no',
                  kind: VenueRefusalKind.doesNotFit),
              maxWait: const Duration(seconds: 5),
              retryEvery: nap,
              onWaiting: (_, __) => waited = true),
          throwsA(refused(VenueRefusalKind.doesNotFit)));
      expect(waited, isFalse);
      expect(v.log, ['hold job', 'start job', 'release job'],
          reason: 'ran once and was released');
    });

    test('cancel ends the wait at once, even in the middle of a long nap',
        () async {
      final v = FakeVenue()..refuseNext(100);
      final cancel = Completer<void>();
      final started = DateTime.now();
      final f = v.withHoldWaiting(need, (h) async => 1,
          maxWait: const Duration(minutes: 5),
          retryEvery: const Duration(minutes: 1),
          cancel: cancel.future,
          onWaiting: (_, __) =>
              Timer(const Duration(milliseconds: 10), cancel.complete));
      await expectLater(f, throwsA(isA<HoldWaitCancelled>()));
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 5)));
    });

    test('already cancelled: no hold is left behind', () async {
      final v = FakeVenue();
      await expectLater(
          v.withHoldWaiting(need, (h) async => 1,
              maxWait: nap * 5, retryEvery: nap, cancel: Future<void>.value()),
          throwsA(isA<HoldWaitCancelled>()));
      expect(await v.holds(), isEmpty);
    });

    test('a hold granted in the instant of cancelling is released, not leaked',
        () async {
      final v = _CancelDuringHold();
      await expectLater(
          v.withHoldWaiting(need, (h) async => 1,
              maxWait: nap * 5, retryEvery: nap, cancel: v.cancel.future),
          throwsA(isA<HoldWaitCancelled>()));
      expect(v.calls, ['hold', 'release']);
    });

    test('onLeaseLost is passed through to the hold once granted', () async {
      final v = _RenewFails()..refuseNext(1);
      final lost = <String>[];
      await v.withHoldWaiting(
          need, (h) => Future<void>.delayed(const Duration(milliseconds: 60)),
          maxWait: const Duration(seconds: 5),
          retryEvery: nap,
          renewEvery: const Duration(milliseconds: 10),
          onLeaseLost: (h, e) => lost.add(h.name));
      expect(lost, ['job']);
    });

    test('retryEvery must be positive (a zero nap would spin)', () async {
      await expectLater(
          FakeVenue().withHoldWaiting(need, (h) async => 1,
              maxWait: nap, retryEvery: Duration.zero),
          throwsA(isA<ArgumentError>()));
    });

    test('LocalVenue: a name already held waits for the other holder to let go',
        () async {
      final v = LocalVenue('test');
      final other = await v.hold(need);
      Timer(const Duration(milliseconds: 15), () => v.release(other));
      final r = await v.withHoldWaiting(need, (h) async => 'got it',
          maxWait: const Duration(seconds: 5), retryEvery: nap);
      expect(r, 'got it');
    });
  });

  group('FakeVenue.refuseNext', () {
    test('refuses exactly N times whatever the capacity, then behaves normally',
        () async {
      final v = FakeVenue(capacity: 9)..refuseNext(2);
      await expectLater(
          v.hold(need), throwsA(refused(VenueRefusalKind.doesNotFit)));
      await expectLater(
          v.hold(need), throwsA(refused(VenueRefusalKind.doesNotFit)));
      expect((await v.hold(need)).name, 'job');
    });
  });
}

class _HoldsFail extends FakeVenue {
  @override
  Future<List<VenueHold>> holds() async =>
      throw VenueUnavailable('holds: down');
}

class _Unavailable extends FakeVenue {
  int tries = 0;
  @override
  Future<VenueHold> hold(VenueNeed need, {int leaseSeconds = 300}) async {
    tries++;
    throw VenueUnavailable('HTTP 503');
  }
}

class _RenewFails extends FakeVenue {
  @override
  Future<void> renew(VenueHold h) async =>
      throw VenueUnavailable('renew: HTTP 410');
}

class _CancelDuringHold extends FakeVenue {
  final cancel = Completer<void>();
  final calls = <String>[];
  @override
  Future<VenueHold> hold(VenueNeed need, {int leaseSeconds = 300}) async {
    calls.add('hold');
    cancel
        .complete(); // cancelled while the request is in flight; the request still succeeds
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return VenueHold(need.name, 'fake', null);
  }

  @override
  Future<void> release(VenueHold h) async => calls.add('release');
}

void plainReasonTests() {
  group('VenueRefused.plainReason', () {
    VenueRefused r(String s) => VenueRefused(s, kind: VenueRefusalKind.forbidden);
    test('unwraps the daemon\'s error.message', () {
      expect(r('{"error":{"code":"forbidden","message":"live-hold limit reached"}}').plainReason, 'live-hold limit reached');
    });
    test('anything else is the reason unchanged', () {
      expect(r('the fake node is full').plainReason, 'the fake node is full');
      expect(r('{"error":"flat"}').plainReason, '{"error":"flat"}');
      expect(r('{"error":{"message":""}}').plainReason, '{"error":{"message":""}}');
      expect(r('start: {"error":{"message":"x"}}').plainReason, 'start: {"error":{"message":"x"}}');
    });
  });
}
