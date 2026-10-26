/// JSON in and out of the opaque bytes the hub carries.
///
/// The Kit never reads a payload, so an app that speaks JSON (every demo app does) needs the same few helpers: encode,
/// decode without throwing on hostile input, a size check before sending, and a send nobody awaits that cannot become an
/// uncaught async error. They live here so each app does not write them again.
///
/// The Kit envelope already carries `kind` and `schema` beside the payload, so there is no second envelope inside the
/// payload: switch on `AppMessage.kind` and check `AppMessage.schema`, then read the body with
/// [AppMessageJson.jsonBody].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'types.dart';

/// Thrown by [PeerJson.encodeWithin] when the encoded value is over the budget.
class PeerPayloadTooLarge extends PeerError {
  PeerPayloadTooLarge(this.bytes, this.maxBytes)
      : super('payload is $bytes bytes; the limit is $maxBytes');
  /// The size of the encoded value.
  final int bytes;
  /// The limit it was checked against.
  final int maxBytes;
}

/// Helpers for JSON payloads, hellos and labels. All are static.
abstract final class PeerJson {
  /// [value] (anything `jsonEncode` accepts: maps, lists, strings, numbers, bools, null) as UTF-8 JSON.
  /// Throws what `jsonEncode` throws for a value that is not JSON-encodable: that is a bug in the sender, not hostile input.
  static Uint8List encode(Object? value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));

  /// Decodes a payload or hello, or returns null when [bytes] is not UTF-8 JSON, or is longer than [maxBytes]. Never throws:
  /// a hostile or malformed message must not escape `onMessage`.
  ///
  /// A payload that is the JSON literal `null` also gives null. Send an object (`{"v": ...}`) rather than a bare value
  /// when "nothing" and "malformed" must be told apart.
  static Object? decode(Uint8List bytes, {int? maxBytes}) {
    if (maxBytes != null && bytes.length > maxBytes) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
  }

  /// How many bytes [encode] would produce for [value].
  static int sizeOf(Object? value) => utf8.encode(jsonEncode(value)).length;

  /// Whether [value] encodes to at most [maxBytes]. Use it before sending to a provider with a payload cap (Hearth's is
  /// 64 KiB minus the Kit header: pass the limit the provider declares, less the header).
  static bool fits(Object? value, int maxBytes) => sizeOf(value) <= maxBytes;

  /// [encode], but throws [PeerPayloadTooLarge] (a [PeerError]) instead of returning bytes over [maxBytes].
  static Uint8List encodeWithin(Object? value, int maxBytes) {
    final b = encode(value);
    if (b.length > maxBytes) throw PeerPayloadTooLarge(b.length, maxBytes);
    return b;
  }

  /// A send nobody awaits: a failure (peer lost, outbox full, hub closed) is swallowed instead of becoming an uncaught
  /// async error. Use it for state that is re-sent anyway; await the future when the outcome matters.
  static void quiet(Future<Object?> send) =>
      unawaited(send.then((_) {}, onError: (Object _) {}));

  /// The display form of a copy: its device and the first four characters of its instance ("laptop #3fa2").
  static String label(PeerId id) =>
      '${id.device} #${id.instance.length < 4 ? id.instance : id.instance.substring(0, 4)}';
}

/// Adds [jsonBody] to [AppMessage].
extension AppMessageJson on AppMessage {
  /// The payload decoded as JSON, or null when it is malformed (see [PeerJson.decode]).
  Object? get jsonBody => PeerJson.decode(payload);
}
