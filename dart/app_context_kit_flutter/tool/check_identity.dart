// Checks that a Flutter app declares the same identity everywhere it has to.
//
//   dart tool/check_identity.dart <app-dir> [<app-dir> ...]
//
// An app is declared in four places (they can drift apart): `app.json` (id, name, version), `pubspec.yaml` (version),
// the macOS runner (`macos/Runner/Configs/AppInfo.xcconfig`: PRODUCT_BUNDLE_IDENTIFIER, PRODUCT_NAME) and the Linux runner
// (`linux/CMakeLists.txt`: APPLICATION_ID; `linux/runner/my_application.cc`: window title). This reads them as plain text
// (no Flutter, no packages) and prints every disagreement.
//
// Exit code: 0 everything agrees, 1 at least one mismatch, 2 usage error or an app.json that cannot be read.
//
// Not checked: Windows (`windows/runner/Runner.rc`), Android and iOS identifiers, and the window title set from Dart.
import 'dart:convert';
import 'dart:io';

/// One finding. A [mismatch] fails the check; a note (not a mismatch) is for things worth knowing, such as a name that differs
/// only in letter case.
class IdentityFinding {
  const IdentityFinding(this.message, {this.mismatch = true});
  final String message;
  final bool mismatch;
  @override
  String toString() => '${mismatch ? 'MISMATCH' : 'note    '}  $message';
}

/// Reads the app in [appDir] and returns every finding (empty when everything agrees).
/// Throws [FormatException] if `app.json` is missing or unusable.
List<IdentityFinding> checkIdentity(Directory appDir) {
  final out = <IdentityFinding>[];
  String path(String rel) => '${appDir.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';

  final manifestFile = File(path('app.json'));
  if (!manifestFile.existsSync()) throw FormatException('no app.json in ${appDir.path}');
  final Object? decoded;
  try {
    decoded = jsonDecode(manifestFile.readAsStringSync());
  } on FormatException catch (e) {
    throw FormatException('app.json is not JSON: ${e.message}');
  }
  if (decoded is! Map || decoded['id'] is! String || decoded['name'] is! String || decoded['version'] is! String) {
    throw const FormatException('app.json needs string "id", "name" and "version"');
  }
  final id = decoded['id'] as String;
  final name = decoded['name'] as String;
  final version = decoded['version'] as String;

  String? firstGroup(String rel, RegExp re) {
    final f = File(path(rel));
    if (!f.existsSync()) return null;
    return re.firstMatch(f.readAsStringSync())?.group(1);
  }

  // pubspec.yaml: the version before any "+build".
  if (!File(path('pubspec.yaml')).existsSync()) {
    out.add(const IdentityFinding('pubspec.yaml not found, so the version was not compared', mismatch: false));
  } else {
    final raw = firstGroup('pubspec.yaml', RegExp(r'^version:\s*([^\s#]+)', multiLine: true));
    if (raw == null) {
      out.add(const IdentityFinding('pubspec.yaml has no version'));
    } else {
      final pubVersion = raw.split('+').first;
      if (pubVersion != version) out.add(IdentityFinding('version: app.json says $version but pubspec.yaml says $pubVersion'));
    }
  }

  // macOS runner.
  const macConfig = 'macos/Runner/Configs/AppInfo.xcconfig';
  if (!Directory(path('macos')).existsSync()) {
    out.add(const IdentityFinding('no macos/ folder, so the macOS identifiers were not compared', mismatch: false));
  } else {
    final bundle = firstGroup(macConfig, RegExp(r'^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(\S+)', multiLine: true));
    if (bundle == null) {
      out.add(const IdentityFinding('macOS: PRODUCT_BUNDLE_IDENTIFIER not found in $macConfig'));
    } else if (bundle != id) {
      out.add(IdentityFinding('id: app.json says $id but the macOS bundle id (PRODUCT_BUNDLE_IDENTIFIER) is $bundle'));
    }
    final product = firstGroup(macConfig, RegExp(r'^\s*PRODUCT_NAME\s*=\s*(.+?)\s*$', multiLine: true));
    if (product != null) out.addAll(_compareName(name, product, 'the macOS PRODUCT_NAME'));
  }

  // Linux runner.
  if (!Directory(path('linux')).existsSync()) {
    out.add(const IdentityFinding('no linux/ folder, so the Linux identifiers were not compared', mismatch: false));
  } else {
    final appId = firstGroup('linux/CMakeLists.txt', RegExp(r'set\(\s*APPLICATION_ID\s+"([^"]*)"\s*\)'));
    if (appId == null) {
      out.add(const IdentityFinding('Linux: APPLICATION_ID not found in linux/CMakeLists.txt'));
    } else if (appId != id) {
      out.add(IdentityFinding('id: app.json says $id but the Linux application id (APPLICATION_ID) is $appId'));
    }
    final title = firstGroup('linux/runner/my_application.cc', RegExp(r'gtk_(?:window|header_bar)_set_title\([^,]+,\s*"([^"]*)"\)'));
    if (title != null) out.addAll(_compareName(name, title, 'the Linux window title'));
  }
  return out;
}

String _squash(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

List<IdentityFinding> _compareName(String name, String other, String where) {
  if (name == other) return const [];
  if (_squash(name) == _squash(other)) {
    return [IdentityFinding('name: app.json says "$name" but $where is "$other" (same name, different letter case)', mismatch: false)];
  }
  return [IdentityFinding('name: app.json says "$name" but $where is "$other"')];
}

/// The command line, returning the exit code.
int run(List<String> args) {
  if (args.isEmpty || args.contains('-h') || args.contains('--help')) {
    stderr.writeln('usage: dart tool/check_identity.dart <app-dir> [<app-dir> ...]');
    return 2;
  }
  var code = 0;
  for (final a in args) {
    stdout.writeln('== $a');
    try {
      final findings = checkIdentity(Directory(a));
      for (final f in findings) {
        stdout.writeln('  $f');
      }
      if (findings.where((f) => f.mismatch).isEmpty) {
        stdout.writeln('  ok: id, name and version agree everywhere they were checked');
      } else if (code == 0) {
        code = 1;
      }
    } on FormatException catch (e) {
      stderr.writeln('  cannot check: ${e.message}');
      code = 2;
    }
  }
  return code;
}

void main(List<String> args) => exit(run(args));
