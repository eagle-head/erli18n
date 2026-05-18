# erli18n

[![Status: experimental](https://img.shields.io/badge/Status-experimental-orange.svg)](#status)
[![CI](https://github.com/eagle-head/erli18n/actions/workflows/ci.yml/badge.svg)](https://github.com/eagle-head/erli18n/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![OTP](https://img.shields.io/badge/OTP-25.3%2B-a90533)](https://www.erlang.org/downloads)
[![SemVer](https://img.shields.io/badge/SemVer-2.0.0-brightgreen)](https://semver.org/spec/v2.0.0.html)

Modern internationalization (i18n) library for Erlang/OTP, fully GNU `gettext` compatible. Drop-in support for `.po` / `.pot` files produced by Poedit, Crowdin, Transifex, Weblate, and the standard `xgettext` toolchain.

```erlang
% rebar.config: {deps, [{erli18n, "0.1.0"}]}.

application:ensure_all_started(erli18n).

%% Load a catalog (parse → compile plural → validate vs CLDR → insert, all atomic).
ok = erli18n_server:ensure_loaded(my_domain, <<"fr">>,
    <<"priv/locale/fr/LC_MESSAGES/my_domain.po">>).

%% Singular lookup.
<<"Bonjour, monde">> = erli18n:gettext(my_domain, <<"Hello, world">>, <<"fr">>).

%% Plural — header-of-.po Plural-Forms is the runtime source of truth.
<<"1 fichier">>   = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 1, <<"fr">>).
<<"42 fichiers">> = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42, <<"fr">>).

%% Contextual (msgctxt — disambiguates homographs).
<<"Mai">>         = erli18n:pgettext(my_domain, <<"month">>, <<"May">>, <<"fr">>).
<<"peut-être">>   = erli18n:pgettext(my_domain, <<"verb">>,  <<"May">>, <<"fr">>).
```

## Status

**Initial development (`0.1.0`).** Per [SemVer 2.0.0 §4](https://semver.org/#spec-item-4), the public API is functional but may break on minor bumps (`0.1.0` → `0.2.0`). Patch bumps (`0.1.0` → `0.1.1`) are strictly backward-compatible. The criteria for a stable `1.0.0` release are documented in [CHANGELOG.md](CHANGELOG.md).

## Why erli18n

Most Erlang projects today either reach for the venerable but [largely-stalled `gettexter`](https://github.com/seriyps/gettexter) or end up routing strings through Elixir's `gettext` (which forces a polyglot build). `erli18n` exists for projects that want **first-class i18n in pure Erlang/OTP**, without trading off compatibility with the standard `gettext` translation tooling.

Concretely:

- **Drop-in `.po` / `.pot` compatibility** — hand-written recursive-descent parser, honors all 9 PO-Semantics Decisions (PSD-001..009 in `CHANGELOG.md`). Works with Poedit, Crowdin, Transifex, Weblate, msgfmt out of the box.
- **CLDR-backed pluralization** — recursive-descent C-expression evaluator for the `Plural-Forms` header. CLDR plural rules inlined for 49 locales; the `.po` header is always runtime source of truth (CLDR consulted only for divergence warning at load).
- **Full GNU gettext API surface** — `gettext` / `ngettext` / `pgettext` / `npgettext`, with `d` / `dc` (domain-explicit) variants. Per-process locale via process dictionary, app-wide defaults via `application:get_env/2`.
- **First-class observability** — 7 `:telemetry` events (catalog load/reload/unload spans, lookup miss & fuzzy_skip opt-in, plural divergence, memory warning rate-limited). `telemetry` declared via `optional_applications` (OTP 24+) — emitted only when the consumer ships it.
- **Anti-bottleneck hot path** — `lookup_*` reads run lock-free from the caller process via direct ETS; writes are serialized through the gen_server owner. No process bottleneck on the lookup side.
- **238 tests, 100% behavioral coverage** — Common Test + PropEr properties (9 properties @ 200 runs) + fuzz scenarios (7 scenarios @ 100–500 runs) + parity SUITE comparing against `gettexter` + GNU `msgfmt` as ground-truth oracle.

Key extraction from source uses the standard GNU `xgettext` CLI — the same approach as Spring Boot MessageSource, Django, Rails I18n, Symfony Translation. Compile-time key validation is intentionally out of scope; runtime + tests is the mainstream pattern.

## Installation

Add to `rebar.config`:

```erlang
{deps, [
    {erli18n, "0.1.0"}
]}.
```

For [`:telemetry`](https://github.com/beam-telemetry/telemetry) observability (optional — `erli18n` runs without it):

```erlang
{deps, [
    {erli18n, "0.1.0"},
    {telemetry, "~> 1.3"}
]}.
```

## Compatibility

| | OTP 25.3 (minimum) | OTP 26 | OTP 27 | OTP 28 |
|---|---|---|---|---|
| Tier-1 (CI) | ✅ | — | ✅ | ✅ |
| Tier-2 (best effort) | — | ✅ | — | — |

OTP 25.3 is the floor because `optional_applications` and several supervisor-init APIs require OTP 25.3+. The CI matrix runs OTP 25.3, 27, and 28; OTP 26 is expected to work but is not exercised every push.

## Documentation

- **API reference** — `rebar3 edoc` regenerates EDoc from the `-doc` attributes (planned: hosted on HexDocs alongside the Hex release).
- **Architecture & design** — the `_reversa_sdd/migration/` corpus in the parent repository documents the design decisions, parity exceptions, risk register, ambiguity log, PropEr properties, and fuzz scenarios that drove the v0.1.0 implementation.
- **Examples** — see `test/erli18n_SUITE_data/` for canonical `.po` fixtures across plural forms, contexts, fuzzy entries, encodings, and edge cases.

## Development

```sh
git clone git@github.com:eagle-head/erli18n.git
cd erli18n
rebar3 compile
bin/quality-gate.sh --fast    # ~30s: compile + xref + erlfmt + elvis + hank + elp lint
bin/quality-gate.sh --full    # ~5min: + dialyzer + eqwalize-all + ct --cover
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full developer setup (mise toolchain pinning, git hooks, local CI emulation with `act`, and the contribution workflow).

## Security

Vulnerability disclosure: see [`SECURITY.md`](SECURITY.md). Do not report security issues via public GitHub issues.

## License

Licensed under the [Apache License, Version 2.0](LICENSE) (SPDX: `Apache-2.0`).

## References

- [GNU gettext manual](https://www.gnu.org/software/gettext/manual/gettext.html) — file format and runtime semantics.
- [Unicode CLDR plural rules](https://cldr.unicode.org/index/cldr-spec/plural-rules) — pluralization data source.
- [`telemetry`](https://github.com/beam-telemetry/telemetry) — observability framework.
- [`gettexter`](https://github.com/seriyps/gettexter) — historical Erlang gettext implementation, used here as the parity oracle.
- [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html) — release-notes and versioning standards adhered to.
