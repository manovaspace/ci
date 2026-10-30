#!/usr/bin/env bash
# Pinned, SHA-256-verified actionlint runner. Usage: ci/actionlint.sh [args...]
# Downloads the official linux/amd64 release binary once and caches it; other platforms fall back
# to compiling the pinned version with `go run`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# An exported ACTIONLINT_SHA256 wins over versions.env (tests override it); capture it first.
sha_override="${ACTIONLINT_SHA256:-}"
# shellcheck source=/dev/null
source "$HERE/versions.env"
if [[ -n "$sha_override" ]]; then
  ACTIONLINT_SHA256="$sha_override"
fi

os="$(uname -s)"
arch="$(uname -m)"
if [[ "$os" != Linux || "$arch" != x86_64 ]]; then
  echo "ci-actionlint: no prebuilt for ${os}/${arch}, compiling" >&2
  exec go run "github.com/rhysd/actionlint/cmd/actionlint@v${ACTIONLINT_VERSION}" "$@"
fi

VER="${ACTIONLINT_VERSION}"
CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/actionlint/${VER}"
BIN="${CACHE}/actionlint"
if [[ ! -x "$BIN" ]]; then
  mkdir -p "$CACHE"
  ARCHIVE="$(mktemp)"
  EXTRACT_DIR=""
  cleanup() {
    rm -f -- "$ARCHIVE"
    if [[ -n "$EXTRACT_DIR" ]]; then
      rm -rf -- "$EXTRACT_DIR"
    fi
  }
  trap cleanup EXIT
  FILE="actionlint_${VER}_linux_amd64.tar.gz"
  curl -sSfL --retry 3 -o "$ARCHIVE" \
    "https://github.com/rhysd/actionlint/releases/download/v${VER}/${FILE}"
  echo "${ACTIONLINT_SHA256}  ${ARCHIVE}" | sha256sum -c
  # Extract beside the cache entry, then rename it into place: $BIN never exists half-written.
  EXTRACT_DIR="$(mktemp -d "$CACHE/.tmp.XXXXXX")"
  tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" actionlint
  chmod +x "$EXTRACT_DIR/actionlint"
  mv -f "$EXTRACT_DIR/actionlint" "$BIN"
  cleanup
  trap - EXIT
fi
exec "$BIN" "$@"
