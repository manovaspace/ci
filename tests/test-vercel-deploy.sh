#!/usr/bin/env bash
# Tests the reusable Vercel deploy workflow: lints it with the pinned actionlint, then asserts the
# reusable-workflow contract (declared inputs and secrets, the three deploy modes, third-party
# actions pinned to a 40-hex SHA, the runner variable, no docker, no expression interpolation into
# run: scripts).
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

WF="$ROOT/.github/workflows/vercel-deploy.yml"

# Fail on a missing file before touching the network.
[[ -f "$WF" ]] || fail "1: .github/workflows/vercel-deploy.yml is missing"

# Pinned actionlint: same cache dir and SHA-256 verification as ci/gitleaks.sh.
CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/manova-ci/actionlint-${ACTIONLINT_VERSION}"
BIN="${CACHE}/actionlint"
if [[ ! -x "$BIN" ]]; then
  mkdir -p "$CACHE"
  ARCHIVE="$tmp/actionlint.tar.gz"
  curl -sSfL -o "$ARCHIVE" \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
  echo "${ACTIONLINT_SHA256}  ${ARCHIVE}" | sha256sum -c
  tar -xzf "$ARCHIVE" -C "$CACHE" actionlint
  chmod +x "$BIN"
fi

if ! out="$("$BIN" -oneline "$WF" 2>&1)"; then
  printf '%s\n' "$out" >&2
  fail "2: actionlint found problems in .github/workflows/vercel-deploy.yml"
fi

# 3. The workflow is reusable and declares the caller-facing inputs and secrets.
grep -q 'workflow_call:' "$WF" || fail "3: workflow should be reusable (workflow_call)"
for name in working-directory staging-alias vercel-version bun-version node-version; do
  grep -qE "^[[:space:]]*${name}:" "$WF" || fail "3: input ${name} is not declared"
done
for name in VERCEL_TOKEN VERCEL_ORG_ID VERCEL_PROJECT_ID; do
  grep -qE "^[[:space:]]*${name}:" "$WF" || fail "3: secret ${name} is not declared"
done

# 4. No expression interpolation inside a `run:` script (script injection). Round-tripping through
#    env: is the rule; expressions are only allowed in `env:`, `with:`, `if:` and friends.
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
    if ($0 ~ /\$\{\{ (secrets|inputs)\./ || $0 ~ /\$\{\{ github\.(head_ref|event)/) print FNR ": " $0
  }
' "$WF")"
[[ -z "$offenders" ]] || fail "4: expression interpolated into a run: script: ${offenders}"

# 5. Every third-party `uses:` is pinned to a full commit SHA.
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  [[ "$ref" =~ @[0-9a-f]{40}$ ]] || fail "5: $ref is not pinned to a 40-hex commit SHA"
done < <(grep -hE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]]+' "$WF" \
  | sed -E 's/.*uses:[[:space:]]*([^[:space:]]+).*/\1/')

# 6. The runner variable selects the standby runner, as in every other workflow here.
runner="$(grep -E '^[[:space:]]*runs-on:' "$WF" | sed -E 's/^[[:space:]]*//')"
[[ "$runner" == "runs-on: \${{ vars.CI_RUNNER || 'ubuntu-latest' }}" ]] \
  || fail "6: runs-on should be \${{ vars.CI_RUNNER || 'ubuntu-latest' }}, got '${runner}'"

# 7. The three modes: preview and production builds, a staging alias, and the fork guard.
grep -Fq -- '--environment=preview' "$WF" || fail "7: no preview pull"
grep -Fq -- '--environment=production' "$WF" || fail "7: no production pull"
grep -Fq 'vercel alias set' "$WF" || fail "7: no staging alias"
grep -Fq 'head.repo.full_name' "$WF" || fail "7: no fork guard"

# 8. Portable and safe on fork pull requests: no docker, no pull_request_target.
if grep -riq docker "$WF"; then
  fail "8: vercel-deploy.yml should not mention docker"
fi
if grep -q 'pull_request_target' "$WF"; then
  fail "8: vercel-deploy.yml should not use pull_request_target"
fi

echo "PASS: test-vercel-deploy"
