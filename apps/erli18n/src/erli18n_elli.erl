-module(erli18n_elli).

-moduledoc """
Optional Elli middleware that negotiates the request locale and sets it before
the handler runs — the Elli counterpart to `erli18n_cowboy`.

`elli` is an **optional** dependency (declared via `optional_applications`, like
`telemetry`): erli18n does not require it and the published package still builds
on `kernel` + `stdlib` alone. This module only runs when an Elli application
installs it via `elli_middleware`, so Elli is present whenever the code runs.
`elli_request` is therefore an externally-provided runtime module, not a build
dependency (the same situation as the rebar3 host API in `rebar3_erli18n_host`):
its calls are confined to a small seam (see the "elli_request seam" section
below) and the default build's xref/dialyzer/eqwalizer are kept clean by
suppressions scoped to exactly those external edges (`-ignore_xref` + the root
`{xref_ignores,...}`, a function-scoped `-dialyzer({no_unknown,...})`, and a
`% elp:ignore W0017` per call site). Every other call stays fully checked.

## Install it

Add `elli` to *your* deps (erli18n does not pull it in), then list `erli18n_elli`
in the `elli_middleware` `mods` ahead of your real handler. Per-middleware
options are the second element of the `{Mod, Args}` pair:

```erlang
application:ensure_all_started(erli18n),
{ok, _} = erli18n_server:ensure_loaded(my_domain, <<"pt_BR">>, "priv/.../my_domain.po"),

Config = [
    {mods, [
        {erli18n_elli, #{cookie_name => <<"locale">>, query_param => <<"lang">>}},
        {my_callback, []}
    ]}
],
elli:start_link([{callback, elli_middleware}, {callback_args, Config}, {port, 8080}]).
```

It runs as an `elli_middleware` pre-processor: `preprocess/2` sets the locale on
the request process before your handler. The module deliberately exports only
`preprocess/2`, not `handle/2`: `elli_middleware` skips the handle phase for any
mod that does not export `handle/2` (its `?IF_NOT_EXPORTED` guard), so this
middleware never intercepts a real handler. A `handle/2 -> ignore` clause would
be unreachable dead code.

## Options (the `Args` map, all optional)

| Key | Default | Meaning |
| :-- | :-- | :-- |
| `sources` | `[query, cookie, header]` | precedence order, highest first |
| `query_param` | `<<"locale">>` | query-string parameter carrying a locale |
| `cookie_name` | `<<"locale">>` | cookie carrying a locale |
| `available` | `erli18n:loaded_locales/0` | the authoritative supported-locale set |
| `default` | `erli18n:default_locale/0` | fallback when nothing matches |
| `set_logger_metadata` | `true` | also set `logger` process metadata `#{locale => L}` |

Default precedence is **query > cookie > Accept-Language header > default**, and
`available`/`default` are resolved **per request**. Negotiation, canonicalization,
and cookie parsing are delegated to `erli18n_http` / `erli18n_negotiate`. The
`path` source is Cowboy-only (Elli exposes the path as raw segments); listing it
here is a harmless no-op.

## Per-process locale, the cross-process hazard, and Phoenix interop

Identical to the Cowboy adapter: Elli runs the middleware and handler in one
request process, so the locale set here is visible to the handler, but it is
**not inherited across a spawn** (worker pools, `gen_server`s, `Task`-style
spawns). See `erli18n_cowboy` for the full discussion of the hazard, the
mitigations (capture-and-re-set, pass explicitly, propagate logger metadata), and
the Phoenix / mixed-Elixir interop note — all of which apply unchanged here.

## References

- Elli middleware: <https://github.com/elli-lib/elli/blob/main/src/elli_middleware.erl>
- `elli_request`: <https://elli.hexdocs.pm/elli_request.html>
""".

-export([preprocess/2]).

-export_type([req/0, options/0]).

%% elli_request is an optional, externally-provided dependency (see the
%% "elli_request seam" section below): scope xref/dialyzer suppression to exactly
%% the two edges this module calls. Mirrored by the root rebar.config
%% `{xref_ignores,...}`.
-ignore_xref([
    {elli_request, get_header, 3},
    {elli_request, query_str, 1}
]).

% elp:ignore W0048 (the function-scoped -dialyzer attribute is the documented host-seam idiom)
-dialyzer({no_unknown, [get_header/2, query_str/1]}).

-doc """
Per-middleware options (the `Args` map). An alias of the framework-agnostic
`erli18n_http_apply:options()`: the Elli adapter adds no adapter-specific keys
(the `path` source is Cowboy-only — see the module docs). Every key is optional.
""".
-type options() :: erli18n_http_apply:options().

-doc """
Stands in for the `elli` request record (a tuple). A module-local alias so the
default `kernel` + `stdlib` build needs no `elli` dependency.
""".
-type req() :: tuple().

-doc """
`elli_middleware` pre-processor: negotiates the locale from the request, sets it
on the request process (and, by default, in `logger` metadata), and returns the
request unchanged so the chain continues.

`Req` is the Elli request record; `Args` is the per-middleware options map (see
the module docs). The `-behaviour(elli_handler)` attribute is omitted on purpose
so the module compiles warning-free (under `warnings_as_errors`) when Elli is
absent; the contract is exercised by the test suite against the real framework.
""".
-spec preprocess(req(), term()) -> req().
preprocess(Req, Args) when is_map(Args) ->
    negotiate(Req, Args);
preprocess(Req, _Args) ->
    %% Fail-soft: a non-map `Args` (middleware misconfiguration) is treated as the
    %% empty option set rather than crashing the request chain.
    negotiate(Req, #{}).

%% Runs the negotiation for the options map. `preprocess/2` guarantees `Opts` is a
%% map (the untrusted `term()` boundary is checked there); `erli18n_http_apply:run/2`
%% then reads only the documented option keys, defaulting any that are absent AND
%% validating the value-typed `available`/`default` keys (a malformed value is
%% dropped with a one-time `logger:warning/2`), so an arbitrary user map — keys or
%% values — is consumed safely and never crashes the request.
-spec negotiate(req(), map()) -> req().
negotiate(Req, Opts) ->
    Extract = fun(Source, EOpts) -> candidate_value(Source, Req, EOpts) end,
    _Locale = erli18n_http_apply:run(Extract, Opts),
    Req.

%% =========================
%% Internal — request extraction (all elli_request calls confined here)
%% =========================

-spec candidate_value(erli18n_http:source(), req(), erli18n_http_apply:raw_options()) ->
    binary() | undefined.
candidate_value(header, Req, _Opts) ->
    get_header(<<"Accept-Language">>, Req);
candidate_value(query, Req, Opts) ->
    Param = query_param(Opts),
    erli18n_http:query_value(query_str(Req), Param);
candidate_value(cookie, Req, Opts) ->
    Name = cookie_name(Opts),
    erli18n_http:cookie_value(get_header(<<"Cookie">>, Req), Name);
candidate_value(path, _Req, _Opts) ->
    %% Elli exposes the path as raw segments, not a named binding; the `path`
    %% source is Cowboy-only. Listing it for Elli contributes nothing.
    undefined.

%% Read the `query_param` / `cookie_name` options from the untrusted option map,
%% defaulting to `<<"locale">>` when absent or non-binary (fail-soft): a malformed
%% value cannot reach `erli18n_http:query_value/2` / `cookie_value/2`, which both
%% require a binary param name.
-spec query_param(erli18n_http_apply:raw_options()) -> binary().
query_param(#{query_param := P}) when is_binary(P) -> P;
query_param(_Opts) -> <<"locale">>.

-spec cookie_name(erli18n_http_apply:raw_options()) -> binary().
cookie_name(#{cookie_name := N}) when is_binary(N) -> N;
cookie_name(_Opts) -> <<"locale">>.

%% --- elli_request seam ---
%%
%% `elli_request` is supplied by the consumer's Elli application at request time;
%% it is NOT a build dependency of the published `erli18n` package (elli is in
%% `optional_applications` only, plus a test-profile dep here so the suites can
%% drive the real API). Same class and same scoped resolution as the cowboy seam
%% and `rebar3_erli18n_host`: the `-ignore_xref` / `-dialyzer` module attributes
%% near the top (mirrored in the root `rebar.config` `{xref_ignores,...}`). ELP
%% resolves `elli_request` from the test-profile dependency, so no per-call-site
%% lint suppression is needed.

-spec get_header(binary(), req()) -> binary() | undefined.
get_header(Name, Req) ->
    elli_request:get_header(Name, Req, undefined).

-spec query_str(req()) -> binary().
query_str(Req) ->
    %% The RAW query string (everything after `?`, percent-escapes intact).
    %% `elli_request:query_str/1` is total — it splits the stored `raw_path` on
    %% `?` and never decodes — so a malformed percent-escape can never raise here;
    %% the fail-soft decoding happens in `erli18n_http:query_value/2`. Using the raw
    %% query rather than `elli_request:get_arg_decoded/3`, whose URI decoder raises on
    %% a malformed escape, keeps the total core parser as the only decoder, so no
    %% try/catch is needed and the seam stays symmetric with the Cowboy adapter.
    elli_request:query_str(Req).
