// Spec section 5 item 5: roster instance ids, withdraw removes only your own file, scan() shows every entry.
import 'dart:convert';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Roster roster;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app-context-roster-');
    roster = Roster(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String entryJson({required String id, String? instance, DateTime? heartbeat, String name = 'N'}) => jsonEncode({
        'id': id,
        if (instance != null) 'instance': instance,
        'name': name,
        'version': '0.1.0',
        'pid': 1,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'heartbeatAt': (heartbeat ?? DateTime.now()).toUtc().toIso8601String(),
      });

  test('newInstanceId is 8 lowercase hex digits and varies', () {
    final ids = {for (var i = 0; i < 50; i++) newInstanceId()};
    expect(ids.length, greaterThan(40));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[0-9a-f]{8}$')));
    }
  });

  test('announce writes <ID>@<INSTANCE>.json with an instance field', () async {
    final a = await roster.announce(id: 'com.slashbuilder.demo.calc', name: 'Calc', version: '0.1.0');
    expect(a.instance, matches(RegExp(r'^[0-9a-f]{8}$')));
    final f = File('${tmp.path}/com.slashbuilder.demo.calc@${a.instance}.json');
    expect(f.existsSync(), isTrue);
    expect(a.path, f.path);
    final j = jsonDecode(f.readAsStringSync()) as Map;
    expect(j['instance'], a.instance);
    expect(j['id'], 'com.slashbuilder.demo.calc');
    expect(roster.running().single.instance, a.instance);
    a.withdraw();
  });

  test('two copies of one app are two entries; withdrawing one leaves the other', () async {
    final a = await roster.announce(id: 'com.slashbuilder.demo.calc', name: 'Calc', version: '0.1.0', instance: 'aaaaaaaa');
    final b = await roster.announce(id: 'com.slashbuilder.demo.calc', name: 'Calc', version: '0.1.0', instance: 'bbbbbbbb');
    expect(roster.running().map((e) => e.instance), ['aaaaaaaa', 'bbbbbbbb']);
    a.withdraw();
    expect(roster.running().map((e) => e.instance), ['bbbbbbbb'], reason: 'the survivor is not erased');
    expect(File('${tmp.path}/com.slashbuilder.demo.calc@aaaaaaaa.json').existsSync(), isFalse);
    b.withdraw();
    expect(roster.scan(), isEmpty);
  });

  test('withdraw touches only its own file, even next to a legacy <ID>.json and another app', () async {
    File('${tmp.path}/com.slashbuilder.demo.calc.json').writeAsStringSync(entryJson(id: 'com.slashbuilder.demo.calc'));
    File('${tmp.path}/com.slashbuilder.demo.other@cccccccc.json').writeAsStringSync(entryJson(id: 'com.slashbuilder.demo.other', instance: 'cccccccc'));
    final a = await roster.announce(id: 'com.slashbuilder.demo.calc', name: 'Calc', version: '0.1.0', instance: 'aaaaaaaa');
    a.withdraw();
    final names = tmp.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();
    expect(names, ['com.slashbuilder.demo.calc.json', 'com.slashbuilder.demo.other@cccccccc.json']);
  });

  test('AppContext gives each opened context its own instance and file', () async {
    final m = AppManifest.fromJson({'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0'});
    final env = {'APP_CONTEXT_SCRATCH': tmp.path};
    final one = await AppContext.open(m, env: env, platform: 'linux', home: '/x');
    final two = await AppContext.open(m, env: env, platform: 'linux', home: '/x');
    expect(one.instance, isNot(two.instance));
    expect(one.roster.running().map((e) => e.instance).toSet(), {one.instance, two.instance});
    await one.close();
    expect(two.roster.running().single.instance, two.instance);
    await two.close();
    expect(two.roster.scan(), isEmpty);
  });

  group('scan', () {
    test('returns every entry with live / stale / unreadable, and running() keeps meaning "live only"', () {
      final now = DateTime.now().toUtc();
      File('${tmp.path}/com.slashbuilder.demo.live@11111111.json')
          .writeAsStringSync(entryJson(id: 'com.slashbuilder.demo.live', instance: '11111111', heartbeat: now));
      File('${tmp.path}/com.slashbuilder.demo.crashed@22222222.json')
          .writeAsStringSync(entryJson(id: 'com.slashbuilder.demo.crashed', instance: '22222222', heartbeat: now.subtract(const Duration(minutes: 5))));
      File('${tmp.path}/com.slashbuilder.demo.broken@33333333.json').writeAsStringSync('{not json');
      File('${tmp.path}/com.slashbuilder.demo.partial@44444444.json').writeAsStringSync('{"id":"com.slashbuilder.demo.partial"}');
      File('${tmp.path}/notes.txt').writeAsStringSync('not a presence file');
      File('${tmp.path}/com.slashbuilder.demo.live@11111111.json.tmp').writeAsStringSync('half-written');

      final recs = roster.scan(now: now);
      expect(recs.map((r) => (r.id, r.instance, r.status)), [
        ('com.slashbuilder.demo.broken', '33333333', RosterStatus.unreadable),
        ('com.slashbuilder.demo.crashed', '22222222', RosterStatus.stale),
        ('com.slashbuilder.demo.live', '11111111', RosterStatus.live),
        ('com.slashbuilder.demo.partial', '44444444', RosterStatus.unreadable),
      ]);
      expect(recs.firstWhere((r) => r.status == RosterStatus.live).entry, isNotNull);
      expect(recs.firstWhere((r) => r.status == RosterStatus.unreadable).entry, isNull);
      expect(recs.first.file, 'com.slashbuilder.demo.broken@33333333.json');

      expect(roster.running(now: now).map((e) => e.id), ['com.slashbuilder.demo.live']);
    });

    test('file names with dots and hyphens in the id are parsed at the last @ and the final .json', () {
      File('${tmp.path}/com.example.my-app.v2@deadbeef.json').writeAsStringSync('garbage');
      final r = roster.scan().single;
      expect(r.status, RosterStatus.unreadable);
      expect(r.id, 'com.example.my-app.v2');
      expect(r.instance, 'deadbeef');
    });

    test('a readable file takes id and instance from its content, not its name', () {
      File('${tmp.path}/whatever.json').writeAsStringSync(entryJson(id: 'com.slashbuilder.demo.calc', instance: '12345678'));
      final r = roster.scan().single;
      expect((r.id, r.instance, r.status), ('com.slashbuilder.demo.calc', '12345678', RosterStatus.live));
    });

    test('a legacy <ID>.json without an instance is still listed (instance null)', () {
      File('${tmp.path}/com.slashbuilder.demo.calc.json').writeAsStringSync(entryJson(id: 'com.slashbuilder.demo.calc'));
      final r = roster.scan().single;
      expect((r.id, r.instance, r.status), ('com.slashbuilder.demo.calc', null, RosterStatus.live));
    });

    test('a missing directory scans as empty', () {
      expect(Roster('${tmp.path}/nope').scan(), isEmpty);
      expect(Roster('${tmp.path}/nope').running(), isEmpty);
    });
  });

  group('parseRosterFileName', () {
    test('splits id and instance', () {
      expect(parseRosterFileName('com.slashbuilder.demo.calc@0a1b2c3d.json'), (id: 'com.slashbuilder.demo.calc', instance: '0a1b2c3d'));
    });
    test('treats anything without a valid 8-hex instance as an id only', () {
      expect(parseRosterFileName('com.slashbuilder.demo.calc.json'), (id: 'com.slashbuilder.demo.calc', instance: null));
      expect(parseRosterFileName('com.slashbuilder.demo.calc@xyz.json'), (id: 'com.slashbuilder.demo.calc@xyz', instance: null));
      expect(parseRosterFileName('com.slashbuilder.demo.calc@0A1B2C3D.json'), (id: 'com.slashbuilder.demo.calc@0A1B2C3D', instance: null));
      expect(parseRosterFileName('@0a1b2c3d.json'), (id: '@0a1b2c3d', instance: null));
    });
  });
}
