#!/usr/bin/env bash
# Tests ci/lib/snapshot.sh: disk guard exits 75, snapshot yields the pinned tree, cleanup trap removes it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/ci/lib/snapshot.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Disk guard: an impossible threshold must exit 75; a trivial one must pass.
set +e
bash -c 'set -euo pipefail; source "$1"; ci_require_disk 99999' _ "$LIB" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 75 ]] || fail "ci_require_disk 99999 exited $rc, want 75"
bash -c 'set -euo pipefail; source "$1"; ci_require_disk 1' _ "$LIB" >/dev/null 2>&1 \
  || fail "ci_require_disk 1 should pass"

# 2. Snapshot of a local repo at an older sha: exact tree, CI_ROOT exported, removed on exit.
src="$tmp/src"
git init -q "$src"
git -C "$src" config user.email ci@example.invalid
git -C "$src" config user.name ci
printf 'one\n' >"$src/a.txt"
git -C "$src" add a.txt
git -C "$src" commit -qm one
old_sha="$(git -C "$src" rev-parse HEAD)"
printf 'two\n' >"$src/a.txt"
printf 'extra\n' >"$src/b.txt"
git -C "$src" add -A
git -C "$src" commit -qm two

dest="$tmp/snap"
bash -c '
  set -euo pipefail
  source "$1"
  ci_snapshot "$2" "$3" "$4"
  [[ "$CI_ROOT" == "$4" ]]
  [[ "$(cat "$CI_ROOT/a.txt")" == one ]]
  [[ ! -e "$CI_ROOT/b.txt" ]]
  [[ "$(git -C "$CI_ROOT" rev-parse HEAD)" == "$3" ]]
' _ "$LIB" "$src" "$old_sha" "$dest" || fail "snapshot does not match pinned sha tree"

[[ ! -e "$dest" ]] || fail "snapshot directory survived the cleanup trap"

echo "PASS: test-snapshot"
