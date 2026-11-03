#!/usr/bin/env bash
#
# nostrLibBench: which Nostr client library, in any language, gets a relay's events
# through its WebSocket client, parser and signature verification fastest?
#
#   ./run.sh                         # every harness whose toolchain is installed
#   ./run.sh --quick                 # smoke run (numbers are noisy)
#   ./run.sh --only rust,go          # a subset of harnesses
#   ./run.sh --workloads all,notes   # any HARNESS.md flag is passed to every harness
#
# Builds and starts the relay (relay/, port $RELAY_PORT, default 7777), runs the harnesses
# one after another (never in parallel: they would steal cores from each other), stops the
# relay. Results land in results/<harness>.json and the ranking in results/report.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_HARNESSES="rust go jvm node bun deno python ruby php dotnet dart"
PORT="${RELAY_PORT:-7777}"

ONLY=""
REBUILD=0
PASS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY="${2//,/ }"; shift 2 ;;
        --rebuild-corpus) REBUILD=1; shift ;;
        *) PASS+=("$1"); shift ;;
    esac
done
HARNESSES="${ONLY:-$ALL_HARNESSES}"

if [[ $REBUILD == 1 || ! -f "$HERE/.corpus/manifest.json" ]]; then
    python3 "$HERE/corpus/prepare.py" ${CORPUS_SOURCE:+--source "$CORPUS_SOURCE"}
fi

(cd "$HERE/relay" && cargo build --release --quiet)
"$HERE/relay/target/release/blast-relay" --corpus "$HERE/.corpus" --port "$PORT" > "$HERE/.relay.log" 2>&1 &
RELAY_PID=$!
trap 'kill $RELAY_PID 2>/dev/null || true' EXIT
for _ in $(seq 50); do
    grep -q listening "$HERE/.relay.log" 2>/dev/null && break
    sleep 0.1
done
grep -q listening "$HERE/.relay.log" || { echo "relay did not start:" >&2; cat "$HERE/.relay.log" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

FAILED=()
cd "$HERE"
for h in $HARNESSES; do
    case "$h" in
        rust) need=cargo; launcher=("$HERE/rust/run.sh") ;;
        go) need=go; launcher=("$HERE/go/run.sh") ;;
        jvm) need=java; launcher=("$HERE/jvm/run.sh") ;;
        node | bun | deno) need=node; launcher=("$HERE/node/run.sh" --runtime "$h") ;;
        python) need=python3; launcher=("$HERE/python/run.sh") ;;
        ruby) need=ruby; launcher=("$HERE/ruby/run.sh") ;;
        php) need=php; launcher=("$HERE/php/run.sh") ;;
        dotnet) need=dotnet; launcher=("$HERE/dotnet/run.sh") ;;
        dart) need=dart; launcher=("$HERE/dart/run.sh") ;;
        *) echo "unknown harness: $h (known: $ALL_HARNESSES)" >&2; exit 2 ;;
    esac
    if [[ ! -x "${launcher[0]}" ]]; then
        echo "== $h: skipped, no harness yet" >&2
        continue
    fi
    if ! have "$need" && [[ ! -x "$HERE/.tools/$need/$need" ]]; then
        echo "== $h: skipped, '$need' not installed" >&2
        continue
    fi
    echo "== $h"
    if ! "${launcher[@]}" --relay "ws://127.0.0.1:$PORT" "${PASS[@]}"; then
        echo "== $h: FAILED" >&2
        FAILED+=("$h")
    fi
done

python3 "$HERE/report/report.py"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "harnesses that failed: ${FAILED[*]}" >&2
    exit 1
fi
