#!/usr/bin/env bash
#
# nostrLibBench Rust harness: builds the release binary from the pinned Cargo.lock (fat LTO,
# one codegen unit, generic x86-64 CPU target like Go's GOAMD64=v1) and runs it. Every HARNESS.md flag passes through:
#
#   rust/run.sh --relay ws://127.0.0.1:7777          # every client on `all`
#   rust/run.sh --quick --clients nostr-sdk-stream
#   rust/run.sh --list
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$(dirname "$HERE")"

# No -C target-cpu=native: apps ship builds for a generic CPU, and the Go and Zig harnesses
# build for the same baseline, so no compiled harness gets this machine's extra instructions.
export RUSTFLAGS="${RUSTFLAGS:-}"
# Two invocations, so cargo features do not unify across them: nostro2's `k256` (default, main
# binary) and `secp256k1` (sibling binary) features cannot be built together.
cargo build --release --locked --quiet --manifest-path "$HERE/Cargo.toml" -p libbench-rust >&2
cargo build --release --locked --quiet --manifest-path "$HERE/Cargo.toml" -p libbench-rust-nostro2-secp256k1 >&2

if [[ ! -f "$BENCH/.corpus/manifest.json" ]]; then
    python3 "$BENCH/corpus/prepare.py" >&2
fi

# Defaults first; flags the caller passes come later and win.
exec "$HERE/target/release/libbench-rust" \
    --corpus "$BENCH/.corpus" \
    --out "$BENCH/results/rust.json" \
    "$@"
