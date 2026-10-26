// The hub against a scripted peer: frames the test writes by hand, so the
// hub's own checks (not a well-behaved provider's) are what is being proven.
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_context_kit/src/peers/peers.dart';
import 'package:test/test.dart';

import 'support.dart';

const remote = PeerIdentity('acct-1', 'com.slashbuilder.demo.app', PeerId('z', 'i1'));

Envelope frame(
  int seq,
  String kind,
  Object? payload, {
  PeerId from = const PeerId('z', 'i1'),
  String account = 'acct-1',
  String app = 'com.slashbuilder.demo.app',
  String channel = 'default',
  int? rid,
}) =>
    Envelope(
      header: EnvelopeHeader(account: account, app: app, channel: channel, from: from, seq: seq, kind: kind, requestId: rid),
      payload: payload is Uint8List ? payload : bytes(jsonEncode(payload)),
    );

Envelope appFrame(int seq, String text) => frame(seq, 'msg', bytes(text));

class Scripted {
  Scripted(this.w, this.provider, this.node, this.link);
  final World w;
  final ScriptedProvider provider;
  final Node node;
  ScriptedLink link;

  Future<void> push(Envelope e) async {
    link.pushEnvelope(e);
    await w.settle();
  }

  Iterable<String> get sentKinds => link.sent.map((e) => e.header.kind);
}

Future<Scripted> scripted(World w, {bool handshake = true, PeerHubOptions options = const PeerHubOptions(), PeerAuthenticator? auth, RecordingHook? hook}) async {
  final sp = ScriptedProvider();
  final n = w.node('a', provider: sp, options: options, auth: auth, hook: hook);
  await n.hub.start();
  final link = sp.inject(remote);
  await w.settle();
  final s = Scripted(w, sp, n, link);
  expect(link.sent.map((e) => e.header.kind), ['kit.hello'], reason: 'the hub speaks first');
  if (handshake) {
    await s.push(frame(1, 'kit.hello', {'nonce': 'n-remote', 'hello': {'x': 1}}));
    await s.push(frame(2, 'kit.auth', {'scheme': 'open', 'value': ''}));
    await s.push(frame(3, 'kit.ready', Uint8List(0)));
    expect(n.hook.events, ['found z@i1', 'ready z@i1']);
  }
  return s;
}

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() async => w.closeAll());

  test('baseline: a hand-written handshake works and the hub answers with hello, auth, ready', () async {
    final s = await scripted(w);
    expect(s.sentKinds, ['kit.hello', 'kit.auth', 'kit.ready']);
    expect(s.link.sent.map((e) => e.header.seq), [1, 2, 3]);
    expect(s.node.hub.peers.single.hello, {'x': 1});
    await s.push(appFrame(4, 'hi'));
    expect(s.node.hook.texts, ['hi']);
  });

  group('sequencing', () {
    test('an exact duplicate is delivered once', () async {
      final s = await scripted(w);
      await s.push(appFrame(4, 'once'));
      await s.push(appFrame(4, 'once'));
      await s.push(appFrame(4, 'once'));
      expect(s.node.hook.texts, ['once']);
      expect(s.node.hub.stats.duplicatesDropped, 2);
    });

    test('out of order frames are held and delivered in order', () async {
      final s = await scripted(w);
      await s.push(appFrame(6, 'third'));
      await s.push(appFrame(5, 'second'));
      expect(s.node.hook.texts, [], reason: 'seq 4 has not arrived');
      await s.push(appFrame(4, 'first'));
      expect(s.node.hook.texts, ['first', 'second', 'third']);
    });

    test('a gap that never fills is skipped after the reorder timeout; the late frame is then dropped', () async {
      final s = await scripted(w);
      await s.push(appFrame(6, 'after-gap'));
      await w.advance(const Duration(milliseconds: 499));
      expect(s.node.hook.texts, isEmpty);
      await w.advance(const Duration(milliseconds: 1));
      expect(s.node.hook.texts, ['after-gap']);
      expect(s.node.hook.messages.single.seq, 6);
      expect(s.node.hub.stats.gapsSkipped, 2);
      await s.push(appFrame(4, 'late'));
      expect(s.node.hook.texts, ['after-gap']);
    });

    test('overflowing the reorder buffer skips the gap at once (memory stays bounded)', () async {
      final s = await scripted(w, options: const PeerHubOptions(reorderBuffer: 3));
      for (var i = 10; i < 14; i++) {
        await s.push(appFrame(i, 'm$i'));
      }
      expect(s.node.hook.texts, ['m10', 'm11', 'm12', 'm13']);
      expect(s.node.hub.stats.gapsSkipped, 6);
    });
  });

  group('protocol violations drop the link, never the hub', () {
    Future<void> expectDropped(Scripted s, String reasonPart) async {
      expect(s.link.closed, isTrue);
      expect(s.node.hook.events.last, startsWith('lost'));
      expect(s.node.hook.changes.last.$1.lostReason, contains(reasonPart));
      expect(s.node.hub.peers, isEmpty);
    }

    test('a frame that is not an envelope', () async {
      final s = await scripted(w);
      s.link.push(bytes('this is not json'));
      await w.settle();
      await expectDropped(s, 'malformed');
      expect(s.node.hub.stats.malformedFrames, 1);
    });

    test('an oversize frame', () async {
      final s = await scripted(w);
      s.link.push(Uint8List(Envelope.maxEncodedBytes + 1));
      await w.settle();
      await expectDropped(s, 'malformed');
    });

    test('a frame stamped with another app id', () async {
      final s = await scripted(w);
      await s.push(frame(4, 'msg', bytes('x'), app: 'com.slashbuilder.demo.other'));
      await expectDropped(s, 'scope');
      expect(s.node.hub.stats.scopeViolations, 1);
      expect(s.node.hook.messages, isEmpty);
    });

    test('a frame stamped with another account', () async {
      final s = await scripted(w);
      await s.push(frame(4, 'msg', bytes('x'), account: 'acct-2'));
      await expectDropped(s, 'scope');
    });

    test('a frame that claims to be from someone else', () async {
      final s = await scripted(w);
      await s.push(frame(4, 'msg', bytes('x'), from: const PeerId('mallory', 'i9')));
      await expectDropped(s, 'does not match');
      expect(s.node.hook.messages, isEmpty);
    });

    test('a frame with seq 0', () async {
      final s = await scripted(w);
      await s.push(appFrame(0, 'x'));
      await expectDropped(s, 'does not match');
    });

    test('anything before hello', () async {
      final s = await scripted(w, handshake: false);
      await s.push(appFrame(1, 'sneaky'));
      expect(s.link.closed, isTrue);
      expect(s.node.hook.events, isEmpty, reason: 'never became a peer at all');
      expect(s.node.hook.messages, isEmpty);
    });

    test('a second hello', () async {
      final s = await scripted(w);
      await s.push(frame(4, 'kit.hello', {'nonce': 'again', 'hello': null}));
      await expectDropped(s, 'second hello');
    });

    test('a hello with no nonce', () async {
      final s = await scripted(w, handshake: false);
      await s.push(frame(1, 'kit.hello', {'hello': 1}));
      expect(s.link.closed, isTrue);
      expect(s.node.hook.events, isEmpty);
    });

    test('a ready before auth', () async {
      final s = await scripted(w, handshake: false);
      await s.push(frame(1, 'kit.hello', {'nonce': 'n', 'hello': null}));
      await s.push(frame(2, 'kit.ready', Uint8List(0)));
      expect(s.link.closed, isTrue);
      expect(s.node.hook.count('ready'), 0);
    });

    test('a peer that never finishes the handshake is dropped after the timeout', () async {
      final s = await scripted(w, handshake: false);
      await w.advance(const Duration(seconds: 4));
      expect(s.link.closed, isFalse);
      await w.advance(const Duration(seconds: 1));
      expect(s.link.closed, isTrue);
    });

    test('a handshake stalled after hello (never sends auth) is dropped and the peer goes away quietly', () async {
      final s = await scripted(w, handshake: false);
      await s.push(frame(1, 'kit.hello', {'nonce': 'n', 'hello': null}));
      expect(s.node.hub.peers.single.state, PeerState.connecting);
      await w.advance(const Duration(seconds: 5));
      expect(s.link.closed, isTrue);
      expect(s.node.hook.events, ['found z@i1', 'lost z@i1']);
    });
  });

  group('handshake edge cases', () {
    test('app frames before ready are dropped, not delivered', () async {
      final s = await scripted(w, handshake: false);
      await s.push(frame(1, 'kit.hello', {'nonce': 'n', 'hello': null}));
      await s.push(frame(2, 'kit.auth', {'scheme': 'open', 'value': ''}));
      await s.push(appFrame(3, 'too early'));
      await s.push(frame(4, 'kit.ready', Uint8List(0)));
      expect(s.node.hook.messages, isEmpty);
      expect(s.node.hub.stats.droppedBeforeReady, 1);
      expect(s.node.hook.events, ['found z@i1', 'ready z@i1']);
    });

    test('a wrong channel gets a kit.reject frame, not silence', () async {
      final s = await scripted(w, handshake: false);
      await s.push(frame(1, 'kit.hello', {'nonce': 'n', 'hello': null}, channel: 'other'));
      expect(s.sentKinds, contains('kit.reject'));
      expect(s.link.closed, isTrue);
      expect(s.node.hook.changes.last.$1.rejectReason, contains('channel mismatch'));
    });

    test('a bad proof gets a kit.reject frame and the app\'s admit is never asked', () async {
      final hook = RecordingHook();
      final s = await scripted(w, handshake: false, auth: SharedSecretAuthenticator('right'), hook: hook);
      await s.push(frame(1, 'kit.hello', {'nonce': 'n', 'hello': null}));
      await s.push(frame(2, 'kit.auth', {'scheme': 'open', 'value': ''}));
      expect(s.sentKinds, contains('kit.reject'));
      expect(hook.hellosSeen, isEmpty);
      expect(hook.count('ready'), 0);
    });

    test('a proof that is not a proof is a protocol violation', () async {
      final s = await scripted(w, handshake: false);
      await s.push(frame(1, 'kit.hello', {'nonce': 'n', 'hello': null}));
      await s.push(frame(2, 'kit.auth', 'garbage'));
      expect(s.link.closed, isTrue);
      expect(s.node.hook.count('ready'), 0);
    });

    test('unknown kit.* kinds are ignored once ready', () async {
      final s = await scripted(w);
      await s.push(frame(4, 'kit.from-the-future', Uint8List(0)));
      await s.push(appFrame(5, 'still fine'));
      expect(s.node.hook.texts, ['still fine']);
    });

    test('a second link from the same peer replaces the first: lost, then the new one is found', () async {
      final s = await scripted(w);
      final second = s.provider.inject(remote);
      await w.settle();
      expect(s.link.closed, isFalse, reason: 'nothing changes until the newcomer says hello');
      second.pushEnvelope(frame(1, 'kit.hello', {'nonce': 'n2', 'hello': null}));
      await w.settle();
      expect(s.link.closed, isTrue, reason: 'the old link is closed');
      expect(s.node.hook.events, ['found z@i1', 'ready z@i1', 'lost z@i1', 'found z@i1']);
      expect(s.node.hook.changes[2].$1.lostReason, 'replaced by a newer link');
      expect(second.closed, isFalse);
      expect(s.node.hub.peers.single.state, PeerState.connecting);
    });

    test('goodbye from the peer: lost with reason goodbye, link closed', () async {
      final s = await scripted(w);
      await s.push(frame(4, 'kit.bye', Uint8List(0)));
      expect(s.node.hook.events.last, 'lost z@i1');
      expect(s.node.hook.changes.last.$1.lostReason, 'goodbye');
      expect(s.link.closed, isTrue);
    });
  });
}
