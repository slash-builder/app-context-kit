import 'dart:async';
import 'dart:convert';

import 'transport.dart';

/// What an app asks Venue for: a named piece of work needing a capability (a ContractClass) with parameters.
class VenueNeed {
  const VenueNeed({required this.name, required this.contractClass, this.parameters = const {}});
  /// The need's name. It becomes the hold's name, which identifies the hold to Venue, so keep it unique among this consumer's live holds.
  final String name;
  /// The capability being asked for, for example `container.run.v1`.
  final String contractClass;
  /// Parameters for the request. Venue, not the Kit, defines what they mean.
  final Map<String, Object> parameters;

  /// The Placement document the daemon takes (JSON is accepted as YAML).
  Map<String, Object?> toPlacement(String consumer) => {
        'apiVersion': 'node.slashbuilder.com/v1alpha1',
        'kind': 'Placement',
        'metadata': {'name': name},
        'spec': {
          'principal': {'name': consumer},
          'claims': [
            {
              'name': 'g',
              'contractClaimSpec': {
                'requests': [
                  {'name': 'r', 'exactly': {'contractClassName': contractClass}, 'parameters': parameters}
                ]
              }
            }
          ]
        }
      };
}

/// A lease on something Venue granted, held by this consumer. Its flags change as the hold moves through its life.
class VenueHold {
  VenueHold(this.name, this.where, this.expiresAt);
  /// The hold's name.
  final String name;
  /// Where the hold lives: `local`, `fake` or `venue`.
  final String where; // local | fake | venue
  /// When the lease lapses unless renewed; null when the session does not say.
  DateTime? expiresAt;
  /// True once [VenueSession.start] has been called for this hold.
  bool started = false;
  /// True once the hold has been released, or found already gone.
  bool released = false;

  /// How many background renewals have failed, and the most recent failure. Recorded by [VenueSession.withHold];
  /// a renewal failure is never swallowed (spec section 5 item 7).
  int renewalFailures = 0;
  /// The most recent renewal failure; see [renewalFailures].
  Object? lastRenewalError;

  /// True once any renewal has failed: the Kit can no longer vouch for the lease. Latched; the app decides what to do
  /// (usually: stop the work). [VenueSession.withHold] also fires its `onLeaseLost` callback, once, when this first becomes true.
  bool leaseLost = false;

  /// Set when releasing this hold failed. A failing release never replaces the body's result or error, so it lands here.
  Object? releaseError;
}

/// Why Venue refused a request. Venue gives no machine-readable reason beyond the HTTP status (see [VenueRefusalKind]).
enum VenueRefusalKind {
  /// HTTP 409: nothing fits right now. Retrying later can succeed.
  doesNotFit,

  /// HTTP 403: not allowed (the live-hold limit, a missing grant, an observer token...). Venue gives these all the same
  /// code, so the Kit cannot tell the limit from the rest: a finding for the Venue project. Treated as not retryable.
  forbidden,
}

/// Venue understood the request and said no.
class VenueRefused implements Exception {
  VenueRefused(this.reason, {required this.kind});
  /// Venue's reason: for the real daemon, its raw response body. See [plainReason].
  final String reason;
  /// Why Venue refused. See [VenueRefusalKind].
  final VenueRefusalKind kind;

  /// Whether asking again later can reasonably succeed: only [VenueRefusalKind.doesNotFit].
  bool get retryable => kind == VenueRefusalKind.doesNotFit;

  /// [reason] as a sentence a person can read. The real daemon's reason is its raw response body
  /// (`{"error":{"code":"forbidden","message":"..."}}`, up to 300 characters); this is that `error.message`, or [reason]
  /// itself when it is not in that shape.
  String get plainReason {
    try {
      final j = jsonDecode(reason);
      final m = j is Map && j['error'] is Map ? (j['error'] as Map)['message'] : null;
      if (m is String && m.isNotEmpty) return m;
    } on FormatException {
      // not JSON: the reason is already text
    }
    return reason;
  }
  @override
  String toString() => 'VenueRefused(${kind.name}: $reason)';
}

/// Venue could not be asked, or answered in a way that is neither success nor a refusal: a transport failure, a
/// timeout, 401, 5xx, a lapsed hold.
class VenueUnavailable implements Exception {
  VenueUnavailable(this.reason, {this.status});
  /// What went wrong, in a sentence.
  final String reason;

  /// The HTTP status, when there was an answer.
  final int? status;
  @override
  String toString() => 'VenueUnavailable($reason)';
}

/// The one thing an app sees of Venue. The same calls work whether Venue is real, absent or faked,
/// so app code does not branch (the way a lease type in a larger app can hide local versus Venue).
abstract class VenueSession {
  /// `local`, `fake` or `venue`.
  String get kind;
  /// True only for a session connected to a real Venue ([kind] is `venue`).
  bool get isConnected => kind == 'venue';

  /// One plain sentence, e.g. "Venue: local (not configured)".
  String get description;

  /// Asks Venue for [need] and returns the hold, which lapses after [leaseSeconds] unless renewed.
  /// Throws [VenueRefused] when Venue says no and [VenueUnavailable] when it cannot be asked.
  Future<VenueHold> hold(VenueNeed need, {int leaseSeconds = 300});
  /// Tells Venue the work for [h] has begun.
  Future<void> start(VenueHold h);
  /// Extends the lease on [h].
  Future<void> renew(VenueHold h);
  /// Gives [h] back. A hold that is already gone counts as released.
  Future<void> release(VenueHold h);

  /// This consumer's own live (not released) holds, e.g. to find orphans after a crash. Other consumers' holds are not listed.
  Future<List<VenueHold>> holds();
  /// The nodes Venue knows about, as the daemon reports them. A local session has none; the fake has one.
  Future<List<Map<String, Object?>>> nodes();
  /// Closes the session. `AppContext.close` calls this last.
  Future<void> close();

  /// Hold, mark started, renew in the background while [body] runs, then release, even on error.
  /// This is the loop every app that uses Venue would otherwise write.
  ///
  /// Renewal failures are not swallowed: each is recorded on the hold ([VenueHold.renewalFailures],
  /// [VenueHold.lastRenewalError]) and the first sets [VenueHold.leaseLost] and calls [onLeaseLost] (once). The body keeps
  /// running; stopping it is the app's decision. A failing release never replaces the body's result or error: it is
  /// recorded in [VenueHold.releaseError]. [renewEvery] defaults to a third of the lease.
  Future<T> withHold<T>(
    VenueNeed need,
    Future<T> Function(VenueHold hold) body, {
    int leaseSeconds = 300,
    void Function(VenueHold hold, Object error)? onLeaseLost,
    Duration? renewEvery,
  }) async {
    final h = await hold(need, leaseSeconds: leaseSeconds);
    return _runHeld(h, body, leaseSeconds: leaseSeconds, onLeaseLost: onLeaseLost, renewEvery: renewEvery);
  }

  /// The part of [withHold] after the hold is granted: start, renew while [body] runs, release.
  Future<T> _runHeld<T>(
    VenueHold h,
    Future<T> Function(VenueHold hold) body, {
    required int leaseSeconds,
    void Function(VenueHold hold, Object error)? onLeaseLost,
    Duration? renewEvery,
  }) async {
    Timer? t;
    try {
      await start(h);
      var renewing = false;
      t = Timer.periodic(renewEvery ?? Duration(seconds: (leaseSeconds ~/ 3).clamp(1, 3600)), (_) async {
        if (renewing || h.released) return; // never overlap renewals; never renew after release
        renewing = true;
        try {
          await renew(h);
        } catch (e) {
          h.renewalFailures++;
          h.lastRenewalError = e;
          if (!h.leaseLost) {
            h.leaseLost = true;
            try {
              onLeaseLost?.call(h, e);
            } catch (cb, st) {
              // The app's own callback threw: report it like any uncaught timer error instead of hiding it.
              Zone.current.handleUncaughtError(cb, st);
            }
          }
        } finally {
          renewing = false;
        }
      });
      return await body(h);
    } finally {
      t?.cancel();
      try {
        await release(h);
      } catch (e) {
        h.releaseError = e;
      }
    }
  }
  /// Like [withHold], but when Venue refuses the hold it asks again every [retryEvery] until [maxWait] of waiting has been
  /// spent, then gives up by rethrowing the LAST [VenueRefused]. With a [maxWait] of [Duration.zero] it is exactly [withHold]
  /// (fail fast). Only the refusal of the hold is retried: an error thrown by [body] is never mistaken for one, and
  /// [VenueUnavailable] is never retried.
  ///
  /// What counts as "worth waiting for":
  ///  * [VenueRefusalKind.doesNotFit] (HTTP 409): always. Nothing fits right now; a hold may be released.
  ///  * [VenueRefusalKind.forbidden] (HTTP 403): ONLY while [holds] shows this consumer still has live holds of its own.
  ///    The real daemon answers its per-consumer live-hold limit with 403 too, and 403 is also what a missing grant or an
  ///    observer token gets. Venue gives no machine-readable reason, so the Kit cannot tell them apart. This is a HEURISTIC
  ///    (the render-queue demo's): a consumer that holds something and is refused 403 is assumed to have hit its own limit
  ///    and waits for one of its holds to end; a consumer with no holds of its own is refused for good at once. It is wrong
  ///    when a consumer both holds something and lacks the grant for a new kind of work (it waits [maxWait] for nothing, then
  ///    gets the real refusal). **A finding for the Venue project:** give 403 a machine-readable reason (or a distinct status) for
  ///    "over the live-hold limit"; then this method should drop the heuristic.
  ///
  /// Waiting is counted in naps of [retryEvery], not read from a clock, so it behaves under a test's fake time: it naps
  /// at most `maxWait ~/ retryEvery` times. [onWaiting] runs before each nap with the refusal and the number of refusals
  /// so far (1 for the first), e.g. to show "waiting for Venue". Completing [cancel] ends the wait at once (even mid-nap)
  /// with [HoldWaitCancelled]; if the hold is granted in the same instant it is released again, not leaked. [cancel] has no
  /// effect once [body] is running. [onLeaseLost] and [renewEvery] are passed to the hold as in [withHold].
  ///
  /// Each waiting consumer asks Venue about once per [retryEvery] (and, for 403, lists its holds): a wait queue or an event
  /// push in Venue would let nobody poll.
  Future<T> withHoldWaiting<T>(
    VenueNeed need,
    Future<T> Function(VenueHold hold) body, {
    required Duration maxWait,
    int leaseSeconds = 300,
    Duration retryEvery = const Duration(seconds: 1),
    Duration? renewEvery,
    Future<void>? cancel,
    void Function(VenueRefused refusal, int attempt)? onWaiting,
    void Function(VenueHold hold, Object error)? onLeaseLost,
  }) async {
    if (retryEvery <= Duration.zero) throw ArgumentError.value(retryEvery, 'retryEvery', 'must be positive');
    var cancelled = false;
    cancel?.then((_) => cancelled = true, onError: (Object _) {});
    var attempt = 0;
    while (true) {
      if (cancelled) throw HoldWaitCancelled();
      attempt++;
      final VenueHold h;
      try {
        h = await hold(need, leaseSeconds: leaseSeconds);
      } on VenueRefused catch (e) {
        if (retryEvery * attempt > maxWait || !await _worthWaitingFor(e)) rethrow;
        onWaiting?.call(e, attempt);
        final woke = Completer<void>();
        final timer = Timer(retryEvery, woke.complete);
        cancel?.then((_) {
          if (!woke.isCompleted) woke.complete();
        }, onError: (Object _) {});
        await woke.future;
        timer.cancel();
        continue;
      }
      if (cancelled) {
        try {
          await release(h);
        } catch (_) {}
        throw HoldWaitCancelled();
      }
      return _runHeld(h, body,
          leaseSeconds: leaseSeconds,
          onLeaseLost: onLeaseLost,
          renewEvery: renewEvery);
    }
  }

  Future<bool> _worthWaitingFor(VenueRefused e) async {
    if (e.retryable) return true;
    try {
      return (await holds())
          .isNotEmpty; // the 403 heuristic; see withHoldWaiting
    } catch (_) {
      return false;
    }
  }
}

/// Thrown by [VenueSession.withHoldWaiting] when the caller's `cancel` future completed while it was waiting for capacity.
class HoldWaitCancelled implements Exception {
  @override
  String toString() => 'HoldWaitCancelled';
}

/// No Venue: the work still runs, and the session says so. Holds are in-process only, so two apps can both "hold" the same thing.
class LocalVenue extends VenueSession {
  LocalVenue(this.why);
  /// Why there is no Venue, for example `Venue not configured`. It is the text inside [description].
  final String why;
  final _held = <String, VenueHold>{};
  @override
  String get kind => 'local';
  @override
  String get description => 'Venue: local ($why)';
  @override
  Future<VenueHold> hold(VenueNeed need, {int leaseSeconds = 300}) async {
    if (_held.containsKey(need.name)) {
      throw VenueRefused('${need.name} is already held in this process', kind: VenueRefusalKind.doesNotFit);
    }
    return _held[need.name] = VenueHold(need.name, 'local', DateTime.now().add(Duration(seconds: leaseSeconds)));
  }

  @override
  Future<void> start(VenueHold h) async => h.started = true;
  @override
  Future<void> renew(VenueHold h) async {}
  @override
  Future<void> release(VenueHold h) async {
    h.released = true;
    _held.remove(h.name);
  }

  @override
  Future<List<VenueHold>> holds() async => List.unmodifiable(_held.values);
  @override
  Future<List<Map<String, Object?>>> nodes() async => const [];
  @override
  Future<void> close() async {}
}

/// An in-memory Venue for mock mode and tests: one fake node with a fixed capacity, and a log of calls.
class FakeVenue extends VenueSession {
  FakeVenue({this.capacity = 1});
  /// How many holds the fake grants at once.
  final int capacity;
  /// Every call, in order, as `hold <name>`, `start <name>`, `renew <name>` or `release <name>`. A refused hold is logged too.
  final log = <String>[];
  final _held = <String, VenueHold>{};
  int _refusals = 0;
  VenueRefusalKind _refusalKind = VenueRefusalKind.doesNotFit;

  /// Makes the next [times] calls to [hold] refuse with [kind] whatever the capacity (then it behaves normally again), so a
  /// test can drive a wait-and-retry loop without arranging a full node. Each refused call is still logged.
  void refuseNext(int times, {VenueRefusalKind kind = VenueRefusalKind.doesNotFit}) {
    _refusals = times;
    _refusalKind = kind;
  }

  @override
  String get kind => 'fake';
  @override
  String get description => 'Venue: fake (mock mode)';
  @override
  Future<VenueHold> hold(VenueNeed need, {int leaseSeconds = 300}) async {
    log.add('hold ${need.name}');
    if (_refusals > 0) {
      _refusals--;
      throw VenueRefused('the fake node refused on purpose (${_refusalKind.name})', kind: _refusalKind);
    }
    if (_held.length >= capacity) {
      throw VenueRefused('the fake node is full', kind: VenueRefusalKind.doesNotFit);
    }
    return _held[need.name] = VenueHold(need.name, 'fake', DateTime.now().add(Duration(seconds: leaseSeconds)));
  }

  @override
  Future<void> start(VenueHold h) async {
    log.add('start ${h.name}');
    h.started = true;
  }

  @override
  Future<void> renew(VenueHold h) async => log.add('renew ${h.name}');
  @override
  Future<void> release(VenueHold h) async {
    log.add('release ${h.name}');
    h.released = true;
    _held.remove(h.name);
  }

  @override
  Future<List<VenueHold>> holds() async => List.unmodifiable(_held.values);
  @override
  Future<List<Map<String, Object?>>> nodes() async => [
        {'name': 'fake-node', 'ready': true}
      ];
  @override
  Future<void> close() async {}
}

/// A real Venue daemon, over HTTP+JSON with a bearer token.
class RemoteVenue extends VenueSession {
  RemoteVenue({required this.base, required this.token, required this.consumer, required this.transport});
  /// The daemon's base URL.
  final Uri base;
  /// The bearer token sent with every request.
  final String token;
  /// The consumer name holds are placed under (the manifest's `venue.consumer`).
  final String consumer;
  /// How requests reach the daemon.
  final DaemonTransport transport;

  @override
  String get kind => 'venue';
  @override
  String get description => 'Venue: connected to $base as $consumer';

  Map<String, String> get _headers => {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  /// One request. Anything that stops an answer arriving (socket, TLS, timeout) is [VenueUnavailable].
  Future<DaemonReply> _call(String method, String path, {String? body}) async {
    try {
      return await transport.send(method, base.resolve(path), headers: _headers, body: body, timeout: const Duration(seconds: 15));
    } catch (e) {
      throw VenueUnavailable('$method $path: $e');
    }
  }

  /// A hold name as one path segment (names reach the request path, so `/` or `?` in one must not change the route).
  static String _seg(String name) => Uri.encodeComponent(name);

  /// Whether the daemon at [base] answers `GET /healthz` with 200 within 2 seconds. Never throws.
  static Future<bool> healthy(DaemonTransport t, Uri base) async {
    try {
      final r = await t.send('GET', base.resolve('/healthz'), headers: const {}, timeout: const Duration(seconds: 2));
      return r.status == 200;
    } catch (_) {
      return false;
    }
  }

  /// The one status mapping (spec section 5 item 6): 409 is `doesNotFit`, 403 is `forbidden`, everything else is
  /// [VenueUnavailable]. [op] prefixes the reason for calls other than `hold`.
  Exception _failure(String? op, DaemonReply r) {
    final prefix = op == null ? '' : '$op: ';
    switch (r.status) {
      case 409:
        return VenueRefused('$prefix${_short(r.body)}', kind: VenueRefusalKind.doesNotFit);
      case 403:
        return VenueRefused('$prefix${_short(r.body)}', kind: VenueRefusalKind.forbidden);
      default:
        return VenueUnavailable('${prefix}HTTP ${r.status}: ${_short(r.body)}', status: r.status);
    }
  }

  @override
  Future<VenueHold> hold(VenueNeed need, {int leaseSeconds = 300}) async {
    final r = await _call('POST', '/v1/holds?leaseSeconds=$leaseSeconds', body: jsonEncode(need.toPlacement(consumer)));
    if (r.status == 201 || r.status == 200) {
      final j = _decode(r.body);
      final name = (j is Map ? j['name'] : null) as String? ?? need.name;
      final exp = j is Map && j['expiresAt'] is String ? DateTime.tryParse(j['expiresAt'] as String) : null;
      return VenueHold(name, 'venue', exp);
    }
    throw _failure(null, r);
  }

  @override
  Future<void> start(VenueHold h) async {
    final r = await _call('POST', '/v1/holds/${_seg(h.name)}/start');
    if (r.status >= 300) throw _failure('start', r);
    h.started = true;
  }

  @override
  Future<void> renew(VenueHold h) async {
    final r = await _call('POST', '/v1/holds/${_seg(h.name)}/renew');
    if (r.status >= 300) throw _failure('renew', r);
  }

  @override
  Future<void> release(VenueHold h) async {
    if (h.released) return;
    final r = await _call('DELETE', '/v1/holds/${_seg(h.name)}');
    h.released = true;
    // 404 and 410: already gone (released elsewhere, or the lease lapsed). That is the state we wanted.
    if (r.status >= 300 && r.status != 404 && r.status != 410) throw _failure('release', r);
  }

  @override
  Future<List<VenueHold>> holds() async {
    final r = await _call('GET', '/v1/holds');
    if (r.status != 200) throw _failure('holds', r);
    final items = _items(r.body, 'holds');
    final out = <VenueHold>[];
    for (final i in items) {
      // The daemon lists every consumer's holds; `holder` is the Placement's principal, which is our consumer name.
      // `live: false` marks a hold whose lease has lapsed but which has not been swept yet.
      if (i['holder'] != consumer || i['name'] is! String || i['live'] == false) continue;
      final exp = i['expiresAt'] is String ? DateTime.tryParse(i['expiresAt'] as String) : null;
      out.add(VenueHold(i['name'] as String, 'venue', exp)..started = i['startedAt'] != null);
    }
    return out;
  }

  @override
  Future<List<Map<String, Object?>>> nodes() async {
    final r = await _call('GET', '/v1/nodes');
    if (r.status != 200) throw _failure('nodes', r);
    return _items(r.body, 'nodes');
  }

  @override
  Future<void> close() async => transport.close();

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  /// `{"items": [...]}` as a list of maps, or [VenueUnavailable] when the daemon answered 200 with something else.
  static List<Map<String, Object?>> _items(String body, String what) {
    final j = _decode(body);
    final items = j is Map ? j['items'] : null;
    if (items is! List) throw VenueUnavailable('$what: the answer is not {"items": [...]}');
    return [
      for (final i in items)
        if (i is Map) i.cast<String, Object?>()
    ];
  }

  static String _short(String s) => s.length > 300 ? '${s.substring(0, 300)}...' : s;
}
