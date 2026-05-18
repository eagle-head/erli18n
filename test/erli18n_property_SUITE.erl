%%% =====================================================================
%%% Common Test runner for property-based tests (PropEr).
%%%
%%% Each test_case in this suite invokes `proper:quickcheck/2` for one
%%% property. `numtests` is fixed at 200 — chosen per
%%% `parity_specs.md` §6.1 ("Min runs CI por PR: 200") as the floor for
%%% PR validation. CI noturno may rerun this same suite with a higher
%%% numtests via ct_run --userconfig, but the default is the
%%% release-blocking baseline.
%%%
%%% PropEr counter-examples are written to stdout (via `{to_file, user}`)
%%% so when a property fails the CT log surfaces the minimized input
%%% directly. Persisting counter-examples to disk (`proper_counterexamples/`)
%%% is documented in `parity_specs.md` §6.1; we leave the disk-corpus
%%% wiring as a follow-up since PropEr 1.5 expects the consumer to
%%% manage that file lifecycle explicitly.
%%% =====================================================================
-module(erli18n_property_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    roundtrip_parse_dump/1,
    idempotent_normalization/1,
    ets_key_canonical/1,
    plural_index_in_range/1,
    plural_compile_or_error/1,
    lookup_singular_deterministic/1,
    lookup_plural_deterministic/1,
    lookup_contextual_deterministic/1,
    lookup_miss_fallback_deterministic/1
]).

%% Number of QuickCheck runs per property. 200 = release-blocking floor
%% per `parity_specs.md` §6.1.
-define(NUMTESTS, 200).

all() ->
    [
        roundtrip_parse_dump,
        idempotent_normalization,
        ets_key_canonical,
        plural_index_in_range,
        plural_compile_or_error,
        lookup_singular_deterministic,
        lookup_plural_deterministic,
        lookup_contextual_deterministic,
        lookup_miss_fallback_deterministic
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    %% Best-effort cleanup; ignore failures (the app may have already
    %% been stopped if a property test bounced it).
    _ = application:stop(erli18n),
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%% =========================
%% Test cases — wrappers around PropEr properties
%% =========================

roundtrip_parse_dump(_Config) ->
    run_property(erli18n_po_props:prop_roundtrip_parse_dump()).

idempotent_normalization(_Config) ->
    run_property(erli18n_po_props:prop_idempotent_normalization()).

ets_key_canonical(_Config) ->
    run_property(erli18n_po_props:prop_ets_key_canonical()).

plural_index_in_range(_Config) ->
    run_property(erli18n_plural_props:prop_index_in_range()).

plural_compile_or_error(_Config) ->
    run_property(erli18n_plural_props:prop_compile_or_error()).

lookup_singular_deterministic(_Config) ->
    run_property(erli18n_lookup_props:prop_singular_lookup_deterministic()).

lookup_plural_deterministic(_Config) ->
    run_property(erli18n_lookup_props:prop_plural_lookup_deterministic()).

lookup_contextual_deterministic(_Config) ->
    run_property(
        erli18n_lookup_props:prop_contextual_lookup_deterministic()
    ).

lookup_miss_fallback_deterministic(_Config) ->
    run_property(
        erli18n_lookup_props:prop_miss_fallback_deterministic()
    ).

%% =========================
%% Helpers
%% =========================

%% Bridge from PropEr's boolean-returning API to CT's exception-based
%% pass/fail convention. We use `{to_file, user}` so failed properties
%% print their minimized counter-example into the standard output stream
%% (the CT framework captures and includes that in the test log).
run_property(Property) ->
    Result = proper:quickcheck(
        Property,
        [
            {numtests, ?NUMTESTS},
            {to_file, user}
        ]
    ),
    ?assert(Result =:= true).
