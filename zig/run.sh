#!/usr/bin/env bash
# nostrLibBench Zig harness launcher: install the pinned Zig, build from the pinned
# build.zig.zon (URLs + content hashes), then run. Every HARNESS.md flag passes through,
# e.g. ./zig/run.sh --quick --clients zig-nostr-relay
#
# Zig is not a system package here: the pinned release tarball from ziglang.org (checked
# against its published SHA-256) is unpacked into the git-ignored .tools/zig/ when missing.
# `zig build -Doptimize=ReleaseFast` builds three binaries into zig/zig-out/bin/:
#   libbench            the driver (no Nostr library): parses flags, re-executes per client
#   libbench-zignostr   zig-nostr/nostr clients (libsecp256k1 compiled from source)
#   libbench-libnostrz  privkeyio/libnostr-z clients (noscrypt + libsecp256k1, OpenSSL)
# The two libraries each compile their own libsecp256k1, so they cannot share one binary.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

ZIG_VERSION=0.16.0
ZIG_SHA256_X86_64=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ZIG_SHA256_AARCH64=""  # filled from ziglang.org/download/index.json when needed

tools="$repo/.tools/zig"
zig="$tools/zig"

install_zig() {
    local arch sha url tmp
    arch="$(uname -m)"
    case "$arch" in
        x86_64) sha="$ZIG_SHA256_X86_64" ;;
        aarch64|arm64) arch=aarch64; sha="$ZIG_SHA256_AARCH64" ;;
        *) echo "zig: unsupported architecture $arch" >&2; exit 1 ;;
    esac
    url="https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz"
    if [[ -z "$sha" ]]; then
        sha="$(curl -fsSL https://ziglang.org/download/index.json |
            python3 -c "import json,sys; print(json.load(sys.stdin)['$ZIG_VERSION']['$arch-linux']['shasum'])")"
    fi
    echo "zig: installing Zig $ZIG_VERSION into $tools" >&2
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/zig.tar.xz" "$url"
    echo "$sha  $tmp/zig.tar.xz" | sha256sum -c --quiet -
    mkdir -p "$tmp/x"
    tar -xJf "$tmp/zig.tar.xz" -C "$tmp/x" --strip-components=1
    rm -rf "$tools"
    mkdir -p "$(dirname "$tools")"
    mv "$tmp/x" "$tools"
    rm -rf "$tmp"
}

if [[ ! -x "$zig" || "$("$zig" version 2>/dev/null)" != "$ZIG_VERSION" ]]; then
    install_zig
fi

# Keep Zig's package cache inside the repo's git-ignored tool dir, not in ~/.cache.
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$repo/.tools/zig-cache}"
[[ "${ZIG_HARNESS_INSTALL_ONLY:-}" == 1 ]] && exit 0
(cd "$here" && "$zig" build -Doptimize=ReleaseFast) >&2

cd "$repo"  # the default --corpus/--out paths are relative to the repo root
exec "$here/zig-out/bin/libbench" "$@"
