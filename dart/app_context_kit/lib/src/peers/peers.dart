/// Peer coordination between copies of the same app.
/// See spec/APP-CONTEXT.md section 6. The parent adds `export 'src/peers/peers.dart';`
/// to `lib/app_context_kit.dart`.
library;

export 'auth.dart';
export 'clock.dart';
export 'coordination.dart';
export 'envelope.dart';
export 'fake_network.dart';
export 'hub.dart' show BroadcastResult, PeerHub, PeerHubOptions, PeerHubStats;
export 'loopback_provider.dart' show FrameDecoder, LoopbackProvider;
export 'provider.dart';
export 'types.dart';
export 'context_peers.dart';
export 'peer_json.dart';
