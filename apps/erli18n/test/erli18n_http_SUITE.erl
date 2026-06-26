%%% =====================================================================
%%% Common Test suite for `erli18n_http` — the pure, framework-agnostic
%%% request-localization core shared by the Cowboy and Elli adapters.
%%%
%%% The module holds no state and touches no framework, so these cases need
%%% no running application: they assert the source precedence, the
%%% canonicalization / base-language fallback delegated to erli18n_negotiate,
%%% the unsupported -> default path, totality over malformed candidates, and
%%% the total/fail-soft cookie-header parser (extraction, trimming, the
%%% split-once value rule, and the anti-DoS bounds).
%%% =====================================================================
-module(erli18n_http_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).

-export([
    header_source_wins/1,
    precedence_query_over_cookie_over_header/1,
    cookie_over_header_when_no_query/1,
    configurable_source_order/1,
    canonicalization_matches_underscored_catalog/1,
    base_language_fallback/1,
    qzero_range_excluded/1,
    unsupported_falls_to_default/1,
    empty_and_undefined_sources_skipped/1,
    malformed_candidate_skipped_is_total/1,
    empty_available_is_default/1,
    cookie_value_basic/1,
    cookie_value_absent/1,
    cookie_value_undefined_header/1,
    cookie_value_empty_header/1,
    cookie_value_whitespace_trimmed/1,
    cookie_value_splits_once/1,
    cookie_value_malformed_pair_skipped/1,
    cookie_value_oversized_is_undefined/1,
    cookie_value_quoted_unquoted/1,
    cookie_value_non_utf8_is_total/1,
    cookie_value_pairs_boundary/1,
    cookie_value_bytes_boundary/1,
    cookie_value_semicolon_flood_bounded/1,
    query_value_basic/1,
    query_value_undefined_raw/1,
    query_value_absent_key/1,
    query_value_valueless_key_skipped/1,
    query_value_percent_decoded/1,
    query_value_malformed_escape_skipped/1,
    query_value_first_match_malformed_then_valid/1,
    query_value_oversized_is_undefined/1,
    query_value_bytes_boundary/1,
    query_value_pairs_boundary/1,
    query_value_ampersand_flood_bounded/1,
    query_value_non_utf8_value_is_total/1,
    lazy_short_circuit_stops_after_first_hit/1,
    lazy_thunks_forced_minimally/1,
    lazy_index_reused_across_candidates/1,
    available_index_once_result_invariant/1
]).

%% This case deliberately feeds non-binary / non-tuple candidate values to prove
%% totality; eqwalizer (correctly) cannot type that ill-formed input, so the
%% documented nowarn idiom applies to this one function.
-eqwalizer({nowarn_function, malformed_candidate_skipped_is_total/1}).

all() ->
    [
        header_source_wins,
        precedence_query_over_cookie_over_header,
        cookie_over_header_when_no_query,
        configurable_source_order,
        canonicalization_matches_underscored_catalog,
        base_language_fallback,
        qzero_range_excluded,
        unsupported_falls_to_default,
        empty_and_undefined_sources_skipped,
        malformed_candidate_skipped_is_total,
        empty_available_is_default,
        cookie_value_basic,
        cookie_value_absent,
        cookie_value_undefined_header,
        cookie_value_empty_header,
        cookie_value_whitespace_trimmed,
        cookie_value_splits_once,
        cookie_value_malformed_pair_skipped,
        cookie_value_oversized_is_undefined,
        cookie_value_quoted_unquoted,
        cookie_value_non_utf8_is_total,
        cookie_value_pairs_boundary,
        cookie_value_bytes_boundary,
        cookie_value_semicolon_flood_bounded,
        query_value_basic,
        query_value_undefined_raw,
        query_value_absent_key,
        query_value_valueless_key_skipped,
        query_value_percent_decoded,
        query_value_malformed_escape_skipped,
        query_value_first_match_malformed_then_valid,
        query_value_oversized_is_undefined,
        query_value_bytes_boundary,
        query_value_pairs_boundary,
        query_value_ampersand_flood_bounded,
        query_value_non_utf8_value_is_total,
        lazy_short_circuit_stops_after_first_hit,
        lazy_thunks_forced_minimally,
        lazy_index_reused_across_candidates,
        available_index_once_result_invariant
    ].

%% =========================
%% negotiate_locale/3
%% =========================

header_source_wins(_Config) ->
    ?assertEqual(
        {~"fr", header},
        erli18n_http:negotiate_locale(
            [{header, ~"fr;q=0.9, de;q=0.5"}], [~"fr", ~"de"], ~"en"
        )
    ),
    ok.

precedence_query_over_cookie_over_header(_Config) ->
    %% All three supply a different supported locale; query (highest) wins.
    Candidates = [{query, ~"fr"}, {cookie, ~"de"}, {header, ~"pt-BR"}],
    Available = [~"fr", ~"de", ~"pt_BR"],
    ?assertEqual({~"fr", query}, erli18n_http:negotiate_locale(Candidates, Available, ~"en")),
    ok.

cookie_over_header_when_no_query(_Config) ->
    Candidates = [{query, undefined}, {cookie, ~"de"}, {header, ~"fr"}],
    Available = [~"fr", ~"de"],
    ?assertEqual({~"de", cookie}, erli18n_http:negotiate_locale(Candidates, Available, ~"en")),
    ok.

configurable_source_order(_Config) ->
    %% With header placed first, the header wins even though a cookie is present.
    Candidates = [{header, ~"fr"}, {cookie, ~"de"}],
    Available = [~"fr", ~"de"],
    ?assertEqual({~"fr", header}, erli18n_http:negotiate_locale(Candidates, Available, ~"en")),
    ok.

canonicalization_matches_underscored_catalog(_Config) ->
    %% A hyphenated single-value override matches an underscored catalog key.
    ?assertEqual(
        {~"pt_BR", cookie},
        erli18n_http:negotiate_locale([{cookie, ~"pt-BR"}], [~"pt_BR"], ~"en")
    ),
    ok.

base_language_fallback(_Config) ->
    %% pt_BR requested, only pt loaded -> RFC 4647 Lookup falls back to pt.
    ?assertEqual(
        {~"pt", cookie},
        erli18n_http:negotiate_locale([{cookie, ~"pt_BR"}], [~"pt"], ~"en")
    ),
    ok.

qzero_range_excluded(_Config) ->
    %% q=0 marks a range as not acceptable; the parser drops it, so de loses.
    ?assertEqual(
        {~"fr", header},
        erli18n_http:negotiate_locale([{header, ~"de;q=0, fr"}], [~"de", ~"fr"], ~"en")
    ),
    ok.

unsupported_falls_to_default(_Config) ->
    Candidates = [{query, ~"ja"}, {cookie, ~"ko"}, {header, ~"zh-CN"}],
    ?assertEqual(
        {~"en", default},
        erli18n_http:negotiate_locale(Candidates, [~"fr", ~"de"], ~"en")
    ),
    ok.

empty_and_undefined_sources_skipped(_Config) ->
    %% undefined and <<>> are skipped; the header is reached.
    Candidates = [{query, undefined}, {cookie, ~""}, {header, ~"fr"}],
    ?assertEqual({~"fr", header}, erli18n_http:negotiate_locale(Candidates, [~"fr"], ~"en")),
    ok.

malformed_candidate_skipped_is_total(_Config) ->
    %% A non-binary candidate value is skipped (totality), not a crash; the
    %% next well-formed candidate still resolves.
    Candidates = [{query, 123}, {cookie, an_atom}, {header, ~"fr"}],
    ?assertEqual({~"fr", header}, erli18n_http:negotiate_locale(Candidates, [~"fr"], ~"en")),
    %% A wholly malformed list still yields the default.
    ?assertEqual(
        {~"en", default},
        erli18n_http:negotiate_locale([not_a_tuple, {query, 1}], [~"fr"], ~"en")
    ),
    ok.

empty_available_is_default(_Config) ->
    ?assertEqual(
        {~"en", default},
        erli18n_http:negotiate_locale([{header, ~"fr"}], [], ~"en")
    ),
    ok.

%% =========================
%% cookie_value/2
%% =========================

cookie_value_basic(_Config) ->
    ?assertEqual(
        ~"pt_BR",
        erli18n_http:cookie_value(~"sid=abc; locale=pt_BR; theme=dark", ~"locale")
    ),
    ok.

cookie_value_absent(_Config) ->
    ?assertEqual(undefined, erli18n_http:cookie_value(~"sid=abc; theme=dark", ~"locale")),
    ok.

cookie_value_undefined_header(_Config) ->
    ?assertEqual(undefined, erli18n_http:cookie_value(undefined, ~"locale")),
    ok.

cookie_value_empty_header(_Config) ->
    ?assertEqual(undefined, erli18n_http:cookie_value(~"", ~"locale")),
    ok.

cookie_value_whitespace_trimmed(_Config) ->
    ?assertEqual(~"fr", erli18n_http:cookie_value(~"  locale = fr  ", ~"locale")),
    ok.

cookie_value_splits_once(_Config) ->
    %% Only the first '=' separates name from value; '=' in the value is kept.
    ?assertEqual(~"a=b", erli18n_http:cookie_value(~"locale=a=b", ~"locale")),
    ok.

cookie_value_malformed_pair_skipped(_Config) ->
    %% A pair with no '=' is skipped; a later valid pair is still found.
    ?assertEqual(~"fr", erli18n_http:cookie_value(~"badpair; locale=fr", ~"locale")),
    ok.

cookie_value_oversized_is_undefined(_Config) ->
    %% Beyond the 8 KiB bound the header is treated as empty (anti-DoS).
    Big = binary:copy(~"x", 9000),
    Header = <<"locale=fr; ", Big/binary>>,
    ?assertEqual(undefined, erli18n_http:cookie_value(Header, ~"locale")),
    ok.

cookie_value_quoted_unquoted(_Config) ->
    %% RFC 6265 §4.1.1 allows a DQUOTE-wrapped cookie-value; exactly one
    %% surrounding pair is stripped.
    ?assertEqual(~"pt_BR", erli18n_http:cookie_value(~"locale=\"pt_BR\"", ~"locale")),
    %% A lone/unbalanced quote is NOT stripped (only a matched surrounding pair).
    ?assertEqual(~"\"pt", erli18n_http:cookie_value(~"locale=\"pt", ~"locale")),
    %% An empty quoted value unquotes to empty.
    ?assertEqual(~"", erli18n_http:cookie_value(~"locale=\"\"", ~"locale")),
    %% A single lone DQUOTE byte (length 1) is below the 2-byte unquote guard, so
    %% it is returned verbatim (the `byte_size(Bin) >= 2` clause is not taken).
    ?assertEqual(~"\"", erli18n_http:cookie_value(~"locale=\"", ~"locale")),
    ok.

cookie_value_non_utf8_is_total(_Config) ->
    %% Raw high bytes as the matched value: returns a binary, never raises.
    H1 = <<"locale=", 16#FF, 16#FE, "; x=y">>,
    R1 = erli18n_http:cookie_value(H1, ~"locale"),
    ?assert(is_binary(R1)),
    ?assertEqual(<<16#FF, 16#FE>>, R1),
    %% High bytes ADJACENT to a matched value (the surrounding OWS scan must not
    %% interpret them as UTF-8): still total, value preserved verbatim.
    H2 = <<"locale= ", 16#FF, "fr", 16#FE, " ; y=z">>,
    R2 = erli18n_http:cookie_value(H2, ~"locale"),
    ?assert(is_binary(R2)),
    ?assertEqual(<<16#FF, "fr", 16#FE>>, R2),
    ok.

cookie_value_pairs_boundary(_Config) ->
    %% Build "p1=v1; p2=v2; ...". With the target at pair 64 it is found; at
    %% pair 65 it is dropped (only the first 64 pairs are parsed). Total bytes
    %% stay well under the 8 KiB byte bound, so the pair bound is what is tested.
    Filler = fun(N) ->
        iolist_to_binary(
            lists:join(
                ~"; ",
                [<<"p", (integer_to_binary(I))/binary, "=v">> || I <- lists:seq(1, N)]
            )
        )
    end,
    %% target is pair 64
    Within = <<(Filler(63))/binary, "; locale=fr">>,
    ?assertEqual(~"fr", erli18n_http:cookie_value(Within, ~"locale")),
    %% target is pair 65
    Beyond = <<(Filler(64))/binary, "; locale=fr">>,
    ?assertEqual(undefined, erli18n_http:cookie_value(Beyond, ~"locale")),
    ok.

cookie_value_bytes_boundary(_Config) ->
    %% At-limit byte boundary: exactly 8192 bytes parses and finds the locale;
    %% exactly 8193 bytes trips the anti-DoS guard and yields undefined. One pair
    %% is well under the 64-pair cap, so only the byte cap is under test.
    Pair = ~"locale=fr",
    AtLimit = pad_to(Pair, 8192),
    ?assertEqual(8192, byte_size(AtLimit)),
    ?assertEqual(~"fr", erli18n_http:cookie_value(AtLimit, ~"locale")),
    OverLimit = pad_to(Pair, 8193),
    ?assertEqual(8193, byte_size(OverLimit)),
    ?assertEqual(undefined, erli18n_http:cookie_value(OverLimit, ~"locale")),
    ok.

cookie_value_semicolon_flood_bounded(_Config) ->
    %% A semicolon flood under the byte cap is still parsed correctly and fast:
    %% the split is bounded at the split itself, so a hostile header costs
    %% O(?MAX_COOKIE_PAIRS), not O(total length). With the target pair FIRST it is
    %% found within the cap; with the target AFTER the flood it is dropped (the
    %% flood alone exhausts the 64-pair budget before the target is reached).
    Flood = binary:copy(~";", 500),
    Front = <<"locale=fr", Flood/binary>>,
    ?assert(byte_size(Front) < 8192),
    ?assertEqual(~"fr", erli18n_http:cookie_value(Front, ~"locale")),
    Back = <<Flood/binary, "locale=fr">>,
    ?assertEqual(undefined, erli18n_http:cookie_value(Back, ~"locale")),
    ok.

%% =========================
%% query_value/2 (total, fail-soft raw-query parser)
%% =========================

query_value_basic(_Config) ->
    %% Named value found among several pairs; only the matched key's value wins.
    ?assertEqual(~"pt-BR", erli18n_http:query_value(~"foo=1&locale=pt-BR&bar=2", ~"locale")),
    %% First occurrence of the key wins.
    ?assertEqual(~"a", erli18n_http:query_value(~"locale=a&locale=b", ~"locale")),
    ok.

query_value_undefined_raw(_Config) ->
    %% An absent raw query (undefined) yields undefined.
    ?assertEqual(undefined, erli18n_http:query_value(undefined, ~"locale")),
    ok.

query_value_absent_key(_Config) ->
    %% A present query without the key yields undefined.
    ?assertEqual(undefined, erli18n_http:query_value(~"foo=1&bar=2", ~"locale")),
    %% An empty raw query yields undefined.
    ?assertEqual(undefined, erli18n_http:query_value(~"", ~"locale")),
    ok.

query_value_valueless_key_skipped(_Config) ->
    %% A value-less key (no '=') is skipped, so a later `key=value` still wins.
    ?assertEqual(~"fr", erli18n_http:query_value(~"locale&locale=fr", ~"locale")),
    %% A lone value-less key yields undefined.
    ?assertEqual(undefined, erli18n_http:query_value(~"locale", ~"locale")),
    ok.

query_value_percent_decoded(_Config) ->
    %% `%XX` escapes are decoded; `+` becomes a space (x-www-form-urlencoded).
    ?assertEqual(~"pt-BR", erli18n_http:query_value(~"locale=pt%2DBR", ~"locale")),
    ?assertEqual(<<"a b">>, erli18n_http:query_value(~"locale=a+b", ~"locale")),
    %% Lowercase hex digits decode too.
    ?assertEqual(<<16#ab>>, erli18n_http:query_value(~"locale=%ab", ~"locale")),
    ok.

query_value_malformed_escape_skipped(_Config) ->
    %% A malformed/odd/truncated escape makes the matched value decode to undefined
    %% (fail-soft, never raises), so the source is skipped.
    ?assertEqual(undefined, erli18n_http:query_value(~"locale=%ZZ", ~"locale")),
    ?assertEqual(undefined, erli18n_http:query_value(~"locale=%", ~"locale")),
    ?assertEqual(undefined, erli18n_http:query_value(~"locale=%E0%", ~"locale")),
    %% A lone '%' as the whole query (value-less key path is not reached; the key
    %% has no '=' so it is simply skipped).
    ?assertEqual(undefined, erli18n_http:query_value(~"%", ~"locale")),
    %% A non-matching key with a malformed escape is irrelevant; a later valid
    %% match still wins (the malformed one is in a different key).
    ?assertEqual(~"fr", erli18n_http:query_value(~"x=%ZZ&locale=fr", ~"locale")),
    ok.

query_value_first_match_malformed_then_valid(_Config) ->
    %% The FIRST occurrence of the key has a malformed escape (decodes to
    %% undefined); lookup continues and a later valid occurrence is returned.
    ?assertEqual(~"fr", erli18n_http:query_value(~"locale=%ZZ&locale=fr", ~"locale")),
    ok.

query_value_oversized_is_undefined(_Config) ->
    %% Beyond the 8 KiB byte cap the whole raw query is treated as empty (anti-DoS).
    Big = binary:copy(~"x", 9000),
    Raw = <<"locale=fr&", Big/binary>>,
    ?assertEqual(undefined, erli18n_http:query_value(Raw, ~"locale")),
    ok.

query_value_bytes_boundary(_Config) ->
    %% Exactly 8192 bytes parses and finds the locale; exactly 8193 trips the cap.
    Pair = ~"locale=fr",
    AtLimit = pad_query_to(Pair, 8192),
    ?assertEqual(8192, byte_size(AtLimit)),
    ?assertEqual(~"fr", erli18n_http:query_value(AtLimit, ~"locale")),
    OverLimit = pad_query_to(Pair, 8193),
    ?assertEqual(8193, byte_size(OverLimit)),
    ?assertEqual(undefined, erli18n_http:query_value(OverLimit, ~"locale")),
    ok.

query_value_pairs_boundary(_Config) ->
    %% With the target at pair 64 it is found; at pair 65 it is dropped (only the
    %% first 64 `&`-segments are scanned). Total bytes stay under the byte cap.
    Filler = fun(N) ->
        iolist_to_binary(
            lists:join(
                ~"&",
                [<<"p", (integer_to_binary(I))/binary, "=v">> || I <- lists:seq(1, N)]
            )
        )
    end,
    Within = <<(Filler(63))/binary, "&locale=fr">>,
    ?assertEqual(~"fr", erli18n_http:query_value(Within, ~"locale")),
    Beyond = <<(Filler(64))/binary, "&locale=fr">>,
    ?assertEqual(undefined, erli18n_http:query_value(Beyond, ~"locale")),
    ok.

query_value_ampersand_flood_bounded(_Config) ->
    %% An '&' flood under the byte cap is parsed correctly and fast: with the
    %% target FIRST it is found within the pair cap; with the target AFTER the
    %% flood it is dropped (the flood exhausts the 64-pair budget first).
    Flood = binary:copy(~"&", 500),
    Front = <<"locale=fr", Flood/binary>>,
    ?assert(byte_size(Front) < 8192),
    ?assertEqual(~"fr", erli18n_http:query_value(Front, ~"locale")),
    Back = <<Flood/binary, "locale=fr">>,
    ?assertEqual(undefined, erli18n_http:query_value(Back, ~"locale")),
    ok.

query_value_non_utf8_value_is_total(_Config) ->
    %% A percent-encoded high byte decodes to that raw byte verbatim; never raises.
    R = erli18n_http:query_value(~"locale=%FF%FE", ~"locale"),
    ?assert(is_binary(R)),
    ?assertEqual(<<16#FF, 16#FE>>, R),
    ok.

%% =========================
%% negotiate_locale_lazy/4
%% =========================

lazy_short_circuit_stops_after_first_hit(_Config) ->
    %% An earlier-precedence source that yields a supported locale must STOP the
    %% walk: the later sources are never extracted. A recording extract fun sends
    %% each extracted source to the test mailbox; only `query` must appear.
    Self = self(),
    Extract = fun(Source) ->
        Self ! {extracted, Source},
        case Source of
            query -> ~"fr";
            cookie -> ~"de";
            header -> ~"pt-BR"
        end
    end,
    {Locale, Won} = erli18n_http:negotiate_locale_lazy(
        [query, cookie, header],
        Extract,
        fun() -> [~"fr", ~"de", ~"pt_BR"] end,
        fun() -> ~"en" end
    ),
    ?assertEqual(~"fr", Locale),
    ?assertEqual(query, Won),
    ?assertEqual([query], drain_extracted()),
    ok.

lazy_thunks_forced_minimally(_Config) ->
    %% The Available thunk is forced at most once (only on the first non-empty
    %% source value) and the Default thunk at most once (only on a total miss).
    AvailCtr = counters:new(1, []),
    DefCtr = counters:new(1, []),
    AvailThunk = fun() ->
        counters:add(AvailCtr, 1, 1),
        [~"fr"]
    end,
    DefThunk = fun() ->
        counters:add(DefCtr, 1, 1),
        ~"en"
    end,
    %% First source undefined (skipped: Available NOT yet forced), second matches.
    Extract = fun
        (query) -> undefined;
        (cookie) -> ~"fr"
    end,
    {~"fr", cookie} = erli18n_http:negotiate_locale_lazy(
        [query, cookie], Extract, AvailThunk, DefThunk
    ),
    ?assertEqual(1, counters:get(AvailCtr, 1)),
    ?assertEqual(0, counters:get(DefCtr, 1)),
    %% Total miss: Available forced once (on the value), Default forced once.
    Extract2 = fun(_) -> ~"ja" end,
    {~"en", default} = erli18n_http:negotiate_locale_lazy(
        [query, cookie], Extract2, AvailThunk, DefThunk
    ),
    ?assertEqual(2, counters:get(AvailCtr, 1)),
    ?assertEqual(1, counters:get(DefCtr, 1)),
    ok.

lazy_index_reused_across_candidates(_Config) ->
    %% The canonical Available index is built ONCE and reused: the first source
    %% yields a value that MISSES (forcing the index), the second yields a value
    %% that HITS against the SAME index. The Available thunk is forced exactly
    %% once across both candidates (the ensure_index `{index, _}` reuse arm).
    AvailCtr = counters:new(1, []),
    AvailThunk = fun() ->
        counters:add(AvailCtr, 1, 1),
        [~"de"]
    end,
    Extract = fun
        (query) -> ~"ja";
        (cookie) -> ~"de"
    end,
    {~"de", cookie} = erli18n_http:negotiate_locale_lazy(
        [query, cookie], Extract, AvailThunk, fun() -> ~"en" end
    ),
    ?assertEqual(1, counters:get(AvailCtr, 1)),
    ok.

available_index_once_result_invariant(_Config) ->
    %% The available-index-once refactor must not change negotiation results
    %% across multi-candidate inputs: a multi-candidate miss-then-hit and a
    %% single-candidate base-language match both resolve as before.
    Avail = [~"pt_BR", ~"fr", ~"de"],
    ?assertEqual(
        {~"de", cookie},
        erli18n_http:negotiate_locale(
            [{query, ~"ja"}, {cookie, ~"de"}, {header, ~"pt-BR"}], Avail, ~"en"
        )
    ),
    ?assertEqual(
        {~"pt_BR", header},
        erli18n_http:negotiate_locale([{header, ~"pt-BR"}], Avail, ~"en")
    ),
    ok.

%% =========================
%% Helpers
%% =========================

%% Grow a "name=value" cookie pair to exactly N bytes by appending a padding
%% pair, so the byte-cap boundary can be hit precisely with the value intact.
pad_to(Pair, N) ->
    Prefix = <<Pair/binary, "; x=">>,
    PadLen = N - byte_size(Prefix),
    <<Prefix/binary, (binary:copy(~"x", PadLen))/binary>>.

%% Query analogue of pad_to/2: grow a "key=value" query pair to exactly N bytes by
%% appending an `&`-delimited padding pair, hitting the byte-cap boundary precisely
%% with the value intact.
pad_query_to(Pair, N) ->
    Prefix = <<Pair/binary, "&x=">>,
    PadLen = N - byte_size(Prefix),
    <<Prefix/binary, (binary:copy(~"x", PadLen))/binary>>.

%% Drain the recorded {extracted, Source} messages in order; [] once empty.
drain_extracted() ->
    receive
        {extracted, S} -> [S | drain_extracted()]
    after 0 -> []
    end.
