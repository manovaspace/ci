#!/usr/bin/env bash
# Tests ci/prepush.sh with throwaway git repos: a clean Go range passes, a failing Go test in the
# range fails, a docs-only range skips tests, ORBIT_PREPUSH_SKIP_TESTS=1 skips tests, an executable
# scripts/prepush.sh replaces the default, a planted token fails even with tests skipped, and a
# node_modules-less package skips its tests. The secret scan runs on each range.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPUSH="$ROOT/ci/prepush.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Go tests and the lint step use the local toolchain; keep the go build tmp on disk.
export GOTMPDIR="$tmp/gotmp"
mkdir -p "$GOTMPDIR"
unset ORBIT_PREPUSH_SKIP_TESTS

expect_fail() {
  local name="$1"
  shift
  if "$@" >"$tmp/$name.log" 2>&1; then
    cat "$tmp/$name.log" >&2
    fail "$name should fail"
  fi
}

expect_pass() {
  local name="$1"
  shift
  "$@" >"$tmp/$name.log" 2>&1 || {
    cat "$tmp/$name.log" >&2
    fail "$name should pass"
  }
}

# commit <repo> <message>: commits the whole working tree with a fixed identity, no hooks.
commit() {
  git -C "$1" add -A
  git -C "$1" -c user.name=ci -c user.email=ci@example.invalid -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit -q -m "$2"
}

# new_go_repo <dir>: a Go module with one formatted file, committed as the base.
new_go_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  printf 'module example.com/prepush\n\ngo 1.21\n' >"$1/go.mod"
  printf 'package main\n\nfunc main() {}\n' >"$1/main.go"
  commit "$1" base
}

# write_failing_test <dir>: a gofmt-clean test that always fails.
write_failing_test() {
  printf 'package main\n\nimport "testing"\n\nfunc TestFails(t *testing.T) {\n\tt.Fatal("planted failure")\n}\n' \
    >"$1/fail_test.go"
}

# 1. Usage: no range, or no repo, exits 2.
set +e
bash "$PREPUSH" "$tmp" >/dev/null 2>&1
rc=$?
bash "$PREPUSH" >/dev/null 2>&1
rc2=$?
set -e
[[ $rc -eq 2 && $rc2 -eq 2 ]] || fail "usage errors should exit 2 (got $rc and $rc2)"

# 2. Clean Go range: secret scan, lint and go test pass; the default go test branch runs.
repo="$tmp/go-ok"
new_go_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'package main\n\nfunc helper() int { return 1 }\n' >"$repo/helper.go"
commit "$repo" "add helper"
expect_pass go-ok bash "$PREPUSH" "$repo" "$base..HEAD"
grep -q 'ci-prepush: passed' "$tmp/go-ok.log" || fail "go-ok should report passed"
grep -q 'GOWORK=off go test' "$tmp/go-ok.log" || fail "go-ok should run go test"

# 3. A failing Go test in the range fails the push.
repo="$tmp/go-fail"
new_go_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
write_failing_test "$repo"
commit "$repo" "add failing test"
expect_fail go-fail bash "$PREPUSH" "$repo" "$base..HEAD"
grep -q 'TestFails' "$tmp/go-fail.log" || fail "go-fail should show the failing test"

# 4. ORBIT_PREPUSH_SKIP_TESTS=1 skips the same failing test.
expect_pass go-skip env ORBIT_PREPUSH_SKIP_TESTS=1 bash "$PREPUSH" "$repo" "$base..HEAD"
grep -q 'ci-prepush: tests skipped (ORBIT_PREPUSH_SKIP_TESTS=1)' "$tmp/go-skip.log" \
  || fail "go-skip should report the skip"

# 5. Docs-only range: the failing test is already in the base, so running tests would fail; the
#    range only touches markdown and must skip them.
repo="$tmp/docs"
new_go_repo "$repo"
write_failing_test "$repo"
commit "$repo" "add failing test"
base="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$repo/docs"
printf '# Notes\n' >"$repo/docs/notes.md"
printf '# Readme\n' >"$repo/README.md"
commit "$repo" "docs only"
expect_pass docs bash "$PREPUSH" "$repo" "$base..HEAD"
grep -q 'ci-prepush: docs-only push, skipping tests' "$tmp/docs.log" \
  || fail "docs should report the docs-only skip"

# 6. An executable scripts/prepush.sh runs instead of the default go test. The override records
#    the ranges it receives; the failing Go test in the same range would fail the default path.
repo="$tmp/override"
new_go_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
write_failing_test "$repo"
mkdir -p "$repo/scripts"
cat >"$repo/scripts/prepush.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$CI_PREPUSH_RANGES" >"$PWD/override-ran"
SCRIPT
chmod +x "$repo/scripts/prepush.sh"
commit "$repo" "add override and failing test"
expect_pass override bash "$PREPUSH" "$repo" "$base..HEAD"
grep -q 'scripts/prepush.sh' "$tmp/override.log" || fail "override should announce scripts/prepush.sh"
[[ "$(cat "$repo/override-ran")" == "$base..HEAD" ]] \
  || fail "override should receive CI_PREPUSH_RANGES=$base..HEAD (got $(cat "$repo/override-ran"))"

# 7. A planted token in the range fails even with ORBIT_PREPUSH_SKIP_TESTS=1: the secret scan is
#    never skippable. The token is assembled at runtime so this file does not contain a match.
repo="$tmp/secret"
new_go_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'github_token = %s%s\n' ghp_ Q7vK2mW9xR4tB8nZ3pL6cH1dF5gJ0sY2aE7u >"$repo/config.env"
commit "$repo" "add config"
expect_fail secret env ORBIT_PREPUSH_SKIP_TESTS=1 bash "$PREPUSH" "$repo" "$base..HEAD"
grep -q 'leaks found: ' "$tmp/secret.log" || fail "secret should be reported by gitleaks"
if grep -q 'ci-prepush: passed' "$tmp/secret.log"; then
  fail "secret should not reach the passed line"
fi

# 8. Two ranges: the union of changed files decides; a docs-only second range does not hide the
#    Go change in the first one.
repo="$tmp/two-ranges"
new_go_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
write_failing_test "$repo"
commit "$repo" "failing test"
mid="$(git -C "$repo" rev-parse HEAD)"
printf '# Notes\n' >"$repo/NOTES.md"
commit "$repo" "docs"
expect_fail two-ranges bash "$PREPUSH" "$repo" "$base..$mid" "$mid..HEAD"
grep -q 'TestFails' "$tmp/two-ranges.log" || fail "two-ranges should run the Go test of the first range"

# 9. A package with node_modules missing: lint and tests both skip, no install is attempted.
repo="$tmp/ts-nomodules"
mkdir -p "$repo"
git -C "$repo" init -q
printf '{"name":"prepush-fixture","scripts":{"test":"exit 1"}}\n' >"$repo/package.json"
commit "$repo" base
base="$(git -C "$repo" rev-parse HEAD)"
printf '{"name":"prepush-fixture","version":"0.0.1","scripts":{"test":"exit 1"}}\n' >"$repo/package.json"
commit "$repo" "bump"
expect_pass ts-nomodules bash "$PREPUSH" "$repo" "$base..HEAD"
grep -q 'node_modules missing, skipping tests' "$tmp/ts-nomodules.log" \
  || fail "ts-nomodules should report the skipped tests"
[[ ! -e "$repo/node_modules" ]] || fail "ts-nomodules must not install dependencies"

# 10. A package with node_modules present: a failing typecheck fails the push and stops before the
#     test script. node_modules is an empty directory here, so nothing is installed or resolved.
repo="$tmp/ts-typecheck"
mkdir -p "$repo/node_modules"
git -C "$repo" init -q
printf '{"name":"prepush-fixture","scripts":{"typecheck":"exit 1","test":"touch ran"}}\n' >"$repo/package.json"
commit "$repo" base
base="$(git -C "$repo" rev-parse HEAD)"
printf '{"name":"prepush-fixture","version":"0.0.1","scripts":{"typecheck":"exit 1","test":"touch ran"}}\n' >"$repo/package.json"
commit "$repo" "bump"
expect_fail ts-typecheck bash "$PREPUSH" "$repo" "$base..HEAD"
grep -q '==> bun run typecheck' "$tmp/ts-typecheck.log" || fail "ts-typecheck should run typecheck"
[[ ! -e "$repo/ran" ]] || fail "ts-typecheck should stop before the test script"

echo "PASS: test-prepush"
