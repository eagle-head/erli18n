# erli18n

[![Hex.pm](https://img.shields.io/hexpm/v/erli18n.svg)](https://hex.pm/packages/erli18n)
[![HexDocs](https://img.shields.io/badge/hex-docs-8e44ad.svg)](https://hexdocs.pm/erli18n/)
[![CI](https://github.com/eagle-head/erli18n/actions/workflows/ci.yml/badge.svg)](https://github.com/eagle-head/erli18n/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![OTP 27+](https://img.shields.io/badge/OTP-27%2B-a90533)](https://www.erlang.org/downloads)

Modern, GNU `gettext`–compatible internationalization (i18n) for Erlang/OTP — in pure Erlang.

> ### Why erli18n?
>
> It's first-class `gettext` i18n for Erlang/OTP, **natively** — no polyglot build, no routing through Elixir, no stalled dependency.
>
> - 📦 **Drop-in `.po` / `.pot`** — load the exact files your translators already produce in Poedit, Crowdin, Transifex, Weblate, or `xgettext`.
> - 🌍 **Real CLDR pluralization** — a true `Plural-Forms` evaluator, with CLDR rules inlined for **49 locales**.
> - ⚡ **Lock-free lookups** — reads run straight from ETS in your own process; only writes go through a `gen_server`. No bottleneck on the hot path.

## Quickstart

Add the dependency to `rebar.config`:

```erlang
{deps, [{erli18n, "0.1.0"}]}.
```

Then load a catalog and translate:

```erlang
application:ensure_all_started(erli18n).

%% Load a `.po` catalog for a (domain, locale). Parse -> compile plural rule ->
%% validate against CLDR -> insert: one atomic step. Returns {ok, NewlyLoaded}
%% (or {ok, already} if it was already loaded).
{ok, _Loaded} = erli18n_server:ensure_loaded(my_domain, <<"pt_BR">>,
    <<"priv/locale/pt_BR/LC_MESSAGES/my_domain.po">>).

%% Singular.
<<"Olá, mundo">> = erli18n:gettext(my_domain, <<"Hello, world">>, <<"pt_BR">>).

%% Plural. ngettext returns the correct plural FORM for N — it does NOT
%% interpolate the number (you format that yourself; see "Common patterns").
<<"arquivo">>  = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 1,  <<"pt_BR">>).
<<"arquivos">> = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42, <<"pt_BR">>).

%% Contextual. The same source word, disambiguated by a msgctxt.
<<"Maio">> = erli18n:pgettext(my_domain, <<"month">>, <<"May">>, <<"pt_BR">>).
<<"pode">> = erli18n:pgettext(my_domain, <<"verb">>,  <<"May">>, <<"pt_BR">>).
```

That is the whole surface: `gettext` (singular), `ngettext` (plural), `pgettext` (contextual), and `npgettext` (contextual + plural), each with `d` / `dc` domain-explicit variants — the full GNU gettext C-macro family, as Erlang functions.

## Common patterns

**Set the locale once per process** (e.g. one web request) — then every lookup in that process uses it, with no locale argument to thread around. App-wide, `set_default_locale/1` does the same for processes that never call `setlocale/1`:

```erlang
erli18n:setlocale(<<"pt_BR">>),                                  %% this process
%% erli18n:set_default_locale(<<"pt_BR">>),                      %% (or: app-wide default)

<<"Olá, mundo">> = erli18n:gettext(my_domain, <<"Hello, world">>),
<<"arquivos">>   = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42).
```

**Set a default domain** so the shortest forms work without naming it each time:

```erlang
erli18n:textdomain(my_domain),
<<"Olá, mundo">> = erli18n:gettext(<<"Hello, world">>).   %% default domain + resolved locale
```

**Format a pluralized count** — `ngettext` gives you the form; you interpolate the number:

```erlang
N = 3,
Form = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, N, <<"pt_BR">>),
<<"3 arquivos">> = iolist_to_binary(io_lib:format("~b ~ts", [N, Form])).
```

**Context + plural together** (`npgettext` — domain, context, singular, plural, N, locale):

```erlang
<<"comentários">> = erli18n:npgettext(my_domain, <<"ui">>,
    <<"comment">>, <<"comments">>, 5, <<"pt_BR">>).
```

**Load several catalogs at startup** in one batch:

```erlang
%% Each entry is {Domain, Locale, PoPath, Opts}; the result is one
%% {Domain, Locale, {ok, NewlyLoaded} | {ok, already} | {error, _}} per entry.
Results = erli18n_server:ensure_loaded_many([
    {my_domain, <<"pt_BR">>, <<"priv/locale/pt_BR/LC_MESSAGES/my_domain.po">>, #{}},
    {my_domain, <<"en_US">>, <<"priv/locale/en_US/LC_MESSAGES/my_domain.po">>, #{}}
]).
```

**Observe at runtime with telemetry** (optional) — for example, get notified whenever a lookup falls through to the source string:

```erlang
telemetry:attach(<<"erli18n-misses">>, [erli18n, lookup, miss],
    fun(_Event, _Measurements, Metadata, _Config) ->
        logger:info("i18n miss: ~p", [Metadata])
    end, undefined).
```

## Core concepts

A few things worth knowing before you reach for the API:

- **Locale is per-process.** `erli18n:setlocale(<<"pt_BR">>)` sets the locale for the *calling* process (stored in its process dictionary); `which_locale/0` reads it back. It is **not** inherited by processes you `spawn`. When a process hasn't set one, lookups fall back to the application-wide default. Passing the locale explicitly always wins.
- **Catalogs are keyed by domain + locale.** A *domain* is a gettext text domain (e.g. `my_domain`) — your way of grouping translations. You load each `(domain, locale)` catalog once; lookups then target a domain explicitly or use the default.
- **The `.po` header drives pluralization.** Each catalog's `Plural-Forms` header is the runtime source of truth for plural selection. CLDR rules (inlined for **49 locales**) are consulted only at load time — to emit a telemetry warning when a header diverges from CLDR, never to override it.
- **Misses degrade gracefully.** A lookup with no catalog, no entry, or an empty translation returns the original `msgid` (or `msgid_plural`), so your UI never shows a blank. And a crash of the catalog server does **not** wipe loaded translations: the ETS table is held by a dedicated owner/heir, so it survives and is handed back intact on restart.

## Why erli18n

Most Erlang projects today either reach for the venerable but [largely-stalled `gettexter`](https://github.com/seriyps/gettexter), or route strings through Elixir's `gettext` (which forces a polyglot build). `erli18n` is for projects that want **first-class i18n in pure Erlang/OTP** without giving up compatibility with the standard `gettext` translation tooling.

- **Drop-in `.po` / `.pot` compatibility** — a hand-written parser that handles real-world catalogs: contexts, plurals, fuzzy entries, charsets, BOMs, and obsolete entries. Works with Poedit, Crowdin, Transifex, Weblate, and `msgfmt` out of the box. (The exact `.po`-semantics decisions are documented in [`CHANGELOG.md`](CHANGELOG.md).)
- **CLDR-backed pluralization** — a real evaluator for the `Plural-Forms` C-expression, with CLDR plural rules inlined for **49 locales**.
- **The full gettext API** — `gettext` / `ngettext` / `pgettext` / `npgettext`, plus the `d` / `dc` domain-explicit variants.
- **Optional, first-class observability** — **7** [`telemetry`](https://github.com/beam-telemetry/telemetry) events (catalog load/reload/unload spans, lookup misses, plural divergence, rate-limited memory warnings). `telemetry` is an *optional* dependency: events fire only when your app ships it.
- **A lock-free hot path** — `lookup_*` reads run directly from ETS in the *calling* process; only writes (loading and reloading catalogs) go through the owning `gen_server`. No process bottleneck on the read side.
- **Heavily tested** — Common Test suites, PropEr property-based tests, fuzzing, and a parity suite that checks output byte-for-byte against GNU `msgfmt` as a ground-truth oracle. 100% behavioral coverage.

String **extraction** uses the standard GNU `xgettext` CLI — the same model as Spring `MessageSource`, Django, Rails I18n, and Symfony Translation. Compile-time key checking is intentionally out of scope; runtime lookup plus tests is the mainstream pattern.

## Installation

```erlang
{deps, [
    {erli18n, "0.1.0"}
]}.
```

For [`telemetry`](https://github.com/beam-telemetry/telemetry) observability (optional — `erli18n` runs fine without it), add it too:

```erlang
{deps, [
    {erli18n, "0.1.0"},
    {telemetry, "~> 1.3"}
]}.
```

## Compatibility

|                      | OTP 27 (minimum) | OTP 28 |
| -------------------- | :--------------: | :----: |
| Tier-1 (CI)          |        ✅        |   ✅   |

OTP 27 is the floor because the public modules use the native `-doc` / `-moduledoc` documentation attributes (EEP-59), which only compile on OTP 27+; on OTP 25.3 / 26 the compiler rejects them with `attribute doc after function definitions`. CI exercises OTP 27 and 28 on every push.

## Status

**Initial development (`0.1.0`).** Per [SemVer 2.0.0 §4](https://semver.org/#spec-item-4), the public API is functional but may change on a minor bump (`0.1.0` → `0.2.0`); patch bumps (`0.1.0` → `0.1.1`) stay backward-compatible. The criteria for a stable `1.0.0` are in [`CHANGELOG.md`](CHANGELOG.md).

## Documentation

- **API reference** — published on [HexDocs](https://hexdocs.pm/erli18n/), generated from the native `-doc` / `-moduledoc` attributes (OTP 27+ documentation). Every public module and function is documented there.
- **Changelog & design decisions** — [`CHANGELOG.md`](CHANGELOG.md) records each release, the versioning policy, and the `.po`-semantics and pluralization decisions behind the implementation.
- **Examples** — the `.po` fixtures under [`test/`](test/) cover plural forms, contexts, fuzzy entries, encodings, and edge cases — a practical reference for what `erli18n` accepts.

## Development

```sh
git clone git@github.com:eagle-head/erli18n.git
cd erli18n
rebar3 compile
bin/quality-gate.sh --fast    # ~30s:  compile + xref + erlfmt + elvis + hank + elp lint
bin/quality-gate.sh --full    # ~5min: + dialyzer + eqwalize-all + Common Test (+ coverage)
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full setup: toolchain pinning with `mise`, git hooks, local CI emulation with `act`, and the contribution workflow.

## Security

To report a vulnerability, see [`SECURITY.md`](SECURITY.md) — please do **not** open a public GitHub issue for security reports.

## License

[Apache License 2.0](LICENSE) (SPDX: `Apache-2.0`).

## References

- [GNU gettext manual](https://www.gnu.org/software/gettext/manual/gettext.html) — `.po` format and runtime semantics.
- [Unicode CLDR plural rules](https://cldr.unicode.org/index/cldr-spec/plural-rules) — pluralization data source.
- [`telemetry`](https://github.com/beam-telemetry/telemetry) — the observability framework.
- [`gettexter`](https://github.com/seriyps/gettexter) — historical Erlang gettext library whose API surface `erli18n` mirrors for easy migration.
