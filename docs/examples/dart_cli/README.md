# dart_cli

A command-line program on the App Context Kit core (pure Dart, no Flutter). It opens an `AppContext`, counts its launches in a setting, writes a file under the data directory and prints where things are. `test/kit_test.dart` is the testing example used in [Testing](../../TESTING.md).

Run it (from this directory). `APP_CONTEXT_SCRATCH` keeps everything in one throwaway folder instead of your real application folders:

```sh
dart pub get
APP_CONTEXT_SCRATCH=/tmp/app-context-demo dart run bin/main.dart
```

It prints this, and `launches` goes up by one each time you run it:

```
app      dev.example.hello 0.1.0
mode     real (scratch)
data     /tmp/app-context-demo/dev.example.hello/data
config   /tmp/app-context-demo/dev.example.hello/config
launches 1
venue    Venue: local (Venue is off for this app)
```

Run the tests: `dart test` (expected: `All tests passed!`, three tests).
