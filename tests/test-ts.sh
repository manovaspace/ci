#!/usr/bin/env bash
# Tests ci/ts.sh with offline fixtures (a local file: dependency, so no network):
# standard scripts run in order, missing test fails unless CI_SKIP_TESTS=1, missing lockfile fails,
# CI_EXTRA runs one extra script and fails when it is absent, NPM_TOKEN writes a temporary @orbit .npmrc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures/ts"
TS_SH="$ROOT/ci/ts.sh"
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

# 1. Standard gate on a package with lint, typecheck, test, build (plus extra scripts).
cp -R "$FIX/ts-ok" "$tmp/ok"
bash "$TS_SH" "$tmp/ok" >"$tmp/ok.log" 2>&1 || { cat "$tmp/ok.log" >&2; fail "ts-ok should pass"; }
[[ "$(cat "$tmp/ok/ran.log")" == $'lint\ntypecheck\ntest\nbuild' ]] \
  || fail "standard scripts did not run in order: $(cat "$tmp/ok/ran.log")"

# 2. Missing test script: fails by default, passes with CI_SKIP_TESTS=1.
cp -R "$FIX/ts-no-test" "$tmp/notest"
expect_fail no-test bash "$TS_SH" "$tmp/notest"
cp -R "$FIX/ts-no-test" "$tmp/notest-skip"
CI_SKIP_TESTS=1 bash "$TS_SH" "$tmp/notest-skip" >/dev/null 2>&1 || fail "CI_SKIP_TESTS=1 should allow a missing test"

# 3. Missing lockfile: fails before install.
cp -R "$FIX/ts-nolock" "$tmp/nolock"
expect_fail no-lock bash "$TS_SH" "$tmp/nolock"

# 4. CI_EXTRA runs one more script; a missing one fails.
cp -R "$FIX/ts-ok" "$tmp/extra"
CI_EXTRA=selfcheck bash "$TS_SH" "$tmp/extra" >/dev/null 2>&1 || fail "CI_EXTRA=selfcheck should pass"
grep -qx selfcheck "$tmp/extra/ran.log" || fail "CI_EXTRA=selfcheck did not run"
cp -R "$FIX/ts-ok" "$tmp/extra-missing"
expect_fail extra-missing env CI_EXTRA=nope bash "$TS_SH" "$tmp/extra-missing"

# 5. NPM_TOKEN: the @orbit registry .npmrc exists during the run (probe script checks) and is removed after.
cp -R "$FIX/ts-ok" "$tmp/npm"
NPM_TOKEN=test-token-not-real CI_EXTRA=probe bash "$TS_SH" "$tmp/npm" >/dev/null 2>&1 \
  || fail "NPM_TOKEN run should pass"
grep -qx probe-ok "$tmp/npm/ran.log" || fail ".npmrc with @orbit registry was not present during the run"
[[ ! -e "$tmp/npm/.npmrc" ]] || fail ".npmrc containing a token survived the run"

echo "PASS: test-ts"
