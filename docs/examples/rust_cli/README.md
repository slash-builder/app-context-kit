# rust_cli

The same program as [`../dart_cli`](../dart_cli), using the Rust crate in `rust/`: same `app.json`, same directories, same settings file.

Run it (from this directory). `APP_CONTEXT_SCRATCH` keeps everything in one throwaway folder:

```sh
APP_CONTEXT_SCRATCH=/tmp/app-context-demo-rs cargo run
```

It prints this, and `launches` goes up by one each time you run it:

```
app      dev.example.hello 0.1.0
mode     real (scratch)
data     /tmp/app-context-demo-rs/dev.example.hello/data
config   /tmp/app-context-demo-rs/dev.example.hello/config
launches 1
venue    Venue: local (Venue is off for this app)
```

The crate has no remote Venue session, so the last line always reports the `local` session. See [Getting started](../../GETTING-STARTED.md#rust).
