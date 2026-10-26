import 'dart:async';

import 'package:app_context_kit/app_context_kit.dart';

/// A scripted [DaemonTransport]: no socket. Each request is recorded as `METHOD /path` and answered by [handler].
class FakeTransport implements DaemonTransport {
  FakeTransport(this.handler);

  /// Returns the reply for a request, or throws to simulate a transport failure.
  final FutureOr<DaemonReply> Function(String method, String path) handler;
  final requests = <String>[];
  bool closed = false;

  @override
  Future<DaemonReply> send(String method, Uri uri, {required Map<String, String> headers, String? body, Duration? timeout}) async {
    final key = '$method ${uri.path}';
    requests.add(key);
    return handler(method, uri.path);
  }

  @override
  void close() => closed = true;
}

DaemonReply reply(int status, [String body = '{}']) => DaemonReply(status, body);
