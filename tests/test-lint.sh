#!/usr/bin/env bash
# Tests ci/lint.sh with offline fixtures: a clean Go module passes, unformatted Go fails,
# a package lint script runs, a failing script fails, a missing node_modules skips with a hint,
# and trees without a lint script or a known stack skip with exit 0.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures/lint"
LINT_SH="$ROOT/ci/lint.sh"
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

# 1. Go module that is formatted and vets clean.
cp -R "$FIX/go-ok" "$tmp/go-ok"
bash "$LINT_SH" "$tmp/go-ok" >"$tmp/go-ok.log" 2>"$tmp/go-ok.err" \
  || { cat "$tmp/go-ok.log" "$tmp/go-ok.err" >&2; fail "go-ok should pass"; }
grep -q 'ci-lint: passed (go)' "$tmp/go-ok.log" || fail "go-ok did not report passed (go)"

# 2. Unformatted Go source: gofmt lists main.go and fails. main.go ships as main.go.bad so the
#    workspace pre-commit gofmt -w cannot silently format the fixture in the tree.
cp -R "$FIX/go-bad" "$tmp/go-bad"
mv "$tmp/go-bad/main.go.bad" "$tmp/go-bad/main.go"
expect_fail go-bad bash "$LINT_SH" "$tmp/go-bad"
grep -q 'ci-lint: gofmt' "$tmp/go-bad.log" || fail "go-bad should name the gofmt check"
grep -q 'main.go' "$tmp/go-bad.log" || fail "go-bad should list main.go"

# 3. Package with a lint script: the script runs. The package.json of each TS fixture ships as
#    package.json.bad so the workspace Biome pass leaves the fixture whitespace alone.
cp -R "$FIX/ts-ok" "$tmp/ts-ok"
mv "$tmp/ts-ok/package.json.bad" "$tmp/ts-ok/package.json"
bash "$LINT_SH" "$tmp/ts-ok" >"$tmp/ts-ok.log" 2>&1 \
  || { cat "$tmp/ts-ok.log" >&2; fail "ts-ok should pass"; }
[[ "$(cat "$tmp/ts-ok/ran.log")" == lint ]] || fail "ts-ok lint script did not run"

# 4. Lint script exits non-zero: the gate fails.
cp -R "$FIX/ts-bad" "$tmp/ts-bad"
mv "$tmp/ts-bad/package.json.bad" "$tmp/ts-bad/package.json"
expect_fail ts-bad bash "$LINT_SH" "$tmp/ts-bad"

# 5. Missing node_modules: skip without installing (CI still runs the full gate).
cp -R "$FIX/ts-nomodules" "$tmp/ts-nomodules"
mv "$tmp/ts-nomodules/package.json.bad" "$tmp/ts-nomodules/package.json"
bash "$LINT_SH" "$tmp/ts-nomodules" >"$tmp/ts-nomodules.log" 2>&1 \
  || { cat "$tmp/ts-nomodules.log" >&2; fail "ts-nomodules should skip"; }
grep -q 'node_modules missing, skipping' "$tmp/ts-nomodules.log" \
  || fail "ts-nomodules should report the skip"

# 6. No lint script and no Biome: skip with exit 0.
cp -R "$FIX/ts-nolint" "$tmp/ts-nolint"
mv "$tmp/ts-nolint/package.json.bad" "$tmp/ts-nolint/package.json"
bash "$LINT_SH" "$tmp/ts-nolint" >"$tmp/ts-nolint.log" 2>&1 \
  || { cat "$tmp/ts-nolint.log" >&2; fail "ts-nolint should skip"; }
grep -q 'no lint script, skipping' "$tmp/ts-nolint.log" || fail "ts-nolint should report the skip"

# 7. No go.mod or package.json: skip with exit 0.
cp -R "$FIX/none" "$tmp/none"
bash "$LINT_SH" "$tmp/none" >"$tmp/none.log" 2>&1 \
  || { cat "$tmp/none.log" >&2; fail "none should skip"; }
grep -q 'ci-lint: no stack detected, skipping' "$tmp/none.log" || fail "none should report no stack"

# 8. No argument: the current directory is linted.
cp -R "$FIX/go-ok" "$tmp/cwd"
(cd "$tmp/cwd" && bash "$LINT_SH") >"$tmp/cwd.log" 2>&1 \
  || { cat "$tmp/cwd.log" >&2; fail "no-argument run in a go module should pass"; }

echo "PASS: test-lint"
