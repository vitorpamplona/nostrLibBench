#!/usr/bin/env bash
#
# nostrLibBench Rust harness: builds the release binary from the pinned Cargo.lock (fat LTO,
# one codegen unit, -C target-cpu=native) and runs it. Every HARNESS.md flag passes through:
#
#   rust/run.sh --relay ws://127.0.0.1:7777          # every client on `all`
#   rust/run.sh --quick --clients nostr-sdk-stream
#   rust/run.sh --list
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$(dirname "$HERE")"

export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"
cargo build --release --locked --quiet --manifest-path "$HERE/Cargo.toml" >&2

if [[ ! -f "$BENCH/.corpus/manifest.json" ]]; then
    python3 "$BENCH/corpus/prepare.py" >&2
fi

# Defaults first; flags the caller passes come later and win.
exec "$HERE/target/release/libbench-rust" \
    --corpus "$BENCH/.corpus" \
    --out "$BENCH/results/rust.json" \
    "$@"
