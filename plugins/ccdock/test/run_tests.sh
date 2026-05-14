#!/usr/bin/env bash
# Runner for the ccdock plugin test suite.
#
# Runs Minitest unit tests (Ruby) for every module under scripts/lib/dock/,
# then runs Bats integration tests for the bash scripts (notify, dump) — if
# Bats is installed. If Bats is missing, prints a hint and exits 0 on the
# Ruby tests alone (Bats is treated as an optional integration layer).
#
# Required gems: mocha, webmock, minitest (gem install if missing).
# Optional: bats-core (brew install bats-core / apt install bats).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"

echo "==> Ruby unit tests"
RUBY_FILES=("$TEST_DIR"/dock/*_test.rb "$TEST_DIR"/dock/commands/*_test.rb)
ruby -I"$TEST_DIR" -e '
  ARGV.each { |f| load f }
' -- "${RUBY_FILES[@]}"

echo
if command -v bats >/dev/null 2>&1; then
  echo "==> Bats integration tests"
  bats "$TEST_DIR"/*.bats
else
  echo "==> Skipping bats tests (bats-core not installed)."
  echo "    Install with: brew install bats-core   # macOS"
  echo "                  apt install bats         # Debian/Ubuntu"
fi
