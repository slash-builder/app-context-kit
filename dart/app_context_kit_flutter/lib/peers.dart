/// Peer UI for apps that use the Kit's peers (`ctx.startPeers` / `ctx.peerHub`).
///
/// Its own library, not part of `app_context_kit_flutter.dart`: an app that still has its own `PeersIndicator` in
/// `lib/kit_gaps/` imports both and would get an ambiguous name. Once that copy is deleted, import this.
library;

export 'src/peers_indicator.dart';
