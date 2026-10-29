#!/usr/bin/env bash
# Stands in for govulncheck in tests (the real tool needs the Go vulnerability DB over the network).
# Exits 3 when the scanned tree carries the VULNERABLE.txt fixture marker.
set -euo pipefail
if [[ -e VULNERABLE.txt ]]; then
  echo "stub-govulncheck: vulnerable call reachable (VULNERABLE.txt)" >&2
  exit 3
fi
