import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _info = AppNote(NoteSeverity.info, 'Venue is off for this app');
const _warn = AppNote(NoteSeverity.warning, 'Settings: damaged.');
const _err = AppNote(NoteSeverity.error, 'Closing failed: boom');

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('hides info notes by default and shows warnings and errors', (t) async {
    await t.pumpWidget(_host(const NotesBanner(notes: [_info, _warn, _err])));
    expect(find.textContaining('Venue is off', findRichText: true), findsNothing);
    expect(find.textContaining('Settings: damaged.', findRichText: true), findsOneWidget);
    expect(find.textContaining('Closing failed: boom', findRichText: true), findsOneWidget);
  });

  testWidgets('with only info notes it takes no space', (t) async {
    await t.pumpWidget(_host(const Column(children: [NotesBanner(notes: [_info]), Text('below')])));
    expect(t.getSize(find.byType(NotesBanner)), Size.zero);
    expect(find.text('below'), findsOneWidget);
  });

  testWidgets('showInfo shows the info note too', (t) async {
    await t.pumpWidget(_host(const NotesBanner(notes: [_info, _warn], showInfo: true)));
    expect(find.textContaining('Venue is off', findRichText: true), findsOneWidget);
  });

  testWidgets('severities differ by icon, visible word and background, not colour alone', (t) async {
    await t.pumpWidget(_host(const NotesBanner(notes: [_info, _warn, _err], showInfo: true)));
    expect(find.text('Note: Venue is off for this app', findRichText: true), findsOneWidget);
    expect(find.text('Warning: Settings: damaged.', findRichText: true), findsOneWidget);
    expect(find.text('Error: Closing failed: boom', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.error), findsOneWidget);
    final colours = {
      for (final c in t.widgetList<Container>(find.descendant(of: find.byType(NotesBanner), matching: find.byType(Container)))) c.color,
    };
    expect(colours.length, 3, reason: 'three severities, three different backgrounds');
  });

  testWidgets('semantics: one labelled node per note, errors and warnings are live regions', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(_host(const NotesBanner(notes: [_info, _warn, _err], showInfo: true)));
    expect(find.bySemanticsLabel('Warning: Settings: damaged.'), findsOneWidget);
    expect(find.bySemanticsLabel('Error: Closing failed: boom'), findsOneWidget);
    expect(find.bySemanticsLabel('Note: Venue is off for this app'), findsOneWidget);
    expect(t.getSemantics(find.bySemanticsLabel('Error: Closing failed: boom')).flagsCollection.isLiveRegion, isTrue);
    expect(t.getSemantics(find.bySemanticsLabel('Note: Venue is off for this app')).flagsCollection.isLiveRegion, isFalse);
    h.dispose();
  });

  testWidgets('not dismissible by default: no close button', (t) async {
    await t.pumpWidget(_host(const NotesBanner(notes: [_warn])));
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('dismissible: tapping close hides that note only and reports it', (t) async {
    final dismissed = <AppNote>[];
    await t.pumpWidget(_host(NotesBanner(notes: const [_warn, _err], dismissible: true, onDismissed: dismissed.add)));
    expect(find.byIcon(Icons.close), findsNWidgets(2));
    expect(find.byTooltip('Dismiss Warning'), findsOneWidget);
    await t.tap(find.byTooltip('Dismiss Warning'));
    await t.pump();
    expect(find.textContaining('Settings: damaged.', findRichText: true), findsNothing);
    expect(find.textContaining('Closing failed', findRichText: true), findsOneWidget);
    expect(dismissed, [_warn]);
  });

  testWidgets('reads a live list: a note added after the first build shows on the next build', (t) async {
    final notes = <AppNote>[_info];
    late StateSetter set;
    await t.pumpWidget(_host(StatefulBuilder(builder: (c, s) {
      set = s;
      return NotesBanner(notes: notes);
    })));
    expect(find.byIcon(Icons.error), findsNothing);
    set(() => notes.add(_err));
    await t.pump();
    expect(find.byIcon(Icons.error), findsOneWidget);
  });

  test('visibleOf filters by severity', () {
    expect(NotesBanner.visibleOf(const [_info, _warn, _err]), [_warn, _err]);
    expect(NotesBanner.visibleOf(const [_info, _warn, _err], showInfo: true), [_info, _warn, _err]);
  });
}
