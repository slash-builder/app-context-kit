// One OS process with one PeerHub over a LoopbackProvider, driven over stdin/stdout by two_process_test.dart.
// Not a test itself (the name has no `_test` suffix). Protocol: JSON lines.
//
//   args: <directory> <account> <app> <device> [instance]
//   out:  {"ev":"ready","pid":N,"id":"device@instance","t":micros}      once started
//         {"ev":"peer","change":"found|ready|lost","peer":"device@instance","why":..., "t":micros}
//         {"ev":"msg","from":"device@instance","kind":K,"text":S,"rid":N|null,"t":micros}
//         {"ev":"reply","to":"device@instance","text":S}                 an answer to a "request" command
//         {"ev":"result","cmd":C,...}                                    the answer to peers/stats/send/broadcast
//         {"ev":"bye"}                                                   after a graceful quit
//   in:   {"cmd":"send","to":"device","text":S} | {"cmd":"broadcast","text":S} | {"cmd":"request","to":"device","text":S}
//         {"cmd":"peers"} | {"cmd":"stats"} | {"cmd":"quit"}
// Every request it receives is answered with "echo:<text>".
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_context_kit/app_context_kit.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
int _now() => DateTime.now().microsecondsSinceEpoch;
void _out(Map<String, Object?> m) {
  stdout.writeln(jsonEncode({...m, 't': _now()}));
}

class _Hook extends AppCoordination {
  _Hook(this.device);
  final String device;
  late PeerHub hub;
  @override
  String get channel => 'default';
  @override
  void attach(PeerHub h) => hub = h;
  @override
  Object? hello() => {'device': device, 'pid': pid};
  @override
  FutureOr<Admit> admit(Peer peer, Object? theirHello) => const Admit.accept();
  @override
  void onPeer(Peer peer, PeerChange change) {
    _out({'ev': 'peer', 'change': change.name, 'peer': peer.id.toString(), 'why': peer.lostReason});
  }

  @override
  void onMessage(Peer from, AppMessage m) {
    final text = utf8.decode(m.payload);
    _out({'ev': 'msg', 'from': from.id.toString(), 'kind': m.kind, 'text': text, 'rid': m.requestId});
    if (m.requestId != null) {
      hub.reply(m, _bytes('echo:$text')).then((_) {}, onError: (Object _) {});
    }
  }
}

Future<void> main(List<String> args) async {
  final dir = args[0], account = args[1], app = args[2], device = args[3];
  final instance = args.length > 4 ? args[4] : 'i${pid.toRadixString(16)}';
  final hook = _Hook(device);
  final hub = PeerHub(
    account: account,
    app: app,
    device: device,
    instance: instance,
    provider: LoopbackProvider(directory: dir, pollInterval: const Duration(milliseconds: 100)),
    hook: hook,
  );
  await hub.start();
  _out({'ev': 'ready', 'pid': pid, 'id': hub.id.toString()});

  // Prefer a ready peer: after a crash the ghost of an old copy of the same device can still be listed as `found`.
  Peer? find(String device) {
    Peer? any;
    for (final p in hub.peers) {
      if (p.id.device != device) continue;
      if (p.state == PeerState.ready) return p;
      any ??= p;
    }
    return any;
  }

  final done = Completer<void>();
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
    final Map<String, dynamic> c;
    try {
      c = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (c['cmd']) {
      case 'send':
        final p = find(c['to'] as String);
        try {
          await hub.send(p!, _bytes(c['text'] as String), kind: 'note');
          _out({'ev': 'result', 'cmd': 'send', 'ok': true});
        } catch (e) {
          _out({'ev': 'result', 'cmd': 'send', 'ok': false, 'error': '$e'});
        }
      case 'broadcast':
        final r = await hub.broadcast(_bytes(c['text'] as String), kind: 'note');
        _out({
          'ev': 'result',
          'cmd': 'broadcast',
          'sent': [for (final p in r.sent) p.toString()],
          'failed': r.failed.length
        });
      case 'request':
        final p = find(c['to'] as String);
        try {
          final r = await hub.request(p!, _bytes(c['text'] as String));
          _out({'ev': 'reply', 'to': p.id.toString(), 'text': utf8.decode(r.payload)});
        } catch (e) {
          _out({'ev': 'reply', 'to': c['to'], 'error': '$e'});
        }
      case 'peers':
        _out({
          'ev': 'result',
          'cmd': 'peers',
          'peers': [for (final p in hub.peers) '${p.id}:${p.state.name}']
        });
      case 'stats':
        _out({'ev': 'result', 'cmd': 'stats', 'dialFailures': hub.stats.dialFailures, 'linksOpened': hub.stats.linksOpened});
      case 'quit':
        await hub.close();
        _out({'ev': 'bye'});
        done.complete();
    }
  }, onDone: () {
    if (!done.isCompleted) done.complete();
  });
  await done.future;
  await hub.close();
  exit(0);
}
