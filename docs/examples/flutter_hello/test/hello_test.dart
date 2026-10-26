import 'dart:io';

import 'package:app_context_kit_flutter/testing.dart';
import 'package:hello/hello_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('taps are saved and survive a quit and relaunch', (tester) async {
    final kit = await pumpKitApp(
      tester,
      manifest: File('app.json').readAsStringSync(),
      app: (ctx) => const HelloApp(),
    );
    expect(find.text('Taps: 0'), findsOneWidget);
    expect(find.text('mock + scratch'), findsOneWidget);

    await tester.tap(find.text('Tap'));
    await tester.pump();
    expect(find.text('Taps: 1'), findsOneWidget);
    expect(kit.ctx.dataFile('taps.log').readAsStringSync(), '1\n');

    await kit.relaunch(); // close, open again on the same scratch directory, mount again
    expect(find.text('Taps: 1'), findsOneWidget);
  });
}
