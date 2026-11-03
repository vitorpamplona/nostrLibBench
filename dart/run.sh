#!/usr/bin/env bash
# nostrLibBench Dart harness launcher: install the pinned Dart SDK if missing, resolve every
# package from its pubspec.lock (--enforce-lockfile), AOT-compile one binary per library, run
# the orchestrator. All HARNESS.md flags pass through, e.g.
#   ./dart/run.sh --quick --workloads smoke --relay ws://127.0.0.1:7777
# Each client runs in a fresh process (see README.md).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

DART_VERSION="3.13.7"   # stable
sdk="$repo/.tools/dart-sdk"
if [[ ! -x "$sdk/bin/dart" ]] || [[ "$(cat "$sdk/version" 2>/dev/null)" != "$DART_VERSION" ]]; then
    echo "installing Dart SDK $DART_VERSION into $sdk" >&2
    mkdir -p "$repo/.tools"
    tmp="$(mktemp -d)"
    curl -fsSL "https://storage.googleapis.com/dart-archive/channels/stable/release/$DART_VERSION/sdk/dartsdk-linux-x64-release.zip" -o "$tmp/dart.zip"
    rm -rf "$sdk"
    unzip -q "$tmp/dart.zip" -d "$repo/.tools/"
    rm -rf "$tmp"
fi
# The top-level run.sh looks for .tools/<tool>/<tool>.
mkdir -p "$repo/.tools/dart"
ln -sf "$sdk/bin/dart" "$repo/.tools/dart/dart"
export PATH="$sdk/bin:$PATH"
export DART_SUPPRESS_ANALYTICS=true
dart --disable-analytics >/dev/null 2>&1 || true

# Build one package: $1 = package dir, $2 = output binary, $3 = "exe" or "cli" (build hooks).
build() {
    local dir="$1" out="$2" kind="$3" log
    if [[ -f "$out" ]] && [[ -z "$(find "$dir/bin" "$dir/pubspec.lock" "$here/common/lib" -newer "$out" -print -quit)" ]]; then
        return 0
    fi
    log="$(mktemp)"
    if ! (cd "$dir" && dart pub get --enforce-lockfile && mkdir -p "$(dirname "$out")" &&
          if [[ "$kind" == cli ]]; then dart build cli -o "$(dirname "$(dirname "$(dirname "$out")")")"; \
          else dart compile exe bin/main.dart -o "$out"; fi) > "$log" 2>&1; then
        echo "dart: build of $dir failed (its rows will report the error):" >&2
        tail -20 "$log" >&2
        rm -f "$out"
    fi
    rm -f "$log"
}

# the orchestrator's entry point is bin/bench.dart
if [[ ! -f "$here/build/bench" ]] || [[ -n "$(find "$here/bench/bin" -newer "$here/build/bench" -print -quit)" ]]; then
    (cd "$here/bench" && dart pub get --enforce-lockfile >/dev/null && dart compile exe bin/bench.dart -o "$here/build/bench" >/dev/null)
fi
for dir in "$here"/clients/*/; do
    name="$(basename "$dir")"
    if [[ -d "$dir/hook" ]] || grep -q '^  ndk:' "$dir/pubspec.yaml"; then
        # ndk has a build hook (it compiles its Rust library with cargo/rustup): `dart build cli`
        build "${dir%/}" "$here/build/$name/bundle/bin/main" cli
    else
        build "${dir%/}" "$here/build/$name/main" exe
    fi
done

cd "$repo"  # the default --corpus/--out paths are relative to the repo root
exec "$here/build/bench" --build-dir "$here/build" "$@"
