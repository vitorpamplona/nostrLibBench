#!/usr/bin/env bash
# nostrLibBench Ruby harness launcher: ruby/run.sh [HARNESS.md flags...]
# Installs the gems pinned in Gemfile.lock into ruby/vendor (git-ignored) on first use or
# when the lockfile changes, then runs bench.rb from the caller's directory (the repo root).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BUNDLE_GEMFILE="$HERE/Gemfile"
export BUNDLE_APP_CONFIG="$HERE/.bundle"
export BUNDLE_PATH="$HERE/vendor"
export BUNDLE_FROZEN=true
export BUNDLE_SILENCE_ROOT_WARNING=1

for a in "$@"; do [[ "$a" == "--list" ]] && exec ruby "$HERE/bench.rb" --list; done

if ! cmp -s "$HERE/Gemfile.lock" "$HERE/vendor/.lock.installed" 2>/dev/null; then
  # rbsecp256k1 (the :fast group, one variant row) links the system libsecp256k1
  # (Debian/Ubuntu: libsecp256k1-dev); without it, install everything else and that row
  # reports the missing gem as its error.
  bundle config set --local build.rbsecp256k1 --with-system-library >/dev/null
  if ! bundle install --quiet; then
    echo "ruby: bundle install failed; retrying without the :fast group (rbsecp256k1)" >&2
    BUNDLE_WITHOUT=fast bundle install --quiet
  fi
  cp "$HERE/Gemfile.lock" "$HERE/vendor/.lock.installed"
fi
exec ruby "$HERE/bench.rb" "$@"
