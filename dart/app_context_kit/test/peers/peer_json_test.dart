import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

void main() {
  test('encode then decode round-trips JSON values, including non-ASCII text',
      () {
    final v = {
      'a': [1, 2.5, null, true],
      'b': 'café ☃'
    };
    expect(PeerJson.decode(PeerJson.encode(v)), v);
    expect(utf8.decode(PeerJson.encode({'k': 1})), '{"k":1}');
  });

  test('decode returns null, never throws, for malformed input', () {
    expect(PeerJson.decode(Uint8List.fromList([0xff, 0xfe, 0x00])), isNull,
        reason: 'not UTF-8');
    expect(PeerJson.decode(Uint8List.fromList(utf8.encode('{"a":'))), isNull,
        reason: 'truncated');
    expect(PeerJson.decode(Uint8List.fromList(utf8.encode('nope'))), isNull);
    expect(PeerJson.decode(Uint8List(0)), isNull, reason: 'empty');
    expect(
        PeerJson.decode(Uint8List.fromList(utf8.encode('[' * 100000))), isNull,
        reason: 'deep and unterminated');
  });

  test('decode with maxBytes refuses an oversized body before parsing it', () {
    final b = PeerJson.encode({'x': 'y' * 100});
    expect(PeerJson.decode(b, maxBytes: b.length), isNotNull);
    expect(PeerJson.decode(b, maxBytes: b.length - 1), isNull);
  });

  test('sizeOf counts UTF-8 bytes, not characters; fits is inclusive', () {
    expect(PeerJson.sizeOf('é'), 4, reason: '"é" is two bytes plus two quotes');
    expect(PeerJson.fits('abc', 5), isTrue);
    expect(PeerJson.fits('abc', 4), isFalse);
  });

  test(
      'encodeWithin returns the bytes when they fit and throws PeerPayloadTooLarge (a PeerError) when not',
      () {
    expect(PeerJson.encodeWithin({'a': 1}, 7), hasLength(7));
    expect(
        () => PeerJson.encodeWithin({'a': 1}, 6),
        throwsA(isA<PeerPayloadTooLarge>()
            .having((e) => e.bytes, 'bytes', 7)
            .having((e) => e.maxBytes, 'maxBytes', 6)));
    expect(PeerPayloadTooLarge(7, 6), isA<PeerError>());
  });

  test(
      'quiet swallows a failed send instead of raising an uncaught async error',
      () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      PeerJson.quiet(Future<Object?>.error(PeerLost('gone')));
      PeerJson.quiet(Future<Object?>.value(1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }, (e, s) => errors.add(e));
    expect(errors, isEmpty);
  });

  test('label is the device and at most four characters of the instance', () {
    expect(PeerJson.label(const PeerId('laptop', '3fa2c9')), 'laptop #3fa2');
    expect(PeerJson.label(const PeerId('laptop', 'ab')), 'laptop #ab');
  });

  test(
      'AppMessage.jsonBody decodes the payload and is null when it is malformed',
      () {
    AppMessage msg(List<int> bytes) => AppMessage(
        from: const PeerId('d', 'i'),
        channel: 'c',
        seq: 1,
        kind: 'k',
        schema: 1,
        payload: Uint8List.fromList(bytes));
    expect(msg(utf8.encode('{"n":3}')).jsonBody, {'n': 3});
    expect(msg([0xff]).jsonBody, isNull);
  });
}
