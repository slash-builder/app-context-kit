/// Value types for peer coordination (spec/APP-CONTEXT.md section 6).
///
/// Nothing in here interprets an app payload. The Kit owns identity, scope and
/// state; the app owns meaning.
library;

import 'dart:typed_data';

/// Which running copy of an app: the device it runs on and a per-process
/// instance id (two copies on one device are two peers).
class PeerId implements Comparable<PeerId> {
  const PeerId(this.device, this.instance);
  /// The device the copy runs on, for example `laptop`.
  final String device;
  /// This copy's instance id (the context's [AppContext.instance] when a hub is built by `ctx.peerHub`).
  final String instance;

  @override
  bool operator ==(Object other) => other is PeerId && other.device == device && other.instance == instance;

  @override
  int get hashCode => Object.hash(device, instance);

  @override
  int compareTo(PeerId other) {
    final d = device.compareTo(other.device);
    return d != 0 ? d : instance.compareTo(other.instance);
  }

  /// `device@instance`, the display form (and the loopback file stem).
  @override
  String toString() => '$device@$instance';
}

/// A full identity claim: the scope key `(account, app)` plus the [PeerId].
///
/// A link or a candidate carries this as a *claim*. The hub checks it against
/// what the peer says in its hello and against the authenticator's proof.
class PeerIdentity {
  const PeerIdentity(this.account, this.app, this.id);
  /// The account the copy says it belongs to.
  final String account;
  /// The app id the copy says it is.
  final String app;
  /// Which copy: its device and instance.
  final PeerId id;

  /// The device part of [id].
  String get device => id.device;
  /// The instance part of [id].
  String get instance => id.instance;

  /// True when [other] is in the same scope: same account AND same app id.
  bool sameScope(PeerIdentity other) => account == other.account && app == other.app;

  @override
  bool operator ==(Object other) => other is PeerIdentity && other.account == account && other.app == app && other.id == id;

  @override
  int get hashCode => Object.hash(account, app, id);

  @override
  String toString() => '$account/$app/$id';
}

/// What a provider offers: an identity plus an opaque, provider-specific
/// [address] (a loopback port, a fake-network key, later a hub topic).
///
/// A provider announces departure with `available: false`.
class PeerCandidate {
  const PeerCandidate(this.identity, this.address, {this.available = true});
  /// Who the provider says this candidate is.
  final PeerIdentity identity;
  /// Where to reach it, in the provider's own terms. The Kit never reads it.
  final String address;
  /// False when the provider is announcing that the candidate has gone.
  final bool available;

  /// The candidate's [PeerId].
  PeerId get id => identity.id;

  /// The same candidate marked `available: false`.
  PeerCandidate withdrawn() => PeerCandidate(identity, address, available: false);

  @override
  String toString() => 'PeerCandidate($identity @ $address${available ? '' : ', withdrawn'})';
}

/// The lifecycle of one [Peer] object. A peer object is never reused: a copy
/// that goes away and comes back is a new [Peer] (same [PeerId]).
///
/// `found -> connecting -> ready -> lost`, or `found/connecting -> rejected`.
enum PeerState { found, connecting, ready, rejected, lost }

/// The three transitions the app hook hears about.
enum PeerChange { found, ready, lost }

/// A remote copy of the same app, as the Kit sees it. Read-only to apps; the
/// hub owns the state.
abstract interface class Peer {
  /// Which copy this is: its device and instance.
  PeerId get id;
  /// The account the peer belongs to. Always the same as this copy's.
  String get account;
  /// The app id the peer runs. Always the same as this copy's.
  String get app;

  /// The hello the peer sent on connect (decoded JSON, opaque to the Kit);
  /// null until received, and null if the peer sent null.
  Object? get hello;
  /// Where this peer is in its life; see [PeerState].
  PeerState get state;

  /// True when the app's `admit` said [Admit.acceptReadOnly]. The Kit only
  /// tags it; the hook decides what read-only means for its own messages.
  bool get readOnly;

  /// Why this peer was rejected (by us, or by them, prefixed "rejected by peer").
  String? get rejectReason;

  /// Why the link ended (`goodbye`, `link closed`, `hub closed`, ...).
  String? get lostReason;
}

/// A change in the peers view, as emitted on `PeerHub.changes`.
class PeerEvent {
  const PeerEvent(this.peer, this.change);
  /// The peer that changed.
  final Peer peer;
  /// What happened to it.
  final PeerChange change;

  @override
  String toString() => 'PeerEvent(${peer.id} $change)';
}

enum AdmitKind { accept, acceptReadOnly, reject }

/// The app's answer to "do you want this peer?".
class Admit {
  /// Talk to the peer normally.
  const Admit.accept()
      : kind = AdmitKind.accept,
        reason = null;
  /// Talk to the peer, and tag it [Peer.readOnly]. The Kit does not filter anything for it.
  const Admit.acceptReadOnly()
      : kind = AdmitKind.acceptReadOnly,
        reason = null;
  /// Refuse the peer. [reason] is sent to it, capped at 256 characters.
  const Admit.reject(String this.reason) : kind = AdmitKind.reject;

  /// The answer.
  final AdmitKind kind;

  /// Set only for [AdmitKind.reject]; it is sent to the peer (capped at 256 chars).
  final String? reason;

  /// True for [AdmitKind.accept] and [AdmitKind.acceptReadOnly].
  bool get accepted => kind != AdmitKind.reject;

  @override
  String toString() => reason == null ? 'Admit.${kind.name}' : 'Admit.reject($reason)';
}

/// What the app receives. The payload is opaque bytes; [schema] is the
/// app-declared integer (the Kit never looks at either).
class AppMessage {
  const AppMessage({
    required this.from,
    required this.channel,
    required this.seq,
    required this.kind,
    required this.schema,
    required this.payload,
    this.requestId,
  });

  /// The sending copy.
  final PeerId from;
  /// The channel the message was sent on.
  final String channel;

  /// Per-sender, per-link sequence number (starts at 1 on every new link; a gap
  /// means a frame was lost or skipped). Useful to apps that want to detect loss.
  final int seq;

  /// App-defined message type. Kinds starting with `kit.` are reserved.
  final String kind;
  /// The sender's payload schema version. The Kit carries it and never reads it.
  final int schema;
  /// The app's bytes, exactly as sent.
  final Uint8List payload;

  /// Non-null when the sender used `request(...)`: answer with `hub.reply`.
  final int? requestId;

  @override
  String toString() => 'AppMessage($from #$seq $kind v$schema ${payload.length}B${requestId == null ? '' : ' rid=$requestId'})';
}

/// Reserved kinds. The `kit.` prefix belongs to the Kit; apps cannot send it.
abstract final class PeerKinds {
  /// Kinds starting with this belong to the Kit; an app cannot send them.
  static const reservedPrefix = 'kit.';
  /// The kind used when an app does not name one.
  static const defaultKind = 'msg';
  /// Handshake: who the sender is and its app-defined hello.
  static const hello = 'kit.hello';
  /// Handshake: the authenticator's challenge or proof.
  static const auth = 'kit.auth';
  /// Handshake: the sender accepts the peer; the link is ready.
  static const ready = 'kit.ready';
  /// Handshake: the sender refuses the peer. The payload carries the reason.
  static const reject = 'kit.reject';
  /// The sender is closing the link.
  static const bye = 'kit.bye';
  /// The answer to a request, sent with `hub.reply`.
  static const reply = 'kit.reply';
}

/// Base of every typed failure in this layer.
class PeerError implements Exception {
  PeerError(this.message);
  /// What went wrong, in a sentence.
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// An envelope that could not be encoded or decoded (malformed, oversized, ...).
class EnvelopeError extends PeerError {
  EnvelopeError(super.message);
}

/// The peer is unknown, rejected or lost (or the [Peer] object is a stale one).
class PeerNotAvailable extends PeerError {
  PeerNotAvailable(super.message);
}

/// The link or peer went away while a message or request was outstanding.
class PeerLost extends PeerError {
  PeerLost(super.message);
}

/// The bounded outbox for a peer is full. The Kit fails the send instead of
/// dropping an older message silently: the app knows what is safe to drop.
class PeerOutboxFull extends PeerError {
  PeerOutboxFull(super.message);
}

/// A request got no reply in time.
class PeerTimeout extends PeerError {
  PeerTimeout(super.message);
}

/// The hub was closed.
class PeerClosed extends PeerError {
  PeerClosed(super.message);
}

/// A different account or app id was involved. Such peers are never connected.
class PeerScopeError extends PeerError {
  PeerScopeError(super.message);
}

/// A provider could not reach the candidate.
class PeerConnectError extends PeerError {
  PeerConnectError(super.message);
}

/// A send on a link that has been closed.
class PeerLinkClosed extends PeerError {
  PeerLinkClosed(super.message);
}
