#!/usr/bin/env bash
# Tests ci/gitleaks.sh: fails on a planted key, passes on a clean tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

clean="$tmp/clean"
mkdir -p "$clean"
printf 'nothing secret here\n' >"$clean/readme.txt"

leaky="$tmp/leaky"
mkdir -p "$leaky"
# Assembled at runtime so this test file itself does not contain a match.
printf 'aws_access_key_id = %s%s\n' AKIA Q7ZK3M2NPXV5HBLT >"$leaky/config.env"

bash "$ROOT/ci/gitleaks.sh" "$clean" >/dev/null 2>&1 || fail "clean tree should pass"

set +e
bash "$ROOT/ci/gitleaks.sh" "$leaky" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "planted key should fail the scan"

echo "PASS: test-gitleaks"
