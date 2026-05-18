-module(erli18n_telemetry).

%% ============================================================================
%%  erli18n_telemetry — thin wrapper over the `:telemetry` library.
%%
%%  Responsibilities:
%%
%%    * Encapsulate the runtime presence/absence of the `telemetry` module
%%      so call sites never have to branch. If `telemetry` is not loaded,
%%      `emit/3` and `span/3` are no-ops (zero crash, zero noise).
%%
%%    * Centralize all `erli18n` event names (`[erli18n, catalog, load]`,
%%      etc.) so a future rename or audit is a one-file change. The event
%%      names are the **public contract** of the lib's observability
%%      surface — see observability.md §3 (naming convention) and §4
%%      (catalogue of events).
%%
%%    * Provide opt-in/opt-out gating for high-frequency events
%%      (lookup miss / fuzzy_skip) via the `emit_lookup_telemetry`
%%      application env flag. Always-on events bypass the gate. See
%%      observability.md §6 (overhead policy).
%%
%%    * Provide a rate-limited memory-warning check used by the loader
%%      to emit `[erli18n, catalog, memory_warning]` at most once per
%%      configured window (RISK-011 mitigation 2: "uma vez por evento de
%%      cruzamento, não a cada tick"). See observability.md §4 (memory
%%      warning schema).
%%
%%  References:
%%
%%    * Library:   https://github.com/beam-telemetry/telemetry
%%    * Hexdocs:   https://hexdocs.pm/telemetry/
%%    * span/3:    https://hexdocs.pm/telemetry/telemetry.html#span-3
%%    * Phoenix:   https://hexdocs.pm/phoenix/Phoenix.Logger.html — naming
%%                 convention `[<lib>, <operation>, <phase>]` source.
%%
%%  Performance note (`code:ensure_loaded/1` cache):
%%
%%    The first call walks the code path to confirm whether `telemetry`
%%    is loadable; subsequent calls hit a `persistent_term` entry
%%    (~sub-microsecond, lock-free, copy-free across processes — see
%%    https://www.erlang.org/doc/man/persistent_term.html). The cache is
%%    invalidated only when the result is `false` (in case the consumer
%%    starts telemetry mid-flight); positive results are sticky for the
%%    VM's lifetime.
%% ============================================================================

%% Emission API.
-export([emit/3, span/3]).

%% Convenience: pre-typed event names.
-export([
    event_catalog_load/0,
    event_catalog_reload/0,
    event_catalog_unload/0,
    event_lookup_miss/0,
    event_lookup_fuzzy_skip/0,
    event_plural_divergence/0,
    event_catalog_memory_warning/0
]).

%% Configuration / gating.
-export([
    lookup_telemetry_enabled/0,
    memory_warning_threshold/0,
    memory_warning_rate_limit_seconds/0,
    memory_warning_check/1
]).

%% Test-only — exposed so the SUITE can reset the persistent_term cache
%% between cases. Not in the documented API surface.
-export([reset_caches/0]).

-export_type([
    event_name/0,
    measurements/0,
    metadata/0,
    span_fun/0,
    span_result/0
]).

%% =========================
%% Types
%% =========================

%% Event name shapes per observability.md §5.
-type event_name() ::
    [
        erli18n
        | catalog
        | lookup
        | plural
        | load
        | reload
        | unload
        | miss
        | fuzzy_skip
        | divergence_warning
        | memory_warning
        | atom()
    ].

-type measurements() :: map().
-type metadata() :: map().

%% Span body must return `{Result, StopMetadata}` per
%% https://hexdocs.pm/telemetry/telemetry.html#span-3.
-type span_fun() :: fun(() -> {term(), metadata()}).
-type span_result() :: term().

%% =========================
%% Cache keys (persistent_term)
%% =========================

%% Sticky-true cache for the loaded check.
-define(LOADED_KEY, {?MODULE, telemetry_loaded}).
%% Rate-limit anchor for memory_warning emission.
-define(MEM_WARN_LAST_KEY, {?MODULE, memory_warning_last_emit}).

%% =========================
%% Event names
%% =========================

-spec event_catalog_load() -> event_name().
event_catalog_load() ->
    [erli18n, catalog, load].

-spec event_catalog_reload() -> event_name().
event_catalog_reload() ->
    [erli18n, catalog, reload].

-spec event_catalog_unload() -> event_name().
event_catalog_unload() ->
    [erli18n, catalog, unload].

-spec event_lookup_miss() -> event_name().
event_lookup_miss() ->
    [erli18n, lookup, miss].

-spec event_lookup_fuzzy_skip() -> event_name().
event_lookup_fuzzy_skip() ->
    [erli18n, lookup, fuzzy_skip].

-spec event_plural_divergence() -> event_name().
event_plural_divergence() ->
    [erli18n, plural, divergence_warning].

-spec event_catalog_memory_warning() -> event_name().
event_catalog_memory_warning() ->
    [erli18n, catalog, memory_warning].

%% =========================
%% Emission
%% =========================

%% Pointwise emit. Safe no-op when `telemetry` is unavailable. The naked
%% `erlang:apply/3` indirection is intentional: dialyzer treats the call
%% as an unknown remote function when `telemetry` is genuinely absent
%% from the PLT, which matches the runtime story exactly.
-spec emit(event_name(), measurements(), metadata()) -> ok.
emit(EventName, Measurements, Metadata) when
    is_list(EventName), is_map(Measurements), is_map(Metadata)
->
    case telemetry_loaded() of
        true ->
            _ = erlang:apply(
                telemetry,
                execute,
                [EventName, Measurements, Metadata]
            ),
            ok;
        false ->
            ok
    end.

%% Span emit. Matches the `:telemetry.span/3` contract:
%%   * Emits `EventPrefix ++ [start]` with measurements
%%     `#{monotonic_time, system_time}` and StartMetadata.
%%   * Runs Fun, which must return `{Result, StopMetadata}`.
%%   * Emits `EventPrefix ++ [stop]` with measurements
%%     `#{monotonic_time, duration}` and (StartMetadata merged with
%%     StopMetadata).
%%   * On exception, emits `EventPrefix ++ [exception]` instead of stop,
%%     with `#{kind, reason, stacktrace}` merged into StartMetadata.
%%
%% Reference: https://hexdocs.pm/telemetry/telemetry.html#span-3.
%%
%% Always-on path (telemetry loaded): we delegate to `:telemetry.span/3`
%% to avoid duplicating the implementation, which keeps measurement
%% semantics byte-equal to what `:telemetry` users expect.
%%
%% No-op path (telemetry absent): we still run Fun (otherwise the lib
%% would behave differently with vs without telemetry — unacceptable).
%% We discard StopMetadata because there's nothing to emit it to.
-spec span(event_name(), metadata(), span_fun()) -> span_result().
span(EventPrefix, StartMetadata, Fun) when
    is_list(EventPrefix), is_map(StartMetadata), is_function(Fun, 0)
->
    case telemetry_loaded() of
        true ->
            erlang:apply(
                telemetry,
                span,
                [EventPrefix, StartMetadata, Fun]
            );
        false ->
            {Result, _StopMetadata} = Fun(),
            Result
    end.

%% =========================
%% Configuration / gating
%% =========================

%% Opt-in flag for the high-frequency lookup events.
%%
%% `application:get_env/3` lookup is an ETS-direct read in the OTP
%% application controller (~100 ns), comparable to telemetry's own no-op
%% overhead. See observability.md §6 ("a flag elimina o overhead de
%% handler attached, não o overhead de lookup da flag — esse é o limite
%% teórico do design").
-spec lookup_telemetry_enabled() -> boolean().
lookup_telemetry_enabled() ->
    case application:get_env(erli18n, emit_lookup_telemetry, false) of
        true -> true;
        false -> false;
        Other -> error({invalid_config, {erli18n, emit_lookup_telemetry, Other, expected, boolean}})
    end.

%% Bytes threshold for memory_warning. Default 100 MiB matches the
%% sys.config example in observability.md §4.
-spec memory_warning_threshold() -> non_neg_integer().
memory_warning_threshold() ->
    case application:get_env(erli18n, memory_warning_threshold, 104857600) of
        N when is_integer(N), N >= 0 -> N;
        Other ->
            error(
                {invalid_config,
                    {erli18n, memory_warning_threshold, Other, expected, non_neg_integer}}
            )
    end.

%% Window (seconds) between successive memory_warning emits.
-spec memory_warning_rate_limit_seconds() -> non_neg_integer().
memory_warning_rate_limit_seconds() ->
    case application:get_env(erli18n, memory_warning_rate_limit_seconds, 60) of
        N when is_integer(N), N >= 0 -> N;
        Other ->
            error(
                {invalid_config,
                    {erli18n, memory_warning_rate_limit_seconds, Other, expected, non_neg_integer}}
            )
    end.

%% Inspect the given memory_info and emit a single memory_warning event
%% if the threshold is crossed and the rate-limit window has elapsed.
%%
%% Returns:
%%   * `not_warned`     — threshold not crossed.
%%   * `rate_limited`   — threshold crossed but a warning was already
%%     emitted within the rate-limit window.
%%   * `warned`         — a `[erli18n, catalog, memory_warning]` event
%%     was just emitted.
%%
%% Rate-limit storage uses `persistent_term` so the check is lock-free
%% from any process. The cost of storing a single integer is one VM
%% global GC at update time — acceptable because the update only happens
%% on actual emit (rare, by design).
-spec memory_warning_check(map()) -> not_warned | rate_limited | warned.
memory_warning_check(MemInfo) when is_map(MemInfo) ->
    Threshold = memory_warning_threshold(),
    Bytes = maps:get(ets_bytes, MemInfo, 0),
    case Bytes > Threshold of
        false ->
            not_warned;
        true ->
            Now = erlang:system_time(second),
            Window = memory_warning_rate_limit_seconds(),
            %% `persistent_term:get/2` returns `term()`. The value under
            %% `?MEM_WARN_LAST_KEY` is only ever written by this module
            %% with `persistent_term:put(?MEM_WARN_LAST_KEY, Now)` where
            %% `Now = erlang:system_time(second) :: integer()`, and the
            %% default we pass is the integer `0`. Narrow at the boundary
            %% so arithmetic is type-checked; a non-integer would mean
            %% someone is reusing our private key — contract violation,
            %% crash explicitly.
            Last =
                case persistent_term:get(?MEM_WARN_LAST_KEY, 0) of
                    L when is_integer(L) -> L;
                    Other ->
                        error(
                            {invalid_persistent_term,
                                {?MEM_WARN_LAST_KEY, Other, expected, integer}}
                        )
                end,
            case (Now - Last) < Window of
                true ->
                    rate_limited;
                false ->
                    persistent_term:put(?MEM_WARN_LAST_KEY, Now),
                    Sample = collect_domain_locales_sample(),
                    emit(
                        event_catalog_memory_warning(),
                        #{
                            ets_bytes => Bytes,
                            threshold_bytes => Threshold,
                            num_catalogs => maps:get(num_catalogs, MemInfo, 0),
                            num_keys => maps:get(num_keys, MemInfo, 0)
                        },
                        %% observability.md §4.2 memory_warning metadata
                        %% calls for `domain_locales_sample`: up to 10
                        %% `{Domain, Locale}` tuples to bound payload
                        %% size in multi-tenant deployments.
                        %% `erli18n_server:loaded_catalogs/0` is a
                        %% caller-process ETS scan — safe to call from
                        %% any process, including the server itself,
                        %% because it never re-enters the gen_server.
                        #{domain_locales_sample => Sample}
                    ),
                    warned
            end
    end.

%% Sample up to 10 (Domain, Locale) tuples. Order is whatever ETS scan
%% returns; we don't sort because the spec doesn't require determinism
%% and sorting would add overhead at no benefit for an observability
%% sample.
collect_domain_locales_sample() ->
    case erlang:function_exported(erli18n_server, loaded_catalogs, 0) of
        true ->
            Catalogs = erli18n_server:loaded_catalogs(),
            Pairs = [{D, L} || {D, L, _N} <- Catalogs],
            lists:sublist(Pairs, 10);
        false ->
            []
    end.

%% =========================
%% Test-only helpers
%% =========================

%% Clear both caches so a test can simulate a fresh VM. Not part of the
%% documented API.
-spec reset_caches() -> ok.
reset_caches() ->
    _ = persistent_term:erase(?LOADED_KEY),
    _ = persistent_term:erase(?MEM_WARN_LAST_KEY),
    ok.

%% =========================
%% Internal
%% =========================

%% Cached "is telemetry loaded?" check.
%%
%% First call: `code:ensure_loaded/1` walks the code server. On success
%% we cache `true` permanently — telemetry doesn't unload at runtime.
%% On failure (module not found, not loadable) we return `false`
%% WITHOUT caching, so that if the consumer brings telemetry up later
%% (`application:start(telemetry)`) the next call observes it.
%%
%% Trade-off documented in observability.md §11: positive-only caching
%% costs at most one `code:ensure_loaded/1` per emit while telemetry is
%% absent (microseconds), and zero per emit once present. Negative
%% caching would be cheaper in the absent case but would prevent
%% on-the-fly enablement, contradicting the "no-op safe, never crashes"
%% contract.
telemetry_loaded() ->
    case persistent_term:get(?LOADED_KEY, undefined) of
        true ->
            true;
        undefined ->
            case code:ensure_loaded(telemetry) of
                {module, telemetry} ->
                    persistent_term:put(?LOADED_KEY, true),
                    true;
                _ ->
                    false
            end
    end.
