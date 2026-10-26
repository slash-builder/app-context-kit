#!/bin/sh
# Runs the Dart core and the Rust core on Linux, in throwaway containers.
#
#   tools/linux-test.sh                  both cores, as a non-root user
#   tools/linux-test.sh dart | rust      one core
#   LINUX_AS_ROOT=1 tools/linux-test.sh  as root (root ignores file mode bits: a few tests behave differently)
#
# The repo is mounted READ-ONLY at /src. Each container copies only what the core needs (spec/, the core, the fixtures)
# into a tmpfs at /work and builds there, so nothing is written back to the checkout. Packages come from the network
# (`dart pub get`, `cargo`), and nothing persists: every container is `--rm` and the caches live in the tmpfs.
#
# Images (override with the env vars):
#   DART_IMAGE  default dart:stable  (the core needs Dart ^3.0.0)
#   RUST_IMAGE  default rust:1.94    (any recent stable; the crate declares no rust-version)
# Nothing outside this repository is needed: the crates come from crates.io and the packages from pub.dev.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
DART_IMAGE="${DART_IMAGE:-dart:stable}"
RUST_IMAGE="${RUST_IMAGE:-rust:1.94}"
WHICH="${1:-both}"

docker info >/dev/null 2>&1 || { echo "docker is not available: cannot run the Linux tests"; exit 2; }
if [ "${LINUX_AS_ROOT:-0}" = 1 ]; then USER_ARGS="--user 0:0"; else USER_ARGS="--user 1000:1000"; fi

# Shared prologue: copy the needed parts of the read-only checkout into /work.
PROLOGUE='
set -eu
mkdir -p /work/home /work/app
export HOME=/work/home
cd /src
tar cf - --exclude=.dart_tool --exclude=build --exclude=target --exclude=pubspec.lock spec rust dart/app_context_kit | tar xf - -C /work/app
echo "kernel: $(uname -sr) $(uname -m); user: $(id -u):$(id -g)"
FAIL=0
# step NAME CMD...: run, show the totals (the last 60 lines if it failed), remember a failure, carry on.
step() {
  name=$1; shift
  if "$@" > /work/step.log 2>&1; then rc=0; else rc=$?; FAIL=1; fi
  echo "-- $name: exit $rc --"
  if [ $rc = 0 ]; then
    tr "\r" "\n" < /work/step.log | grep -E "test result|Running|All (other )?tests|skipped" | tail -n 12
  else
    tr "\r" "\n" < /work/step.log | tail -n 60
  fi
}
'

run_dart() {
  echo "== Dart core on Linux ($DART_IMAGE) =="
  docker run --rm $USER_ARGS --network bridge -v "$REPO:/src:ro" --tmpfs /work:exec,mode=1777,size=2g \
    -e PUB_CACHE=/work/pub-cache "$DART_IMAGE" sh -c "$PROLOGUE"'
    dart --version
    cd /work/app/dart/app_context_kit
    dart pub get | tail -2
    step "conformance fixtures (Dart)" dart test test/conformance_test.dart -r compact
    step "whole package (Dart)" dart test -r compact
    exit $FAIL
  '
}

run_rust() {
  echo "== Rust core on Linux ($RUST_IMAGE) =="
  docker run --rm $USER_ARGS --network bridge -v "$REPO:/src:ro" --tmpfs /work:exec,mode=1777,size=4g \
    -e CARGO_HOME=/work/cargo -e CARGO_TARGET_DIR=/work/target "$RUST_IMAGE" sh -c "$PROLOGUE"'
    cd /work/app/rust
    rustc --version; cargo --version
    step "conformance fixtures (Rust)" cargo test --test conformance
    step "whole crate (Rust)" cargo test
    exit $FAIL
  '
}

status=0
case "$WHICH" in
  dart) run_dart || status=1 ;;
  rust) run_rust || status=1 ;;
  both) run_dart || status=1; run_rust || status=1 ;;
  *) echo "usage: $0 [both|dart|rust]"; exit 2 ;;
esac
exit $status
