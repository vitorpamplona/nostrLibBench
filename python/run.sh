#!/usr/bin/env bash
# nostrLibBench Python harness launcher: python/run.sh [HARNESS.md flags...]
# Creates .venv from the pinned requirements.txt on first use (or when it changes), plus the
# nostrj overlay (requirements-nostrj.txt), then runs bench.py from the repo root.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON:-python3.13}"
VENV="$HERE/.venv"
PIP=("$VENV/bin/pip" install -q --disable-pip-version-check)

if [[ ! -x "$VENV/bin/python" ]]; then
  "$PY" -m venv "$VENV"
fi
if ! cmp -s "$HERE/requirements.txt" "$VENV/.requirements.installed"; then
  "${PIP[@]}" -r "$HERE/requirements.txt"
  cp "$HERE/requirements.txt" "$VENV/.requirements.installed"
fi
if ! cmp -s "$HERE/requirements-nostrj.txt" "$VENV/.requirements-nostrj.installed"; then
  rm -rf "$VENV/overlays/nostrj"
  "${PIP[@]}" --no-deps --target "$VENV/overlays/nostrj" -r "$HERE/requirements-nostrj.txt"
  cp "$HERE/requirements-nostrj.txt" "$VENV/.requirements-nostrj.installed"
fi
cd "$HERE/.."
exec "$VENV/bin/python" "$HERE/bench.py" "$@"
