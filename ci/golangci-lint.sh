#!/usr/bin/env bash
# Pinned, SHA-256-verified golangci-lint runner. Usage: ci/golangci-lint.sh [args...]
# Downloads the official linux/amd64 release binary once and caches it; other platforms fall back
# to compiling the pinned version with `go run`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# An exported GOLANGCI_LINT_SHA256 wins over versions.env (tests override it); capture it first.
sha_override="${GOLANGCI_LINT_SHA256:-}"
# shellcheck source=/dev/null
source "$HERE/versions.env"
if [[ -n "$sha_override" ]]; then
  GOLANGCI_LINT_SHA256="$sha_override"
fi

os="$(uname -s)"
arch="$(uname -m)"
if [[ "$os" != Linux || "$arch" != x86_64 ]]; then
  echo "ci-golangci-lint: no prebuilt for ${os}/${arch}, compiling" >&2
  exec go run "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION}" "$@"
fi

VER="${GOLANGCI_LINT_VERSION#v}"
CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/golangci-lint/${VER}"
BIN="${CACHE}/golangci-lint"
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
  FILE="golangci-lint-${VER}-linux-amd64.tar.gz"
  curl -sSfL --retry 3 -o "$ARCHIVE" \
    "https://github.com/golangci/golangci-lint/releases/download/v${VER}/${FILE}"
  echo "${GOLANGCI_LINT_SHA256}  ${ARCHIVE}" | sha256sum -c
  # Extract beside the cache entry, then rename it into place: $BIN never exists half-written.
  EXTRACT_DIR="$(mktemp -d "$CACHE/.tmp.XXXXXX")"
  tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" --strip-components=1 "golangci-lint-${VER}-linux-amd64/golangci-lint"
  chmod +x "$EXTRACT_DIR/golangci-lint"
  mv -f "$EXTRACT_DIR/golangci-lint" "$BIN"
  cleanup
  trap - EXIT
fi
exec "$BIN" "$@"
