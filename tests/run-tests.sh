#!/usr/bin/env bash
# Runs claude-stats.sh on a small made-up log folder and checks the numbers.
# Usage: tests/run-tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

NO_COLOR=1 ./claude-stats.sh --offline --dir tests/fixtures/projects \
  --since 2026-09-01 --until 2026-09-30 --html "$tmp/report.html" > "$tmp/out.txt"

# Ignore leading, trailing and repeated spaces
sed 's/^ *//; s/ *$//; s/  */ /g' "$tmp/out.txt" > "$tmp/norm.txt"

fail=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! grep -Fxq -- "$line" "$tmp/norm.txt"; then echo "MISSING in terminal output: $line"; fail=1; fi
done < tests/expected.txt
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! grep -Fq -- "$line" "$tmp/report.html"; then echo "MISSING in HTML report: $line"; fail=1; fi
done < tests/expected-html.txt

if [ "$fail" -ne 0 ]; then echo "FAILED"; cat "$tmp/out.txt"; exit 1; fi
echo "OK: claude-stats.sh"
