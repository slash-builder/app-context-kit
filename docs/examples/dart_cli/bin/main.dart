import 'dart:io';

import 'package:app_context_kit/app_context_kit.dart';

Future<void> main() async {
  final manifest = AppManifest.parse(File('app.json').readAsStringSync());

  await AppContext.run(manifest, (ctx) async {
    // A setting: kept in <config>/config.json, written atomically.
    final launches = ctx.config.get<int>('launches', 0) + 1;
    ctx.config.set('launches', launches);

    // A file of the app's own: under <data>.
    ctx.dataFile('hello.txt').writeAsStringSync('launch $launches\n');

    print('app      ${ctx.manifest.id} ${ctx.manifest.version}');
    print('mode     ${ctx.mode.name}${ctx.scratch ? ' (scratch)' : ''}');
    print('data     ${ctx.dirs.data}');
    print('config   ${ctx.dirs.config}');
    print('launches $launches');
    print('venue    ${ctx.venue.description}');
  });
}
