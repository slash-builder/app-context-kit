// Can the one hook shape express a signal, a sync and a handoff, without the
// hub knowing which is which? These tests are the evidence.
import 'dart:typed_data';

import 'package:app_context_kit/src/peers/peers.dart';
import 'package:test/test.dart';

import 'sample_hooks.dart';
import 'support.dart';

/// A hub whose hook is any [AppCoordination] (not the recording one).
PeerHub hubFor(World w, String device, AppCoordination hook, {String instance = 'i1'}) => PeerHub(
      account: 'acct-1',
      app: 'com.slashbuilder.demo.app',
      device: device,
      instance: instance,
      provider: w.network.provider(),
      hook: hook,
      clock: w.clock,
    );

void main() {
  late World w;
  final hubs = <PeerHub>[];
  setUp(() => w = World());
  tearDown(() async {
    for (final h in hubs) {
      await h.close();
    }
    hubs.clear();
  });

  Future<PeerHub> up(String device, AppCoordination hook) async {
    final h = hubFor(w, device, hook);
    hubs.add(h);
    await h.start();
    await w.settle();
    return h;
  }

  group('live signal', () {
    test('a finished timer reaches every other copy; a late joiner learns it from hello, not a replay', () async {
      final got = <String, List<String>>{'b': [], 'c': []};
      final a = TimerSignalHook();
      await up('a', a);
      await up('b', TimerSignalHook(onFinished: (label, from) => got['b']!.add('$label from ${from.device}')));
      await up('c', TimerSignalHook(onFinished: (label, from) => got['c']!.add('$label from ${from.device}')));

      a.finish('tea');
      await w.settle();
      expect(got, {'b': ['tea from a'], 'c': ['tea from a']});

      final late = TimerSignalHook(onFinished: (l, f) => got.putIfAbsent('d', () => []).add(l));
      final dHub = await up('d', late);
      await w.settle();
      expect(got.containsKey('d'), isFalse, reason: 'best effort: nothing is replayed');
      expect(late.lastFinishedOf(dHub.peers.firstWhere((p) => p.id.device == 'a')), 'tea');
    });
  });

  group('sync (merge rule defined by the app)', () {
    test('edits propagate and converge; a partition heals by the newer side pushing; ties break by the app rule', () async {
      final notes = {for (final d in ['a', 'b', 'c']) d: NoteSyncHook(d)};
      final hubs3 = {for (final d in ['a', 'b', 'c']) d: await up(d, notes[d]!)};
      String view() => notes.values.map((n) => n.note.text).join('|');

      notes['a']!.edit('A1', 100);
      await w.settle();
      expect(view(), 'A1|A1|A1');

      // c is cut off; both sides keep editing; c's edit is older than b's.
      w.network.isolate(hubs3['c']!.id);
      await w.settle();
      notes['b']!.edit('B2', 200);
      notes['c']!.edit('C-old', 150);
      await w.settle();
      expect(view(), 'B2|B2|C-old');

      w.network.heal(hubs3['c']!.id);
      await w.settle();
      expect(view(), 'B2|B2|B2', reason: 'c is behind, so a/b push; c is not newer, so it pushes nothing');

      // A tie on the stamp: the app's rule (higher writer id) decides, on every copy.
      notes['a']!.edit('tie-from-a', 300);
      notes['c']!.edit('tie-from-c', 300);
      await w.settle();
      expect(view(), 'tie-from-c|tie-from-c|tie-from-c');

      // A stale stamp (say, a device with a slow clock) never wins, even for its own author.
      notes['b']!.edit('stale', 10);
      await w.settle();
      expect(view(), 'tie-from-c|tie-from-c|tie-from-c');
    });

    test('the app\'s schema number is its own: an unknown schema is ignored, the hub does not care', () async {
      final a = NoteSyncHook('a');
      final b = NoteSyncHook('b');
      final ha = await up('a', a);
      await up('b', b);
      await ha.broadcast(Uint8List(0), kind: 'note.changed', schema: 2);
      await w.settle();
      expect(b.note.text, '');
    });
  });

  group('handoff', () {
    test('"send me your current game state": request/reply, then the source stands down', () async {
      final a = GameHandoffHook()..game = {'moves': 42, 'board': 'x.o.x'};
      final b = GameHandoffHook();
      await up('a', a);
      final hb = await up('b', b);
      expect(hb.peers.single.hello, {'proto': 3, 'moves': 42, 'inProgress': true});

      await b.pullFrom(hb.peers.single);
      await w.settle();
      expect(b.game, {'moves': 42, 'board': 'x.o.x'});
      expect(a.released, isTrue);
    });

    test('the app\'s own admit policy keeps an incompatible copy out', () async {
      final a = GameHandoffHook(proto: 3);
      final old = GameHandoffHook(proto: 2);
      final ha = await up('a', a);
      await up('b', old);
      expect(ha.peers, isEmpty);
      expect(ha.stats.hookErrors, 0);
    });

    test('a copy that never answers times out with a typed error', () async {
      final a = GameHandoffHook()..released = true; // will not reply
      final b = GameHandoffHook();
      await up('a', a);
      final hb = await up('b', b);
      final f = b.pullFrom(hb.peers.single, timeout: const Duration(seconds: 1));
      final check = expectLater(f, throwsA(isA<PeerTimeout>()));
      await w.advance(const Duration(seconds: 1));
      await check;
    });
  });

  group('all three on ONE hub (the app muxes)', () {
    test('a signal, a sync and a handoff share one hub and one set of peers', () async {
      final finished = <String>[];
      Map<String, AppCoordination> facets(String d) => {
            'timer': TimerSignalHook(facet: 'timer', onFinished: (l, f) => finished.add('$d:$l')),
            'note': NoteSyncHook(d, facet: 'note'),
            'game': GameHandoffHook(facet: 'game'),
          };
      final fa = facets('a');
      final fb = facets('b');
      await up('a', MuxHook('everything', fa));
      final hb = await up('b', MuxHook('everything', fb));

      (fa['timer'] as TimerSignalHook).finish('eggs');
      (fa['note'] as NoteSyncHook).edit('hello', 5);
      (fa['game'] as GameHandoffHook).game = {'moves': 7};
      await w.settle();
      expect(finished, ['b:eggs']);
      expect((fb['note'] as NoteSyncHook).note.text, 'hello');
      await (fb['game'] as GameHandoffHook).pullFrom(hb.peers.single);
      expect((fb['game'] as GameHandoffHook).game, {'moves': 7});
    });

    test('FINDING: admit is per peer, so one facet\'s refusal costs the whole peer (notes stop syncing too)', () async {
      final fa = {'note': NoteSyncHook('a', facet: 'note'), 'game': GameHandoffHook(facet: 'game', proto: 3)};
      final fb = {'note': NoteSyncHook('b', facet: 'note'), 'game': GameHandoffHook(facet: 'game', proto: 2)};
      final ha = await up('a', MuxHook('everything', fa));
      await up('b', MuxHook('everything', fb));
      (fa['note'] as NoteSyncHook).edit('should sync', 5);
      await w.settle();
      expect(ha.peers, isEmpty);
      expect((fb['note'] as NoteSyncHook).note.text, '', reason: 'notes were fine; the game protocol mismatch blocked them');
    });
  });
}
