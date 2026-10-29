#!/usr/bin/env bash
# Runs every tests/test-*.sh with bash and reports PASS/FAIL per file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for t in "$HERE"/test-*.sh; do
  name="$(basename "$t" .sh)"
  if bash "$t"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    failed=1
  fi
done
exit "$failed"
