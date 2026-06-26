%%% =====================================================================
%%% Common Test suite for `erli18n_negotiate` — the pure Phase 2
%%% canonicalization / fallback-chain / Accept-Language negotiation engine.
%%%
%%% The module holds no state, so these cases need no running application:
%%% they assert the canonicalization truth table, RFC 4647 Lookup chain
%%% construction, RFC 9110 Accept-Language parsing (q-values, ordering,
%%% fail-soft), negotiation/best-match, the anti-DoS at-limit boundaries,
%%% and the atom-safety invariant (no untrusted input is ever interned).
%%% =====================================================================
-module(erli18n_negotiate_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0
]).

-export([
    canonicalize_truth_table/1,
    canonicalize_aliases/1,
    canonicalize_alias_language_subtag_only/1,
    canonicalize_idempotent/1,
    canonicalize_failsoft_bounds/1,
    fallback_chain_truth_table/1,
    fallback_chain_default_undefined/1,
    fallback_chain_dedup/1,
    fallback_chain_oversized_is_opaque/1,
    fallback_chain_default_floor_at_cap/1,
    override_chain_basic/1,
    negotiate_bounds_preference_list/1,
    accept_language_rfc_example/1,
    accept_language_qvalues/1,
    accept_language_ordering_stable/1,
    accept_language_failsoft/1,
    accept_language_at_limits/1,
    negotiate_basic/1,
    negotiate_casing_preserved/1,
    negotiate_legacy_alias/1,
    negotiate_accept_language_lookup/1,
    negotiate_nomatch/1,
    negotiate_default/1,
    best_match_wildcard_skip/1,
    best_match_first_available_wins/1,
    available_index_contract/1,
    available_index_first_occurrence_wins/1,
    negotiate_with_index_matches/1,
    no_atom_interning/1
]).

all() ->
    [
        canonicalize_truth_table,
        canonicalize_aliases,
        canonicalize_alias_language_subtag_only,
        canonicalize_idempotent,
        canonicalize_failsoft_bounds,
        fallback_chain_truth_table,
        fallback_chain_default_undefined,
        fallback_chain_dedup,
        fallback_chain_oversized_is_opaque,
        fallback_chain_default_floor_at_cap,
        override_chain_basic,
        negotiate_bounds_preference_list,
        accept_language_rfc_example,
        accept_language_qvalues,
        accept_language_ordering_stable,
        accept_language_failsoft,
        accept_language_at_limits,
        negotiate_basic,
        negotiate_casing_preserved,
        negotiate_legacy_alias,
        negotiate_accept_language_lookup,
        negotiate_nomatch,
        negotiate_default,
        best_match_wildcard_skip,
        best_match_first_available_wins,
        available_index_contract,
        available_index_first_occurrence_wins,
        negotiate_with_index_matches,
        no_atom_interning
    ].

%% =========================
%% Canonicalization
%% =========================

canonicalize_truth_table(_Config) ->
    Cases = [
        {~"pt-BR", ~"pt_BR"},
        {~"PT_br", ~"pt_BR"},
        {~"zh-hant", ~"zh_Hant"},
        {~"zh-Hant-TW", ~"zh_Hant_TW"},
        {~"zh-hant-tw", ~"zh_Hant_TW"},
        {~"ca_ES@valencia", ~"ca_ES"},
        {~"pt_BR.UTF-8", ~"pt_BR"},
        {~"en", ~"en"},
        {~"sh", ~"sh"},
        {~"no", ~"no"},
        {~"nb", ~"nb"},
        {~"tl", ~"tl"},
        {~"zh-CN", ~"zh_CN"},
        {~"i-klingon", ~"i_klingon"},
        {~"es-419", ~"es_419"}
    ],
    [
        ?assertEqual(Expected, erli18n_negotiate:canonicalize(Input))
     || {Input, Expected} <- Cases
    ],
    ok.

canonicalize_aliases(_Config) ->
    Cases = [
        {~"in", ~"id"},
        {~"iw", ~"he"},
        {~"ji", ~"yi"},
        {~"jw", ~"jv"},
        {~"mo", ~"ro"},
        {~"iw-IL", ~"he_IL"},
        {~"IW_il", ~"he_IL"}
    ],
    [
        ?assertEqual(Expected, erli18n_negotiate:canonicalize(Input))
     || {Input, Expected} <- Cases
    ],
    ok.

canonicalize_alias_language_subtag_only(_Config) ->
    %% `iw` is an alias only when it is the language (subtag 0). As a region
    %% it must NOT be rewritten (it is just uppercased).
    ?assertEqual(~"xx_IW", erli18n_negotiate:canonicalize(~"xx-iw")),
    ?assertEqual(~"en_IN", erli18n_negotiate:canonicalize(~"en-in")),
    ok.

canonicalize_idempotent(_Config) ->
    Inputs = [
        ~"pt-BR",
        ~"PT_br",
        ~"zh-hant-tw",
        ~"iw-IL",
        ~"ca_ES@valencia",
        ~"EN",
        ~"es-419"
    ],
    [
        ?assertEqual(
            erli18n_negotiate:canonicalize(I),
            erli18n_negotiate:canonicalize(erli18n_negotiate:canonicalize(I))
        )
     || I <- Inputs
    ],
    ok.

canonicalize_failsoft_bounds(_Config) ->
    %% Empty -> unchanged.
    ?assertEqual(<<>>, erli18n_negotiate:canonicalize(<<>>)),
    %% Exactly at the 35-byte cap is processed.
    At = binary:copy(~"a", 35),
    ?assertEqual(At, erli18n_negotiate:canonicalize(At)),
    %% One over the cap -> returned unchanged (not processed).
    Over = binary:copy(~"A", 36),
    ?assertEqual(Over, erli18n_negotiate:canonicalize(Over)),
    %% 8 subtags processed; 9 subtags -> returned unchanged.
    Eight = ~"a-b-c-d-e-f-g-HH",
    ?assertEqual(~"a_b_c_d_e_f_g_HH", erli18n_negotiate:canonicalize(Eight)),
    Nine = ~"a-b-c-d-e-f-g-h-i",
    ?assertEqual(Nine, erli18n_negotiate:canonicalize(Nine)),
    ok.

%% =========================
%% Fallback chain
%% =========================

fallback_chain_truth_table(_Config) ->
    Cases = [
        {~"pt-BR", ~"en", [~"pt_BR", ~"pt", ~"en"]},
        {~"zh_Hant_TW", ~"en", [~"zh_Hant_TW", ~"zh_Hant", ~"zh", ~"en"]},
        {~"iw_IL", ~"en", [~"he_IL", ~"he", ~"en"]},
        {~"en", ~"en", [~"en"]},
        {~"pt", ~"pt", [~"pt"]}
    ],
    [
        ?assertEqual(Expected, erli18n_negotiate:fallback_chain(Locale, Default))
     || {Locale, Default, Expected} <- Cases
    ],
    ok.

fallback_chain_default_undefined(_Config) ->
    ?assertEqual([~"pt_BR", ~"pt"], erli18n_negotiate:fallback_chain(~"pt-BR", undefined)),
    ?assertEqual([~"en"], erli18n_negotiate:fallback_chain(~"en", undefined)),
    ok.

fallback_chain_dedup(_Config) ->
    %% Default already present in the truncation chain is not duplicated.
    ?assertEqual([~"pt_BR", ~"pt"], erli18n_negotiate:fallback_chain(~"pt_BR", ~"pt")),
    %% The chain is strictly shortening and duplicate-free.
    Chain = erli18n_negotiate:fallback_chain(~"zh_Hant_TW", ~"zh"),
    ?assertEqual([~"zh_Hant_TW", ~"zh_Hant", ~"zh"], Chain),
    ?assertEqual(length(Chain), length(lists:usort(Chain))),
    ok.

fallback_chain_oversized_is_opaque(_Config) ->
    %% canonicalize/1 returns an over-?MAX_TAG_BYTES tag unchanged, and
    %% fallback_chain/2 must NOT feed it into the per-level truncation scan
    %% (which would be O(n^2)). A pathological many-separator tag yields a
    %% bounded chain (the opaque tag + the default) in negligible time.
    Huge = binary:copy(~"a_", 8000),
    {Micros, ChainNoDef} = timer:tc(fun() -> erli18n_negotiate:fallback_chain(Huge, undefined) end),
    ?assertEqual([Huge], ChainNoDef),
    ?assertEqual([Huge, ~"en"], erli18n_negotiate:fallback_chain(Huge, ~"en")),
    %% Bounded: well under a second even at 16 KB (pre-fix this was ~600 ms).
    ?assert(Micros < 200000),
    ok.

fallback_chain_default_floor_at_cap(_Config) ->
    %% A tag whose truncation prefix alone fills ?MAX_CHAIN (8) must still end
    %% in the Default floor (the "ends in Default" contract holds at the cap).
    Chain = erli18n_negotiate:fallback_chain(~"a-b-c-d-e-f-g-h", ~"zz"),
    ?assert(length(Chain) =< 8),
    ?assertEqual(~"a_b_c_d_e_f_g_h", hd(Chain)),
    ?assertEqual(~"zz", lists:last(Chain)),
    ok.

override_chain_basic(_Config) ->
    %% Explicit-override chain: canonicalized override list prefixed by the
    %% locale and floored by the default, bounded by the SAME ?MAX_CHAIN.
    ?assertEqual(
        [~"de_AT", ~"de", ~"en"],
        erli18n_negotiate:override_chain(~"de-AT", [~"de"], ~"en")
    ),
    %% Override entries are canonicalized (hyphenated override still matches).
    ?assertEqual(
        [~"de_AT", ~"pt_BR", ~"en"],
        erli18n_negotiate:override_chain(~"de_AT", [~"pt-BR"], ~"en")
    ),
    %% Bounded at ?MAX_CHAIN (8) even for an over-long override list.
    Long = [integer_to_binary(I) || I <- lists:seq(1, 50)],
    ?assert(length(erli18n_negotiate:override_chain(~"de", Long, ~"en")) =< 8),
    ok.

negotiate_bounds_preference_list(_Config) ->
    %% An over-cap preference entry is skipped (it cannot match a canonical
    %% catalog key), and a valid sibling still resolves.
    Huge = binary:copy(~"a_", 8000),
    ?assertEqual({ok, ~"pt"}, erli18n_negotiate:negotiate([Huge, ~"pt-BR"], [~"pt"])),
    %% The preference list is bounded by a per-CONSUMED-cell budget (?MAX_RANGES,
    %% 32 cells inspected max): every inspected cell — accepted, wildcard-skipped,
    %% or oversized-skipped — decrements it. A real match within the first 32 cells
    %% still resolves.
    NearPrefs = lists:duplicate(30, ~"*") ++ [~"pt"],
    ?assertEqual({ok, ~"pt"}, erli18n_negotiate:negotiate(NearPrefs, [~"pt"])),
    %% A real match that appears only AFTER the 32-cell budget is exhausted (here
    %% behind 5000 wildcard cells) is correctly unreachable — that IS the anti-DoS
    %% contract — and the bounded scan still terminates quickly regardless of the
    %% input length.
    Prefs = lists:duplicate(5000, ~"*") ++ [~"pt"],
    {Micros, Res} = timer:tc(fun() -> erli18n_negotiate:negotiate(Prefs, [~"pt"]) end),
    ?assertEqual(error, Res),
    ?assert(Micros < 200000),
    ok.

%% =========================
%% Accept-Language parsing
%% =========================

accept_language_rfc_example(_Config) ->
    %% RFC 9110 §12.5.4 worked example.
    ?assertEqual(
        [{~"da", 1000}, {~"en-gb", 800}, {~"en", 700}],
        erli18n_negotiate:parse_accept_language(~"da, en-gb;q=0.8, en;q=0.7")
    ),
    ok.

accept_language_qvalues(_Config) ->
    %% Absent q -> 1000.
    ?assertEqual([{~"de", 1000}], erli18n_negotiate:parse_accept_language(~"de")),
    %% q=0.9 -> 900; q=0.85 -> 850; q=0.005 -> 5.
    ?assertEqual([{~"de", 900}], erli18n_negotiate:parse_accept_language(~"de;q=0.9")),
    ?assertEqual([{~"de", 850}], erli18n_negotiate:parse_accept_language(~"de;q=0.85")),
    ?assertEqual([{~"de", 5}], erli18n_negotiate:parse_accept_language(~"de;q=0.005")),
    %% Exact q=1 -> 1000 (full weight, kept).
    ?assertEqual([{~"de", 1000}], erli18n_negotiate:parse_accept_language(~"de;q=1")),
    %% Well-formed q=0 -> dropped (including the empty-fraction `q=0.`).
    ?assertEqual([], erli18n_negotiate:parse_accept_language(~"de;q=0")),
    ?assertEqual([], erli18n_negotiate:parse_accept_language(~"de;q=0.000")),
    ?assertEqual([], erli18n_negotiate:parse_accept_language(~"de;q=0.")),
    %% Malformed q -> full weight (1000), entry kept.
    ?assertEqual([{~"de", 1000}], erli18n_negotiate:parse_accept_language(~"de;q=1.5")),
    ?assertEqual([{~"de", 1000}], erli18n_negotiate:parse_accept_language(~"de;q=abc")),
    ?assertEqual([{~"de", 1000}], erli18n_negotiate:parse_accept_language(~"de;q=")),
    %% Malformed FRACTION (non-digit after `0.`) -> full weight.
    ?assertEqual([{~"de", 1000}], erli18n_negotiate:parse_accept_language(~"de;q=0.a")),
    %% Case-insensitive q key; OWS tolerated.
    ?assertEqual([{~"de", 800}], erli18n_negotiate:parse_accept_language(~"  de ; Q=0.8 ")),
    %% Range lowercased; wildcard retained.
    ?assertEqual([{~"en-us", 1000}], erli18n_negotiate:parse_accept_language(~"EN-US")),
    ?assertEqual([{~"*", 500}], erli18n_negotiate:parse_accept_language(~"*;q=0.5")),
    ok.

accept_language_ordering_stable(_Config) ->
    %% Descending q; ties keep header order.
    ?assertEqual(
        [{~"da", 1000}, {~"x", 1000}, {~"en", 700}],
        erli18n_negotiate:parse_accept_language(~"da, , en;q=0.7, x;q=1.5")
    ),
    %% A lower-q entry that appears first still sorts after higher-q ones.
    ?assertEqual(
        [{~"fr", 1000}, {~"en", 900}, {~"de", 100}],
        erli18n_negotiate:parse_accept_language(~"de;q=0.1, en;q=0.9, fr")
    ),
    ok.

accept_language_failsoft(_Config) ->
    ?assertEqual([], erli18n_negotiate:parse_accept_language(<<>>)),
    ?assertEqual([], erli18n_negotiate:parse_accept_language(~"   ")),
    ?assertEqual([], erli18n_negotiate:parse_accept_language(~",,,")),
    %% Garbage characters in a range -> that element skipped, not a crash.
    ?assertEqual([{~"en", 1000}], erli18n_negotiate:parse_accept_language(~"en, #bad!, ")),
    ok.

accept_language_at_limits(_Config) ->
    %% Header exactly at 4096 bytes parses; 4097 -> [].
    Body4096 = build_header_bytes(4096),
    ?assert(erli18n_negotiate:parse_accept_language(Body4096) =/= []),
    Body4097 = <<Body4096/binary, $x>>,
    ?assertEqual(4097, byte_size(Body4097)),
    ?assertEqual([], erli18n_negotiate:parse_accept_language(Body4097)),
    %% 64 comma elements OK; 65 -> [].
    H64 = join_commas(lists:duplicate(64, ~"en")),
    ?assert(erli18n_negotiate:parse_accept_language(H64) =/= []),
    H65 = join_commas(lists:duplicate(65, ~"en")),
    ?assertEqual([], erli18n_negotiate:parse_accept_language(H65)),
    %% Accepted-range budget caps at 32 (distinct ranges so none dedup away).
    Many = join_commas([<<"a", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 40)]),
    ?assertEqual(32, length(erli18n_negotiate:parse_accept_language(Many))),
    %% A range over 35 bytes is skipped; a sibling within bounds survives.
    Long = binary:copy(~"a", 36),
    ?assertEqual(
        [{~"en", 1000}],
        erli18n_negotiate:parse_accept_language(<<Long/binary, ", en">>)
    ),
    ok.

%% =========================
%% Negotiation
%% =========================

negotiate_basic(_Config) ->
    ?assertEqual({ok, ~"pt"}, erli18n_negotiate:negotiate([~"pt-BR"], [~"pt", ~"en"])),
    ?assertEqual(
        {ok, ~"pt_BR"}, erli18n_negotiate:negotiate([~"pt_BR"], [~"pt_BR", ~"pt"])
    ),
    ok.

negotiate_casing_preserved(_Config) ->
    %% A canonicalized preference matches a catalog key in any input casing,
    %% and the ORIGINAL available casing is returned.
    ?assertEqual({ok, ~"pt_BR"}, erli18n_negotiate:negotiate([~"PT_br"], [~"pt_BR"])),
    ?assertEqual({ok, ~"pt-br"}, erli18n_negotiate:negotiate([~"pt-BR"], [~"pt-br"])),
    ok.

negotiate_legacy_alias(_Config) ->
    ?assertEqual({ok, ~"he"}, erli18n_negotiate:negotiate([~"iw"], [~"he", ~"en"])),
    ok.

negotiate_accept_language_lookup(_Config) ->
    %% Feed the parsed header straight into negotiate; en-gb truncates to en.
    Pref = erli18n_negotiate:parse_accept_language(~"da, en-gb;q=0.8, en;q=0.7"),
    ?assertEqual({ok, ~"en"}, erli18n_negotiate:negotiate(Pref, [~"en"])),
    ok.

negotiate_nomatch(_Config) ->
    ?assertEqual(error, erli18n_negotiate:negotiate([~"zh_Hant"], [~"en", ~"pt"])),
    ok.

negotiate_default(_Config) ->
    ?assertEqual({ok, ~"en"}, erli18n_negotiate:negotiate([~"zh"], [~"pt"], ~"en")),
    ?assertEqual(~"en", erli18n_negotiate:best_match([~"en-US"], [~"en"], ~"x")),
    ok.

best_match_wildcard_skip(_Config) ->
    %% A '*' range does not force-pick an arbitrary available locale.
    ?assertEqual(~"en", erli18n_negotiate:best_match([{~"*", 1000}], [~"de"], ~"en")),
    ?assertEqual(error, erli18n_negotiate:negotiate([~"*"], [~"de"])),
    ok.

best_match_first_available_wins(_Config) ->
    %% Two available entries canonicalizing to the same key: the first wins.
    ?assertEqual(
        {ok, ~"pt-BR"},
        erli18n_negotiate:negotiate([~"pt_BR"], [~"pt-BR", ~"pt_BR"])
    ),
    ok.

%% =========================
%% Prebuilt available index (available_index/1 + negotiate_with_index/2)
%% =========================

available_index_contract(_Config) ->
    %% available_index/1 builds a canonical -> original map: it IS a map, keyed by
    %% the canonicalized form, valued by the original catalog casing.
    Index = erli18n_negotiate:available_index([~"pt-BR", ~"fr", ~"en"]),
    ?assert(is_map(Index)),
    ?assertEqual(#{~"pt_BR" => ~"pt-BR", ~"fr" => ~"fr", ~"en" => ~"en"}, Index),
    %% An empty available set yields the empty index.
    ?assertEqual(#{}, erli18n_negotiate:available_index([])),
    ok.

available_index_first_occurrence_wins(_Config) ->
    %% Two entries canonicalizing to the SAME key: the FIRST occurrence's original
    %% casing is the one kept in the index (first-occurrence-wins).
    Index = erli18n_negotiate:available_index([~"pt-BR", ~"pt_BR"]),
    ?assertEqual(#{~"pt_BR" => ~"pt-BR"}, Index),
    %% That first-occurrence original is what a later match returns.
    ?assertEqual(
        {ok, ~"pt-BR"},
        erli18n_negotiate:negotiate_with_index([~"pt_BR"], Index)
    ),
    ok.

negotiate_with_index_matches(_Config) ->
    %% negotiate_with_index/2 against a PREBUILT index returns {ok, OriginalCasing}
    %% for several preference lists, and error on no match — matching negotiate/2's
    %% semantics but hoisting the index out of the per-candidate loop.
    Index = erli18n_negotiate:available_index([~"pt_BR", ~"en"]),
    %% Exact canonical hit.
    ?assertEqual({ok, ~"pt_BR"}, erli18n_negotiate:negotiate_with_index([~"pt-BR"], Index)),
    %% Base-language fallback (en-US -> en).
    ?assertEqual({ok, ~"en"}, erli18n_negotiate:negotiate_with_index([~"en-US"], Index)),
    %% First acceptable preference wins over a later one.
    ?assertEqual(
        {ok, ~"en"},
        erli18n_negotiate:negotiate_with_index([~"zh", ~"en", ~"pt-BR"], Index)
    ),
    %% No match -> error.
    ?assertEqual(error, erli18n_negotiate:negotiate_with_index([~"zh_Hant"], Index)),
    %% Result is identical to building the index inline via negotiate/2.
    ?assertEqual(
        erli18n_negotiate:negotiate([~"pt-BR"], [~"pt_BR", ~"en"]),
        erli18n_negotiate:negotiate_with_index([~"pt-BR"], Index)
    ),
    ok.

%% =========================
%% Atom safety (anti-DoS)
%% =========================

no_atom_interning(_Config) ->
    %% Feeding many DISTINCT hostile tags/headers must not grow the atom
    %% table — locales stay binaries, never `binary_to_atom`.
    Before = erlang:system_info(atom_count),
    _ = [
        erli18n_negotiate:canonicalize(<<"zz", (integer_to_binary(I))/binary, "-XX">>)
     || I <- lists:seq(1, 2000)
    ],
    _ = [
        erli18n_negotiate:parse_accept_language(<<"l", (integer_to_binary(I))/binary, ";q=0.5">>)
     || I <- lists:seq(1, 2000)
    ],
    _ = erli18n_negotiate:negotiate(
        [<<"q", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 500)],
        [<<"r", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 500)]
    ),
    After = erlang:system_info(atom_count),
    ?assertEqual(Before, After),
    ok.

%% =========================
%% Helpers
%% =========================

%% Build a valid Accept-Language header of EXACTLY N bytes as a SINGLE
%% element (a short range padded with trailing OWS), so the byte-size
%% boundary is exercised without tripping the element-count cap.
build_header_bytes(N) when N >= 2 ->
    <<"en", (binary:copy(~" ", N - 2))/binary>>.

join_commas(Elems) ->
    iolist_to_binary(lists:join(~",", Elems)).
