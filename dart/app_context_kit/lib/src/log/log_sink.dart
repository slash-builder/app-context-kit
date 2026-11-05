// The seam between code that has something to say and the log that keeps it.
//
// A Kit that wants to leave a trail (a process supervisor, a wire client)
// takes a [LogSink] in its constructor and never reaches for a global. The
// app hands it the App Context Kit's [DebugLog], or [NullLogSink] when it
// wants silence, or a recording fake in a test.

/// How much a log line matters.
enum LogLevel { debug, info, warn, error }

/// Where events go. [DebugLog] implements it. An implementation must never
/// throw and must be cheap when it is not recording.
abstract interface class LogSink {
  /// Record one event. [component] and [name] are fixed lowercase words;
  /// [fields] are the fixed-vocabulary facts the sink's allow-list admits.
  void event(
    String component,
    String name, {
    LogLevel level = LogLevel.info,
    Map<String, Object?> fields = const {},
  });
}

/// A [LogSink] that records nothing. The default for a Kit whose app gave it
/// no log.
class NullLogSink implements LogSink {
  const NullLogSink();

  @override
  void event(
    String component,
    String name, {
    LogLevel level = LogLevel.info,
    Map<String, Object?> fields = const {},
  }) {}
}
