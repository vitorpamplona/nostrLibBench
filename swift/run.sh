#!/usr/bin/env bash
# nostrLibBench Swift harness launcher: build from the pinned Package.resolved files, then run.
# Every HARNESS.md flag passes through, e.g. ./swift/run.sh --quick --workloads smoke
#
# Toolchain: `swift` from PATH on macOS (Xcode or a swift.org toolchain; swift-nostr needs
# Swift 6.3+). On Linux: .tools/swift/ in the repo (installed there from swift.org if
# missing, Swift $SWIFT_PIN for this Ubuntu/Debian), else `swift` from PATH.
#
# Builds (logs in swift/.build/logs/<package>.log, binaries linked into swift/.build/bin/):
#   swift/                       libbench, the parent: runs each client in a fresh process
#   swift/libs/bench-<package>/  one package per library, each with its own Package.resolved
# On Linux only the packages that build there are built; the Apple-only clients report
# `error: "macOS only"`. A package that fails to build does not stop the others: its clients
# report `error: "not built (...)"`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
SWIFT_PIN="${SWIFT_PIN:-6.4.2}"

ALL_PACKAGES="nostr-sdk-ios rust-nostr swift-nostr nostr-essentials"
LINUX_PACKAGES="swift-nostr"

install_linux_swift() {
    local dest="$repo/.tools/swift" os id ver plat file url tmp
    id="$(. /etc/os-release && echo "$ID")"
    ver="$(. /etc/os-release && echo "$VERSION_ID")"
    case "$id" in
        ubuntu) plat="ubuntu${ver//./}"; file="ubuntu$ver" ;;
        debian) plat="debian${ver}"; file="debian$ver" ;;
        *) echo "swift: no toolchain and no swift.org build for $id $ver; install Swift $SWIFT_PIN" >&2; exit 1 ;;
    esac
    [[ "$(uname -m)" == aarch64 ]] && { plat="$plat-aarch64"; file="$file-aarch64"; }
    url="https://download.swift.org/swift-$SWIFT_PIN-release/$plat/swift-$SWIFT_PIN-RELEASE/swift-$SWIFT_PIN-RELEASE-$file.tar.gz"
    tmp="$(mktemp -d)"
    echo "swift: installing Swift $SWIFT_PIN into $dest from $url" >&2
    curl -fL --retry 3 -o "$tmp/swift.tar.gz" "$url"
    if command -v gpg >/dev/null 2>&1; then
        curl -fsSL -o "$tmp/swift.tar.gz.sig" "$url.sig"
        curl -fsSL --compressed -o "$tmp/keys.asc" https://www.swift.org/keys/all-keys.asc
        GNUPGHOME="$tmp/gnupg" && mkdir -m 700 "$GNUPGHOME" && export GNUPGHOME
        gpg -q --import "$tmp/keys.asc" 2>/dev/null
        gpg -q --verify "$tmp/swift.tar.gz.sig" "$tmp/swift.tar.gz" || { echo "swift: bad signature" >&2; exit 1; }
        unset GNUPGHOME
    fi
    rm -rf "$dest" && mkdir -p "$dest"
    tar -xzf "$tmp/swift.tar.gz" -C "$dest" --strip-components=1
    rm -rf "$tmp"
}

if [[ "$(uname)" == Darwin ]]; then
    SWIFT="$(command -v swift || true)"
    [[ -n "$SWIFT" ]] || { echo "swift: not found; install Xcode (or its command line tools)" >&2; exit 1; }
else
    if [[ -x "$repo/.tools/swift/usr/bin/swift" ]]; then
        SWIFT="$repo/.tools/swift/usr/bin/swift"
    elif command -v swift >/dev/null 2>&1; then
        SWIFT="$(command -v swift)"
    else
        install_linux_swift
        SWIFT="$repo/.tools/swift/usr/bin/swift"
    fi
    export PATH="$(dirname "$SWIFT"):$PATH"
    # Optional: a libcurl built with WebSocket support (Ubuntu's 8.5 has none), for
    # URLSessionWebSocketTask on Linux. See README "Linux".
    if [[ -d "$repo/.tools/curl-ws/lib" ]]; then
        export LD_LIBRARY_PATH="$repo/.tools/curl-ws/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
fi

# Which library packages to build: all of them, or those of the --clients asked for.
packages="$ALL_PACKAGES"
list=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        --list) list=1 ;;
        --clients | --clients=*)
            if [[ "${args[$i]}" == --clients=* ]]; then cl="${args[$i]#--clients=}"; else cl="${args[$((i + 1))]:-}"; fi
            packages=""
            for c in ${cl//,/ }; do
                case "$c" in
                    nostr-sdk-ios-*) p=nostr-sdk-ios ;;
                    nostr-sdk-swift-*) p=rust-nostr ;;
                    swift-nostr-*) p=swift-nostr ;;
                    nostr-essentials-*) p=nostr-essentials ;;
                    *) p="" ;;
                esac
                [[ -n "$p" && " $packages " != *" $p "* ]] && packages="$packages $p"
            done
            ;;
    esac
done
if [[ "$(uname)" != Darwin ]]; then
    keep=""
    for p in $packages; do [[ " $LINUX_PACKAGES " == *" $p "* ]] && keep="$keep $p"; done
    packages="$keep"
fi

mkdir -p "$here/.build/logs" "$here/.build/bin"
"$SWIFT" build -c release --package-path "$here" >&2
ln -sf "$("$SWIFT" build -c release --package-path "$here" --show-bin-path)/libbench" "$here/.build/bin/libbench"

if [[ $list == 0 ]]; then
    for p in $packages; do
        dir="$here/libs/bench-$p"
        logf="$here/.build/logs/$p.log"
        rm -f "$here/.build/bin/libbench-$p"
        echo "swift: building $p (log: swift/.build/logs/$p.log)" >&2
        if "$SWIFT" build -c release --package-path "$dir" --only-use-versions-from-resolved-file > "$logf" 2>&1; then
            ln -sf "$("$SWIFT" build -c release --package-path "$dir" --show-bin-path)/libbench-$p" "$here/.build/bin/libbench-$p"
        else
            echo "swift: $p FAILED to build; its clients will report an error. Last lines of $logf:" >&2
            tail -n 15 "$logf" >&2
        fi
    done
fi

export LIBBENCH_SWIFT_DIR="$here"
LIBBENCH_SWIFT_VERSION="$("$SWIFT" --version 2>/dev/null | grep -o 'Swift version [^ ]* ([^)]*)' | head -1 | sed 's/^Swift version /Swift /')"
export LIBBENCH_SWIFT_VERSION="${LIBBENCH_SWIFT_VERSION:-Swift}"
cd "$repo" # the default --corpus/--out paths are relative to the repo root
exec "$here/.build/bin/libbench" "$@"
