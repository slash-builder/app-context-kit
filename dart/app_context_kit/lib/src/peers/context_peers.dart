/// The bridge between an [AppContext] and the peer hub: who this copy is (account, device, instance), which provider
/// to use for the current mode, and the manifest gate that makes "peers" an opt-in Kit.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../app_context.dart';
import '../config_store.dart';
import 'auth.dart';
import 'coordination.dart';
import 'fake_network.dart';
import 'hub.dart';
import 'loopback_provider.dart';
import 'provider.dart';

/// The kit name an app lists in `app.json` `kits` to use peers.
const String peersKitName = 'peers';

/// Thrown when an app asks for peers without declaring the Kit in its manifest.
class KitNotDeclared implements Exception {
  KitNotDeclared(this.kit, this.appId);
  /// The kit that was asked for (`peers`).
  final String kit;
  /// The app whose manifest does not list it.
  final String appId;
  @override
  String toString() => 'KitNotDeclared: $appId uses "$kit" but its app.json "kits" does not list it';
}

/// Peer coordination for an [AppContext]: who this copy is ([peerAccount], [peerDevice]) and how to build a hub ([startPeers], [peerHub]).
extension AppContextPeers on AppContext {
  /// `APP_CONTEXT_ACCOUNT`, else config `account`, else `local` (a single-user machine with no household account yet).
  String get peerAccount {
    final e = env['APP_CONTEXT_ACCOUNT'];
    if (e != null && e.isNotEmpty) return e;
    return config.get<String>('account', 'local');
  }

  /// `APP_CONTEXT_DEVICE`, else config `device`; generated once (`d-` plus 8 hex digits) and saved, or ephemeral if the
  /// settings file is damaged (a damaged file is never overwritten).
  String get peerDevice {
    final e = env['APP_CONTEXT_DEVICE'];
    if (e != null && e.isNotEmpty) return e;
    final saved = config.get<String>('device', '');
    if (saved.isNotEmpty) return saved;
    final r = math.Random.secure();
    final id = 'd-${List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join()}';
    try {
      config.set('device', id);
    } on DamagedConfigError {
      // keep it for this run only
    }
    return id;
  }

  /// Where loopback peers announce themselves: `APP_CONTEXT_PEERS_DIR`, else the roster directory plus `-peers`.
  String get peersDirectory {
    final e = env['APP_CONTEXT_PEERS_DIR'];
    if (e != null && e.isNotEmpty) return e;
    return '${roster.dir}-peers';
  }

  /// Builds (does not start) a [PeerHub] for this copy of the app.
  ///
  /// The provider is, in order: the one passed; the fake network passed (or a private one) in mock mode; otherwise a
  /// [LoopbackProvider] over [peersDirectory]. The app must list `"peers"` in `app.json` `kits`.
  PeerHub peerHub(
    AppCoordination hook, {
    PeerProvider? provider,
    FakePeerNetwork? network,
    PeerAuthenticator? authenticator,
    PeerHubOptions options = const PeerHubOptions(),
  }) {
    final hub =
        _buildHub(this, hook, provider, network, authenticator, options);
    onClose(hub.close);
    return hub;
  }

  /// Builds AND starts a hub for [hook], and never throws for a runtime condition: an unwritable peers directory or a
  /// provider that fails to open becomes [PeersHandle.error], and the app carries on alone.
  ///
  /// [KitNotDeclared] (the manifest does not list `"peers"`) is NOT swallowed: that is a bug in the app, not something
  /// that happens to a person. The call returns at once; [PeersHandle.started] completes when the hub is open or has
  /// failed, and [PeersHandle.changes] fires on that and on every peer change, so a widget can rebuild.
  ///
  /// The hub is closed with the context (a close that fails on a hub which never opened is not reported). Takes the same
  /// [network] and [options] as [peerHub]; use [peerHub] when you need a custom provider or authenticator.
  PeersHandle startPeers(
    AppCoordination hook, {
    FakePeerNetwork? network,
    PeerHubOptions options = const PeerHubOptions(),
  }) {
    final handle = PeersHandle._();
    final PeerHub hub;
    try {
      hub = _buildHub(this, hook, null, network, null, options);
    } on KitNotDeclared {
      rethrow;
    } on FileSystemException catch (e) {
      handle._settle(
          error:
              'peers unavailable: ${e.message}${e.path == null || e.path!.isEmpty ? '' : ' (${e.path})'}');
      onClose(handle._shutdown);
      return handle;
    } on Exception catch (e) {
      handle._settle(error: 'peers unavailable: $e');
      onClose(handle._shutdown);
      return handle;
    }
    handle._hub = hub;
    handle._watch(hub);
    handle._started = _open(hub, handle);
    onClose(() async {
      // Close the hub first (it ends its own change stream), then the handle's, even if the close fails.
      try {
        await hub.close();
      } catch (_) {
        // A hub that never opened may fail to close; that is already in handle.error. A healthy one is the app's to hear about.
        if (handle.error == null) rethrow;
      } finally {
        await handle._shutdown();
      }
    });
    return handle;
  }

  static Future<void> _open(PeerHub hub, PeersHandle handle) async {
    try {
      await hub.start();
      handle._settle();
    } catch (e) {
      handle._settle(error: 'peers unavailable: $e', dropHub: true);
      try {
        await hub.close(); // release whatever the provider half-opened
      } catch (_) {}
    }
  }
}

PeerHub _buildHub(
    AppContext ctx,
    AppCoordination hook,
    PeerProvider? provider,
    FakePeerNetwork? network,
    PeerAuthenticator? authenticator,
    PeerHubOptions options) {
  if (!ctx.manifest.kits.contains(peersKitName)) throw KitNotDeclared(peersKitName, ctx.manifest.id);
  final PeerProvider p = provider ??
      (ctx.isMock
          ? (network ?? FakePeerNetwork()).provider()
          : LoopbackProvider(directory: _ensure(ctx.peersDirectory)));
  return PeerHub(
    account: ctx.peerAccount,
    app: ctx.manifest.id,
    device: ctx.peerDevice,
    instance: ctx.instance,
    provider: p,
    hook: hook,
    authenticator: authenticator,
    options: options,
  );
}

String _ensure(String dir) {
  Directory(dir).createSync(recursive: true);
  return dir;
}

/// A peer hub that was built and started for an app which must keep working when peers do not. Made by
/// [AppContextPeers.startPeers]; closed with the context.
///
/// Nothing here throws at the app. Read [error], [hub] and [changes] and carry on.
class PeersHandle {
  PeersHandle._() : _changes = StreamController<void>.broadcast();

  PeerHub? _hub;
  String? _error;
  bool _settled = false;
  final StreamController<void> _changes;
  StreamSubscription<Object?>? _hubSub;

  /// The hub, or null when peers are unavailable (it could not be built, or it failed to open: see [error]).
  ///
  /// It is non-null while the hub is still opening ([isStarting]); sending then simply finds no peers. If opening fails
  /// the hub is closed and this becomes null, so `handle.hub?.broadcast(...)` is always safe.
  PeerHub? get hub => _hub;

  /// Completes when the hub is open or has failed to open. Never completes with an error.
  Future<void> get started => _started;
  Future<void> _started = Future<void>.value();

  /// Why peers are unavailable, as a sentence starting `peers unavailable: `. Null while all is well, including while starting.
  String? get error => _error;

  /// True until [started] completes.
  bool get isStarting => !_settled;

  /// True when the hub is open and there is no error.
  bool get isRunning => _settled && _error == null && _hub != null;

  /// Fires (with no data) whenever something an indicator would show changed: the hub opened or failed, or a peer was
  /// found, became ready or was lost. A broadcast stream that ends when the context closes.
  Stream<void> get changes => _changes.stream;

  void _watch(PeerHub hub) {
    _hubSub = hub.changes.listen((_) => _notify(), onError: (Object _) {});
  }

  void _settle({String? error, bool dropHub = false}) {
    _settled = true;
    if (error != null) _error = error;
    if (dropHub) _hub = null;
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _shutdown() async {
    await _hubSub?.cancel();
    _hubSub = null;
    if (!_changes.isClosed) await _changes.close();
  }
}
