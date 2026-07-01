-module(erli18n_plural_adequacy_SUITE).

%%% =====================================================================
%%% Test-adequacy suite for `erli18n_plural`.
%%%
%%% Purpose: pin the boundary/contract behaviours that
%%% `erli18n_plural_SUITE` / `erli18n_plural_props` reach but never
%%% ASSERT, so a regression in any of the following is caught:
%%%
%%%   * the LOWER nplurals range bound (`nplurals=0`) — only the UPPER
%%%     bound (10000) is asserted (`N >= 1` guard, line 854);
%%%   * the NEGATIVE half of the `evaluate_checked/2` form-range guard
%%%     (`Form >= 0`, line 576) — only positive overflow is asserted;
%%%   * the SELECTED form for a negative cardinal flowing through a real
%%%     modulo-based CLDR rule (Russian) — totality is covered, but the
%%%     specific index (the `eval_rem` sign convention) is not;
%%%   * the exact 7-digit `nplurals` boundary (digit-cap vs range
%%%     interplay, line 845 `D > ?MAX_INT_DIGITS`);
%%%   * the exact upper boundary 1000/1001 (`N =< ?NPLURALS_MAX`);
%%%   * a constant divisor that ARITHMETICALLY evaluates to zero
%%%     (`n / (2 - 2)`) — the static-unsafe guard, line 1548;
%%%   * a large body integer literal (uncapped by digit count) degrading
%%%     to a typed `{unsafe_plural_rule, {form_out_of_range, _, _}}`;
%%%   * NUL / control / non-ASCII bytes in the plural body surfacing as a
%%%     typed `{syntax_error, {unexpected_char, _}, _}` with no crash.
%%%
%%% Each case asserts a behaviour the current `erli18n_plural` already
%%% exhibits; a regression at the named line breaks it.
%%% =====================================================================

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    nplurals_zero_lower_bound_rejected/1,
    nplurals_upper_boundary_exact/1,
    nplurals_seven_digit_routes_to_out_of_range/1,
    evaluate_checked_negative_form_reported/1,
    ru_negative_n_selects_pinned_form/1,
    constant_division_by_zero_rejected/1,
    large_body_literal_fails_soft/1,
    control_and_non_ascii_bytes_rejected/1
]).

all() ->
    [
        nplurals_zero_lower_bound_rejected,
        nplurals_upper_boundary_exact,
        nplurals_seven_digit_routes_to_out_of_range,
        evaluate_checked_negative_form_reported,
        ru_negative_n_selects_pinned_form,
        constant_division_by_zero_rejected,
        large_body_literal_fails_soft,
        control_and_non_ascii_bytes_rejected
    ].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.

%% =========================
%% Helpers (mirrors erli18n_plural_SUITE)
%% =========================

%% The Russian 3-form rule, byte-for-byte as in erli18n_plural_SUITE:193.
ru() ->
    <<
        "nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : "
        "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2;"
    >>.

compile_ok(Header) ->
    {ok, Compiled} = erli18n_plural:compile(Header),
    Compiled.

%% =========================
%% nplurals lower bound
%% =========================

%% `nplurals=0` is the min-1 lower boundary: the digit run is a single
%% byte (passes the empty-check at line 843 and the 7-digit cap at 845),
%% then `0 >= 1` is FALSE at line 854, so the range guard rejects it with
%% {nplurals_out_of_range, 0}. The existing suite asserts only the UPPER
%% bound (10000), so the `N >= 1` conjunct is reached but never fails;
%% this pins it, killing the mutant `N >= 1` -> `N >= 0` (which would let
%% nplurals=0 compile and break the pos_integer() invariant clamp_form/2
%% depends on). Exact-equality (not assertMatch) pins the reported value.
nplurals_zero_lower_bound_rejected(_Config) ->
    ?assertEqual(
        {error, {nplurals_out_of_range, 0}},
        erli18n_plural:compile(~"nplurals=0; plural=0;")
    ).

%% =========================
%% nplurals exact upper boundary
%% =========================

%% ?NPLURALS_MAX is 1000 (line 316): 1000 is the last accepted value
%% (`1000 =< 1000` true) and 1001 is the first rejected (`1001 =< 1000`
%% false). Both are 4-digit, so they clear the digit cap and exercise
%% the range check itself — killing a `=<` -> `<` mutant on line 854.
nplurals_upper_boundary_exact(_Config) ->
    Accepted = compile_ok(~"nplurals=1000; plural=0;"),
    ?assertEqual(1000, maps:get(nplurals, Accepted)),
    ?assertEqual(
        {error, {nplurals_out_of_range, 1001}},
        erli18n_plural:compile(~"nplurals=1001; plural=0;")
    ).

%% =========================
%% nplurals 7-digit boundary
%% =========================

%% "1000000" is exactly 7 bytes, so the digit cap `D > ?MAX_INT_DIGITS`
%% (7 > 7, line 845) is FALSE — it is NOT rerouted to
%% nplurals_too_many_digits — and falls through to the range check, where
%% `1000000 =< 1000` is false, yielding {nplurals_out_of_range, 1000000}.
%% Pinning the exact tag distinguishes the two rejection paths and kills
%% the off-by-one mutant `D > 7` -> `D >= 7`.
nplurals_seven_digit_routes_to_out_of_range(_Config) ->
    ?assertEqual(
        {error, {nplurals_out_of_range, 1000000}},
        erli18n_plural:compile(~"nplurals=1000000; plural=0;")
    ).

%% =========================
%% evaluate_checked/2 negative form
%% =========================

%% `nplurals=3; plural=n - 1;` compiles (it depends on n, so it is not
%% statically rejected). At N=0 the form is -1; the guard at line 576
%% `Form >= 0 andalso Form < NPlurals` short-circuits on the LOWER half
%% (`-1 >= 0` is false) and surfaces {form_out_of_range, -1, 3} rather
%% than escaping {ok, -1}. The existing suite only feeds a POSITIVE
%% out-of-range form (n + 4 -> 4), so dropping the `Form >= 0 andalso`
%% conjunct would still pass there; this kills that mutant. As a control,
%% an in-range N (3 -> form 2) must still return {ok, 2}.
evaluate_checked_negative_form_reported(_Config) ->
    C = compile_ok(~"nplurals=3; plural=n - 1;"),
    ?assertEqual(
        {error, {form_out_of_range, -1, 3}},
        erli18n_plural:evaluate_checked(C, 0)
    ),
    ?assertEqual({ok, 2}, erli18n_plural:evaluate_checked(C, 3)).

%% =========================
%% Negative N over a real modulo rule
%% =========================

%% evaluate/2 passes negative N through unchanged (no abs(), docstring
%% 470-473); Erlang `rem` truncates toward zero (line 1362), so for the
%% Russian rule N=-21 gives n%10=-1 and n%100=-21: cond1 (n%10==1) and
%% cond2 (n%10>=2) are both false, so the rule's ELSE branch selects
%% form 2 — a defined index in [0,3), no crash, NOT a clamp constant.
%% N=-11 and N=-1 likewise land on form 2. Pinning the specific index
%% (rather than merely "in range") kills an abs()/sign-flip mutant of
%% eval_rem (which would compute 21%10==1 -> form 0).
ru_negative_n_selects_pinned_form(_Config) ->
    C = compile_ok(ru()),
    ?assertEqual(2, erli18n_plural:evaluate(C, -21)),
    ?assertEqual(2, erli18n_plural:evaluate(C, -11)),
    ?assertEqual(2, erli18n_plural:evaluate(C, -1)),
    %% Cross-check via evaluate_checked/2: a genuine in-range selection,
    %% NOT a clamp masking an out-of-range value.
    ?assertEqual({ok, 2}, erli18n_plural:evaluate_checked(C, -21)).

%% =========================
%% Constant divisor that evaluates to zero
%% =========================

%% `2 - 2` is constant (is_constant/1, no `n`) and arithmetically equals
%% 0, so check_static_divisor/2 (line 1548) reaches eval_ast_checked ->
%% to_integer -> 0 and returns {division_by_zero, '/'}, wrapped by
%% compile/1 into {unsafe_plural_rule, {division_by_zero, '/'}}. This is
%% distinct from a LITERAL `/ 0` (already asserted by the existing
%% suite): a mutant that replaced the eval_ast_checked probe with a
%% literal `Divisor =:= 0` check would ACCEPT `n / (2 - 2)`; pinning the
%% rejection kills it. The `%` analogue (`3 - 3`) is checked too.
constant_division_by_zero_rejected(_Config) ->
    ?assertEqual(
        {error, {unsafe_plural_rule, {division_by_zero, '/'}}},
        erli18n_plural:compile(~"nplurals=2; plural=n / (2 - 2);")
    ),
    ?assertEqual(
        {error, {unsafe_plural_rule, {division_by_zero, '%'}}},
        erli18n_plural:compile(~"nplurals=2; plural=n % (3 - 3);")
    ).

%% =========================
%% Large body literal, uncapped by digit count
%% =========================

%% Integer literals INSIDE the expression body are not digit-capped (only
%% the `nplurals=` field is, line 851); a ~20-digit literal is consumed
%% in full (consume_integer/2). Being a wholly constant rule, validate_safe
%% probes it with static_form_in_range/2: the literal is far outside
%% [0,2), so compile/1 fails SOFT with the typed
%% {unsafe_plural_rule, {form_out_of_range, Literal, 2}} — never a crash,
%% never {ok, _}. We pin the exact literal in the payload, distinguishing
%% this body-literal path from the digit-capped nplurals field.
large_body_literal_fails_soft(_Config) ->
    ?assertEqual(
        {error, {unsafe_plural_rule, {form_out_of_range, 99999999999999999999, 2}}},
        erli18n_plural:compile(~"nplurals=2; plural=99999999999999999999;")
    ).

%% =========================
%% NUL / control / non-ASCII bytes in the body
%% =========================

%% A NUL (and a 0xFF) byte in the plural body is not whitespace, so it
%% survives skip_ws/trim into parse_primary, whose catch-all (line 1180)
%% throws {syntax_error, {unexpected_char, C}, _}: a typed error, no
%% crash. The existing syntax tests use only printable ASCII (`$@`), so
%% the non-printable bytes are an unexercised input class. We pin the
%% offending byte in the payload for each.
control_and_non_ascii_bytes_rejected(_Config) ->
    Nul = <<"nplurals=2; plural=", 0, ";">>,
    ?assertMatch(
        {error, {syntax_error, {unexpected_char, 0}, _}},
        erli18n_plural:compile(Nul)
    ),
    HighByte = <<"nplurals=2; plural=", 255, ";">>,
    ?assertMatch(
        {error, {syntax_error, {unexpected_char, 255}, _}},
        erli18n_plural:compile(HighByte)
    ).
