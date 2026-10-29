#!/usr/bin/env bash
# Disposable checkout and disk guard for ci/*.sh. Source this file; do not execute it.
#
#   ci_require_disk <GiB>          exit 75 when free space on / is below <GiB>
#   ci_snapshot <git-url|dir> <sha> <dest>
#                                  fresh checkout of exactly <sha> at <dest>; exports CI_ROOT=<dest>;
#                                  <dest> is removed on shell EXIT by a trap installed here

ci_require_disk() {
  local need_gib="${1:?ci_require_disk <GiB>}"
  local avail_kib
  avail_kib="$(df --output=avail / | tail -n 1 | tr -d '[:space:]')"
  if (( avail_kib < need_gib * 1024 * 1024 )); then
    echo "ci: ${avail_kib} KiB free on /, need ${need_gib} GiB; refusing to build" >&2
    exit 75
  fi
}

ci_snapshot() {
  local src="${1:?ci_snapshot <git-url|dir> <sha> <dest>}"
  local sha="${2:?ci_snapshot <git-url|dir> <sha> <dest>}"
  local dest="${3:?ci_snapshot <git-url|dir> <sha> <dest>}"

  if [[ -d "$src" ]]; then
    src="file://$(realpath "$src")"
  fi
  [[ ! -e "$dest" ]] || { echo "ci_snapshot: $dest already exists" >&2; return 1; }

  mkdir -p "$(dirname "$dest")"
  git init -q "$dest"
  git -C "$dest" remote add origin "$src"
  git -C "$dest" fetch -q --depth 1 origin "$sha"
  git -C "$dest" checkout -q --detach FETCH_HEAD

  export CI_ROOT="$dest"
  # Installed in the caller's shell on purpose: the snapshot dies with the CI script.
  CI_SNAPSHOT_DIR="$dest"
  trap 'rm -rf -- "$CI_SNAPSHOT_DIR"' EXIT
}
