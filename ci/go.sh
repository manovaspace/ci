#!/usr/bin/env bash
# Go CI gate, run from a checkout: gitleaks, sibling replace resolution, gofmt, go vet,
# go test -race, govulncheck, golangci-lint. Tool versions come from ci/versions.env.
#
# Usage: ci/go.sh [--no-race] [repo-dir]
# Env:
#   CI_GOVULNCHECK       override the govulncheck command (tests only; default: pinned go run)
#   CI_GOLANGCI_LINT     override the golangci-lint command (tests only; default: pinned prebuilt)
#   CI_SIBLING_URL_BASE  prefix for sibling clone URLs (default https://; tests use file://)
#   GH_READ_TOKEN        GitHub read token for private github.com/manovaspace modules and siblings
set -euo pipefail

# Never let git prompt for credentials: a missing token must fail the gate, not hang it.
export GIT_TERMINAL_PROMPT=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/versions.env"
# shellcheck source=/dev/null
source "$HERE/lib/snapshot.sh"

export GOPRIVATE="${GOPRIVATE:-github.com/manovaspace/*}"
export GONOSUMDB="${GONOSUMDB:-$GOPRIVATE}"

race=(-race)
repo=.
for arg in "$@"; do
  case "$arg" in
    --no-race) race=() ;;
    *) repo="$arg" ;;
  esac
done
ROOT="$(cd "$repo" && pwd)"

if [[ -n "${GH_READ_TOKEN:-}" ]]; then
  # Private modules are fetched with the read token through git's insteadOf; the token is
  # never echoed and nothing is written to disk.
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="url.https://x-access-token:${GH_READ_TOKEN}@github.com/manovaspace/.insteadOf"
  export GIT_CONFIG_VALUE_0="https://github.com/manovaspace/"
fi

# Clone URL for a module path. The insteadOf above adds auth for github.com/manovaspace/*;
# a token is never embedded here and never printed.
sibling_url() {
  local modpath="$1" base="${CI_SIBLING_URL_BASE:-https://}"
  printf '%s%s.git' "$base" "$modpath"
}

# Clones every `replace <module> => ../<sibling>` target that is missing. Revision: the
# go.mod-required tag when it exists; otherwise the default branch (warned).
resolve_siblings() {
  local gomod="$ROOT/go.mod"
  [[ -f "$gomod" ]] || return 0
  local line modpath target dest required url
  while IFS= read -r line; do
    modpath="$(awk '{ if ($1 == "replace") print $2; else print $1 }' <<<"$line")"
    target="$(sed -n 's/.*=>[[:space:]]*\(\.\.[^[:space:]]*\).*/\1/p' <<<"$line")"
    [[ -n "$modpath" && -n "$target" ]] || continue
    dest="$(realpath -m "$ROOT/$target")"
    if [[ -e "$dest/go.mod" ]]; then
      continue
    fi
    required="$(awk -v m="$modpath" '$1 == m && $0 !~ /=>/ { print $2; exit }' "$gomod")"
    url="$(sibling_url "$modpath")"
    echo "==> sibling $modpath -> $dest (${required:-no required version})"
    if ! git clone -q "$url" "$dest"; then
      echo "ci-go: cannot clone sibling $modpath (set GH_READ_TOKEN for private modules)" >&2
      exit 1
    fi
    if [[ -n "$required" && "$(git -C "$dest" tag -l "$required")" == "$required" ]]; then
      git -C "$dest" checkout -q "tags/$required"
    else
      echo "warning: $modpath $required has no matching tag; using default branch" >&2
    fi
  done < <(grep -E '^[[:space:]]*(replace[[:space:]]+)?[^[:space:]]+[[:space:]]+(v[^[:space:]]+[[:space:]]+)?=>[[:space:]]*\.\.' "$gomod" || true)
}

ci_require_disk 5

echo "==> gitleaks"
"$HERE/gitleaks.sh" "$ROOT"

cd "$ROOT"
resolve_siblings

echo "==> gofmt"
unformatted="$(gofmt -l .)"
if [[ -n "$unformatted" ]]; then
  echo "ci-go: gofmt found unformatted files:" >&2
  printf '%s\n' "$unformatted" >&2
  exit 1
fi

if [[ -n "${CI_GOVULNCHECK:-}" ]]; then
  read -r -a vuln_cmd <<<"$CI_GOVULNCHECK"
else
  vuln_cmd=(go run "golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}")
fi
if [[ -n "${CI_GOLANGCI_LINT:-}" ]]; then
  read -r -a lint_cmd <<<"$CI_GOLANGCI_LINT"
else
  lint_cmd=("$HERE/golangci-lint.sh" run)
fi

echo "==> go vet"
go vet ./...

echo "==> go test"
go test "${race[@]}" -count=1 ./...

echo "==> govulncheck"
"${vuln_cmd[@]}" ./...

echo "==> golangci-lint"
"${lint_cmd[@]}" ./...
echo "go gate passed"
