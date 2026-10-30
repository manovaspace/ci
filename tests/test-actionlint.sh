#!/usr/bin/env bash
# Tests ci/actionlint.sh offline: a checksum mismatch rejects the archive and leaves no binary,
# and a cached binary is reused without any download (PATH has no curl).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT_SH="$ROOT/ci/actionlint.sh"
# shellcheck source=/dev/null
source "$ROOT/ci/versions.env"
VER="${ACTIONLINT_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. actionlint_checksum_mismatch_fails: a wrong expected SHA rejects the archive, so no binary
#    lands in the cache. curl is stubbed with a local archive, so the test needs no network.
printf 'not the actionlint release\n' >"$tmp/fake.tar.gz"

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
  ACTIONLINT_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
  XDG_CACHE_HOME="$cache" PATH="$tmp/curl-bin:$PATH" \
  bash "$LINT_SH" --version >"$tmp/mismatch.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "a checksum mismatch should fail"
[[ ! -e "$cache/actionlint/$VER/actionlint" ]] || fail "a checksum mismatch left a binary in the cache"

# 2. actionlint_cached_binary_reused: an executable stub at the cache path runs without curl on PATH.
cache="$tmp/cache-reuse"
bindir="$cache/actionlint/$VER"
mkdir -p "$bindir"
cat >"$bindir/actionlint" <<'STUB'
#!/usr/bin/env bash
echo stub-actionlint
STUB
chmod +x "$bindir/actionlint"

pathdir="$tmp/reuse-bin"
mkdir -p "$pathdir"
for cmd in bash uname dirname sha256sum tar mkdir cat env; do
  ln -s "$(command -v "$cmd")" "$pathdir/$cmd"
done

out="$(env XDG_CACHE_HOME="$cache" PATH="$pathdir" "$BASH" "$LINT_SH" --version)" \
  || fail "a cached binary should run without curl"
[[ "$out" == stub-actionlint ]] || fail "cached binary was not reused (output: $out)"

echo "PASS: test-actionlint"
