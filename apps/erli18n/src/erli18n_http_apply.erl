-module(erli18n_http_apply).

-moduledoc """
Internal effectful runner shared by the optional web adapters.

This module ties the pure negotiation core (`erli18n_http:negotiate_locale/3`) to
the per-request side effects (`erli18n:setlocale/1` plus optional `logger`
process metadata), parameterized by a per-source candidate-extraction callback
each adapter supplies. It is the shared body that was previously duplicated across
`erli18n_cowboy:execute/2` and `erli18n_elli:preprocess/2`.

It makes **zero** framework calls — it never touches `cowboy_req` / `elli_request`.
The only external module it invokes is the extraction *fun* the caller passes, and
that fun is where the framework seam (and its scoped suppressions) lives, in the
adapter. So this module needs **no** suppressions of any kind: every call it makes
(`erli18n:loaded_locales/0`, `erli18n:default_locale/0`, `erli18n:setlocale/1`,
`erli18n_http:negotiate_locale/3`, `logger:update_process_metadata/1`) resolves to
an in-tree or `kernel`/`stdlib` module that xref, dialyzer, and eqwalizer all see.

Purity contrast: `erli18n_http` stays pure (negotiation only — no `setlocale`, no
logger, no I/O); `erli18n_http_apply` is its *effectful* sibling (it does
`setlocale` and logger) but remains framework-agnostic.

Source extraction itself is **lazy and short-circuiting**: `run/2` drives
`erli18n_http:negotiate_locale_lazy/4`, which calls the per-source `Extract`
callback only when a source is reached and stops at the first source that yields
a supported locale, so a higher-precedence winner means the later sources are
never extracted. The `available` and `default` option defaults are likewise
resolved **lazily** via thunks: `erli18n:loaded_locales/0` is forced only once a
source yields a non-empty value and `erli18n:default_locale/0` only on a total
miss, so an explicitly-supplied `available`/`default` is truly zero-cost.
""".

-export([run/2]).

-export_type([extract/0, options/0, raw_options/0]).

-doc """
Framework-agnostic per-request options for `run/2`, owned by this core module
and shared by the adapters (`erli18n_cowboy` extends it with `path_binding`;
`erli18n_elli` references it directly). Every key is optional; an omitted key
falls back to the documented default, and `available`/`default` are resolved
lazily so an explicitly-supplied value is zero-cost.

- `sources` — precedence order, highest first (default `[query, cookie, header]`).
- `query_param` — query-string parameter carrying a locale (adapter default `<<"locale">>`).
- `cookie_name` — cookie carrying a locale (adapter default `<<"locale">>`).
- `available` — the authoritative supported-locale set (default `erli18n:loaded_locales/0`).
- `default` — fallback when nothing matches (default `erli18n:default_locale/0`).
- `set_logger_metadata` — also set `logger` process metadata `#{locale => L}` (default `true`).

This is the precise set of keys the core runner itself reads; every key is
optional. An adapter that needs an extra key (e.g. cowboy's `path_binding`)
declares its own `options/0` extending this shape and reads that key in its own
extraction callback — the core never reads it, so it stays out of this type.
`run/2` reads each key with a default, so a user map that omits some (or carries
extra, adapter-specific) keys is consumed safely. Beyond omitted keys,
*malformed option values* are consumed safely too: `run/2` validates the
`available` and `default` values at the request boundary (see
`validate_options/1`); a non-binary `default` or a non-list / bad-element
`available` is dropped — so the documented default (`erli18n:default_locale/0` /
`erli18n:loaded_locales/0`) applies — and the misconfiguration is reported once
via `logger:warning/2`. So operator misconfiguration is fail-soft-and-observable,
never request-fatal: no user-supplied option value can crash the request process.
""".
-type options() :: #{
    sources => [erli18n_http:source()],
    query_param => binary(),
    cookie_name => binary(),
    available => [erli18n_negotiate:locale()],
    default => erli18n_negotiate:locale(),
    set_logger_metadata => boolean()
}.

-doc """
The untrusted per-request option map exactly as it arrives from the operator's
configuration (the `erli18n` key of Cowboy's `env`, or an Elli middleware `Args`
map). Unlike `options/0` — which is the *well-typed* shape the runner relies on
internally — every value here may be arbitrary: an operator may have written a
non-binary `default` or a non-list `available`. `run/2` accepts this wider type
and `validate_options/1` narrows it to `options/0` at the request boundary,
dropping any malformed value (fail-soft-and-observable). Modelled as an
arbitrary map (any key, any value) — the unconstrained shape an operator map
actually has at the boundary — so the malformed-value clauses of the validators
are reachable and statically checked, and a generic `map()` from the adapter
(e.g. Cowboy's `env` value) assigns to it without a narrowing cast.
""".
-type raw_options() :: #{term() => term()}.

-doc """
A per-source extraction callback supplied by an adapter: given a source tag and
the untrusted per-request option map (`raw_options/0`, exactly as the operator
configured it), it returns the raw candidate value (or `undefined`). This fun is
the ONLY thing that touches the framework request, so the seam (and its scoped
suppressions) stays in the adapter, never here. The callback reads only the
non-value-typed keys it needs (`query_param`, `cookie_name`, cowboy's
`path_binding`) with its own per-read guards, so it tolerates a malformed value
fail-soft. `run/2` adapts it to the arity-1 `erli18n_http:extract_fun/0` consumed
by the lazy engine by closing over the raw `Opts`.
""".
-type extract() :: fun((erli18n_http:source(), raw_options()) -> binary() | undefined).

-doc """
Resolves the request locale and applies it as side effects.

Given an adapter's per-source `Extract` callback and its `Opts`, this delegates
to `erli18n_http:negotiate_locale_lazy/4`, which extracts each source on demand
in `sources` order and stops at the first source that yields a supported locale,
then sets the locale on the calling process via `erli18n:setlocale/1`, optionally
updates `logger` process metadata, and returns the chosen locale.

The `sources`, `available`, and `default` defaults are resolved lazily from
`Opts`: `available` (default `erli18n:loaded_locales/0`) is forced only when a
source actually yields a non-empty value, `default` (default
`erli18n:default_locale/0`) only on a total miss, and an explicitly-supplied
`available`/`default` is never recomputed (truly zero-cost). `set_logger_metadata`
defaults to `true`.

`Opts` is first passed through `validate_options/1`, which drops any malformed
`available`/`default` value (falling back to the documented default and emitting
one `logger:warning/2`), so an operator misconfiguration is fail-soft-and-observable
rather than request-fatal.
""".
-spec run(extract(), raw_options()) -> erli18n_negotiate:locale().
run(Extract, Opts0) when is_function(Extract, 2), is_map(Opts0) ->
    %% Validate only the two value-typed keys the runner forwards to its thunks
    %% (`available`/`default`); a malformed value is dropped here (fail-soft-and-
    %% observable) so the documented default applies. The other keys (`sources`,
    %% `set_logger_metadata`, and the adapter-read `query_param`/`cookie_name`/
    %% `path_binding`) are consumed from the original `Opts0` with per-read guards
    %% downstream, so they never need narrowing here.
    Validated = validate_options(Opts0),
    Sources = sources(Opts0),
    AvailableThunk = available_thunk(Validated),
    DefaultThunk = default_thunk(Validated),
    Extract1 = fun(Source) -> Extract(Source, Opts0) end,
    {Locale, _Won} = erli18n_http:negotiate_locale_lazy(
        Sources, Extract1, AvailableThunk, DefaultThunk
    ),
    ok = erli18n:setlocale(Locale),
    ok = set_logger_metadata(Locale, Opts0),
    Locale.

%% `sources` precedence list from the raw options, defaulting when absent or not
%% a list. A non-list `sources` is treated as absent (fail-soft). A supplied list
%% is filtered to the known `source()` atoms in order, so a stray element (which
%% would otherwise reach the adapter's `candidate_value/3` with no matching clause
%% and crash the request) is dropped rather than request-fatal.
-spec sources(raw_options()) -> [erli18n_http:source()].
sources(#{sources := S}) when is_list(S) ->
    lists:foldr(fun keep_source/2, [], S);
sources(_Opts) ->
    [query, cookie, header].

%% Prepend `Src` to `Acc` only if it is one of the known `source()` atoms,
%% matching each atom explicitly so the result narrows to `[source()]` for the
%% static checkers. Any other element is dropped (fail-soft), so it can never
%% reach an adapter's extraction callback as an unhandled source.
-spec keep_source(term(), [erli18n_http:source()]) -> [erli18n_http:source()].
keep_source(query, Acc) -> [query | Acc];
keep_source(cookie, Acc) -> [cookie | Acc];
keep_source(header, Acc) -> [header | Acc];
keep_source(path, Acc) -> [path | Acc];
keep_source(_Other, Acc) -> Acc.

-doc """
Normalizes per-request option *values* at the `run/2` boundary so that a
malformed value can never crash the request process.

It inspects only the two value-typed keys the runner forwards to its thunks:

- `default` must be a `binary()` locale tag. A non-binary value is dropped, so
  `default_thunk/1` falls back to `erli18n:default_locale/0`.
- `available` must be a list whose every element is a `binary()` locale tag. A
  non-list value, or a list that empties once non-binary elements are filtered
  out, is dropped, so `available_thunk/1` falls back to
  `erli18n:loaded_locales/0`. A list with only binary elements is kept as-is.

Each dropped value emits exactly one `logger:warning/2`, so the misconfiguration
is observable without ever being request-fatal (fail-soft-and-observable). The
returned map is a fresh well-typed `options/0` carrying only the validated
`available`/`default` keys, so `available_thunk/1` / `default_thunk/1` keep their
two clauses and never see a malformed value. The other keys (`sources`,
`query_param`, `cookie_name`, `set_logger_metadata`, and any adapter-specific
keys such as cowboy's `path_binding`) are NOT carried here: `run/2` reads
`sources` via its own `sources/1` (which filters to known sources) and forwards
the original raw `Opts` to the adapter's extraction callback, which guards each
read itself.
""".
-spec validate_options(raw_options()) -> options().
validate_options(Opts) ->
    validate_available(Opts, validate_default(Opts, #{})).

%% `default` must be a binary locale tag. The validated value (if any) is written
%% into the typed accumulator `Acc`; a non-binary value is dropped (so the
%% `erli18n:default_locale/0` default applies) and reported once. Reads the
%% untrusted `raw_options()`, writes the well-typed `options()`.
-spec validate_default(raw_options(), options()) -> options().
validate_default(#{default := D}, Acc) when is_binary(D) ->
    Acc#{default => D};
validate_default(#{default := D}, Acc) ->
    logger:warning(
        "erli18n: ignoring malformed `default` per-request option ~tp "
        "(expected a binary locale tag); falling back to erli18n:default_locale/0",
        [D]
    ),
    Acc;
validate_default(_Opts, Acc) ->
    Acc.

%% `available` must be a list of binary locale tags. The validated list (if any)
%% is written into the typed accumulator `Acc`; a non-list value, or a list that
%% filters down to empty, is dropped (so the `erli18n:loaded_locales/0` default
%% applies) and reported once. Reads the untrusted `raw_options()`, writes the
%% well-typed `options()`.
-spec validate_available(raw_options(), options()) -> options().
validate_available(#{available := A}, Acc) when is_list(A) ->
    case [L || L <- A, is_binary(L)] of
        [] ->
            warn_available(A),
            Acc;
        Filtered ->
            Acc#{available => Filtered}
    end;
validate_available(#{available := A}, Acc) ->
    warn_available(A),
    Acc;
validate_available(_Opts, Acc) ->
    Acc.

-spec warn_available(term()) -> ok.
warn_available(A) ->
    logger:warning(
        "erli18n: ignoring malformed `available` per-request option ~tp "
        "(expected a list of binary locale tags); falling back to "
        "erli18n:loaded_locales/0",
        [A]
    ).

%% Available set as a thunk: an explicitly-supplied `available` is returned
%% as-is (zero-cost); otherwise `erli18n:loaded_locales/0` is deferred to the
%% lazy engine, which forces it only when a source actually yields a value.
-spec available_thunk(options()) -> erli18n_http:thunk([erli18n_negotiate:locale()]).
available_thunk(#{available := A}) ->
    fun() -> A end;
available_thunk(_Opts) ->
    fun erli18n:loaded_locales/0.

%% Default as a thunk: an explicit `default` is returned as-is; otherwise
%% `erli18n:default_locale/0` is deferred and forced only on a total miss.
-spec default_thunk(options()) -> erli18n_http:thunk(erli18n_negotiate:locale()).
default_thunk(#{default := D}) ->
    fun() -> D end;
default_thunk(_Opts) ->
    fun erli18n:default_locale/0.

-spec set_logger_metadata(erli18n_negotiate:locale(), raw_options()) -> ok.
set_logger_metadata(Locale, Opts) ->
    case Opts of
        #{set_logger_metadata := false} -> ok;
        _ -> logger:update_process_metadata(#{locale => Locale})
    end.
