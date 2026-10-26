/// The app's side of coordination: the hook.
///
/// The Kit finds, authenticates, connects and routes; the app says what that
/// means. Five jobs, none of which the Kit interprets:
///
///  1. [channel]: which conversation inside the app this hook owns.
///  2. [hello]: what to tell a peer on connect (a JSON-encodable value).
///  3. [admit]: whether to talk to a peer, given its hello.
///  4. [onPeer]: a peer was found, became ready, or was lost.
///  5. [onMessage]: the app's meaning lives here.
///
/// One hook serves one hub, and one hub serves one channel.
library;

import 'dart:async';

import 'hub.dart';
import 'types.dart';

/// The app's side of coordination. Implement it and pass it to `ctx.startPeers` or `ctx.peerHub`.
abstract class AppCoordination {
  /// Scope within the app, e.g. `"default"` or `"game"`. Peers on a different
  /// channel are rejected at the handshake.
  String get channel;

  /// Called once per connection attempt (so it can describe *current* state:
  /// "game in progress", the note's version). Must be JSON-encodable; the Kit
  /// carries it and never reads it. Return null to say nothing.
  Object? hello();

  /// Called once per connection after the Kit has checked identity, with the
  /// peer's decoded hello. May be async (a pairing prompt, a storage lookup);
  /// the link waits.
  ///
  /// [Admit.acceptReadOnly] only tags `peer.readOnly`. The Kit does not drop or
  /// filter anything for a read-only peer; the hook decides what read-only
  /// means (e.g. ignore that peer's write messages in [onMessage]).
  FutureOr<Admit> admit(Peer peer, Object? theirHello);

  /// A peer was found, became ready, or was lost. Runs before the same event
  /// appears on `PeerHub.changes`.
  void onPeer(Peer peer, PeerChange change);

  /// A message from a ready peer, in per-sender `seq` order, once. Synchronous
  /// on purpose: the hub processes one link's frames one at a time, so an app
  /// that does async work here must queue it itself.
  void onMessage(Peer from, AppMessage message);

  /// Called once by `PeerHub.start()` so the hook can reach the management
  /// interface (send, broadcast, request, reply, peers) without a late-bound
  /// field. Not one of the five jobs; the default does nothing.
  void attach(PeerHub hub) {}
}
