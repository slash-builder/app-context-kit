import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A fresh random instance id: 8 lowercase hex digits (spec section 5 item 5).
String newInstanceId([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
}

final _instancePattern = RegExp(r'^[0-9a-f]{8}$');

/// The content of one presence file: which app, which copy, and when it last said it was alive.
class RosterEntry {
  RosterEntry(this.id, this.name, this.version, this.pid, this.startedAt, this.heartbeatAt, {this.instance});
  /// The app's id, display name and version, from its manifest.
  final String id, name, version;
  /// The process id of the copy. Meaningful only on the same machine and for the same user; the roster does not check that it is alive.
  final int pid;
  /// When the copy started and when it last refreshed its entry.
  final DateTime startedAt, heartbeatAt;

  /// Which copy of the app this is; `null` only for a presence file written before instance ids existed.
  final String? instance;

  /// True when [heartbeatAt] is more than [after] (default 15 seconds) before [now]: the copy exited without withdrawing, most likely a crash.
  bool isStale(DateTime now, {Duration after = const Duration(seconds: 15)}) => now.difference(heartbeatAt) > after;

  /// The JSON written to the presence file.
  Map<String, Object?> toJson() => {
        'id': id,
        if (instance != null) 'instance': instance,
        'name': name,
        'version': version,
        'pid': pid,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'heartbeatAt': heartbeatAt.toUtc().toIso8601String(),
      };

  /// Reads a presence file's JSON, or returns null when it is not a complete entry.
  static RosterEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final inst = j['instance'];
      if (j.containsKey('instance') && inst is! String) return null;
      return RosterEntry(j['id'] as String, j['name'] as String, j['version'] as String, j['pid'] as int,
          DateTime.parse(j['startedAt'] as String), DateTime.parse(j['heartbeatAt'] as String),
          instance: inst as String?);
    } catch (_) {
      return null;
    }
  }
}

/// Whether a presence file is a running copy, a copy that stopped heartbeating (a crash), or not a presence file at all.
enum RosterStatus { live, stale, unreadable }

/// One presence file as [Roster.scan] found it.
class RosterRecord {
  RosterRecord(this.file, this.status, this.entry, this.id, this.instance);

  /// The file name, e.g. `com.slashbuilder.demo.calc@1a2b3c4d.json`.
  final String file;
  /// Whether the file is a live entry, a stale one or unreadable.
  final RosterStatus status;

  /// What the file says; `null` when [status] is [RosterStatus.unreadable].
  final RosterEntry? entry;

  /// The app id and instance: from the file's content when readable, otherwise from the file name (so an unreadable
  /// file can still be attributed). Either may be `null` if the name does not follow `<ID>@<INSTANCE>.json`.
  final String? id, instance;
}

/// Splits `<ID>@<INSTANCE>.json` into its parts. The id contains dots, so only the final `.json` is removed and the
/// split is at the last `@`. A name without a valid 8-hex instance (an old `<ID>.json`) has a null instance.
({String id, String? instance}) parseRosterFileName(String fileName) {
  final stem = fileName.endsWith('.json') ? fileName.substring(0, fileName.length - '.json'.length) : fileName;
  final at = stem.lastIndexOf('@');
  if (at > 0 && _instancePattern.hasMatch(stem.substring(at + 1))) {
    return (id: stem.substring(0, at), instance: stem.substring(at + 1));
  }
  return (id: stem, instance: null);
}

String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

/// Who is running, by presence file. The smallest version of "BRoster".
class Roster {
  /// A roster over [dir]. It creates nothing until something is announced.
  Roster(this.dir);
  /// The roster directory.
  final String dir;

  File _file(String id, String instance) => File('$dir${Platform.pathSeparator}$id@$instance.json');

  /// Writes this copy's presence file (`<ID>@<INSTANCE>.json`) and keeps its heartbeat going. [instance] defaults to a
  /// fresh random id.
  Future<RosterAnnouncement> announce(
      {required String id, required String name, required String version, String? instance, Duration every = const Duration(seconds: 5)}) async {
    Directory(dir).createSync(recursive: true);
    final inst = instance ?? newInstanceId();
    final file = _file(id, inst);
    final started = DateTime.now().toUtc();
    late final RosterAnnouncement ann;
    void write() {
      final e = RosterEntry(id, name, version, pid, started, DateTime.now().toUtc(), instance: inst);
      final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(e.toJson()));
      tmp.renameSync(file.path);
    }

    write();
    // A failed heartbeat (the directory vanished, disk full) must not become an uncaught timer error that kills the app.
    final timer = Timer.periodic(every, (_) {
      try {
        write();
      } catch (e) {
        ann.lastError = e;
      }
    });
    return ann = RosterAnnouncement._(timer, file, inst);
  }

  /// Every presence file with its status, sorted by app id then instance. Nothing is deleted. A viewer uses this to tell a
  /// crash (`stale`) from "never ran" (no entry) from a damaged file (`unreadable`).
  List<RosterRecord> scan({DateTime? now, Duration staleAfter = const Duration(seconds: 15)}) {
    final d = Directory(dir);
    if (!d.existsSync()) return [];
    final n = now ?? DateTime.now().toUtc();
    final out = <RosterRecord>[];
    for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      final name = _baseName(f.path);
      final fromName = parseRosterFileName(name);
      RosterEntry? e;
      try {
        e = RosterEntry.fromJson(jsonDecode(f.readAsStringSync()));
      } catch (_) {
        e = null;
      }
      if (e == null) {
        out.add(RosterRecord(name, RosterStatus.unreadable, null, fromName.id, fromName.instance));
      } else {
        out.add(RosterRecord(name, e.isStale(n, after: staleAfter) ? RosterStatus.stale : RosterStatus.live, e, e.id, e.instance));
      }
    }
    out.sort((a, b) {
      final c = (a.id ?? a.file).compareTo(b.id ?? b.file);
      return c != 0 ? c : (a.instance ?? '').compareTo(b.instance ?? '');
    });
    return out;
  }

  /// Everything announced and not stale. Stale and unreadable files are skipped, not deleted (see [scan] to see them).
  List<RosterEntry> running({DateTime? now, Duration staleAfter = const Duration(seconds: 15)}) =>
      [for (final r in scan(now: now, staleAfter: staleAfter)) if (r.status == RosterStatus.live) r.entry!];
}

/// A copy's live presence entry. [Roster.announce] returns one; [withdraw] ends it.
class RosterAnnouncement {
  RosterAnnouncement._(this._timer, this._file, this.instance);
  final Timer _timer;
  final File _file;

  /// This copy's instance id (the part after `@` in the file name).
  final String instance;

  /// The presence file's path.
  String get path => _file.path;

  /// The most recent heartbeat failure, if any.
  Object? lastError;

  /// Stops the heartbeat and removes this copy's own file, and only that file.
  void withdraw() {
    _timer.cancel();
    if (_file.existsSync()) _file.deleteSync();
  }
}
