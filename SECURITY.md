# Security policy

## Reporting a vulnerability

**Do not open a public issue for a vulnerability.** Report it privately, by either of these:

1. **GitHub private vulnerability reporting:** use the "Report a vulnerability" button on the [Security tab of this repository](https://github.com/slash-builder/app-context-kit/security/advisories/new). Only the maintainer and you see the report.
2. **Email:** security@slashbuilder.com, for when GitHub's form is not an option for you.

Please include:

* what you found and where (file, command or page);
* the commit of `main` you looked at (`git rev-parse HEAD`) and your operating system;
* steps to reproduce it, or a short proof of concept;
* what you think the impact is, and whether anyone else knows.

## What to expect

You get an **acknowledgement within 7 days**, from a person. Nothing else is promised: this project has one maintainer, no paid support and no fixed fix time. If the report is valid, the reply says what happens next; if it is not, it says why.

## Supported versions

This project is pre-1.0 (the spec is version 0.1) and has no releases. **Only the latest commit of `main` is supported.** An older commit gets no fixes; update to `main`.

## Scope

In scope: the code, the spec and the documentation in **this repository**: the Dart core, the Flutter companion, the Rust crate, the conformance fixtures, the tools and the docs.

Out of scope: third-party services and software (GitHub, Flutter, Dart, Rust and their packages) and any other software the Kit can be used with. A problem there belongs with its owners. If you are not sure where something belongs, report it here, privately.
