# ci

Shared CI gates for Manova repositories: small, dependency-free shell scripts plus one pinned
version file, callable from any workflow. Public and MIT — no secrets live here.

## Gates

- `ci/go.sh [--no-race] [repo-dir]` — gitleaks tree scan, sibling `replace => ../*` clone resolution,
  `gofmt -l`, `go vet`, `go test -race -count=1`, `govulncheck`, `golangci-lint`.
- `ci/ts.sh [repo-dir]` — gitleaks tree scan, optional `@orbit` `.npmrc`, `bun install
  --frozen-lockfile`, then `lint`, `typecheck`, `test`, `build` when the package defines them.
- `ci/lint.sh [repo-dir]` — fast, offline pre-push lint: `gofmt` + `go vet` for Go, the package
  `lint` script or Biome for Bun, and a clean skip for trees it cannot lint. The workspace
  `pre-push` hook runs it.

The Go and TS gates source `ci/lib/snapshot.sh` (disk guard + disposable pinned checkout) and read
tool versions from `ci/versions.env`; `ci/gitleaks.sh [dir]` is the pinned, history-free scanner
they call. `ci/golangci-lint.sh [args...]` runs the pinned, SHA-256-verified golangci-lint
prebuilt binary, downloaded once and cached.

When govulncheck reports a reachable advisory that has no fixed version, a repository can list its
ID in `.github/vuln-allow.txt` (one `GO-YYYY-NNNN` per line, optional trailing reason, `#` starts a
comment). The gate prints `ci-go: allowing <ID>` and passes; any unlisted advisory still fails.
Allowlists are per repository and should be reviewed like code.

## Environment

| Variable | Used by | Meaning |
| --- | --- | --- |
| `GH_READ_TOKEN` | go | Read token for private `github.com/manovaspace` modules and siblings. Never printed or written to disk. |
| `NPM_TOKEN` | ts | Read token for the `@orbit` scope. Never set on pull_request runs. |
| `CI_SKIP_TESTS` | ts | `1` allows a package with no `test` script. |
| `CI_EXTRA` | ts | One extra package script to run after the standard ones. |
| `CI_SIBLING_URL_BASE` | go | Prefix for sibling clone URLs (default `https://`; tests use `file://`). |

## Use it

`uses: manovaspace/ci@v1` runs the gate with every tool pinned here, so the consumer repository
installs nothing itself. A complete Go or TS check:

```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
permissions: { contents: read }
jobs:
  check:
    runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with: { persist-credentials: false }
      - uses: manovaspace/ci@v1
        with: { stack: __STACK__ }
        env:
          GH_READ_TOKEN: ${{ secrets.GH_READ_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

Inputs: `stack` (`go` or `ts`, required), `working-directory` (default `.`), `skip-tests` (`true`
allows a TS package without a `test` script) and `extra` (one extra TS package script).
`GH_READ_TOKEN` and `NPM_TOKEN` are not inputs: they arrive from the caller's step `env:`.

`vars.CI_RUNNER` selects the runner: unset means `ubuntu-latest`, `vps` switches the repository to
the standby self-hosted runner.

`templates/` holds copy-paste workflows: `ci.yml` (the file above), `codeql.yml` (weekly CodeQL on
a schedule, no per-push run) and `deploy-ssh.yml` (SSH deploy of `__SERVICE__` on `main`). Replace
`__STACK__`, `__LANG__` and `__SERVICE__` with the repository's values.

## Tests

```bash
bash tests/run.sh
```

Runs every `tests/test-*.sh` against fixtures and stubs; no network (gitleaks and actionlint
excepted, they use the pinned releases). Prints `PASS <name>` / `FAIL <name>` and exits non-zero
on any failure.
