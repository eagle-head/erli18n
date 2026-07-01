-module(erli18n_cowboy).

-moduledoc """
Optional Cowboy middleware that negotiates the request locale and sets it before
the handler runs — turnkey per-request localization.

`cowboy` is an **optional** dependency (declared via `optional_applications`, like
`telemetry`): erli18n does not require it and the published package still builds
and runs on `kernel` + `stdlib` alone. This module only executes when a Cowboy
application installs it in its middleware chain, so Cowboy is by definition
present whenever the code runs. `cowboy_req` is therefore an externally-provided
runtime module rather than a build dependency — the same situation as the rebar3
host API in `rebar3_erli18n_host` — so its calls are confined to a small seam
(see the "cowboy_req seam" section below) and the default build's xref, dialyzer,
and eqwalizer are kept clean by suppressions scoped to exactly those external
edges: `-ignore_xref` + the root `rebar.config` `{xref_ignores,...}`, a
function-scoped `-dialyzer({no_unknown,...})`, a `% elp:ignore W0017` per call
site, and — for the two seam calls whose upstream `cowboy_req` specs return an
`any()`-tainted union eqwalizer cannot refine (`header/3`, `binding/2`) — a
function-scoped `-eqwalizer({nowarn_function,...})`. Every other call stays fully
checked.

## Install it

Add `cowboy` to *your* application's deps (it is not pulled in by erli18n), then
put `erli18n_cowboy` in the middleware list ahead of `cowboy_handler` (and after
`cowboy_router` if you negotiate from a path binding). Pass options under the
`erli18n` key of the protocol `env`:

```erlang
%% Load your catalogs once at boot.
application:ensure_all_started(erli18n),
{ok, _} = erli18n_server:ensure_loaded(my_domain, <<"pt_BR">>, "priv/.../my_domain.po"),

Dispatch = cowboy_router:compile([{'_', [{"/[...]", my_handler, []}]}]),
{ok, _} = cowboy:start_clear(http, [{port, 8080}], #{
    env => #{
        dispatch => Dispatch,
        %% Middleware options (all optional — see "Options" below):
        erli18n => #{cookie_name => <<"locale">>, query_param => <<"lang">>}
    },
    middlewares => [erli18n_cowboy, cowboy_router, cowboy_handler]
}).
```

When you negotiate from a **path binding** (`path_binding`), `erli18n_cowboy`
must run AFTER `cowboy_router` (the router is what fills in the bindings the
adapter reads) but still before `cowboy_handler`:

```erlang
Dispatch = cowboy_router:compile([
    {'_', [{"/:locale/[...]", my_handler, []}]}
]),
{ok, _} = cowboy:start_clear(http, [{port, 8080}], #{
    env => #{
        dispatch => Dispatch,
        erli18n => #{sources => [path, query, cookie, header], path_binding => locale}
    },
    %% erli18n_cowboy AFTER cowboy_router so the `:locale` binding is populated:
    middlewares => [cowboy_router, erli18n_cowboy, cowboy_handler]
}).
```

In the handler the locale is already set for the request process, so the gettext
families need no locale argument:

```erlang
init(Req, State) ->
    Title = erli18n:gettext(my_domain, <<"Welcome">>),   %% uses the negotiated locale
    {ok, cowboy_req:reply(200, #{}, Title, Req), State}.
```

## Options (the `erli18n` key of `env`, all optional)

| Key | Default | Meaning |
| :-- | :-- | :-- |
| `sources` | `[query, cookie, header]` | precedence order, highest first |
| `query_param` | `<<"locale">>` | query-string parameter carrying a locale |
| `cookie_name` | `<<"locale">>` | cookie carrying a locale |
| `path_binding` | `undefined` | a `cowboy_router` binding to read (enables the `path` source) |
| `available` | `erli18n:loaded_locales/0` | the authoritative supported-locale set |
| `default` | `erli18n:default_locale/0` | fallback when nothing matches |
| `set_logger_metadata` | `true` | also set `logger` process metadata `#{locale => L}` |

The default precedence is **query > cookie > Accept-Language header > default**
(i18next-http-middleware's default order; Django's "explicit beats persisted
beats browser-preferred" spirit). `available`/`default` are resolved **per
request** (never captured at install time), so they reflect the catalogs loaded
at the moment of the request. Negotiation, canonicalization, and cookie parsing
are delegated to `erli18n_http` (and through it `erli18n_negotiate`); see those
modules for the matching and BCP-47 fallback semantics.

The chosen locale is also written into the Cowboy `Env` under `erli18n_locale`,
so downstream middlewares or the handler can read it explicitly rather than
relying on the process dictionary.

## The locale is per-process — and per-process state does not cross a spawn

`erli18n:setlocale/1` writes the locale to the **calling process's** dictionary,
and Cowboy runs the whole middleware chain plus the handler in **one request
process**, so the locale this middleware sets is visible to the handler with no
extra wiring. But process state is *not inherited across a spawn*. Any time a
request handler hands work to a **different** process, that process starts with
`erli18n:which_locale() = undefined` and falls back to `default_locale/0`. This
silently affects:

- a worker **pool** (`poolboy`, a `gen_server`, a `gen_statem`) you `call`/`cast`;
- a `Task`-style / `proc_lib:spawn` / `erlang:spawn` background job;
- a **Cowboy stream handler that offloads** work to another process.

Mitigations — pick per call site:

1. **Capture and re-set** in the worker. In the request process read
   `Locale = erli18n:which_locale()`, hand it across, and call
   `erli18n:setlocale(Locale)` as the first statement on the other side.
2. **Pass it explicitly.** Thread the locale as a function/message argument and
   use the `*locale*`-suffixed lookups, e.g.
   `erli18n:gettext(Domain, Msgid, Locale)`, instead of relying on ambient state.
3. **Propagate via logger metadata.** With `set_logger_metadata` on, the locale
   is in this process's `logger` metadata; carry that same map into the worker
   (logger metadata is itself per-process and not inherited).

## Phoenix / mixed Elixir stacks (no Elixir dependency)

erli18n takes no Elixir or Phoenix dependency. In a mixed stack the bridge is the
shared per-process locale: call `erli18n:setlocale/1` from a `Plug` (an Erlang
module is callable from Elixir as `:erli18n.setlocale(locale)`) in the same
request process that runs your erli18n lookups — typically right where you would
call `Gettext.put_locale/1`. If you also use Elixir `Gettext`, set both from that
one plug so the two libraries agree; erli18n's canonical locale form (`"pt_BR"`,
underscore) already matches Gettext's. Nothing here links the two libraries at
build time.

## References

- Cowboy middlewares: <https://ninenines.eu/docs/en/cowboy/2.13/guide/middlewares/>
- `cowboy_req`: <https://ninenines.eu/docs/en/cowboy/2.13/manual/cowboy_req/>
- `logger` process metadata: <https://www.erlang.org/doc/apps/kernel/logger.html>
""".

-export([execute/2]).

-export_type([options/0, req/0]).

%% cowboy_req is an optional, externally-provided dependency (see the "cowboy_req
%% seam" section below): scope xref/dialyzer suppression to exactly the three
%% edges this module calls, leaving every other call fully checked. Mirrored by
%% the root rebar.config `{xref_ignores,...}`.
-ignore_xref([
    {cowboy_req, header, 3},
    {cowboy_req, qs, 1},
    {cowboy_req, binding, 3}
]).

% elp:ignore W0048 (the function-scoped -dialyzer attribute is the documented host-seam idiom)
-dialyzer({no_unknown, [header/3, qs/1, binding/2]}).

%% eqwalizer narrows the two seam calls whose UPSTREAM `cowboy_req` specs return
%% an `any()`-tainted union it cannot refine back to this module's declared spec:
%% `cowboy_req:header/3 :: binary() | Default when Default::any()` (so the result
%% is `binary() | term()`) and `cowboy_req:binding/3 :: any() | Default` (so the
%% result is `term()`). For exactly those two functions the documented
%% `nowarn_function` seam idiom applies. The third seam call, `qs/1`, needs NO
%% suppression: `cowboy_req:qs/1 :: binary()` narrows cleanly. The Elli adapter
%% carries ZERO such attrs because `elli_request`'s corresponding specs are
%% `any()`-free and eqwalizer refines them — the asymmetry is upstream, not ours,
%% and adding a redundant suppression to Elli would violate the minimal-seam rule.
-eqwalizer({nowarn_function, header/3}).
-eqwalizer({nowarn_function, binding/2}).

-doc """
Middleware options, read from the `erli18n` key of the Cowboy protocol `env`.

The `path_binding`-extended form of `t:erli18n_http_apply:options/0` (the shared
framework-agnostic option set): every shared key plus the Cowboy-only
`path_binding` that enables the `path` source. Every key is optional; see the
module docs for defaults and semantics.
""".
-type options() :: #{
    sources => [erli18n_http:source()],
    query_param => binary(),
    cookie_name => binary(),
    path_binding => atom(),
    available => [erli18n_negotiate:locale()],
    default => erli18n_negotiate:locale(),
    set_logger_metadata => boolean()
}.

-doc """
Stands in for `cowboy_req:req/0` (a map). A module-local alias so the default
`kernel` + `stdlib` build needs no `cowboy` dependency.
""".
-type req() :: map().

-doc """
The `cowboy_middleware` callback. Negotiates the locale from the request, sets it
on the request process (and, by default, in `logger` metadata), records it in
`Env` under `erli18n_locale`, and continues the chain with `{ok, Req, Env}`.

`Req` is the Cowboy request map and `Env` the middleware environment map; this
function never replies or stops the chain, so it composes with any handler. The
`-behaviour(cowboy_middleware)` attribute is intentionally omitted so the module
compiles warning-free (under `warnings_as_errors`) when Cowboy is absent from the
build; the callback contract is exercised by the test suite against the real
framework instead.
""".
-spec execute(req(), map()) -> {ok, req(), map()}.
execute(Req, Env) ->
    Opts =
        case Env of
            #{erli18n := O} when is_map(O) -> O;
            _ -> #{}
        end,
    Extract = fun(Source, EOpts) -> candidate_value(Source, Req, EOpts) end,
    Locale = erli18n_http_apply:run(Extract, Opts),
    {ok, Req, Env#{erli18n_locale => Locale}}.

%% =========================
%% Internal — request extraction (all cowboy_req calls confined here)
%% =========================

-spec candidate_value(erli18n_http:source(), req(), erli18n_http_apply:raw_options()) ->
    binary() | undefined.
candidate_value(header, Req, _Opts) ->
    header(<<"accept-language">>, Req);
candidate_value(query, Req, Opts) ->
    Param = query_param(Opts),
    erli18n_http:query_value(qs(Req), Param);
candidate_value(cookie, Req, Opts) ->
    Name = cookie_name(Opts),
    erli18n_http:cookie_value(header(<<"cookie">>, Req, undefined), Name);
candidate_value(path, Req, Opts) ->
    case maps:get(path_binding, Opts, undefined) of
        Key when is_atom(Key), Key =/= undefined -> binding(Key, Req);
        %% `undefined` (the no-path-source default) and any non-atom misconfigured
        %% `path_binding` value both mean "no path source": skip it fail-soft
        %% rather than crashing the request with a case_clause.
        _NoneOrMalformed -> undefined
    end.

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

%% --- cowboy_req seam ---
%%
%% `cowboy_req` is supplied by the consumer's Cowboy application at request time;
%% it is NOT a build dependency of the published `erli18n` package (cowboy is in
%% `optional_applications` only, and a test-profile dep here purely so the suites
%% can drive the real API). The default-profile gate therefore analyzes these
%% calls with cowboy absent. This is the SAME class as the rebar3 host API in
%% `rebar3_erli18n_host`, and the resolution is identical and scoped to exactly
%% the three edges this module calls: the `-ignore_xref` / `-dialyzer` module
%% attributes near the top (mirrored by the root `rebar.config`
%% `{xref_ignores,...}` for the umbrella run). ELP resolves `cowboy_req` from the
%% test-profile dependency, so it needs no per-call-site lint suppressions at
%% these edges. Every other call in this module stays under the full
%% xref / dialyzer / eqwalizer checks.

-spec header(binary(), req()) -> binary() | undefined.
header(Name, Req) ->
    header(Name, Req, undefined).

-spec header(binary(), req(), Default) -> binary() | Default.
header(Name, Req, Default) ->
    cowboy_req:header(Name, Req, Default).

-spec qs(req()) -> binary().
qs(Req) ->
    %% The RAW query-string binary (everything after `?`, percent-escapes intact).
    %% `cowboy_req:qs/1` is total — it reads the already-parsed `qs` map key and
    %% never decodes — so a malformed percent-escape can never raise here; the
    %% fail-soft decoding happens in `erli18n_http:query_value/2`. This replaces
    %% `cowboy_req:parse_qs/1`, whose decoder (`cow_qs:parse_qs/1`) RAISES on a
    %% malformed escape.
    cowboy_req:qs(Req).

-spec binding(atom(), req()) -> binary() | undefined.
binding(Key, Req) ->
    cowboy_req:binding(Key, Req, undefined).
