-module(rebar3_erli18n_jaro).

-moduledoc """
Jaro-similarity fuzzy matcher for msgmerge-style merge.

When `merge` finds a msgid in the old catalog that no longer appears in the
freshly extracted `.pot`, it tries to pair it with a NEW msgid (one present
in the new `.pot` but absent from the old catalog) so the translator's work
can carry over as a `#, fuzzy` entry instead of being lost to `#~` obsolete.
The pairing uses `string:jaro_similarity/2` (stdlib, OTP 27+), comparing
each removed msgid against each added msgid.

A pair is accepted only when its similarity is at or above the threshold
(default `0.8`, matching GNU `msgmerge`'s fuzzy heuristic spirit). Among
candidates above the threshold the highest score wins; ties break
deterministically on the candidate's position in the supplied list (earlier
wins), so the result never depends on map iteration order.

The comparison is bounded: O(|removed| x |added|) similarity calls, each over
two bounded strings — there is no catalog cross-product beyond that.
""".

-export([best_match/2, best_match/3, similarity/2]).

-define(DEFAULT_THRESHOLD, 0.8).

-doc """
Find the best fuzzy match for `Needle` among `Candidates`, default threshold.

Equivalent to `best_match(Needle, Candidates, 0.8)`.
""".
-spec best_match(binary(), [binary()]) -> {ok, binary(), float()} | nomatch.
best_match(Needle, Candidates) ->
    best_match(Needle, Candidates, ?DEFAULT_THRESHOLD).

-doc """
Find the best fuzzy match for `Needle` among `Candidates` at `Threshold`.

Returns `{ok, Match, Score}` for the highest-scoring candidate whose
similarity is `>= Threshold`, breaking ties toward the earlier candidate in
the list. Returns `nomatch` when no candidate reaches the threshold (or the
list is empty).
""".
-spec best_match(binary(), [binary()], float()) -> {ok, binary(), float()} | nomatch.
best_match(Needle, Candidates, Threshold) when is_binary(Needle), is_float(Threshold) ->
    Scored = [{similarity(Needle, C), C} || C <- Candidates],
    Eligible = [SC || {S, _} = SC <- Scored, S >= Threshold],
    case Eligible of
        [] ->
            nomatch;
        _ ->
            %% Highest score wins; on a tie keep the earliest candidate.
            %% `fold` over the in-order list with a strict `>` keeps the
            %% first occurrence of the maximum, which is the deterministic
            %% tie-break we want.
            {BestScore, BestCand} = pick_best(Eligible),
            {ok, BestCand, BestScore}
    end.

-spec pick_best([{float(), binary()}]) -> {float(), binary()}.
pick_best([First | Rest]) ->
    lists:foldl(
        fun({Score, Cand}, {AccScore, _AccCand} = Acc) ->
            case Score > AccScore of
                true -> {Score, Cand};
                false -> Acc
            end
        end,
        First,
        Rest
    ).

-doc """
Jaro similarity of two binaries, in `0.0..1.0`.

A thin wrapper over `string:jaro_similarity/2` that accepts binaries
directly. Two empty strings are defined as fully similar (`1.0`), matching
the stdlib.
""".
-spec similarity(binary(), binary()) -> float().
similarity(A, B) when is_binary(A), is_binary(B) ->
    %% `string:jaro_similarity/2` accepts `unicode:chardata()` directly, and
    %% a binary IS chardata — so the msgids are compared without a lossy
    %% list conversion (which would also force handling an impossible
    %% error-tuple return for these already-valid UTF-8 inputs).
    string:jaro_similarity(A, B).
