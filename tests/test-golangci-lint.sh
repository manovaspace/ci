#!/usr/bin/env bash
# Tests ci/golangci-lint.sh offline: a checksum mismatch rejects the archive and leaves no binary,
# and a cached binary is reused without any download (PATH has no curl).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT_SH="$ROOT/ci/golangci-lint.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/versions.env"
VER="${GOLANGCI_LINT_VERSION#v}"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. golangci_checksum_mismatch_fails: a wrong expected SHA rejects the archive, so nothing is
#    extracted and no binary lands in the cache. curl is stubbed with a local archive, so the test
#    needs no network.
printf 'not the golangci-lint release\n' >"$tmp/fake.tar.gz"

mkdir -p "$tmp/curl-bin"
cat >"$tmp/curl-bin/curl" <<'STUB'
#!/usr/bin/env bash
# Offline curl: writes $STUB_ARCHIVE to the -o target.
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    --retry | -*)
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$out" ]] || {
  echo "stub-curl: no -o target" >&2
  exit 1
}
cat "$STUB_ARCHIVE" >"$out"
STUB
chmod +x "$tmp/curl-bin/curl"

cache="$tmp/cache-mismatch"
set +e
STUB_ARCHIVE="$tmp/fake.tar.gz" \
  GOLANGCI_LINT_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
  XDG_CACHE_HOME="$cache" PATH="$tmp/curl-bin:$PATH" \
  bash "$LINT_SH" version >"$tmp/mismatch.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "a checksum mismatch should fail"
[[ ! -e "$cache/golangci-lint/$VER/golangci-lint" ]] || fail "a checksum mismatch left a binary in the cache"

# 2. golangci_cached_binary_reused: an executable stub at the cache path runs without curl on PATH.
cache="$tmp/cache-reuse"
bindir="$cache/golangci-lint/$VER"
mkdir -p "$bindir"
cat >"$bindir/golangci-lint" <<'STUB'
#!/usr/bin/env bash
echo stub-golangci
STUB
chmod +x "$bindir/golangci-lint"

pathdir="$tmp/reuse-bin"
mkdir -p "$pathdir"
for cmd in bash uname dirname sha256sum tar mkdir cat env; do
  ln -s "$(command -v "$cmd")" "$pathdir/$cmd"
done

out="$(env XDG_CACHE_HOME="$cache" PATH="$pathdir" "$BASH" "$LINT_SH" version)" \
  || fail "a cached binary should run without curl"
[[ "$out" == stub-golangci ]] || fail "cached binary was not reused (output: $out)"

# 3. golangci_failed_extract_leaves_no_binary: an archive that passes the checksum but lacks the
#    expected member fails the extraction and leaves neither a binary nor a .tmp.* directory.
wrong="$tmp/wrong-src"
mkdir -p "$wrong/golangci-lint-${VER}-linux-amd64"
printf 'not the binary\n' >"$wrong/golangci-lint-${VER}-linux-amd64/README.md"
tar -czf "$tmp/wrong.tar.gz" -C "$wrong" "golangci-lint-${VER}-linux-amd64"
sha="$(sha256sum "$tmp/wrong.tar.gz" | awk '{print $1}')"

cache="$tmp/cache-failed-extract"
set +e
STUB_ARCHIVE="$tmp/wrong.tar.gz" GOLANGCI_LINT_SHA256="$sha" XDG_CACHE_HOME="$cache" \
  PATH="$tmp/curl-bin:$PATH" bash "$LINT_SH" version >"$tmp/failed-extract.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "an archive without the expected member should fail"
[[ ! -e "$cache/golangci-lint/$VER/golangci-lint" ]] || fail "a failed extract left a binary in the cache"
[[ -z "$(find "$cache" -name '.tmp.*' -print 2>/dev/null)" ]] || fail "a failed extract left a .tmp.* directory"

echo "PASS: test-golangci-lint"
