import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';

import 'hello_app.dart';

Future<void> main() => AppContextKit.run(manifestAsset: 'app.json', app: (_) => const HelloApp());
