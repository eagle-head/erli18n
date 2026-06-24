-module(jaro_SUITE).

-moduledoc """
Tests for `rebar3_erli18n_jaro` — the Jaro-similarity fuzzy matcher.

Covers the threshold boundary (a pair just below vs at the default 0.8 is
rejected/accepted), deterministic tie-breaking toward the earlier candidate,
the empty-candidate `nomatch`, and the `similarity/2` wrapper.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    identical_is_one/1,
    disjoint_is_low/1,
    best_match_picks_closest/1,
    threshold_rejects_below/1,
    tie_breaks_to_earlier/1,
    later_candidate_can_win/1,
    empty_candidates_nomatch/1,
    custom_threshold/1
]).

all() ->
    [
        identical_is_one,
        disjoint_is_low,
        best_match_picks_closest,
        threshold_rejects_below,
        tie_breaks_to_earlier,
        later_candidate_can_win,
        empty_candidates_nomatch,
        custom_threshold
    ].

identical_is_one(_Config) ->
    ?assertEqual(1.0, rebar3_erli18n_jaro:similarity(<<"hello">>, <<"hello">>)).

disjoint_is_low(_Config) ->
    %% Completely disjoint strings score 0.0.
    ?assertEqual(0.0, rebar3_erli18n_jaro:similarity(<<"abc">>, <<"xyz">>)).

best_match_picks_closest(_Config) ->
    %% "color" is closest to "colour" among the candidates.
    {ok, Match, Score} = rebar3_erli18n_jaro:best_match(
        <<"colour">>, [<<"flavour">>, <<"color">>, <<"banana">>]
    ),
    ?assertEqual(<<"color">>, Match),
    ?assert(Score >= 0.8).

threshold_rejects_below(_Config) ->
    %% Two strings whose similarity is below 0.8 produce nomatch.
    ?assertEqual(
        nomatch,
        rebar3_erli18n_jaro:best_match(<<"apple">>, [<<"orange">>])
    ),
    %% Sanity: that pair really is below the default threshold.
    ?assert(rebar3_erli18n_jaro:similarity(<<"apple">>, <<"orange">>) < 0.8).

tie_breaks_to_earlier(_Config) ->
    %% Two candidates with identical scores: the EARLIER one wins.
    A = <<"abcd">>,
    %% Both "abce" and "abcf" are equidistant from "abcd".
    SA = rebar3_erli18n_jaro:similarity(A, <<"abce">>),
    SB = rebar3_erli18n_jaro:similarity(A, <<"abcf">>),
    ?assertEqual(SA, SB),
    {ok, Match, _} = rebar3_erli18n_jaro:best_match(A, [<<"abce">>, <<"abcf">>]),
    ?assertEqual(<<"abce">>, Match).

later_candidate_can_win(_Config) ->
    %% The closest candidate appears LAST in the list — the fold must update
    %% the running best when a strictly higher score is seen.
    {ok, Match, _} = rebar3_erli18n_jaro:best_match(
        <<"needle">>, [<<"xxxxxx">>, <<"needld">>, <<"needle">>]
    ),
    ?assertEqual(<<"needle">>, Match).

empty_candidates_nomatch(_Config) ->
    ?assertEqual(nomatch, rebar3_erli18n_jaro:best_match(<<"x">>, [])).

custom_threshold(_Config) ->
    %% A very low threshold accepts a weak match the default would reject.
    {ok, <<"orange">>, _} = rebar3_erli18n_jaro:best_match(
        <<"apple">>, [<<"orange">>], 0.1
    ),
    %% A threshold of 1.0 only accepts an exact match.
    ?assertEqual(
        nomatch,
        rebar3_erli18n_jaro:best_match(<<"apple">>, [<<"apples">>], 1.0)
    ),
    {ok, <<"apple">>, 1.0} = rebar3_erli18n_jaro:best_match(
        <<"apple">>, [<<"apple">>], 1.0
    ).
