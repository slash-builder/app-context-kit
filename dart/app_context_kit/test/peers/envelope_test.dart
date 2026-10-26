import 'dart:convert';
import 'dart:typed_data';

import 'package:app_context_kit/src/peers/peers.dart';
import 'package:test/test.dart';

Envelope sample({int seq = 7, String kind = 'msg', int schema = 3, int? rid, List<int> payload = const [1, 2, 3, 255]}) => Envelope(
      header: EnvelopeHeader(
        account: 'acct-1',
        app: 'com.slashbuilder.demo.app',
        channel: 'default',
        from: const PeerId('mac', 'a1b2'),
        seq: seq,
        kind: kind,
        requestId: rid,
      ),
      schema: schema,
      payload: Uint8List.fromList(payload),
    );

Uint8List json(Map<String, Object?> m) => Uint8List.fromList(utf8.encode(jsonEncode(m)));

Map<String, Object?> good() => (jsonDecode(utf8.decode(sample().encode())) as Map).cast<String, Object?>();

void main() {
  group('encoding', () {
    test('is stable: fixed key order, payload as base64', () {
      expect(
        utf8.decode(sample().encode()),
        '{"v":1,"account":"acct-1","app":"com.slashbuilder.demo.app","channel":"default",'
        '"from":{"device":"mac","instance":"a1b2"},"seq":7,"kind":"msg","schema":3,"payload":"AQID/w=="}',
      );
    });

    test('a request id appears just before the payload', () {
      expect(utf8.decode(sample(rid: 9).encode()), contains('"schema":3,"rid":9,"payload":'));
    });

    test('round trips every field, including an empty payload and a request id', () {
      for (final e in [sample(), sample(rid: 12), sample(payload: const []), sample(seq: 0, schema: 0)]) {
        final back = Envelope.decode(e.encode());
        expect(back.header, e.header);
        expect(back.schema, e.schema);
        expect(back.payload, e.payload);
      }
    });

    test('round trips non-ASCII identifiers', () {
      final e = Envelope(
        header: const EnvelopeHeader(account: 'compte-é', app: 'com.slashbuilder.demo', channel: 'canal-日本', from: PeerId('mac', 'i'), seq: 1, kind: 'k'),
        payload: Uint8List(0),
      );
      expect(Envelope.decode(e.encode()).header, e.header);
    });

    test('a payload of exactly 1 MiB is accepted and one byte more is not', () {
      final ok = sample(payload: Uint8List(Envelope.maxPayloadBytes));
      expect(Envelope.decode(ok.encode()).payload.length, Envelope.maxPayloadBytes);
      expect(() => sample(payload: Uint8List(Envelope.maxPayloadBytes + 1)).encode(), throwsA(isA<EnvelopeError>()));
    });

    test('a full-size frame fits under maxEncodedBytes', () {
      expect(sample(payload: Uint8List(Envelope.maxPayloadBytes)).encode().length, lessThanOrEqualTo(Envelope.maxEncodedBytes));
    });
  });

  group('rejects bad input (EnvelopeError, never anything else)', () {
    void bad(String why, Uint8List input) => test(why, () => expect(() => Envelope.decode(input), throwsA(isA<EnvelopeError>())));

    bad('not JSON', Uint8List.fromList(utf8.encode('hello')));
    bad('invalid UTF-8', Uint8List.fromList([0xff, 0xfe, 0x00]));
    bad('empty', Uint8List(0));
    bad('a JSON array', Uint8List.fromList(utf8.encode('[1,2]')));
    bad('a JSON string', Uint8List.fromList(utf8.encode('"x"')));
    bad('a frame over the size cap', Uint8List(Envelope.maxEncodedBytes + 1));
    bad('wrong version', json({...good(), 'v': 2}));
    bad('missing version', json({...good()}..remove('v')));
    bad('missing account', json({...good()}..remove('account')));
    bad('numeric app', json({...good(), 'app': 5}));
    bad('empty channel', json({...good(), 'channel': ''}));
    bad('control character in kind', json({...good(), 'kind': 'a\nb'}));
    bad('overlong kind', json({...good(), 'kind': 'k' * 257}));
    bad('from missing', json({...good()}..remove('from')));
    bad('from not an object', json({...good(), 'from': 'mac@x'}));
    bad('from.device missing', json({...good(), 'from': {'instance': 'i'}}));
    bad('negative seq', json({...good(), 'seq': -1}));
    bad('fractional seq', Uint8List.fromList(utf8.encode(utf8.decode(sample().encode()).replaceFirst('"seq":7', '"seq":7.5'))));
    bad('seq as string', json({...good(), 'seq': '7'}));
    bad('seq beyond 2^53', json({...good(), 'seq': 9007199254740993}));
    bad('negative schema', json({...good(), 'schema': -1}));
    bad('schema beyond 2^31', json({...good(), 'schema': 2147483648}));
    bad('rid of zero', json({...good(), 'rid': 0}));
    bad('rid as string', json({...good(), 'rid': 'x'}));
    bad('payload missing', json({...good()}..remove('payload')));
    bad('payload not a string', json({...good(), 'payload': [1, 2]}));
    bad('payload not base64', json({...good(), 'payload': '***'}));
    bad('payload base64 not canonical', json({...good(), 'payload': 'AQID/w'}));
    bad('payload base64 over the cap', json({...good(), 'payload': base64.encode(Uint8List(Envelope.maxPayloadBytes + 1))}));

    test('encode refuses a bad header too', () {
      expect(() => sample(kind: '').encode(), throwsA(isA<EnvelopeError>()));
      expect(() => sample(seq: -1).encode(), throwsA(isA<EnvelopeError>()));
      expect(() => sample(rid: 0).encode(), throwsA(isA<EnvelopeError>()));
      expect(() => sample(schema: -2).encode(), throwsA(isA<EnvelopeError>()));
    });
  });

  test('unknown extra keys are ignored (forward compatibility)', () {
    final e = Envelope.decode(json({...good(), 'future': {'x': 1}}));
    expect(e.header.kind, 'msg');
  });

  test('fuzz: random bytes never throw anything but EnvelopeError', () {
    var state = 12345;
    int next() => state = (state * 1103515245 + 12345) & 0x7fffffff;
    for (var i = 0; i < 500; i++) {
      final b = Uint8List.fromList(List.generate(next() % 200, (_) => next() & 0xff));
      try {
        Envelope.decode(b);
      } on EnvelopeError {
        // expected
      }
    }
  });
}
