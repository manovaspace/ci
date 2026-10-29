#!/usr/bin/env bash
# Stands in for govulncheck in tests (the real tool needs the Go vulnerability DB over the network).
# Reports one reachable advisory and exits 3 when the scanned tree carries the VULNERABLE.txt fixture marker.
set -euo pipefail
if [[ -e VULNERABLE.txt ]]; then
  echo "Vulnerability #1: GO-2099-0001"
  echo "    Stub finding used by the kit tests"
  echo "  More info: https://pkg.go.dev/vuln/GO-2099-0001"
  echo "  Module: example.com/stub"
  echo "    Found in: example.com/stub@v1.0.0"
  echo "    Fixed in: N/A"
  exit 3
fi
echo "No vulnerabilities found."
