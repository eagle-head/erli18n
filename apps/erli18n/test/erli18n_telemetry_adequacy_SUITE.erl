-module(erli18n_telemetry_adequacy_SUITE).

%%% =====================================================================
%%% erli18n_telemetry_adequacy_SUITE
%%%
%%% Purpose: adequacy-hardening suite for `erli18n_telemetry`. It pins the
%%% observable return/emission contracts that the existing
%%% `erli18n_telemetry_SUITE` reaches but never asserts, so that the
%%% surviving mutants named in the test-adequacy audit are killed:
%%%
%%%   * span/3 exception contract — a raising Fun emits exactly one
%%%     `[...,exception]` event (kind/reason/stacktrace), zero `[...,stop]`,
%%%     and the exception re-propagates.
%%%   * memory_warning_check/1 return atoms asserted DIRECTLY
%%%     (not_warned / rate_limited / warned), including:
%%%       - strict `>` threshold boundary (Bytes == Threshold -> not_warned;
%%%         kills the `> -> >=` mutant),
%%%       - absent `ets_bytes` key -> defaults to 0 -> not_warned,
%%%       - below-threshold -> not_warned,
%%%       - second crossing within the window -> rate_limited,
%%%       - window == 0 -> every crossing re-emits (two `warned`, two events;
%%%         kills the `< -> =<` window-boundary mutant),
%%%       - `domain_locales_sample` clamped to exactly 10 with > 10 catalogs.
%%%   * Sticky-positive / no-negative-cache detection — a mid-flight
%%%     `application:start(telemetry)` is picked up on the next emit (a `false`
%%%     detection is NOT negatively cached).
%%%   * function_clause / badmatch failure shapes of emit/3 and span/3.
%%%
%%% This suite was GENERATED from the test-adequacy audit (findings F1..F24).
%%%
%%% RED/GREEN expectation: GREEN. Every testcase is expected to PASS against
%%% the current production source. telemetry is an optional dependency present
%%% in the test profile and is booted in init_per_suite, mirroring
%%% erli18n_telemetry_SUITE.
%%% =====================================================================

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Handler callback (must be exported because telemetry refers to it by
%% `{Module, Function}` tuple).
-export([handle_event/4]).

-export([
    span_exception_emits_exception_and_reraises/1,
    memory_warning_threshold_boundary_not_warned/1,
    memory_warning_below_threshold_not_warned/1,
    memory_warning_absent_ets_bytes_not_warned/1,
    memory_warning_second_crossing_rate_limited/1,
    memory_warning_window_zero_reemits/1,
    domain_locales_sample_capped_at_ten/1,
    mid_flight_telemetry_enable_picked_up/1,
    emit_and_span_function_clause_on_mistyped_args/1,
    span_noop_badmatch_on_non_tuple_return/1
]).

%% These two cases deliberately feed ill-typed args (a non-event-name term and a
%% non-tuple span Fun return) to prove the function_clause / badmatch behavior;
%% eqwalizer (correctly) cannot type that ill-formed input, so the documented
%% nowarn idiom applies to exactly these two functions.
-eqwalizer({nowarn_function, emit_and_span_function_clause_on_mistyped_args/1}).
-eqwalizer({nowarn_function, span_noop_badmatch_on_non_tuple_return/1}).

all() ->
    [
        span_exception_emits_exception_and_reraises,
        memory_warning_threshold_boundary_not_warned,
        memory_warning_below_threshold_not_warned,
        memory_warning_absent_ets_bytes_not_warned,
        memory_warning_second_crossing_rate_limited,
        memory_warning_window_zero_reemits,
        domain_locales_sample_capped_at_ten,
        mid_flight_telemetry_enable_picked_up,
        emit_and_span_function_clause_on_mistyped_args,
        span_noop_badmatch_on_non_tuple_return
    ].

%% =========================
%% Setup / teardown
%% =========================

init_per_suite(Config) ->
    %% `telemetry` is declared as optional_applications in erli18n.app.src so
    %% it is NOT auto-started by ensure_all_started/1. Boot it explicitly to
    %% exercise the attach/emit path, mirroring erli18n_telemetry_SUITE.
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _Apps} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    application:unset_env(erli18n, emit_lookup_telemetry),
    application:unset_env(erli18n, memory_warning_threshold),
    application:unset_env(erli18n, memory_warning_rate_limit_seconds),
    ok = application:stop(erli18n),
    _ = application:stop(telemetry),
    ok.

init_per_testcase(TC, Config) ->
    %% Clean slate per test: unload any catalog that lingers from a previous
    %% case, reset env flags and the memory-warning rate-limit cache, and
    %% create a fresh capture ETS.
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    application:set_env(erli18n, emit_lookup_telemetry, false),
    application:set_env(erli18n, memory_warning_threshold, 104857600),
    application:set_env(erli18n, memory_warning_rate_limit_seconds, 60),
    erli18n_telemetry:reset_caches(),
    Tab = ets:new(erli18n_telemetry_adequacy_capture, [public, ordered_set]),
    HandlerId = handler_id(TC),
    [{capture_tab, Tab}, {handler_id, HandlerId} | Config].

end_per_testcase(_TC, Config) ->
    HandlerId = ?config(handler_id, Config),
    try
        telemetry:detach(HandlerId)
    catch
        _:_ -> ok
    end,
    Tab = ?config(capture_tab, Config),
    try
        ets:delete(Tab)
    catch
        _:_ -> ok
    end,
    ok.

%% =========================
%% Helpers
%% =========================

handler_id(TC) ->
    list_to_binary(
        "erli18n_adequacy_handler_" ++
            atom_to_list(TC) ++ "_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ).

%% Attach to a list of event names. Captures every emit into the suite's ETS
%% table as `{Seq, EventName, Measurements, Metadata}`.
attach(Config, EventNames) ->
    HandlerId = ?config(handler_id, Config),
    Tab = ?config(capture_tab, Config),
    ok = telemetry:attach_many(
        HandlerId,
        EventNames,
        fun ?MODULE:handle_event/4,
        #{tab => Tab}
    ),
    ok.

handle_event(EventName, Measurements, Metadata, #{tab := Tab}) ->
    Seq = erlang:unique_integer([monotonic, positive]),
    ets:insert(Tab, {Seq, EventName, Measurements, Metadata}),
    ok.

captured(Config) ->
    Tab = ?config(capture_tab, Config),
    [{N, M, Meta} || {_S, N, M, Meta} <- ets:tab2list(Tab)].

captured_for(Config, EventName) ->
    [{M, Meta} || {N, M, Meta} <- captured(Config), N =:= EventName].

%% Write a minimal, valid `.po` into the testcase priv_dir and return the path.
%% Adjacent string literals concatenate; the `\\n` sequences are literal
%% backslash-n inside the quoted `.po` header lines.
write_minimal_po(Config) ->
    Dir = ?config(priv_dir, Config),
    Path = filename:join(Dir, "adequacy_minimal.po"),
    PoData =
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\"Language: en\\n\"\n"
        "\n"
        "msgid \"hello\"\n"
        "msgstr \"Hello\"\n",
    ok = file:write_file(Path, PoData),
    Path.

%% Run Fun with telemetry deliberately unloaded from the VM, then restore.
%% Mirrors the production no-op story (cache reset + module purge + path
%% removal + ensure_loaded observing `{error, nofile}`).
with_telemetry_unloaded(Fun) ->
    ok = erli18n_telemetry:reset_caches(),
    TelFile =
        case code:which(telemetry) of
            Path when is_list(Path) -> Path;
            Other -> error({telemetry_module_path_unexpected, Other})
        end,
    TelDir = filename:dirname(TelFile),
    true = code:del_path(TelDir),
    _ = application:stop(telemetry),
    _ = code:delete(telemetry),
    _ = code:purge(telemetry),
    ?assertEqual({error, nofile}, code:ensure_loaded(telemetry)),
    try
        Fun()
    after
        true = code:add_patha(TelDir),
        {module, telemetry} = code:ensure_loaded(telemetry),
        ok = erli18n_telemetry:reset_caches(),
        {ok, _} = application:ensure_all_started(telemetry)
    end.

%% =========================
%% F1, F12 — span/3 exception contract
%% =========================

%% A raising Fun on the telemetry-LOADED path must route through
%% telemetry:span/3 and emit exactly one `[...,exception]` event carrying
%% kind/reason/stacktrace, emit ZERO `[...,stop]`, and re-propagate the
%% original error. Kills any mutant that swaps exception->stop or swallows
%% the raise.
span_exception_emits_exception_and_reraises(Config) ->
    ok = attach(Config, [
        [erli18n, catalog, load, start],
        [erli18n, catalog, load, stop],
        [erli18n, catalog, load, exception]
    ]),
    %% The exception re-propagates to the caller (class error, reason boom).
    ?assertError(
        boom,
        erli18n_telemetry:span(
            [erli18n, catalog, load],
            #{domain => default},
            fun() -> error(boom) end
        )
    ),
    Excs = captured_for(Config, [erli18n, catalog, load, exception]),
    Stops = captured_for(Config, [erli18n, catalog, load, stop]),
    ?assertEqual(1, length(Excs)),
    ?assertEqual(0, length(Stops)),
    {_M, ExcMeta} = hd(Excs),
    ?assertEqual(error, maps:get(kind, ExcMeta)),
    ?assertEqual(boom, maps:get(reason, ExcMeta)),
    ?assert(is_list(maps:get(stacktrace, ExcMeta))).

%% =========================
%% F4, F8, F13 — strict `>` threshold boundary
%% =========================

%% Bytes == Threshold must NOT fire (strict `>`): returns the atom not_warned
%% and emits zero events. Kills the `> -> >=` mutant (which would `warned`).
memory_warning_threshold_boundary_not_warned(Config) ->
    application:set_env(erli18n, memory_warning_threshold, 1000),
    erli18n_telemetry:reset_caches(),
    ok = attach(Config, [[erli18n, catalog, memory_warning]]),
    ?assertEqual(
        not_warned,
        erli18n_telemetry:memory_warning_check(
            #{ets_bytes => 1000, num_catalogs => 0, num_keys => 0}
        )
    ),
    ?assertEqual(0, length(captured_for(Config, [erli18n, catalog, memory_warning]))).

%% =========================
%% F2, F23 — below-threshold not_warned (asserted directly)
%% =========================

%% The module's own doctest input (#{ets_bytes => 1024} under the default
%% 100 MiB threshold) returns the bare atom not_warned and emits nothing.
memory_warning_below_threshold_not_warned(Config) ->
    %% init_per_testcase already set the default threshold (104857600).
    ok = attach(Config, [[erli18n, catalog, memory_warning]]),
    ?assertEqual(
        not_warned,
        erli18n_telemetry:memory_warning_check(#{ets_bytes => 1024})
    ),
    ?assertEqual(0, length(captured_for(Config, [erli18n, catalog, memory_warning]))).

%% =========================
%% F11, F18, F22 — absent ets_bytes key defaults to 0 -> not_warned
%% =========================

%% A malformed snapshot lacking the `ets_bytes` key degrades safely: the
%% default of 0 cannot exceed a positive threshold, so not_warned, zero events.
memory_warning_absent_ets_bytes_not_warned(Config) ->
    application:set_env(erli18n, memory_warning_threshold, 1),
    erli18n_telemetry:reset_caches(),
    ok = attach(Config, [[erli18n, catalog, memory_warning]]),
    ?assertEqual(
        not_warned,
        erli18n_telemetry:memory_warning_check(#{num_catalogs => 1, num_keys => 1})
    ),
    ?assertEqual(0, length(captured_for(Config, [erli18n, catalog, memory_warning]))).

%% =========================
%% F3, F9 — second within-window crossing returns rate_limited
%% =========================

%% First crossing warns; a second crossing within the 60s window returns the
%% bare atom rate_limited and emits NO additional event (still exactly one).
memory_warning_second_crossing_rate_limited(Config) ->
    application:set_env(erli18n, memory_warning_threshold, 1),
    application:set_env(erli18n, memory_warning_rate_limit_seconds, 60),
    erli18n_telemetry:reset_caches(),
    ok = attach(Config, [[erli18n, catalog, memory_warning]]),
    ?assertEqual(
        warned,
        erli18n_telemetry:memory_warning_check(
            #{ets_bytes => 2, num_catalogs => 0, num_keys => 0}
        )
    ),
    ?assertEqual(
        rate_limited,
        erli18n_telemetry:memory_warning_check(
            #{ets_bytes => 2, num_catalogs => 0, num_keys => 0}
        )
    ),
    ?assertEqual(1, length(captured_for(Config, [erli18n, catalog, memory_warning]))).

%% =========================
%% F5, F14, F17 — window == 0 degenerate (every crossing re-emits)
%% =========================

%% With the window set to 0, `(Now - Last) < 0` is always false, so EVERY
%% crossing re-emits: two `warned` returns and two events. In the common
%% same-second case this also kills the `< -> =<` boundary mutant (which would
%% turn the second call into rate_limited / a single event).
memory_warning_window_zero_reemits(Config) ->
    application:set_env(erli18n, memory_warning_threshold, 1),
    application:set_env(erli18n, memory_warning_rate_limit_seconds, 0),
    erli18n_telemetry:reset_caches(),
    ok = attach(Config, [[erli18n, catalog, memory_warning]]),
    ?assertEqual(
        warned,
        erli18n_telemetry:memory_warning_check(
            #{ets_bytes => 2, num_catalogs => 0, num_keys => 0}
        )
    ),
    ?assertEqual(
        warned,
        erli18n_telemetry:memory_warning_check(
            #{ets_bytes => 2, num_catalogs => 0, num_keys => 0}
        )
    ),
    ?assertEqual(2, length(captured_for(Config, [erli18n, catalog, memory_warning]))).

%% =========================
%% F6, F10, F15 — domain_locales_sample clamped to exactly 10
%% =========================

%% With more than 10 distinct catalogs loaded, the emitted
%% `domain_locales_sample` has length EXACTLY 10 (not the catalog count). Kills
%% the `lists:sublist(Pairs, 10)` cap (a missing/altered cap would yield 12).
%% Loads happen under the default high threshold so the loader does not pre-emit
%% and consume the rate-limit anchor; the threshold is lowered and the cache
%% reset only afterwards, just before the direct (warned) check.
domain_locales_sample_capped_at_ten(Config) ->
    Path = write_minimal_po(Config),
    Locales = [list_to_binary("loc" ++ integer_to_list(N)) || N <- lists:seq(1, 12)],
    [{ok, _} = erli18n_server:ensure_loaded(default, L, Path) || L <- Locales],
    ?assertEqual(12, length(erli18n_server:loaded_catalogs())),
    application:set_env(erli18n, memory_warning_threshold, 1),
    application:set_env(erli18n, memory_warning_rate_limit_seconds, 60),
    erli18n_telemetry:reset_caches(),
    ok = attach(Config, [[erli18n, catalog, memory_warning]]),
    ?assertEqual(
        warned,
        erli18n_telemetry:memory_warning_check(
            #{ets_bytes => 2, num_catalogs => 12, num_keys => 12}
        )
    ),
    Events = captured_for(Config, [erli18n, catalog, memory_warning]),
    ?assertEqual(1, length(Events)),
    {_M, Meta} = hd(Events),
    Sample = maps:get(domain_locales_sample, Meta),
    ?assert(is_list(Sample)),
    ?assertEqual(10, length(Sample)).

%% =========================
%% F7, F16, F20, F24 — mid-flight enable: `false` is not negatively cached
%% =========================

%% With telemetry absent and the loaded-cache unset, the first emit observes
%% `false`, no-ops, and writes NO negative cache. Bringing telemetry up
%% mid-flight (without an intervening reset_caches) must make the very next emit
%% detect it and deliver the event. A mutant that negatively caches `false`
%% (persistent_term:put(?LOADED_KEY, false)) is killed both by the
%% `undefined` cache assertion and by the delivered-event assertion.
mid_flight_telemetry_enable_picked_up(Config) ->
    ok = erli18n_telemetry:reset_caches(),
    TelFile =
        case code:which(telemetry) of
            P when is_list(P) -> P;
            Other -> error({telemetry_module_path_unexpected, Other})
        end,
    TelDir = filename:dirname(TelFile),
    true = code:del_path(TelDir),
    _ = application:stop(telemetry),
    _ = code:delete(telemetry),
    _ = code:purge(telemetry),
    ?assertEqual({error, nofile}, code:ensure_loaded(telemetry)),
    try
        %% Absent-path emit: returns ok, no event, and crucially no cache write.
        ?assertEqual(
            ok,
            erli18n_telemetry:emit(
                [erli18n, catalog, unload], #{count => 1}, #{domain => default}
            )
        ),
        %% The `false` detection was NOT negatively cached.
        ?assertEqual(
            undefined,
            persistent_term:get({erli18n_telemetry, telemetry_loaded}, undefined)
        ),
        %% Bring telemetry up mid-flight WITHOUT reset_caches in between.
        true = code:add_patha(TelDir),
        {module, telemetry} = code:ensure_loaded(telemetry),
        {ok, _} = application:ensure_all_started(telemetry),
        ok = attach(Config, [[erli18n, catalog, unload]]),
        %% Next emit must now detect telemetry and deliver the event.
        ?assertEqual(
            ok,
            erli18n_telemetry:emit(
                [erli18n, catalog, unload], #{count => 1}, #{domain => default}
            )
        ),
        ?assertEqual(1, length(captured_for(Config, [erli18n, catalog, unload])))
    after
        _ = code:add_patha(TelDir),
        _ = code:ensure_loaded(telemetry),
        ok = erli18n_telemetry:reset_caches(),
        {ok, _} = application:ensure_all_started(telemetry)
    end.

%% =========================
%% F19 — mistyped arguments raise function_clause
%% =========================

%% emit/3 and span/3 are single guarded clauses; wrong-typed arguments must
%% crash with function_clause (caller crash), never silently no-op.
emit_and_span_function_clause_on_mistyped_args(_Config) ->
    ?assertError(
        function_clause,
        erli18n_telemetry:emit(not_a_list, #{}, #{})
    ),
    ?assertError(
        function_clause,
        erli18n_telemetry:span([], not_a_map, fun() -> {ok, #{}} end)
    ).

%% =========================
%% F21 — span/3 no-op path: non-tuple Fun return crashes with badmatch
%% =========================

%% On the telemetry-absent path, span/3 binds `{Result, _StopMetadata} = Fun()`
%% BEFORE any emission; a non-tuple return raises `{badmatch, not_a_tuple}` and
%% nothing is emitted (no telemetry handler can even be attached while absent).
span_noop_badmatch_on_non_tuple_return(_Config) ->
    with_telemetry_unloaded(
        fun() ->
            ?assertError(
                {badmatch, not_a_tuple},
                erli18n_telemetry:span(
                    [erli18n, catalog, load],
                    #{},
                    fun() -> not_a_tuple end
                )
            )
        end
    ).
