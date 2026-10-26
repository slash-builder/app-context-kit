import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:app_context_kit_flutter/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  group('loadManifest', () {
    test('reads and parses the asset', () async {
      final m = await AppContextKit.loadManifest('app.json', bundle: MapBundle({'app.json': goodManifest}));
      expect(m.id, 'dev.test.demo');
      expect(m.name, 'Demo');
    });

    test('a missing asset says to declare it in the pubspec', () async {
      final e = await AppContextKit.loadManifest('app.json', bundle: MapBundle({})).then<AppContextKitStartupError?>((_) => null, onError: (Object e) => e as AppContextKitStartupError);
      expect(e!.code, 'manifest-asset-missing');
      expect(e.hint, contains('assets'));
    });

    test('bad JSON and a bad id come back as the manifest codes', () async {
      Future<String> codeOf(String text) => AppContextKit.loadManifest('app.json', bundle: MapBundle({'app.json': text}))
          .then((_) => 'ok', onError: (Object e) => (e as AppContextKitStartupError).code);
      expect(await codeOf('{nope'), 'not-json');
      expect(await codeOf('[]'), 'not-object');
      expect(await codeOf('{"id":"Bad","name":"x","version":"1.0.0"}'), 'bad-id');
      expect(await codeOf('{"id":"a.b","name":"x","version":"1"}'), 'bad-version');
    });
  });

  group('openContext', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-open-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('Venue mode on with no token is a venue-required startup error', () async {
      final bundle = MapBundle({'app.json': '{"id":"dev.test.need","name":"Need","version":"0.1.0","venue":{"mode":"on"}}'});
      final e = await AppContextKit.openContext(manifestAsset: 'app.json', bundle: bundle, env: {'APP_CONTEXT_SCRATCH': tmp.path, 'HOME': tmp.path}, announce: false)
          .then<AppContextKitStartupError?>((_) => null, onError: (Object e) => e as AppContextKitStartupError);
      expect(e, isNotNull);
      expect(e!.code, 'venue-required');
      expect(e.message, contains('no token'));
    });

    test('a bad mode in the environment is a bad-mode startup error', () async {
      final e = await AppContextKit.openContext(
              manifestAsset: 'app.json',
              bundle: MapBundle({'app.json': goodManifest}),
              env: {'APP_CONTEXT_SCRATCH': tmp.path, 'HOME': tmp.path, 'APP_CONTEXT_MODE': 'fast'},
              announce: false)
          .then<AppContextKitStartupError?>((_) => null, onError: (Object e) => e as AppContextKitStartupError);
      expect(e!.code, 'bad-mode');
    });

    test('opens a context in mock mode', () async {
      final ctx = await AppContextKit.openContext(
          manifestAsset: 'app.json',
          bundle: MapBundle({'app.json': goodManifest}),
          env: {'APP_CONTEXT_SCRATCH': tmp.path, 'HOME': tmp.path, 'APP_CONTEXT_MODE': 'mock'},
          announce: false);
      expect(ctx.isMock, isTrue);
      await ctx.close();
    });
  });

  group('AppContextKit.run', () {
    Map<String, String> env(Directory d) => {'APP_CONTEXT_SCRATCH': d.path, 'HOME': d.path, 'APP_CONTEXT_MODE': 'mock'};

    Future<(AppContextKitSession, List<int>, List<String>)> start(
      WidgetTester t,
      Directory tmp, {
      String manifest = goodManifest,
      Widget Function(AppContext)? app,
      bool announce = false,
      Map<String, String>? environment,
    }) async {
      final exits = <int>[];
      final reports = <String>[];
      final session = (await t.runAsync(() => AppContextKit.run(
            manifestAsset: 'app.json',
            bundle: MapBundle({'app.json': manifest}),
            env: environment ?? env(tmp),
            announce: announce,
            handleSignals: false,
            exitProcess: exits.add,
            report: reports.add,
            app: app ?? (ctx) => const MaterialApp(home: Scaffold(body: Text('the app'))),
          )))!;
      addTearDown(session.dispose);
      await t.pump();
      return (session, exits, reports);
    }

    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-run-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    testWidgets('mounts the app under the scope', (t) async {
      AppContext? seen;
      final (session, _, _) = await start(t, tmp, app: (ctx) => MaterialApp(home: Builder(builder: (c) {
            seen = AppContextScope.of(c);
            return const Text('the app');
          })));
      expect(find.text('the app'), findsOneWidget);
      expect(session.error, isNull);
      expect(identical(seen, session.ctx), isTrue);
    });

    testWidgets('a window close (the lifecycle exit request) closes once, answers exit, withdraws the roster entry', (t) async {
      final (session, exits, reports) = await start(t, tmp, announce: true);
      final roster = Directory(session.ctx!.resolved.roster);
      expect(roster.listSync(), hasLength(1));
      var hooks = 0;
      session.ctx!.onClose(() => hooks++);

      final response = await t.runAsync(() => t.binding.handleRequestAppExit());
      expect(response, AppExitResponse.exit);
      expect(hooks, 1);
      expect(roster.listSync(), isEmpty);

      await t.runAsync(() => t.binding.handleRequestAppExit());
      expect(hooks, 1, reason: 'asking again does not close again');
      expect(session.exit!.closeCalls, 1);
      expect(exits, isEmpty, reason: 'the lifecycle path lets the engine end the process');
      expect(reports, isEmpty);
    });

    testWidgets('a failing onClose hook is reported to the report sink, not thrown, and exit still goes ahead', (t) async {
      final (session, _, reports) = await start(t, tmp);
      session.ctx!.onClose(() => throw StateError('save failed'));
      final response = await t.runAsync(() => t.binding.handleRequestAppExit());
      expect(response, AppExitResponse.exit);
      expect(reports.single, contains('save failed'));
    });

    testWidgets('AppContextKit.quit closes then ends the process with 0', (t) async {
      final (session, exits, _) = await start(t, tmp);
      var hooks = 0;
      session.ctx!.onClose(() => hooks++);
      await t.runAsync(AppContextKit.quit);
      expect(hooks, 1);
      expect(exits, [0]);
    });

    testWidgets('a bad manifest shows the error screen with the code instead of crashing', (t) async {
      final (session, _, _) = await start(t, tmp, manifest: '{"id":"nope","name":"x","version":"1.0.0"}');
      expect(session.ctx, isNull);
      expect(session.error!.code, 'bad-id');
      expect(find.text('Error code: bad-id'), findsOneWidget);
      expect(find.text('This app could not start'), findsOneWidget);
    });

    testWidgets('Venue mode on with no token shows venue-required', (t) async {
      final (session, _, _) = await start(t, tmp,
          manifest: '{"id":"dev.test.need","name":"Need","version":"0.1.0","venue":{"mode":"on"}}',
          environment: {'APP_CONTEXT_SCRATCH': tmp.path, 'HOME': tmp.path});
      expect(session.error!.code, 'venue-required');
      expect(find.text('Error code: venue-required'), findsOneWidget);
      expect(find.textContaining('no token'), findsWidgets);
    });

    testWidgets('an app builder that throws shows app-build-failed and withdraws the roster entry', (t) async {
      final (session, _, _) = await start(t, tmp, announce: true, app: (ctx) => throw StateError('bad build'));
      expect(session.error!.code, 'app-build-failed');
      expect(find.text('Error code: app-build-failed'), findsOneWidget);
      // the roster directory is resolved by the Kit; look for any announced file (ID@INSTANCE.json) anywhere under scratch
      final leftovers = tmp.listSync(recursive: true).whereType<File>().where((f) => f.path.contains('@') && f.path.endsWith('.json'));
      expect(leftovers, isEmpty);
    });
  });

  group('the pieces together', () {
    testWidgets('AppContextKit.buildRoot with the test helper is what AppContextKit.run mounts', (t) async {
      final kit = await pumpKitApp(t,
          manifest: goodManifest,
          app: (ctx) => MaterialApp(
                home: Scaffold(
                  body: Column(children: [
                    ModeBadge.forContext(ctx),
                    NotesBanner.forContext(ctx),
                    Builder(builder: (c) => Text('id ${AppContextScope.of(c).manifest.id}')),
                  ]),
                ),
              ));
      expect(find.text('id dev.test.demo'), findsOneWidget);
      expect(find.text('mock + scratch'), findsOneWidget);
      // mock mode's only note is the info line about the fake Venue, which the banner hides
      expect(kit.ctx.notes.map((n) => n.severity), [NoteSeverity.info]);
      expect(t.getSize(find.byType(NotesBanner)), Size.zero);
    });

    testWidgets('a damaged config.json becomes a warning the banner shows', (t) async {
      final dir = Directory.systemTemp.createTempSync('app-context-damaged-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final probe = await testAppContext(t, manifest: goodManifest, scratch: dir);
      File('${probe.ctx.dirs.config}/config.json').writeAsStringSync('{ not json');
      await probe.close();
      final kit = await testAppContext(t, manifest: goodManifest, scratch: dir);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: NotesBanner.forContext(kit.ctx))));
      expect(find.textContaining('Settings:', findRichText: true), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });
  });
}
