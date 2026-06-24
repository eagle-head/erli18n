# Contributing to erli18n

Thanks for your interest in contributing. All contributions are welcome — bug reports, feature requests, documentation fixes, code review, and pull requests.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md) in all interactions.

> **The full workflow — branching, commit rules, the CI gate, merge strategy, and the per-package release process — is documented in [`docs/WORKFLOW.md`](docs/WORKFLOW.md).** This file covers setup and the day-to-day essentials; `docs/WORKFLOW.md` is the authoritative playbook.

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
rebar3 do ct, cover    # full suite, ~30s on a recent laptop
```

### Quality gate

`bin/quality-gate.sh` is the single source of truth for all pre-commit and pre-push checks. The same script runs locally and inside CI (CI invokes `--fast` directly; the `--full` suite is exercised by the dialyzer and test jobs).

| Mode | Steps | Wall time |
|---|---|---|
| `--fast` (or `--pre-commit`) | compile, xref, erlfmt --check, elvis, hank, elp lint, the translation-freshness check | ~30s |
| `--full` (or `--pre-push`, default) | + `require_elp`, dialyzer, eqwalize-all, ct --cover, the translation-freshness check | ~5min |
| `--fix` | erlfmt --write (auto-format only; runs no checks) | ~5s |

`elp` is **required** for `--full`: a dedicated `require_elp` step records a hard FAIL (non-zero gate exit) when `elp` is not found, and the `elp lint` and `eqwalize-all` steps run strictly (a missing `elp` is a FAIL there too). This closes the "SKIP-passes" hole — a machine without `elp` can no longer pass the strict gate by silently skipping the type/diagnostic checks. Only the cheap `--fast` lane keeps the soft-skip (with an install hint) so a fast pre-commit pass is still possible without `elp`. Real CI (GitHub-hosted) does not preinstall ELP, so the strict `--full` gate is a local pre-push responsibility — see the local-runner section below for end-to-end parity.

The **translation-freshness check** runs `rebar3 erli18n check` from inside `examples/erli18n_demo/` (the downstream consumer), not in the library repo itself. The library is the facade and never calls its own `gettext`, so extraction there finds zero call sites and the check would protect nothing; the example has real `erli18n:gettext`/`ngettext`/`pgettext` call sites and committed `.pot`/`.po` baselines, so the check FAILS on drift and PASSES in sync — a genuinely non-vacuous gate. The gate's `ensure_demo_checkouts` step recreates the example's `_checkouts/erli18n` and `_checkouts/rebar3_erli18n` links (git-ignored, recreatable) before running it.

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

The repository is a **rebar3 umbrella** with two independently publishable apps
plus a downstream-consumer example:

```text
apps/erli18n/            the runtime library (a published Hex package)
  src/                   implementation (facade + server + persistent_term store + po parser + plural + telemetry)
  include/erli18n.hrl    public include (the ?GETTEXT_DOMAIN extraction contract)
  test/                  Common Test suites + PropEr properties + fuzz harness + parity oracle
  rebar.config           the lib's own deps (telemetry) + compile options + per-app hex/ex_doc plugins + this package's doc/hex config
  README / CHANGELOG / LICENSE   the lib's own publish-ready package docs
apps/rebar3_erli18n/     the catalog-tooling rebar3 plugin (a separate published Hex package)
  src/                   the four providers (extract / merge / check / report) + PO serializer + host seam
  test/                  the plugin's Common Test suites
  rebar.config           the plugin's {deps,[erli18n]} + per-app hex/ex_doc plugins + this package's doc/hex config
  README / CHANGELOG / LICENSE   the plugin's own publish-ready package docs
examples/erli18n_demo/   a real downstream consumer ({deps,[erli18n]} + {plugins,[rebar3_erli18n]})
  src/                   production modules with literal-msgid gettext call sites
  priv/gettext/          committed .pot/.po baselines the translation-freshness check compares against
README.md                the umbrella landing page → links into each package's README
CHANGELOG.md             umbrella-level repo history → links to each package's changelog
bin/quality-gate.sh      canonical check runner
hooks/                   git pre-commit / pre-push wrappers
.github/workflows/       GitHub Actions CI + Release definitions
compose.yml              local act-runner infrastructure
Dockerfile.act-runner    local-only runner image with ELP baked in
elvis.config             style rules
rebar.config             umbrella-wide tooling (project plugins, the test profile, dialyzer/xref/hank/erlfmt policy)
```

Each published app is self-contained: it physically carries its own
`README.md`, `CHANGELOG.md`, `LICENSE`, its `{deps, ...}`, its `{ex_doc, ...}` /
`{hex, ...}` doc config, and its own `{project_plugins, [rebar3_hex,
rebar3_ex_doc]}` — everything a per-app `cd apps/<app> && rebar3 hex publish`
needs. The Hex tarball ships the README/CHANGELOG/LICENSE because `rebar3_hex`
globs a package's files relative to the app directory. The `erli18n` library
README under `apps/erli18n/README.md` is what the package ships and what HexDocs
renders as its landing page; the plugin documents itself under
`apps/rebar3_erli18n/`. The repository-root `README.md` and `CHANGELOG.md` are
umbrella-level docs (a landing page and repo history) that link into the
per-package files and are **not** shipped inside either tarball. The umbrella
root `rebar.config` keeps only umbrella-wide dev tooling (the quality-gate
plugins, the `test` profile, and the dialyzer/xref/hank/erlfmt policy).

### Consuming the plugin downstream (and locally)

A downstream app opts into the catalog tooling with `{plugins, [rebar3_erli18n]}`
in its own `rebar.config` (alongside its normal `{deps, [{erli18n, "~> 0.5"}]}`),
which surfaces `rebar3 erli18n {extract,merge,check,report}`.

The plugin declares `{deps, [{erli18n, "~> 0.5"}]}` (the **plugin → lib**
direction — the gpb / `rebar3_gpb_plugin` idiom). That declaration is
load-bearing: it is what pulls the runtime library onto the plugin's code path
at provider-run time so the providers can call `erli18n_po:parse/1`,
`erli18n_po:dump/1`, and `erli18n_po:escape_string/1` across the published
package boundary.

For **local development against the unpublished in-repo apps**, rebar3 has no
native `{path, ...}` resource, so the consumer surfaces both apps through
rebar3's documented `_checkouts/` override. `examples/erli18n_demo/` does exactly
this — it provides **both** `_checkouts/erli18n` and `_checkouts/rebar3_erli18n`
links. Both are required (verified against rebar3 3.24 / OTP 28): the plugin
checkout takes precedence over a Hex fetch for the plugin name, and the lib
checkout is what the plugin's `{deps, [erli18n]}` resolves to. After publish, a
consumer drops the checkouts and resolves both packages from Hex normally. The
quality gate recreates these links via `ensure_demo_checkouts` before running the
translation-freshness check. See `apps/rebar3_erli18n/README.md` for the full
cross-package load-path proof and the xref host-seam ignore rationale.

## Pull request workflow

1. **Fork** the repository (or create a branch if you have write access).
2. **Create a feature branch** from `main`:
   ```sh
   git checkout -b feat/short-descriptive-name
   ```
3. **Make your change** — keep the diff small and focused. One logical concern per PR.
4. **Add or update tests** — every behavioral change needs a test. Bug fixes need a regression test that fails on the old code and passes on the new.
5. **Update the affected package's `CHANGELOG.md`** under `[Unreleased]` — `apps/erli18n/CHANGELOG.md` for a library change, `apps/rebar3_erli18n/CHANGELOG.md` for a plugin change. Describe the change from the user's perspective, not the implementation detail.
6. **Run the full quality gate**:
   ```sh
   bin/quality-gate.sh --full
   ```
7. **Commit** following the convention: imperative mood, present tense, one sentence first line, body explains why not what.
8. **Push** and open a pull request against `main`. CI does **not** run automatically on pull requests — the local quality gate (step 6) is the gate. A maintainer can trigger the CI workflow on demand via **Run workflow** (`workflow_dispatch`) when needed.
9. **Respond to review** — address feedback or push back with rationale. Force-pushes to feature branches are fine; force-pushes to `main` are not.

## Telemetry / public API changes

If your PR changes a function exported from `erli18n`, the structure of a `:telemetry` event, or the schema of an application env key, it is **public API** and triggers a minor bump on the next release (per the `0.x` SemVer policy in `apps/erli18n/CHANGELOG.md`).

For telemetry events, follow the `@stable` / `@unstable` annotation policy documented in the `erli18n_telemetry` module `-moduledoc` — events marked `@stable` cannot change schema within the `0.x` series.

## Release process

The umbrella ships **two independently versioned Hex packages** — the runtime
library `erli18n` and the rebar3 plugin `rebar3_erli18n` — each cut from its
own **per-package prefixed tag**:

| Package | Publish dir | Tag scheme | `vsn` source | Changelog |
| ------- | ----------- | ---------- | ------------ | --------- |
| `erli18n` | `apps/erli18n` | `erli18n-vX.Y.Z` | `apps/erli18n/src/erli18n.app.src` | `apps/erli18n/CHANGELOG.md` |
| `rebar3_erli18n` | `apps/rebar3_erli18n` | `rebar3_erli18n-vX.Y.Z` | `apps/rebar3_erli18n/src/rebar3_erli18n.app.src` | `apps/rebar3_erli18n/CHANGELOG.md` |

Releases are tag-driven. To cut one for a package, a maintainer:

1. Merges the relevant PRs to `main`.
2. Updates that package's `CHANGELOG.md`: moves `[Unreleased]` content under a
   new `[X.Y.Z] — YYYY-MM-DD` heading.
3. Bumps `vsn` in that package's `.app.src`.
4. Tags with the package-prefixed scheme — e.g.
   `git tag -a erli18n-vX.Y.Z -m "..."` or `git tag -a rebar3_erli18n-vX.Y.Z` —
   and pushes the tag.
5. The `release.yml` workflow derives the app from the tag prefix, validates the
   tag version against that package's `.app.src` `vsn`, then publishes the
   package to Hex.pm, the docs to HexDocs, and creates a GitHub Release from the
   per-package changelog. It publishes each package **from its own app
   directory** (`cd apps/<app> && rebar3 hex publish package`, and
   `rebar3 hex publish docs --doc-dir doc`). Publishing from the app dir — rather
   than `--app <app>` from the umbrella root — is what resolves the package's
   deps into a per-app lock; for the plugin that lock is what carries `erli18n`
   into the published `requirements` (see below).

The two publishes are **independently versioned but coupled by the plugin's
`{deps, [{erli18n, "~> X.Y"}]}` constraint**, so the publish order is strict:
release **`erli18n` first**, confirm it is live on Hex, then release
`rebar3_erli18n`. Because the plugin is published from its own app directory,
the build resolves `erli18n` from Hex into the plugin's lock as a level-0
`{pkg,...}` entry, and that entry is what `rebar3_hex`'s `create_package` carries
into the published `requirements`. So the plugin's `requirements` can only be
populated once the matching `erli18n` minor is on Hex; the workflow enforces the
order with an `erli18n`-first guard on the `rebar3_erli18n-v*` path (it fails
fast if the required `erli18n` minor is not yet published). When `erli18n`'s
minor advances, bump the `~>` constraint in `apps/rebar3_erli18n/rebar.config` in
the same release that depends on the new minor.

## Questions

Open an issue or a discussion. For security-sensitive matters see [`SECURITY.md`](SECURITY.md).
