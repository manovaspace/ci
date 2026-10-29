# ci

Shared CI gates for Manova repositories: small, dependency-free shell scripts plus one pinned
version file, callable from any workflow. Public and MIT — no secrets live here.

## Gates

- `ci/go.sh [--no-race] [repo-dir]` — gitleaks tree scan, sibling `replace => ../*` clone resolution,
  `gofmt -l`, `go vet`, `go test -race -count=1`, `govulncheck`, `golangci-lint`.
- `ci/ts.sh [repo-dir]` — gitleaks tree scan, optional `@orbit` `.npmrc`, `bun install
  --frozen-lockfile`, then `lint`, `typecheck`, `test`, `build` when the package defines them.

Both source `ci/lib/snapshot.sh` (disk guard + disposable pinned checkout) and read tool versions
from `ci/versions.env`; `ci/gitleaks.sh [dir]` is the pinned, history-free scanner they call.

## Environment

| Variable | Used by | Meaning |
| --- | --- | --- |
| `GH_READ_TOKEN` | go | Read token for private `github.com/manovaspace` modules and siblings. Never printed or written to disk. |
| `NPM_TOKEN` | ts | Read token for the `@orbit` scope. Never set on pull_request runs. |
| `CI_SKIP_TESTS` | ts | `1` allows a package with no `test` script. |
| `CI_EXTRA` | ts | One extra package script to run after the standard ones. |
| `CI_SIBLING_URL_BASE` | go | Prefix for sibling clone URLs (default `https://`; tests use `file://`). |

## Tests

```bash
bash tests/run.sh
```

Runs every `tests/test-*.sh` against fixtures and stubs; no network (gitleaks excepted, it uses the
pinned release). Prints `PASS <name>` / `FAIL <name>` and exits non-zero on any failure.

A composite action and workflow templates follow in a later change.
