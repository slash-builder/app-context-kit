// Spec section 5 item 4: close() is idempotent and isolates hooks; Venue closes last.
import 'dart:async';
import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';
import 'package:test/test.dart';

import 'support/fake_transport.dart';

AppManifest manifest() => AppManifest.fromJson({'id': 'com.slashbuilder.demo.calc', 'name': 'Calc', 'version': '0.1.0'});

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app-context-close-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppContext> open({DaemonTransport? transport, Map<String, String> more = const {}}) =>
      AppContext.open(manifest(), env: {'APP_CONTEXT_SCRATCH': tmp.path, ...more}, platform: 'linux', home: '/x', transport: transport);

  test('the second close does nothing: hooks run once', () async {
    final ctx = await open();
    var runs = 0;
    ctx.onClose(() => runs++);
    await ctx.close();
    await ctx.close();
    await ctx.close();
    expect(runs, 1);
  });

  test('concurrent closes run the hooks once', () async {
    final ctx = await open();
    var runs = 0;
    ctx.onClose(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      runs++;
    });
    await Future.wait([ctx.close(), ctx.close()]);
    expect(runs, 1);
  });

  test('every hook runs even if one throws; the errors are raised together afterwards', () async {
    final ctx = await open();
    final ran = <String>[];
    ctx.onClose(() => ran.add('first'));
    ctx.onClose(() {
      ran.add('second');
      throw StateError('second broke');
    });
    ctx.onClose(() async {
      ran.add('third');
      throw ArgumentError('third broke');
    });
    ctx.onClose(() => ran.add('fourth'));

    final err = await ctx.close().then<Object?>((_) => null, onError: (Object e) => e);
    expect(ran, ['fourth', 'third', 'second', 'first'], reason: 'last added runs first, and none is skipped');
    expect(err, isA<AppCloseError>());
    final errors = (err as AppCloseError).errors;
    expect(errors, hasLength(2));
    expect(errors[0], isA<ArgumentError>());
    expect(errors[1], isA<StateError>());
    expect(err.stackTraces, hasLength(2));

    await ctx.close(); // the second call is silent even though the first failed
  });

  test('the roster entry is withdrawn even when a hook throws, and before the hooks run', () async {
    final ctx = await open();
    List<RosterEntry>? seenInHook;
    ctx.onClose(() => seenInHook = ctx.roster.running());
    ctx.onClose(() => throw StateError('x'));
    await ctx.close().then((_) {}, onError: (Object _) {});
    expect(seenInHook, isEmpty);
    expect(ctx.roster.scan(), isEmpty);
  });

  test('Venue is closed last, after every hook, and still closed when hooks throw', () async {
    final order = <String>[];
    File('${tmp.path}/t').writeAsStringSync('tok');
    final t = _RecordingTransport(order);
    final ctx = await open(transport: t, more: {'VENUE_TOKEN_FILE': '${tmp.path}/t'});
    expect(ctx.venue.kind, 'venue');
    ctx.onClose(() => order.add('hook-a'));
    ctx.onClose(() {
      order.add('hook-b');
      throw StateError('b');
    });
    await ctx.close().then((_) {}, onError: (Object _) {});
    expect(order.skipWhile((e) => e != 'hook-b').toList(), ['hook-b', 'hook-a', 'venue-closed']);
  });

  test('a Venue close failure is reported together with the hook errors, and the hooks still ran', () async {
    File('${tmp.path}/t').writeAsStringSync('tok');
    final ctx = await open(transport: _ThrowingCloseTransport(), more: {'VENUE_TOKEN_FILE': '${tmp.path}/t'});
    var hookRan = false;
    ctx.onClose(() => hookRan = true);
    ctx.onClose(() => throw StateError('hook'));
    final err = await ctx.close().then<Object?>((_) => null, onError: (Object e) => e);
    expect(hookRan, isTrue);
    expect((err as AppCloseError).errors.map((e) => e.runtimeType), [StateError, UnsupportedError]);
  });
}

class _ThrowingCloseTransport extends FakeTransport {
  _ThrowingCloseTransport() : super((m, p) => reply(200));
  @override
  void close() => throw UnsupportedError('transport close failed');
}

class _RecordingTransport extends FakeTransport {
  _RecordingTransport(this.order) : super((m, p) => reply(200));
  final List<String> order;
  @override
  void close() {
    order.add('venue-closed');
    super.close();
  }
}
