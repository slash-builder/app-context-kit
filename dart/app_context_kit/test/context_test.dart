import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

AppManifest manifest([Map<String, Object?> extra = const {}]) =>
    AppManifest.fromJson({'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0', ...extra});

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-test-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, String> scratchEnv([Map<String, String> more = const {}]) => {'APP_CONTEXT_SCRATCH': tmp.path, ...more};

  test('open creates the directories, announces in the roster and closes cleanly', () async {
    final ctx = await AppContext.open(manifest(), env: scratchEnv(), platform: 'linux', home: '/nonexistent');
    for (final d in ctx.dirs.all) {
      expect(Directory(d).existsSync(), isTrue, reason: d);
    }
    expect(ctx.scratch, isTrue);
    expect(ctx.roster.running().map((e) => e.id), ['com.slashbuilder.demo.calc']);
    await ctx.close();
    expect(ctx.roster.running(), isEmpty);
  });

  test('config round-trips and a corrupt file is reported, not replaced', () async {
    var ctx = await AppContext.open(manifest(), env: scratchEnv(), platform: 'linux', home: '/x', announce: false);
    ctx.config.set('fontSize', 14);
    await ctx.close();
    ctx = await AppContext.open(manifest(), env: scratchEnv(), platform: 'linux', home: '/x', announce: false);
    expect(ctx.config.get<int>('fontSize', 0), 14);
    final f = File('${ctx.dirs.config}/config.json')..writeAsStringSync('{not json');
    await ctx.close();
    ctx = await AppContext.open(manifest(), env: scratchEnv(), platform: 'linux', home: '/x', announce: false);
    expect(ctx.config.problem, isNotNull);
    expect(ctx.notes.any((n) => n.text.startsWith('Settings:') && n.severity == NoteSeverity.warning), isTrue);
    expect(ctx.noteTexts.any((t) => t.startsWith('Settings:')), isTrue);
    expect(f.readAsStringSync(), '{not json');
    await ctx.close();
  });

  test('with no token, auto degrades to a local Venue and says so', () async {
    final ctx = await AppContext.open(manifest(), env: scratchEnv(), platform: 'linux', home: '/x', announce: false);
    expect(ctx.venue.kind, 'local');
    expect(ctx.venue.description, contains('not configured'));
    await ctx.close();
  });

  test('venue mode on with no token refuses to open', () async {
    expect(
        () => AppContext.open(manifest({'venue': {'mode': 'on'}}), env: scratchEnv(), platform: 'linux', home: '/x', announce: false),
        throwsA(isA<VenueUnavailable>()));
  });

  test('mock mode gives the fake Venue and withHold runs hold, start, renew-free, release in order', () async {
    final ctx = await AppContext.open(manifest(), env: scratchEnv({'CALC_MODE': 'mock'}), platform: 'linux', home: '/x', announce: false);
    final fake = ctx.venue as FakeVenue;
    final r = await ctx.venue.withHold(const VenueNeed(name: 'j1', contractClass: 'container.run.v1'), (h) async => h.started);
    expect(r, isTrue);
    expect(fake.log, ['hold j1', 'start j1', 'release j1']);
    await ctx.close();
  });

  test('withHold releases when the body throws', () async {
    final ctx = await AppContext.open(manifest(), env: scratchEnv({'CALC_MODE': 'mock'}), platform: 'linux', home: '/x', announce: false);
    final fake = ctx.venue as FakeVenue;
    await expectLater(
        ctx.venue.withHold(const VenueNeed(name: 'j2', contractClass: 'x'), (h) async => throw StateError('boom')), throwsStateError);
    expect(fake.log.last, 'release j2');
    await ctx.close();
  });

  test('the fake refuses a hold when full', () async {
    final v = FakeVenue(capacity: 1);
    await v.hold(const VenueNeed(name: 'a', contractClass: 'x'));
    expect(() => v.hold(const VenueNeed(name: 'b', contractClass: 'x')),
        throwsA(isA<VenueRefused>().having((e) => e.kind, 'kind', VenueRefusalKind.doesNotFit)));
  });

  test('fakeCapacity sizes the fake Venue (default 1)', () async {
    const need = VenueNeed(name: 'a', contractClass: 'x');
    final env = scratchEnv({'CALC_MODE': 'mock'});
    var ctx = await AppContext.open(manifest(), env: env, platform: 'linux', home: '/x', announce: false);
    await ctx.venue.hold(need);
    await expectLater(ctx.venue.hold(const VenueNeed(name: 'b', contractClass: 'x')), throwsA(isA<VenueRefused>()));
    await ctx.close();

    ctx = await AppContext.open(manifest(), env: env, platform: 'linux', home: '/x', announce: false, fakeCapacity: 3);
    for (final n in ['a', 'b', 'c']) {
      await ctx.venue.hold(VenueNeed(name: n, contractClass: 'x'));
    }
    await expectLater(ctx.venue.hold(const VenueNeed(name: 'd', contractClass: 'x')), throwsA(isA<VenueRefused>()));
    await ctx.close();
  });

  test('notes carry a severity (info for a normal local Venue)', () async {
    final ctx = await AppContext.open(manifest(), env: scratchEnv(), platform: 'linux', home: '/x', announce: false);
    expect(ctx.notes.map((n) => n.severity), [NoteSeverity.info]);
    expect(ctx.notes.single.text, ctx.venue.description);
    expect(ctx.noteTexts, [ctx.venue.description]);
    await ctx.close();
  });

  test('a failed Venue open (mode on) leaves nothing in the roster', () async {
    final env = scratchEnv();
    await expectLater(
        AppContext.open(manifest({'venue': {'mode': 'on'}}), env: env, platform: 'linux', home: '/x'), throwsA(isA<VenueUnavailable>()));
    final roster = Roster('${tmp.path}/roster');
    expect(roster.scan(), isEmpty);
  });

  test('run closes after the body, and a close failure does not replace the body error', () async {
    final env = scratchEnv();
    late AppContext seen;
    await expectLater(
        AppContext.run(manifest(), (ctx) async {
          seen = ctx;
          ctx.onClose(() => throw StateError('hook'));
          throw ArgumentError('body');
        }, env: env, platform: 'linux', home: '/x'),
        throwsArgumentError);
    expect(seen.roster.scan(), isEmpty);
    expect(seen.notes.any((n) => n.severity == NoteSeverity.error && n.text.contains('hook')), isTrue);
  });

  test('stale roster entries are hidden', () async {
    final ctx = await AppContext.open(manifest(), env: scratchEnv(), platform: 'linux', home: '/x');
    final later = DateTime.now().toUtc().add(const Duration(minutes: 1));
    expect(ctx.roster.running(now: later), isEmpty);
    await ctx.close();
  });
}
