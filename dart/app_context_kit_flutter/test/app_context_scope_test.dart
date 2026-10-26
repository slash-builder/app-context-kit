import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:app_context_kit_flutter/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _manifest = '{"id":"dev.test.scope","name":"Scope","version":"0.0.1"}';

void main() {
  testWidgets('of() gives widgets below the scope the context', (t) async {
    final kit = await testAppContext(t, manifest: _manifest);
    AppContext? seen;
    await t.pumpWidget(AppContextScope(
      ctx: kit.ctx,
      child: Builder(builder: (c) {
        seen = AppContextScope.of(c);
        return const SizedBox();
      }),
    ));
    expect(identical(seen, kit.ctx), isTrue);
  });

  testWidgets('of() without a scope throws an error that says how to fix it', (t) async {
    await t.pumpWidget(Builder(builder: (c) {
      AppContextScope.of(c);
      return const SizedBox();
    }));
    final e = t.takeException();
    expect(e, isA<FlutterError>());
    expect(e.toString(), contains('AppContextKit.run'));
  });

  testWidgets('maybeOf() is null without a scope', (t) async {
    AppContext? seen;
    var asked = false;
    await t.pumpWidget(Builder(builder: (c) {
      asked = true;
      seen = AppContextScope.maybeOf(c);
      return const SizedBox();
    }));
    expect(asked, isTrue);
    expect(seen, isNull);
  });

  testWidgets('swapping in another context rebuilds dependents; the same context does not', (t) async {
    final a = await testAppContext(t, manifest: _manifest);
    final b = await testAppContext(t, manifest: _manifest);
    var builds = 0;
    final probe = Builder(builder: (c) {
      AppContextScope.of(c);
      builds++;
      return const SizedBox();
    });
    await t.pumpWidget(AppContextScope(ctx: a.ctx, child: probe));
    expect(builds, 1);
    await t.pumpWidget(AppContextScope(ctx: a.ctx, child: probe));
    expect(builds, 1, reason: 'same context, same child: nothing to rebuild');
    await t.pumpWidget(AppContextScope(ctx: b.ctx, child: probe));
    expect(builds, 2);
  });
}
