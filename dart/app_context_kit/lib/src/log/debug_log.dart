// An app-wide debug log, OFF by default, switched on in Settings.
//
// Moved here from Courier (`lib/diagnostics/debug_log.dart`, b9af9d6). Courier
// had no persistent log: when something went wrong after the screen had moved
// on, there was nothing to look at. When the owner turns this on,
// one line per event is written to a file in the app's own data folder.
//
// What a line holds: a UTC time, a level, a component tag, an event name and
// FIXED-vocabulary fields: counts, lengths, status and exit codes, durations,
// error CLASSES, phases (enum names). What it never holds: credentials, tokens,
// codes, the query part of a link, request or response bodies, chat text, file
// contents, fingerprints or keys, anything a program printed, or the path of a
// secret.
//
// How that is held, not just promised:
//  * a field name must be on the allow-list ([kLogFields] unless the app gives
//    its own); anything else is dropped;
//  * a field value is a number, a bool, an enum name, or a short string that has
//    been scrubbed (token-shaped runs, links and queries removed), cut to 64
//    characters and limited to letters, digits and `_ . -`;
//  * component and event names are fixed lowercase words;
//  * the finished line is scrubbed once more before it is written, and the
//    tail handed to "Copy diagnostics" is scrubbed again on the way out;
//  * switched off, a call returns at once: no folder, no file, no work.
//
// The folder is `0700` and the files `0600`; `debug.log` is capped at 1 MiB
// and two older files are kept (`.1`, `.2`), so at most 3 MiB. A failure to
// write is dropped: logging never breaks the app.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../app_context.dart';
import 'log_sink.dart';

/// The field names a line may carry unless the app passes its own set to
/// [DebugLog]. Anything else is dropped. These are the names Courier used.
const Set<String> kLogFields = {
  'phase', // an enum name: where in a flow
  'result', // a fixed failure/result code (enum name) or a small number
  'status', // a status code, such as an HTTP status
  'exit', // a process exit code
  'ms', // a duration
  'count', // how many
  'bytes', // how long (a size, never content)
  'len', // a length
  'attempt', // which try
  'ok', // a yes/no
  'kind', // which sort of call (a fixed word)
  'class', // an error CLASS name
  'state', // a lifecycle state (enum name)
  'build', // build id (short, fixed)
  'platform', // operating system name
  'mode', // debug / profile / release
  'scopes', // how many scopes
  'devices', // how many devices
  'findings', // how many findings
  'rows', // rows on a screen (a count)
  'changed', // rows changed since last shown (a count)
  'tokenrun', // whether a key-looking run is on a screen (yes/no only)
  'age', // milliseconds since the last output
  'row', // a cursor row (a number)
  'col', // a cursor column (a number)
  'emitted', // lines passed on (a count)
  'rewritten', // rows drawn over after being passed on (a count)
};

final RegExp _componentName = RegExp(r'^[a-z][a-z0-9_]{0,23}$');
final RegExp _eventName = RegExp(r'^[a-z][a-z0-9_.]{0,47}$');

/// Token-shaped and link-shaped runs, removed from anything free-form.
final List<RegExp> _secretShapes = [
  RegExp(r'sk-ant-[A-Za-z0-9_\-]*'),
  RegExp(r'gh[pousr]_[A-Za-z0-9]+'),
  RegExp(r'github_pat_[A-Za-z0-9_]+'),
  RegExp(r'xox[abprs]-[A-Za-z0-9\-]+'),
  RegExp(r'AKIA[0-9A-Z]{12,}'),
  RegExp(r'Bearer\s+\S+', caseSensitive: false),
  RegExp(r'Basic\s+[A-Za-z0-9+/=]{8,}', caseSensitive: false),
  RegExp(r'eyJ[A-Za-z0-9_\-]{6,}(\.[A-Za-z0-9_\-]*)*'),
  RegExp(r'[a-z][a-z0-9+.\-]{0,31}://\S*'),
  RegExp(r'[?&][A-Za-z0-9_\-]+=[^\s&]*'),
];

final RegExp _longRun = RegExp(r'[A-Za-z0-9+/_\-=]{24,}');

/// A long unbroken run of key-looking characters (hex, base64, ids): one with
/// a digit in it, or a very long one. (A long class name is letters only.)
String _scrubLongRuns(String s) => s.replaceAllMapped(_longRun, (m) {
      final run = m.group(0)!;
      return run.length >= 64 || RegExp(r'[0-9]').hasMatch(run) ? '[x]' : run;
    });

/// [s] with token-shaped and link-shaped runs replaced by `[x]`.
String scrubForLog(String s) {
  var t = s;
  for (final r in _secretShapes) {
    t = t.replaceAll(r, '[x]');
  }
  return _scrubLongRuns(t);
}

/// Strings longer than this are cut BEFORE they are cleaned (so the cost of
/// cleaning never depends on how much an error said).
const int _kInputCap = 256;

/// A string field value: cut, scrubbed, limited to `[A-Za-z0-9_.-]` (other
/// characters become `_`) and cut again to 64 characters.
String safeLogString(String s) {
  final capped = s.length > _kInputCap ? s.substring(0, _kInputCap) : s;
  final t = scrubForLog(capped)
      .replaceAll('[x]', 'X')
      .replaceAll(RegExp(r'[^A-Za-z0-9_.\-]+'), '_');
  return t.length > 64 ? t.substring(0, 64) : t;
}

/// The shape of a fixed word, a class name or a build id. Nothing else is
/// accepted as a string value.
final RegExp _fixedWord = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.+\-]{0,31}$');

/// A word that is that shape but looks like a key (all capitals and digits, or
/// long with a digit) is not a word.
bool _keyish(String v) =>
    RegExp(r'^[0-9]{5,}$').hasMatch(v) ||
    (v.length >= 20 && RegExp(r'^[A-Z0-9]+$').hasMatch(v)) ||
    (v.length >= 24 && RegExp(r'[0-9]').hasMatch(v));

/// The one way a value gets into a line, or null when it may not. Numbers,
/// bools, durations and enum names are taken; a string only if it is a fixed
/// word (a class name, a verb, a build id): anything else is dropped, not
/// cleaned.
String? _value(Object? v) {
  if (v == null) return null;
  if (v is bool) return v ? 'true' : 'false';
  if (v is int) return '$v';
  if (v is double) return v.isFinite ? v.toStringAsFixed(1) : null;
  if (v is Duration) return '${v.inMilliseconds}';
  if (v is Enum) return safeLogString(v.name);
  if (v is String) {
    if (!_fixedWord.hasMatch(v) || _keyish(v)) return null;
    return safeLogString(v);
  }
  return null; // lists, maps, objects: not loggable
}

/// What an error is, and nothing it said: its class, and a status or code
/// number (at most three digits) if its text carries one (`HTTP 404`,
/// `code 24`). Longer numbers in the text are never taken.
Map<String, Object?> errorFields(Object error) {
  final raw = '$error';
  final text = raw.length > _kInputCap ? raw.substring(0, _kInputCap) : raw;
  final status = RegExp(r'\bHTTP (\d{3})\b').firstMatch(text)?.group(1);
  final code =
      RegExp(r'\b(?:code|error|errno)\W{0,3}(\d{1,3})\b', caseSensitive: false)
          .firstMatch(text)
          ?.group(1);
  return {
    'class': error.runtimeType.toString(),
    if (status != null) 'status': int.parse(status),
    if (code != null) 'result': int.parse(code),
  };
}

class DebugLog implements LogSink {
  /// A log in the folder [directory] resolves to (made on the first write).
  /// [appName] heads the text [tail] returns ("<appName> debug log: ...").
  /// [allowedFields] is the field-name allow-list, [kLogFields] by default.
  DebugLog({
    required Future<Directory> Function() directory,
    this.maxBytes = 1024 * 1024,
    this.keep = 3,
    bool enabled = false,
    DateTime Function()? now,
    this.appName = 'App',
    Set<String> allowedFields = kLogFields,
    @visibleForTesting
    Future<bool> Function(String mode, String path)? lockDown,
    @visibleForTesting Future<void> Function(String mode, String path)? chmod,
  })  : _dir = directory,
        _chmod = chmod ?? _runChmod,
        _lockDownOverride = lockDown,
        _now = now ?? DateTime.now,
        _allowed = allowedFields,
        _on = enabled;

  /// A log in `<state>/logs` of an open [AppContext] (the state directory is
  /// where the spec puts logs and history), named after the app.
  factory DebugLog.forContext(
    AppContext context, {
    bool enabled = false,
    Set<String> allowedFields = kLogFields,
  }) =>
      DebugLog(
        directory: () async => Directory('${context.dirs.state}/logs'),
        enabled: enabled,
        appName: context.manifest.name,
        allowedFields: allowedFields,
      );

  /// The app's log, for [dlog] and callers that have no other way to reach
  /// one. It has NO folder until the app assigns one (`DebugLog.instance =
  /// DebugLog.forContext(ctx)`): until then it is off and writes nothing.
  /// Tests replace it. Code inside a Kit should take a [LogSink] instead of
  /// reaching for this.
  static DebugLog instance = DebugLog(
    directory: () async => throw StateError('DebugLog.instance has no folder'),
  );

  /// Heads the text [tail] returns.
  final String appName;
  final Set<String> _allowed;

  final Future<Directory> Function() _dir;

  /// chmod [mode] [path] and say whether nothing is left for the group or
  /// others. A test replaces it to make tightening fail.
  final Future<bool>? Function(String mode, String path)? _lockDownOverride;

  /// Runs `chmod`. A test replaces it with one that does nothing.
  final Future<void> Function(String mode, String path) _chmod;

  Future<bool> _lockDown(String mode, String path) =>
      _lockDownOverride?.call(mode, path) ?? _chmodAndCheck(mode, path);
  final int maxBytes;

  /// How many files in all: the current one and `keep - 1` older ones.
  final int keep;
  final DateTime Function() _now;
  bool _on;
  final StreamController<bool> _changes = StreamController<bool>.broadcast(sync: true);

  static const String fileName = 'debug.log';

  Future<void> _tail = Future<void>.value();
  Directory? _directory;

  /// Whether lines are being written.
  bool get enabled => _on;
  set enabled(bool on) {
    if (on == _on) return;
    _on = on;
    _changes.add(on);
  }

  /// Each change of [enabled] (not each assignment: setting the same value
  /// again says nothing). Follow the Settings switch with this. The Flutter
  /// companion turns it into a `ValueListenable`.
  Stream<bool> get enabledChanges => _changes.stream;

  /// Record one event. Does nothing while the log is off. Never throws.
  @override
  void event(
    String component,
    String name, {
    LogLevel level = LogLevel.info,
    Map<String, Object?> fields = const {},
  }) {
    if (!_on) return;
    try {
      final b = StringBuffer()
        ..write(_now().toUtc().toIso8601String())
        ..write(' ')
        ..write(level.name)
        ..write(' ')
        ..write(_componentName.hasMatch(component) ? component : 'invalid')
        ..write(' ')
        ..write(_eventName.hasMatch(name) ? name : 'invalid');
      for (final e in fields.entries) {
        if (!_allowed.contains(e.key)) continue; // unknown: dropped
        final v = _value(e.value);
        if (v == null) continue;
        b
          ..write(' ')
          ..write(e.key)
          ..write('=')
          ..write(v);
      }
      b.write('\n');
      final line = scrubLine(b.toString());
      _tail = _tail.then((_) => _append(line)).catchError((Object _) {});
    } on Object {
      // never break the caller
    }
  }

  /// The last pass over a finished line: the line is words and numbers, so a
  /// token-shaped run in it can only be a mistake.
  @visibleForTesting
  static String scrubLine(String line) => _scrubLongRuns(line);

  // ---- the files -----------------------------------------------------------
  //
  // Nothing here follows a link: the folder and every file are looked at
  // WITHOUT following links first, and a link, a folder or file of another
  // kind, or permissions that stay open to the group or others after chmod,
  // stop all writing until "Clear logs" (which removes what is there and starts
  // over). Files are created exclusively, empty, and locked down before the
  // first byte.

  /// A reason not to write any more (a link was found, or permissions would
  /// not tighten). Cleared by [clear].
  bool _broken = false;

  static FileSystemEntityType _type(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false);

  /// chmod [mode] and check the result: no bits for the group or others.
  static Future<void> _runChmod(String mode, String path) async {
    await Process.run('chmod', [mode, path]);
  }

  Future<bool> _chmodAndCheck(String mode, String path) async {
    if (Platform.isWindows) return true;
    try {
      await _chmod(mode, path);
      return (FileStat.statSync(path).mode & 0x3f) == 0;
    } on Object {
      return false;
    }
  }

  Never _refuse() {
    _broken = true;
    throw const FileSystemException('debug log refused');
  }

  Future<Directory> _folder() async {
    final cached = _directory;
    if (cached != null) return cached;
    final d = await _dir();
    var t = _type(d.path);
    if (t == FileSystemEntityType.notFound) {
      d.createSync(recursive: true);
      t = _type(d.path);
    }
    if (t != FileSystemEntityType.directory) _refuse(); // a link, or a file
    if (!await _lockDown('700', d.path)) _refuse();
    for (final f in _files(d)) {
      if (!await _checkFile(f)) _refuse();
    }
    return _directory = d;
  }

  /// A log file that is there must be a plain file, and is locked down.
  Future<bool> _checkFile(File f) async {
    final t = _type(f.path);
    if (t == FileSystemEntityType.notFound) return true;
    if (t != FileSystemEntityType.file) return false;
    return _lockDown('600', f.path);
  }

  List<File> _files(Directory d) => [
        File('${d.path}/$fileName'),
        for (var i = 1; i < keep; i++) File('${d.path}/$fileName.$i'),
      ];

  Future<void> _append(String line) async {
    if (_broken) return;
    try {
      await _appendChecked(line);
    } on Object {
      _broken = true; // a link or open permissions: stop, say nothing
    }
  }

  Future<void> _appendChecked(String line) async {
    final dir = await _folder();
    if (_type(dir.path) != FileSystemEntityType.directory) _refuse();
    final files = _files(dir);
    final current = files.first;
    // Every write looks again: a file swapped for a link, or loosened,
    // since the last one.
    if (!await _checkFile(current)) _refuse();
    if (_type(current.path) == FileSystemEntityType.file &&
        current.lengthSync() + line.length > maxBytes) {
      // debug.log.2 goes, .1 becomes .2, debug.log becomes .1
      for (var i = files.length - 1; i >= 1; i--) {
        if (_type(files[i].path) != FileSystemEntityType.notFound) {
          // a link is removed itself, never followed
          files[i].deleteSync();
        }
        if (_type(files[i - 1].path) != FileSystemEntityType.notFound) {
          files[i - 1].renameSync(files[i].path);
        }
      }
      for (final f in files.skip(1)) {
        if (!await _checkFile(f)) _refuse();
      }
    }
    if (_type(current.path) == FileSystemEntityType.notFound) {
      // Created empty (and not if something is already there), then locked
      // down BEFORE anything is written to it.
      current.createSync(exclusive: true);
      if (!await _lockDown('600', current.path)) _refuse();
    }
    if (_type(current.path) != FileSystemEntityType.file) _refuse();
    current.writeAsStringSync(line, mode: FileMode.append);
  }

  /// Wait for lines already accepted to be on disk.
  Future<void> flush() => _tail;

  /// The folder the log is in (not created by asking), or null.
  Future<String?> folderPath() async {
    try {
      return (_directory ?? await _dir()).path;
    } on Object {
      return null;
    }
  }

  /// The most bytes read from one file for [tail].
  static const int _kTailRead = 64 * 1024;

  /// The newest lines, scrubbed again, with a header, for "Copy diagnostics".
  /// Whether or not the log is on, what is there is returned. Only plain files
  /// are read (never a link), and only their last 64 KiB.
  Future<String> tail({int maxChars = 32 * 1024}) async {
    await _tail;
    final b = StringBuffer(
        '$appName debug log: steps, counts, codes and timings only.\n');
    try {
      final path = await folderPath();
      if (path == null || _type(path) != FileSystemEntityType.directory) {
        b.write('(nothing recorded)\n');
      } else {
        final all = StringBuffer();
        for (final f in _files(Directory(path)).reversed) {
          // oldest first
          if (_type(f.path) != FileSystemEntityType.file) continue;
          all.write(_readTail(f));
        }
        var text = scrubLine(all.toString());
        if (text.length > maxChars) {
          text = text.substring(text.length - maxChars);
          text = text.substring(text.indexOf('\n') + 1);
        }
        b.write(text.isEmpty ? '(nothing recorded)\n' : text);
      }
    } on Object {
      b.write('(the log could not be read)\n');
    }
    return b.toString();
  }

  static String _readTail(File f) {
    final raf = f.openSync();
    try {
      final len = raf.lengthSync();
      final from = len > _kTailRead ? len - _kTailRead : 0;
      raf.setPositionSync(from);
      final bytes = raf.readSync(len - from);
      var text = utf8.decode(bytes, allowMalformed: true);
      if (from > 0) {
        final nl = text.indexOf('\n');
        text = nl < 0 ? '' : text.substring(nl + 1); // a whole line first
      }
      return text;
    } finally {
      raf.closeSync();
    }
  }

  /// Delete every log file (the folder stays), in the same queue as the
  /// writes, and start over (a refusal is forgotten).
  Future<void> clear() {
    _tail = _tail.then((_) => _clear()).catchError((Object _) {});
    return _tail;
  }

  Future<void> _clear() async {
    try {
      final path = await folderPath();
      // A folder that is a link is not entered: nothing behind it is touched.
      if (path == null || _type(path) != FileSystemEntityType.directory) {
        _broken = false;
        _directory = null;
        return;
      }
      for (final f in _files(Directory(path))) {
        // a link is removed itself, never followed
        if (_type(f.path) != FileSystemEntityType.notFound) f.deleteSync();
      }
    } on Object {
      // nothing to clear
    }
    _broken = false;
    _directory = null;
  }
}

/// Record one event on the app's log (a no-op while it is off). A
/// convenience for an app's own code; a Kit takes a [LogSink] instead.
void dlog(
  String component,
  String name, {
  LogLevel level = LogLevel.info,
  Map<String, Object?> fields = const {},
}) =>
    DebugLog.instance.event(component, name, level: level, fields: fields);

/// One line for a program that was run on [sink]: which kind of call (a fixed
/// word), its exit code and how long it took, or the CLASS of the error that
/// stopped it from running. Never an argument, its output or its error text.
void logProcess(
  LogSink sink,
  String component,
  String name, {
  required String kind,
  required Stopwatch took,
  int? exit,
  Object? error,
}) =>
    sink.event(component, name,
        level: exit == 0 ? LogLevel.debug : LogLevel.warn,
        fields: {
          'kind': kind,
          'ms': took.elapsedMilliseconds,
          'exit': exit,
          'ok': exit == 0,
          if (error != null) 'class': error.runtimeType.toString(),
        });

/// [logProcess] on the app's log.
void dlogProcess(
  String component,
  String name, {
  required String kind,
  required Stopwatch took,
  int? exit,
  Object? error,
}) =>
    logProcess(DebugLog.instance, component, name,
        kind: kind, took: took, exit: exit, error: error);
