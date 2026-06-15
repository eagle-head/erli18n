# Contributing to erli18n

Thanks for your interest in contributing. All contributions are welcome — bug reports, feature requests, documentation fixes, code review, and pull requests.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md) in all interactions.

## Ways to contribute

- **Report bugs** via GitHub Issues. Include OTP version, `erli18n` version, a minimal reproducer (ideally a Common Test case or `.po` fixture), and the actual vs expected behavior.
- **Suggest features** via GitHub Issues. For non-trivial proposals, lay out the motivation, the proposed API, and impact on the parity SUITE before opening a PR — this saves a round-trip if the design is contentious.
- **Improve documentation** in `README.md`, `CHANGELOG.md`, or the `-doc` module-level attributes.
- **Submit pull requests** for bug fixes or features. Smaller, focused PRs are reviewed faster than omnibus ones.

## Development setup

### Prerequisites

- **Erlang/OTP 27 or later** — `27` is the minimum supported (the native `-doc`/`-moduledoc` EEP-59 attributes require OTP 27+); CI exercises `27` and `28`.
- **`rebar3 3.24`** — the version pinned in `.github/workflows/ci.yml`.
- **`mise`** ([https://mise.jdx.dev](https://mise.jdx.dev/)) — recommended for tool pinning. The `mise.toml` at the repo root pins `actionlint` for workflow validation; you can add Erlang/`rebar3` pins locally if you like.

Optional but useful:

- **`elp`** (Erlang Language Platform) — for `elp lint` and `eqwalize-all`. Install via the [VS Code / Cursor extension](https://marketplace.visualstudio.com/items?itemName=erlang-language-platform.erlang-language-platform) (the easiest path) or from the [GitHub releases](https://github.com/WhatsApp/erlang-language-platform/releases).
- **`docker`** + **`act`** ([https://nektosact.com](https://nektosact.com/)) — for running the GitHub Actions workflow locally before pushing. Bootstrap is documented in `compose.yml`.
- **GNU `gettext`** (`apt install gettext`, `brew install gettext`, `apk add gettext`) — required for `erli18n_parity_SUITE` to exercise the `msgfmt` oracle. Without it the suite skips gracefully.

### Getting started

```sh
git clone git@github.com:eagle-head/erli18n.git
cd erli18n
rebar3 compile
rebar3 do ct, cover    # 289 tests, ~30s on a recent laptop
```

### Quality gate

`bin/quality-gate.sh` is the single source of truth for all pre-commit and pre-push checks. The same script runs locally and inside CI (CI invokes `--fast` directly; the `--full` suite is exercised by the dialyzer and test jobs).

| Mode | Steps | Wall time |
|---|---|---|
| `--fast` (or `--pre-commit`) | compile, xref, erlfmt --check, elvis, hank, elp lint | ~30s |
| `--full` (or `--pre-push`, default) | + dialyzer, eqwalize-all, ct --cover | ~5min |
| `--fix` | erlfmt --write (auto-format only; runs no checks) | ~5s |

`elp lint` and `eqwalize-all` are gracefully skipped when `elp` is not on `PATH` or available via VS Code / Cursor extension. Real CI (GitHub-hosted) does not preinstall ELP, so those steps run only locally — see the local-runner section below for end-to-end parity.

### Git hooks

`hooks/install.sh` symlinks `bin/quality-gate.sh --pre-commit` and `--pre-push` into `.git/hooks/`. Optional but recommended:

```sh
./hooks/install.sh
```

### Local CI emulation (optional)

The same workflow that runs on GitHub-hosted runners can be exercised locally via [`act`](https://nektosact.com/). `compose.yml` declares the runner image and the toolcache volume bootstrap:

```sh
docker compose --profile pull-only pull                       # 17GB upstream runner image (once)
docker compose --profile init up --abort-on-container-exit    # chown the act-toolcache volume (once)
docker compose build act-runner                               # bake ELP into the local runner image (once)
mise exec -- act -j lint                                      # run the lint job
```

The custom `erli18n/act-runner:24.04` image extends `ghcr.io/catthehacker/ubuntu:full-24.04` with ELP — see `Dockerfile.act-runner`. This is **local-only**: real GitHub-hosted runners do not have ELP, and the workflow YAML is unchanged. The local image gives you full quality-gate parity (`elp lint` + `eqwalize-all`) without polluting `ci.yml`.

## Project layout

```text
src/                 erli18n implementation (façade + server + po parser + plural + telemetry)
include/             public header (erli18n.hrl — public macros/types)
test/                Common Test suites + PropEr properties + fuzz harness + parity oracle
bin/quality-gate.sh  canonical check runner
hooks/               git pre-commit / pre-push wrappers
.github/workflows/   GitHub Actions CI definition
compose.yml          local act-runner infrastructure
Dockerfile.act-runner  local-only runner image with ELP baked in
elvis.config         style rules
rebar.config         build configuration + project plugins (erlfmt / hank / lint)
```

## Pull request workflow

1. **Fork** the repository (or create a branch if you have write access).
2. **Create a feature branch** from `main`:
   ```sh
   git checkout -b feat/short-descriptive-name
   ```
3. **Make your change** — keep the diff small and focused. One logical concern per PR.
4. **Add or update tests** — every behavioral change needs a test. Bug fixes need a regression test that fails on the old code and passes on the new.
5. **Update `CHANGELOG.md`** under `[Unreleased]` — describe the change from the user's perspective, not the implementation detail.
6. **Run the full quality gate**:
   ```sh
   bin/quality-gate.sh --full
   ```
7. **Commit** following the convention: imperative mood, present tense, one sentence first line, body explains why not what.
8. **Push** and open a pull request against `main`. CI does **not** run automatically on pull requests — the local quality gate (step 6) is the gate. A maintainer can trigger the CI workflow on demand via **Run workflow** (`workflow_dispatch`) when needed.
9. **Respond to review** — address feedback or push back with rationale. Force-pushes to feature branches are fine; force-pushes to `main` are not.

## Telemetry / public API changes

If your PR changes a function exported from `erli18n`, the structure of a `:telemetry` event, or the schema of an application env key, it is **public API** and triggers a minor bump on the next release (per the `0.x` SemVer policy in `CHANGELOG.md`).

For telemetry events, follow the `@stable` / `@unstable` annotation policy documented in the `erli18n_telemetry` module `-moduledoc` — events marked `@stable` cannot change schema within the `0.x` series.

## Release process

Releases are tag-driven. Maintainers cut a release by:

1. Merging the relevant PRs to `main`.
2. Updating `CHANGELOG.md`: move `[Unreleased]` content under a new `[X.Y.Z] — YYYY-MM-DD` heading.
3. Bumping `vsn` in `src/erli18n.app.src`.
4. Tagging: `git tag -a vX.Y.Z -m "..."` and pushing the tag.
5. CI publishes to Hex.pm on tag push via the `release.yml` workflow (pushing a `vX.Y.Z` tag publishes the package to Hex.pm, the docs to HexDocs, and creates a GitHub Release).

## Questions

Open an issue or a discussion. For security-sensitive matters see [`SECURITY.md`](SECURITY.md).
