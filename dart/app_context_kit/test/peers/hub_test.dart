import 'dart:async';
import 'dart:typed_data';

import 'package:app_context_kit/src/peers/peers.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() async => w.closeAll());

  group('discovery and connect', () {
    test('two hubs find each other, handshake and become ready, hellos exchanged', () async {
      final a = await w.startedNode('a', hook: RecordingHook(helloValue: {'game': 'idle', 'proto': 3}));
      final b = await w.startedNode('b', hook: RecordingHook(helloValue: 'hi from b'));

      expect(a.hook.events, ['found b@i1', 'ready b@i1']);
      expect(b.hook.events, ['found a@i1', 'ready a@i1']);
      expect(a.hub.peers.single.state, PeerState.ready);
      expect(a.hub.peers.single.hello, 'hi from b');
      expect(b.hub.peers.single.hello, {'game': 'idle', 'proto': 3});
      expect(a.hub.peers.single.account, 'acct-1');
      expect(a.hub.peers.single.app, 'com.slashbuilder.demo.app');
      // one connection = two link ends, not two connections
      expect(w.network.openLinkEnds, 2);
    });

    test('a hub that starts first is found by one that starts later (either order)', () async {
      final b = await w.startedNode('b');
      final a = await w.startedNode('a');
      expect(a.hook.events, ['found b@i1', 'ready b@i1']);
      expect(b.hook.events, ['found a@i1', 'ready a@i1']);
    });

    test('three hubs form a full mesh with exactly one connection per pair', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b');
      final c = await w.startedNode('c');
      for (final n in [a, b, c]) {
        expect(n.hub.readyPeers.map((p) => p.id.device).toSet(), {'a', 'b', 'c'}.difference({n.hub.device}), reason: n.hub.id.toString());
        expect(n.hook.count('ready'), 2);
      }
      expect(w.network.openLinkEnds, 6);
    });

    test('two copies of one app on one device are two peers (different instances)', () async {
      final one = await w.startedNode('mac', instance: 'i1');
      final two = await w.startedNode('mac', instance: 'i2');
      expect(one.hub.peers.single.id, const PeerId('mac', 'i2'));
      expect(two.hub.peers.single.id, const PeerId('mac', 'i1'));
      expect(one.hub.peers.single.state, PeerState.ready);
    });

    test('the changes stream mirrors the hook', () async {
      final a = w.node('a');
      final seen = <String>[];
      a.hub.changes.listen((e) => seen.add('${e.change.name} ${e.peer.id}'));
      await a.hub.start();
      await w.startedNode('b');
      expect(seen, a.hook.events);
      expect(seen, ['found b@i1', 'ready b@i1']);
    });
  });

  group('hello and admit', () {
    test('admit sees the peer and its hello; accept makes it ready', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b', hook: RecordingHook(helloValue: {'caps': ['x']}));
      expect(a.hook.hellosSeen, [
        {'caps': ['x']}
      ]);
      expect(b.hook.hellosSeen, [null]);
    });

    test('reject: no ready, both sides told why, and the peer is not redialed', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b', hook: RecordingHook(admitFn: (p, h) => const Admit.reject('not today')));

      expect(b.hook.events, ['found a@i1', 'lost a@i1']);
      expect(b.hook.changes.last.$1.state, PeerState.rejected);
      expect(b.hook.changes.last.$1.rejectReason, 'not today');
      expect(a.hook.events, ['found b@i1', 'lost b@i1']);
      expect(a.hook.changes.last.$1.state, PeerState.rejected);
      expect(a.hook.changes.last.$1.rejectReason, 'rejected by peer: not today');
      expect(a.hub.peers, isEmpty);
      expect(b.hub.peers, isEmpty);
      expect(a.hook.count('ready'), 0);

      final attempts = w.network.connectAttempts;
      await w.advance(const Duration(minutes: 5));
      expect(w.network.connectAttempts, attempts, reason: 'a rejected peer is not redialed');
      expect(w.network.openLinkEnds, 0);
      await expectLater(a.hub.send(a.hook.changes.last.$1, bytes('x')), throwsA(isA<PeerNotAvailable>()));
    });

    test('a rejected peer is offered again after the provider withdraws and re-announces it', () async {
      final a = await w.startedNode('a');
      var allow = false;
      final b = await w.startedNode('b', hook: RecordingHook(admitFn: (p, h) => allow ? const Admit.accept() : const Admit.reject('closed')));
      expect(a.hook.count('ready'), 0);
      allow = true;
      w.network.isolate(b.hub.id);
      await w.settle();
      w.network.heal(b.hub.id);
      await w.settle();
      expect(a.hook.count('ready'), 1);
      expect(a.hub.peers.single.state, PeerState.ready);
    });

    test('accept-read-only only tags the peer; the Kit still delivers and the hook decides', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b', hook: RecordingHook(admitFn: (p, h) => const Admit.acceptReadOnly()));
      expect(b.hub.peers.single.readOnly, isTrue);
      expect(a.hub.peers.single.readOnly, isFalse, reason: 'the decision is local; the other side is not told');
      expect(b.hub.peers.single.state, PeerState.ready);
      await a.hub.send(a.hub.peers.single, bytes('write: x'));
      await w.settle();
      expect(b.hook.texts, ['write: x']);
    });

    test('admit may be async: the peer is not ready until the app answers', () async {
      final gate = Completer<Admit>();
      final a = await w.startedNode('a');
      final b = await w.startedNode('b', hook: RecordingHook(admitFn: (p, h) => gate.future));
      expect(b.hub.peers.single.state, PeerState.connecting);
      expect(a.hub.peers.single.state, PeerState.connecting);
      gate.complete(const Admit.accept());
      await w.settle();
      expect(b.hub.peers.single.state, PeerState.ready);
      expect(a.hub.peers.single.state, PeerState.ready);
    });

    test('an admit that throws is a rejection and does not crash the hub', () async {
      final errors = <String>[];
      final a = await w.startedNode('a', options: PeerHubOptions(onHookError: (where, e, s) => errors.add(where)));
      final b = await w.startedNode('b', hook: RecordingHook(admitFn: (p, h) => throw StateError('boom')));
      expect(b.hub.stats.hookErrors, 1);
      expect(b.hub.peers, isEmpty);
      expect(a.hook.changes.last.$1.rejectReason, 'rejected by peer: admit failed');
      expect(errors, isEmpty, reason: 'only a\'s own errors are reported to a\'s callback');
    });

    test('a different channel is refused at the handshake', () async {
      final a = await w.startedNode('a', hook: RecordingHook(channelName: 'game'));
      final b = await w.startedNode('b', hook: RecordingHook(channelName: 'notes'));
      expect(a.hub.peers, isEmpty);
      expect(b.hub.peers, isEmpty);
      expect(a.hook.count('ready'), 0);
      expect(b.hook.changes.last.$1.rejectReason, contains('channel mismatch'));
    });

    test('the shared-secret authenticator: same secret connects, a different one is refused', () async {
      final a = await w.startedNode('a', auth: SharedSecretAuthenticator('s3cret'));
      final b = await w.startedNode('b', auth: SharedSecretAuthenticator('s3cret'));
      expect(a.hub.peers.single.state, PeerState.ready);

      final c = await w.startedNode('c', auth: SharedSecretAuthenticator('wrong'));
      expect(c.hub.peers, isEmpty);
      expect(c.hook.changes.where((e) => e.$2 == PeerChange.lost).map((e) => e.$1.rejectReason), everyElement(anyOf(
        equals('authentication failed'),
        equals('rejected by peer: authentication failed'),
      )));
      expect(a.hub.readyPeers.map((p) => p.id.device), ['b'], reason: 'c never became a peer of a');
      expect(b.hub.readyPeers.map((p) => p.id.device), ['a']);
    });

    test('a proof is bound to the challenge: a proof for one challenge fails another', () async {
      final auth = SharedSecretAuthenticator('k');
      const who = PeerIdentity('acct', 'app', PeerId('d', 'i'));
      final proof = await auth.prove(who, 'challenge-1');
      expect(await auth.verify(who, 'challenge-1', proof), isTrue);
      expect(await auth.verify(who, 'challenge-2', proof), isFalse);
      expect(await auth.verify(const PeerIdentity('acct', 'other.app', PeerId('d', 'i')), 'challenge-1', proof), isFalse);
      expect(await auth.verify(who, 'challenge-1', const Proof('open', '')), isFalse);
    });
  });

  group('scope isolation (account AND app id)', () {
    test('another app or another account is never offered, connected or sent to', () async {
      final a1 = await w.startedNode('a');
      final a2 = await w.startedNode('b');
      final otherApp = await w.startedNode('c', app: 'com.slashbuilder.demo.other');
      final otherAcct = await w.startedNode('d', account: 'acct-2');

      expect(a1.hub.readyPeers.map((p) => p.id.device), ['b']);
      expect(a2.hub.readyPeers.map((p) => p.id.device), ['a']);
      expect(otherApp.hub.peers, isEmpty);
      expect(otherAcct.hub.peers, isEmpty);
      expect(otherApp.hook.events, isEmpty);
      expect(otherAcct.hook.events, isEmpty);

      final result = await a1.hub.broadcast(bytes('app-A secret'));
      await w.settle();
      expect(result.sent, [a2.hub.id]);
      expect(a2.hook.texts, ['app-A secret']);
      expect(otherApp.hook.messages, isEmpty);
      expect(otherAcct.hook.messages, isEmpty);

      // The wire agrees: no frame was ever delivered to the other app's or account's hub.
      final strangers = {otherApp.hub.identity, otherAcct.hub.identity};
      expect(w.network.deliveries.where((d) => strangers.contains(d.to)), isEmpty);
      expect(w.network.deliveries.where((d) => strangers.contains(d.from)), isEmpty);
      expect(w.network.deliveries, isNotEmpty);
    });

    test('the provider refuses to dial or accept across scopes even when asked to', () async {
      final a = await w.startedNode('a');
      final stranger = w.network.provider();
      await stranger.open(const PeerIdentity('acct-1', 'com.slashbuilder.demo.other', PeerId('x', 'i1')));
      final aCandidate = PeerCandidate(a.hub.identity, 'a@i1');
      await expectLater(stranger.connect(aCandidate), throwsA(isA<PeerScopeError>()));
      final wrongAcct = w.network.provider();
      await wrongAcct.open(const PeerIdentity('acct-9', 'com.slashbuilder.demo.app', PeerId('y', 'i1')));
      await expectLater(wrongAcct.connect(aCandidate), throwsA(isA<PeerScopeError>()));
      // and neither shows up in discovery of the other
      expect(await stranger.discover().take(0).toList(), isEmpty);
      final seen = <PeerCandidate>[];
      final sub = stranger.discover().listen(seen.add);
      final sub2 = wrongAcct.discover().listen(seen.add);
      await w.settle();
      expect(seen, isEmpty);
      await sub.cancel();
      await sub2.cancel();
      await stranger.close();
      await wrongAcct.close();
    });

    test('a hub ignores a candidate from another scope even if a provider offers one', () async {
      final sp = ScriptedProvider();
      final h = w.node('a', provider: sp);
      await h.hub.start();
      sp.offer(const PeerCandidate(PeerIdentity('acct-1', 'com.slashbuilder.demo.other', PeerId('z', 'i')), 'x'));
      sp.offer(const PeerCandidate(PeerIdentity('acct-2', 'com.slashbuilder.demo.app', PeerId('z', 'i')), 'x'));
      await w.settle();
      expect(h.hub.peers, isEmpty);
      expect(h.hook.events, isEmpty);
      expect(h.hub.stats.scopeViolations, 2);
    });

    test('a hub drops an incoming link whose claim is out of scope', () async {
      final sp = ScriptedProvider();
      final h = w.node('a', provider: sp);
      await h.hub.start();
      final l1 = sp.inject(const PeerIdentity('acct-1', 'com.slashbuilder.demo.other', PeerId('z', 'i')));
      final l2 = sp.inject(const PeerIdentity('acct-2', 'com.slashbuilder.demo.app', PeerId('z', 'i')));
      await w.settle();
      expect(l1.closed, isTrue);
      expect(l2.closed, isTrue);
      expect(l1.sent, isEmpty, reason: 'nothing, not even a hello, goes to a stranger');
      expect(l2.sent, isEmpty);
      expect(h.hook.events, isEmpty);
    });
  });

  group('ordering and duplicates', () {
    test('jitter reorders frames and the network duplicates some; the app sees each once, in order', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b', options: const PeerHubOptions(reorderBuffer: 64));
      w.network.jitter = const Duration(milliseconds: 80);
      w.network.duplicateRate = 0.4;
      final expected = [for (var i = 0; i < 40; i++) 'm$i'];
      for (final m in expected) {
        unawaited(a.hub.send(a.hub.peers.single, bytes(m)));
      }
      await w.advance(const Duration(milliseconds: 400));
      expect(b.hook.texts, expected);
      expect(b.hook.messages.map((m) => m.seq).toList(), isNot(contains(0)));
      expect(b.hub.stats.duplicatesDropped, greaterThan(0));
      expect(b.hub.stats.gapsSkipped, 0);
    });

    test('a lost frame leaves a visible gap: later frames wait, then the gap is skipped once', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b');
      w.network.dropIf = (from, to, frame) {
        final e = Envelope.decode(frame);
        return e.header.kind == 'msg' && text(e.payload) == 'm2';
      };
      for (var i = 0; i < 5; i++) {
        unawaited(a.hub.send(a.hub.peers.single, bytes('m$i')));
      }
      await w.advance(const Duration(milliseconds: 100));
      expect(b.hook.texts, ['m0', 'm1'], reason: 'm3 and m4 wait for m2');
      await w.advance(const Duration(milliseconds: 500));
      expect(b.hook.texts, ['m0', 'm1', 'm3', 'm4']);
      final seqs = b.hook.messages.map((m) => m.seq).toList();
      expect(seqs[2] - seqs[1], 2, reason: 'the app can see the jump');
      expect(b.hub.stats.gapsSkipped, 1);
    });
  });

  group('broadcast, request and reply', () {
    test('broadcast reaches every ready peer and reports who', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b');
      final c = await w.startedNode('c');
      final r = await a.hub.broadcast(bytes('hello all'), kind: 'note', schema: 4);
      await w.settle();
      expect(r.sent.toSet(), {b.hub.id, c.hub.id});
      expect(r.failed, isEmpty);
      for (final n in [b, c]) {
        expect(n.hook.texts, ['hello all']);
        expect(n.hook.messages.single.kind, 'note');
        expect(n.hook.messages.single.schema, 4);
        expect(n.hook.messages.single.from, a.hub.id);
        expect(n.hook.messages.single.channel, 'default');
      }
      expect(a.hook.messages, isEmpty, reason: 'no echo to the sender');
    });

    test('request gets the peer\'s reply; the Kit never reads either payload', () async {
      final a = await w.startedNode('a');
      late Node b;
      b = await w.startedNode('b',
          hook: RecordingHook(onMessageFn: (from, m) {
            if (m.requestId != null) unawaited(b.hub.reply(m, bytes('pong:${text(m.payload)}'), schema: 9));
          }));
      final reply = await a.hub.request(a.hub.peers.single, bytes('ping'), kind: 'q', schema: 2);
      expect(text(reply.payload), 'pong:ping');
      expect(reply.schema, 9);
      expect(reply.kind, PeerKinds.reply);
      expect(b.hook.messages.single.kind, 'q');
    });

    test('two requests in flight are answered to the right caller, even out of order', () async {
      final a = await w.startedNode('a');
      final held = <AppMessage>[];
      late Node b;
      b = await w.startedNode('b', hook: RecordingHook(onMessageFn: (from, m) => held.add(m)));
      final p = a.hub.peers.single;
      final f1 = a.hub.request(p, bytes('one'));
      final f2 = a.hub.request(p, bytes('two'));
      await w.settle();
      expect(held.map((m) => text(m.payload)), ['one', 'two']);
      await b.hub.reply(held[1], bytes('reply-two'));
      await b.hub.reply(held[0], bytes('reply-one'));
      expect(text((await f1).payload), 'reply-one');
      expect(text((await f2).payload), 'reply-two');
    });

    test('a request times out with a typed error, and a late reply is ignored', () async {
      final a = await w.startedNode('a');
      final seen = <AppMessage>[];
      final b = await w.startedNode('b', hook: RecordingHook(onMessageFn: (from, m) => seen.add(m)));
      final f = a.hub.request(a.hub.peers.single, bytes('anyone?'), timeout: const Duration(seconds: 2));
      final check = expectLater(f, throwsA(isA<PeerTimeout>()));
      await w.advance(const Duration(milliseconds: 1999));
      var done = false;
      unawaited(f.then((_) {}, onError: (_) => done = true));
      await w.settle();
      expect(done, isFalse, reason: 'not yet');
      await w.advance(const Duration(milliseconds: 1));
      await check;
      await b.hub.reply(seen.single, bytes('too late'));
      await w.settle();
      expect(a.hook.messages, isEmpty, reason: 'the late reply is not an app message');
    });

    test('a request fails with PeerLost if the peer goes away first', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b');
      final f = a.hub.request(a.hub.peers.single, bytes('x'));
      final check = expectLater(f, throwsA(isA<PeerLost>()));
      w.network.isolate(b.hub.id);
      await w.settle();
      await check;
    });

    test('kit.* kinds are reserved and replies need a request', () async {
      final a = await w.startedNode('a');
      await w.startedNode('b');
      await expectLater(a.hub.send(a.hub.peers.single, bytes('x'), kind: 'kit.hello'), throwsArgumentError);
      await expectLater(a.hub.send(a.hub.peers.single, bytes('x'), kind: ''), throwsArgumentError);
      await expectLater(a.hub.send(a.hub.peers.single, bytes('x'), schema: -1), throwsArgumentError);
      await expectLater(a.hub.reply(AppMessage(from: PeerId('b', 'i1'), channel: 'default', seq: 1, kind: 'k', schema: 0, payload: Uint8List(0)), bytes('x')), throwsArgumentError);
    });

    test('an oversize payload is refused up front', () async {
      final a = await w.startedNode('a');
      await w.startedNode('b');
      await expectLater(a.hub.send(a.hub.peers.single, Uint8List(Envelope.maxPayloadBytes + 1)), throwsA(isA<EnvelopeError>()));
      await a.hub.send(a.hub.peers.single, Uint8List(Envelope.maxPayloadBytes));
    });
  });

  group('a peer vanishing and coming back', () {
    test('partition then heal: lost, then found and ready again as a NEW Peer, and traffic resumes', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b');
      final first = a.hub.peers.single;
      w.network.isolate(b.hub.id);
      await w.settle();
      expect(a.hook.events, ['found b@i1', 'ready b@i1', 'lost b@i1']);
      expect(b.hook.events, ['found a@i1', 'ready a@i1', 'lost a@i1']);
      expect(a.hub.peers, isEmpty);
      expect(first.state, PeerState.lost);
      expect(first.lostReason, isNotNull);

      w.network.heal(b.hub.id);
      await w.settle();
      expect(a.hook.events.skip(3), ['found b@i1', 'ready b@i1']);
      final second = a.hub.peers.single;
      expect(second, isNot(same(first)));
      expect(second.state, PeerState.ready);
      await expectLater(a.hub.send(first, bytes('stale')), throwsA(isA<PeerNotAvailable>()));
      await a.hub.send(second, bytes('back'));
      await w.settle();
      expect(b.hook.texts, ['back']);
    });

    test('a copy that quits and a new copy with the same ids starts: the old one said goodbye, the new one is found', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b');
      await b.hub.close();
      await w.settle();
      expect(a.hook.events, ['found b@i1', 'ready b@i1', 'lost b@i1']);
      expect(a.hook.changes.last.$1.lostReason, 'goodbye');

      final b2 = await w.startedNode('b');
      expect(a.hook.events.skip(3), ['found b@i1', 'ready b@i1']);
      expect(b2.hub.peers.single.state, PeerState.ready);
    });

    test('a dropped link (not a partition) is redialed after the backoff, by the lower id', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b');
      w.network.dropLinks(a.hub.id, b.hub.id);
      await w.settle();
      expect(a.hook.events, ['found b@i1', 'ready b@i1', 'lost b@i1', 'found b@i1']);
      expect(b.hook.events, ['found a@i1', 'ready a@i1', 'lost a@i1', 'found a@i1']);
      await w.advance(const Duration(milliseconds: 199));
      expect(a.hub.peers.single.state, PeerState.found);
      await w.advance(const Duration(milliseconds: 1));
      expect(a.hub.peers.single.state, PeerState.ready);
      expect(b.hub.peers.single.state, PeerState.ready);
    });

    test('dial failures are retried on the injected backoff schedule, then give up', () async {
      final flaky = FlakyProvider(w.network.provider(), w.clock, failures: 99);
      final a = w.node('a', provider: flaky, options: PeerHubOptions(backoff: _Fixed([100, 200, 400])));
      await a.hub.start();
      await w.startedNode('b');
      await w.advance(const Duration(hours: 1));
      final t0 = flaky.attempts.first;
      expect(flaky.attempts.map((t) => t.difference(t0).inMilliseconds), [0, 100, 300, 700]);
      expect(a.hub.stats.dialFailures, 4);
      expect(a.hub.peers.single.state, PeerState.found, reason: 'gave up quietly; still known');
    });

    test('a few failures then success: the peer becomes ready on the schedule', () async {
      final flaky = FlakyProvider(w.network.provider(), w.clock, failures: 2);
      final a = w.node('a', provider: flaky, options: PeerHubOptions(backoff: _Fixed([100, 200, 400])));
      await a.hub.start();
      await w.startedNode('b');
      expect(a.hub.peers.single.state, PeerState.found);
      await w.advance(const Duration(milliseconds: 100));
      expect(a.hub.peers.single.state, PeerState.found);
      await w.advance(const Duration(milliseconds: 200));
      expect(a.hub.peers.single.state, PeerState.ready);
    });
  });

  group('backpressure', () {
    test('a congested link fills the bounded outbox and send FAILS with PeerOutboxFull', () async {
      final gate = GateProvider(w.network.provider());
      final a = await w.startedNode('a', provider: gate, options: const PeerHubOptions(outboxMessages: 3));
      final b = await w.startedNode('b');
      final p = a.hub.peers.single;
      gate.gated = true;
      final sends = [for (var i = 0; i < 4; i++) a.hub.send(p, bytes('m$i'))];
      await w.settle();
      expect(gate.sendsStarted, greaterThanOrEqualTo(1));
      await expectLater(a.hub.send(p, bytes('m4')), throwsA(isA<PeerOutboxFull>()));
      await expectLater(a.hub.request(p, bytes('r')), throwsA(isA<PeerOutboxFull>()));
      expect((await a.hub.broadcast(bytes('b'))).failed.keys, [b.hub.id]);
      expect(b.hook.messages, isEmpty);

      gate.release();
      await Future.wait(sends);
      await w.settle();
      expect(b.hook.texts, ['m0', 'm1', 'm2', 'm3'], reason: 'nothing queued was dropped, order kept');
      await a.hub.send(p, bytes('m5'));
      await w.settle();
      expect(b.hook.texts.last, 'm5');
    });

    test('the outbox is also bounded in bytes', () async {
      final gate = GateProvider(w.network.provider());
      final a = await w.startedNode('a', provider: gate, options: const PeerHubOptions(outboxBytes: 10));
      await w.startedNode('b');
      final p = a.hub.peers.single;
      gate.gated = true;
      final first = a.hub.send(p, bytes('123456')); // goes in flight, no longer queued
      final second = a.hub.send(p, bytes('123456')); // queued: 6 of 10
      await w.settle();
      await expectLater(a.hub.send(p, bytes('123456')), throwsA(isA<PeerOutboxFull>()));
      gate.release();
      await Future.wait([first, second]);
    });

    test('queued messages fail with PeerLost when the peer is lost', () async {
      final gate = GateProvider(w.network.provider());
      final a = await w.startedNode('a', provider: gate);
      final b = await w.startedNode('b');
      gate.gated = true;
      final p = a.hub.peers.single;
      final futures = [for (var i = 0; i < 3; i++) a.hub.send(p, bytes('m$i'))];
      final checks = [for (final f in futures.skip(1)) expectLater(f, throwsA(isA<PeerLost>()))];
      await w.settle();
      w.network.isolate(b.hub.id);
      await w.settle();
      gate.release();
      await Future.wait(checks);
      unawaited(futures.first.then((_) {}, onError: (_) {}));
    });
  });

  group('close', () {
    test('close says goodbye, is idempotent, and later use fails with PeerClosed', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b');
      final peerOfB = a.hub.peers.single;
      final f1 = a.hub.close();
      final f2 = a.hub.close();
      expect(identical(f1, f2), isTrue);
      await f1;
      await a.hub.close();
      await w.settle();

      expect(b.hook.events, ['found a@i1', 'ready a@i1', 'lost a@i1']);
      expect(b.hook.changes.last.$1.lostReason, 'goodbye');
      expect(b.hub.peers, isEmpty);
      expect(a.hook.events.last, 'lost b@i1');
      expect(peerOfB.state, PeerState.lost);
      await expectLater(a.hub.send(peerOfB, bytes('x')), throwsA(isA<PeerClosed>()));
      await expectLater(a.hub.start(), throwsA(isA<PeerClosed>()));
      expect(w.network.openLinkEnds, 0);
      expect(await a.hub.changes.isEmpty, isTrue, reason: 'the changes stream is closed');
    });

    test('closing the higher id: the dialer sees goodbye and does not redial', () async {
      final a = await w.startedNode('a');
      final b = await w.startedNode('b');
      final attempts = w.network.connectAttempts;
      await b.hub.close();
      await w.advance(const Duration(minutes: 2));
      expect(a.hook.changes.last.$1.lostReason, 'goodbye');
      expect(a.hub.peers, isEmpty);
      expect(w.network.connectAttempts, attempts);
    });

    test('close fails outstanding requests with PeerClosed', () async {
      final a = await w.startedNode('a');
      await w.startedNode('b');
      final f = a.hub.request(a.hub.peers.single, bytes('?'));
      final check = expectLater(f, throwsA(isA<PeerClosed>()));
      await a.hub.close();
      await check;
    });

    test('close before start, and a close with no peers, are fine', () async {
      final n = w.node('solo');
      await n.hub.close();
      final m = await w.startedNode('lone');
      await m.hub.close();
    });
  });

  group('hooks that misbehave', () {
    test('onMessage throwing is counted and does not stop later messages', () async {
      final a = await w.startedNode('a');
      var first = true;
      final b = await w.startedNode('b', hook: RecordingHook(onMessageFn: (f, m) {
        if (first) {
          first = false;
          throw StateError('app bug');
        }
      }));
      await a.hub.send(a.hub.peers.single, bytes('one'));
      await a.hub.send(a.hub.peers.single, bytes('two'));
      await w.settle();
      expect(b.hook.texts, ['one', 'two']);
      expect(b.hub.stats.hookErrors, 1);
      expect(b.hub.peers.single.state, PeerState.ready);
    });
  });
}

/// A backoff with an explicit schedule in milliseconds, then null (give up).
class _Fixed implements Backoff {
  _Fixed(this.ms);
  final List<int> ms;
  @override
  Duration? delay(int attempt) => attempt < ms.length ? Duration(milliseconds: ms[attempt]) : null;
}
