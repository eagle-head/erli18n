%%% =====================================================================
%%% Test-adequacy Common Test suite for `erli18n_negotiate` — the pure
%%% Phase 2 canonicalization / fallback-chain / Accept-Language engine.
%%%
%%% GENERATED FROM THE TEST-ADEQUACY AUDIT. This suite is additive: it
%%% does NOT duplicate the behavior already pinned by
%%% `erli18n_negotiate_SUITE` / `erli18n_negotiate_props`; it adds the
%%% specific VALUE oracles the audit flagged as "reached but not pinned"
%%% (surviving covered mutants) plus the documented negative contracts and
%%% totality properties that had no coverage:
%%%
%%%   * q-value fraction guard boundary (`byte_size(Frac) =< 3`): an
%%%     over-precision fraction (`q=0.1234`, `q=0.0000`) must CLAMP to full
%%%     weight (1000) and never crash — a value assertion that dies if the
%%%     guard were widened to `=< 4` (which would route a 4-byte fraction
%%%     into the 0..3-byte `pad3/1` and `function_clause`).
%%%   * `find_q/1` non-q-parameter recursion and its `[] -> 1000` base.
%%%   * `to_locale_list/2` per-consumed-cell `?MAX_RANGES` budget at its
%%%     exact 31-resolves / 32-errors off-by-one boundary.
%%%   * `override_chain/3`'s `is_binary` override filter and its
%%%     order-preserving deduplication.
%%%   * the documented `function_clause` negative contracts of
%%%     `canonicalize/1` and `parse_accept_language/1` on a non-binary arg.
%%%   * standalone totality properties for `fallback_chain/2` and
%%%     `override_chain/3`.
%%%   * a differential shape-parity oracle against cowlib's
%%%     `cow_http_hd:parse_accept_language/1` (a test-profile dependency).
%%%
%%% EXPECTATION: GREEN. Every assertion encodes the CURRENT documented and
%%% implemented behavior of `erli18n_negotiate`; the suite is expected to
%%% pass against the production source as it stands.
%%% =====================================================================
-module(erli18n_negotiate_adequacy_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

%% PropEr `?FORALL`/`?LET` generators are statically typed as `term()` by
%% eqwalizer, so every property and generator function that binds a generated
%% value carries a static `-eqwalizer({nowarn_function, F/A}).` annotation —
%% the same zero-runtime-dep pattern used in `erli18n_negotiate_props`.
-eqwalizer({nowarn_function, prop_qvalue_fraction/0}).
-eqwalizer({nowarn_function, prop_fallback_chain_total/0}).
-eqwalizer({nowarn_function, prop_override_chain_total/0}).
-eqwalizer({nowarn_function, frac_digits/0}).
-eqwalizer({nowarn_function, wild_tag/0}).
-eqwalizer({nowarn_function, tag_token/0}).
-eqwalizer({nowarn_function, override_chain_filters_non_binary_entries/1}).
-eqwalizer({nowarn_function, canonicalize_non_binary_raises_function_clause/1}).
-eqwalizer({nowarn_function, parse_accept_language_non_binary_raises_function_clause/1}).

-export([
    all/0
]).

-export([
    qvalue_fraction_over_three_digits_clamps/1,
    qvalue_fraction_value_property/1,
    find_q_non_q_param_and_base/1,
    negotiate_max_ranges_budget_boundary/1,
    override_chain_filters_non_binary_entries/1,
    override_chain_dedup_contract/1,
    canonicalize_non_binary_raises_function_clause/1,
    parse_accept_language_non_binary_raises_function_clause/1,
    fallback_chain_total_property/1,
    override_chain_total_property/1,
    parse_accept_language_cowlib_shape_parity/1
]).

%% Release-blocking QuickCheck floor (mirrors erli18n_property_SUITE).
-define(NUMTESTS, 200).

all() ->
    [
        qvalue_fraction_over_three_digits_clamps,
        qvalue_fraction_value_property,
        find_q_non_q_param_and_base,
        negotiate_max_ranges_budget_boundary,
        override_chain_filters_non_binary_entries,
        override_chain_dedup_contract,
        canonicalize_non_binary_raises_function_clause,
        parse_accept_language_non_binary_raises_function_clause,
        fallback_chain_total_property,
        override_chain_total_property,
        parse_accept_language_cowlib_shape_parity
    ].

%% =====================================================================
%% q-value fraction guard boundary (F1, F2, F3, F8, F11; remediation of F18)
%%
%% `qval_to_milli(<<"0.", Frac/binary>>) when byte_size(Frac) =< 3` is the
%% ONLY thing routing a fraction into the 0..3-byte `pad3/1`. A fraction of
%% 4+ digits FAILS the guard and clamps to full weight (1000) via the
%% catch-all — it must NOT be dropped and must NOT crash. Pinning the
%% min-1 (3-digit -> real value) and max+1 (4-digit -> 1000) cases kills a
%% `=< 3` -> `=< 4` widening (which would `function_clause` in `pad3/1`) and
%% a `=< 3` -> `=< 2` narrowing (which would clamp a valid 3-digit fraction).
%% =====================================================================
qvalue_fraction_over_three_digits_clamps(_Config) ->
    %% 3-digit fraction (max IN-grammar) goes through the real value path.
    ?assertEqual(
        [{~"de", 123}],
        erli18n_negotiate:parse_accept_language(~"de;q=0.123")
    ),
    %% 4-digit fraction (max+1) clamps to full weight, entry retained.
    ?assertEqual(
        [{~"de", 1000}],
        erli18n_negotiate:parse_accept_language(~"de;q=0.1234")
    ),
    %% The surprising case: a 4-digit ALL-ZERO fraction is NOT a well-formed
    %% q=0, so it clamps to 1000 and is KEPT (not dropped). Were the guard
    %% widened to `=< 4`, this 4-byte fraction would route into `pad3/1`
    %% (no 4-byte clause) and crash with `function_clause`.
    ?assertEqual(
        [{~"de", 1000}],
        erli18n_negotiate:parse_accept_language(~"de;q=0.0000")
    ),
    %% A 5-digit fraction likewise clamps to 1000 without raising.
    ?assertEqual(
        [{~"de", 1000}],
        erli18n_negotiate:parse_accept_language(~"de;q=0.99999")
    ),
    ok.

%% =====================================================================
%% q-value VALUE property biased to 0/1/2/3/4/5-digit fractions (F21)
%%
%% Asserts the COMPUTED milli value (not merely output shape) against an
%% independent reference, with a generator biased to the guard boundary, so
%% the documented `0.NNN` -> milli mapping and the load-bearing `=< 3` guard
%% are pinned rather than merely reached.
%% =====================================================================
qvalue_fraction_value_property(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_qvalue_fraction(),
            [{numtests, ?NUMTESTS}, {to_file, user}]
        )
    ),
    ok.

%% =====================================================================
%% find_q/1 non-q parameter recursion + `[] -> 1000` base
%% (F4, F5, F9, F12, F15; remediation of F18)
%%
%% A param-bearing element whose parameter is NOT a `q` must resolve to the
%% absent-q default (1000) via the `_ -> find_q(Rest)` skip and the
%% `find_q([]) -> 1000` base. Were the base mutated to 0, every param-bearing
%% range lacking an explicit q would drop (q=0 -> finalize skip) — so a VALUE
%% assertion on the `de;charset=utf-8 -> 1000` cases catches it.
%% =====================================================================
find_q_non_q_param_and_base(_Config) ->
    %% Non-q param, no q at all: base case `find_q([]) -> 1000`.
    ?assertEqual(
        [{~"de", 1000}],
        erli18n_negotiate:parse_accept_language(~"de;charset=utf-8")
    ),
    ?assertEqual(
        [{~"de", 1000}],
        erli18n_negotiate:parse_accept_language(~"de;foo=bar")
    ),
    ?assertEqual(
        [{~"de", 1000}],
        erli18n_negotiate:parse_accept_language(~"de;foo")
    ),
    %% Non-q param BEFORE q: the recursion clause skips it, q resolved later.
    ?assertEqual(
        [{~"de", 800}],
        erli18n_negotiate:parse_accept_language(~"de;foo=bar;q=0.8")
    ),
    ?assertEqual(
        [{~"de", 800}],
        erli18n_negotiate:parse_accept_language(~"de;foo;q=0.8")
    ),
    ?assertEqual(
        [{~"de", 800}],
        erli18n_negotiate:parse_accept_language(~"de;charset=utf-8;q=0.8")
    ),
    %% Duplicate q: the FIRST matching token wins (recursion stops at it).
    ?assertEqual(
        [{~"de", 500}],
        erli18n_negotiate:parse_accept_language(~"de;q=0.5;q=0.8")
    ),
    ok.

%% =====================================================================
%% to_locale_list/2 per-consumed-cell ?MAX_RANGES budget off-by-one
%% (F6, F13, F16, F26; remediation of F18)
%%
%% Init budget = ?MAX_RANGES (32). Every inspected cell decrements it, and
%% `to_locale_list(_, 0) -> []` short-circuits BEFORE the next cell is
%% inspected. So 31 leading wildcards leave the 32nd cell (`pt`) reachable
%% with budget 1 (resolves), but 32 leading wildcards drive budget to 0 so
%% `pt` is never inspected (errors). Pinning BOTH sides kills an
%% init-31/init-33 or a `(_,0)`->`(_,1)` base off-by-one.
%% =====================================================================
negotiate_max_ranges_budget_boundary(_Config) ->
    Pt = ~"pt",
    Prefs31 = lists:duplicate(31, ~"*") ++ [Pt],
    ?assertEqual({ok, Pt}, erli18n_negotiate:negotiate(Prefs31, [Pt])),
    Prefs32 = lists:duplicate(32, ~"*") ++ [Pt],
    ?assertEqual(error, erli18n_negotiate:negotiate(Prefs32, [Pt])),
    ok.

%% =====================================================================
%% override_chain/3 is_binary override filter (F7, F10, F14, F17;
%% remediation of F18)
%%
%% The head guard only checks `is_list(Overrides)`; the
%% `[canonicalize(X) || X <- Overrides, is_binary(X)]` filter is the SOLE
%% defense against a non-binary override reaching binary-only
%% `canonicalize/1`. A non-binary entry must be silently dropped and the call
%% must never raise. Removing the filter makes the atom/integer entries
%% `function_clause`, so the `?assertEqual` (which also asserts no-raise)
%% dies under that mutation.
%% =====================================================================
override_chain_filters_non_binary_entries(_Config) ->
    %% Atom in the middle is dropped; binaries canonicalized in order.
    ?assertEqual(
        [~"de_AT", ~"de", ~"fr", ~"en"],
        erli18n_negotiate:override_chain(~"de-AT", [~"de", foo, ~"fr"], ~"en")
    ),
    %% Atom AND integer dropped (leading + trailing).
    ?assertEqual(
        [~"de", ~"fr", ~"en"],
        erli18n_negotiate:override_chain(~"de", [foo, ~"fr", 123], ~"en")
    ),
    %% Atom + integer dropped; surviving binary canonicalized.
    ?assertEqual(
        [~"de_AT", ~"de", ~"en"],
        erli18n_negotiate:override_chain(~"de-AT", [~"de", foo, 42], ~"en")
    ),
    %% Several non-binaries among binaries: the binary-only canonical chain.
    ?assertEqual(
        [~"de", ~"fr", ~"pt_BR", ~"en"],
        erli18n_negotiate:override_chain(
            ~"de", [~"fr", 123, undefined, ~"pt-BR"], ~"en"
        )
    ),
    ok.

%% =====================================================================
%% override_chain/3 order-preserving deduplication (F24)
%%
%% The documented "Order-preserving deduplicated" contract, exercised through
%% the public entry with a duplicate-PRODUCING input (override duplicates the
%% canonical locale; default duplicates a chain entry). A no-op `dedup`
%% mutation changes the result, so the value assertion catches it.
%% =====================================================================
override_chain_dedup_contract(_Config) ->
    %% Override duplicates the canonicalized locale -> single `de`, then `en`.
    Chain1 = erli18n_negotiate:override_chain(~"de", [~"de"], ~"en"),
    ?assertEqual([~"de", ~"en"], Chain1),
    ?assertEqual(length(Chain1), length(lists:usort(Chain1))),
    %% Default duplicates a chain entry -> no trailing duplicate.
    Chain2 = erli18n_negotiate:override_chain(~"de-AT", [~"de_AT", ~"de"], ~"de"),
    ?assertEqual([~"de_AT", ~"de"], Chain2),
    ?assertEqual(length(Chain2), length(lists:usort(Chain2))),
    ok.

%% =====================================================================
%% canonicalize/1 documented negative contract (F22, F25, F27, F28)
%%
%% `canonicalize(Tag) when is_binary(Tag)` is the only clause; a non-binary
%% argument is a programmer error that must raise `function_clause`. Pinning
%% it guards against a future guard-widening that silently changes the
%% binary-in/binary-out contract.
%% =====================================================================
canonicalize_non_binary_raises_function_clause(_Config) ->
    ?assertError(function_clause, erli18n_negotiate:canonicalize(123)),
    ?assertError(function_clause, erli18n_negotiate:canonicalize(pt_br)),
    ?assertError(function_clause, erli18n_negotiate:canonicalize("string-as-list")),
    ok.

%% =====================================================================
%% parse_accept_language/1 documented negative contract (F23)
%%
%% `parse_accept_language(Bin) when is_binary(Bin)` is the only clause; a
%% non-binary argument (a string/list, or `undefined`) at the HTTP trust
%% boundary must raise `function_clause`.
%% =====================================================================
parse_accept_language_non_binary_raises_function_clause(_Config) ->
    ?assertError(function_clause, erli18n_negotiate:parse_accept_language("da, en")),
    ?assertError(function_clause, erli18n_negotiate:parse_accept_language(undefined)),
    ok.

%% =====================================================================
%% fallback_chain/2 standalone totality property (F20)
%%
%% For any binary Locale and any binary|undefined Default, `fallback_chain/2`
%% returns a non-empty, bounded (=< ?MAX_CHAIN = 8), all-binary list whose
%% head is `canonicalize(Locale)`; when Default is a binary,
%% `canonicalize(Default)` is a member (the documented floor — `dedup` may
%% drop the appended copy when it duplicates an earlier entry, so membership,
%% not last-position, is the robust invariant). It never raises.
%% =====================================================================
fallback_chain_total_property(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_fallback_chain_total(),
            [{numtests, ?NUMTESTS}, {to_file, user}]
        )
    ),
    ok.

%% =====================================================================
%% override_chain/3 standalone totality property (F29)
%%
%% For any binary Locale, ANY Overrides list (binaries mixed with atoms and
%% integers), and any binary|undefined Default, `override_chain/3` returns a
%% non-empty, bounded, all-binary list headed by `canonicalize(Locale)`,
%% dropping every non-binary entry and never raising — exercising the
%% `is_binary` filter under arbitrary input.
%% =====================================================================
override_chain_total_property(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_override_chain_total(),
            [{numtests, ?NUMTESTS}, {to_file, user}]
        )
    ),
    ok.

%% =====================================================================
%% Differential shape-parity with cowlib (F19)
%%
%% The module doc promises the output shape matches cowlib's
%% `cow_http_hd:parse_accept_language/1` so a Cowboy app may feed either into
%% `negotiate/2`. For WELL-FORMED headers with no `q=0` entry and q-values
%% already in non-increasing header order (so cowlib's header-order output
%% coincides with this parser's descending-q sort), the two parsers must
%% agree element-for-element. cowlib is a test-profile dependency (transitive
%% via cowboy).
%% =====================================================================
parse_accept_language_cowlib_shape_parity(_Config) ->
    Headers = [
        ~"da, en-gb;q=0.8, en;q=0.7",
        ~"en, en-US, en-cockney, i-cherokee, x-pig-latin, es-419"
    ],
    [
        ?assertEqual(
            cow_http_hd:parse_accept_language(H),
            erli18n_negotiate:parse_accept_language(H)
        )
     || H <- Headers
    ],
    %% Belt-and-suspenders: pin the RFC 9110 worked example to its literal
    %% shape so the parity contract is anchored even independent of cowlib.
    ?assertEqual(
        [{~"da", 1000}, {~"en-gb", 800}, {~"en", 700}],
        erli18n_negotiate:parse_accept_language(hd(Headers))
    ),
    ok.

%% =====================================================================
%% Properties
%% =====================================================================

prop_qvalue_fraction() ->
    ?FORALL(
        DigitsGen,
        frac_digits(),
        begin
            Frac = list_to_binary(DigitsGen),
            Header = <<"de;q=0.", Frac/binary>>,
            Got = erli18n_negotiate:parse_accept_language(Header),
            Expected = expected_qvalue(Frac),
            case Got =:= Expected of
                true -> true;
                false -> ct_fail("prop_qvalue_fraction", [Frac, Got, Expected])
            end
        end
    ).

prop_fallback_chain_total() ->
    ?FORALL(
        {LocaleGen, DefaultGen},
        {wild_tag(), default_gen()},
        begin
            Locale = LocaleGen,
            Default = DefaultGen,
            %% Canonicalize the generated tags HERE (inside the nowarn'd
            %% property) so the plain helper never feeds a generated `term()`
            %% into binary-only `canonicalize/1`.
            Canon = erli18n_negotiate:canonicalize(Locale),
            DefaultCanon =
                case is_binary(Default) of
                    true -> erli18n_negotiate:canonicalize(Default);
                    false -> undefined
                end,
            try erli18n_negotiate:fallback_chain(Locale, Default) of
                Chain when is_list(Chain) ->
                    check_fallback(Chain, Canon, DefaultCanon);
                Other ->
                    ct_fail("prop_fallback_chain non-list", [Other, Locale, Default])
            catch
                Class:Reason:Stack ->
                    ct_fail("prop_fallback_chain crashed", [Class, Reason, Stack, Locale, Default])
            end
        end
    ).

prop_override_chain_total() ->
    ?FORALL(
        {LocaleGen, OverridesGen, DefaultGen},
        {wild_tag(), list(override_entry()), default_gen()},
        begin
            Locale = LocaleGen,
            Overrides = OverridesGen,
            Default = DefaultGen,
            Canon = erli18n_negotiate:canonicalize(Locale),
            try erli18n_negotiate:override_chain(Locale, Overrides, Default) of
                Chain when is_list(Chain) ->
                    check_override(Chain, Canon);
                Other ->
                    ct_fail("prop_override_chain non-list", [Other, Locale, Overrides])
            catch
                Class:Reason:Stack ->
                    ct_fail("prop_override_chain crashed", [Class, Reason, Stack, Locale, Overrides])
            end
        end
    ).

%% =====================================================================
%% Property oracles / validators (plain functions)
%% =====================================================================

%% Independent reference for the milli value of `de;q=0.<Frac>` with Frac a
%% digit-only binary: <=3 digits map through the padded 3-digit integer (a
%% well-formed zero drops the entry), 4+ digits clamp to full weight (1000).
expected_qvalue(Frac) ->
    case byte_size(Frac) =< 3 of
        true ->
            case pad3_int(Frac) of
                0 -> [];
                Milli -> [{~"de", Milli}]
            end;
        false ->
            [{~"de", 1000}]
    end.

pad3_int(Frac) ->
    Padded =
        case byte_size(Frac) of
            0 -> ~"000";
            1 -> <<Frac/binary, $0, $0>>;
            2 -> <<Frac/binary, $0>>;
            3 -> Frac
        end,
    <<A, B, C>> = Padded,
    (A - $0) * 100 + (B - $0) * 10 + (C - $0).

%% `Canon` is `canonicalize(Locale)` and `DefaultCanon` is
%% `canonicalize(Default)` (or `undefined`), both computed by the caller —
%% so this helper does no binary-only SUT call on a generated value.
check_fallback(Chain, Canon, DefaultCanon) ->
    DefaultOk =
        case DefaultCanon of
            undefined -> true;
            _ -> lists:member(DefaultCanon, Chain)
        end,
    Ok =
        Chain =/= [] andalso
            length(Chain) =< 8 andalso
            lists:all(fun is_binary/1, Chain) andalso
            hd(Chain) =:= Canon andalso
            DefaultOk,
    case Ok of
        true -> true;
        false -> ct_fail("check_fallback", [Chain, Canon, DefaultCanon])
    end.

check_override(Chain, Canon) ->
    Ok =
        Chain =/= [] andalso
            length(Chain) =< 8 andalso
            lists:all(fun is_binary/1, Chain) andalso
            hd(Chain) =:= Canon,
    case Ok of
        true -> true;
        false -> ct_fail("check_override", [Chain, Canon])
    end.

ct_fail(Label, Args) ->
    ct:pal("~s: ~p~n", [Label, Args]),
    false.

%% =====================================================================
%% Generators
%% =====================================================================

%% A digit-only fraction string biased across the guard boundary: 0..5
%% digits (so 0/1/2/3 exercise the value path and 4/5 the clamp catch-all).
frac_digits() ->
    ?LET(
        L,
        list(oneof([$0, $1, $2, $3, $4, $5, $6, $7, $8, $9])),
        lists:sublist(L, 5)
    ).

%% Arbitrary tag bytes (BCP-47 alphabet plus separators/POSIX markers and the
%% occasional raw byte); may be oversized or many-subtag — exercises the
%% fail-soft bounds. Mirrors `erli18n_negotiate_props:wild_tag/0`.
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

%% A fallback/override default: a binary tag or `undefined`.
default_gen() ->
    oneof([undefined, wild_tag()]).

%% An override-list entry: mostly binary tags, sometimes a non-binary
%% (atom/integer) to exercise the `is_binary` filter.
override_entry() ->
    frequency([
        {5, wild_tag()},
        {1, oneof([foo, bar, baz, undefined])},
        {1, range(0, 1000)}
    ]).
