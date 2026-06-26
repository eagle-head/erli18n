# Umbrella changelog

This repository is a rebar3 umbrella that publishes two separate Hex packages.
Each package keeps its own changelog as the source of truth for its releases:

- **`erli18n`** (runtime library) — [`apps/erli18n/CHANGELOG.md`](apps/erli18n/CHANGELOG.md)
- **`rebar3_erli18n`** (rebar3 plugin) — [`apps/rebar3_erli18n/CHANGELOG.md`](apps/rebar3_erli18n/CHANGELOG.md)

This file records only **umbrella-level** history — repository structure and
shared-tooling changes that are not specific to a single package. For what
changed in a published package, read that package's changelog above.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Two runnable middleware example apps under `examples/`.**
  `examples/erli18n_cowboy_demo/` and `examples/erli18n_elli_demo/` are standalone
  rebar3 projects that demonstrate the optional `erli18n_cowboy` / `erli18n_elli`
  per-request localization middleware end to end — a web server that negotiates
  the request locale (query → cookie → `Accept-Language`) and translates in the
  handler with no locale argument, with committed `pt_BR` / `es` catalogs and a
  `curl` matrix proving each negotiation source. Like `examples/erli18n_demo`,
  each lives outside `apps/` and surfaces the unpublished in-repo `erli18n`
  through a gitignored `_checkouts/` symlink.

### Changed

- **Restructured the repository into a self-contained two-package umbrella.**
  Each published app now physically owns its package-facing docs: the
  `erli18n` library README and changelog were relocated from the repo root
  into [`apps/erli18n/`](apps/erli18n/), joining the plugin which already
  carried its own (`apps/rebar3_erli18n/`). A verbatim Apache-2.0 `LICENSE`
  was added to each app. This is required for Hex packaging: `rebar3_hex`
  globs a package's files relative to the app directory, so root-level
  `README`/`CHANGELOG`/`LICENSE` were never shipped inside the `erli18n`
  tarball before this change.
- **Moved package-specific doc configuration out of the umbrella root.** The
  `erli18n` package's `{ex_doc, ...}` and `{hex, {doc, ...}}` blocks now live
  in [`apps/erli18n/rebar.config`](apps/erli18n/rebar.config) (with the ExDoc
  `extras` referencing only that package's own README/CHANGELOG/LICENSE). The
  umbrella root `rebar.config` keeps only umbrella-wide settings: project
  plugins, the `test` profile, and the dialyzer/xref/hank/erlfmt policy.
