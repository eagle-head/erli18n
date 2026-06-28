# Locale negotiation & per-request localization

Catalogs are keyed by an exact binary, so by default a `pt_BR` request only
matches a `pt_BR` catalog. This guide covers the two opt-in pieces that close
the common gaps — request-time negotiation and a lookup-time fallback chain —
and the optional Cowboy/Elli middleware that wires them into a web framework.
None of this changes the default exact-match behavior or touches the copy-free
hot path. Full reference: [`erli18n_negotiate`](erli18n_negotiate.html),
[`erli18n_http`](erli18n_http.html), [`erli18n_cowboy`](erli18n_cowboy.html),
[`erli18n_elli`](erli18n_elli.html).

## 1. Request-time negotiation

Pick the best locale a client supports from those you have loaded.
`parse_accept_language/1` turns an HTTP header into a priority-ordered list;
`negotiate/2` resolves it against your available set (with BCP-47
canonicalization and base-language fallback), always returning a usable locale:

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

A typical handler negotiates once per request and calls `setlocale/1`:

```erlang
Prefs = erli18n:parse_accept_language(AcceptLanguageHeader),
{ok, Locale} = erli18n:negotiate(Prefs, my_supported_locales()),
erli18n:setlocale(Locale).
```

## 2. Lookup-time fallback chain

The `erli18n.locale_fallback` setting (default `off`) controls what a lookup
does when it misses the exact locale. When enabled, the lookup walks a
canonicalization-aware BCP-47 chain before falling back to the `msgid`, so a
`pt_BR` user reads a loaded `pt` catalog:

```erlang
%% Only a "pt" catalog is loaded.
<<"Hello">>    = erli18n:gettext(my_domain, <<"Hello">>, <<"pt_BR">>),  %% off: raw msgid

erli18n:set_locale_fallback(base_language),
<<"Olá"/utf8>> = erli18n:gettext(my_domain, <<"Hello">>, <<"pt_BR">>).  %% pt_BR -> pt
```

`set_locale_fallback/1` accepts:

- `off` (default) — exact match only.
- `base_language` — `pt_BR` → `pt` → the application default locale.
- `{explicit, Map}` where `Map :: #{locale() => [locale()]}` overrides specific
  locales; unlisted ones still fall through to `base_language`.

The chain runs **only on a miss** and **only** when enabled, so an exact hit
stays a single copy-free `persistent_term:get` with zero added cost.
Canonicalization covers separator and case normalization plus a closed
legacy-alias set (`iw`→`he`, `in`→`id`, `ji`→`yi`, `jw`→`jv`, `mo`→`ro`).
Script⇄region *Likely Subtags* inference (`zh_Hans` ⇄ `zh_CN`) is an explicit
non-goal — load catalogs under the keys your clients send, or use an
`{explicit, Map}`.

## 3. Per-request middleware (Cowboy / Elli)

Two optional adapters wire that negotiation into a web framework so you stop
hand-rolling it: [`erli18n_cowboy`](erli18n_cowboy.html) (a `cowboy_middleware`)
and [`erli18n_elli`](erli18n_elli.html) (an `elli_middleware`), both built on the
pure, framework-agnostic core [`erli18n_http`](erli18n_http.html). Both negotiate
the locale and call `setlocale/1` before your handler runs, so handlers
translate with no locale argument. Like `telemetry`, neither framework is a
dependency of the published package — you add whichever you already use.

```erlang
%% Cowboy: install the middleware ahead of the handler.
Dispatch = cowboy_router:compile([{'_', [{"/[...]", my_handler, []}]}]),
cowboy:start_clear(http, [{port, 8080}], #{
    env => #{dispatch => Dispatch, erli18n => #{cookie_name => <<"locale">>}},
    middlewares => [erli18n_cowboy, cowboy_router, cowboy_handler]
}).
```

The default precedence is **query string > cookie > `Accept-Language` header >
default** (configurable per request). The available set defaults to
`erli18n:loaded_locales/0` and the default to `default_locale/0`.

### Fail-soft by construction

The query seam is total on both adapters: each feeds the raw query binary
(Cowboy's `cowboy_req:qs/1`, Elli's `elli_request:query_str/1` — both never
raising) to the single core extractor `erli18n_http:query_value/2`, which
percent-decodes the matched value itself. A value-less key (`?locale`) or a
malformed escape (`?locale=%ZZ`) is skipped, never crashing the request. A
malformed per-request `default` / `available` option falls back to the
documented default with a one-time `logger:warning`, so an operator
misconfiguration is observable rather than request-fatal.

### Mind the spawn boundary

The locale is per-process and is **not** inherited across a spawn. Cowboy and
Elli run the middleware and handler in one request process, so the handler sees
it — but any cross-process handoff (a pooled worker, a shared `gen_server`, a
`Task`-style spawn, a Cowboy stream handler that offloads) starts at
`which_locale() = undefined`. Capture `Locale = erli18n:which_locale()` and
re-`setlocale/1` it in the worker, or pass it explicitly. The adapters also set
`logger` process metadata `#{locale => L}` by default so request logs carry it.
The [`erli18n_cowboy`](erli18n_cowboy.html) module docs cover the full hazard,
the mitigations, and a Phoenix interop note (no Elixir dependency).

## Runnable examples

Two end-to-end middleware demos live in the repository:
[`examples/erli18n_cowboy_demo/`](https://github.com/eagle-head/erli18n/tree/main/examples/erli18n_cowboy_demo)
and
[`examples/erli18n_elli_demo/`](https://github.com/eagle-head/erli18n/tree/main/examples/erli18n_elli_demo).

## Where to next

- [Getting started](getting-started.html) — load a catalog and translate.
- [Pluralization](pluralization.html) — how a locale's plural rule is chosen.
- [`erli18n_negotiate`](erli18n_negotiate.html) — the negotiation/canonicalization
  reference.
