#!/usr/bin/env bash
# Tests ci/migrations.sh against a fixture repository with a base branch: a changed goose
# migration that adds NOT NULL without a default fails, a changed nullable column passes, an
# unchanged bad migration is not linted, the Down section is ignored, an empty glob does nothing,
# and a checksum mismatch aborts before any lint runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_SH="$ROOT/ci/migrations.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/versions.env"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

goose() {
  local up="$1" down="$2"
  cat <<SQL
-- +goose Up
SET lock_timeout = '1s';
SET statement_timeout = '5s';
$up
-- +goose Down
$down
SQL
}

# A base branch with an already-bad migration, then a feature branch whose changes are linted.
src="$tmp/src"
git init -q "$src"
git -C "$src" config user.email ci@example.invalid
git -C "$src" config user.name ci
git -C "$src" checkout -q -b main
mkdir -p "$src/migrations/old"
goose 'ALTER TABLE t ADD COLUMN IF NOT EXISTS old_required text NOT NULL;' \
  'ALTER TABLE t DROP COLUMN IF EXISTS old_required;' \
  >"$src/migrations/old/0001_old_required.sql"
git -C "$src" add -A
git -C "$src" commit -qm base

git clone -q --bare "$src" "$tmp/remote.git"
work="$tmp/work"
git clone -q "$tmp/remote.git" "$work"
git -C "$work" config user.email ci@example.invalid
git -C "$work" config user.name ci
git -C "$work" checkout -q -b feat

mkdir -p "$work/migrations/bad" "$work/migrations/good"
goose 'ALTER TABLE t ADD COLUMN IF NOT EXISTS bad_required text NOT NULL;' \
  'ALTER TABLE t DROP COLUMN IF EXISTS bad_required;' \
  >"$work/migrations/bad/0002_bad_required.sql"
# The Down section drops a column (unsafe, and it would trip several rules); only Up is linted.
goose 'ALTER TABLE t ADD COLUMN IF NOT EXISTS good_nullable text;' \
  'ALTER TABLE t DROP COLUMN IF EXISTS good_nullable;' \
  >"$work/migrations/good/0003_good_nullable.sql"
git -C "$work" add -A
git -C "$work" commit -qm feat

run() {
  local glob="$1"
  shift
  ( cd "$work" && env GITHUB_BASE_REF=main "$@" bash "$MIGRATIONS_SH" "$glob" )
}

# 1. A changed NOT NULL column without a default fails and names the rule and the file.
set +e
run 'migrations/bad/*.sql' >"$tmp/bad.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "a changed NOT NULL column should fail"
grep -q 'adding-required-field' "$tmp/bad.log" || fail "output should name the squawk rule"
grep -q '0002_bad_required.sql' "$tmp/bad.log" || fail "output should name the migration file"

# 2. A changed nullable column passes, and the Down section was not linted.
run 'migrations/good/*.sql' >"$tmp/good.log" 2>&1 \
  || { cat "$tmp/good.log" >&2; fail "a changed nullable column should pass"; }

# 3. The unchanged old migration is not linted, so its NOT NULL column cannot fail the pull request.
run 'migrations/old/*.sql' >"$tmp/old.log" 2>&1 \
  || { cat "$tmp/old.log" >&2; fail "an unchanged migration should be ignored"; }
grep -q 'no changed migrations' "$tmp/old.log" || fail "output should say no migration changed"

# 4. An empty glob does nothing and says why.
( cd "$work" && bash "$MIGRATIONS_SH" "" ) >"$tmp/empty.log" 2>&1 \
  || fail "an empty glob should pass"
grep -q 'no migrations-glob' "$tmp/empty.log" || fail "output should say the glob is empty"

# 5. No base branch (push or dispatch): lint nothing and say why.
( cd "$work" && env -u GITHUB_BASE_REF bash "$MIGRATIONS_SH" 'migrations/bad/*.sql' ) \
  >"$tmp/nobase.log" 2>&1 || fail "a run without GITHUB_BASE_REF should pass"
grep -q 'GITHUB_BASE_REF is empty' "$tmp/nobase.log" || fail "output should say why nothing ran"

# 6. A checksum mismatch aborts and leaves no binary in the cache. curl is stubbed, so the test
#    needs no network for this case.
printf 'not the squawk release\n' >"$tmp/fake"
mkdir -p "$tmp/curl-bin"
cat >"$tmp/curl-bin/curl" <<'STUB'
#!/usr/bin/env bash
# Offline curl: writes $STUB_ARCHIVE to the -o target.
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    --retry | -*)
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$out" ]] || {
  echo "stub-curl: no -o target" >&2
  exit 1
}
cat "$STUB_ARCHIVE" >"$out"
STUB
chmod +x "$tmp/curl-bin/curl"

cache="$tmp/cache-mismatch"
set +e
run 'migrations/bad/*.sql' \
  STUB_ARCHIVE="$tmp/fake" XDG_CACHE_HOME="$cache" \
  SQUAWK_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
  PATH="$tmp/curl-bin:$PATH" >"$tmp/mismatch.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "a checksum mismatch should fail"
[[ ! -e "$cache/squawk/$SQUAWK_VERSION/squawk" ]] || fail "a checksum mismatch left a binary in the cache"

echo "PASS: test-migrations"
