// Runs against a real Venue daemon. Start any compatible daemon, give it a consumer named `calc` that is granted
// container.run.v1 and limited to 3 live holds (the limit test below relies on that), then set VENUE_DAEMON and
// VENUE_TOKEN_FILE (the path of a file holding calc's token) and run:
//   VENUE_DAEMON=http://127.0.0.1:7878 VENUE_TOKEN_FILE=<calc token file> dart test test/venue_real_test.dart
// Without VENUE_TOKEN_FILE every test here is skipped, and a skipped run proves nothing about the daemon.
import 'dart:async';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

void main() {
  final tokenFile = Platform.environment['VENUE_TOKEN_FILE'];
  final skip = tokenFile == null ? 'set VENUE_DAEMON and VENUE_TOKEN_FILE (a compatible daemon must be running)' : null;

  // Hold names must be unique per run: a hold left by an earlier run would make a name clash look like a refusal.
  final run = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  String unique(String what) => 'ak-$what-$run';

  Future<AppContext> openCtx() async {
    final tmp = Directory.systemTemp.createTempSync('app-context-real-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final m = AppManifest.fromJson({'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0'});
    final ctx = await AppContext.open(m, env: {...Platform.environment, 'APP_CONTEXT_SCRATCH': tmp.path}, announce: false);
    addTearDown(ctx.close);
    expect(ctx.venue.kind, 'venue', reason: ctx.venue.description);
    return ctx;
  }

  test('opens a real session, takes a hold, starts it and releases it', () async {
    final ctx = await openCtx();
    expect((await ctx.venue.nodes()).first['name'], isNotEmpty);
    final name = unique('basic');
    final out = await ctx.venue.withHold(VenueNeed(name: name, contractClass: 'container.run.v1'), (h) async => '${h.name} started=${h.started}');
    expect(out, '$name started=true');
  }, skip: skip);

  test('holds() lists this consumer\'s own live holds, and not a released one', () async {
    final ctx = await openCtx();
    final name = unique('listed');
    final h = await ctx.venue.hold(VenueNeed(name: name, contractClass: 'container.run.v1'));
    addTearDown(() => ctx.venue.release(h));
    final mine = await ctx.venue.holds();
    expect(mine.map((x) => x.name), contains(name));
    expect(mine.firstWhere((x) => x.name == name).started, isFalse);
    await ctx.venue.start(h);
    expect((await ctx.venue.holds()).firstWhere((x) => x.name == name).started, isTrue);
    await ctx.venue.release(h);
    expect((await ctx.venue.holds()).map((x) => x.name), isNot(contains(name)));
  }, skip: skip);

  test('the live-hold limit (HTTP 403) surfaces as VenueRefused(forbidden), not as unavailable', () async {
    final ctx = await openCtx();
    final held = <VenueHold>[];
    addTearDown(() async {
      for (final h in held) {
        await ctx.venue.release(h);
      }
    });
    // calc has maxLiveHolds 3. Anything it already holds counts, so fill whatever room is left and then ask once more.
    final room = 3 - (await ctx.venue.holds()).length;
    for (var i = 0; i < room; i++) {
      held.add(await ctx.venue.hold(VenueNeed(name: unique('limit$i'), contractClass: 'container.run.v1')));
    }
    final err = await ctx.venue
        .hold(VenueNeed(name: unique('limit-over'), contractClass: 'container.run.v1'))
        .then<Object?>((h) {
      held.add(h); // so a wrongly granted extra hold is still released
      return null;
    }, onError: (Object e) => e);
    expect(err, isA<VenueRefused>(), reason: 'a ${err.runtimeType} instead: $err');
    final refused = err as VenueRefused;
    expect(refused.kind, VenueRefusalKind.forbidden, reason: refused.reason);
    expect(refused.retryable, isFalse);
    expect(refused.reason, isNotEmpty);
    expect(held, hasLength(room), reason: 'the 4th hold was refused, nothing extra was taken');
  }, skip: skip);

  group('withHoldWaiting against the real live-hold limit (HTTP 403 forbidden)',
      () {
    // Fills the consumer to its limit of 3 live holds and returns them (so the caller can release one or all).
    Future<List<VenueHold>> fill(AppContext ctx, String tag) async {
      final held = <VenueHold>[];
      addTearDown(() async {
        for (final h in held) {
          if (!h.released) await ctx.venue.release(h);
        }
      });
      final room = 3 - (await ctx.venue.holds()).length;
      for (var i = 0; i < room; i++) {
        held.add(await ctx.venue.hold(VenueNeed(
            name: unique('$tag$i'), contractClass: 'container.run.v1')));
      }
      return held;
    }

    test(
        'waits while it holds its own, and is granted once one of its holds ends',
        () async {
      final ctx = await openCtx();
      final held = await fill(ctx, 'wait');
      expect(held, isNotEmpty);
      Timer(const Duration(milliseconds: 400),
          () => ctx.venue.release(held.first));
      final kinds = <VenueRefusalKind>[];
      final name = unique('waited');
      final got = await ctx.venue.withHoldWaiting(
          VenueNeed(name: name, contractClass: 'container.run.v1'),
          (h) async => h.name,
          maxWait: const Duration(seconds: 20),
          retryEvery: const Duration(milliseconds: 100),
          onWaiting: (e, n) => kinds.add(e.kind));
      expect(got, name);
      expect(kinds, isNotEmpty, reason: 'it was refused at first');
      expect(kinds.toSet(), {VenueRefusalKind.forbidden},
          reason:
              'the daemon answers its limit with 403, which the Kit types as forbidden');
    }, skip: skip);

    test(
        'gives up at maxWait with the forbidden refusal when nothing is released',
        () async {
      final ctx = await openCtx();
      await fill(ctx, 'giveup');
      await expectLater(
          ctx.venue.withHoldWaiting(
              VenueNeed(
                  name: unique('never'), contractClass: 'container.run.v1'),
              (h) async => 1,
              maxWait: const Duration(milliseconds: 300),
              retryEvery: const Duration(milliseconds: 100)),
          throwsA(isA<VenueRefused>()
              .having((e) => e.kind, 'kind', VenueRefusalKind.forbidden)));
    }, skip: skip);
  });
}
