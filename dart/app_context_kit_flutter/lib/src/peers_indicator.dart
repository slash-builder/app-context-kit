import 'dart:async';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:flutter/material.dart';

/// Who this copy is talking to: "This copy: laptop #3fa2", "Peers: 2" with one chip per connected copy ("phone #9c01"), and
/// "(1 connecting)" for copies that are found but not yet ready. When peers are unavailable it says so and why
/// ("Peers: off (peers unavailable: ...)"), so a person using the app alone can see why it is alone.
///
/// Give it what `ctx.startPeers(hook)` returned ([PeersIndicator.forHandle]; it follows the hub opening or failing) or a
/// hub you built yourself ([PeersIndicator.new]). It rebuilds itself on every change. Plain Material.
///
/// Accessible: the whole indicator is ONE live region read as a sentence ("This copy laptop #3fa2. 2 peers connected: ...
/// 1 connecting."), and an unavailable state is words plus an icon, never colour alone.
///
/// Import it from `package:app_context_kit_flutter/peers.dart`.
class PeersIndicator extends StatefulWidget {
  /// For a hub you built yourself. A null [hub] is the "peers are off" state, with [offlineReason] as the why.
  const PeersIndicator({super.key, required PeerHub? hub, this.offlineReason, this.extra})
      : _hub = hub,
        _handle = null;

  /// For the result of `ctx.startPeers(hook)`.
  const PeersIndicator.forHandle(PeersHandle handle, {super.key, this.extra})
      : _handle = handle,
        _hub = null,
        offlineReason = null;

  final PeerHub? _hub;
  final PeersHandle? _handle;

  /// Why peers are off when [PeersIndicator.new] was given no hub. Ignored with a handle (its `error` is used).
  final String? offlineReason;

  /// A line the app wants shown under the chips (a notice such as "Timer finished on laptop").
  final String? extra;

  @override
  State<PeersIndicator> createState() => _PeersIndicatorState();
}

class _PeersIndicatorState extends State<PeersIndicator> {
  StreamSubscription<void>? _sub;

  Stream<void>? _changesOf(PeersIndicator w) {
    final handle = w._handle;
    if (handle != null) return handle.changes;
    return w._hub?.changes.map<void>((_) {});
  }

  void _listen() {
    _sub = _changesOf(widget)?.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(PeersIndicator old) {
    super.didUpdateWidget(old);
    if (!identical(old._hub, widget._hub) || !identical(old._handle, widget._handle)) {
      _sub?.cancel();
      _listen();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final handle = widget._handle;
    final hub = handle != null ? handle.hub : widget._hub;
    final offlineReason = handle != null ? handle.error : widget.offlineReason;
    final extra = widget.extra;
    if (hub == null || hub.isClosed) {
      final text = 'Peers: off${offlineReason == null ? '' : ' ($offlineReason)'}';
      return Semantics(
        container: true,
        liveRegion: true,
        excludeSemantics: true,
        label: text.replaceFirst('Peers: off', 'Peers are off'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.link_off, size: 16),
            const SizedBox(width: 6),
            Flexible(child: Text(text, key: const ValueKey('peers-offline'))),
          ]),
        ),
      );
    }
    final ready = hub.readyPeers;
    final other = hub.peers.where((p) => p.state != PeerState.ready).length;
    final self = PeerJson.label(hub.id);
    final summary = [
      'This copy $self.',
      ready.isEmpty ? 'No peers connected.' : '${ready.length} ${ready.length == 1 ? 'peer' : 'peers'} connected: ${ready.map((p) => PeerJson.label(p.id)).join(', ')}.',
      if (other > 0) '$other connecting.',
      if (extra != null) extra,
    ].join(' ');
    return Semantics(
      container: true,
      liveRegion: true,
      excludeSemantics: true,
      label: summary,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('This copy: $self', key: const ValueKey('peers-self')),
          Text('Peers: ${ready.length}', key: const ValueKey('peers-count')),
          for (final p in ready)
            Chip(key: ValueKey('peer-${p.id}'), label: Text(PeerJson.label(p.id)), visualDensity: VisualDensity.compact),
          if (other > 0) Text('($other connecting)', key: const ValueKey('peers-connecting')),
          if (extra != null) Text(extra, key: const ValueKey('peers-extra')),
        ]),
      ),
    );
  }
}
