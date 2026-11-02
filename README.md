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
- `ci/migrations.sh <glob>` — pinned squawk on the goose migrations a pull request changed against
  its base branch only, so an old migration never fails a new rule.

The Go and TS gates source `ci/lib/snapshot.sh` (disk guard + disposable pinned checkout) and read
tool versions from `ci/versions.env`; `ci/gitleaks.sh [dir]` is the pinned, history-free scanner
they call. `ci/golangci-lint.sh [args...]` runs the pinned, SHA-256-verified golangci-lint
prebuilt binary, downloaded once and cached. `ci/actionlint.sh [args...]` does the same for
actionlint and runs on any repository that has `.github/workflows`.

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

Inputs: `stack` (`go` or `ts`, required), `tier` (`pr` or `release`, default `pr`),
`working-directory` (default `.`), `skip-tests` (`true` allows a TS package without a `test`
script), `extra` (one extra TS package script) and `migrations-glob` (default empty; see
[Migrations](#migrations)).
`GH_READ_TOKEN` and `NPM_TOKEN` are not inputs: they arrive from the caller's step `env:`.

`vars.CI_RUNNER` selects the runner: unset means `ubuntu-latest`, `vps` switches the repository to
the standby self-hosted runner.

`templates/` holds copy-paste workflows: `ci.yml` (the file above), `codeql.yml` (weekly CodeQL on
a schedule, no per-push run) and `deploy-ssh.yml` (SSH deploy of `__SERVICE__` on `main`). Replace
`__STACK__`, `__LANG__` and `__SERVICE__` with the repository's values.

## Migrations

Set `migrations-glob` to lint the goose migrations a pull request changes with the pinned
`squawk`:

```yaml
- uses: manovaspace/ci@v1
  with:
    stack: go
    migrations-glob: apps/api/migrations/*.sql
```

The glob is a git pathspec relative to `working-directory`. Only files added or modified by the
pull request are linted: the action diffs
`origin/$GITHUB_BASE_REF...HEAD -- <glob>` (falling back to the base tip against the checked-out
merge tree when the shallow merge commit has no merge base) and never touches an unchanged file,
so an old migration that breaks a new rule cannot fail an unrelated pull request. On `push` and
`workflow_dispatch` runs there is no base branch, so the step prints why and lints nothing.

Goose files are linted through their `-- +goose Up` section only; `squawk --help` has no goose
mode, so the section is extracted with `sed` and piped to squawk with `--stdin-filepath`, which
keeps the real migration name in the findings. A file without goose markers is linted whole.

Squawk exits non-zero on any warning it reports, naming the rule and the file; the gate fails with
it. To accept one finding, put squawk's ignore comment directly above the statement, with a reason
after a second `--`:

```sql
-- squawk-ignore ban-drop-column -- the column is unused since #1234
ALTER TABLE receipts DROP COLUMN legacy_ref;
```

Always give a reason: a bare ignore is invisible to review, and the reason is what lets the next
reader decide whether the exception still holds. An ignore for a rule that did not fire is itself
an `unused-ignore` warning, so remove stale ignores.

## Tiers

`tier` (default `pr`) says how much the gate runs. Only `ci/go.sh` acts on it (`CI_TIER`); `ci/ts.sh`
ignores it for now.

- `pr` — the light gate on every pull request. Behaviour is unchanged: `go test -race -count=1 ./...`
  and a test that skips itself stays green.
- `release` — the heavy gate on the release pull request. `TEST_DATABASE_URL` must be set and
  non-empty, or the gate exits 1 with `ci-go: tier=release needs TEST_DATABASE_URL` before running
  anything. Tests then run as `go test -race -count=1 -v ./...` against real dependencies, and any
  skipped test fails the gate unless the repository lists it — a database-backed test that skips
  itself proves nothing and must not pass silently on the release.

`.github/allowed-skips.txt` lives in the consumer repository: one Go test name per line, `#` starts a
comment, and an optional trailing reason is ignored (same parsing as `.github/vuln-allow.txt`).

```
# integration tests with no fixture yet
TestNeedsLegacyReplica  needs the legacy replica
```

Each listed skip prints `ci-go: allowing skip <name>`; an unlisted one prints
`ci-go: skipped tests are not allowed on tier=release (list them in .github/allowed-skips.txt):`
followed by the test names, and fails. A failing `go test` exits with its own code.

### Release workflow

`.github/workflows/release-check.yml` is a reusable workflow for that tier: it starts PostgreSQL,
Redis and NATS (JetStream), then runs the gate with `stack: go` and `tier: release`, and passes
`TEST_DATABASE_URL`, `TEST_REDIS_URL` and `TEST_NATS_URL` to it. Call it from the bot's release
pull request into `main`, which is recognised by its head branch name (`changeset-release/main` for
Changesets, `release-please--*` for release-please); there is no `release` branch:

```yaml
name: release-check
on:
  pull_request:
    branches: [main]
permissions: { contents: read }
jobs:
  release-check:
    if: github.head_ref == 'changeset-release/main' || startsWith(github.head_ref, 'release-please--')
    uses: manovaspace/ci/.github/workflows/release-check.yml@v1
    secrets: inherit
```

It always runs on `ubuntu-latest` and never on the standby VPS runner: `vars.CI_RUNNER` is not
consulted, because release checks need service containers and docker.

### Pinning

`uses: manovaspace/ci@v1` follows a moving tag, so a new release changes CI under every consumer at
once. Pin the kit by full commit SHA with a version comment instead:

```yaml
- uses: manovaspace/ci@<40-hex sha> # v1.0.7
```

A moved tag then cannot change CI under you, and Renovate keeps the pin current.

## Tests

```bash
bash tests/run.sh
```

Runs every `tests/test-*.sh` against fixtures and stubs; no network (gitleaks and actionlint
excepted, they use the pinned releases). Prints `PASS <name>` / `FAIL <name>` and exits non-zero
on any failure.
