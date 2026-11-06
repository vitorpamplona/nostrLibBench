#!/usr/bin/env bash
# nostrLibBench .NET harness launcher: install the pinned .NET SDK if missing, restore every
# project from its packages.lock.json (locked mode), build Release, run the orchestrator.
# All HARNESS.md flags pass through, e.g. ./dotnet/run.sh --quick --relay ws://127.0.0.1:7777
# Each client runs in a fresh process (one binary per library, see README.md).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

DOTNET_SDK_VERSION="10.0.403"   # current LTS (.NET 10) SDK; runtime 10.0.14
tools="$repo/.tools/dotnet"
export DOTNET_ROOT="$tools"
export PATH="$tools:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

if [[ ! -x "$tools/dotnet" ]] || ! "$tools/dotnet" --list-sdks 2>/dev/null | grep -q "^$DOTNET_SDK_VERSION "; then
    echo "installing .NET SDK $DOTNET_SDK_VERSION into $tools" >&2
    mkdir -p "$repo/.tools"
    installer="$(mktemp -d)/dotnet-install.sh"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$installer"
    bash "$installer" --version "$DOTNET_SDK_VERSION" --install-dir "$tools" --no-path >&2
fi

projects=(Bench Clients/NostrClient Clients/NNostr Clients/NostrNet Clients/NostrSdk Clients/Blockcore Clients/NostraFs Clients/NostrSharp)
for p in "${projects[@]}"; do
    dir="$here/$p"
    name="$(basename "$(ls "$dir"/*.csproj)" .csproj)"
    locked=()
    [[ -f "$dir/packages.lock.json" ]] && locked=(--locked-mode)
    log="$(mktemp)"
    if ! { dotnet restore "$dir" "${locked[@]}" --verbosity quiet &&
           dotnet build "$dir" -c Release --no-restore -o "$here/out/$name" --verbosity quiet -nologo; } > "$log" 2>&1; then
        cat "$log" >&2; rm -f "$log"; echo "dotnet: build of $p failed" >&2; exit 1
    fi
    rm -f "$log"
done

cd "$repo"  # the default --corpus/--out paths are relative to the repo root
exec "$here/out/Bench/Bench" "$@"
