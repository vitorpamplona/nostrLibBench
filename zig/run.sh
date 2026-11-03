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
# Every package of the build, transitive ones included: content hash, tarball URL and, for
# GitHub, the repo + commit to rebuild the same tarball with `git archive` when the tarball
# URL is not reachable (some sandboxes and proxies only let git through; Zig's own HTTP
# client also fails behind some proxies). `zig fetch` checks the content hash either way,
# so what gets built is exactly what build.zig.zon (and the libraries' own zon files) pin.
packages=(
  # zig-nostr/nostr v0.16.0 and its dependencies
  "nostr-0.16.0-CMyPzYmkEQBqRKpV_8jJYu769GBnHVzyZELHxbblGk0V https://github.com/zig-nostr/nostr/archive/dfa0e4b36f78400969800407d7cf3589fc48594c.tar.gz zig-nostr/nostr dfa0e4b36f78400969800407d7cf3589fc48594c"
  "N-V-__8AAO1SWwCbwhTAU7t6L3XQtTy6TzE8CiOGHjENn_rl https://github.com/bitcoin-core/secp256k1/archive/1a53f4961f337b4d166c25fce72ef0dc88806618.tar.gz bitcoin-core/secp256k1 1a53f4961f337b4d166c25fce72ef0dc88806618"
  "N-V-__8AAHEsCACb_b9D1HnCysDKIhKFOrITbxYh9JRh9ix5 https://github.com/LMDB/lmdb/archive/ce201088de95d26fc0da36ba805bf2ddc2ba74ff.tar.gz LMDB/lmdb ce201088de95d26fc0da36ba805bf2ddc2ba74ff"
  "zg-0.16.2-oGqU3HqftgI6rwFS90ypwfjgToH8Pz829OKuFURlm773 https://codeberg.org/atman/zg/archive/ce364b17d60b28fda1af24c6575b93c47afe043e.tar.gz - -"
  # privkeyio/libnostr-z v0.5.0 and its dependencies
  "nostr-0.5.0-JY6OcKMgEABIisCx3kmE4ybZbmnO5PyWyodAGjukxEJs https://github.com/privkeyio/libnostr-z/archive/5accad27a7ad71d503cd3c8152ea9540d2c23cda.tar.gz privkeyio/libnostr-z 5accad27a7ad71d503cd3c8152ea9540d2c23cda"
  "noscrypt-0.1.14-q33-Y3suyADLggvQIxeDkW7bCwZA4VuR2zAnm9M2Sbva https://github.com/privkeyio/noscrypt/archive/01f2ed5801198da139fd9856dcc475a80121acf5.tar.gz privkeyio/noscrypt 01f2ed5801198da139fd9856dcc475a80121acf5"
  "N-V-__8AAAZ8QgBoM0e_aCVlmr4bXY3hGnNSWSWNhluMsCs5 https://github.com/ashvardanian/StringZilla/archive/refs/tags/v4.5.1.tar.gz ashvardanian/StringZilla refs/tags/v4.5.1"
)

prefetch() {
    local hash="$1" url="$2" repo="$3" ref="$4" tmp got
    [[ -e "$ZIG_GLOBAL_CACHE_DIR/p/$hash.tar.gz" || -d "$ZIG_GLOBAL_CACHE_DIR/p/$hash" || -d "$here/zig-pkg/$hash" ]] && return 0
    tmp="$(mktemp -d)"
    if ! curl -fsSL -o "$tmp/pkg.tar.gz" "$url" 2>/dev/null; then
        if [[ "$repo" == "-" ]]; then
            echo "zig: cannot download $url" >&2; rm -rf "$tmp"; return 1
        fi
        echo "zig: $url unreachable, rebuilding it from git ($repo $ref)" >&2
        git init -q "$tmp/git"
        git -C "$tmp/git" fetch -q --depth 1 "https://github.com/$repo" "$ref"
        git -C "$tmp/git" archive --format=tar.gz --prefix=pkg/ FETCH_HEAD > "$tmp/pkg.tar.gz"
    fi
    got="$(cd "$here" && "$zig" fetch "$tmp/pkg.tar.gz")"
    rm -rf "$tmp"
    if [[ "$got" != "$hash" ]]; then
        echo "zig: hash mismatch for $url: got $got, pinned $hash" >&2; return 1
    fi
}

for p in "${packages[@]}"; do
    # shellcheck disable=SC2086
    prefetch $p
done

(cd "$here" && "$zig" build -Doptimize=ReleaseFast) >&2

cd "$repo"  # the default --corpus/--out paths are relative to the repo root
exec "$here/zig-out/bin/libbench" "$@"
