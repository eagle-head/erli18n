# erli18n

[![Hex.pm](https://img.shields.io/hexpm/v/erli18n.svg)](https://hex.pm/packages/erli18n)
[![HexDocs](https://img.shields.io/badge/hex-docs-8e44ad.svg)](https://hexdocs.pm/erli18n/)
[![CI](https://github.com/eagle-head/erli18n/actions/workflows/ci.yml/badge.svg)](https://github.com/eagle-head/erli18n/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![OTP 27+](https://img.shields.io/badge/OTP-27%2B-a90533)](https://www.erlang.org/downloads)

Modern, GNU `gettext`–compatible internationalization (i18n) for Erlang/OTP — in pure Erlang.

This repository is a **rebar3 umbrella** that ships **two separately-published Hex packages**:

| Package | Path | What it is |
| ------- | ---- | ---------- |
| [`erli18n`](apps/erli18n/) | [`apps/erli18n/`](apps/erli18n/) | The runtime i18n library — `.po`/`.pot` loading, CLDR pluralization, copy-free `persistent_term` lookups, and the full GNU gettext facade family (`gettext`, `ngettext`, `pgettext`, `npgettext`, plus interpolating `f`-suffix siblings), and optional per-request localization middleware for Cowboy & Elli. |
| [`rebar3_erli18n`](apps/rebar3_erli18n/) | [`apps/rebar3_erli18n/`](apps/rebar3_erli18n/) | The companion rebar3 plugin — an Erlang-native string extractor that walks your source's abstract forms and produces `.pot` templates, giving you `rebar3 erli18n {extract,merge,check,report}`. It is a separate Hex package that depends on `erli18n`. |

The two packages have **independent versions**, coupled only by the plugin's `~>` dependency constraint on the library (the plugin reuses `erli18n`'s public PO read/serialize API across the package boundary). The umbrella co-locates them for atomic cross-package changes and shared tooling; each is published to Hex on its own.

## Getting started

To consume both packages from a downstream project, add the runtime library as a dependency and the extractor as a plugin in your `rebar.config`:

```erlang
%% rebar.config of a downstream consumer
{deps, [{erli18n, "~> 0.6"}]}.
{plugins, [rebar3_erli18n]}.
```

For the runtime library — installation, the full facade API, locale negotiation, interpolation, and worked examples — see the package README:

➡️ **[`apps/erli18n/README.md`](apps/erli18n/README.md)**

For the string-extraction plugin — installation as a `{plugins, [...]}` entry and the `extract`/`merge`/`check`/`report` commands — see the plugin README:

➡️ **[`apps/rebar3_erli18n/README.md`](apps/rebar3_erli18n/README.md)**

A runnable downstream consumer that wires up both — real `gettext` call sites and committed catalogs — lives under [`examples/erli18n_demo/`](examples/erli18n_demo). Two runnable middleware examples show per-request locale negotiation in a web server: [`examples/erli18n_cowboy_demo/`](examples/erli18n_cowboy_demo) (Cowboy) and [`examples/erli18n_elli_demo/`](examples/erli18n_elli_demo) (Elli).

## Repository layout

```
.
├── apps/
│   ├── erli18n/          # the erli18n runtime library (Hex package)
│   │   ├── README.md     #   package-facing README (install + full API)
│   │   ├── CHANGELOG.md  #   the erli18n package changelog
│   │   ├── LICENSE       #   Apache-2.0
│   │   ├── rebar.config  #   runtime deps + this package's doc/hex config
│   │   └── include/ src/ test/
│   │                     #   (doc/ is generated ex_doc output → HexDocs,
│   │                     #    gitignored; not part of the source tree)
│   └── rebar3_erli18n/   # the rebar3 plugin (Hex package)
│       ├── README.md  CHANGELOG.md  LICENSE  rebar.config
│       └── src/ test/
├── examples/                 # runnable standalone example apps:
│   ├── erli18n_demo/         #   downstream consumer of both packages
│   ├── erli18n_cowboy_demo/  #   per-request localization middleware (Cowboy)
│   └── erli18n_elli_demo/    #   per-request localization middleware (Elli)
├── scripts/                # gen_docs.sh + ex_doc_config.escript (doc helpers)
├── rebar.config            # umbrella-wide settings only (plugins, profiles,
│                           #   dialyzer/xref/hank/erlfmt policy) — no
│                           #   package-specific doc/hex config lives here
├── LICENSE                 # umbrella license (Apache-2.0)
├── CHANGELOG.md            # umbrella-level history → links to per-app changelogs
├── CONTRIBUTING.md  CODE_OF_CONDUCT.md  SECURITY.md
```

Per published-app convention (each Hex package ships its own `LICENSE`, `README.md`, and `CHANGELOG.md` physically inside the app directory), the package-facing docs for each app live under `apps/<app>/`. The repo-root `README.md` (this file), `CHANGELOG.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and `SECURITY.md` are umbrella-level dev/community docs and are **not** shipped inside either package tarball.

## Development

```sh
git clone git@github.com:eagle-head/erli18n.git
cd erli18n
rebar3 compile
bin/quality-gate.sh --fast    # ~30s:  compile + xref + erlfmt + elvis + hank + elp lint
bin/quality-gate.sh --full    # ~5min: + dialyzer + eqwalize-all + Common Test (+ coverage)
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full setup: toolchain pinning with `mise`, git hooks, local CI emulation with `act`, and the contribution workflow.

## Documentation

- **API reference** — published on [HexDocs](https://hexdocs.pm/erli18n/), generated from the native `-doc` / `-moduledoc` attributes (OTP 27+ documentation).
- **Changelogs** — each package owns its changelog: [`apps/erli18n/CHANGELOG.md`](apps/erli18n/CHANGELOG.md) and [`apps/rebar3_erli18n/CHANGELOG.md`](apps/rebar3_erli18n/CHANGELOG.md). Umbrella-level repo history is in the root [`CHANGELOG.md`](CHANGELOG.md).

## Security

To report a vulnerability, see [`SECURITY.md`](SECURITY.md) — please do **not** open a public GitHub issue for security reports.

## License

[Apache License 2.0](LICENSE) (SPDX: `Apache-2.0`). Each package ships its own copy of the license under `apps/<app>/LICENSE`.

## References

- [GNU gettext manual](https://www.gnu.org/software/gettext/manual/gettext.html) — `.po` format and runtime semantics.
- [Unicode CLDR plural rules](https://cldr.unicode.org/index/cldr-spec/plural-rules) — pluralization data source.
- [`telemetry`](https://github.com/beam-telemetry/telemetry) — the observability framework.
- [`gettexter`](https://github.com/seriyps/gettexter) — historical Erlang gettext library whose API surface `erli18n` mirrors for easy migration.
