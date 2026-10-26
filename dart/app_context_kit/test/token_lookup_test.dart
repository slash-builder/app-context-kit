// Spec section 5 item 2: token lookup and what happens when VENUE_TOKEN_FILE is set but unusable.
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

import 'support/fake_transport.dart';

AppManifest manifest([Map<String, Object?> extra = const {}]) =>
    AppManifest.fromJson({'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0', ...extra});

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-token-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, String> env([Map<String, String> more = const {}]) => {'APP_CONTEXT_SCRATCH': tmp.path, ...more};
  String configDir() => '${tmp.path}/com.slashbuilder.demo.calc/config';
  File defaultTokenFile() => File('${configDir()}/venue-token')..createSync(recursive: true);

  group('lookupVenueToken (pure)', () {
    test('VENUE_TOKEN wins over the file and the default', () {
      File('${tmp.path}/t').writeAsStringSync('from-file');
      final r = AppContext.lookupVenueToken({'VENUE_TOKEN': ' direct \n', 'VENUE_TOKEN_FILE': '${tmp.path}/t'}, configDir());
      expect((r.token, r.problem), ('direct', null));
    });

    test('VENUE_TOKEN_FILE is read and trimmed, and wins over <config>/venue-token', () {
      defaultTokenFile().writeAsStringSync('from-default');
      File('${tmp.path}/t').writeAsStringSync('from-file\n');
      final r = AppContext.lookupVenueToken({'VENUE_TOKEN_FILE': '${tmp.path}/t'}, configDir());
      expect((r.token, r.problem), ('from-file', null));
    });

    test('<config>/venue-token is the last resort', () {
      defaultTokenFile().writeAsStringSync('from-default\n');
      final r = AppContext.lookupVenueToken({}, configDir());
      expect((r.token, r.problem), ('from-default', null));
    });

    test('nothing configured is neither a token nor a problem', () {
      final r = AppContext.lookupVenueToken({}, configDir());
      expect((r.token, r.problem), (null, null));
    });

    test('empty variables count as unset', () {
      defaultTokenFile().writeAsStringSync('from-default');
      final r = AppContext.lookupVenueToken({'VENUE_TOKEN': '', 'VENUE_TOKEN_FILE': ''}, configDir());
      expect(r.token, 'from-default');
    });

    test('a VENUE_TOKEN_FILE that is missing is a problem and does NOT fall through to <config>/venue-token', () {
      defaultTokenFile().writeAsStringSync('from-default');
      final missing = '${tmp.path}/nope';
      final r = AppContext.lookupVenueToken({'VENUE_TOKEN_FILE': missing}, configDir());
      expect(r.token, isNull);
      expect(r.problem, allOf(contains('VENUE_TOKEN_FILE'), contains(missing), contains('does not exist')));
    });

    test('a VENUE_TOKEN_FILE that is empty (or only whitespace) is a problem and does not fall through', () {
      defaultTokenFile().writeAsStringSync('from-default');
      File('${tmp.path}/empty').writeAsStringSync(' \n');
      final r = AppContext.lookupVenueToken({'VENUE_TOKEN_FILE': '${tmp.path}/empty'}, configDir());
      expect(r.token, isNull);
      expect(r.problem, contains('empty'));
    });

    test('a VENUE_TOKEN_FILE that is a directory or not text is a problem, not a crash', () {
      expect(AppContext.lookupVenueToken({'VENUE_TOKEN_FILE': tmp.path}, configDir()).problem, isNotNull);
      File('${tmp.path}/bin').writeAsBytesSync([0xff, 0xfe, 0xfd]);
      expect(AppContext.lookupVenueToken({'VENUE_TOKEN_FILE': '${tmp.path}/bin'}, configDir()).problem, isNotNull);
    });
  });

  group('AppContext.open', () {
    test('auto: a missing VENUE_TOKEN_FILE degrades to a local session whose description names the problem (and warns)', () async {
      defaultTokenFile().writeAsStringSync('from-default');
      final missing = '${tmp.path}/nope';
      final t = FakeTransport((m, p) => reply(200));
      final ctx = await AppContext.open(manifest(),
          env: env({'VENUE_TOKEN_FILE': missing}), platform: 'linux', home: '/x', announce: false, transport: t);
      expect(ctx.venue.kind, 'local');
      expect(ctx.venue.description, allOf(contains('VENUE_TOKEN_FILE'), contains(missing)));
      expect(ctx.notes.last.severity, NoteSeverity.warning);
      expect(t.requests, isEmpty, reason: 'no token, so the daemon is never asked');
      await ctx.close();
    });

    test('auto: an empty VENUE_TOKEN_FILE degrades the same way', () async {
      File('${tmp.path}/empty').writeAsStringSync('');
      final ctx = await AppContext.open(manifest(),
          env: env({'VENUE_TOKEN_FILE': '${tmp.path}/empty'}), platform: 'linux', home: '/x', announce: false);
      expect(ctx.venue.kind, 'local');
      expect(ctx.venue.description, contains('empty'));
      await ctx.close();
    });

    test('on: a missing VENUE_TOKEN_FILE fails to open with a VenueUnavailable that names the problem', () async {
      await expectLater(
          AppContext.open(manifest({'venue': {'mode': 'on'}}),
              env: env({'VENUE_TOKEN_FILE': '${tmp.path}/nope'}), platform: 'linux', home: '/x', announce: false),
          throwsA(isA<VenueUnavailable>().having((e) => e.reason, 'reason', contains('VENUE_TOKEN_FILE'))));
    });

    test('off: a broken VENUE_TOKEN_FILE is irrelevant', () async {
      final ctx = await AppContext.open(manifest({'venue': {'mode': 'off'}}),
          env: env({'VENUE_TOKEN_FILE': '${tmp.path}/nope'}), platform: 'linux', home: '/x', announce: false);
      expect(ctx.venue.kind, 'local');
      expect(ctx.notes.last.severity, NoteSeverity.info);
      await ctx.close();
    });

    test('a good token and a healthy daemon give a Venue session (the fake transport sees /healthz)', () async {
      File('${tmp.path}/t').writeAsStringSync('tok');
      final t = FakeTransport((m, p) => reply(200));
      final ctx = await AppContext.open(manifest(),
          env: env({'VENUE_TOKEN_FILE': '${tmp.path}/t', 'VENUE_DAEMON': 'http://example.invalid:1'}),
          platform: 'linux', home: '/x', announce: false, transport: t);
      expect(ctx.venue.kind, 'venue');
      expect(t.requests, ['GET /healthz']);
      await ctx.close();
      expect(t.closed, isTrue);
    });

    test('auto: a daemon that does not answer degrades to local with a warning', () async {
      final t = FakeTransport((m, p) => throw const SocketException('refused'));
      final ctx = await AppContext.open(manifest(),
          env: env({'VENUE_TOKEN': 'tok'}), platform: 'linux', home: '/x', announce: false, transport: t);
      expect(ctx.venue.kind, 'local');
      expect(ctx.venue.description, contains('did not answer'));
      expect(ctx.notes.last.severity, NoteSeverity.warning);
      expect(t.closed, isTrue);
      await ctx.close();
    });

    test('on: a daemon that does not answer fails to open', () async {
      final t = FakeTransport((m, p) => throw const SocketException('refused'));
      await expectLater(
          AppContext.open(manifest({'venue': {'mode': 'on'}}),
              env: env({'VENUE_TOKEN': 'tok'}), platform: 'linux', home: '/x', announce: false, transport: t),
          throwsA(isA<VenueUnavailable>()));
    });
  });
}
