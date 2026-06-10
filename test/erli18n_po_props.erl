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
    prop_large_string_roundtrip/0,
    prop_parse_output_is_valid_utf8/0,
    prop_msgid_plural_roundtrip/0
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

%% Finding #11 (po-hex-octal-escape-emits-invalid-utf8) — CLOSURE
%% INVARIANT: parse output is always valid UTF-8.
%%
%% Claim: for any catalog source generated with an arbitrary charset
%% (utf8 | latin1 | us_ascii) and arbitrary `\xHH`/`\OOO` escapes
%% (including HH/OOO >= 0x80) injected into a msgstr, IF
%% `erli18n_po:parse/1` returns `{ok, Cat}`, THEN every `translation()`,
%% `msgid()` and `context()` in `Cat.entries` is valid UTF-8 — i.e.
%% `unicode:characters_to_binary(B, utf8, utf8)` returns a binary.
%%
%% This is the invariant the bug VIOLATED: `\xFF` in a UTF-8 catalog used
%% to make `parse` return `{ok, _}` with a translation containing the raw
%% byte 0xFF (invalid UTF-8 despite charset=UTF-8), which crashed
%% downstream unicode ops with badarg. The fix makes the parser either
%% transcode the escape into valid UTF-8 or fail with a structured error;
%% in NEITHER case may it return `{ok, _}` carrying invalid UTF-8.
prop_parse_output_is_valid_utf8() ->
    ?FORALL(
        SrcGen,
        po_source_with_escapes(),
        begin
            Src = eqwalizer:dynamic_cast(SrcGen),
            case erli18n_po:parse(Src) of
                {ok, #{entries := Entries}} ->
                    lists:all(fun entry_fields_valid_utf8/1, Entries);
                {error, _} ->
                    %% A structured error is an acceptable (and for
                    %% out-of-charset escapes, the correct) outcome — the
                    %% invariant only constrains the `{ok, _}` case.
                    true
            end
        end
    ).

%% Finding #14 (dump-drops-msgid-plural-silently) — CLOSURE INVARIANT:
%% `dump/1` must round-trip `msgid_plural` faithfully.
%%
%% Claim: for any well-formed plural catalog whose `.po` SOURCE declares a
%% `msgid_plural` form text DISTINCT from the singular `msgid`, the
%% `parse -> dump -> parse` cycle preserves that `msgid_plural` byte for
%% byte. The bug: the parsed `entry/0' plural shape dropped `msgid_plural'
%% entirely, so `dump/1' re-emitted the singular `msgid' in the
%% `msgid_plural' slot — silently corrupting the plural-form source text.
%%
%% We assert the invariant from the OUTSIDE: parse the generated source,
%% dump it, and verify the dumped `.po' carries the ORIGINAL
%% `msgid_plural' line (not the singular `msgid'). A re-parse round-trip
%% then confirms the value survives a full cycle. Using `ru'/`pl'/`ar'
%% style real plural rules per the finding's test note.
prop_msgid_plural_roundtrip() ->
    ?FORALL(
        SpecGen,
        plural_source_spec(),
        begin
            #{
                src := Src,
                msgid := Msgid,
                msgid_plural := MsgidPlural
            } = eqwalizer:dynamic_cast(SpecGen),
            %% Precondition: the two forms differ, so emitting the wrong
            %% one is observable.
            true = (Msgid =/= MsgidPlural),
            case erli18n_po:parse(Src) of
                {ok, Parsed} ->
                    %% (1) the parsed model must RETAIN the original plural
                    %% form (the bug dropped it). (2) a full parse∘dump∘parse
                    %% cycle must preserve it byte for byte. Comparing through
                    %% the parser sidesteps escaper-specific text-matching.
                    Retained = msgid_plural_of(Parsed) =:= MsgidPlural,
                    Dumped = erli18n_po:dump(Parsed),
                    case erli18n_po:parse(Dumped) of
                        {ok, Reparsed} ->
                            Stable =
                                msgid_plural_of(Reparsed) =:= MsgidPlural,
                            case Retained andalso Stable of
                                true ->
                                    true;
                                false ->
                                    ct:pal(
                                        "msgid_plural_roundtrip: expected "
                                        "~p~nretained=~p stable=~p~n"
                                        "dumped=~p~n",
                                        [
                                            MsgidPlural,
                                            Retained,
                                            Stable,
                                            Dumped
                                        ]
                                    ),
                                    false
                            end;
                        {error, _} = Err ->
                            ct:pal(
                                "msgid_plural_roundtrip: reparse failed "
                                "~p~ndumped=~p~n",
                                [Err, Dumped]
                            ),
                            false
                    end;
                {error, _} = Err ->
                    ct:pal(
                        "msgid_plural_roundtrip: first parse failed ~p~n"
                        "src=~p~n",
                        [Err, Src]
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
        {Ctx, Msgid, MsgidPlural, Forms},
        {valid_context(), valid_msgid(), valid_msgid(), plural_forms(NPlurals)},
        %% Finding #14: the parsed plural entry retains `msgid_plural`
        %% (4th element). The generator produces a concrete plural form
        %% (reusing `valid_msgid/0`, which yields a non-empty UTF-8 binary)
        %% so `parse∘dump` is byte-exact: the parser always materializes a
        %% concrete `msgid_plural` from the source `msgid_plural` line, and
        %% the dumper re-emits it verbatim. The `undefined` (no explicit
        %% plural-form) fallback is covered by a dedicated unit test.
        {plural, Ctx, Msgid, MsgidPlural, Forms}
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

%% Finding #14 generator: a minimal plural catalog SOURCE whose
%% `msgid_plural` form is DISTINCT from the singular `msgid`. We draw
%% from `ru`/`pl`/`ar`-style plural rules (real, multi-form) so the round
%% trip exercises 3..6 plural indices. The source is produced by the
%% library's own `dump/1` from a hand-built parsed map, guaranteeing a
%% valid `.po` regardless of which control bytes the string generators
%% emit. Returns the source plus the two canonical forms so the property
%% can assert preservation.
plural_source_spec() ->
    ?LET(
        {NPluralsGen, MsgidGen, MsgidPluralGen},
        {oneof([3, 6]), valid_msgid(), valid_msgid()},
        begin
            NPlurals = eqwalizer:dynamic_cast(NPluralsGen),
            Msgid = eqwalizer:dynamic_cast(MsgidGen),
            MsgidPluralBase = eqwalizer:dynamic_cast(MsgidPluralGen),
            %% Force distinctness: prepend a sentinel that cannot collide
            %% with the singular form (which never starts with this run).
            MsgidPlural = <<"PLURAL-", MsgidPluralBase/binary>>,
            Forms = [
                {I, <<"t", (integer_to_binary(I))/binary>>}
             || I <- lists:seq(0, NPlurals - 1)
            ],
            Catalog = #{
                header => #{
                    plural_forms => plural_header_bin(NPlurals),
                    content_type => <<"text/plain; charset=UTF-8">>,
                    charset => utf8,
                    raw => raw_header_bin(NPlurals)
                },
                entries => [{plural, undefined, Msgid, MsgidPlural, Forms}]
            },
            CatalogCast = eqwalizer:dynamic_cast(Catalog),
            Src = erli18n_po:dump(CatalogCast),
            #{src => Src, msgid => Msgid, msgid_plural => MsgidPlural}
        end
    ).

%% Extract the `msgid_plural` carried by the single plural entry of a
%% parsed catalog. Returns the binary, or `not_found` if the parsed model
%% still drops it.
msgid_plural_of(#{entries := Entries}) ->
    case [P || {plural, _Ctx, _Msgid, P, _Forms} <- Entries] of
        [MsgidPlural | _] -> MsgidPlural;
        [] -> not_found
    end.

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
key_for_sort({plural, Ctx, Msgid, _MsgidPlural, _}) -> {1, Ctx, Msgid}.

%% Canonicalize a full parsed catalog: keep only the semantic fields,
%% so transient `raw` differences (e.g. trailing newline normalization)
%% do not produce false counter-examples in P2.
canonicalize_parsed(#{header := Header, entries := Entries}) ->
    Kept = maps:with([plural_forms, charset], Header),
    #{
        header => Kept,
        entries => canonicalize_entries(Entries)
    }.

%% =========================
%% Finding #11 generators/helpers — escape injection across charsets
%% =========================

%% Generate the SOURCE BYTES of a minimal single-entry catalog whose
%% header declares a charset and whose msgstr contains an
%% adversarially-chosen escape sequence. Unlike the other generators
%% (which build a parsed map), this one produces the raw `.po` text so the
%% parser's escape-decode path is exercised end-to-end.
po_source_with_escapes() ->
    ?LET(
        {CharsetGen, EscapeGen},
        {oneof([<<"UTF-8">>, <<"ISO-8859-1">>, <<"US-ASCII">>]), escape_fragment()},
        begin
            Charset = eqwalizer:dynamic_cast(CharsetGen),
            Escape = eqwalizer:dynamic_cast(EscapeGen),
            <<
                "msgid \"\"\n"
                "msgstr \"\"\n"
                "\"Content-Type: text/plain; charset=",
                Charset/binary,
                "\\n\"\n"
                "\n"
                "msgid \"k\"\n"
                "msgstr \"x",
                Escape/binary,
                "y\"\n"
            >>
        end
    ).

%% A fragment of escape sequence(s) spliced into a msgstr. Mixes
%% always-ASCII escapes (`\n`, `\t`, `\x41`, `\101`) with high-byte
%% escapes (`\x80..\xFF`, `\200..\377`) and consecutive high-byte runs
%% (e.g. `\xC3\xBF`, a valid UTF-8 multibyte) so both the rejection and
%% the transcode paths are hit. Every character of the fragment is itself
%% ASCII, so the catalog body always survives the charset gate; only the
%% DECODED byte can be high.
escape_fragment() ->
    oneof([
        <<"\\n">>,
        <<"\\t">>,
        <<"\\x41">>,
        <<"\\101">>,
        ?LET(
            BGen,
            choose(16#80, 16#FF),
            hex_escape_bin(eqwalizer:dynamic_cast(BGen))
        ),
        ?LET(
            BGen,
            choose(16#80, 16#FF),
            octal_escape_bin(eqwalizer:dynamic_cast(BGen))
        ),
        %% Consecutive high-byte hex escapes forming a UTF-8 multibyte
        %% codepoint (U+0080..U+07FF -> two bytes 0xC2..0xDF, 0x80..0xBF).
        ?LET(
            {HiGen, LoGen},
            {choose(16#C2, 16#DF), choose(16#80, 16#BF)},
            <<
                (hex_escape_bin(eqwalizer:dynamic_cast(HiGen)))/binary,
                (hex_escape_bin(eqwalizer:dynamic_cast(LoGen)))/binary
            >>
        )
    ]).

%% Render a byte as a `\xHH` escape (two uppercase hex digits).
hex_escape_bin(Byte) when is_integer(Byte), Byte >= 0, Byte =< 16#FF ->
    Hex = string:uppercase(
        list_to_binary(io_lib:format("~2.16.0b", [Byte]))
    ),
    <<"\\x", Hex/binary>>.

%% Render a byte as a `\OOO` escape (three octal digits).
octal_escape_bin(Byte) when is_integer(Byte), Byte >= 0, Byte =< 16#FF ->
    Oct = list_to_binary(io_lib:format("~3.8.0b", [Byte])),
    <<"\\", Oct/binary>>.

%% Every text field of a parsed entry must be valid UTF-8.
entry_fields_valid_utf8({singular, Ctx, Msgid, Translation}) ->
    is_valid_utf8(Ctx) andalso
        is_valid_utf8(Msgid) andalso
        is_valid_utf8(Translation);
entry_fields_valid_utf8({plural, Ctx, Msgid, MsgidPlural, Forms}) ->
    is_valid_utf8(Ctx) andalso
        is_valid_utf8(Msgid) andalso
        is_valid_utf8(MsgidPlural) andalso
        lists:all(
            fun({_Idx, T}) -> is_valid_utf8(T) end,
            Forms
        ).

%% `undefined` context is vacuously valid; otherwise round-trip the binary
%% through the UTF-8 validator (the exact op a unicode-aware consumer runs
%% and the op that crashed with badarg on the pre-fix raw byte).
is_valid_utf8(undefined) ->
    true;
is_valid_utf8(B) when is_binary(B) ->
    is_binary(unicode:characters_to_binary(B, utf8, utf8)).
