#!/usr/bin/env bash
# Lint goose Postgres migrations that changed against the pull request base with pinned squawk.
# Old migrations are never linted, so a rule added later cannot fail unrelated pull requests.
#
# Usage: ci/migrations.sh [glob]
# Env:
#   MIGRATIONS_GLOB    glob of migration files (an argument wins); empty means nothing to do
#   GITHUB_BASE_REF    pull request base branch; empty (push or dispatch) means lint nothing
#   SQUAWK_VERSION     pin override, normally read from ci/versions.env
#   SQUAWK_SHA256      pin override, normally read from ci/versions.env (tests use it)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# An exported SQUAWK_SHA256 wins over versions.env (tests override it); capture it first.
sha_override="${SQUAWK_SHA256:-}"
# shellcheck source=/dev/null
source "$HERE/versions.env"
if [[ -n "$sha_override" ]]; then
  SQUAWK_SHA256="$sha_override"
fi

glob="${1:-${MIGRATIONS_GLOB:-}}"
if [[ -z "$glob" ]]; then
  echo "ci-migrations: no migrations-glob set; skipping"
  exit 0
fi

base="${GITHUB_BASE_REF:-}"
if [[ -z "$base" ]]; then
  echo "ci-migrations: GITHUB_BASE_REF is empty (not a pull_request event); no changed migrations to lint"
  exit 0
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "ci-migrations: not inside a git checkout; cannot find changed migrations" >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "origin/$base^{commit}" >/dev/null; then
  echo "ci-migrations: fetching origin/$base"
  git fetch --no-tags --depth=1 origin "+refs/heads/$base:refs/remotes/origin/$base"
fi

# The glob is a git pathspec relative to the current directory (the action's working-directory).
read -r -a patterns <<<"$glob"
if ! changed="$(git diff --name-only --diff-filter=AM "origin/$base...HEAD" -- "${patterns[@]}" 2>/dev/null)"; then
  # actions/checkout fetches the pull request merge commit at depth 1, so there is no merge base.
  # The merge tree against the base tip carries exactly the pull request's changes.
  changed="$(git diff --name-only --diff-filter=AM "origin/$base" HEAD -- "${patterns[@]}")"
fi

if [[ -z "$changed" ]]; then
  echo "ci-migrations: no changed migrations match $glob"
  exit 0
fi

os="$(uname -s)"
arch="$(uname -m)"
if [[ "$os" != Linux || "$arch" != x86_64 ]]; then
  echo "ci-migrations: no prebuilt squawk for ${os}/${arch}" >&2
  exit 1
fi

VER="${SQUAWK_VERSION}"
CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/squawk/${VER}"
BIN="${CACHE}/squawk"
if [[ ! -x "$BIN" ]]; then
  mkdir -p "$CACHE"
  TMP="$(mktemp "$CACHE/.squawk.XXXXXX")"
  cleanup() { rm -f -- "$TMP"; }
  trap cleanup EXIT
  curl -sSfL --retry 3 -o "$TMP" \
    "https://github.com/sbdchd/squawk/releases/download/v${VER}/squawk-linux-x64"
  echo "${SQUAWK_SHA256}  ${TMP}" | sha256sum -c
  chmod +x "$TMP"
  # Rename the verified binary into place: $BIN never exists half-written.
  mv -f "$TMP" "$BIN"
  cleanup
  trap - EXIT
fi

# squawk has no goose mode (`squawk --help`), so extract the Up section and lint only that. A file
# without a goose marker is linted whole. `--stdin-filepath` keeps the original name in findings.
lint_file() {
  local file="$1" sql
  if grep -qE '^[[:space:]]*--[[:space:]]*[+]goose[[:space:]]+Up[[:space:]]*$' "$file"; then
    # Print from the top of the file through the Up section (line numbers stay true); stop at Down.
    sql="$(sed -n '1,/^[[:space:]]*--[[:space:]]*[+]goose[[:space:]]*Down[[:space:]]*$/p' "$file")"
  else
    sql="$(cat "$file")"
  fi
  printf '%s\n' "$sql" | "$BIN" --reporter gcc --stdin-filepath "$file"
}

status=0
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  echo "==> squawk $file"
  if ! lint_file "$file"; then
    status=1
  fi
done <<<"$changed"

if [[ $status -ne 0 ]]; then
  echo "ci-migrations: squawk found problems in changed migrations" >&2
fi
exit "$status"
