#!/usr/bin/env bash
# Shared conventions block for a repository's AGENTS.md. The block is a copy of conventions/core.md
# between two markers, stamped with conventions/VERSION. Offline, dependency-free.
#
# Usage:
#   ci/conventions.sh render            print the block (markers included) to stdout
#   ci/conventions.sh check [dir]       default dir ".": exit 0 when the block matches, 1 when stale
#   ci/conventions.sh sync [dir]        replace the block in dir/AGENTS.md, or append it when absent
#
# Env: CONVENTIONS_REQUIRED=1 makes a missing block a failure in check (default: warning only).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONV_DIR="$HERE/../conventions"
CORE="$CONV_DIR/core.md"
VERSION_FILE="$CONV_DIR/VERSION"
START_PREFIX='<!-- manova:conventions v'
END_LINE='<!-- /manova:conventions -->'

usage() {
  echo "usage: conventions.sh render | check [dir] | sync [dir]" >&2
  exit 2
}

version() {
  local v
  v="$(tr -d '[:space:]' < "$VERSION_FILE")"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    echo "conventions: $VERSION_FILE must hold a single integer, found '$v'" >&2
    exit 1
  fi
  printf '%s' "$v"
}

render() {
  local v
  v="$(version)"
  printf '<!-- manova:conventions v%s — generated from manovaspace/ci conventions/core.md; edit it there -->\n' "$v"
  # awk 1 terminates a last line that lacks a newline, so the end marker starts on its own line.
  awk 1 "$CORE"
  printf '%s\n' "$END_LINE"
}

# Prints "<start> <end>" line numbers of the block in $1; "0 0" when there is no block. A start
# with no end marker prints "<start> 0".
locate() {
  awk -v sp="$START_PREFIX" -v el="$END_LINE" '
    !s && index($0, sp) == 1 { s = NR; next }
    s && !e && $0 == el { e = NR }
    END { print s + 0, e + 0 }
  ' "$1"
}

check() {
  local dir="$1" file start end found
  file="$dir/AGENTS.md"
  if [[ ! -f "$file" ]]; then
    echo "conventions: no AGENTS.md in $dir, nothing to check"
    exit 0
  fi
  read -r start end < <(locate "$file")
  if [[ "$start" == 0 ]]; then
    if [[ "${CONVENTIONS_REQUIRED:-0}" == 1 ]]; then
      echo "::error::AGENTS.md has no shared conventions block. Add it: bash <ci>/ci/conventions.sh sync" >&2
      exit 1
    fi
    echo "::warning::AGENTS.md has no shared conventions block. Add it: bash <ci>/ci/conventions.sh sync"
    exit 0
  fi
  if [[ "$end" == 0 ]]; then
    echo "::error::AGENTS.md shared conventions block has a start marker (line $start) but no '$END_LINE'" >&2
    exit 1
  fi

  # Compare the stored block with the rendered one; process substitution needs no temp file.
  if cmp -s <(sed -n "${start},${end}p" "$file") <(render); then
    echo "conventions v$(version) current"
    exit 0
  fi
  found="$(sed -n "${start}s/^<!-- manova:conventions v\([0-9][0-9]*\).*/\1/p" "$file")"
  echo "::error::AGENTS.md shared conventions block is stale: found v${found:-?}, current v$(version). Run: bash <ci>/ci/conventions.sh sync" >&2
  exit 1
}

sync() {
  local dir="$1" file start end
  # Global on purpose: the EXIT trap runs after this function returns, when a local would be gone.
  tmp=""
  trap 'rm -f -- "$tmp"' EXIT
  file="$dir/AGENTS.md"
  if [[ ! -f "$file" ]]; then
    echo "conventions: $file not found, nothing created" >&2
    exit 1
  fi
  read -r start end < <(locate "$file")
  if [[ "$start" != 0 && "$end" == 0 ]]; then
    echo "conventions: $file has a start marker (line $start) but no '$END_LINE', fix it by hand" >&2
    exit 1
  fi

  tmp="$(mktemp)"
  if [[ "$start" == 0 ]]; then
    # Append: end the last line if it lacks a newline, then a blank line, then the block.
    cat "$file" >"$tmp"
    if [[ -s "$file" && -n "$(tail -c1 "$file")" ]]; then
      printf '\n' >>"$tmp"
    fi
    printf '\n' >>"$tmp"
    render >>"$tmp"
  else
    # Replace: bytes before the start line and after the end line are copied unchanged.
    {
      head -n "$((start - 1))" "$file"
      render
      tail -n "+$((end + 1))" "$file"
    } >"$tmp"
  fi
  # Write through the existing file so its mode is kept.
  cat "$tmp" >"$file"
  echo "conventions v$(version) synced into $file"
}

cmd="${1:-}"
arg="${2:-.}"
case "$cmd" in
  render) render ;;
  check) check "$arg" ;;
  sync) sync "$arg" ;;
  *) usage ;;
esac
