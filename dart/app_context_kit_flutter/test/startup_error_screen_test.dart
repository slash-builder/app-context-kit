import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the code, what happened and what to do', (t) async {
    const err = AppContextKitStartupError(code: 'bad-id', message: 'The manifest is wrong.', hint: 'Fix app.json.');
    await t.pumpWidget(const StartupErrorScreen(error: err));
    expect(find.text('This app could not start'), findsOneWidget);
    expect(find.text('The manifest is wrong.'), findsOneWidget);
    expect(find.text('Fix app.json.'), findsOneWidget);
    expect(find.text('Error code: bad-id'), findsOneWidget);
  });

  testWidgets('has semantics for the code and a header', (t) async {
    final h = t.ensureSemantics();
    const err = AppContextKitStartupError(code: 'venue-required', message: 'm', hint: 'h');
    await t.pumpWidget(const StartupErrorScreen(error: err, title: 'Cannot start Foo'));
    expect(find.bySemanticsLabel('Error code venue-required'), findsOneWidget);
    expect(find.text('Cannot start Foo'), findsOneWidget);
    h.dispose();
  });

  group('AppContextKitStartupError.from', () {
    test('every manifest code is passed through with a plain reason', () {
      for (final code in ['not-json', 'not-object', 'bad-id', 'bad-name', 'bad-version', 'bad-kits', 'duplicate-kit', 'bad-prefix', 'bad-venue']) {
        final e = AppContextKitStartupError.from(ManifestError(code), manifestAsset: 'app.json');
        expect(e.code, code);
        expect(e.message, isNot(contains('refused with code')), reason: '$code has a specific message');
        expect(e.hint, contains('app.json'));
      }
    });

    test('resolve errors, a required Venue and other failures', () {
      expect(AppContextKitStartupError.from(ResolveError('bad-mode')).code, 'bad-mode');
      expect(AppContextKitStartupError.from(ResolveError('missing-env')).code, 'missing-env');
      final v = AppContextKitStartupError.from(VenueUnavailable('Venue is required but no token was found'));
      expect(v.code, 'venue-required');
      expect(v.message, 'Venue is required but no token was found');
      expect(v.hint, contains('VENUE_TOKEN'));
      expect(AppContextKitStartupError.from(StateError('x')).code, 'open-failed');
    });

    test('an AppContextKitStartupError is returned as it is', () {
      const e = AppContextKitStartupError(code: 'x', message: 'm', hint: 'h');
      expect(identical(AppContextKitStartupError.from(e), e), isTrue);
    });
  });
}
