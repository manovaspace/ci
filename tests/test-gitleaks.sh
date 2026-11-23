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

# Range mode: a git repo with a base commit, a clean commit and then a commit that adds a planted
# token. The token is assembled at runtime so this file does not contain a match.
repo="$tmp/range"
mkdir -p "$repo"
git -C "$repo" init -q
range_commit() {
  git -C "$repo" add -A
  git -C "$repo" -c user.name=ci -c user.email=ci@example.invalid -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit -q -m "$1"
}
printf 'nothing secret here\n' >"$repo/readme.txt"
range_commit base
base="$(git -C "$repo" rev-parse HEAD)"
printf 'more text\n' >>"$repo/readme.txt"
range_commit clean
clean="$(git -C "$repo" rev-parse HEAD)"

# scan_range <range> <log>: runs the range scan into <log> and returns its exit code. Pass/fail is
# checked on gitleaks' own verdict text too, so a range that merely errors cannot pass as a leak.
scan_range() {
  local rc
  set +e
  bash "$ROOT/ci/gitleaks.sh" --range "$1" "$repo" >"$2" 2>&1
  rc=$?
  set -e
  return "$rc"
}

scan_range "$base..$clean" "$tmp/clean.log" || fail "clean commit range should pass"
grep -q 'no leaks found' "$tmp/clean.log" || fail "clean commit range should report no leaks"
scan_range "HEAD --not $base" "$tmp/multi.log" || fail "clean multi-word range should pass"
grep -q 'no leaks found' "$tmp/multi.log" || fail "clean multi-word range should report no leaks"

printf 'github_token = %s%s\n' ghp_ Q7vK2mW9xR4tB8nZ3pL6cH1dF5gJ0sY2aE7u >"$repo/leak.env"
range_commit leak

if scan_range "$clean..HEAD" "$tmp/leak.log"; then
  fail "planted token in the range should fail the scan"
fi
grep -q 'leaks found: ' "$tmp/leak.log" || fail "planted token should be reported as a leak"

# The multi-word form reaches the leaking commit too, so the range string is split by gitleaks.
if scan_range "HEAD --not $clean" "$tmp/leak-multi.log"; then
  fail "multi-word range with the leaking commit should fail"
fi
grep -q 'leaks found: ' "$tmp/leak-multi.log" || fail "multi-word range should report the leak"

set +e
bash "$ROOT/ci/gitleaks.sh" --range >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 2 ]] || fail "--range without a range should exit 2 (got $rc)"

echo "PASS: test-gitleaks"
