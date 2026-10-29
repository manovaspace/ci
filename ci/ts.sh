#!/usr/bin/env bash
# TypeScript/Bun CI gate, run from a checkout: gitleaks, @orbit .npmrc (only when NPM_TOKEN is set),
# bun install --frozen-lockfile, then lint, typecheck, test, build when present.
#
# Usage: ci/ts.sh [repo-dir]
# Env:
#   NPM_TOKEN          read token for the @orbit scope on npm.internal.manova.space.
#                      Never set on pull_request runs. Never printed.
#   CI_SKIP_TESTS=1    allow a package with no `test` script
#   CI_EXTRA=<script>  run one more package script after the standard ones (must exist)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/lib/snapshot.sh"

repo="${1:-.}"
ROOT="$(cd "$repo" && pwd)"

has_script() {
  CI_SCRIPT_NAME="$1" bun -e 'const s = require("./package.json").scripts || {}; process.exit(s[process.env.CI_SCRIPT_NAME] ? 0 : 1)'
}

run_if_present() {
  if has_script "$1"; then
    echo "==> bun run $1"
    bun run "$1"
  fi
}

ci_require_disk 5

echo "==> gitleaks"
"$HERE/gitleaks.sh" "$ROOT"

cd "$ROOT"
[[ -f bun.lock || -f bun.lockb ]] || {
  echo "ci/ts.sh: no bun.lock or bun.lockb; --frozen-lockfile requires one" >&2
  exit 1
}

if [[ -n "${NPM_TOKEN:-}" ]]; then
  [[ ! -e .npmrc ]] || { echo "ci/ts.sh: .npmrc already exists; refusing to overwrite it" >&2; exit 1; }
  printf '@orbit:registry=https://npm.internal.manova.space/\n//npm.internal.manova.space/:_authToken=%s\n' \
    "$NPM_TOKEN" >.npmrc
  trap 'rm -f -- "$ROOT/.npmrc"' EXIT
fi

echo "==> bun install --frozen-lockfile"
bun install --frozen-lockfile

run_if_present lint
run_if_present typecheck

if has_script test; then
  echo "==> bun run test"
  bun run test
elif [[ "${CI_SKIP_TESTS:-}" == 1 ]]; then
  echo "==> no test script; CI_SKIP_TESTS=1"
else
  echo "ci/ts.sh: no test script in package.json (set CI_SKIP_TESTS=1 to allow)" >&2
  exit 1
fi

run_if_present build

if [[ -n "${CI_EXTRA:-}" ]]; then
  has_script "$CI_EXTRA" || { echo "ci/ts.sh: CI_EXTRA=$CI_EXTRA is not a package script" >&2; exit 1; }
  echo "==> bun run $CI_EXTRA"
  bun run "$CI_EXTRA"
fi
echo "ts gate passed"
