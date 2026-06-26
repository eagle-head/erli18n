-module(erli18n_http).

-moduledoc """
Framework-agnostic core for per-request locale negotiation.

This module holds ALL the negotiation logic shared by the optional web adapters
`erli18n_cowboy` and `erli18n_elli`, so the adapters stay thin (they only extract
raw request values and apply the result) and a single tested implementation backs
both. It is **pure**: no process-dictionary writes, no logging, no I/O — the
side effects (`erli18n:setlocale/1`, logger metadata) live in the adapters. That
keeps this module total and property-testable without a running web server.

## What it does

`negotiate_locale/3` resolves the request locale from an ordered list of
candidate sources, applying a configurable precedence and falling back to a
default. The default precedence used by both adapters is **query > cookie >
Accept-Language header > default**, mirroring i18next-http-middleware's default
order and Django's "explicit beats persisted beats browser-preferred" spirit
(see the Django locale-discovery docs in References).

Each source is tried in order; the first one that yields a *supported* locale
wins. Matching is delegated to `erli18n_negotiate`:

- a `header` value (a raw `Accept-Language` binary) goes through
  `erli18n_negotiate:parse_accept_language/1` (RFC 9110 §12.5.4 q-values,
  fail-soft) and then `erli18n_negotiate:negotiate/2`;
- a single-value source (`query`, `cookie`, `path`) is `canonicalize/1`-d
  (so a hyphenated `pt-BR` matches an underscored `pt_BR` catalog key) and then
  matched the same way, which also gives the BCP-47 base-language fallback
  (`pt_BR` → `pt`) for free.

The single locale value an adapter feeds for the `query` source is itself
extracted in-module by the total `query_value/2` (see "## Query parsing"): both
adapters hand it the **raw** query binary from the framework's non-raising
accessor and let this module decode it, rather than delegating to the
framework's own raising query decoder.

`erli18n_negotiate:negotiate/2` returns `{ok, Locale}` on a hit and `error` on a
miss, which is exactly what lets this module tell "this source matched" apart
from "fall through to the next source". On a total miss the configured `Default`
is returned with the source tag `default`.

## Cookie parsing

`cookie_value/2` extracts a single named cookie from a raw `Cookie` header
binary. Both adapters use it rather than the framework's own cookie parser:
Cowboy's `cowboy_req:parse_cookies/1` raises on malformed cookies, and Elli ships
no cookie parser at all. This parser is total and fail-soft (a malformed pair is
skipped, never raised) and is bounded against abuse, matching the anti-DoS
posture of `erli18n_negotiate`. A DQUOTE-wrapped cookie-value (RFC 6265 §4.1.1,
e.g. `locale="pt_BR"`) has its single surrounding double-quote pair stripped.

## Query parsing

`query_value/2` extracts a single named query parameter from a raw query-string
binary (the part after `?`, without the leading `?`). Both adapters use it rather
than the framework's own query decoder: Cowboy's `cowboy_req:parse_qs/1`
(via `cow_qs:parse_qs/1`) raises on a malformed percent-escape (`?x=%ZZ`, a bare
`?%`, a truncated `?a=%E0%`), and Elli's decoded accessor raises likewise. Both
adapters instead feed the **raw** query binary from the framework's total
accessor (Cowboy's `cowboy_req:qs/1`, Elli's `elli_request:query_str/1` — neither
raises) and let this module decode it. The parser is total and fail-soft and
shares the cookie parser's anti-DoS posture: it is byte-capped
(> 8 KiB raw query is treated as absent) and its `&`-split is bounded
(`take_segments/2`, dropping the unscanned tail past the pair cap). Percent
(`%XX`) escapes and the `application/x-www-form-urlencoded` `+`-as-space rule are
decoded in-module by a **total** `percent_decode/1`; an invalid, odd, or
truncated escape makes the matched value fail-soft to `undefined` (the source is
skipped) rather than raising. A value-less key (`?locale`, no `=`) and an absent
key both yield `undefined`.

## References

- RFC 9110 §12.5.4 (Accept-Language): <https://www.rfc-editor.org/rfc/rfc9110.html#section-12.5.4>
- RFC 6265 §4.2 (Cookie header syntax): <https://www.rfc-editor.org/rfc/rfc6265.html#section-4.2>
- Django locale discovery: <https://docs.djangoproject.com/en/stable/topics/i18n/translation/>
- `erli18n_negotiate` — the negotiation/canonicalization engine this delegates to.
""".

-export([negotiate_locale/3, negotiate_locale_lazy/4, cookie_value/2, query_value/2]).

-export_type([source/0, candidate/0, candidates/0, extract_fun/0, thunk/1]).

%% =========================
%% Types
%% =========================

-doc """
Where a candidate locale was read from. `query`/`cookie`/`path` carry a single
already-extracted locale value; `header` carries a raw `Accept-Language` header
binary. `default` is never an input — it is the source tag
`negotiate_locale/3` returns when every candidate misses.
""".
-type source() :: query | cookie | header | path.

-doc """
A single candidate: the source and its raw value (or `undefined`/`<<>>` when the
request did not supply it, in which case the candidate is skipped).
""".
-type candidate() :: {source(), binary() | undefined}.

-doc "An ordered list of candidates, highest precedence first.".
-type candidates() :: [candidate()].

-doc """
An extraction callback: given a `source()`, returns that source's raw candidate
value from the request, or `undefined`/`<<>>` when the request does not supply
it. The ONLY impure part of `negotiate_locale_lazy/4` — it is the adapter's seam
to the framework request; everything else in this module stays pure.
`negotiate_locale_lazy/4` calls it AT MOST ONCE per source and stops at the
first source that yields a supported locale, so a higher-precedence winner means
the later sources are never extracted.
""".
-type extract_fun() :: fun((source()) -> binary() | undefined).

-doc """
A zero-arity thunk deferring an expensive lookup so it is evaluated only when
actually needed. `negotiate_locale_lazy/4` forces the `Available` thunk at most
once (on the first non-empty source value) and the `Default` thunk at most once
(only on a total miss), so an explicitly-supplied available/default the adapter
already has in hand costs nothing.
""".
-type thunk(T) :: fun(() -> T).

%% Anti-DoS bounds for cookie-header parsing (aligned with erli18n_negotiate).
-define(MAX_COOKIE_BYTES, 8192).
-define(MAX_COOKIE_PAIRS, 64).

%% Anti-DoS bounds for query-string parsing (same posture as the cookie caps).
-define(MAX_QUERY_BYTES, 8192).
-define(MAX_QUERY_PAIRS, 64).

%% =========================
%% Negotiation
%% =========================

-doc """
Resolves the request locale from `Candidates` (highest precedence first) against
the `Available` locale set, falling back to `Default`.

Each candidate is tried in order. A candidate whose value is `undefined` or empty
is skipped. A `header` value is parsed with
`erli18n_negotiate:parse_accept_language/1`; any other source's value is
`erli18n_negotiate:canonicalize/1`-d. The candidate's preference is matched
against `Available` with `erli18n_negotiate:negotiate/2`; the first `{ok, Locale}`
wins. If every candidate misses, `{Default, default}` is returned.

Returns `{Locale, Source}` — the chosen locale plus which source produced it
(`default` on total miss), so callers can log/emit which signal won. Callers that
only need the locale take `element(1, _)`.

Total and fail-soft: it never raises on arbitrary `Candidates` values (the
delegated `erli18n_negotiate` functions are themselves total), and on a total
miss it falls back to `Default` rather than raising — the returned locale is
always a member of `Available` or equal to `Default`.

```erlang
1> erli18n_http:negotiate_locale(
..     [{query, undefined}, {cookie, <<"pt-BR">>}, {header, <<"fr;q=0.9">>}],
..     [<<"pt_BR">>, <<"fr">>], <<"en">>).
{<<"pt_BR">>, cookie}
2> erli18n_http:negotiate_locale([{header, <<"de">>}], [<<"fr">>], <<"en">>).
{<<"en">>, default}
```
""".
-spec negotiate_locale(candidates(), [erli18n_negotiate:locale()], erli18n_negotiate:locale()) ->
    {erli18n_negotiate:locale(), source() | default}.
negotiate_locale(Candidates, Available, Default) when
    is_list(Candidates), is_list(Available), is_binary(Default)
->
    %% Eager-list form: the caller already holds every value, so the Available
    %% index is built once (the first non-empty candidate forces it) and Default
    %% is a constant thunk. Sources are the candidate tags in order; the extract
    %% fun reads the matching candidate value from the supplied list, preserving
    %% the existing skip-`undefined`/`<<>>`/malformed-entry totality.
    Sources = [Source || {Source, _Value} <- Candidates, is_atom(Source)],
    Extract = fun(Source) -> candidate_lookup(Source, Candidates) end,
    negotiate_locale_lazy(Sources, Extract, fun() -> Available end, fun() -> Default end).

%% First candidate value for `Source` in the list, or `undefined`. Mirrors the
%% old per-element skip: a malformed (non-`{source, value}`) entry contributes no
%% source tag and is never looked up.
-spec candidate_lookup(source(), candidates()) -> binary() | undefined.
candidate_lookup(Source, Candidates) ->
    case lists:keyfind(Source, 1, Candidates) of
        {Source, Value} when is_binary(Value) -> Value;
        _NoneOrNonBinary -> undefined
    end.

-doc """
Lazy, short-circuiting variant of `negotiate_locale/3` for the per-request hot
path.

Walks `Sources` in order and, for each, calls `Extract(Source)` to obtain that
source's raw value ONLY when the source is reached — so once an
earlier-precedence source yields a supported locale, the later sources are never
extracted (no cookie split, no header parse for a request a query already
answered). `AvailableThunk` is forced at most once, on the first source that
yields a non-empty value (the available index is then built once and reused for
every remaining candidate); `DefaultThunk` is forced at most once, only when
every source misses. So an adapter that already holds `available`/`default`
passes `fun() -> Value end` and pays nothing extra.

Returns `{Locale, Source}` exactly like `negotiate_locale/3` (`default` on total
miss). Pure apart from the supplied `Extract` callback (no `setlocale`, no
logger, no framework calls). Total and fail-soft: a non-binary or empty
extracted value is skipped, the delegated `erli18n_negotiate` functions never
raise, and the result is always a member of the available set or equal to the
default.

`negotiate_locale/3` is `negotiate_locale_lazy/4` with an eager candidate list:
the list form stays the supported API for callers that already have all values.
""".
-spec negotiate_locale_lazy(
    [source()],
    extract_fun(),
    thunk([erli18n_negotiate:locale()]),
    thunk(erli18n_negotiate:locale())
) -> {erli18n_negotiate:locale(), source() | default}.
negotiate_locale_lazy(Sources, Extract, AvailableThunk, DefaultThunk) when
    is_list(Sources),
    is_function(Extract, 1),
    is_function(AvailableThunk, 0),
    is_function(DefaultThunk, 0)
->
    lazy_loop(Sources, Extract, AvailableThunk, DefaultThunk, no_index).

%% Walk the sources lazily. `IndexState` is `no_index` until the first non-empty
%% source value forces `AvailableThunk` and builds the canonical index once; from
%% then on it is `{index, Index}` and reused for every remaining candidate. On a
%% total miss the `DefaultThunk` is forced exactly once.
-spec lazy_loop(
    [source()],
    extract_fun(),
    thunk([erli18n_negotiate:locale()]),
    thunk(erli18n_negotiate:locale()),
    no_index | {index, erli18n_negotiate:available_index()}
) -> {erli18n_negotiate:locale(), source() | default}.
lazy_loop([], _Extract, _AvailableThunk, DefaultThunk, _IndexState) ->
    {DefaultThunk(), default};
lazy_loop([Source | Rest], Extract, AvailableThunk, DefaultThunk, IndexState0) ->
    case Extract(Source) of
        Value when is_binary(Value), Value =/= <<>> ->
            {Index, IndexState1} = ensure_index(IndexState0, AvailableThunk),
            case erli18n_negotiate:negotiate_with_index(preferred(Source, Value), Index) of
                {ok, Locale} ->
                    {Locale, Source};
                error ->
                    lazy_loop(Rest, Extract, AvailableThunk, DefaultThunk, IndexState1)
            end;
        _SkipEmptyOrMalformed ->
            lazy_loop(Rest, Extract, AvailableThunk, DefaultThunk, IndexState0)
    end.

%% Force/memoize the available index: built at most once per call regardless of
%% how many sources are tried.
-spec ensure_index(
    no_index | {index, erli18n_negotiate:available_index()},
    thunk([erli18n_negotiate:locale()])
) -> {erli18n_negotiate:available_index(), {index, erli18n_negotiate:available_index()}}.
ensure_index({index, Index}, _AvailableThunk) ->
    {Index, {index, Index}};
ensure_index(no_index, AvailableThunk) ->
    Index = erli18n_negotiate:available_index(AvailableThunk()),
    {Index, {index, Index}}.

%% The header carries an Accept-Language list (q-values); every other source
%% carries a single locale value to canonicalize into a one-element preference.
-spec preferred(source(), binary()) ->
    [erli18n_negotiate:locale()]
    | [{erli18n_negotiate:language_range(), erli18n_negotiate:qvalue()}].
preferred(header, Value) ->
    erli18n_negotiate:parse_accept_language(Value);
preferred(_Other, Value) ->
    [erli18n_negotiate:canonicalize(Value)].

%% =========================
%% Cookie extraction
%% =========================

-doc """
Extracts the value of the named cookie from a raw `Cookie` header binary, or
`undefined` if the header is absent/empty or the cookie is not present.

Used by both adapters instead of the framework's own cookie parser (Cowboy's
raises on malformed input; Elli has none). Total and fail-soft: a malformed
`name=value` pair is skipped. Two distinct anti-DoS caps apply (the same stance
as `erli18n_negotiate`):

- the **byte cap** (> 8 KiB, `?MAX_COOKIE_BYTES`) treats the whole header as
  empty — the result is `undefined` without scanning any pair;
- the **pair cap** (`?MAX_COOKIE_PAIRS` = 64) bounds the `;`-split and DROPS the
  unscanned tail past the 64th pair (`take_segments/2`); it does NOT empty the
  cookie — pairs within the cap are still parsed and returned, so a named cookie
  appearing among the first 64 pairs is found normally.

```erlang
1> erli18n_http:cookie_value(<<"sid=abc; locale=pt_BR; theme=dark">>, <<"locale">>).
<<"pt_BR">>
2> erli18n_http:cookie_value(undefined, <<"locale">>).
undefined
```
""".
-spec cookie_value(binary() | undefined, binary()) -> binary() | undefined.
cookie_value(undefined, _Name) ->
    undefined;
cookie_value(Raw, _Name) when byte_size(Raw) > ?MAX_COOKIE_BYTES ->
    undefined;
cookie_value(Raw, Name) when is_binary(Raw), is_binary(Name) ->
    Pairs = parse_cookie_header(Raw),
    lookup_cookie(Pairs, Name).

-spec lookup_cookie([{binary(), binary()}], binary()) -> binary() | undefined.
lookup_cookie([], _Name) ->
    undefined;
lookup_cookie([{Name, Value} | _Rest], Name) ->
    Value;
lookup_cookie([_Other | Rest], Name) ->
    lookup_cookie(Rest, Name).

%% Split "a=1; b=2; ..." into [{<<"a">>,<<"1">>}, ...], bounded and fail-soft.
%% The split is itself bounded: `take_segments/2` peels at most
%% `?MAX_COOKIE_PAIRS` leading `;`-delimited segments via single (non-global)
%% `binary:split/2` calls and DROPS the rest unscanned — so a hostile header with
%% thousands of semicolons under the byte cap costs O(?MAX_COOKIE_PAIRS *
%% avg_pair_len), not O(total length). Pairs without a "=" are skipped;
%% surrounding whitespace is trimmed. For any input within the 64-pair cap the
%% parsed result is byte-identical to a global split + sublist.
-spec parse_cookie_header(binary()) -> [{binary(), binary()}].
parse_cookie_header(Raw) ->
    Bounded = take_segments(Raw, ?MAX_COOKIE_PAIRS),
    lists:foldr(fun parse_cookie_pair/2, [], Bounded).

%% Peel at most `N` leading `;`-delimited segments, stopping (and discarding the
%% unscanned tail) once the budget is spent. Each step splits at the FIRST `;`
%% only, so total work is bounded by N segments regardless of how many `;` the
%% tail holds. At the cap the final segment is the leading `;`-free head of the
%% remainder, matching `lists:sublist(binary:split(Raw,";",[global]), N)`.
-spec take_segments(binary(), non_neg_integer()) -> [binary()].
take_segments(_Bin, 0) ->
    [];
take_segments(Bin, N) ->
    case binary:split(Bin, [<<";">>]) of
        [Single] -> [Single];
        [Head, Tail] -> [Head | take_segments(Tail, N - 1)]
    end.

-spec parse_cookie_pair(binary(), [{binary(), binary()}]) -> [{binary(), binary()}].
parse_cookie_pair(Segment, Acc) ->
    case binary:split(trim(Segment), [<<"=">>]) of
        [Name, Value] when Name =/= <<>> -> [{trim(Name), unquote(trim(Value))} | Acc];
        _NoEqualsOrEmptyName -> Acc
    end.

%% Strip a single surrounding DQUOTE pair from a cookie value (RFC 6265 §4.1.1
%% allows a DQUOTE-wrapped cookie-value). Byte-level and total: only a value of
%% at least two bytes that both starts and ends with `"` is unwrapped; anything
%% else (including a lone `"` or `"x`) is returned unchanged. Never raises. Runs
%% after `trim/1`, so `locale = "pt_BR"` (OWS then quotes) unwraps correctly.
-spec unquote(binary()) -> binary().
unquote(<<$", Rest/binary>> = Bin) when byte_size(Bin) >= 2 ->
    Last = byte_size(Rest) - 1,
    case binary:at(Rest, Last) of
        $" -> binary:part(Rest, 0, Last);
        _ -> Bin
    end;
unquote(Bin) ->
    Bin.

%% =========================
%% Query extraction
%% =========================

-doc """
Extracts the value of the named query parameter from a raw query-string binary
(the part after `?`, without the leading `?`), or `undefined` if the raw query is
absent/empty, the parameter is not present, or the parameter has no value.

Used by both adapters instead of the framework's own query decoder (Cowboy's
`cowboy_req:parse_qs/1` and Elli's decoded accessor both raise on a malformed
percent-escape). The adapters feed the **raw** query binary from the framework's
total accessor (`cowboy_req:qs/1`, `elli_request:query_str/1`). This parser is
total and fail-soft, sharing the cookie parser's anti-DoS posture: a byte cap
(> 8 KiB raw query yields `undefined`) and a bounded `&`-split that drops the
unscanned tail past the pair cap.

Percent (`%XX`) escapes and the `application/x-www-form-urlencoded` `+`-as-space
rule are decoded in-module by a total `percent_decode/1`. An invalid, odd, or
truncated escape (`%ZZ`, a lone `%`, a truncated `%E0%`) is fail-soft: the
matched value decodes to `undefined` (the source is skipped) rather than raising.
A value-less key (`?locale`, no `=`) and an absent key both yield `undefined`.

```erlang
1> erli18n_http:query_value(<<"foo=1&locale=pt-BR&bar=2">>, <<"locale">>).
<<"pt-BR">>
2> erli18n_http:query_value(<<"locale=%ZZ">>, <<"locale">>).
undefined
3> erli18n_http:query_value(undefined, <<"locale">>).
undefined
```
""".
-spec query_value(binary() | undefined, binary()) -> binary() | undefined.
query_value(undefined, _Name) ->
    undefined;
query_value(Raw, _Name) when byte_size(Raw) > ?MAX_QUERY_BYTES ->
    undefined;
query_value(Raw, Name) when is_binary(Raw), is_binary(Name) ->
    Segments = take_query_segments(Raw, ?MAX_QUERY_PAIRS),
    lookup_query(Segments, Name).

%% Scan the bounded `&`-delimited segments for the FIRST whose key matches `Name`,
%% returning its fail-soft percent-decoded value (or `undefined` if decoding fails
%% or the value is absent). A value-less key (no `=`) is skipped, so a later
%% `Name=value` still wins; an absent key yields `undefined`.
-spec lookup_query([binary()], binary()) -> binary() | undefined.
lookup_query([], _Name) ->
    undefined;
lookup_query([Segment | Rest], Name) ->
    case binary:split(Segment, [<<"=">>]) of
        [Name, RawValue] ->
            case percent_decode(RawValue) of
                undefined -> lookup_query(Rest, Name);
                Value -> Value
            end;
        _NoEqualsOrOtherKey ->
            lookup_query(Rest, Name)
    end.

%% Peel at most `N` leading `&`-delimited segments, dropping the unscanned tail
%% once the budget is spent. Each step splits at the FIRST `&` only, so total work
%% is bounded by N segments regardless of how many `&` the tail holds — the same
%% bounded-split idiom as the cookie `take_segments/2`.
-spec take_query_segments(binary(), non_neg_integer()) -> [binary()].
take_query_segments(_Bin, 0) ->
    [];
take_query_segments(Bin, N) ->
    case binary:split(Bin, [<<"&">>]) of
        [Single] -> [Single];
        [Head, Tail] -> [Head | take_query_segments(Tail, N - 1)]
    end.

%% Total `application/x-www-form-urlencoded` decoder. `+` becomes a space and each
%% `%XX` becomes the byte `XX`; the produced byte sequence is returned verbatim
%% (no UTF-8 validation — a locale value is `canonicalize/1`-d downstream). Returns
%% `undefined` (fail-soft) on any malformed escape: a `%` not followed by two
%% hex digits, including a truncated escape at end-of-input. Never raises.
-spec percent_decode(binary()) -> binary() | undefined.
percent_decode(Bin) ->
    percent_decode(Bin, <<>>).

-spec percent_decode(binary(), binary()) -> binary() | undefined.
percent_decode(<<>>, Acc) ->
    Acc;
percent_decode(<<$%, Hi, Lo, Rest/binary>>, Acc) ->
    case {hex_digit(Hi), hex_digit(Lo)} of
        {HiV, LoV} when is_integer(HiV), is_integer(LoV) ->
            percent_decode(Rest, <<Acc/binary, (HiV * 16 + LoV)>>);
        _NonHex ->
            undefined
    end;
percent_decode(<<$%, _Truncated/binary>>, _Acc) ->
    %% A `%` with fewer than two trailing bytes (lone `%` or `%X`).
    undefined;
percent_decode(<<$+, Rest/binary>>, Acc) ->
    percent_decode(Rest, <<Acc/binary, $\s>>);
percent_decode(<<C, Rest/binary>>, Acc) ->
    percent_decode(Rest, <<Acc/binary, C>>).

%% Value of one ASCII hex digit (0-9, A-F, a-f), or `not_hex` for anything else.
-spec hex_digit(byte()) -> 0..15 | not_hex.
hex_digit(C) when C >= $0, C =< $9 -> C - $0;
hex_digit(C) when C >= $A, C =< $F -> C - $A + 10;
hex_digit(C) when C >= $a, C =< $f -> C - $a + 10;
hex_digit(_C) -> not_hex.

%% Trim leading/trailing ASCII spaces and tabs (cookie-pair OWS, RFC 6265).
%% Byte-level on purpose: `string:trim/3` interprets the binary as UTF-8 and
%% raises `badarg` on arbitrary header bytes, which would break totality. Cookie
%% OWS is ASCII SP/HTAB, so a byte scan is both correct and total.
-spec trim(binary()) -> binary().
trim(Bin) ->
    trim_trailing(trim_leading(Bin)).

-spec trim_leading(binary()) -> binary().
trim_leading(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t ->
    trim_leading(Rest);
trim_leading(Bin) ->
    Bin.

-spec trim_trailing(binary()) -> binary().
trim_trailing(<<>>) ->
    <<>>;
trim_trailing(Bin) ->
    Last = byte_size(Bin) - 1,
    case binary:at(Bin, Last) of
        C when C =:= $\s; C =:= $\t -> trim_trailing(binary:part(Bin, 0, Last));
        _ -> Bin
    end.
