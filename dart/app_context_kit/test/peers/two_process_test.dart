// The peers code with a REAL process boundary: each PeerHub runs in its own OS process (test/peers/two_process_worker.dart,
// a plain `dart` VM started with the package config), over a LoopbackProvider sharing one temp directory. Everything else in
// test/peers/ runs in one process. The loopback test could not show what a dying process looks like to its neighbour;
// this one kills -9 it.
//
// The kill tests print their numbers (run with `dart test test/peers/two_process_test.dart -r expanded` to see them) and
// docs/PLATFORMS.md records them. APP_CONTEXT_GHOST_SECONDS (default 12) is how long the survivor is watched after the kill.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// One worker process and everything it has printed so far.
class Worker {
  Worker._(this.process, this.name);
  final Process process;
  final String name;
  final events = <Map<String, dynamic>>[];
  final stderrText = StringBuffer();
  late final int pid;
  final _waiters = <_Waiter>[];

  static Future<Worker> start(String name, Directory dir,
      {String account = 'acct', String app = 'com.slashbuilder.demo.two', String? device, String? instance}) async {
    final root = Directory.current.path; // `dart test` runs from the package root
    final p = await Process.start(Platform.resolvedExecutable, [
      '--packages=$root/.dart_tool/package_config.json',
      '$root/test/peers/two_process_worker.dart',
      dir.path,
      account,
      app,
      device ?? name,
      if (instance != null) instance,
    ]);
    final w = Worker._(p, name);
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final Map<String, dynamic> m;
      try {
        m = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        w.stderrText.writeln('stdout: $line');
        return;
      }
      w.events.add(m);
      for (final x in w._waiters.toList()) {
        if (x.test(m)) {
          w._waiters.remove(x);
          x.done.complete(m);
        }
      }
    });
    p.stderr.transform(utf8.decoder).listen(w.stderrText.write);
    final ready = await w.waitFor((e) => e['ev'] == 'ready', timeout: const Duration(seconds: 30));
    w.pid = ready['pid'] as int;
    return w;
  }

  /// The first event (already seen or still to come) that satisfies [test].
  Future<Map<String, dynamic>> waitFor(bool Function(Map<String, dynamic>) test,
      {Duration timeout = const Duration(seconds: 10), String? why}) {
    for (final e in events) {
      if (test(e)) return Future.value(e);
    }
    final w = _Waiter(test);
    _waiters.add(w);
    return w.done.future.timeout(timeout, onTimeout: () {
      _waiters.remove(w);
      throw TimeoutException(
          '$name: no event for ${why ?? 'condition'} within $timeout. Seen:\n${events.map(jsonEncode).join('\n')}\nstderr: $stderrText');
    });
  }

  Future<Map<String, dynamic>> peerEvent(String change, String device, {String? why}) =>
      waitFor((e) => e['ev'] == 'peer' && e['change'] == change && (e['peer'] as String).startsWith('$device@'),
          why: why ?? '$change $device');

  void command(Map<String, Object?> c) => process.stdin.writeln(jsonEncode(c));

  /// Sends a command and returns the next `result` event for it.
  Future<Map<String, dynamic>> ask(Map<String, Object?> c) {
    final before = events.length;
    final f = waitFor((e) => e['ev'] == 'result' && e['cmd'] == c['cmd'] && events.indexOf(e) >= before, why: 'result of ${c['cmd']}');
    command(c);
    return f;
  }

  List<Map<String, dynamic>> get peerEvents => [...events.where((e) => e['ev'] == 'peer')];

  void kill9() => Process.killPid(pid, ProcessSignal.sigkill);

  Future<void> dispose() async {
    process.kill(ProcessSignal.sigkill);
    Process.killPid(pid, ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  }
}

class _Waiter {
  _Waiter(this.test);
  final bool Function(Map<String, dynamic>) test;
  final done = Completer<Map<String, dynamic>>();
}

double _ms(int micros) => micros / 1000;
String _device(Object? peer) => (peer as String).split('@').first;

void main() {
  late Directory tmp;
  final workers = <Worker>[];
  Future<Worker> spawn(String name, {String account = 'acct', String app = 'com.slashbuilder.demo.two', String? device, String? instance}) async {
    final w = await Worker.start(name, tmp, account: account, app: app, device: device, instance: instance);
    workers.add(w);
    return w;
  }

  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-twoproc-'));
  tearDown(() async {
    for (final w in workers) {
      await w.dispose();
    }
    workers.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  List<File> announcements(String device) => Directory('${tmp.path}/acct/com.slashbuilder.demo.two')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.split('/').last.startsWith('$device@'))
      .toList();

  group('two real processes', () {
    test('find each other, hello/admit, send, broadcast and request/reply; a third process with another app id never sees them', () async {
      final a = await spawn('alpha');
      final b = await spawn('beta');
      final other = await spawn('gamma', app: 'com.slashbuilder.demo.other');
      final otherAccount = await spawn('delta', account: 'acct2');

      await a.peerEvent('ready', 'beta');
      await b.peerEvent('ready', 'alpha');
      expect(a.pid, isNot(b.pid));
      expect(a.pid, isNot(pid), reason: 'a separate OS process');

      // The worker's admit accepts everyone, so `ready` on both sides is the proof that hello and admit ran in both directions.
      final sent = await a.ask({'cmd': 'send', 'to': 'beta', 'text': 'one'});
      expect(sent['ok'], isTrue);
      final got = await b.waitFor((e) => e['ev'] == 'msg' && e['text'] == 'one');
      expect(_device(got['from']), 'alpha');
      expect(got['kind'], 'note');
      expect(got['rid'], isNull);

      final bc = await b.ask({'cmd': 'broadcast', 'text': 'to-all'});
      expect(bc['sent'], hasLength(1));
      await a.waitFor((e) => e['ev'] == 'msg' && e['text'] == 'to-all');

      b.command({'cmd': 'request', 'to': 'alpha', 'text': 'ping'});
      expect((await b.waitFor((e) => e['ev'] == 'reply'))['text'], 'echo:ping');
      a.command({'cmd': 'request', 'to': 'beta', 'text': 'pong'});
      expect((await a.waitFor((e) => e['ev'] == 'reply'))['text'], 'echo:pong');

      // Several poll cycles later nobody else has appeared, in either direction.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(other.peerEvents, isEmpty);
      expect(otherAccount.peerEvents, isEmpty);
      expect(other.events.where((e) => e['ev'] == 'msg'), isEmpty);
      expect(a.peerEvents.map((e) => '${e['change']} ${_device(e['peer'])}'), ['found beta', 'ready beta']);
      expect(b.peerEvents.map((e) => '${e['change']} ${_device(e['peer'])}'), ['found alpha', 'ready alpha']);
      expect((await a.ask({'cmd': 'peers'}))['peers'], hasLength(1));
      // The directory layout is the first fence: one directory per account and app.
      for (final d in ['acct/com.slashbuilder.demo.two', 'acct/com.slashbuilder.demo.other', 'acct2/com.slashbuilder.demo.two']) {
        expect(Directory('${tmp.path}/$d').existsSync(), isTrue, reason: d);
      }
    });

    test('a graceful quit is "lost: goodbye" with the announcement withdrawn, and a restart is a new peer', () async {
      final a = await spawn('alpha');
      final b = await spawn('beta');
      await a.peerEvent('ready', 'beta');
      expect(announcements('beta'), hasLength(1));

      b.command({'cmd': 'quit'});
      final lost = await a.peerEvent('lost', 'beta');
      expect(lost['why'], 'goodbye');
      await b.process.exitCode.timeout(const Duration(seconds: 10));
      expect(announcements('beta'), isEmpty);
      expect((await a.ask({'cmd': 'peers'}))['peers'], isEmpty);

      final b2 = await spawn('beta');
      await a.waitFor((e) => e['ev'] == 'peer' && e['change'] == 'ready' && _readyCount(a) == 2, why: 'the second ready');
      expect(b2.pid, isNot(b.pid));
    });
  });

  group('kill -9', () {
    /// Kills [victim] and watches [survivor]. The lower device id is the one that dials, so killing `beta` leaves a survivor
    /// that redials the ghost and killing `alpha` leaves one that only waits to be dialed.
    Future<void> ghostScenario({required String victim, required String survivor}) async {
      final watch = Duration(seconds: int.parse(Platform.environment['APP_CONTEXT_GHOST_SECONDS'] ?? '12'));
      final v = await spawn(victim);
      final s = await spawn(survivor);
      await s.peerEvent('ready', victim);
      await v.peerEvent('ready', survivor);
      final ghost = announcements(victim).single;

      final killedAt = DateTime.now().microsecondsSinceEpoch;
      v.kill9();
      final lost = await s.peerEvent('lost', victim);
      final lostAfter = _ms((lost['t'] as int) - killedAt);
      final role = survivor == 'alpha' ? 'the dialer' : 'the one that waits to be dialed';
      print(
          'kill -9 of $victim: the survivor $survivor ($role) saw lost after ${lostAfter.toStringAsFixed(1)} ms, reason "${lost['why']}"');
      expect(lost['why'], 'link closed', reason: 'no goodbye was possible');
      expect(lostAfter, lessThan(2000));

      // Watch the survivor: its dial failures and its view of the peer, twice a second.
      final samples = <String>[];
      var lastFailures = 0;
      int? lastDialAt;
      String? lastView;
      final start = DateTime.now();
      while (DateTime.now().difference(start) < watch) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final stats = await s.ask({'cmd': 'stats'});
        final view = ((await s.ask({'cmd': 'peers'}))['peers'] as List)
            .map((p) => (p as String).split('@').first + p.substring(p.indexOf(':')))
            .toList();
        final f = stats['dialFailures'] as int;
        final at = DateTime.now().difference(start).inMilliseconds;
        if (f != lastFailures) lastDialAt = at;
        lastFailures = f;
        if ('$view' != lastView) samples.add('${(at / 1000).toStringAsFixed(1)}s dials=$f view=$view');
        lastView = '$view';
      }
      samples.forEach(print);
      print('survivor events after the kill: ${s.peerEvents.map((e) => '${e['change']}${e['change'] == 'lost' ? '(${e['why']})' : ''}'
          '@${_ms((e['t'] as int) - killedAt).toStringAsFixed(0)}ms').join(', ')}');
      print(
          'after ${watch.inSeconds}s: ghost file present: ${ghost.existsSync()}; failed dials: $lastFailures; last one ${lastDialAt}ms into the watch; '
          'view: $lastView');

      // A crashed copy must not stay in the view for ever: the announcement stops being refreshed, so it is dropped
      // (within a few seconds), the survivor stops dialing it, and the dead copy's file is not offered again.
      expect(lastView, '[]', reason: 'after ${watch.inSeconds}s the survivor still lists the dead copy: $lastView');
      expect(s.peerEvents.last['change'], 'lost', reason: 'the last thing the survivor heard about the dead copy must be lost');
      final failuresAfterDrop = lastFailures;
      await Future<void>.delayed(const Duration(seconds: 1));
      expect((await s.ask({'cmd': 'stats'}))['dialFailures'], failuresAfterDrop, reason: 'still dialing a dead copy');

      // A fresh process with the same device id (a restart) has a NEW instance id, so it is a new peer, reachable at once.
      final v2 = await spawn(victim);
      await s.waitFor((e) => e['ev'] == 'peer' && e['change'] == 'ready' && (e['t'] as int) > killedAt,
          why: 'ready for the restarted $victim');
      await v2.peerEvent('ready', survivor);
      final view = (await s.ask({'cmd': 'peers'}))['peers'] as List;
      print('after a fresh process with the same device id started, $survivor sees: $view; ghost file present: ${ghost.existsSync()}');
      expect(view, hasLength(1), reason: 'only the live copy is listed, not the ghost: $view');
      expect(view.single as String, endsWith(':ready'));
      final sent = await s.ask({'cmd': 'send', 'to': victim, 'text': 'after-restart'});
      expect(sent['ok'], isTrue);
      await v2.waitFor((e) => e['ev'] == 'msg' && e['text'] == 'after-restart');
    }

    test('the survivor that dials sees lost at once; the ghost is observed (numbers printed); a restart with the same device id works',
        () => ghostScenario(victim: 'beta', survivor: 'alpha'));

    test('the survivor that waits to be dialed sees lost at once; the ghost is observed (numbers printed); a restart works',
        () => ghostScenario(victim: 'alpha', survivor: 'beta'));
  });
}

int _readyCount(Worker w) => w.peerEvents.where((e) => e['change'] == 'ready').length;
