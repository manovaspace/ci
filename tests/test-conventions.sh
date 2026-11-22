#!/usr/bin/env bash
# Tests ci/conventions.sh on temp AGENTS.md files: missing file, missing block (warning, or failure
# with CONVENTIONS_REQUIRED=1), append, idempotent sync, stale block detection, and a sync that
# replaces the block and keeps the bytes before and after it unchanged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONV="$ROOT/ci/conventions.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_fail() {
  local name="$1"
  shift
  if "$@" >"$tmp/$name.log" 2>&1; then
    cat "$tmp/$name.log" >&2
    fail "$name should fail"
  fi
}

# 1. No AGENTS.md: check passes and creates nothing.
mkdir "$tmp/none"
bash "$CONV" check "$tmp/none" >"$tmp/none.log" 2>&1 || { cat "$tmp/none.log" >&2; fail "1: check without AGENTS.md should pass"; }
[[ ! -e "$tmp/none/AGENTS.md" ]] || fail "1: check must not create AGENTS.md"

# 2. AGENTS.md without a block: warning, exit 0; CONVENTIONS_REQUIRED=1 makes it exit 1.
mkdir "$tmp/noblock"
printf '# Repo\n\nHand-written rules.\n' >"$tmp/noblock/AGENTS.md"
bash "$CONV" check "$tmp/noblock" >"$tmp/noblock.log" 2>&1 || { cat "$tmp/noblock.log" >&2; fail "2: missing block should only warn"; }
grep -q '^::warning::.*conventions.sh sync' "$tmp/noblock.log" || fail "2: missing block should print a warning naming sync"
expect_fail 2-required env CONVENTIONS_REQUIRED=1 bash "$CONV" check "$tmp/noblock"

# 3. Sync appends the block; check then passes.
bash "$CONV" sync "$tmp/noblock" >/dev/null || fail "3: sync should append"
bash "$CONV" check "$tmp/noblock" >"$tmp/current.log" 2>&1 || { cat "$tmp/current.log" >&2; fail "3: check after sync should pass"; }
grep -q 'conventions v1 current' "$tmp/current.log" || fail "3: check should report conventions v1 current"

# 4. Sync twice leaves the file unchanged.
cp "$tmp/noblock/AGENTS.md" "$tmp/once.md"
bash "$CONV" sync "$tmp/noblock" >/dev/null || fail "4: second sync should succeed"
cmp "$tmp/once.md" "$tmp/noblock/AGENTS.md" || fail "4: sync is not idempotent"

# 5. Stale block: an edited line inside the block fails check; sync repairs it and keeps the text
#    before and after the block byte-identical.
printf '\nKeep this after.\n' >>"$tmp/noblock/AGENTS.md"
sed -i '/^<!-- manova:conventions v/a edited by hand' "$tmp/noblock/AGENTS.md"
expect_fail 5-stale bash "$CONV" check "$tmp/noblock"
grep -q '::error::.*stale: found v1, current v1' "$tmp/5-stale.log" || fail "5: stale error should name found and current versions"
bash "$CONV" sync "$tmp/noblock" >/dev/null || fail "5: sync should replace the stale block"
{
  printf '# Repo\n\nHand-written rules.\n\n'
  bash "$CONV" render
  printf '\nKeep this after.\n'
} >"$tmp/expected.md"
cmp "$tmp/expected.md" "$tmp/noblock/AGENTS.md" || fail "5: sync must keep bytes before and after the block"
bash "$CONV" check "$tmp/noblock" >/dev/null || fail "5: check after repair should pass"

# 6. A block stamped with another version is reported with both versions.
mkdir "$tmp/old"
printf '<!-- manova:conventions v0 — generated from manovaspace/ci conventions/core.md; edit it there -->\nold\n<!-- /manova:conventions -->\n' >"$tmp/old/AGENTS.md"
expect_fail 6-old bash "$CONV" check "$tmp/old"
grep -q 'found v0, current v1' "$tmp/6-old.log" || fail "6: old block should name found v0 and current v1"

# 7. Sync without AGENTS.md fails and creates nothing.
mkdir "$tmp/empty"
expect_fail 7-nofile bash "$CONV" sync "$tmp/empty"
[[ ! -e "$tmp/empty/AGENTS.md" ]] || fail "7: sync must not create AGENTS.md"

# 8. render starts with the marker line for the current version.
[[ "$(bash "$CONV" render | head -n 1)" == "<!-- manova:conventions v$(tr -d '[:space:]' < "$ROOT/conventions/VERSION") — "* ]] \
  || fail "8: render should start with <!-- manova:conventions v<VERSION>"
[[ "$(bash "$CONV" render | head -n 1)" == "<!-- manova:conventions v1 "* ]] || fail "8: render should start with v1 for VERSION 1"

echo "PASS: test-conventions"
