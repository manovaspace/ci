#!/usr/bin/env bash
# Local per-change gate for the workspace pre-push hook: secret scan of each pushed range (never
# skipped), lint (never skipped), then tests unless the push is docs-only or
# ORBIT_PREPUSH_SKIP_TESTS=1. Clears git's repository-local environment so tests cannot write to
# the pushing repository. Never installs dependencies, never reaches the network (except
# gitleaks' one-time cached download).
#
# Usage: ci/prepush.sh <repo-dir> <range> [<range>...]
#   each <range> is one rev-list argument string, e.g. "abc123..def456" or
#   "def456 --not --remotes=origin"
# Env:
#   ORBIT_PREPUSH_SKIP_TESTS=1  skip the test step only; the secret scan and lint still run
#   XDG_CACHE_HOME              GOTMPDIR default base (${XDG_CACHE_HOME:-$HOME/.cache}/go-tmp)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: ci/prepush.sh <repo-dir> <range> [<range>...]" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
[[ -n "$1" && -d "$1" ]] || usage
ROOT="$(cd "$1" && pwd)"
shift
ranges=("$@")
for range in "${ranges[@]}"; do
  words=()
  read -r -a words <<<"$range" || true
  [[ ${#words[@]} -gt 0 ]] || usage
done

# Same detection lint.sh uses: exit 0 when package.json defines the named script.
has_script() {
  CI_SCRIPT_NAME="$1" bun -e 'const s = require("./package.json").scripts || {}; process.exit(s[process.env.CI_SCRIPT_NAME] ? 0 : 1)'
}

# Union of changed paths over all ranges, one per line, sorted, no empty lines.
changed_files() {
  local range words
  for range in "${ranges[@]}"; do
    # The range is one rev-list argument string, split on purpose (no globbing).
    read -r -a words <<<"$range" || true
    git -C "$ROOT" log --name-only --pretty=format: "${words[@]}"
  done | sed '/^$/d' | sort -u
}

# True when every changed path is markdown or under docs/, and also when nothing changed.
is_docs_only() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      *.md | *.mdx | docs/*) ;;
      *) return 1 ;;
    esac
  done <<<"$files"
  return 0
}

run_tests() {
  if is_docs_only; then
    echo "ci-prepush: docs-only push, skipping tests"
  elif [[ "${ORBIT_PREPUSH_SKIP_TESTS:-}" == 1 ]]; then
    echo "ci-prepush: tests skipped (ORBIT_PREPUSH_SKIP_TESTS=1)"
  elif [[ -x "$ROOT/scripts/prepush.sh" ]]; then
    echo "==> scripts/prepush.sh"
    CI_PREPUSH_RANGES="$(printf '%s\n' "${ranges[@]}")" "$ROOT/scripts/prepush.sh" "${ranges[@]}"
  elif [[ -f "$ROOT/go.mod" ]]; then
    if [[ -z "${GOTMPDIR:-}" ]]; then
      # /tmp is a small tmpfs on the dev host; link steps need disk.
      GOTMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/go-tmp"
      mkdir -p "$GOTMPDIR"
      export GOTMPDIR
    fi
    echo "==> GOWORK=off go test ./..."
    GOWORK=off go test ./...
  elif [[ -f "$ROOT/package.json" ]]; then
    if [[ ! -d "$ROOT/node_modules" ]]; then
      echo "ci-prepush: node_modules missing, skipping tests (run bun install to test locally)"
    else
      command -v bun >/dev/null 2>&1 || {
        echo "ci-prepush: bun not on PATH, cannot read the test script" >&2
        exit 1
      }
      ran=0
      if has_script typecheck; then
        echo "==> bun run typecheck"
        bun run typecheck
        ran=1
      fi
      if has_script test; then
        echo "==> bun run test"
        bun run test
        ran=1
      fi
      if [[ $ran -eq 0 ]]; then
        echo "ci-prepush: no typecheck or test script, skipping"
      fi
    fi
  else
    echo "ci-prepush: no stack detected, skipping tests"
  fi
}

cd "$ROOT"

# git runs hooks with repository-local variables set (GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE,
# GIT_COMMON_DIR, ...). Tests that create throwaway repositories in temp dirs would inherit them and
# write to the pushing repository, so clear them all here. The git calls below use git -C "$ROOT".
# shellcheck disable=SC2046 # word splitting is intended: one variable name per line
unset $(git rev-parse --local-env-vars)

echo "==> secret scan"
for range in "${ranges[@]}"; do
  bash "$HERE/gitleaks.sh" --range "$range" "$ROOT"
done

echo "==> lint"
bash "$HERE/lint.sh" "$ROOT"

echo "==> tests"
files="$(changed_files)"
run_tests

echo "ci-prepush: passed"
