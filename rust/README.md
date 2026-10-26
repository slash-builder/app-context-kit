# slashbuilder-app-context-kit

The Rust implementation of the App Context Kit: the root namespace for one running app. It resolves an app's manifest and directories, keeps a settings store that never overwrites a damaged file, has first-class scratch and mock modes, publishes a presence entry per running copy, and hides whether a resource broker is real, absent or fake.

Import it as `app_context_kit` (`use app_context_kit::...`).

It implements the written contract in [`spec/APP-CONTEXT.md`](https://github.com/slash-builder/app-context-kit/blob/main/spec/APP-CONTEXT.md) and passes the same shared conformance fixtures as the Dart implementation. This crate does not include peers or a remote resource-broker session; the Dart core has those.

Repository, documentation and the other implementations: https://github.com/slash-builder/app-context-kit

Licence: Apache-2.0.
