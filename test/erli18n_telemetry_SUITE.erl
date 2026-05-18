-module(erli18n_telemetry_SUITE).

%% Common Test suite for the `:telemetry` observability layer (Parte 7).
%%
%% Schemas and contract under test come from:
%%   `_reversa_sdd/migration/observability.md` §4 (catalogue),
%%   §5 (typespecs), §6 (overhead policy).
%%
%% Pattern:
%%   * Each test attaches one or more `telemetry` handlers to the
%%     event(s) under test via `telemetry:attach_many/4`.
%%   * Triggers the operation (load, lookup, etc.).
%%   * Reads the captured events from an ETS table populated by the
%%     handler callback.
%%   * Detaches the handlers in `end_per_testcase/2`.
%%
%% This mirrors the recommended `telemetry` test pattern from
%% https://hexdocs.pm/telemetry/readme.html#testing.

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
    telemetry_catalog_load_emits_span_start_stop/1,
    telemetry_catalog_load_already_reports_result_in_metadata/1,
    telemetry_catalog_load_error_path_uses_stop_not_exception/1,
    telemetry_catalog_reload_emits_span/1,
    telemetry_catalog_unload_emits_span/1,
    telemetry_catalog_unload_not_loaded_reports_zero/1,
    telemetry_lookup_miss_opt_in_default_off/1,
    telemetry_lookup_miss_opt_in_enabled/1,
    telemetry_lookup_miss_function_metadata/1,
    telemetry_lookup_fuzzy_skip_emits_on_load/1,
    telemetry_lookup_fuzzy_skip_not_emitted_when_include_fuzzy/1,
    telemetry_plural_divergence_always_on/1,
    telemetry_plural_divergence_not_emitted_when_aligned/1,
    telemetry_memory_warning_when_threshold_crossed/1,
    telemetry_memory_warning_rate_limited/1,
    telemetry_metadata_includes_po_path/1,
    telemetry_event_names_are_canonical/1,
    telemetry_emit_is_noop_when_telemetry_unloaded/1,
    telemetry_span_runs_fun_when_telemetry_unloaded/1,
    telemetry_memory_warning_sample_empty_without_server/1
]).

all() ->
    [
        telemetry_catalog_load_emits_span_start_stop,
        telemetry_catalog_load_already_reports_result_in_metadata,
        telemetry_catalog_load_error_path_uses_stop_not_exception,
        telemetry_catalog_reload_emits_span,
        telemetry_catalog_unload_emits_span,
        telemetry_catalog_unload_not_loaded_reports_zero,
        telemetry_lookup_miss_opt_in_default_off,
        telemetry_lookup_miss_opt_in_enabled,
        telemetry_lookup_miss_function_metadata,
        telemetry_lookup_fuzzy_skip_emits_on_load,
        telemetry_lookup_fuzzy_skip_not_emitted_when_include_fuzzy,
        telemetry_plural_divergence_always_on,
        telemetry_plural_divergence_not_emitted_when_aligned,
        telemetry_memory_warning_when_threshold_crossed,
        telemetry_memory_warning_rate_limited,
        telemetry_metadata_includes_po_path,
        telemetry_event_names_are_canonical,
        telemetry_emit_is_noop_when_telemetry_unloaded,
        telemetry_span_runs_fun_when_telemetry_unloaded,
        telemetry_memory_warning_sample_empty_without_server
    ].

%% =========================
%% Setup / teardown
%% =========================

init_per_suite(Config) ->
    %% `telemetry` is declared as optional_applications in erli18n.app.src
    %% so it is NOT auto-started by ensure_all_started/1. The consumer of
    %% the lib is responsible for booting telemetry if they want events
    %% routed; here we boot it explicitly to exercise the attach/emit
    %% path. The lib itself remains crash-safe when telemetry is missing
    %% (verified by the `erli18n_telemetry:telemetry_loaded/0` guard).
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _Apps} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    %% Reset env to defaults so tests in other suites do not inherit
    %% telemetry opt-in.
    application:unset_env(erli18n, emit_lookup_telemetry),
    application:unset_env(erli18n, memory_warning_threshold),
    application:unset_env(erli18n, memory_warning_rate_limit_seconds),
    ok = application:stop(erli18n),
    _ = application:stop(telemetry),
    ok.

init_per_testcase(TC, Config) ->
    %% Clean slate per test: unload any catalog that lingers from a
    %% previous case, reset env flags and the memory-warning
    %% rate-limit cache, and create a fresh capture ETS.
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    application:set_env(erli18n, emit_lookup_telemetry, false),
    application:set_env(erli18n, memory_warning_threshold, 104857600),
    application:set_env(erli18n, memory_warning_rate_limit_seconds, 60),
    erli18n_telemetry:reset_caches(),
    Tab = ets:new(erli18n_telemetry_capture, [public, ordered_set]),
    HandlerId = handler_id(TC),
    [{capture_tab, Tab}, {handler_id, HandlerId} | Config].

end_per_testcase(_TC, Config) ->
    %% Best-effort teardown: handler may already be detached and table
    %% may already be deleted by mid-test code. Both are acceptable.
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
        "erli18n_test_handler_" ++
            atom_to_list(TC) ++ "_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ).

fixture(Config, Name) ->
    Dir = ?config(data_dir, Config),
    filename:join(Dir, Name).

%% Attach to a list of event names. Captures every emit into the suite's
%% ETS table as `{Seq, EventName, Measurements, Metadata}`.
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

%% Capture callback. The 4-arity signature is the `telemetry` v1.x
%% convention (https://hexdocs.pm/telemetry/telemetry.html#type-handler_function).
handle_event(EventName, Measurements, Metadata, #{tab := Tab}) ->
    Seq = erlang:unique_integer([monotonic, positive]),
    ets:insert(Tab, {Seq, EventName, Measurements, Metadata}),
    ok.

%% Read all captured events in emission order.
captured(Config) ->
    Tab = ?config(capture_tab, Config),
    [{N, M, Meta} || {_S, N, M, Meta} <- ets:tab2list(Tab)].

%% Filter captured by event name.
captured_for(Config, EventName) ->
    [{M, Meta} || {N, M, Meta} <- captured(Config), N =:= EventName].

%% =========================
%% Catalog load span
%% =========================

%% Spec: observability.md §4.1 `[erli18n, catalog, load]`. A successful
%% load emits exactly two events: `..., load, start]` followed by
%% `..., load, stop]`. The stop carries `result => ok` and
%% `keys_loaded => N` in metadata.
telemetry_catalog_load_emits_span_start_stop(Config) ->
    ok = attach(Config, [
        [erli18n, catalog, load, start],
        [erli18n, catalog, load, stop],
        [erli18n, catalog, load, exception]
    ]),
    Path = fixture(Config, "minimal_en.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    Events = captured(Config),
    %% Exactly one start and one stop, no exception.
    Starts = [E || {[erli18n, catalog, load, start], _, _} = E <- Events],
    Stops = [E || {[erli18n, catalog, load, stop], _, _} = E <- Events],
    Excs = [E || {[erli18n, catalog, load, exception], _, _} = E <- Events],
    ?assertEqual(1, length(Starts)),
    ?assertEqual(1, length(Stops)),
    ?assertEqual(0, length(Excs)),
    %% Stop metadata: result => ok, keys_loaded => 1, domain/locale carried.
    {[erli18n, catalog, load, stop], _M, StopMeta} = hd(Stops),
    ?assertEqual(ok, maps:get(result, StopMeta)),
    ?assertEqual(1, maps:get(keys_loaded, StopMeta)),
    ?assertEqual(default, maps:get(domain, StopMeta)),
    ?assertEqual(<<"en">>, maps:get(locale, StopMeta)),
    %% Stop measurements include duration (telemetry:span/3 contract).
    {[erli18n, catalog, load, stop], StopM, _} = hd(Stops),
    ?assert(maps:is_key(duration, StopM)),
    ?assert(maps:is_key(monotonic_time, StopM)).

%% Spec: observability.md §4.1 idempotent fast-path. A second
%% `ensure_loaded` still emits the span; the stop metadata records
%% `result => already` and `keys_loaded => 0`. RISK-012 mitigation 2.
telemetry_catalog_load_already_reports_result_in_metadata(Config) ->
    ok = attach(Config, [[erli18n, catalog, load, stop]]),
    Path = fixture(Config, "minimal_en.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    {ok, already} = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    Stops = captured_for(Config, [erli18n, catalog, load, stop]),
    ?assertEqual(2, length(Stops)),
    [{_M1, Meta1}, {_M2, Meta2}] = Stops,
    %% First call: ok / 1 key. Second call: already / 0.
    ?assertEqual(ok, maps:get(result, Meta1)),
    ?assertEqual(1, maps:get(keys_loaded, Meta1)),
    ?assertEqual(already, maps:get(result, Meta2)),
    ?assertEqual(0, maps:get(keys_loaded, Meta2)).

%% Spec: observability.md §8 — failure that returns `{error, _}` (not a
%% crash) emits `:stop` with `result => {error, _}`, NOT `:exception`.
%% Exception is reserved for Erlang throw/error/exit.
telemetry_catalog_load_error_path_uses_stop_not_exception(Config) ->
    ok = attach(Config, [
        [erli18n, catalog, load, start],
        [erli18n, catalog, load, stop],
        [erli18n, catalog, load, exception]
    ]),
    Path = fixture(Config, "invalid_syntax.po"),
    Result = erli18n_server:ensure_loaded(default, <<"x">>, Path),
    ?assertMatch({error, {syntax_error, _, _}}, Result),
    Events = captured(Config),
    Stops = [E || {[erli18n, catalog, load, stop], _, _} = E <- Events],
    Excs = [E || {[erli18n, catalog, load, exception], _, _} = E <- Events],
    ?assertEqual(1, length(Stops)),
    ?assertEqual(0, length(Excs)),
    {_, _M, StopMeta} = hd(Stops),
    ?assertMatch({error, _}, maps:get(result, StopMeta)),
    ?assertEqual(0, maps:get(keys_loaded, StopMeta)).

%% Spec: observability.md §4.1 `[erli18n, catalog, reload]`. Same
%% schema as load; distinct event name lets consumers react
%% specifically to overwrites.
telemetry_catalog_reload_emits_span(Config) ->
    Path = fixture(Config, "minimal_en.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    ok = attach(Config, [
        [erli18n, catalog, reload, start],
        [erli18n, catalog, reload, stop]
    ]),
    {ok, 1} = erli18n_server:reload(default, <<"en">>, Path),
    Events = captured(Config),
    Starts = [E || {[erli18n, catalog, reload, start], _, _} = E <- Events],
    Stops = [E || {[erli18n, catalog, reload, stop], _, _} = E <- Events],
    ?assertEqual(1, length(Starts)),
    ?assertEqual(1, length(Stops)),
    {_, _, StopMeta} = hd(Stops),
    ?assertEqual(ok, maps:get(result, StopMeta)),
    ?assertEqual(1, maps:get(keys_loaded, StopMeta)).

%% Spec: observability.md §4.1 `[erli18n, catalog, unload]`. Stop
%% metadata reports `result => ok` and `keys_removed` count.
telemetry_catalog_unload_emits_span(Config) ->
    Path = fixture(Config, "minimal_en.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    ok = attach(Config, [
        [erli18n, catalog, unload, start],
        [erli18n, catalog, unload, stop]
    ]),
    ok = erli18n_server:unload(default, <<"en">>),
    Stops = captured_for(Config, [erli18n, catalog, unload, stop]),
    ?assertEqual(1, length(Stops)),
    {_M, StopMeta} = hd(Stops),
    ?assertEqual(ok, maps:get(result, StopMeta)),
    %% Minimal_en.po has 1 singular entry + 1 header row = 2 rows
    %% deleted from ETS.
    ?assert(maps:get(keys_removed, StopMeta) >= 1),
    ?assertEqual(default, maps:get(domain, StopMeta)),
    ?assertEqual(<<"en">>, maps:get(locale, StopMeta)).

%% Spec: observability.md §4.1 unload of a catalog that was never
%% loaded -> result => not_loaded, keys_removed => 0.
telemetry_catalog_unload_not_loaded_reports_zero(Config) ->
    ok = attach(Config, [[erli18n, catalog, unload, stop]]),
    ok = erli18n_server:unload(default, <<"never_loaded">>),
    Stops = captured_for(Config, [erli18n, catalog, unload, stop]),
    ?assertEqual(1, length(Stops)),
    {_, StopMeta} = hd(Stops),
    ?assertEqual(not_loaded, maps:get(result, StopMeta)),
    ?assertEqual(0, maps:get(keys_removed, StopMeta)).

%% =========================
%% Lookup miss — opt-in
%% =========================

%% Spec: observability.md §6 (overhead policy) — lookup miss is opt-in.
%% Default OFF means zero events even when a miss occurs.
telemetry_lookup_miss_opt_in_default_off(Config) ->
    %% Confirm default is off.
    ?assertEqual(false, erli18n_telemetry:lookup_telemetry_enabled()),
    ok = attach(Config, [[erli18n, lookup, miss]]),
    %% Trigger a miss: domain/locale not loaded, gettext falls back to
    %% msgid.
    <<"nonexistent">> = erli18n:gettext(
        default,
        <<"nonexistent">>,
        <<"en">>
    ),
    Events = captured_for(Config, [erli18n, lookup, miss]),
    ?assertEqual(0, length(Events)).

%% Spec: observability.md §4.2 lookup_miss measurements/metadata
%% schema. Opt-in via `application:set_env(erli18n,
%% emit_lookup_telemetry, true)`.
telemetry_lookup_miss_opt_in_enabled(Config) ->
    application:set_env(erli18n, emit_lookup_telemetry, true),
    ok = attach(Config, [[erli18n, lookup, miss]]),
    <<"nonexistent">> = erli18n:gettext(
        default,
        <<"nonexistent">>,
        <<"fr">>
    ),
    Events = captured_for(Config, [erli18n, lookup, miss]),
    ?assertEqual(1, length(Events)),
    {M, Meta} = hd(Events),
    ?assertEqual(1, maps:get(count, M)),
    ?assertEqual(default, maps:get(domain, Meta)),
    ?assertEqual(<<"fr">>, maps:get(locale, Meta)),
    ?assertEqual(<<"nonexistent">>, maps:get(msgid, Meta)),
    ?assertEqual(gettext, maps:get(function, Meta)),
    ?assertEqual(undefined, maps:get(context, Meta)).

%% Spec: observability.md §4.2 — function metadata distinguishes the
%% call shape: gettext, ngettext, pgettext, npgettext.
telemetry_lookup_miss_function_metadata(Config) ->
    application:set_env(erli18n, emit_lookup_telemetry, true),
    ok = attach(Config, [[erli18n, lookup, miss]]),
    %% Force one miss per call shape; no catalog loaded.
    <<"a">> = erli18n:gettext(default, <<"a">>, <<"en">>),
    <<"bs">> = erli18n:ngettext(default, <<"b">>, <<"bs">>, 2, <<"en">>),
    <<"c">> = erli18n:pgettext(default, <<"menu">>, <<"c">>, <<"en">>),
    <<"ds">> = erli18n:npgettext(
        default,
        <<"menu">>,
        <<"d">>,
        <<"ds">>,
        2,
        <<"en">>
    ),
    Events = captured_for(Config, [erli18n, lookup, miss]),
    ?assertEqual(4, length(Events)),
    Functions = lists:sort([maps:get(function, Meta) || {_M, Meta} <- Events]),
    ?assertEqual([gettext, ngettext, npgettext, pgettext], Functions),
    %% pgettext / npgettext carry their context atom in metadata.
    PgettextEvent = [
        E
     || {_M, Meta} = E <- Events,
        maps:get(function, Meta) =:= pgettext
    ],
    ?assertEqual(1, length(PgettextEvent)),
    {_, PgMeta} = hd(PgettextEvent),
    ?assertEqual(<<"menu">>, maps:get(context, PgMeta)).

%% =========================
%% Fuzzy skip — loader-level emit
%% =========================

%% Spec: observability.md §4.2 fuzzy_skip — loader-level aggregated
%% emit; same opt-in flag as lookup miss. fuzzy_entry.po has 1 fuzzy
%% entry that is dropped by default; we expect count=1 when the flag is
%% on.
telemetry_lookup_fuzzy_skip_emits_on_load(Config) ->
    application:set_env(erli18n, emit_lookup_telemetry, true),
    ok = attach(Config, [[erli18n, lookup, fuzzy_skip]]),
    Path = fixture(Config, "fuzzy_entry.po"),
    {ok, _N} = erli18n_server:ensure_loaded(default, <<"fr">>, Path),
    Events = captured_for(Config, [erli18n, lookup, fuzzy_skip]),
    ?assertEqual(1, length(Events)),
    {M, Meta} = hd(Events),
    ?assertEqual(1, maps:get(count, M)),
    ?assertEqual(default, maps:get(domain, Meta)),
    ?assertEqual(<<"fr">>, maps:get(locale, Meta)).

%% Spec: observability.md §4.2 — `include_fuzzy => true` means no
%% entries are dropped, so the event is not emitted.
telemetry_lookup_fuzzy_skip_not_emitted_when_include_fuzzy(Config) ->
    application:set_env(erli18n, emit_lookup_telemetry, true),
    ok = attach(Config, [[erli18n, lookup, fuzzy_skip]]),
    Path = fixture(Config, "fuzzy_entry.po"),
    {ok, _N} = erli18n_server:ensure_loaded(
        default,
        <<"fr">>,
        Path,
        #{include_fuzzy => true}
    ),
    Events = captured_for(Config, [erli18n, lookup, fuzzy_skip]),
    ?assertEqual(0, length(Events)).

%% =========================
%% Plural divergence — always-on
%% =========================

%% Spec: observability.md §4.2 — plural divergence is always-on (no
%% opt-in). divergent_fr.po has French header `n != 1` while CLDR
%% canonical for fr is `n > 1`.
telemetry_plural_divergence_always_on(Config) ->
    %% Explicitly leave emit_lookup_telemetry off to prove this event
    %% is unconditional.
    application:set_env(erli18n, emit_lookup_telemetry, false),
    ok = attach(Config, [[erli18n, plural, divergence_warning]]),
    Path = fixture(Config, "divergent_fr.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"fr">>, Path),
    Events = captured_for(Config, [erli18n, plural, divergence_warning]),
    ?assertEqual(1, length(Events)),
    {M, Meta} = hd(Events),
    ?assertEqual(1, maps:get(count, M)),
    ?assertEqual(default, maps:get(domain, Meta)),
    ?assertEqual(<<"fr">>, maps:get(locale, Meta)),
    %% Both rules carried so the consumer can render the diff.
    ?assert(is_binary(maps:get(po_rule, Meta))),
    ?assert(is_binary(maps:get(cldr_rule, Meta))).

%% Spec: observability.md §4.2 — no event when header rule == CLDR
%% canonical. plural_fr.po uses `n > 1` which matches CLDR for fr.
telemetry_plural_divergence_not_emitted_when_aligned(Config) ->
    ok = attach(Config, [[erli18n, plural, divergence_warning]]),
    Path = fixture(Config, "plural_fr.po"),
    {ok, _} = erli18n_server:ensure_loaded(default, <<"fr">>, Path),
    Events = captured_for(Config, [erli18n, plural, divergence_warning]),
    ?assertEqual(0, length(Events)).

%% =========================
%% Memory warning — always-on, rate-limited
%% =========================

%% Spec: observability.md §4.2 — emits when ets_bytes crosses
%% threshold. Test forces threshold to 1 byte so any load triggers.
%% Also verifies the metadata sample (`domain_locales_sample`) per
%% §4.2 ("amostra de até 10 `{Domain, Locale}`").
telemetry_memory_warning_when_threshold_crossed(Config) ->
    application:set_env(erli18n, memory_warning_threshold, 1),
    application:set_env(erli18n, memory_warning_rate_limit_seconds, 60),
    erli18n_telemetry:reset_caches(),
    ok = attach(Config, [[erli18n, catalog, memory_warning]]),
    Path = fixture(Config, "minimal_en.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    Events = captured_for(Config, [erli18n, catalog, memory_warning]),
    ?assertEqual(1, length(Events)),
    {M, Meta} = hd(Events),
    ?assert(maps:get(ets_bytes, M) > 0),
    ?assertEqual(1, maps:get(threshold_bytes, M)),
    ?assert(maps:get(num_keys, M) >= 1),
    ?assert(maps:get(num_catalogs, M) >= 1),
    Sample = maps:get(domain_locales_sample, Meta),
    ?assert(is_list(Sample)),
    ?assert(length(Sample) =< 10),
    ?assert(lists:member({default, <<"en">>}, Sample)).

%% Spec: observability.md §4.2 — rate-limit window suppresses repeated
%% emits even when threshold remains crossed.
telemetry_memory_warning_rate_limited(Config) ->
    application:set_env(erli18n, memory_warning_threshold, 1),
    application:set_env(erli18n, memory_warning_rate_limit_seconds, 60),
    erli18n_telemetry:reset_caches(),
    ok = attach(Config, [[erli18n, catalog, memory_warning]]),
    Path1 = fixture(Config, "minimal_en.po"),
    Path2 = fixture(Config, "plural_fr.po"),
    %% Five distinct loads, all crossing the 1-byte threshold.
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"l1">>, Path1),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"l2">>, Path1),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"l3">>, Path2),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"l4">>, Path2),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"l5">>, Path1),
    Events = captured_for(Config, [erli18n, catalog, memory_warning]),
    %% Exactly one event within the 60s window.
    ?assertEqual(1, length(Events)).

%% Spec: observability.md §4.1 — po_path is part of the load start/stop
%% metadata. Verifies the binary normalization (the path is passed as a
%% string by the loader; metadata must be binary per §5 typespec).
telemetry_metadata_includes_po_path(Config) ->
    ok = attach(Config, [
        [erli18n, catalog, load, start],
        [erli18n, catalog, load, stop]
    ]),
    Path = fixture(Config, "minimal_en.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    Starts = captured_for(Config, [erli18n, catalog, load, start]),
    ?assertEqual(1, length(Starts)),
    {_M, Meta} = hd(Starts),
    PoPath = maps:get(po_path, Meta),
    ?assert(is_binary(PoPath)),
    ?assert(binary:match(PoPath, <<"minimal_en.po">>) =/= nomatch),
    %% fuzzy_included default is false (no opt passed).
    ?assertEqual(false, maps:get(fuzzy_included, Meta)),
    %% language is lc_messages — observability.md §4.1 base metadata.
    ?assertEqual(lc_messages, maps:get(language, Meta)).

%% Sanity: the event-name accessors in `erli18n_telemetry` must return
%% the exact lists documented in observability.md §3-4. This guards
%% against accidental renames during refactoring — renames would be a
%% major-version-breaking change per §7.
telemetry_event_names_are_canonical(_Config) ->
    ?assertEqual(
        [erli18n, catalog, load],
        erli18n_telemetry:event_catalog_load()
    ),
    ?assertEqual(
        [erli18n, catalog, reload],
        erli18n_telemetry:event_catalog_reload()
    ),
    ?assertEqual(
        [erli18n, catalog, unload],
        erli18n_telemetry:event_catalog_unload()
    ),
    ?assertEqual(
        [erli18n, lookup, miss],
        erli18n_telemetry:event_lookup_miss()
    ),
    ?assertEqual(
        [erli18n, lookup, fuzzy_skip],
        erli18n_telemetry:event_lookup_fuzzy_skip()
    ),
    ?assertEqual(
        [erli18n, plural, divergence_warning],
        erli18n_telemetry:event_plural_divergence()
    ),
    ?assertEqual(
        [erli18n, catalog, memory_warning],
        erli18n_telemetry:event_catalog_memory_warning()
    ).

%% =========================
%% Telemetry-absent path
%% =========================
%%
%% These tests exercise the no-op branches of `erli18n_telemetry` that
%% fire when the `telemetry` library is not loaded in the running VM
%% (observability.md §11 "no-op safe, never crashes"). We simulate
%% absence by temporarily removing telemetry from the code path,
%% deleting/purging the module, and resetting the persistent_term cache
%% so the next call to `telemetry_loaded/0` actually walks the code
%% server (instead of hitting the sticky-true cache). The teardown
%% restores the code path, reloads telemetry, and re-attaches the
%% application so subsequent suites and tests see a clean state.

%% Spec: observability.md §11 — when telemetry is absent, `emit/3` must
%% return `ok` without raising. Covers the `false ->` clause of
%% `emit/3` and the `_ ->` clause of `telemetry_loaded/0`.
telemetry_emit_is_noop_when_telemetry_unloaded(_Config) ->
    with_telemetry_unloaded(
        fun() ->
            ?assertEqual(
                ok,
                erli18n_telemetry:emit(
                    [erli18n, catalog, load],
                    #{count => 1},
                    #{domain => default}
                )
            )
        end
    ).

%% Spec: observability.md §11 — when telemetry is absent, `span/3` must
%% still run Fun (so the lib has identical observable behaviour with or
%% without telemetry) and return Fun's first tuple element. Covers the
%% `false ->` clause of `span/3` (the `{Result, _StopMetadata} = Fun()`
%% / `Result` lines) and the `_ ->` clause of `telemetry_loaded/0`.
telemetry_span_runs_fun_when_telemetry_unloaded(_Config) ->
    Marker = make_ref(),
    with_telemetry_unloaded(
        fun() ->
            Result = erli18n_telemetry:span(
                [erli18n, catalog, load],
                #{domain => default},
                fun() -> {Marker, #{result => ok}} end
            ),
            ?assertEqual(Marker, Result)
        end
    ).

%% Spec: observability.md §4.2 — when `erli18n_server` is not loaded,
%% `collect_domain_locales_sample/0` must return `[]` (defensive guard
%% so the telemetry module never crashes the caller). Covers the
%% `false ->` clause of `collect_domain_locales_sample/0`.
telemetry_memory_warning_sample_empty_without_server(Config) ->
    %% Force-cross the threshold and short window so the first call
    %% emits.
    application:set_env(erli18n, memory_warning_threshold, 1),
    application:set_env(erli18n, memory_warning_rate_limit_seconds, 60),
    erli18n_telemetry:reset_caches(),
    ok = attach(Config, [[erli18n, catalog, memory_warning]]),
    %% Hot-unload erli18n_server so that
    %% `erlang:function_exported(erli18n_server, loaded_catalogs, 0)`
    %% returns false. The gen_server process keeps running on old
    %% (soft-purged-out) code, but no API calls are made against it
    %% during this test — we drive `memory_warning_check/1` directly
    %% with a synthetic MemInfo map.
    try
        true = code:delete(erli18n_server),
        %% soft_purge is best-effort; if a process is using the old
        %% code we proceed anyway because the function_exported check
        %% only inspects the *current* loaded version.
        _ = code:soft_purge(erli18n_server),
        ?assertEqual(
            false,
            erlang:function_exported(
                erli18n_server,
                loaded_catalogs,
                0
            )
        ),
        warned = erli18n_telemetry:memory_warning_check(
            #{
                ets_bytes => 2,
                num_catalogs => 0,
                num_keys => 0
            }
        ),
        Events = captured_for(
            Config,
            [erli18n, catalog, memory_warning]
        ),
        ?assertEqual(1, length(Events)),
        {_M, Meta} = hd(Events),
        ?assertEqual([], maps:get(domain_locales_sample, Meta))
    after
        {module, erli18n_server} = code:ensure_loaded(erli18n_server)
    end.

%% Run Fun with telemetry deliberately unloaded from the VM, then
%% restore. Mirrors the production no-op story: persistent_term cache
%% reset + module purge + path removal + ensure_loaded must observe
%% `{error, nofile}`.
with_telemetry_unloaded(Fun) ->
    ok = erli18n_telemetry:reset_caches(),
    %% `code:which/1` returns `loaded_filename() | non_existing | ...`;
    %% narrow at the boundary so `filename:dirname/1` and `code:del_path/1`
    %% see a concrete `string()`. If telemetry is not loaded we abort the
    %% helper — the suite skips telemetry-unloaded cases when the dep is
    %% absent (covered by other branches), so this is a defensive guard
    %% rather than a runtime path.
    TelFile =
        case code:which(telemetry) of
            Path when is_list(Path) -> Path;
            Other -> error({telemetry_module_path_unexpected, Other})
        end,
    TelDir = filename:dirname(TelFile),
    true = code:del_path(TelDir),
    %% Best-effort: stop the app if it is running so processes do not
    %% hold references to old code.
    _ = application:stop(telemetry),
    _ = code:delete(telemetry),
    _ = code:purge(telemetry),
    %% Sanity: telemetry is now genuinely absent from the code server.
    ?assertEqual({error, nofile}, code:ensure_loaded(telemetry)),
    try
        Fun()
    after
        true = code:add_patha(TelDir),
        {module, telemetry} = code:ensure_loaded(telemetry),
        ok = erli18n_telemetry:reset_caches(),
        {ok, _} = application:ensure_all_started(telemetry)
    end.
