import 'dart:convert';
import 'dart:io';

import 'app_context.dart';

/// What [AppJsonFile.read] found: nothing, a value, or a file that exists but cannot be used.
class AppJsonRead {
  const AppJsonRead({this.value, this.problem, required this.exists});
  /// The decoded JSON when the file was read; null when it does not exist, is damaged, or contains the JSON literal `null`.
  final Object? value;

  /// Why the file could not be used (null when it was read fine or does not exist).
  final String? problem;
  /// Whether the file exists. Use it to tell a missing file from one that contains `null`.
  final bool exists;

  /// True when there is no problem: either the file is missing ([exists] false) or [value] is its content.
  bool get ok => problem == null;
}

/// An app-owned JSON file (usually under `ctx.dirs.data`) with the three things every app that keeps real data needs: an
/// atomic write (temp file, then rename), a read that tells "missing" from "damaged", and a way to set a damaged file aside
/// instead of overwriting it. `ConfigStore` does the same for the one settings file; this is for the app's own files.
///
/// Get one with [AppContextJson.dataJson] or wrap any [File].
class AppJsonFile {
  AppJsonFile(this.file);
  /// The file this wraps.
  final File file;

  /// Never throws for a missing or damaged file: see [AppJsonRead].
  AppJsonRead read() {
    if (!file.existsSync()) return const AppJsonRead(exists: false);
    try {
      return AppJsonRead(value: jsonDecode(file.readAsStringSync()), exists: true);
    } on FormatException catch (e) {
      return AppJsonRead(problem: 'not valid JSON: ${e.message}', exists: true);
    } on FileSystemException catch (e) {
      // Not UTF-8, or unreadable. (readAsStringSync throws FileSystemException, not FormatException, for bad UTF-8.)
      return AppJsonRead(problem: 'could not be read: ${e.message}', exists: true);
    }
  }

  /// Writes [json] atomically, creating the directory. Throws [FileSystemException] when the disk says no.
  void write(Object? json) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(json), flush: true);
    tmp.renameSync(file.path);
  }

  /// Moves a damaged file out of the way (never deletes it) and returns where it went (`<name>.damaged-<utc millis>`).
  File quarantine() => file.renameSync('${file.path}.damaged-${DateTime.now().toUtc().millisecondsSinceEpoch}');

  /// Deletes the file. A file that does not exist is fine.
  void delete() {
    if (file.existsSync()) file.deleteSync();
  }
}

/// Adds [dataJson] to [AppContext].
extension AppContextJson on AppContext {
  /// [name] under the app's data directory as an [AppJsonFile].
  AppJsonFile dataJson(String name) => AppJsonFile(dataFile(name));
}
