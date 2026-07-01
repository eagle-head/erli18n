%%% =====================================================================
%%% Property-based tests for `erli18n_negotiate` — the pure locale
%%% negotiation canonicalization / fallback / Accept-Language engine.
%%%
%%% Properties:
%%%   * P-CANON-TOTAL — over arbitrary tag bytes (including oversized,
%%%     mixed-separator, raw-byte tags), `canonicalize/1` returns a binary
%%%     and never raises.
%%%   * P-CANON-IDEMPOTENT — `canonicalize(canonicalize(X)) =:= canonicalize(X)`.
%%%   * P-CANON-SEP-EQUIV — for a bounded clean tag, the all-hyphen and
%%%     all-underscore spellings canonicalize identically (separators are
%%%     equivalent on input).
%%%   * P-AL-TOTAL — over arbitrary header bytes, `parse_accept_language/1`
%%%     returns a `[{binary(), 0..1000}]` list, with every Q in 1..1000
%%%     (q=0 dropped), length =< the range cap, sorted non-increasing.
%%%   * P-BEST-MATCH-MEMBER — `best_match/3` always returns the Default or a
%%%     member of the available list, and never raises.
%%% =====================================================================
-module(erli18n_negotiate_props).

-include_lib("proper/include/proper.hrl").

-export([
    prop_canonicalize_is_total/0,
    prop_canonicalize_idempotent/0,
    prop_separator_equivalence/0,
    prop_parse_accept_language_is_total/0,
    prop_best_match_is_member/0
]).

-export([wild_tag/0, clean_tag/0, header_bytes/0, tag_list/0]).

%% PropEr `?FORALL`/`?LET` generators are statically typed as `term()` by
%% eqwalizer, so every function that binds a generated value to a documented
%% shape (a `binary()` tag/header, a tag/preference list, the token list fed to
%% `iolist_to_binary/1`, a byte fed to a `<<...>>` literal, the list fed to
%% `lists:sublist/2`) carries a static `-eqwalizer({nowarn_function, F/A}).`
%% annotation — the same zero-runtime-dep pattern used in the runtime modules
%% `erli18n_server`/`erli18n_pt_store`. This keeps the suite free of a runtime
%% `eqwalizer` cast helper (and of the `eqwalizer_support` dep).
-eqwalizer({nowarn_function, prop_canonicalize_is_total/0}).
-eqwalizer({nowarn_function, prop_canonicalize_idempotent/0}).
-eqwalizer({nowarn_function, prop_separator_equivalence/0}).
-eqwalizer({nowarn_function, prop_parse_accept_language_is_total/0}).
-eqwalizer({nowarn_function, prop_best_match_is_member/0}).
-eqwalizer({nowarn_function, wild_tag/0}).
-eqwalizer({nowarn_function, tag_token/0}).
-eqwalizer({nowarn_function, clean_tag/0}).
-eqwalizer({nowarn_function, subtag/0}).
-eqwalizer({nowarn_function, header_bytes/0}).
-eqwalizer({nowarn_function, header_token/0}).
-eqwalizer({nowarn_function, bounded_list/2}).
-eqwalizer({nowarn_function, non_empty_bounded_list/2}).

%% =========================
%% Properties
%% =========================

prop_canonicalize_is_total() ->
    ?FORALL(
        TagGen,
        wild_tag(),
        begin
            Tag = TagGen,
            try erli18n_negotiate:canonicalize(Tag) of
                Out when is_binary(Out) -> true;
                Other -> ct_fail("P-CANON-TOTAL non-binary", [Other, Tag])
            catch
                Class:Reason:Stack ->
                    ct_fail("P-CANON-TOTAL crashed", [Class, Reason, Stack, Tag])
            end
        end
    ).

prop_canonicalize_idempotent() ->
    ?FORALL(
        TagGen,
        wild_tag(),
        begin
            Tag = TagGen,
            Once = erli18n_negotiate:canonicalize(Tag),
            Twice = erli18n_negotiate:canonicalize(Once),
            case Once =:= Twice of
                true -> true;
                false -> ct_fail("P-CANON-IDEMPOTENT", [Tag, Once, Twice])
            end
        end
    ).

prop_separator_equivalence() ->
    ?FORALL(
        TagGen,
        clean_tag(),
        begin
            Tag = TagGen,
            Dashed = binary:replace(Tag, ~"_", ~"-", [global]),
            Scored = binary:replace(Tag, ~"-", ~"_", [global]),
            A = erli18n_negotiate:canonicalize(Dashed),
            B = erli18n_negotiate:canonicalize(Scored),
            case A =:= B of
                true -> true;
                false -> ct_fail("P-CANON-SEP-EQUIV", [Tag, Dashed, Scored, A, B])
            end
        end
    ).

prop_parse_accept_language_is_total() ->
    ?FORALL(
        HeaderGen,
        header_bytes(),
        begin
            Header = HeaderGen,
            try erli18n_negotiate:parse_accept_language(Header) of
                List when is_list(List) ->
                    valid_al_output(List) orelse ct_fail("P-AL-TOTAL bad output", [List, Header]);
                Other ->
                    ct_fail("P-AL-TOTAL non-list", [Other, Header])
            catch
                Class:Reason:Stack ->
                    ct_fail("P-AL-TOTAL crashed", [Class, Reason, Stack, Header])
            end
        end
    ).

prop_best_match_is_member() ->
    ?FORALL(
        {PrefGen, AvailGen},
        {tag_list(), tag_list()},
        begin
            Pref = PrefGen,
            Avail = AvailGen,
            Default = ~"und",
            try erli18n_negotiate:best_match(Pref, Avail, Default) of
                R when is_binary(R) ->
                    (R =:= Default orelse lists:member(R, Avail)) orelse
                        ct_fail("P-BEST-MATCH not a member", [R, Pref, Avail]);
                Other ->
                    ct_fail("P-BEST-MATCH non-binary", [Other, Pref, Avail])
            catch
                Class:Reason:Stack ->
                    ct_fail("P-BEST-MATCH crashed", [Class, Reason, Stack, Pref, Avail])
            end
        end
    ).

%% =========================
%% Output validators (plain functions)
%% =========================

%% Every entry is {binary(), 1..1000}; the list is at most 32 long and sorted
%% by non-increasing Q (q=0 entries are dropped, so Q is strictly positive).
valid_al_output(List) ->
    length(List) =< 32 andalso
        lists:all(
            fun
                ({R, Q}) when is_binary(R), is_integer(Q), Q >= 1, Q =< 1000 -> true;
                (_) -> false
            end,
            List
        ) andalso non_increasing([Q || {_R, Q} <- List]).

non_increasing([]) -> true;
non_increasing([_]) -> true;
non_increasing([A, B | Rest]) when A >= B -> non_increasing([B | Rest]);
non_increasing(_) -> false.

ct_fail(Label, Args) ->
    ct:pal("~s: ~p~n", [Label, Args]),
    false.

%% =========================
%% Generators
%% =========================

%% Arbitrary tag bytes biased toward the BCP-47 alphabet plus separators and
%% the POSIX charset/modifier suffix markers, with occasional raw bytes. May
%% be oversized or have many subtags (exercises the fail-soft bounds).
wild_tag() ->
    ?LET(Toks, list(tag_token()), iolist_to_binary(Toks)).

tag_token() ->
    frequency([
        {6, ?LET(C, oneof([$a, $b, $z, $A, $Z, $i, $w]), <<C>>)},
        {3, ?LET(D, oneof([$0, $1, $9]), <<D>>)},
        {3, ~"-"},
        {3, ~"_"},
        {1, ~"."},
        {1, ~"@"},
        {1, ?LET(Byte, range(0, 255), <<Byte>>)}
    ]).

%% A bounded, well-formed-ish tag: 1..6 subtags of 1..4 ALPHA/DIGIT bytes,
%% joined by a single (random) separator, so it stays within the canonicalize
%% bounds and the separator-equivalence property is meaningful.
clean_tag() ->
    ?LET(
        Subtags,
        non_empty_bounded_list(subtag(), 6),
        iolist_to_binary(lists:join(~"-", Subtags))
    ).

subtag() ->
    ?LET(Chars, non_empty_bounded_list(alnum(), 4), list_to_binary(Chars)).

alnum() ->
    oneof([$a, $b, $c, $x, $z, $0, $1, $9]).

%% Arbitrary Accept-Language header bytes biased toward the header grammar.
header_bytes() ->
    ?LET(Toks, list(header_token()), iolist_to_binary(Toks)).

header_token() ->
    frequency([
        {5, ?LET(C, oneof([$e, $n, $p, $t, $d, $a, $r, $-]), <<C>>)},
        {3, ~","},
        {3, ~";"},
        {2, ~"q="},
        {2, ?LET(D, oneof([$0, $1, $2, $5, $8, $9, $.]), <<D>>)},
        {2, ~" "},
        {1, ~"*"},
        {1, ?LET(Byte, range(0, 255), <<Byte>>)}
    ]).

%% A small list of tags (preference or available set).
tag_list() ->
    bounded_list(some_tag(), 6).

some_tag() ->
    oneof([
        ~"pt",
        ~"pt_BR",
        ~"pt-BR",
        ~"en",
        ~"en-US",
        ~"zh_Hant_TW",
        ~"iw",
        ~"*",
        ~"de_AT"
    ]).

%% PropEr `list/1` with an upper bound on length (resize keeps it small).
bounded_list(Gen, Max) ->
    ?LET(L, list(Gen), lists:sublist(L, Max)).

non_empty_bounded_list(Gen, Max) ->
    ?LET(L, non_empty(list(Gen)), lists:sublist(L, Max)).
