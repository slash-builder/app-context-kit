/// The Kit-owned envelope: a header the Kit reads and an opaque payload it never does.
///
/// Wire form (UTF-8 JSON, keys always in this order so the bytes are stable):
///
/// ```json
/// {"v":1,"account":"a","app":"dev.x","channel":"default","from":{"device":"d","instance":"i"},
///  "seq":1,"kind":"msg","schema":0,"rid":7,"payload":"<base64>"}
/// ```
///
/// `rid` is present only on requests and replies. `schema` is the app-declared
/// payload version; the Kit carries it and does not look at it. Unknown extra
/// keys are ignored (forward compatibility); a different `v` is rejected.
///
/// The payload is capped at [Envelope.maxPayloadBytes] (1 MiB). The Hearth
/// envelope is capped the same, so a payload that fits here fits there.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'types.dart';

/// The routing header: scope key, channel, sender, sequence, kind.
class EnvelopeHeader {
  const EnvelopeHeader({
    required this.account,
    required this.app,
    required this.channel,
    required this.from,
    required this.seq,
    required this.kind,
    this.requestId,
  });

  /// The sender's account.
  final String account;
  /// The sender's app id.
  final String app;
  /// The channel the message belongs to.
  final String channel;
  /// The sending copy.
  final PeerId from;
  /// Per-sender, per-link sequence number, starting at 1 on a new link.
  final int seq;
  /// The app-defined message type; `kit.` kinds are the Kit's own.
  final String kind;

  /// Request correlation id (>= 1) on requests and replies; null otherwise.
  final int? requestId;

  @override
  bool operator ==(Object other) =>
      other is EnvelopeHeader &&
      other.account == account &&
      other.app == app &&
      other.channel == channel &&
      other.from == from &&
      other.seq == seq &&
      other.kind == kind &&
      other.requestId == requestId;

  @override
  int get hashCode => Object.hash(account, app, channel, from, seq, kind, requestId);

  @override
  String toString() => 'EnvelopeHeader($account/$app/$channel $from #$seq $kind${requestId == null ? '' : ' rid=$requestId'})';
}

/// A header the Kit reads and a payload it never does.
class Envelope {
  const Envelope({required this.header, this.schema = 0, required this.payload});

  /// The routing header.
  final EnvelopeHeader header;

  /// App-declared payload schema version (0 .. 2^31-1).
  final int schema;
  /// The app's bytes, never interpreted. At most [maxPayloadBytes].
  final Uint8List payload;

  /// The wire format version. A frame with another version is rejected.
  static const int version = 1;

  /// 1 MiB, the cap shared with the Hearth envelope.
  static const int maxPayloadBytes = 1024 * 1024;

  /// Longest allowed identifier/kind string (characters).
  static const int maxFieldChars = 256;

  /// Room for the JSON header around the base64 payload.
  static const int _headerAllowance = 8192;

  /// The largest frame [decode] will look at: base64 of a full payload plus header room.
  static const int maxEncodedBytes = ((maxPayloadBytes + 2) ~/ 3) * 4 + _headerAllowance;

  static const int _maxSafeInt = 9007199254740991; // 2^53 - 1, safe on every JSON consumer
  static const int _maxSchema = 2147483647;

  /// The wire form: UTF-8 JSON as described in the library comment. Throws [EnvelopeError] if the payload or a field is over its limit.
  Uint8List encode() {
    final h = header;
    if (payload.length > maxPayloadBytes) {
      throw EnvelopeError('payload is ${payload.length} bytes; the cap is $maxPayloadBytes');
    }
    _checkString('account', h.account);
    _checkString('app', h.app);
    _checkString('channel', h.channel);
    _checkString('from.device', h.from.device);
    _checkString('from.instance', h.from.instance);
    _checkString('kind', h.kind);
    if (h.seq < 0 || h.seq > _maxSafeInt) throw EnvelopeError('seq out of range: ${h.seq}');
    if (schema < 0 || schema > _maxSchema) throw EnvelopeError('schema out of range: $schema');
    final rid = h.requestId;
    if (rid != null && (rid < 1 || rid > _maxSafeInt)) throw EnvelopeError('rid out of range: $rid');
    final map = <String, Object?>{
      'v': version,
      'account': h.account,
      'app': h.app,
      'channel': h.channel,
      'from': {'device': h.from.device, 'instance': h.from.instance},
      'seq': h.seq,
      'kind': h.kind,
      'schema': schema,
      if (rid != null) 'rid': rid,
      'payload': base64.encode(payload),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  /// Parses and validates a frame. Throws [EnvelopeError] for anything malformed
  /// or oversized; never throws anything else.
  static Envelope decode(List<int> bytes) {
    if (bytes.length > maxEncodedBytes) {
      throw EnvelopeError('frame is ${bytes.length} bytes; the cap is $maxEncodedBytes');
    }
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw EnvelopeError('not valid UTF-8 JSON: ${e.message}');
    }
    if (raw is! Map) throw EnvelopeError('envelope is not a JSON object');
    final v = raw['v'];
    if (v != version) throw EnvelopeError('unsupported envelope version: $v');
    final from = raw['from'];
    if (from is! Map) throw EnvelopeError('from is missing or not an object');
    final seq = _int(raw, 'seq', 0, _maxSafeInt);
    final schema = _int(raw, 'schema', 0, _maxSchema);
    final int? rid = raw.containsKey('rid') ? _int(raw, 'rid', 1, _maxSafeInt) : null;
    final b64 = raw['payload'];
    if (b64 is! String) throw EnvelopeError('payload is missing or not a base64 string');
    if (b64.length > ((maxPayloadBytes + 2) ~/ 3) * 4) {
      throw EnvelopeError('payload is larger than the $maxPayloadBytes byte cap');
    }
    final Uint8List payload;
    try {
      payload = base64.decode(b64);
    } on FormatException catch (e) {
      throw EnvelopeError('payload is not valid base64: ${e.message}');
    }
    if (payload.length > maxPayloadBytes) {
      throw EnvelopeError('payload is ${payload.length} bytes; the cap is $maxPayloadBytes');
    }
    if (base64.encode(payload) != b64) throw EnvelopeError('payload base64 is not canonical');
    return Envelope(
      header: EnvelopeHeader(
        account: _str(raw, 'account'),
        app: _str(raw, 'app'),
        channel: _str(raw, 'channel'),
        from: PeerId(_str(from, 'device', 'from.device'), _str(from, 'instance', 'from.instance')),
        seq: seq,
        kind: _str(raw, 'kind'),
        requestId: rid,
      ),
      schema: schema,
      payload: payload,
    );
  }

  static final RegExp _control = RegExp(r'[\u0000-\u001f\u007f]');

  static void _checkString(String name, String s) {
    if (s.isEmpty) throw EnvelopeError('$name is empty');
    if (s.length > maxFieldChars) throw EnvelopeError('$name is longer than $maxFieldChars characters');
    if (_control.hasMatch(s)) throw EnvelopeError('$name contains a control character');
  }

  static String _str(Map m, String key, [String? label]) {
    final v = m[key];
    final name = label ?? key;
    if (v is! String) throw EnvelopeError('$name is missing or not a string');
    _checkString(name, v);
    return v;
  }

  static int _int(Map m, String key, int min, int max) {
    final v = m[key];
    if (v is! int) throw EnvelopeError('$key is missing or not an integer');
    if (v < min || v > max) throw EnvelopeError('$key out of range: $v');
    return v;
  }

  @override
  String toString() => 'Envelope(${header.kind} #${header.seq} v$schema ${payload.length}B)';
}
