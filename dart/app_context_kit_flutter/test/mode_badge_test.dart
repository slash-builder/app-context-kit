import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:app_context_kit_flutter/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _manifest = '{"id":"dev.test.badge","name":"Badge","version":"0.0.1"}';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('real and unscratched shows nothing at all', (t) async {
    await t.pumpWidget(_host(const ModeBadge(isMock: false, scratch: false)));
    expect(find.byType(Chip), findsNothing);
    expect(t.getSize(find.byType(ModeBadge)), Size.zero);
  });

  for (final (mock, scratch, label) in [
    (true, false, 'mock'),
    (false, true, 'scratch'),
    (true, true, 'mock + scratch'),
  ]) {
    testWidgets('isMock=$mock scratch=$scratch shows "$label"', (t) async {
      final handle = t.ensureSemantics();
      await t.pumpWidget(_host(ModeBadge(isMock: mock, scratch: scratch)));
      expect(find.text(label), findsOneWidget);
      expect(find.byType(Chip), findsOneWidget);
      // not colour alone: the words are the signal, and a screen reader gets a sentence
      expect(find.bySemanticsLabel('Running in $label mode'), findsOneWidget);
      handle.dispose();
    });
  }

  test('labelFor is null only when there is nothing to say', () {
    expect(ModeBadge.labelFor(isMock: false, scratch: false), isNull);
    expect(ModeBadge.labelFor(isMock: true, scratch: true), 'mock + scratch');
  });

  testWidgets('forContext reads the context: the test helper gives mock + scratch', (t) async {
    final kit = await testAppContext(t, manifest: _manifest);
    await t.pumpWidget(_host(ModeBadge.forContext(kit.ctx)));
    expect(find.text('mock + scratch'), findsOneWidget);
  });

  testWidgets('forContext with a real, unscratched context shows nothing', (t) async {
    // Real mode, no scratch: the home is a temp dir so nothing touches the developer's folders.
    final kit = await testAppContext(t, manifest: _manifest, platform: 'linux', env: {
      'APP_CONTEXT_MODE': 'real',
      'APP_CONTEXT_SCRATCH': '',
      'XDG_DATA_HOME': '', // empty means unset; HOME (the scratch dir) is the base
    });
    expect(kit.ctx.isMock, isFalse);
    expect(kit.ctx.scratch, isFalse);
    await t.pumpWidget(_host(ModeBadge.forContext(kit.ctx)));
    expect(find.byType(Chip), findsNothing);
  });
}
