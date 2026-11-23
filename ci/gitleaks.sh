#!/usr/bin/env bash
# Pinned gitleaks scan. Usage:
#   ci/gitleaks.sh [dir]                                   tree scan, no git history
#   ci/gitleaks.sh --range "<rev-list args>" [repo-dir]    scan the commits of one range
# The range is one string that may hold several rev-list words ("abc..def", or
# "def --not --remotes=origin"); gitleaks splits it. Non-zero on any finding.
# Platforms: linux and darwin, x64 and arm64; the binary is cached per os_arch.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/versions.env"

os="$(uname -s)"
arch="$(uname -m)"
case "$os/$arch" in
  Linux/x86_64) platform=linux_x64; sha="$GITLEAKS_SHA256" ;;
  Linux/aarch64 | Linux/arm64) platform=linux_arm64; sha="$GITLEAKS_SHA256_LINUX_ARM64" ;;
  Darwin/x86_64) platform=darwin_x64; sha="$GITLEAKS_SHA256_DARWIN_X64" ;;
  Darwin/arm64) platform=darwin_arm64; sha="$GITLEAKS_SHA256_DARWIN_ARM64" ;;
  *)
    echo "ci-gitleaks: no pinned gitleaks for ${os}/${arch} (linux or darwin, x64 or arm64)" >&2
    exit 1
    ;;
esac

# sha256sum where present (linux), shasum -a 256 otherwise (macOS).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/gitleaks/${GITLEAKS_VERSION}/${platform}"
BIN="${CACHE}/gitleaks"
if [[ ! -x "$BIN" ]]; then
  mkdir -p "$CACHE"
  ARCHIVE="$(mktemp)"
  trap 'rm -f -- "$ARCHIVE"' EXIT
  curl -sSfL --retry 3 -o "$ARCHIVE" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${platform}.tar.gz"
  got="$(sha256_of "$ARCHIVE")"
  if [[ "$got" != "$sha" ]]; then
    echo "ci-gitleaks: sha256 mismatch for gitleaks ${platform}: want ${sha}, got ${got}" >&2
    exit 1
  fi
  tar -xzf "$ARCHIVE" -C "$CACHE" gitleaks
  chmod +x "$BIN"
fi

if [[ "${1:-}" == --range ]]; then
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo 'usage: ci/gitleaks.sh --range "<rev-list args>" [repo-dir]' >&2
    exit 2
  fi
  "$BIN" git --log-opts="$2" --redact --exit-code 1 "${3:-.}"
else
  "$BIN" detect --source "${1:-.}" --no-git --redact --exit-code 1
fi
