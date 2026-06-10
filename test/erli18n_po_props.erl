%%% =====================================================================
%%% Property-based tests for `erli18n_po` — parser/dumper invariants.
%%%
%%% Spec source-of-truth: `parity_specs.md` §6.1 (properties P1, P2, P5).
%%%   * P1 — Roundtrip parse/dump.
%%%   * P2 — Idempotent normalization (dump∘parse∘dump∘parse = parse).
%%%   * P5 — ETS-key canonical equivalence (PSD-006): `{Context, Msgid}`
%%%          tuple round-trips through `parse∘dump` unchanged even when
%%%          `Msgid` contains the EOT byte (`0x04`) that the legacy `.mo`
%%%          format used as the context/msgid boundary.
%%%
%%% References:
%%%   * Hughes, "QuickCheck: a lightweight tool for random testing of
%%%     Haskell programs", ICFP 2000.
%%%   * Papadakis et al., "PropEr: a QuickCheck-Inspired Property-Based
%%%     Testing Tool for Erlang", PADL 2011 —
%%%     https://proper-testing.github.io/papers/proper_acm.pdf
%%%   * PropEr docs — https://hexdocs.pm/proper/
%%%
%%% Generator strategy: build catalogs from the inside out — first a
%%% header with a syntactically valid `Plural-Forms` line, then a list of
%%% entries (singular or plural). Plural entries are constrained so the
%%% emitted indices match the header's `nplurals` (per PSD-009; otherwise
%%% `erli18n_po:parse/1` would refuse the catalog with
%%% `{plural_count_mismatch, ...}`). Strings are drawn from a mixed
%%% population of plain ASCII, UTF-8 multibyte, and `\n`/`\t`/`\"`/`\\`
%%% sequences so the escape pipeline gets exercised.
%%% =====================================================================
-module(erli18n_po_props).

-include_lib("proper/include/proper.hrl").

-export([
    prop_roundtrip_parse_dump/0,
    prop_idempotent_normalization/0,
    prop_ets_key_canonical/0,
    prop_large_string_roundtrip/0
]).

%% Generators (exported so other property modules can compose them).
-export([
    valid_po/0,
    valid_entry/1,
    valid_singular/0,
    valid_plural/1,
    valid_msgid/0,
    valid_context/0,
    valid_translation/0,
    valid_translation_with_eot/0,
    plural_header_bin/1
]).

%% =========================
%% Properties
%% =========================

%% P1 — Roundtrip parse/dump.
%%
%% Claim: for any well-formed catalog `Po` produced by `valid_po/0`,
%%   `parse(dump(Po)).entries =:= Po.entries`
%%
%% We compare only `entries` (and not the full map) because `dump/1`
%% intentionally rewrites the header text — the original `raw` header
%% binary in `Po` is whatever the generator chose, while the dumped
%% header is the canonical multi-line form. The semantic content
%% (plural_forms, charset) survives the round trip, which we cover in
%% `prop_idempotent_normalization/0`.
prop_roundtrip_parse_dump() ->
    ?FORALL(
        PoGen,
        valid_po(),
        begin
            %% PropEr generator boundary: cast to the documented
            %% `erli18n_po:parsed_catalog()` shape — `valid_po/0` is
            %% hand-rolled to satisfy that contract.
            Po = eqwalizer:dynamic_cast(PoGen),
            Dumped = erli18n_po:dump(Po),
            case erli18n_po:parse(Dumped) of
                {ok, Reparsed} ->
                    OrigEntries = canonicalize_entries(maps:get(entries, Po)),
                    RoundtripEntries =
                        canonicalize_entries(maps:get(entries, Reparsed)),
                    OrigEntries =:= RoundtripEntries;
                {error, _} = Err ->
                    %% Parser refusal on dumped output is a real bug;
                    %% surface the counter-example with the failure.
                    ct:pal(
                        "parse(dump(Po)) failed: ~p~ndumped=~p~n",
                        [Err, Dumped]
                    ),
                    false
            end
        end
    ).

%% P2 — Idempotent normalization.
%%
%% Claim: `parse(dump(parse(dump(Po)))) =:= parse(dump(Po))`.
%% Equivalently: one full round trip places the catalog in a canonical
%% form; a second round trip is the identity.
%%
%% We compare the parsed maps directly. The first `parse(dump(_))`
%% produces a canonical header (raw == "Content-Type: text/plain; ...")
%% and canonical entry order, so the second iteration must reproduce
%% byte-for-byte the same parsed map.
prop_idempotent_normalization() ->
    ?FORALL(
        PoGen,
        valid_po(),
        begin
            %% Generator boundary — see `prop_roundtrip_parse_dump/0`.
            Po = eqwalizer:dynamic_cast(PoGen),
            Dumped1 = erli18n_po:dump(Po),
            case erli18n_po:parse(Dumped1) of
                {ok, Parsed1} ->
                    Dumped2 = erli18n_po:dump(Parsed1),
                    case erli18n_po:parse(Dumped2) of
                        {ok, Parsed2} ->
                            canonicalize_parsed(Parsed1) =:=
                                canonicalize_parsed(Parsed2);
                        {error, _} = Err ->
                            ct:pal("second parse failed: ~p~n", [Err]),
                            false
                    end;
                {error, _} = Err ->
                    ct:pal(
                        "first parse failed: ~p~ndumped=~p~n",
                        [Err, Dumped1]
                    ),
                    false
            end
        end
    ).

%% P5 — ETS-key canonical equivalence (PSD-006).
%%
%% PSD-006 declares the runtime key as the tuple `{Context, Msgid}`
%% (Context = `undefined` or binary, separate from Msgid). The
%% historical `.mo` format glues them with the EOT byte (`0x04`); if a
%% naive refactor ever switches our parser to use the glued
%% representation, an `Msgid` containing a literal `0x04` would break
%% silently. This property pins the invariant: the parse∘dump round
%% trip preserves `{Context, Msgid}` exactly, including the case where
%% the msgid contains EOT bytes.
%%
%% We do not call any internal `ets_key_from_mo_decode/1` helper (it
%% does not exist in the implementation — and PSD-006 says it should
%% not). Instead the property exercises the same invariant from the
%% outside: parse(dump(...)).entries preserves the tuple shape.
prop_ets_key_canonical() ->
    ?FORALL(
        {Ctx, Msgid, Translation},
        {valid_context(), valid_msgid_with_eot(), valid_translation_with_eot()},
        begin
            Po = make_singular_catalog(Ctx, Msgid, Translation),
            Dumped = erli18n_po:dump(Po),
            case erli18n_po:parse(Dumped) of
                {ok, #{entries := [{singular, Ctx2, Msgid2, T2}]}} ->
                    Ctx =:= Ctx2 andalso
                        Msgid =:= Msgid2 andalso
                        Translation =:= T2;
                Other ->
                    ct:pal(
                        "ets_key_canonical: unexpected parse result ~p~n"
                        "dumped=~p~n",
                        [Other, Dumped]
                    ),
                    false
            end
        end
    ).

%% P1b — Large single-string round trip (Finding #3 equivalence guard).
%%
%% The Finding #3 fix replaced the right-append fold in
%% `bins_to_binary/1` with `iolist_to_binary(lists:reverse(_))`. That
%% function backs both the parse-side decoder (`decode_chars/2`) and the
%% dump-side escaper (`escape_string/2`), so the swap must be byte-exact
%% on large inputs, not just fast. This property builds a catalog whose
%% msgid and translation are each tens of KB (well past the
%% in-place-growth threshold where the old and new code could diverge if
%% the materialization were wrong), dumps it, reparses it, and asserts
%% the entries survive unchanged. It complements `prop_decode_is_linear`
%% in the fuzz suite: that one pins the *cost*, this one pins the
%% *result*.
prop_large_string_roundtrip() ->
    ?FORALL(
        {NGen, FillerGen},
        {oneof([8_000, 32_000, 64_000]), oneof([$a, $z, $9, $\s])},
        begin
            %% Generator boundary — see `prop_roundtrip_parse_dump/0`.
            %% `oneof/1` is typed `term()` by eqwalizer; cast to the
            %% documented integer shapes the generators produce.
            N = eqwalizer:dynamic_cast(NGen),
            Filler = eqwalizer:dynamic_cast(FillerGen),
            Big = binary:copy(<<Filler>>, N),
            Msgid = <<"id-", Big/binary>>,
            Translation = <<"tr-", Big/binary>>,
            Po = make_singular_catalog(undefined, Msgid, Translation),
            Dumped = erli18n_po:dump(Po),
            case erli18n_po:parse(Dumped) of
                {ok, #{entries := [{singular, undefined, M2, T2}]}} ->
                    M2 =:= Msgid andalso T2 =:= Translation;
                Other ->
                    ct:pal(
                        "large_string_roundtrip: unexpected parse "
                        "result ~p (N=~p)~n",
                        [Other, N]
                    ),
                    false
            end
        end
    ).

%% =========================
%% Generators
%% =========================

%% A well-formed catalog with header + 0..20 entries. The header's
%% `nplurals` count is fixed first, then entries are generated so plural
%% entries respect that count (parser would otherwise reject them per
%% PSD-009).
valid_po() ->
    ?LET(
        NPlurals,
        oneof([1, 2, 3, 6]),
        ?LET(
            Entries,
            list(valid_entry(NPlurals)),
            #{
                header => #{
                    plural_forms => plural_header_bin(NPlurals),
                    content_type =>
                        <<"text/plain; charset=UTF-8">>,
                    charset => utf8,
                    raw => raw_header_bin(NPlurals)
                },
                entries => Entries
            }
        )
    ).

valid_entry(NPlurals) ->
    oneof([valid_singular(), valid_plural(NPlurals)]).

valid_singular() ->
    ?LET(
        {Ctx, Msgid, T},
        {valid_context(), valid_msgid(), valid_translation()},
        {singular, Ctx, Msgid, T}
    ).

valid_plural(NPlurals) ->
    ?LET(
        {Ctx, Msgid, Forms},
        {valid_context(), valid_msgid(), plural_forms(NPlurals)},
        {plural, Ctx, Msgid, Forms}
    ).

%% Plural translations: exactly NPlurals entries, indexed 0..NPlurals-1.
plural_forms(NPlurals) ->
    ?LET(
        TranslationsGen,
        vector(NPlurals, valid_translation()),
        %% PropEr `vector/2` is typed as `proper_gen:instance()` by
        %% eqwalizer; cast at the boundary to the documented shape
        %% (`[binary()]`, the contract of `valid_translation/0`).
        lists:zip(
            lists:seq(0, NPlurals - 1),
            eqwalizer:dynamic_cast(TranslationsGen)
        )
    ).

%% Context: 50% undefined, 50% short binary 0..20 chars (UTF-8 + ASCII
%% mix). We bias toward shorter context strings because real-world `.po`
%% contexts are typically very short ("button", "menu", "title").
valid_context() ->
    weighted_union([
        {1, exactly(undefined)},
        {1,
            ?LET(
                NGen,
                choose(0, 20),
                %% Generator boundary — cast the `choose/2` instance to
                %% the documented `non_neg_integer()` shape consumed by
                %% `proper_unicode:utf8/2`.
                proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
            )}
    ]).

%% Msgid: non-empty UTF-8 binary, 1..50 codepoints, with a 30% chance
%% of containing escape-eligible characters (`\n`, `\t`, `\"`, `\\`).
%%
%% NOTE: msgid =:= <<>> is RESERVED by GNU gettext for the header entry
%% (see GNU manual §11.2 "The Format of PO Files" — "the empty string
%% as msgid is reserved"). Our parser correctly treats a non-header
%% `msgid ""` as a header on the second occurrence — to keep the
%% generator within the legitimate user-data space we forbid empty
%% msgids.
valid_msgid() ->
    ?LET(
        BaseGen,
        ?SUCHTHAT(
            BGen,
            ?LET(
                NGen,
                choose(1, 50),
                proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
            ),
            %% Generator boundary — `BGen` is `proper_gen:instance()`
            %% (statically `term()`); the documented shape is `binary()`.
            byte_size(eqwalizer:dynamic_cast(BGen)) > 0
        ),
        maybe_inject_escapes(eqwalizer:dynamic_cast(BaseGen), 30)
    ).

%% Translation: same population as msgid but allowed empty (PSD-003 says
%% empty msgstr is preserved as `<<>>` by the parser; lookup decides
%% the fallback).
valid_translation() ->
    ?LET(
        BaseGen,
        ?LET(
            NGen,
            choose(0, 50),
            proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
        ),
        %% Generator boundary — see `valid_msgid/0`.
        maybe_inject_escapes(eqwalizer:dynamic_cast(BaseGen), 30)
    ).

%% Msgid variant that forces an EOT byte (0x04) somewhere in the
%% middle, used by `prop_ets_key_canonical/0`. EOT is a 7-bit ASCII
%% control character; we splice it at the start of the suffix so the
%% concatenation `<<Prefix/binary, 4, Suffix/binary>>` lands on a
%% codepoint boundary and stays valid UTF-8. The msgid must also be
%% non-empty (see `valid_msgid/0` comment about the reserved-header
%% rule).
valid_msgid_with_eot() ->
    ?LET(
        {PrefixGen, SuffixGen},
        {
            ?LET(
                NGen,
                choose(0, 20),
                proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
            ),
            ?LET(
                NGen,
                choose(1, 20),
                proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
            )
        },
        %% Generator boundary — see `valid_msgid/0`.
        begin
            Prefix = eqwalizer:dynamic_cast(PrefixGen),
            Suffix = eqwalizer:dynamic_cast(SuffixGen),
            <<Prefix/binary, 4, Suffix/binary>>
        end
    ).

%% Translation variant — same EOT-injection treatment as msgid, but
%% may be empty (PSD-003).
valid_translation_with_eot() ->
    ?LET(
        {PrefixGen, SuffixGen},
        {
            ?LET(
                NGen,
                choose(0, 20),
                proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
            ),
            ?LET(
                NGen,
                choose(0, 20),
                proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
            )
        },
        %% Generator boundary — see `valid_msgid/0`.
        begin
            Prefix = eqwalizer:dynamic_cast(PrefixGen),
            Suffix = eqwalizer:dynamic_cast(SuffixGen),
            <<Prefix/binary, 4, Suffix/binary>>
        end
    ).

%% Header serialization helpers — the dumper expects `plural_forms`
%% (the canonical body line) and `raw` (the full header text) to be
%% consistent. We keep the synthesis local so the generator stays
%% deterministic and reviewable.
plural_header_bin(1) ->
    <<"nplurals=1; plural=0;">>;
plural_header_bin(2) ->
    <<"nplurals=2; plural=(n != 1);">>;
plural_header_bin(3) ->
    <<
        "nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : "
        "n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2;"
    >>;
plural_header_bin(6) ->
    <<
        "nplurals=6; plural=n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : "
        "n%100>=3 && n%100<=10 ? 3 : "
        "n%100>=11 ? 4 : 5;"
    >>.

raw_header_bin(NPlurals) ->
    PF = plural_header_bin(NPlurals),
    <<
        "Content-Type: text/plain; charset=UTF-8\n"
        "Plural-Forms: ",
        PF/binary,
        "\n"
    >>.

%% =========================
%% Helpers
%% =========================

%% Inject zero or more escape-eligible characters into `Bin` with
%% `Probability` chance (per character). Escapes are inserted on
%% codepoint boundaries via `unicode:characters_to_list/1`, which is
%% the only safe way to splice ASCII control chars into an arbitrary
%% UTF-8 binary without splitting a multibyte sequence — a naive
%% `binary:part/3` at a random byte offset would produce invalid UTF-8
%% and trip the parser's `unicode:characters_to_binary/3` validation
%% (per PSD-002).
maybe_inject_escapes(Bin, Probability) ->
    case rand:uniform(100) =< Probability of
        true ->
            case unicode:characters_to_list(Bin, utf8) of
                CharList when is_list(CharList) ->
                    Escape = oneof_static([$\n, $\t, $", $\\]),
                    Pos =
                        case CharList of
                            [] -> 0;
                            _ -> rand:uniform(length(CharList) + 1) - 1
                        end,
                    {Before, After} = lists:split(Pos, CharList),
                    NewList = Before ++ [Escape | After],
                    unicode:characters_to_binary(NewList);
                _Err ->
                    %% Generator produced invalid UTF-8 (should not
                    %% happen with `proper_unicode:utf8/2` upstream, but
                    %% defensive nonetheless). Skip the injection.
                    Bin
            end;
        false ->
            Bin
    end.

oneof_static(Choices) ->
    Idx = rand:uniform(length(Choices)),
    lists:nth(Idx, Choices).

%% Single-entry catalog factory for P5. The header is fixed (2-form
%% English-style plural rule); we only vary `Ctx`, `Msgid`,
%% `Translation`.
make_singular_catalog(Ctx, Msgid, Translation) ->
    #{
        header => #{
            plural_forms => plural_header_bin(2),
            content_type => <<"text/plain; charset=UTF-8">>,
            charset => utf8,
            raw => raw_header_bin(2)
        },
        entries => [{singular, Ctx, Msgid, Translation}]
    }.

%% Canonicalize entries before comparison: sort by (Ctx, Msgid). The
%% parser preserves source order, but our generator may produce entries
%% that would re-sort differently if we ever switch to a deduplicating
%% representation. Sorting is the cheapest insurance against false
%% positives during shrinking.
canonicalize_entries(Entries) ->
    lists:sort(fun cmp_entry/2, Entries).

cmp_entry(A, B) ->
    key_for_sort(A) =< key_for_sort(B).

key_for_sort({singular, Ctx, Msgid, _}) -> {0, Ctx, Msgid};
key_for_sort({plural, Ctx, Msgid, _}) -> {1, Ctx, Msgid}.

%% Canonicalize a full parsed catalog: keep only the semantic fields,
%% so transient `raw` differences (e.g. trailing newline normalization)
%% do not produce false counter-examples in P2.
canonicalize_parsed(#{header := Header, entries := Entries}) ->
    Kept = maps:with([plural_forms, charset], Header),
    #{
        header => Kept,
        entries => canonicalize_entries(Entries)
    }.
