/// Injectable time for the peer layer: every timeout, backoff and fake-network
/// latency goes through a [PeerClock], so tests are deterministic and fast.
library;

import 'dart:async';
import 'dart:math' as math;

/// A scheduled callback that can be cancelled.
abstract interface class PeerTimer {
  /// Stops the callback from running, if it has not already.
  void cancel();
}

/// The time source for the peer layer: the current time, and one-shot timers.
abstract interface class PeerClock {
  /// The current time, in UTC.
  DateTime now();

  /// Runs [callback] once after [delay].
  PeerTimer schedule(Duration delay, void Function() callback);
}

/// Wall-clock time and real [Timer]s. The default.
class SystemPeerClock implements PeerClock {
  const SystemPeerClock();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  PeerTimer schedule(Duration delay, void Function() callback) => _SystemTimer(Timer(delay, callback));
}

class _SystemTimer implements PeerTimer {
  _SystemTimer(this._t);
  final Timer _t;
  @override
  void cancel() => _t.cancel();
}

/// A clock that only moves when the test says so. Timers fire in (due time,
/// creation order) order, and between firings the event loop is given a few
/// turns so streams and futures settle, which is what makes tests deterministic.
class ManualPeerClock implements PeerClock {
  ManualPeerClock([DateTime? start]) : _now = (start ?? DateTime.utc(2026, 1, 1)).toUtc();

  DateTime _now;
  final List<_ManualTimer> _timers = [];
  int _order = 0;

  @override
  DateTime now() => _now;

  @override
  PeerTimer schedule(Duration delay, void Function() callback) {
    final t = _ManualTimer(_now.add(delay), _order++, callback);
    _timers.add(t);
    return t;
  }

  /// Timers that have not fired and have not been cancelled.
  int get pendingTimers => _timers.where((t) => !t.done).length;

  /// Lets queued microtasks and zero-delay events run (streams, futures).
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Moves time forward by [by], firing every timer that falls due on the way.
  Future<void> advance(Duration by) async {
    final target = _now.add(by);
    await settle();
    while (true) {
      final due = _timers.where((t) => !t.done && !t.due.isAfter(target)).toList()
        ..sort((a, b) {
          final c = a.due.compareTo(b.due);
          return c != 0 ? c : a.order.compareTo(b.order);
        });
      if (due.isEmpty) break;
      final t = due.first;
      if (t.due.isAfter(_now)) _now = t.due;
      t.done = true;
      _timers.remove(t);
      t.callback();
      await settle();
    }
    _now = target;
    await settle();
  }
}

class _ManualTimer implements PeerTimer {
  _ManualTimer(this.due, this.order, this.callback);
  final DateTime due;
  final int order;
  final void Function() callback;
  bool done = false;

  @override
  void cancel() => done = true;
}

/// How long to wait before retry number `attempt` (0 = the first retry), or
/// null to give up until the provider announces the candidate again.
abstract interface class Backoff {
  Duration? delay(int attempt);
}

/// `initial * factor^attempt`, capped at [max], giving up after [maxAttempts].
/// No jitter by default so schedules are predictable; inject your own for that.
class ExponentialBackoff implements Backoff {
  const ExponentialBackoff({
    this.initial = const Duration(milliseconds: 200),
    this.max = const Duration(seconds: 5),
    this.factor = 2.0,
    this.maxAttempts = 10,
  });

  /// The wait before the first retry.
  final Duration initial;
  /// The longest wait between retries.
  final Duration max;
  /// Each wait is the previous one times this.
  final double factor;
  /// How many retries before giving up until the provider announces the candidate again.
  final int maxAttempts;

  @override
  Duration? delay(int attempt) {
    if (attempt >= maxAttempts) return null;
    final micros = initial.inMicroseconds * math.pow(factor, attempt);
    return Duration(microseconds: math.min(micros, max.inMicroseconds.toDouble()).round());
  }
}
