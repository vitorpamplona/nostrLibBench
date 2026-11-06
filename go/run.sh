#!/usr/bin/env bash
# nostrLibBench Go harness launcher: build from the pinned go.mod/go.sum, then run.
# Every HARNESS.md flag passes through, e.g. ./go/run.sh --quick --clients go-nostr-relay
#
# Builds three binaries into go/libbench/ (git-ignored):
#   libbench               every client, default build (pure-Go crypto)
#   libbench-secp-gonostr  go-nostr with its libsecp256k1 build tag (cgo)
#   libbench-secp-fiatjaf  fiatjaf.com/nostr with its libsecp256k1 build tag (cgo)
# (go-nostr and fiatjaf.com/nostr vendor the same libsecp256k1 C sources, so they cannot
# share one cgo binary.) The libbench parent runs each client in a fresh child process of
# the binary it needs. go.mod pins the Go toolchain; with the default GOTOOLCHAIN=auto an
# older local go downloads it. GOGC/GOMEMLIMIT/GOMAXPROCS are inherited and recorded.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

for a in "$@"; do
    if [[ "$a" == "--list" ]]; then
        (cd "$here" && go build -o libbench/libbench .) >&2
        exec "$here/libbench/libbench" --list
    fi
done

(
    cd "$here"
    go build -o libbench/libbench .
    if command -v "$(go env CC 2>/dev/null || echo gcc)" >/dev/null 2>&1; then
        CGO_ENABLED=1 go build -tags libsecp256k1,secp_gonostr -o libbench/libbench-secp-gonostr .
        CGO_ENABLED=1 go build -tags libsecp256k1,secp_fiatjaf -o libbench/libbench-secp-fiatjaf .
    else
        echo "go: no C compiler, the *-libsecp256k1 clients will report an error" >&2
    fi
) >&2

cd "$repo"  # the default --corpus/--out paths are relative to the repo root
exec "$here/libbench/libbench" "$@"
