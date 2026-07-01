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
> - 🌍 **Real CLDR pluralization** — a true `Plural-Forms` evaluator backed by the upstream CLDR plural rules, inlined for offline use.
> - ⚡ **Copy-free lookups** — reads run straight from `persistent_term` in your own process, with no copy onto the caller heap and no lock; only writes go through a `gen_server`. No bottleneck on the hot path.
> - 🌐 **Per-request localization for Cowboy & Elli** — optional `erli18n_cowboy` / `erli18n_elli` middleware negotiate the request locale (query → cookie → `Accept-Language`) and set it before your handler, so handlers translate with no locale argument. Both are optional like `telemetry`: not pulled into the published `kernel` + `stdlib` build.

## Quickstart

Add the dependency to `rebar.config`:

```erlang
{deps, [{erli18n, "~> 0.7"}]}.
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

%% Plural. ngettext returns the correct plural FORM for N (it selects the
%% form; the `f` family below splices the number in — see "Interpolation").
<<"arquivo">>  = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 1,  <<"pt_BR">>).
<<"arquivos">> = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42, <<"pt_BR">>).

%% Contextual. The same source word, disambiguated by a msgctxt.
<<"Maio">> = erli18n:pgettext(my_domain, <<"month">>, <<"May">>, <<"pt_BR">>).
<<"pode">> = erli18n:pgettext(my_domain, <<"verb">>,  <<"May">>, <<"pt_BR">>).

%% Interpolating. The `f`-suffix family resolves the translation, then
%% splices named `%{var}` placeholders from a Bindings map (see below).
<<"3 arquivos">> = erli18n:ngettextf(my_domain, <<"%{count} file">>,
    <<"%{count} files">>, 3, <<"pt_BR">>, #{}).   %% count => 3 auto-bound
```

That is the whole surface: `gettext` (singular), `ngettext` (plural), `pgettext` (contextual), and `npgettext` (contextual + plural), each with `d` / `dc` domain-explicit variants — the full GNU gettext C-macro family, as Erlang functions. Each also has an interpolating `f`-suffix sibling (`gettextf`, `ngettextf`, `pgettextf`, `npgettextf`) that splices named `%{var}` values into the resolved string.

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

**Format a pluralized count** — use the `f`-suffix `ngettextf`: it selects the plural form *and* splices the number in. The count is auto-bound as `%{count}`, so the translator controls where the number lands in each language:

```erlang
%% Source: msgid "%{count} file" / msgid_plural "%{count} files"
%% pt_BR:  msgstr[0] "%{count} arquivo" / msgstr[1] "%{count} arquivos"
<<"3 arquivos">> = erli18n:ngettextf(my_domain,
    <<"%{count} file">>, <<"%{count} files">>, 3, <<"pt_BR">>, #{}).
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

## Interpolation

Every lookup family has an interpolating `f`-suffix sibling — `gettextf`, `ngettextf`, `pgettextf`, `npgettextf` (plus the `d` / `dc` aliases) — that takes a trailing `Bindings :: map()`. Each `f` function resolves the translation exactly like its non-`f` sibling, then substitutes **named `%{var}` placeholders** in the result:

```erlang
erli18n:setlocale(<<"pt_BR">>),

%% Source msgid "Hello, %{name}!" with pt_BR msgstr "Olá, %{name}!"
<<"Olá, Ada!">> = erli18n:gettextf(my_domain, <<"Hello, %{name}!">>,
    #{name => <<"Ada">>}).
```

Named placeholders (rather than positional `~s`) decouple the wording from argument order: a translator can move `%{name}` anywhere in the sentence — or repeat it — and the binding still resolves by name. Binding keys are atoms; values may be a binary, an iolist/string, an integer, a float, or an atom, and are coerced to UTF-8 text. **Plural members auto-bind `count => N`**, so `%{count}` is always available without passing it yourself (a caller-supplied `count` wins):

```erlang
%% pt_BR msgstr[1] "%{count} arquivos" — count auto-bound to 42
<<"42 arquivos">> = erli18n:ngettextf(my_domain,
    <<"%{count} file">>, <<"%{count} files">>, 42, <<"pt_BR">>, #{}).
```

**Escaping.** A literal percent is `%%`; to emit a literal `%{name}` un-substituted, write `%%{name}` (the `%%` collapses to `%`, leaving `{name}` untouched):

```erlang
<<"100% sure">>   = erli18n:gettextf(<<"100%% sure">>, #{}).
<<"use %{name}">> = erli18n:gettextf(<<"use %%{name}">>, #{name => <<"X">>}).
```

**Missing bindings — `lenient` vs `strict`.** The `f` functions on `erli18n` are **lenient**: an unbound `%{name}` is left in place literally and nothing crashes. Interpolation is total and fail-soft — for any input and any bindings it returns a binary and never raises. When you want an unbound placeholder to be a hard error instead, call `erli18n_interp:format/3` directly with the `strict` policy:

```erlang
%% Lenient (the f-family default): unknown placeholder stays literal.
<<"Hi %{who}">> = erli18n:gettextf(<<"Hi %{who}">>, #{}).

%% Strict: opt in via erli18n_interp:format/3 — raises on a missing binding.
erli18n_interp:format(<<"Hi %{who}">>, #{}, #{on_missing => strict}).
%% ** exception error: {erli18n_interp, {missing_binding, who}}
```

> ### Bidi / RTL caveat
>
> Interpolation does **not** auto-insert Unicode bidi isolation marks (U+2066–U+2069) around spliced values. Placing an RTL value (Arabic, Hebrew) into an LTR sentence — or the reverse — can reorder neighboring punctuation under the Unicode Bidirectional Algorithm. If you mix directions, isolate the values yourself.

## Locale negotiation & fallback (opt-in)

Catalogs are keyed by exact binary, so by default a `pt_BR` request only matches a `pt_BR` catalog. Two **opt-in** pieces close the common gaps — without changing the default exact-match behavior or touching the copy-free hot path.

**1. Request-time negotiation** (`erli18n_negotiate`, exposed on the facade). Pick the best locale a client supports from those you have loaded. `parse_accept_language/1` turns an HTTP header into a priority-ordered list; `negotiate/2` resolves it (with BCP-47 canonicalization and base-language fallback) against your available set, always returning a usable locale:

```erlang
Available = [<<"en">>, <<"pt">>, <<"de">>],

%% Hyphenated, mixed-case, and legacy tags all canonicalize to match.
{ok, <<"pt">>} = erli18n:negotiate([<<"pt-BR">>], Available),

%% Straight from an Accept-Language header (q-values honored, q=0 dropped).
{ok, <<"de">>} = erli18n:negotiate(
    erli18n:parse_accept_language(<<"fr-CH, de;q=0.9, en;q=0.5">>),
    Available),

%% One-off tag canonicalization to the catalog-key shape.
<<"pt_BR">> = erli18n:canonicalize_locale(<<"PT-br.UTF-8">>).
```

A typical web handler negotiates once per request and calls `setlocale/1`:

```erlang
Prefs = erli18n:parse_accept_language(AcceptLanguageHeader),
{ok, Locale} = erli18n:negotiate(Prefs, my_supported_locales()),
erli18n:setlocale(Locale).
```

**2. Lookup-time fallback chain** (`erli18n.locale_fallback`, default `off`). When enabled, a lookup that misses the exact locale walks a canonicalization-aware BCP-47 chain before falling back to the `msgid`, so a `pt_BR` user reads a loaded `pt` catalog:

```erlang
%% Only a "pt" catalog is loaded.
<<"Hello">> = erli18n:gettext(my_domain, <<"Hello">>, <<"pt_BR">>),  %% off: raw msgid

erli18n:set_locale_fallback(base_language),
<<"Olá"/utf8>> = erli18n:gettext(my_domain, <<"Hello">>, <<"pt_BR">>).  %% pt_BR -> pt
```

`locale_fallback` accepts `off` (default), `base_language` (`pt_BR` → `pt` → `default_locale`), or `{explicit, Map}` where `Map :: #{locale() => [locale()]}` overrides specific locales (unlisted ones fall through to `base_language`). The chain runs **only on a miss** and **only** when enabled, so an exact hit stays a single copy-free `persistent_term:get` with zero added cost. Canonicalization covers separator (`pt-BR`/`pt_BR`) and case normalization plus a closed legacy-alias set (`iw`→`he`, `in`→`id`, `ji`→`yi`, `jw`→`jv`, `mo`→`ro`). Script⇄region *Likely Subtags* inference (`zh_Hans` ⇄ `zh_CN`) is an explicit non-goal — load catalogs under the keys your clients send, or use an `{explicit, Map}`.

## Per-request localization (Cowboy / Elli)

Two **optional** adapters wire that per-request negotiation into a web framework so you stop hand-rolling it: [`erli18n_cowboy`](https://hexdocs.pm/erli18n/erli18n_cowboy.html) (a `cowboy_middleware`) and [`erli18n_elli`](https://hexdocs.pm/erli18n/erli18n_elli.html) (an `elli_middleware`), both built on the pure, framework-agnostic core [`erli18n_http`](https://hexdocs.pm/erli18n/erli18n_http.html) (`negotiate_locale/3`, `negotiate_locale_lazy/4`, `cookie_value/2`, and `query_value/2`), which you can also call directly when wiring a framework the adapters don't cover. Both negotiate the locale from the request and call `setlocale/1` before your handler runs, so handlers translate with no locale argument. `cowboy`/`elli` are optional **like `telemetry`** — neither is a dependency of the published package, which still runs on `kernel` + `stdlib` alone; you add whichever framework you already use.

```erlang
%% Cowboy: install the middleware ahead of the handler.
Dispatch = cowboy_router:compile([{'_', [{"/[...]", my_handler, []}]}]),
cowboy:start_clear(http, [{port, 8080}], #{
    env => #{dispatch => Dispatch, erli18n => #{cookie_name => <<"locale">>}},
    middlewares => [erli18n_cowboy, cowboy_router, cowboy_handler]
}).
```

The default precedence is **query string > cookie > `Accept-Language` header > default** (i18next's order; Django's "explicit beats persisted beats browser-preferred" spirit), configurable per request. The available set defaults to `erli18n:loaded_locales/0` — the distinct locales you have actually loaded, the authoritative thing to negotiate against — and the default to `default_locale/0`.

The query seam is **total and fail-soft on both adapters**: each adapter feeds the raw query binary (Cowboy's `cowboy_req:qs/1`, Elli's `elli_request:query_str/1` — both total, never raising) to the single core extractor `erli18n_http:query_value/2`, which percent-decodes the matched value itself. A value-less key (`?locale`) and a malformed percent-escape (`?locale=%ZZ`, bare `?%`, `?locale=%E0%`) are simply skipped, never crashing the request. Per-request option **values** are equally fail-soft: a malformed `default` or `available` falls back to the documented default (`default_locale/0` / `loaded_locales/0`) with a one-time `logger:warning`, so an operator misconfiguration is observable rather than request-fatal.

**Mind the spawn boundary.** As above, the locale is per-process and is **not** inherited across a spawn. Cowboy and Elli run the middleware and handler in one request process, so the handler sees it — but any cross-process handoff (a pooled worker, a shared `gen_server`, a `Task`-style spawn, a Cowboy stream handler that offloads) starts at `which_locale() = undefined`. Capture `Locale = erli18n:which_locale()` and re-`setlocale/1` it in the worker, or pass it explicitly. The adapters also set `logger` process metadata `#{locale => L}` by default so request logs carry it. The `erli18n_cowboy` module docs cover the full hazard, the mitigations, and a Phoenix interop note (no Elixir dependency).

## Core concepts

A few things worth knowing before you reach for the API:

- **Locale is per-process.** `erli18n:setlocale(<<"pt_BR">>)` sets the locale for the *calling* process (stored in its process dictionary); `which_locale/0` reads it back. It is **not** inherited by processes you `spawn`. When a process hasn't set one, lookups fall back to the application-wide default. Passing the locale explicitly always wins.
- **Catalogs are keyed by domain + locale.** A *domain* is a gettext text domain (e.g. `my_domain`) — your way of grouping translations. You load each `(domain, locale)` catalog once; lookups then target a domain explicitly or use the default.
- **The `.po` header drives pluralization.** Each catalog's `Plural-Forms` header is the runtime source of truth for plural selection. CLDR rules (inlined as a static table that tracks the upstream GNU gettext / CLDR data) are consulted only at load time — to emit a telemetry warning when a header diverges from CLDR, never to override it.
- **Misses degrade gracefully.** A lookup with no catalog, no entry, or an empty translation returns the original `msgid` (or `msgid_plural`), so your UI never shows a blank. And a crash of the catalog server does **not** wipe loaded translations: catalogs live in `persistent_term`, which is owned by the runtime (not by the server process), so they survive a server crash untouched — no dedicated table owner or heir is needed.

## Why erli18n

Most Erlang projects today either reach for the venerable but [largely-stalled `gettexter`](https://github.com/seriyps/gettexter), or route strings through Elixir's `gettext` (which forces a polyglot build). `erli18n` is for projects that want **first-class i18n in pure Erlang/OTP** without giving up compatibility with the standard `gettext` translation tooling.

- **Drop-in `.po` / `.pot` compatibility** — a hand-written parser that handles real-world catalogs: contexts, plurals, fuzzy entries, charsets, BOMs, and obsolete entries. Works with Poedit, Crowdin, Transifex, Weblate, and `msgfmt` out of the box. (The exact `.po`-semantics decisions are documented in [`CHANGELOG.md`](CHANGELOG.md).) The `erli18n_po` module exposes this read/serialize surface as public API — `parse/1,2`, `parse_file/1,2`, `dump/1`, and `escape_string/1` (the five GNU gettext PO escapes — backslash, double-quote, newline, tab, carriage return — applied exactly as `dump/1` does). `escape_string/1` is published so the separate [`rebar3_erli18n`](https://github.com/eagle-head/erli18n/tree/main/apps/rebar3_erli18n) plugin can serialize the PO metadata it owns byte-identically to `dump/1` across the `{deps, [erli18n]}` boundary, instead of vendoring a duplicate escaper.
- **CLDR-backed pluralization** — a real evaluator for the `Plural-Forms` C-expression, with the upstream CLDR plural rules inlined for offline use.
- **The full gettext API** — `gettext` / `ngettext` / `pgettext` / `npgettext`, plus the `d` / `dc` domain-explicit variants, and an interpolating `f`-suffix family (`gettextf`, …) for named `%{var}` substitution.
- **Optional, first-class observability** — **8** [`telemetry`](https://github.com/beam-telemetry/telemetry) events (catalog load/reload/unload spans, lookup misses, fuzzy-entry skips, locale fallback, plural divergence, rate-limited memory warnings). `telemetry` is an *optional* dependency: events fire only when your app ships it.
- **A copy-free hot path** — `lookup_*` reads run directly from `persistent_term` in the *calling* process, with no copy onto the caller heap and no lock; only writes (loading and reloading catalogs) go through the owning `gen_server`. No process bottleneck on the read side. A reload or unload defers a one-time, node-wide `persistent_term` literal-area GC, paid once per write and negligible for the load-once workload.
- **Heavily tested** — Common Test suites, PropEr property-based tests, fuzzing, and a parity suite that checks output byte-for-byte against GNU `msgfmt` as a ground-truth oracle. 100% behavioral coverage.

String **extraction** is handled by the companion rebar3 plugin, [`rebar3_erli18n`](https://github.com/eagle-head/erli18n/tree/main/apps/rebar3_erli18n) — an Erlang-native extractor that walks your source's abstract forms and recognizes the full facade family by name and arity, producing `.pot` templates (the `mix gettext.extract` experience for Erlang). It is shipped as a **separate** Hex package that depends on this library (`{deps, [{erli18n, "~> 0.7"}]}`); consumers opt in with `{plugins, [rebar3_erli18n]}` and gain `rebar3 erli18n {extract,merge,check,report,compile}`. Only **compile-time-literal** msgids are extracted (runtime-computed keys still translate, they just aren't discovered statically) — the same model and the same caveat as Elixir's Gettext. The plugin also offers an **opt-in** `compile` provider that bakes catalogs into BEAM carriers plus an **opt-in** compile-time key-existence check (`rebar3 erli18n compile`); runtime lookup plus the `check` freshness gate remains the default. (The plugin is published as its own Hex package, after this library; see [`apps/rebar3_erli18n/README.md`](https://github.com/eagle-head/erli18n/blob/main/apps/rebar3_erli18n/README.md).)

**Compiled catalogs (opt-in).** By default catalogs load at runtime from `.po` files with [`erli18n:ensure_loaded/3,4`](https://hexdocs.pm/erli18n/erli18n.html). As an opt-in alternative, the `rebar3_erli18n` plugin can bake each catalog — already parsed, with its `Plural-Forms` rule already compiled — into a generated BEAM module, and [`erli18n:register_compiled_catalogs/1`](https://hexdocs.pm/erli18n/erli18n.html) registers them at boot with **no `.po` parse and no plural compile** (the install cost remains; it is *no parse / no compile at startup*, not *zero-load*). Call it once in your app's `start/2`, before the supervision tree. See the "Compiled catalogs" section of the `erli18n` module docs and the plugin README.

## Installation

```erlang
{deps, [
    {erli18n, "~> 0.7"}
]}.
```

For [`telemetry`](https://github.com/beam-telemetry/telemetry) observability (optional — `erli18n` runs fine without it), add it too:

```erlang
{deps, [
    {erli18n, "~> 0.7"},
    {telemetry, "~> 1.3"}
]}.
```

For the optional per-request adapters, add the web framework you already use to **your** application's `{deps}` — `erli18n` does not pull `cowboy` or `elli` in (they are optional like `telemetry`), so the published library keeps building on `kernel` + `stdlib` alone:

```erlang
{deps, [
    {erli18n, "~> 0.7"},
    {cowboy, "~> 2.13"}    %% or: {elli, "~> 3.3"}
]}.
```

## Compatibility

|                      | OTP 27 (minimum) | OTP 28 | OTP 29 |
| -------------------- | :--------------: | :----: | :----: |
| Tier-1 (CI)          |        ✅        |   ✅   |   ✅   |

OTP 27 is the floor because the public modules use the native `-doc` / `-moduledoc` documentation attributes (EEP-59), which only compile on OTP 27+; on OTP 25.3 / 26 the compiler rejects them with `attribute doc after function definitions`. CI exercises OTP 27, 28, and 29 — all Tier-1 — on every push to `main` and every pull request.

## Status

**Initial development (`0.7.0`).** Per [SemVer 2.0.0 §4](https://semver.org/#spec-item-4), the public API is functional but may change on a minor bump (`0.7.0` → `0.8.0`); patch bumps (`0.7.0` → `0.7.1`) stay backward-compatible. The criteria for a stable `1.0.0` are in [`CHANGELOG.md`](CHANGELOG.md).

## Documentation

- **API reference** — published on [HexDocs](https://hexdocs.pm/erli18n/), generated from the native `-doc` / `-moduledoc` attributes (OTP 27+ documentation). Every public module and function is documented there.
- **Changelog & design decisions** — [`CHANGELOG.md`](CHANGELOG.md) records each release, the versioning policy, and the `.po`-semantics and pluralization decisions behind the implementation.
- **Examples** — the `.po` fixtures under [`apps/erli18n/test/`](https://github.com/eagle-head/erli18n/tree/main/apps/erli18n/test) cover plural forms, contexts, fuzzy entries, encodings, and edge cases — a practical reference for what `erli18n` accepts. A runnable downstream consumer lives under [`examples/erli18n_demo/`](https://github.com/eagle-head/erli18n/tree/main/examples/erli18n_demo), with real `gettext` call sites and committed catalogs. Two runnable middleware examples show per-request locale negotiation end to end: [`examples/erli18n_cowboy_demo/`](https://github.com/eagle-head/erli18n/tree/main/examples/erli18n_cowboy_demo) (Cowboy) and [`examples/erli18n_elli_demo/`](https://github.com/eagle-head/erli18n/tree/main/examples/erli18n_elli_demo) (Elli).

## Development

```sh
git clone git@github.com:eagle-head/erli18n.git
cd erli18n
rebar3 compile
bin/quality-gate.sh --fast    # ~30s:  compile + xref + erlfmt + elvis + hank + elp lint + actionlint
bin/quality-gate.sh --full    # ~5min: + dialyzer + eqwalize-all + Common Test (+ coverage) + gettext parity
```

See [`CONTRIBUTING.md`](https://github.com/eagle-head/erli18n/blob/main/CONTRIBUTING.md) for the full setup: toolchain pinning with `mise`, git hooks, local CI emulation with `act`, and the contribution workflow.

## Security

To report a vulnerability, see [`SECURITY.md`](https://github.com/eagle-head/erli18n/blob/main/SECURITY.md) — please do **not** open a public GitHub issue for security reports.

## License

[Apache License 2.0](LICENSE) (SPDX: `Apache-2.0`).

## References

- [GNU gettext manual](https://www.gnu.org/software/gettext/manual/gettext.html) — `.po` format and runtime semantics.
- [Unicode CLDR plural rules](https://cldr.unicode.org/index/cldr-spec/plural-rules) — pluralization data source.
- [`telemetry`](https://github.com/beam-telemetry/telemetry) — the observability framework.
- [`gettexter`](https://github.com/seriyps/gettexter) — historical Erlang gettext library whose API surface `erli18n` mirrors for easy migration.
