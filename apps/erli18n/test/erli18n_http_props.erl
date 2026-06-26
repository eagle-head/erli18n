%%% =====================================================================
%%% Property-based tests for `erli18n_http` — the pure request-localization
%%% core shared by the web adapters.
%%%
%%% Properties:
%%%   * P-NEG-TOTAL — over arbitrary candidate lists (including `undefined`,
%%%     empty, and malformed entries), arbitrary available sets, and an
%%%     arbitrary default, `negotiate_locale/3` returns `{binary(), atom()}`,
%%%     never raises, and the chosen locale is always a member of
%%%     `[Default | Available]`.
%%%   * P-COOKIE-TOTAL — over arbitrary `Cookie` header bytes (and
%%%     `undefined`), `cookie_value/2` returns a `binary()` or `undefined` and
%%%     never raises.
%%%   * P-QUERY-TOTAL — over arbitrary raw query bytes (and `undefined`),
%%%     including malformed percent-escapes, `&`-floods, and oversize input,
%%%     `query_value/2` returns a `binary()` or `undefined` and never raises.
%%% =====================================================================
-module(erli18n_http_props).

-include_lib("proper/include/proper.hrl").

-export([
    prop_negotiate_locale_is_total/0,
    prop_cookie_value_is_total/0,
    prop_query_value_is_total/0
]).

-export([
    candidates_gen/0,
    candidate_gen/0,
    value_gen/0,
    header_value_gen/0,
    available_gen/0,
    locale_gen/0,
    cookie_header_gen/0,
    cookie_bytes/0,
    cookie_token/0,
    oversize_cookie_bytes/0,
    query_raw_gen/0,
    query_bytes/0,
    query_token/0,
    oversize_query_bytes/0
]).

%% PropEr `?FORALL`/`?LET` generators are statically typed as `term()` by
%% eqwalizer, so each property and each generator that binds a generated value to
%% a documented shape carries a static `-eqwalizer({nowarn_function, F/A}).`
%% annotation — the same pattern used in `erli18n_negotiate_props`.
-eqwalizer({nowarn_function, prop_negotiate_locale_is_total/0}).
-eqwalizer({nowarn_function, prop_cookie_value_is_total/0}).
-eqwalizer({nowarn_function, prop_query_value_is_total/0}).
-eqwalizer({nowarn_function, cookie_bytes/0}).
-eqwalizer({nowarn_function, cookie_token/0}).
-eqwalizer({nowarn_function, oversize_cookie_bytes/0}).
-eqwalizer({nowarn_function, header_value_gen/0}).
-eqwalizer({nowarn_function, header_token/0}).
-eqwalizer({nowarn_function, query_bytes/0}).
-eqwalizer({nowarn_function, query_token/0}).
-eqwalizer({nowarn_function, oversize_query_bytes/0}).

%% =========================
%% Properties
%% =========================

prop_negotiate_locale_is_total() ->
    ?FORALL(
        {Cands, Avail, Def},
        {candidates_gen(), available_gen(), locale_gen()},
        begin
            try erli18n_http:negotiate_locale(Cands, Avail, Def) of
                {Locale, Source} when is_binary(Locale), is_atom(Source) ->
                    lists:member(Locale, [Def | Avail]) orelse
                        ct_fail("P-NEG-TOTAL not a member", [Locale, Avail, Def]);
                Other ->
                    ct_fail("P-NEG-TOTAL bad shape", [Other, Cands])
            catch
                Class:Reason:Stack ->
                    ct_fail("P-NEG-TOTAL crashed", [Class, Reason, Stack, Cands])
            end
        end
    ).

prop_cookie_value_is_total() ->
    ?FORALL(
        {Header, Name},
        {cookie_header_gen(), locale_gen()},
        begin
            try erli18n_http:cookie_value(Header, Name) of
                undefined -> true;
                V when is_binary(V) -> true;
                Other -> ct_fail("P-COOKIE-TOTAL bad output", [Other, Header, Name])
            catch
                Class:Reason:Stack ->
                    ct_fail("P-COOKIE-TOTAL crashed", [Class, Reason, Stack, Header, Name])
            end
        end
    ).

prop_query_value_is_total() ->
    ?FORALL(
        {Raw, Name},
        {query_raw_gen(), locale_gen()},
        begin
            try erli18n_http:query_value(Raw, Name) of
                undefined -> true;
                V when is_binary(V) -> true;
                Other -> ct_fail("P-QUERY-TOTAL bad output", [Other, Raw, Name])
            catch
                Class:Reason:Stack ->
                    ct_fail("P-QUERY-TOTAL crashed", [Class, Reason, Stack, Raw, Name])
            end
        end
    ).

%% =========================
%% Generators
%% =========================

%% A list of candidates, including well-formed pairs and outright garbage
%% elements, to exercise the malformed-skip path and totality.
candidates_gen() ->
    list(candidate_gen()).

candidate_gen() ->
    oneof([
        {oneof([query, cookie, header, path]), value_gen()},
        not_a_tuple,
        7,
        {only_one_element}
    ]).

%% Candidate values: absent, empty, real locales, hyphenated/q-valued strings,
%% non-binary garbage, AND adversarial Accept-Language headers (so the header
%% source is driven with hostile input — oversized, many-comma, random/invalid
%% UTF-8 bytes, malformed q-values — not just hand-picked well-formed strings).
value_gen() ->
    oneof([
        undefined,
        ~"",
        locale_gen(),
        ~"pt-BR",
        ~"fr;q=0.9, de;q=0.5",
        42,
        an_atom,
        header_value_gen()
    ]).

%% An adversarial Accept-Language header value. Mirrors the cookie_bytes /
%% oversize_cookie_bytes posture so the negotiation header path
%% (parse_accept_language -> to_locale_list -> canonicalize) is exercised with
%% hostile input: an oversized header (> the parser's caps), a many-comma flood,
%% random/invalid-UTF-8 bytes, and malformed q-values.
header_value_gen() ->
    frequency([
        {4, ?LET(Toks, list(header_token()), iolist_to_binary(Toks))},
        %% Many-comma flood (drives the pre-split / range budget).
        {2, ?LET(N, range(1, 6000), binary:copy(~"en,", N))},
        %% Guaranteed-oversized header so the parser's byte/element caps are hit.
        {1,
            ?LET(
                Tail,
                ?LET(Toks, list(header_token()), iolist_to_binary(Toks)),
                <<(binary:copy(~"a-", 5000))/binary, Tail/binary>>
            )}
    ]).

%% Tokens biased toward the Accept-Language grammar (tags, ',', ';q=', spaces),
%% with malformed q-values and occasional raw bytes (including invalid UTF-8).
header_token() ->
    frequency([
        {5, ?LET(C, oneof([$e, $n, $f, $r, $d, $p, $t, $-, $_]), <<C>>)},
        {3, ~", "},
        {2, oneof([~";q=0.9", ~";q=", ~";q=abc", ~";q=1.5", ~";q=0.a"])},
        {2, ~" "},
        {1, ?LET(Byte, range(0, 255), <<Byte>>)}
    ]).

available_gen() ->
    list(locale_gen()).

locale_gen() ->
    oneof([~"en", ~"fr", ~"de", ~"pt", ~"pt_BR", ~"ja"]).

%% A raw Cookie header: absent, or arbitrary bytes biased toward the cookie
%% grammar (names, '=', ';', spaces) with occasional raw bytes and oversize.
cookie_header_gen() ->
    frequency([
        {1, undefined},
        {8, cookie_bytes()},
        {1, oversize_cookie_bytes()}
    ]).

cookie_bytes() ->
    ?LET(Toks, list(cookie_token()), iolist_to_binary(Toks)).

%% A guaranteed-oversize (> the 8192-byte cookie bound) header so the anti-DoS
%% byte-bound `undefined` branch of cookie_value/2 is actually exercised — this
%% makes the "occasional ... oversize" claim above true rather than aspirational.
%% A leading well-formed `locale=fr` pair before the padding ensures the branch
%% is taken on a header that would otherwise have matched.
oversize_cookie_bytes() ->
    ?LET(
        Tail,
        cookie_bytes(),
        <<"locale=fr; ", (binary:copy(~"x", 8200))/binary, Tail/binary>>
    ).

cookie_token() ->
    frequency([
        {6, ?LET(C, oneof([$a, $l, $o, $c, $e, $s, $i, $d]), <<C>>)},
        {3, ~"="},
        {3, ~"; "},
        {2, ~" "},
        {1, ?LET(Byte, range(0, 255), <<Byte>>)}
    ]).

%% A raw query string: absent, or arbitrary bytes biased toward the query grammar
%% (`key=value` pairs, `&`, `+`, percent-escapes — well-formed AND malformed) with
%% occasional raw bytes and oversize, paralleling the cookie generators so the new
%% query_value/2 path is driven with hostile input.
query_raw_gen() ->
    frequency([
        {1, undefined},
        {8, query_bytes()},
        {1, oversize_query_bytes()}
    ]).

query_bytes() ->
    ?LET(Toks, list(query_token()), iolist_to_binary(Toks)).

%% A guaranteed-oversize (> the 8192-byte query bound) raw query so the anti-DoS
%% byte-bound `undefined` branch of query_value/2 is actually exercised. A leading
%% well-formed `locale=fr` pair before the padding ensures the branch is taken on
%% input that would otherwise have matched.
oversize_query_bytes() ->
    ?LET(
        Tail,
        query_bytes(),
        <<"locale=fr&", (binary:copy(~"x", 8200))/binary, Tail/binary>>
    ).

query_token() ->
    frequency([
        {5, ?LET(C, oneof([$l, $o, $c, $a, $e, $f, $r, $1]), <<C>>)},
        {3, ~"="},
        {3, ~"&"},
        {2, ~"+"},
        %% Percent-escapes: well-formed AND malformed (`%ZZ`, lone `%`, truncated).
        {2, oneof([~"%2D", ~"%ab", ~"%FF", ~"%ZZ", ~"%", ~"%E0%", ~"%G"])},
        {1, ?LET(Byte, range(0, 255), <<Byte>>)}
    ]).

%% =========================
%% Helpers
%% =========================

ct_fail(Label, Args) ->
    ct:pal("~s: ~p~n", [Label, Args]),
    false.
