-module(erli18n_negotiate).

-moduledoc """
Canonicalization-aware BCP-47 locale negotiation and fallback (Phase 2).

This module is the pure, total, dependency-free engine behind erli18n's
opt-in locale-fallback chain and the `Accept-Language` negotiation helpers
exposed on the `erli18n` facade (`negotiate/2`, `parse_accept_language/1`,
`canonicalize_locale/1`). It holds **no** state: no `gen_server`, no ETS,
no process dictionary, no `application:get_env`. Every function runs in the
caller's process and is property-testable in isolation.

## The problem it solves

erli18n catalogs are keyed by exact binary (`<<"pt_BR">>`). Two correctness
gaps follow from that:

1. A `pt_BR` user with only a `pt` catalog loaded gets the raw `msgid`
   (English) instead of Portuguese — there is no base-language fallback.
2. HTTP delivers hyphenated, mixed-case tags (`pt-BR`, `PT_br`) and legacy
   subtags (`iw` for Hebrew), none of which match the underscored catalog
   key `pt_BR`.

This module closes both: `canonicalize/1` folds a tag to the catalog-key
shape, `fallback_chain/2` builds the ordered candidate list to try, and
`parse_accept_language/1` + `negotiate/2,3` / `best_match/3` pick the best
supported locale from a client preference list.

It does **not** change erli18n's default behavior. The facade only consults
this module **after** an exact-match miss and **only** when the application
env `erli18n.locale_fallback` is enabled (default `off`). The lock-free
exact-hit hot path is untouched.

## Canonicalization (`canonicalize/1`)

Target shape = erli18n catalog key = underscore-joined, RFC 5646 §2.1.1
positional casing: language lowercase, script Titlecase, region UPPERCASE
(`pt_BR`, `zh_Hant`, `zh_Hant_TW`). The transform is:

- Strip a POSIX charset/modifier suffix (`pt_BR.UTF-8`, `ca_ES@valencia`).
- Treat `-` and `_` as equivalent separators.
- Case each subtag by position (language) and byte length (2 = region,
  4 = script, else lowercase).
- Map a small, **closed** set of IANA-deprecated two-letter language codes
  to their preferred value, on the language subtag only.

It is **idempotent** (`canonicalize(canonicalize(X)) =:= canonicalize(X)`)
and never raises on any binary content (an oversized or absurd tag is
returned unchanged).

### Legacy-alias table (the complete, IN-scope set)

| Deprecated | Preferred | Language |
|---|---|---|
| `in` | `id` | Indonesian |
| `iw` | `he` | Hebrew |
| `ji` | `yi` | Yiddish |
| `jw` | `jv` | Javanese |
| `mo` | `ro` | Moldovan → Romanian |

**Out of scope (documented non-goals):** `sh` (macrolanguage, no preferred
value), `no`/`nb`/`nn` (not deprecated), `tl`/`fil`, the script-vs-region
inference `zh_Hans` ⇄ `zh_CN` (needs the CLDR *Add Likely Subtags*
algorithm + data), and grandfathered/irregular tags (`i-klingon`). Those
pass through as ordinary (mis)canonicalized binaries that simply miss the
catalog — never special-cased.

## Fallback chain (`fallback_chain/2`)

RFC 4647 §3.4 *Lookup*: canonicalize, then progressively drop the trailing
subtag, appending the (canonicalized) default last. `pt-BR` with default
`en` yields `[<<"pt_BR">>, <<"pt">>, <<"en">>]`. The chain is
order-preserving deduplicated and bounded. The facade walks it doing one
catalog read per candidate, short-circuiting on the first hit — so the cost
is O(chain length) extra reads **only on a miss**, zero on a hit.

Script subtags are kept during truncation (`zh_Hant_TW → zh_Hant → zh`),
matching RFC 4647 Lookup rather than CLDR's script-aware stop.

## Accept-Language (`parse_accept_language/1`, `best_match/3`)

`parse_accept_language/1` parses an HTTP `Accept-Language` header
(RFC 9110 §12.5.4) into `[{Range, Q}]` with `Q` as an integer in milli-units
(`0..1000`). Absent `q` is `1000`; a well-formed `q=0` entry is dropped
("not acceptable"); the list is sorted by descending `Q` with a stable
header-order tiebreak. The output shape matches cowlib's
`cow_http_hd:parse_accept_language/1`, but this parser is total/fail-soft
(it never crashes on malformed input — cowlib does).

`best_match/3` / `negotiate/2,3` run RFC 4647 Lookup of the (already
priority-ordered) preference list against the available catalog locales,
returning the first supported match (or a default / `error`).

## Totality and anti-DoS

Consistent with `erli18n_interp` and `erli18n_plural`, the work is bounded
fail-closed and never interns untrusted text into atoms:

- `?MAX_TAG_BYTES` (35) — a longer tag/range is returned unchanged / skipped.
- `?MAX_SUBTAGS` (8) — a tag with more subtags is returned unchanged.
- `?MAX_CHAIN` (8) — fallback chain length cap.
- `?MAX_HEADER_BYTES` (4096) — a longer `Accept-Language` header → `[]`.
- `?MAX_RAW_ELEMS` (64) — comma-split element cap (RFC 9110 §5.6.1) → `[]`.
- `?MAX_RANGES` (32) — accepted-range budget in `parse_accept_language/1`;
  per-consumed-cell budget (32 cells inspected max) in `to_locale_list/2`.

No `binary_to_atom`/`list_to_atom` is used anywhere; locales stay binaries,
so a stream of distinct hostile tags cannot exhaust the atom table.

## Quickstart

```erlang
1> erli18n_negotiate:canonicalize(<<"pt-BR">>).
<<"pt_BR">>
2> erli18n_negotiate:canonicalize(<<"iw-IL">>).
<<"he_IL">>
3> erli18n_negotiate:fallback_chain(<<"pt-BR">>, <<"en">>).
[<<"pt_BR">>,<<"pt">>,<<"en">>]
4> erli18n_negotiate:parse_accept_language(<<"da, en-gb;q=0.8, en;q=0.7">>).
[{<<"da">>,1000},{<<"en-gb">>,800},{<<"en">>,700}]
5> erli18n_negotiate:negotiate([<<"pt-BR">>], [<<"pt">>, <<"en">>]).
{ok,<<"pt">>}
```
""".

-export([
    canonicalize/1,
    fallback_chain/2,
    override_chain/3,
    parse_accept_language/1,
    negotiate/2,
    negotiate/3,
    negotiate_with_index/2,
    available_index/1,
    best_match/3
]).

-export_type([locale/0, language_range/0, qvalue/0, available_index/0]).

%% ===================================================================
%% Types
%% ===================================================================

-doc """
A locale tag as a binary, in erli18n catalog-key shape after
canonicalization (`<<"pt_BR">>`, `<<"zh_Hant">>`). Same semantics as
`t:erli18n_server:locale/0`.
""".
-type locale() :: binary().

-doc """
An RFC 4647 language range as it appears on the wire in an `Accept-Language`
header (`<<"en-gb">>`); may be the wildcard `<<"*">>`. ASCII-lowercased by
`parse_accept_language/1`, hyphen-separated (NOT yet canonicalized).
""".
-type language_range() :: binary().

-doc """
A quality value as an integer in milli-units, `0..1000` (`q=1` → `1000`,
`q=0.8` → `800`). Integer arithmetic avoids float parsing of untrusted text.
""".
-type qvalue() :: 0..1000.

-doc """
A prebuilt canonical→original index of an available-locale set: maps
`canonicalize(Original)` to the original `Available` casing, first occurrence
winning. Produced by `available_index/1` and consumed by
`negotiate_with_index/2`, so a caller negotiating many preference lists against
ONE available set builds the index once and reuses it.
""".
-type available_index() :: #{locale() => locale()}.

%% ===================================================================
%% Anti-DoS caps. Bound the work fail-closed, mirroring the caps in
%% `erli18n_interp`. These CLAMP/skip; they never raise.
%% ===================================================================

%% Maximum bytes of a single locale tag / language range. RFC 5646 tags are
%% short; a longer input is returned unchanged (canonicalize) or skipped
%% (a range). 35 covers every realistic language-script-region-variant tag.
-define(MAX_TAG_BYTES, 35).

%% Maximum subtag count in a tag. A tag with more is returned unchanged so a
%% pathological `a-a-a-...` cannot force per-segment allocation.
-define(MAX_SUBTAGS, 8).

%% Maximum fallback-chain length (extra catalog reads on a miss).
-define(MAX_CHAIN, 8).

%% Maximum `Accept-Language` header size; a larger header parses to `[]`
%% before any splitting.
-define(MAX_HEADER_BYTES, 4096).

%% Maximum comma-separated elements accepted before splitting work begins
%% (RFC 9110 §5.6.1 list-DoS bound); more → `[]`.
-define(MAX_RAW_ELEMS, 64).

%% Two distinct per-budget uses, both fail-closed at 32:
%%  - `parse_accept_language/1`: maximum ACCEPTED (post-filter) ranges kept
%%    from one header; there a skipped/empty element does NOT consume the
%%    budget (the budget counts outputs).
%%  - `to_locale_list/2` (raw negotiation input): a per-CONSUMED-cell budget —
%%    EVERY inspected cell (accepted, wildcard-skipped, or oversized-skipped)
%%    consumes one unit, so at most 32 cells are ever inspected regardless of
%%    how many are skipped (O(1) in input length on skip-heavy hostile input).
-define(MAX_RANGES, 32).

%% ===================================================================
%% Canonicalization
%% ===================================================================

-doc """
Canonicalizes ONE BCP-47 / POSIX locale tag to erli18n catalog-key shape.

Underscore-joined, RFC 5646 §2.1.1 positional casing (language lowercase,
script Titlecase, region UPPERCASE), with a charset/modifier suffix stripped
and a bounded legacy-language alias applied to the language subtag. Hyphen
and underscore are equivalent on input.

Total and idempotent: any binary input returns a binary and re-running
produces the same result. A binary over `?MAX_TAG_BYTES`, an empty binary,
or a tag with more than `?MAX_SUBTAGS` subtags is returned UNCHANGED
(fail-soft). A non-binary argument is a programmer error and raises
`function_clause` (the contract is binary-in/binary-out).

```erlang
1> erli18n_negotiate:canonicalize(<<"PT_br">>).
<<"pt_BR">>
2> erli18n_negotiate:canonicalize(<<"zh-hant-tw">>).
<<"zh_Hant_TW">>
3> erli18n_negotiate:canonicalize(<<"ca_ES@valencia">>).
<<"ca_ES">>
4> erli18n_negotiate:canonicalize(<<"iw">>).
<<"he">>
```

See `fallback_chain/2` (uses this) and the module doc for the alias table
and the documented non-goals (`zh_Hans` ⇄ `zh_CN` Likely Subtags).
""".
-spec canonicalize(binary()) -> binary().
canonicalize(Tag) when is_binary(Tag) ->
    Size = byte_size(Tag),
    case Size =:= 0 orelse Size > ?MAX_TAG_BYTES of
        true -> Tag;
        false -> canonicalize_bounded(Tag)
    end.

%% Internal: canonicalize a tag already known to be 1..?MAX_TAG_BYTES bytes.
-spec canonicalize_bounded(binary()) -> binary().
canonicalize_bounded(Tag0) ->
    Tag = strip_posix_suffix(Tag0),
    Parts = binary:split(Tag, [~"-", ~"_"], [global]),
    case length(Parts) > ?MAX_SUBTAGS of
        true -> Tag0;
        false -> join_underscore(case_subtags(Parts))
    end.

%% Cut at the first '.' (POSIX charset, e.g. `pt_BR.UTF-8`) or '@' (POSIX
%% modifier, e.g. `ca_ES@valencia`), keeping the head.
-spec strip_posix_suffix(binary()) -> binary().
strip_posix_suffix(Tag) ->
    case binary:match(Tag, [~".", ~"@"]) of
        nomatch -> Tag;
        {Pos, _Len} -> binary:part(Tag, 0, Pos)
    end.

%% Case each subtag by position: subtag 0 (language) lowercase + alias; the
%% rest by byte length (2 = region UPPER, 4 = script Title, else lower).
%% The only caller feeds `binary:split/3` output, which is always a non-empty
%% list (at minimum `[Tag]`), so there is no `[]` clause — a `[]` here would be
%% a contract violation and is left to crash explicitly.
-spec case_subtags([binary(), ...]) -> [binary(), ...].
case_subtags([Lang | Rest]) ->
    [alias_lang(ascii_lower(Lang)) | [case_subtag(S) || S <- Rest]].

-spec case_subtag(binary()) -> binary().
case_subtag(S) ->
    case byte_size(S) of
        2 -> ascii_upper(S);
        4 -> ascii_title(S);
        _ -> ascii_lower(S)
    end.

%% Closed, compile-time legacy-language alias table (IANA deprecated
%% two-letter codes carrying a Preferred-Value). Applies to the language
%% subtag only. Any other value passes through unchanged.
-spec alias_lang(binary()) -> binary().
alias_lang(~"in") -> ~"id";
alias_lang(~"iw") -> ~"he";
alias_lang(~"ji") -> ~"yi";
alias_lang(~"jw") -> ~"jv";
alias_lang(~"mo") -> ~"ro";
alias_lang(Other) -> Other.

-spec join_underscore([binary()]) -> binary().
join_underscore(Parts) ->
    iolist_to_binary(lists:join(~"_", Parts)).

%% ASCII-only case folders (BCP-47 subtags are ASCII by spec). Deliberately
%% NOT `string:lowercase/1`: byte-range folding avoids the Turkish-İ locale
%% hazard and allocates leanly.
-spec ascii_lower(binary()) -> binary().
ascii_lower(B) ->
    <<<<(lower_byte(C))>> || <<C>> <= B>>.

-spec ascii_upper(binary()) -> binary().
ascii_upper(B) ->
    <<<<(upper_byte(C))>> || <<C>> <= B>>.

%% Only called on a length-4 script subtag (`case_subtag/1`), so the input is
%% never empty; no `<<>>` clause.
-spec ascii_title(binary()) -> binary().
ascii_title(<<First, Rest/binary>>) -> <<(upper_byte(First)), (ascii_lower(Rest))/binary>>.

-spec lower_byte(byte()) -> byte().
lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

-spec upper_byte(byte()) -> byte().
upper_byte(C) when C >= $a, C =< $z -> C - 32;
upper_byte(C) -> C.

%% ===================================================================
%% Fallback chain (RFC 4647 §3.4 Lookup)
%% ===================================================================

-doc """
Builds the ordered, deduplicated RFC 4647 *Lookup* fallback chain for a
locale, ending in `Default` (canonicalized) unless `Default =:= undefined`.

`Locale` is canonicalized first, then the trailing subtag is dropped
repeatedly to a fixpoint (`zh_Hant_TW → zh_Hant → zh`); `Default` is appended
last. The result is order-preserving deduplicated and capped at `?MAX_CHAIN`.
The head is the most specific candidate. Total; the returned list is always
non-empty (at minimum `[canonicalize(Locale)]`).

```erlang
1> erli18n_negotiate:fallback_chain(<<"pt-BR">>, <<"en">>).
[<<"pt_BR">>,<<"pt">>,<<"en">>]
2> erli18n_negotiate:fallback_chain(<<"zh_Hant_TW">>, <<"en">>).
[<<"zh_Hant_TW">>,<<"zh_Hant">>,<<"zh">>,<<"en">>]
3> erli18n_negotiate:fallback_chain(<<"en">>, undefined).
[<<"en">>]
```

The facade walks this list with one catalog read per candidate, returning on
the first hit; this is what makes a `pt_BR` user fall back to a loaded `pt`
catalog. See `canonicalize/1`.
""".
-spec fallback_chain(locale(), locale() | undefined) -> [locale(), ...].
fallback_chain(Locale, Default) when is_binary(Locale) ->
    cap_with_default(dedup(base_chain(canonicalize(Locale))), Default).

-doc """
Builds an explicit-override fallback chain for `{explicit, Map}` mode: the
canonicalized `Overrides` list prefixed with `canonicalize(Locale)` and floored
with `Default`. Order-preserving deduplicated and bounded by the SAME
`?MAX_CHAIN` cap as `fallback_chain/2`. Total.

Exposed so the facade's explicit-map mode reuses one bounding/dedup
implementation instead of re-deriving the cap.

```erlang
1> erli18n_negotiate:override_chain(<<"de-AT">>, [<<"de">>], <<"en">>).
[<<"de_AT">>,<<"de">>,<<"en">>]
```
""".
-spec override_chain(locale(), [locale()], locale() | undefined) -> [locale(), ...].
override_chain(Locale, Overrides, Default) when is_binary(Locale), is_list(Overrides) ->
    Canon = canonicalize(Locale),
    CanonOverrides = [canonicalize(X) || X <- Overrides, is_binary(X)],
    cap_with_default(dedup([Canon | CanonOverrides]), Default).

%% The candidate list before the default floor: the RFC 4647 truncation
%% prefixes of the (already canonical) tag. An over-`?MAX_TAG_BYTES` tag is
%% one that `canonicalize/1` returned UNCHANGED (fail-soft), so it is treated
%% as a single opaque candidate here — never fed into the per-level
%% `truncate_one/1` scan, which would be O(n^2) on a pathological
%% many-separator tag.
-spec base_chain(binary()) -> [binary(), ...].
base_chain(Tag) ->
    case byte_size(Tag) > ?MAX_TAG_BYTES of
        true -> [Tag];
        false -> truncations(Tag)
    end.

%% [Tag, parent, grandparent, ...] down to the single language subtag.
-spec truncations(binary()) -> [binary(), ...].
truncations(Tag) ->
    case truncate_one(Tag) of
        nomatch -> [Tag];
        Parent -> [Tag | truncations(Parent)]
    end.

%% Drop the last `_`-delimited subtag; `nomatch` when there is no separator.
%% Mirrors the `erli18n_plural:base_locale/1` idiom (duplicated to keep this
%% module self-contained — `base_locale/1` is private there).
-spec truncate_one(binary()) -> binary() | nomatch.
truncate_one(Tag) ->
    case binary:matches(Tag, ~"_") of
        [] ->
            nomatch;
        Matches ->
            {Pos, _Len} = lists:last(Matches),
            binary:part(Tag, 0, Pos)
    end.

%% Bound the chain at `?MAX_CHAIN` while ALWAYS preserving the (canonicalized)
%% `Default` floor as the last element — so the documented "ends in Default"
%% contract holds even when the truncation prefix alone would fill the cap.
-spec cap_with_default([locale(), ...], locale() | undefined) -> [locale(), ...].
cap_with_default(Base, undefined) ->
    lists:sublist(Base, ?MAX_CHAIN);
cap_with_default(Base, Default) when is_binary(Default) ->
    dedup(lists:sublist(Base, ?MAX_CHAIN - 1) ++ [canonicalize(Default)]).

%% Order-preserving deduplication (NOT `lists:usort/1`: order is load-bearing).
-spec dedup([locale()]) -> [locale()].
dedup(List) ->
    {Acc, _Seen} = lists:foldl(
        fun(X, {AccIn, Seen}) ->
            case maps:is_key(X, Seen) of
                true -> {AccIn, Seen};
                false -> {[X | AccIn], Seen#{X => true}}
            end
        end,
        {[], #{}},
        List
    ),
    lists:reverse(Acc).

%% ===================================================================
%% Accept-Language parsing (RFC 9110 §12.5.4 + §12.4.2)
%% ===================================================================

-doc """
Parses an HTTP `Accept-Language` header into `[{Range, Q}]`.

`Range` is the ASCII-lowercased, hyphen-separated language range as on the
wire (NOT canonicalized; may be `<<"*">>`); `Q` is an integer in milli-units
(`0..1000`). An absent `q` parameter means `1000`; a well-formed `q=0` entry
is DROPPED. The list is sorted by descending `Q`, ties broken by ascending
header position (stable).

Total and fail-soft: any malformed element is skipped, never crashing.
Returns `[]` on an empty header, a header over `?MAX_HEADER_BYTES`, or one
with more than `?MAX_RAW_ELEMS` comma elements. A non-binary argument raises
`function_clause`. At most `?MAX_RANGES` ranges are returned.

The output shape matches cowlib's `cow_http_hd:parse_accept_language/1`, so a
Cowboy app may feed either source into `negotiate/2`. Unlike cowlib, this
parser never raises on hostile input.

```erlang
1> erli18n_negotiate:parse_accept_language(<<"da, en-gb;q=0.8, en;q=0.7">>).
[{<<"da">>,1000},{<<"en-gb">>,800},{<<"en">>,700}]
2> erli18n_negotiate:parse_accept_language(<<"fr;q=0, de">>).
[{<<"de">>,1000}]
```

See `best_match/3` and `negotiate/2,3`.
""".
-spec parse_accept_language(binary()) -> [{language_range(), qvalue()}].
parse_accept_language(Bin) when is_binary(Bin) ->
    parse_accept_language_1(Bin).

-spec parse_accept_language_1(binary()) -> [{language_range(), qvalue()}].
parse_accept_language_1(Bin) ->
    case byte_size(Bin) > ?MAX_HEADER_BYTES of
        true ->
            [];
        false ->
            Elems = binary:split(Bin, ~",", [global]),
            case length(Elems) > ?MAX_RAW_ELEMS of
                true -> [];
                false -> stable_sort_desc_q(parse_elems(Elems, ?MAX_RANGES, 1, []))
            end
    end.

%% Fold elements in header order. The accepted-range budget and the index
%% counter advance ONLY on an accepted entry, so skipped/empty elements cost
%% nothing and the index is a dense header-order rank for the stable tiebreak.
-spec parse_elems([binary()], non_neg_integer(), pos_integer(), [
    {qvalue(), pos_integer(), language_range()}
]) ->
    [{qvalue(), pos_integer(), language_range()}].
parse_elems([], _Budget, _Idx, Acc) ->
    Acc;
parse_elems(_Elems, 0, _Idx, Acc) ->
    Acc;
parse_elems([E | Rest], Budget, Idx, Acc) ->
    case parse_one(E) of
        skip -> parse_elems(Rest, Budget, Idx, Acc);
        {Range, Q} -> parse_elems(Rest, Budget - 1, Idx + 1, [{Q, Idx, Range} | Acc])
    end.

-spec parse_one(binary()) -> {language_range(), qvalue()} | skip.
parse_one(E0) ->
    case trim_ows(E0) of
        <<>> ->
            skip;
        E ->
            {RangePart, Q} = split_range_q(E),
            finalize(trim_ows(RangePart), Q)
    end.

%% Split a `range[;params]` element into the range and the resolved q (1000
%% when there is no `q=` parameter).
-spec split_range_q(binary()) -> {binary(), qvalue()}.
split_range_q(E) ->
    case binary:split(E, ~";") of
        [Range] -> {Range, 1000};
        [Range, Params] -> {Range, find_q(binary:split(Params, ~";", [global]))}
    end.

-spec find_q([binary()]) -> qvalue().
find_q([]) ->
    1000;
find_q([Token | Rest]) ->
    case trim_ows(Token) of
        <<Q, $=, Val/binary>> when Q =:= $q; Q =:= $Q -> qval_to_milli(trim_ows(Val));
        _ -> find_q(Rest)
    end.

%% Parse a qvalue ("0" / "1" / "0.NNN" / "1.000") into milli-units. Any
%% malformation (q=abc, q=2, q=1.5, q=) clamps to full weight (1000); only a
%% well-formed zero yields 0. Never `binary_to_float`.
-spec qval_to_milli(binary()) -> qvalue().
qval_to_milli(~"0") -> 0;
qval_to_milli(~"1") -> 1000;
qval_to_milli(<<"1.", _/binary>>) -> 1000;
qval_to_milli(<<"0.", Frac/binary>>) when byte_size(Frac) =< 3 -> frac_to_milli(Frac);
qval_to_milli(_) -> 1000.

-spec frac_to_milli(binary()) -> qvalue().
frac_to_milli(Frac) ->
    case all_digits(Frac) of
        false -> 1000;
        true -> digits3_to_int(pad3(Frac))
    end.

-spec pad3(binary()) -> binary().
pad3(<<>>) -> ~"000";
pad3(<<A>>) -> <<A, $0, $0>>;
pad3(<<A, B>>) -> <<A, B, $0>>;
pad3(<<A, B, C>>) -> <<A, B, C>>.

-spec digits3_to_int(binary()) -> 0..999.
digits3_to_int(<<A, B, C>>) ->
    (A - $0) * 100 + (B - $0) * 10 + (C - $0).

-spec all_digits(binary()) -> boolean().
all_digits(<<>>) -> true;
all_digits(<<C, Rest/binary>>) when C >= $0, C =< $9 -> all_digits(Rest);
all_digits(_) -> false.

%% Accept a range only if non-empty, within ?MAX_TAG_BYTES, made solely of
%% ALPHA / DIGIT / '-' / '*', and not a well-formed q=0. Lowercased on accept.
-spec finalize(binary(), qvalue()) -> {language_range(), qvalue()} | skip.
finalize(<<>>, _Q) ->
    skip;
finalize(_Range, 0) ->
    skip;
finalize(Range, Q) ->
    case byte_size(Range) =< ?MAX_TAG_BYTES andalso valid_range_chars(Range) of
        true -> {ascii_lower(Range), Q};
        false -> skip
    end.

-spec valid_range_chars(binary()) -> boolean().
valid_range_chars(<<>>) ->
    true;
valid_range_chars(<<C, Rest/binary>>) ->
    case is_range_char(C) of
        true -> valid_range_chars(Rest);
        false -> false
    end.

-spec is_range_char(byte()) -> boolean().
is_range_char(C) ->
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $- orelse
        C =:= $*.

%% Optional whitespace = SP / HTAB (RFC 9110 OWS).
-spec trim_ows(binary()) -> binary().
trim_ows(B) ->
    trim_trailing_ows(trim_leading_ows(B)).

-spec trim_leading_ows(binary()) -> binary().
trim_leading_ows(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t -> trim_leading_ows(Rest);
trim_leading_ows(B) -> B.

-spec trim_trailing_ows(binary()) -> binary().
trim_trailing_ows(<<>>) ->
    <<>>;
trim_trailing_ows(B) ->
    Size = byte_size(B),
    case binary:at(B, Size - 1) of
        C when C =:= $\s; C =:= $\t -> trim_trailing_ows(binary:part(B, 0, Size - 1));
        _ -> B
    end.

%% Stable sort: descending Q, then ascending header index for ties.
-spec stable_sort_desc_q([{qvalue(), pos_integer(), language_range()}]) ->
    [{language_range(), qvalue()}].
stable_sort_desc_q(Acc) ->
    Sorted = lists:sort(
        fun({Q1, I1, _}, {Q2, I2, _}) ->
            case Q1 =:= Q2 of
                true -> I1 =< I2;
                false -> Q1 > Q2
            end
        end,
        Acc
    ),
    [{Range, Q} || {Q, _I, Range} <- Sorted].

%% ===================================================================
%% Negotiation (RFC 4647 Lookup against an available set)
%% ===================================================================

-doc """
Picks the best supported locale for a preference list, or `error`.

`Preferred` is an ordered preference list (priority = position): either
`[locale()]` or the `[{locale(), qvalue()}]` output of
`parse_accept_language/1` (the `Q` is ignored — order already encodes
priority, and `q=0` ranges were already dropped). `Available` is the list of
catalog locales (e.g. `erli18n:loaded_catalogs/0` locales).

Each `Preferred` entry is canonicalized and resolved through its
`fallback_chain/2` (no default) against a canonical→original index of
`Available`; the FIRST hit wins. `*` ranges are skipped. The returned locale
is the ORIGINAL `Available` casing. Total.

```erlang
1> erli18n_negotiate:negotiate([<<"pt-BR">>], [<<"pt">>, <<"en">>]).
{ok,<<"pt">>}
2> erli18n_negotiate:negotiate([<<"zh_Hant">>], [<<"en">>]).
error
```

See `negotiate/3` (default instead of `error`) and `best_match/3`.
""".
-spec negotiate([locale()] | [{locale(), qvalue()}], [locale()]) -> {ok, locale()} | error.
negotiate(Preferred, Available) ->
    negotiate_with_index(Preferred, available_index(Available)).

-doc """
Like `negotiate/2`, but against a PREBUILT `available_index/1` instead of a raw
`Available` list — so the canonical index is built once and reused across many
preference lists (e.g. one per request source).

`negotiate(Preferred, Available)` is exactly
`negotiate_with_index(Preferred, available_index(Available))`; this arity lets a
caller hoist the `available_index/1` out of a per-candidate loop. Semantics are
otherwise identical: each `Preferred` entry is canonicalized and resolved through
its `fallback_chain/2` against the index, first hit winning, returning the
original `Available` casing. Total.

```erlang
1> Ix = erli18n_negotiate:available_index([<<"pt">>, <<"en">>]).
2> erli18n_negotiate:negotiate_with_index([<<"pt-BR">>], Ix).
{ok,<<"pt">>}
3> erli18n_negotiate:negotiate_with_index([<<"zh_Hant">>], Ix).
error
```

See `negotiate/2` (raw-list form) and `available_index/1`.
""".
-spec negotiate_with_index([locale()] | [{locale(), qvalue()}], available_index()) ->
    {ok, locale()} | error.
negotiate_with_index(Preferred, Index) when is_map(Index) ->
    case match_preferred(to_locale_list(Preferred), Index) of
        {ok, _Original} = Found -> Found;
        nomatch -> error
    end.

-doc """
Like `negotiate/2`, but returns `{ok, Default}` instead of `error` when
nothing matches. `Default` is the caller's chosen floor (the RFC 4647
*Lookup* default) and is NOT validated against `Available`. Total.

```erlang
1> erli18n_negotiate:negotiate([<<"zh_Hant">>], [<<"en">>], <<"en">>).
{ok,<<"en">>}
```
""".
-spec negotiate([locale()] | [{locale(), qvalue()}], [locale()], locale()) -> {ok, locale()}.
negotiate(Preferred, Available, Default) ->
    {ok, best_match(Preferred, Available, Default)}.

-doc """
The bare RFC 4647 *Lookup* primitive: like `negotiate/3` but returns the
matched (or `Default`) locale directly, never wrapped. Always succeeds
(falls to `Default`). Total.

```erlang
1> erli18n_negotiate:best_match([<<"en-US">>], [<<"en">>], <<"x">>).
<<"en">>
```
""".
-spec best_match([locale()] | [{locale(), qvalue()}], [locale()], locale()) -> locale().
best_match(Preferred, Available, Default) ->
    case match_preferred(to_locale_list(Preferred), available_index(Available)) of
        {ok, Original} -> Original;
        nomatch -> Default
    end.

%% Normalize a preference list to plain locale binaries: strip q tuples and
%% wildcard ranges, preserving order. Each entry is bounded — an entry over
%% `?MAX_TAG_BYTES` is skipped (it can never match a canonical catalog key, and
%% leaving it in would feed the truncation path an oversized tag). The
%% `?MAX_RANGES` budget here is a per-CONSUMED-cell budget: every inspected cell
%% (accepted, wildcard-skipped, or oversized-skipped) decrements it, so at most
%% 32 input cells are ever inspected. This is stricter than (and distinct from)
%% `parse_accept_language/1`'s pre-split `?MAX_RAW_ELEMS` cap and its
%% accepted-output `?MAX_RANGES` budget — so a hostile preference list cannot
%% drive unbounded negotiation work even when supplied raw (not via the parser),
%% including a list that is overwhelmingly wildcards or oversized tags.
-spec to_locale_list([locale()] | [{locale(), qvalue()}]) -> [locale()].
to_locale_list(List) ->
    to_locale_list(List, ?MAX_RANGES).

-spec to_locale_list([locale()] | [{locale(), qvalue()}], non_neg_integer()) -> [locale()].
to_locale_list(_List, 0) ->
    [];
to_locale_list([], _Budget) ->
    [];
to_locale_list([X | Rest], Budget) ->
    case is_wildcard(X) of
        true ->
            to_locale_list(Rest, Budget - 1);
        false ->
            L = strip_q(X),
            case byte_size(L) =< ?MAX_TAG_BYTES of
                true -> [L | to_locale_list(Rest, Budget - 1)];
                false -> to_locale_list(Rest, Budget - 1)
            end
    end.

-spec strip_q(locale() | {locale(), qvalue()}) -> locale().
strip_q({L, _Q}) when is_binary(L) -> L;
strip_q(L) when is_binary(L) -> L.

-spec is_wildcard(locale() | {locale(), qvalue()}) -> boolean().
is_wildcard({~"*", _}) -> true;
is_wildcard(~"*") -> true;
is_wildcard(_) -> false.

-doc """
Builds the canonical→original index for an available-locale set, for reuse
across many `negotiate_with_index/2` calls.

Maps `canonicalize(A)` to the original `A` for each `A` in `Available`, first
occurrence winning (so the earliest entry's original catalog casing is the one
returned by a later match). This is the per-`Available` work `negotiate/2`
otherwise repeats on every call; build it once when negotiating multiple
preference lists against the same set. Total.

```erlang
1> Ix = erli18n_negotiate:available_index([<<"pt_BR">>, <<"fr">>]).
2> erli18n_negotiate:negotiate_with_index([<<"pt-BR">>], Ix).
{ok,<<"pt_BR">>}
```
""".
-spec available_index([locale()]) -> available_index().
available_index(Available) ->
    lists:foldl(
        fun(A, Acc) ->
            K = canonicalize(A),
            case maps:is_key(K, Acc) of
                true -> Acc;
                false -> Acc#{K => A}
            end
        end,
        #{},
        Available
    ).

-spec match_preferred([locale()], available_index()) -> {ok, locale()} | nomatch.
match_preferred([], _Index) ->
    nomatch;
match_preferred([P | Rest], Index) ->
    case match_chain(fallback_chain(P, undefined), Index) of
        {ok, _Original} = Found -> Found;
        nomatch -> match_preferred(Rest, Index)
    end.

-spec match_chain([locale()], available_index()) -> {ok, locale()} | nomatch.
match_chain([], _Index) ->
    nomatch;
match_chain([C | Rest], Index) ->
    case maps:find(C, Index) of
        {ok, _Original} = Found -> Found;
        error -> match_chain(Rest, Index)
    end.
