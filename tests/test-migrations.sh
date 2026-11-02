#!/usr/bin/env bash
# Tests ci/migrations.sh against a fixture repository with a base branch: a changed goose
# migration that adds NOT NULL without a default fails, a changed nullable column passes, an
# unchanged bad migration is not linted, the Down section is ignored, an empty glob does nothing,
# a checksum mismatch aborts before any lint runs, an unreachable origin fails with a clear
# checkout hint, and a migration under a subdirectory is linted from that working directory.
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

# 7. An unreachable origin with no base ref fails with a clear checkout hint, not a raw git error.
private="$tmp/private"
git init -q "$private"
git -C "$private" config user.email ci@example.invalid
git -C "$private" config user.name ci
goose 'ALTER TABLE t ADD COLUMN IF NOT EXISTS private_col text;' \
  'ALTER TABLE t DROP COLUMN IF EXISTS private_col;' \
  >"$private/migration.sql"
git -C "$private" add -A
git -C "$private" commit -qm private
git -C "$private" remote add origin "file://$tmp/missing-remote.git"
want="ci-migrations: cannot fetch origin/main; check out with fetch-depth: 0"
want+=" (private repositories with persist-credentials: false cannot fetch)"
set +e
( cd "$private" && env GITHUB_BASE_REF=main bash "$MIGRATIONS_SH" 'migration.sql' ) \
  >"$tmp/fetch.log" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "an unreachable origin should exit 1"
grep -Fq -- "$want" "$tmp/fetch.log" || fail "output should print the fetch-depth hint"
grep -q '^fatal:' "$tmp/fetch.log" && fail "output should not include a raw git error"

# 8. A migration below the working directory is linted when the step runs from that directory:
#    plain `git diff` prints paths relative to the repository root, so the script must ask for
#    paths relative to the working directory before it reads or reports them. The same fixture
#    from the repository root with a root-relative glob must keep working.
nested_src="$tmp/nested-src"
git init -q "$nested_src"
git -C "$nested_src" config user.email ci@example.invalid
git -C "$nested_src" config user.name ci
git -C "$nested_src" checkout -q -b main
mkdir -p "$nested_src/apps/api/internal/platform/migrations"
goose 'ALTER TABLE t ADD COLUMN IF NOT EXISTS seed text;' \
  'ALTER TABLE t DROP COLUMN IF EXISTS seed;' \
  >"$nested_src/apps/api/internal/platform/migrations/0001_seed.sql"
git -C "$nested_src" add -A
git -C "$nested_src" commit -qm base

git clone -q --bare "$nested_src" "$tmp/nested-remote.git"
nested="$tmp/nested-work"
git clone -q "$tmp/nested-remote.git" "$nested"
git -C "$nested" config user.email ci@example.invalid
git -C "$nested" config user.name ci
git -C "$nested" checkout -q -b feat

migrations_dir="$nested/apps/api/internal/platform/migrations"
mkdir -p "$migrations_dir/bad" "$migrations_dir/good"
goose 'ALTER TABLE t ADD COLUMN IF NOT EXISTS nested_required text NOT NULL;' \
  'ALTER TABLE t DROP COLUMN IF EXISTS nested_required;' \
  >"$migrations_dir/bad/0002_nested_required.sql"
goose 'ALTER TABLE t ADD COLUMN IF NOT EXISTS nested_nullable text;' \
  'ALTER TABLE t DROP COLUMN IF EXISTS nested_nullable;' \
  >"$migrations_dir/good/0003_nested_nullable.sql"
git -C "$nested" add -A
git -C "$nested" commit -qm feat

nested_run() {
  local dir="$1" glob="$2"
  ( cd "$dir" && env GITHUB_BASE_REF=main bash "$MIGRATIONS_SH" "$glob" )
}

# From apps/api, with a glob relative to it: the bad file fails, named relative to the same directory.
set +e
nested_run "$nested/apps/api" 'internal/platform/migrations/bad/*.sql' \
  >"$tmp/nested-bad.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "a changed NOT NULL column under a subdirectory should fail"
grep -q 'adding-required-field' "$tmp/nested-bad.log" \
  || fail "subdirectory output should name the squawk rule"
grep -q 'internal/platform/migrations/bad/0002_nested_required.sql' "$tmp/nested-bad.log" \
  || fail "subdirectory output should name the file relative to the working directory"
grep -q 'No such file or directory' "$tmp/nested-bad.log" \
  && fail "subdirectory output should not show a missing file"

nested_run "$nested/apps/api" 'internal/platform/migrations/good/*.sql' \
  >"$tmp/nested-good.log" 2>&1 \
  || { cat "$tmp/nested-good.log" >&2; fail "a changed nullable column under a subdirectory should pass"; }

# From the repository root with a root-relative glob, behaviour is unchanged.
set +e
nested_run "$nested" 'apps/api/internal/platform/migrations/bad/*.sql' \
  >"$tmp/nested-root-bad.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "a changed NOT NULL column from the repository root should fail"
grep -q 'adding-required-field' "$tmp/nested-root-bad.log" \
  || fail "root output should name the squawk rule"
grep -q 'apps/api/internal/platform/migrations/bad/0002_nested_required.sql' \
  "$tmp/nested-root-bad.log" \
  || fail "root output should name the file relative to the repository root"

nested_run "$nested" 'apps/api/internal/platform/migrations/good/*.sql' \
  >"$tmp/nested-root-good.log" 2>&1 \
  || { cat "$tmp/nested-root-good.log" >&2; fail "a changed nullable column from the repository root should pass"; }

echo "PASS: test-migrations"
