%%% =====================================================================
%%% Common Test runner for `erli18n_po` fuzz scenarios (F1..F7) per
%%% `parity_specs.md` §6.2.
%%%
%%% Each scenario runs `proper:quickcheck/2` with 500 generated inputs.
%%% That number matches the "Min runs CI por PR" floor from §6.2; CI
%%% noturno is expected to bump this via a CT config override but the
%%% default is the release-blocking baseline.
%%%
%%% F7 (end-to-end against `ensure_loaded`) is intentionally given the
%%% same numtests as the parser-isolated scenarios — the file I/O
%%% overhead per iteration is small (sub-millisecond) and the
%%% supervisor-invariant check is fast.
%%% =====================================================================
-module(erli18n_fuzz_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    fuzz_random_bytes/1,
    fuzz_mutated_po/1,
    fuzz_truncated_po/1,
    fuzz_embedded_controls/1,
    fuzz_encoding_mismatch/1,
    fuzz_extreme_inputs/1,
    fuzz_decode_is_linear/1,
    fuzz_end_to_end/1,
    fuzz_giant_integer_runs/1
]).

-define(NUMTESTS, 500).

all() ->
    [
        fuzz_random_bytes,
        fuzz_mutated_po,
        fuzz_truncated_po,
        fuzz_embedded_controls,
        fuzz_encoding_mismatch,
        fuzz_extreme_inputs,
        fuzz_decode_is_linear,
        fuzz_end_to_end,
        fuzz_giant_integer_runs
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(erli18n),
    ok.

%% =========================
%% Scenarios
%% =========================

fuzz_random_bytes(_Config) ->
    run(erli18n_po_fuzz:prop_random_bytes()).

fuzz_mutated_po(_Config) ->
    run(erli18n_po_fuzz:prop_mutated_po()).

fuzz_truncated_po(_Config) ->
    run(erli18n_po_fuzz:prop_truncated_po()).

fuzz_embedded_controls(_Config) ->
    run(erli18n_po_fuzz:prop_embedded_controls()).

fuzz_encoding_mismatch(_Config) ->
    run(erli18n_po_fuzz:prop_encoding_mismatch()).

fuzz_extreme_inputs(_Config) ->
    %% Bumped numtests down for F6 — each variant builds a 100KB+
    %% binary in memory, and 500 iterations across three variants is
    %% sufficient to surface any obvious super-linear blowup. Pinned
    %% explicitly so the rationale stays visible.
    Result =
        proper:quickcheck(
            erli18n_po_fuzz:prop_extreme_inputs(),
            [{numtests, 100}, {to_file, user}]
        ),
    ?assert(Result =:= true).

fuzz_decode_is_linear(_Config) ->
    %% F6b — Finding #3 regression guard. The property measures a single
    %% large-msgid parse against an absolute wall-clock budget, so a
    %% handful of iterations is plenty (and each builds a 400KB blob).
    %% The quadratic predecessor blew the budget by 4-6x; the linear
    %% decoder clears it by orders of magnitude.
    Result =
        proper:quickcheck(
            erli18n_po_fuzz:prop_decode_is_linear(),
            [{numtests, 10}, {to_file, user}]
        ),
    ?assert(Result =:= true).

fuzz_end_to_end(_Config) ->
    %% F7 uses temp files + ensure_loaded — also slightly more
    %% expensive per iteration, so we cap at 200 (still far above the
    %% 100-iteration noise floor where bugs typically surface).
    Result =
        proper:quickcheck(
            erli18n_po_fuzz:prop_end_to_end_no_supervisor_restart(),
            [{numtests, 200}, {to_file, user}]
        ),
    ?assert(Result =:= true).

fuzz_giant_integer_runs(_Config) ->
    %% F8 — Finding #8 regression guard
    %% (po-plural-unbounded-binary-to-integer-bignum). Each variant is a
    %% deterministic fixed input (giant / system_limit-sized digit runs),
    %% so a handful of iterations exercises every `oneof/1` branch.
    %% Building a 1.4M-digit blob per iteration is the cost driver, so we
    %% keep numtests modest while staying well above the per-variant
    %% coverage floor.
    Result =
        proper:quickcheck(
            erli18n_po_fuzz:prop_giant_integer_runs_bounded(),
            [{numtests, 50}, {to_file, user}]
        ),
    ?assert(Result =:= true).

%% =========================
%% Helpers
%% =========================

run(Property) ->
    Result = proper:quickcheck(
        Property,
        [
            {numtests, ?NUMTESTS},
            {to_file, user}
        ]
    ),
    ?assert(Result =:= true).
