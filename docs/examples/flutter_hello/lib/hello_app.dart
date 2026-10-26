import 'package:app_context_kit/app_context_kit.dart';
import 'package:app_context_kit_flutter/app_context_kit_flutter.dart';
import 'package:flutter/material.dart';

class HelloApp extends StatefulWidget {
  const HelloApp({super.key});

  @override
  State<HelloApp> createState() => _HelloAppState();
}

class _HelloAppState extends State<HelloApp> {
  late final AppContext ctx;
  late final SessionSettings settings;
  late int taps;
  var _started = false;

  // An InheritedWidget cannot be read in initState, so read the context on the first didChangeDependencies.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    ctx = AppContextScope.of(context);
    settings = SessionSettings(ctx.config);
    taps = settings.get<int>('taps', 0);
  }

  void _tap() {
    setState(() => taps++);
    settings.set('taps', taps); // a setting, in <config>/config.json
    ctx.dataFile('taps.log').writeAsStringSync('$taps\n'); // a file, under <data>
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: ctx.manifest.name,
        home: Scaffold(
          appBar: AppBar(title: Text(ctx.manifest.name), actions: [ModeBadge.forContext(ctx)]),
          body: Column(children: [
            NotesBanner.forContext(ctx),
            Text('Taps: $taps'),
            FilledButton(onPressed: _tap, child: const Text('Tap')),
          ]),
        ),
      );
}
