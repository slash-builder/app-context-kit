/// How peers are found and carried. The hub talks only to these two interfaces,
/// so the same hook works over the fake network, loopback, and (later) a LAN or
/// Hearth transport.
library;

import 'dart:async';
import 'dart:typed_data';

import 'types.dart';

/// One bidirectional, ordered, message-framed connection to one remote copy.
///
/// [send] takes one whole message; the link delivers it as one event on the
/// remote [inbound] (framing is the provider's job). Delivery may be lossy
/// (fake network faults); the hub copes with that.
abstract interface class PeerLink {
  /// Who the provider says is at the other end. A claim: the hub checks it
  /// against the hello header and the authenticator's proof, and drops the link
  /// if the scope differs from its own.
  PeerIdentity get remote;

  /// Single-subscription; buffers until listened to; completes when the link ends.
  Stream<Uint8List> get inbound;

  /// Completes when the transport has accepted [bytes] (not when the peer got
  /// them). May stay pending while the transport is congested; the hub's bounded
  /// outbox is what stops that growing without limit.
  Future<void> send(Uint8List bytes);

  /// Idempotent. Pending sends are flushed best effort.
  Future<void> close();
}

/// How peers are found and carried. The Kit ships a fake (`FakePeerNetwork.provider()`) and a loopback provider.
abstract interface class PeerProvider {
  /// Announce [self] and start accepting. Called once, before the other members.
  ///
  /// Added to the sketch's three members: a provider has to know who it is to
  /// announce itself (loopback writes a file) and to enforce the scope key.
  Future<void> open(PeerIdentity self);

  /// Candidates in the same scope as `self` (same account AND app id), never
  /// `self`. Replays what is currently known, then follows changes; a candidate
  /// that goes away is re-emitted with `available: false`. Providers MUST NOT
  /// offer a candidate from another account or app.
  Stream<PeerCandidate> discover();

  /// Dial [c]. Throws [PeerScopeError] for a candidate outside the scope and
  /// [PeerConnectError] when it cannot be reached.
  Future<PeerLink> connect(PeerCandidate c);

  /// Links dialed by remote peers. Providers MUST NOT emit a link whose
  /// `remote` is outside the scope. Single-subscription, buffers until listened to.
  Stream<PeerLink> get incoming;

  /// Withdraw the announcement and close everything. Idempotent.
  Future<void> close();
}
