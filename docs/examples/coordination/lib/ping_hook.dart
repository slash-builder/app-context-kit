import 'dart:async';

import 'package:app_context_kit/app_context_kit.dart';

/// A complete coordination hook: the five jobs, and nothing else.
///
/// "ping": any copy can ask another copy "are you there?", and the other copy answers with its device name.
class PingHook extends AppCoordination {
  PeerHub? hub;

  /// Peer changes as the Kit reported them, e.g. "ready desktop".
  final List<String> events = [];

  /// Messages this hook did not understand. A hook counts these instead of throwing.
  int ignored = 0;

  // 1. Which conversation inside the app this hook owns.
  @override
  String get channel => 'ping';

  // The Kit hands the hook its hub once, from PeerHub.start().
  @override
  void attach(PeerHub hub) => this.hub = hub;

  // 2. What to tell a peer when a link opens. Any JSON-encodable value.
  @override
  Object? hello() => {'proto': 1};

  // 3. Whether to talk to this peer, given what it said in its hello.
  @override
  FutureOr<Admit> admit(Peer peer, Object? theirHello) =>
      theirHello is Map && theirHello['proto'] == 1
          ? const Admit.accept()
          : const Admit.reject('ping protocol 1 only');

  // 4. A peer was found, became ready, or was lost.
  @override
  void onPeer(Peer peer, PeerChange change) =>
      events.add('${change.name} ${peer.id.device}');

  // 5. The app's meaning lives here. Answer a ping; count anything else.
  @override
  void onMessage(Peer from, AppMessage message) {
    if (message.kind == 'ping' && message.schema == 1 && message.requestId != null) {
      PeerJson.quiet(hub!.reply(message, PeerJson.encode({'pong': hub!.device}), schema: 1));
    } else {
      ignored++;
    }
  }

  /// Ask [peer] if it is there. Returns the name it answered with, or null for an answer in the wrong shape.
  /// Throws a PeerError (PeerTimeout, PeerLost, ...) if there is no answer.
  Future<String?> ping(Peer peer) async {
    final reply = await hub!.request(peer, PeerJson.encode({'n': 1}), kind: 'ping', schema: 1);
    final body = reply.jsonBody;
    return body is Map && body['pong'] is String ? body['pong'] as String : null;
  }
}
