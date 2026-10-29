#!/usr/bin/env bash
# Tests the composite action and the workflow templates: downloads the pinned actionlint, lints the
# rendered templates and this repo's own workflows, then asserts the contract of action.yml and
# templates/ (runner variable, no docker, CodeQL triggers, no input interpolation in run: scripts,
# third-party actions pinned to a 40-hex commit SHA).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/ci/versions.env"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Fail on missing files before touching the network: the first run of this test in a checkout that
# has not been implemented yet should say what is missing, not stall on a download.
for f in action.yml templates/ci.yml templates/codeql.yml templates/deploy-ssh.yml; do
  [[ -f "$ROOT/$f" ]] || fail "$f is missing"
done

# Pinned actionlint: same cache dir and SHA-256 verification as ci/gitleaks.sh.
CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/manova-ci/actionlint-${ACTIONLINT_VERSION}"
BIN="${CACHE}/actionlint"
if [[ ! -x "$BIN" ]]; then
  mkdir -p "$CACHE"
  ARCHIVE="$(mktemp)"
  curl -sSfL -o "$ARCHIVE" \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
  echo "${ACTIONLINT_SHA256}  ${ARCHIVE}" | sha256sum -c
  tar -xzf "$ARCHIVE" -C "$CACHE" actionlint
  rm -f "$ARCHIVE"
  chmod +x "$BIN"
fi

# Templates are real workflows once the placeholders are replaced, so actionlint can parse them.
wf="$tmp/workflows"
mkdir -p "$wf"
for f in "$ROOT"/templates/*.yml; do
  sed -e 's/__STACK__/go/g' -e 's/__LANG__/go/g' -e 's/__SERVICE__/handbook/g' "$f" \
    >"$wf/$(basename "$f")"
done

if ! out="$("$BIN" -oneline "$wf"/*.yml 2>&1)"; then
  printf '%s\n' "$out" >&2
  fail "actionlint found problems in templates/ (rendered)"
fi
if ! out="$("$BIN" -oneline "$ROOT"/.github/workflows/*.yml 2>&1)"; then
  printf '%s\n' "$out" >&2
  fail "actionlint found problems in .github/workflows/"
fi

# 1. The CI template honours the runner variable, so a repository can switch to the standby runner.
grep -Fq "\${{ vars.CI_RUNNER || 'ubuntu-latest' }}" "$ROOT/templates/ci.yml" \
  || fail "1: templates/ci.yml should run on \${{ vars.CI_RUNNER || 'ubuntu-latest' }}"

# 2. Templates are portable: nothing in them depends on docker being available.
if grep -riq docker "$ROOT/templates"; then
  fail "2: templates/ should not mention docker"
fi

# 3. CodeQL is a scheduled/on-demand scan only: no push and no pull_request trigger.
if grep -qE '^[[:space:]]*push:' "$ROOT/templates/codeql.yml"; then
  fail "3: templates/codeql.yml should not trigger on push"
fi
if grep -qE '^[[:space:]]*pull_request:' "$ROOT/templates/codeql.yml"; then
  fail "3: templates/codeql.yml should not trigger on pull_request"
fi

# 4. No `${{ inputs.* }}` inside a `run:` script (script injection). Round-tripping through env: is
#    the rule; expressions are only allowed in `env:`, `with:`, `if:` and friends.
#    The awk below tracks a literal `run: |` block by indentation: everything indented deeper than
#    the `run:` key belongs to the script, the first line at or above that indent ends it.
offenders="$(awk '
  /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ {
    inrun = 1
    match($0, /^[[:space:]]*/)
    indent = RLENGTH
    next
  }
  inrun {
    if ($0 ~ /^[[:space:]]*$/) next
    match($0, /^[[:space:]]*/)
    if (RLENGTH <= indent) {
      inrun = 0
      next
    }
    if (index($0, "${{ inputs.") > 0) print FNR ": " $0
  }
' "$ROOT/action.yml")"
[[ -z "$offenders" ]] || fail "4: input expression interpolated into a run: script: ${offenders}"

# 5. Every third-party `uses:` is pinned to a full commit SHA. The in-repo action (`./`) and this
#    repository's own action (`manovaspace/ci@v1`) are the only moving references allowed.
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  case "$ref" in
    ./* | manovaspace/ci@v1) continue ;;
  esac
  [[ "$ref" =~ @[0-9a-f]{40}$ ]] || fail "5: $ref is not pinned to a 40-hex commit SHA"
done < <(grep -hE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]]+' \
  "$ROOT/action.yml" "$ROOT"/templates/*.yml \
  | sed -E 's/.*uses:[[:space:]]*([^[:space:]]+).*/\1/')

# 6. Deploy follows a successful CI run on main (or a manual dispatch), never a bare push.
grep -q 'workflow_run:' "$ROOT/templates/deploy-ssh.yml" \
  || fail "6: templates/deploy-ssh.yml should trigger on workflow_run"
grep -q 'conclusion == ' "$ROOT/templates/deploy-ssh.yml" \
  || fail "6: templates/deploy-ssh.yml should require a successful CI conclusion"
grep -q "workflow_run.event == 'push'" "$ROOT/templates/deploy-ssh.yml" \
  || fail "6: templates/deploy-ssh.yml should only deploy CI runs started by a push"
if grep -q 'push:' "$ROOT/templates/deploy-ssh.yml"; then
  fail "6: templates/deploy-ssh.yml should not trigger on push"
fi

echo "PASS: test-templates"
