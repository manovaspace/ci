#!/usr/bin/env bash
# Tests ci/go.sh with fixtures and stubs: clean module passes, a reachable vuln fails,
# a planted secret fails, a sibling `replace => ../orbit-*` is cloned and resolved, unformatted
# source fails, and a private sibling without GH_READ_TOKEN fails fast instead of prompting.
# Tool stubs replace govulncheck and golangci-lint so the test needs no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures/go"
GO_SH="$ROOT/ci/go.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_go_sh() {
  # Stubs: govulncheck from fixture bin, golangci-lint as `true`.
  CI_GOVULNCHECK="$FIX/bin/stub-govulncheck.sh" CI_GOLANGCI_LINT=true bash "$GO_SH" "$@"
}

# 1. Clean module: exit 0 with race detector on (the default).
cp -R "$FIX/gomod-ok" "$tmp/ok"
run_go_sh "$tmp/ok" >"$tmp/ok.log" 2>&1 || { cat "$tmp/ok.log" >&2; fail "clean module should pass"; }

# 2. Reachable vulnerability (stubbed govulncheck exits 3): non-zero.
cp -R "$FIX/gomod-vuln" "$tmp/vuln"
set +e
run_go_sh --no-race "$tmp/vuln" >"$tmp/vuln.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "vulnerable module should fail"

# 3. Planted secret in the tree: gitleaks runs first and fails the gate.
cp -R "$FIX/gomod-ok" "$tmp/leak"
printf 'aws_access_key_id = %s%s\n' AKIA Q7ZK3M2NPXV5HBLT >"$tmp/leak/config.env"
set +e
run_go_sh --no-race "$tmp/leak" >"$tmp/leak.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "planted secret should fail the gate"

# 4. Sibling replace: ../orbit-lib is absent, so go.sh clones the module path from
#    CI_SIBLING_URL_BASE at the go.mod-required version (tag v0.1.0) next to the app.
remote="$tmp/remotes/github.com/manovaspace/orbit-lib.git"
lib_src="$tmp/lib-src"
mkdir -p "$lib_src"
git -C "$lib_src" init -q
git -C "$lib_src" config user.email ci@example.invalid
git -C "$lib_src" config user.name ci
printf 'module github.com/manovaspace/orbit-lib\n\ngo 1.26\n' >"$lib_src/go.mod"
printf 'package lib\n\nconst Name = "orbit-lib"\n' >"$lib_src/lib.go"
git -C "$lib_src" add -A
git -C "$lib_src" commit -qm "lib v0.1.0"
git -C "$lib_src" tag v0.1.0
git clone -q --bare "$lib_src" "$remote"

mkdir -p "$tmp/work"
cp -R "$FIX/gomod-sibling" "$tmp/work/app"
CI_SIBLING_URL_BASE="file://$tmp/remotes/" CI_GOVULNCHECK="$FIX/bin/stub-govulncheck.sh" CI_GOLANGCI_LINT=true \
  bash "$GO_SH" --no-race "$tmp/work/app" >"$tmp/sib.log" 2>&1 \
  || { cat "$tmp/sib.log" >&2; fail "sibling replace should resolve and pass"; }
[[ -f "$tmp/work/orbit-lib/go.mod" ]] || fail "sibling was not cloned to ../orbit-lib"
[[ "$(git -C "$tmp/work/orbit-lib" describe --tags --exact-match)" == v0.1.0 ]] \
  || fail "sibling not checked out at the required tag v0.1.0"

# 5. Unformatted source: gofmt lists the file and fails the gate.
cp -R "$FIX/gomod-ok" "$tmp/fmt"
printf 'func  Bad( ) {\nreturn\n}\n' >>"$tmp/fmt/main.go"
set +e
run_go_sh --no-race "$tmp/fmt" >"$tmp/fmt.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "unformatted source should fail the gate"
grep -q 'ci-go: gofmt' "$tmp/fmt.log" || fail "output should name the gofmt check"
grep -q 'main.go' "$tmp/fmt.log" || fail "output should list main.go"

# 6. Private sibling with no token: fail fast (no credential prompt, no hang).
cp -R "$FIX/gomod-private-sibling" "$tmp/priv"
set +e
env -u GH_READ_TOKEN CI_SIBLING_URL_BASE=file:///nonexistent/ \
  CI_GOVULNCHECK="$FIX/bin/stub-govulncheck.sh" CI_GOLANGCI_LINT=true \
  timeout 10 bash "$GO_SH" --no-race "$tmp/priv" >"$tmp/priv.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "private sibling without GH_READ_TOKEN should fail"
[[ $rc -ne 124 ]] || fail "private sibling without GH_READ_TOKEN timed out"
grep -q 'orbit-billing' "$tmp/priv.log" || fail "error should name the sibling module"
grep -q 'GH_READ_TOKEN' "$tmp/priv.log" || fail "error should mention GH_READ_TOKEN"

echo "PASS: test-go"
