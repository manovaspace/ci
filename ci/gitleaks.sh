#!/usr/bin/env bash
# Pinned gitleaks tree scan (no git history). Usage: ci/gitleaks.sh [dir]. Non-zero on any finding.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/versions.env"

SRC="${1:-.}"
CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/gitleaks/${GITLEAKS_VERSION}"
BIN="${CACHE}/gitleaks"
if [[ ! -x "$BIN" ]]; then
  mkdir -p "$CACHE"
  ARCHIVE="$(mktemp)"
  curl -sSfL -o "$ARCHIVE" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  echo "${GITLEAKS_SHA256}  ${ARCHIVE}" | sha256sum -c
  tar -xzf "$ARCHIVE" -C "$CACHE" gitleaks
  rm -f "$ARCHIVE"
  chmod +x "$BIN"
fi
"$BIN" detect --source "$SRC" --no-git --redact --exit-code 1
