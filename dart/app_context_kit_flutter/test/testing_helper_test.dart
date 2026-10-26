import 'dart:convert';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:app_context_kit_flutter/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A tiny app that keeps a counter in settings and saves it on close, like the demo apps do.
class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  late AppContext ctx;
  int n = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ctx = AppContextScope.of(context);
    n = ctx.config.get<int>('n', 0);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Column(children: [
            ModeBadge.forContext(ctx),
            Text('count $n'),
            TextButton(onPressed: () => setState(() => n++), child: const Text('inc')),
          ]),
        ),
      );
}

void main() {
  String? firstScratch;

  group('testAppContext', () {
    testWidgets('opens in mock mode inside a temp scratch dir, with no roster entry', (t) async {
      final kit = await testAppContext(t, manifest: goodManifest);
      firstScratch = kit.scratch.path;
      expect(kit.ctx.isMock, isTrue);
      expect(kit.ctx.scratch, isTrue);
      expect(kit.ctx.dirs.data, startsWith(kit.scratch.path));
      expect(kit.ctx.dirs.config, startsWith(kit.scratch.path));
      expect(Directory(kit.ctx.resolved.roster).existsSync() && Directory(kit.ctx.resolved.roster).listSync().isNotEmpty, isFalse,
          reason: 'announce defaults to false');
      expect(kit.ctx.venue.kind, 'fake');
    });

    testWidgets('the scratch directory from the previous test is gone', (t) async {
      expect(firstScratch, isNotNull);
      expect(Directory(firstScratch!).existsSync(), isFalse);
    });

    testWidgets('the host environment is not consulted', (t) async {
      // APP_CONTEXT_MODE=real in the caller's own map wins, but nothing from Platform.environment does: with no env the mode is mock.
      final kit = await testAppContext(t, manifest: goodManifest);
      expect(kit.env.keys, containsAll(['APP_CONTEXT_SCRATCH', 'APP_CONTEXT_MODE', 'HOME']));
      expect(kit.env['APP_CONTEXT_MODE'], 'mock');
    });

    testWidgets('accepts an AppManifest, JSON text or a map', (t) async {
      final a = await testAppContext(t, manifest: AppManifest.parse(goodManifest));
      final b = await testAppContext(t, manifest: goodManifest);
      final c = await testAppContext(t, manifest: jsonDecode(goodManifest) as Map);
      expect([a.ctx.manifest.id, b.ctx.manifest.id, c.ctx.manifest.id], everyElement('dev.test.demo'));
      expect(() => testAppContext(t, manifest: 42), throwsArgumentError);
    });

    testWidgets('close runs the onClose hooks once; reopen gives a new context on the same files', (t) async {
      final kit = await testAppContext(t, manifest: goodManifest);
      var ran = 0;
      kit.ctx.onClose(() => ran++);
      kit.ctx.config.set('k', 'v');
      final first = kit.ctx;
      await kit.close();
      await kit.close();
      expect(ran, 1);
      final second = await kit.reopen();
      expect(identical(first, second), isFalse);
      expect(second.config.get<String>('k', ''), 'v');
      expect(second.dirs.data, first.dirs.data);
      expect(ran, 1, reason: 'the old context does not close again');
    });

    testWidgets('announce: true announces and a close withdraws the roster entry', (t) async {
      final kit = await testAppContext(t, manifest: goodManifest, announce: true);
      final roster = Directory(kit.ctx.resolved.roster);
      expect(roster.listSync(), hasLength(1));
      await kit.close();
      expect(roster.listSync(), isEmpty);
    });

    testWidgets('a caller-supplied scratch directory is reused and not deleted', (t) async {
      final mine = Directory.systemTemp.createTempSync('mine-');
      addTearDown(() => mine.deleteSync(recursive: true));
      final kit = await testAppContext(t, manifest: goodManifest, scratch: mine);
      expect(kit.scratch.path, mine.path);
      expect(kit.ctx.dirs.data, startsWith(mine.path));
    });
  });

  group('pumpKitApp', () {
    testWidgets('mounts the app under the scope; relaunch keeps the settings', (t) async {
      final kit = await pumpKitApp(t, manifest: goodManifest, app: (ctx) => const _Counter());
      expect(find.text('count 0'), findsOneWidget);
      expect(find.text('mock + scratch'), findsOneWidget);
      await t.tap(find.text('inc'));
      await t.pump();
      expect(find.text('count 1'), findsOneWidget);
      // the app saves on close
      kit.ctx.onClose(() => kit.ctx.config.set('n', 1));

      final before = kit.ctx;
      await kit.relaunch();
      expect(identical(before, kit.ctx), isFalse);
      expect(find.text('count 1'), findsOneWidget, reason: 'the second launch read what the first saved');
    });

    testWidgets('quit closes the context while the widgets are still mounted, then unmounts', (t) async {
      final kit = await pumpKitApp(t, manifest: goodManifest, app: (ctx) => const _Counter());
      var mountedAtClose = false;
      kit.ctx.onClose(() => mountedAtClose = find.byType(_Counter).evaluate().isNotEmpty);
      await kit.quit();
      expect(mountedAtClose, isTrue);
      expect(find.byType(_Counter), findsNothing);
    });

    testWidgets('settle: true waits for animations', (t) async {
      await pumpKitApp(t, manifest: goodManifest, app: (ctx) => const _Counter(), settle: true);
      expect(find.text('count 0'), findsOneWidget);
    });
  });
}
