#!/usr/bin/env bash
# nostrLibBench PHP harness launcher: php/run.sh [HARNESS.md flags...]
# Installs the packages pinned in composer.lock into php/vendor (git-ignored) on first use
# or when the lockfile changes, then runs bench.php from the caller's directory (the repo root).
# Needs PHP 8.3 with ext-gmp (swentel/nostr-php requires it; Debian/Ubuntu: php8.3-gmp).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHP="${PHP:-php}"

for a in "$@"; do [[ "$a" == "--list" ]] && exec "$PHP" "$HERE/bench.php" --list; done

"$PHP" -r 'exit(extension_loaded("gmp") && extension_loaded("pcntl") ? 0 : 1);' \
  || { echo "php: needs ext-gmp and ext-pcntl (e.g. apt install php8.3-gmp)" >&2; exit 1; }

if ! cmp -s "$HERE/composer.lock" "$HERE/vendor/.lock.installed" 2>/dev/null; then
  (cd "$HERE" && composer install --no-plugins --no-interaction --no-progress --quiet --no-dev --optimize-autoloader)
  cp "$HERE/composer.lock" "$HERE/vendor/.lock.installed"
fi
exec "$PHP" "$HERE/bench.php" "$@"
