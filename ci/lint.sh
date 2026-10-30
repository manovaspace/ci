#!/usr/bin/env bash
# Fast, offline lint gate for the workspace pre-push hook: gofmt and go vet for a Go module,
# the package `lint` script or Biome for a Bun package, and a clean skip for anything else.
# Never installs, never reaches the network.
#
# Usage: ci/lint.sh [repo-dir]
set -euo pipefail

repo="${1:-.}"
ROOT="$(cd "$repo" && pwd)"

# Same detection ci/ts.sh uses: exit 0 when package.json defines the named script.
has_script() {
  CI_SCRIPT_NAME="$1" bun -e 'const s = require("./package.json").scripts || {}; process.exit(s[process.env.CI_SCRIPT_NAME] ? 0 : 1)'
}

lint_go() {
  local unformatted
  echo "==> gofmt"
  unformatted="$(gofmt -l .)"
  if [[ -n "$unformatted" ]]; then
    echo "ci-lint: gofmt found unformatted files:" >&2
    printf '%s\n' "$unformatted" >&2
    exit 1
  fi
  echo "==> go vet"
  # Vet this module on its own: an ancestor go.work (the developer's workspace) does not
  # necessarily list the repo being linted, and `go vet ./...` fails when it does not.
  GOWORK=off go vet ./...
}

lint_ts() {
  if [[ ! -d node_modules ]]; then
    # Pre-push must never install and must not block a worktree that has no dependencies yet;
    # the full gate in CI still lints the pushed tree.
    echo "ci-lint: node_modules missing, skipping (run bun install to lint locally)"
    exit 0
  fi
  if has_script lint; then
    echo "==> bun run lint"
    bun run lint
  elif [[ -x node_modules/.bin/biome ]]; then
    echo "==> biome check ."
    node_modules/.bin/biome check .
  else
    # A skip is a pass, but never claim a lint ran.
    echo "ci-lint: no lint script, skipping"
    exit 0
  fi
}

cd "$ROOT"

if [[ -f go.mod ]]; then
  lint_go
  echo "ci-lint: passed (go)"
elif [[ -f package.json ]]; then
  lint_ts
  echo "ci-lint: passed (ts)"
else
  echo "ci-lint: no stack detected, skipping"
fi
