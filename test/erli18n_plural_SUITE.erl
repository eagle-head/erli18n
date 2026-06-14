-module(erli18n_plural_SUITE).

%% Common Test suite for erli18n_plural — the recursive-descent evaluator
%% for the GNU gettext `Plural-Forms:` header expression.
%%
%% Each test case carries the source-of-truth design citation in its
%% docstring so failures point straight at the spec that motivated the
%% behaviour (PSD-004, PSD-008, BR-DESCARTAR-003, paradigm §E3).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    compile_english_n_neq_1/1,
    evaluate_english_n_eq_0/1,
    evaluate_english_n_eq_1/1,
    evaluate_english_n_eq_2/1,
    compile_french_n_gt_1/1,
    compile_russian_complex/1,
    compile_japanese_degenerate/1,
    bignum_arithmetic/1,
    bignum_huge/1,
    fallback_rule_returns_c_default/1,
    cldr_rule_known_locales/1,
    cldr_rule_unknown_locale/1,
    cldr_rule_with_region/1,
    cldr_rule_with_region_fallback/1,
    validate_against_cldr_ok/1,
    validate_against_cldr_divergence/1,
    validate_against_cldr_ast_matches_binary_api/1,
    validate_against_cldr_ast_no_recompile/1,
    syntax_error_unclosed_paren/1,
    syntax_error_invalid_op/1,
    missing_nplurals/1,
    missing_plural_expr/1,
    nplurals_out_of_range/1,
    plural_by_po_header_convenience/1,
    operator_precedence_arithmetic/1,
    operator_associativity/1,
    ternary_nested/1,
    bool_short_circuit_or/1,
    bool_short_circuit_and/1,
    not_operator/1,
    relational_ops/1,
    modulo_c_semantics/1,
    arabic_six_forms/1,
    polish_three_forms/1,
    whitespace_tolerance/1,
    form_out_of_range_clamps_to_zero/1,
    divide_by_zero_clamps_no_crash/1,
    evaluate_checked_reports_anomalies/1,
    compile_rejects_statically_unsafe_rule/1,
    %% Finding #2 (plural-compile-superlinear-unbounded): the parser must
    %% bound expression byte-length and recursion depth, and compile in
    %% linear time even on adversarial-but-trivial input.
    compile_rejects_oversized_expr/1,
    compile_rejects_deeply_nested_expr/1,
    compile_pathological_input_is_linear/1,
    %% Finding #9 (plural-bignum-cpu-dos-evaluate-hotpath): even within the
    %% byte cap, a wide flat operator chain (`n*n*...*n`) builds an AST with
    %% thousands of nodes that `evaluate/2` walks (and whose bignum grows)
    %% on EVERY ngettext call. The node-count cap rejects it at compile.
    compile_rejects_complex_expr/1,
    compile_accepts_real_world_rules_under_node_cap/1,
    %% Coverage additions — header malformed paths
    empty_nplurals_value/1,
    empty_plural_value/1,
    no_trailing_semicolon/1,
    header_with_newline_terminator/1,
    field_without_equals_then_real_field/1,
    field_with_non_delim_after_name/1,
    field_at_end_of_input/1,
    header_tab_delim/1,
    header_newline_delim/1,
    header_cr_delim/1,
    header_semicolon_delim_no_space/1,
    %% Coverage additions — parser syntax errors
    ternary_missing_colon/1,
    unknown_identifier_after_n/1,
    unexpected_char_at_primary/1,
    unexpected_eof_at_primary/1,
    not_followed_by_neq/1,
    peek2_with_single_byte_remaining/1,
    relational_lt_single_byte/1,
    relational_gt_single_byte/1,
    %% Coverage additions — CLDR + validation paths
    validate_against_unknown_locale_is_ok/1,
    validate_against_cldr_with_bad_header/1,
    cldr_rule_hyphen_region_unknown/1
]).

all() ->
    [
        compile_english_n_neq_1,
        evaluate_english_n_eq_0,
        evaluate_english_n_eq_1,
        evaluate_english_n_eq_2,
        compile_french_n_gt_1,
        compile_russian_complex,
        compile_japanese_degenerate,
        bignum_arithmetic,
        bignum_huge,
        fallback_rule_returns_c_default,
        cldr_rule_known_locales,
        cldr_rule_unknown_locale,
        cldr_rule_with_region,
        cldr_rule_with_region_fallback,
        validate_against_cldr_ok,
        validate_against_cldr_divergence,
        validate_against_cldr_ast_matches_binary_api,
        validate_against_cldr_ast_no_recompile,
        syntax_error_unclosed_paren,
        syntax_error_invalid_op,
        missing_nplurals,
        missing_plural_expr,
        nplurals_out_of_range,
        plural_by_po_header_convenience,
        operator_precedence_arithmetic,
        operator_associativity,
        ternary_nested,
        bool_short_circuit_or,
        bool_short_circuit_and,
        not_operator,
        relational_ops,
        modulo_c_semantics,
        arabic_six_forms,
        polish_three_forms,
        whitespace_tolerance,
        form_out_of_range_clamps_to_zero,
        divide_by_zero_clamps_no_crash,
        evaluate_checked_reports_anomalies,
        compile_rejects_statically_unsafe_rule,
        compile_rejects_oversized_expr,
        compile_rejects_deeply_nested_expr,
        compile_pathological_input_is_linear,
        compile_rejects_complex_expr,
        compile_accepts_real_world_rules_under_node_cap,
        %% Coverage additions
        empty_nplurals_value,
        empty_plural_value,
        no_trailing_semicolon,
        header_with_newline_terminator,
        field_without_equals_then_real_field,
        field_with_non_delim_after_name,
        field_at_end_of_input,
        header_tab_delim,
        header_newline_delim,
        header_cr_delim,
        header_semicolon_delim_no_space,
        ternary_missing_colon,
        unknown_identifier_after_n,
        unexpected_char_at_primary,
        unexpected_eof_at_primary,
        not_followed_by_neq,
        peek2_with_single_byte_remaining,
        relational_lt_single_byte,
        relational_gt_single_byte,
        validate_against_unknown_locale_is_ok,
        validate_against_cldr_with_bad_header,
        cldr_rule_hyphen_region_unknown
    ].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.

%% =========================
%% Helpers
%% =========================

eng() -> <<"nplurals=2; plural=n != 1;">>.
fre() -> <<"nplurals=2; plural=n > 1;">>.
ja() -> <<"nplurals=1; plural=0;">>.
ru() ->
    <<
        "nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : "
        "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2;"
    >>.
ar() ->
    <<
        "nplurals=6; plural=n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : "
        "n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5;"
    >>.
pl() ->
    <<
        "nplurals=3; plural=n==1 ? 0 : "
        "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2;"
    >>.

compile_ok(Header) ->
    {ok, Compiled} = erli18n_plural:compile(Header),
    Compiled.

%% =========================
%% Compile / evaluate basics (English)
%% =========================

%% English `n != 1` parses to a single `{binop, '!=', n, 1}` AST node.
compile_english_n_neq_1(_Config) ->
    Compiled = compile_ok(eng()),
    ?assertEqual(2, maps:get(nplurals, Compiled)),
    ?assertEqual({binop, '!=', n, 1}, maps:get(expr, Compiled)),
    ?assertEqual(eng(), maps:get(raw, Compiled)).

evaluate_english_n_eq_0(_Config) ->
    %% N=0 → "0 != 1" → true → form 1 (plural)
    ?assertEqual(1, erli18n_plural:evaluate(compile_ok(eng()), 0)).

evaluate_english_n_eq_1(_Config) ->
    %% N=1 → "1 != 1" → false → form 0 (singular)
    ?assertEqual(0, erli18n_plural:evaluate(compile_ok(eng()), 1)).

evaluate_english_n_eq_2(_Config) ->
    ?assertEqual(1, erli18n_plural:evaluate(compile_ok(eng()), 2)),
    ?assertEqual(1, erli18n_plural:evaluate(compile_ok(eng()), 100)).

%% =========================
%% French and Slavic
%% =========================

%% French treats 0 and 1 as singular, 2+ plural.
compile_french_n_gt_1(_Config) ->
    C = compile_ok(fre()),
    ?assertEqual(0, erli18n_plural:evaluate(C, 0)),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 2)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 50)).

%% Russian: 3 plural forms, complex modulo-based rule.
%% Known oracle values from glibc + Unicode CLDR vetting set:
%%   N=1   → 0 (one)
%%   N=2   → 1 (few)
%%   N=5   → 2 (many)
%%   N=11  → 2 (many — special case for teens)
%%   N=21  → 0 (one — ends in 1 but not 11)
%%   N=22  → 1 (few)
%%   N=25  → 2 (many)
%%   N=101 → 0 (one)
compile_russian_complex(_Config) ->
    C = compile_ok(ru()),
    ?assertEqual(3, maps:get(nplurals, C)),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 2)),
    ?assertEqual(2, erli18n_plural:evaluate(C, 5)),
    ?assertEqual(2, erli18n_plural:evaluate(C, 11)),
    ?assertEqual(0, erli18n_plural:evaluate(C, 21)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 22)),
    ?assertEqual(2, erli18n_plural:evaluate(C, 25)),
    ?assertEqual(0, erli18n_plural:evaluate(C, 101)).

%% PSD-008: degenerate plural (`nplurals=1; plural=0;`) — used by
%% ja/zh/ko/vi/th — must round-trip and return 0 for any N.
compile_japanese_degenerate(_Config) ->
    C = compile_ok(ja()),
    ?assertEqual(1, maps:get(nplurals, C)),
    %% the literal 0
    ?assertEqual(0, maps:get(expr, C)),
    [
        ?assertEqual(0, erli18n_plural:evaluate(C, N))
     || N <- [0, 1, 2, 5, 100, 1000, 1 bsl 32]
    ].

%% =========================
%% Bignum support (scenario 7 of 09-edge-cases.feature)
%% =========================

%% N = 2^31 (just past int32 boundary).
bignum_arithmetic(_Config) ->
    C = compile_ok(ru()),
    %% 2147483648
    N = 1 bsl 31,
    %% N=2147483648, N%10=8, N%100=48 → not 1 form, not 1..4 form → 2 (many)
    ?assertEqual(2, erli18n_plural:evaluate(C, N)).

%% N = 10^13 — bignum well beyond any native integer width.
bignum_huge(_Config) ->
    C = compile_ok(ru()),
    N = 9999999999999,
    %% N%10=9, N%100=99 → falls to form 2 (many)
    ?assertEqual(2, erli18n_plural:evaluate(C, N)),
    %% Larger still
    ?assertEqual(2, erli18n_plural:evaluate(C, 1 bsl 100)).

%% =========================
%% Fallback rule
%% =========================

%% PSD-004 / GNU manual: when a .po has no Plural-Forms header at all,
%% the C/English Germanic default applies.
fallback_rule_returns_c_default(_Config) ->
    ?assertEqual(
        <<"nplurals=2; plural=n != 1;">>,
        erli18n_plural:fallback_rule()
    ),
    %% And it must itself round-trip through compile/evaluate.
    C = compile_ok(erli18n_plural:fallback_rule()),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 2)).

%% =========================
%% CLDR data table lookups
%% =========================

cldr_rule_known_locales(_Config) ->
    ?assertMatch({ok, _}, erli18n_plural:cldr_rule(<<"en">>)),
    ?assertMatch({ok, _}, erli18n_plural:cldr_rule(<<"fr">>)),
    ?assertMatch({ok, _}, erli18n_plural:cldr_rule(<<"ja">>)),
    ?assertMatch({ok, _}, erli18n_plural:cldr_rule(<<"ru">>)),
    {ok, JaExpr} = erli18n_plural:cldr_rule(<<"ja">>),
    ?assertEqual(<<"0">>, JaExpr).

cldr_rule_unknown_locale(_Config) ->
    %% A locale guaranteed not to be in the v0.1 table.
    ?assertEqual(undefined, erli18n_plural:cldr_rule(<<"xx">>)),
    ?assertEqual(undefined, erli18n_plural:cldr_rule(<<"zz_QQ">>)).

cldr_rule_with_region(_Config) ->
    %% pt_BR is explicitly listed in the table.
    ?assertMatch(
        {ok, <<"n > 1">>},
        erli18n_plural:cldr_rule(<<"pt_BR">>)
    ).

%% Decision: when the region tag is unknown, fall back to the base
%% language tag. fr_BE is not in the table but fr is — return the fr
%% rule. Documented in src/erli18n_plural.erl on `cldr_rule/1`.
cldr_rule_with_region_fallback(_Config) ->
    {ok, BaseExpr} = erli18n_plural:cldr_rule(<<"fr">>),
    ?assertMatch(
        {ok, BaseExpr},
        erli18n_plural:cldr_rule(<<"fr_BE">>)
    ),
    %% Also for hyphen-separated BCP47 region tags.
    ?assertMatch(
        {ok, BaseExpr},
        erli18n_plural:cldr_rule(<<"fr-BE">>)
    ).

%% =========================
%% CLDR divergence
%% =========================

%% Header that matches CLDR canonical English rule should be ok.
validate_against_cldr_ok(_Config) ->
    ?assertEqual(
        ok,
        erli18n_plural:validate_against_cldr(<<"en">>, eng())
    ),
    %% The French header `n > 1` matches CLDR fr.
    ?assertEqual(
        ok,
        erli18n_plural:validate_against_cldr(<<"fr">>, fre())
    ),
    %% Whitespace differences must not trigger a warning.
    ?assertEqual(
        ok,
        erli18n_plural:validate_against_cldr(
            <<"en">>, <<"nplurals=2;  plural= n != 1 ;">>
        )
    ).

%% English `n != 1` declared for French (CLDR says `n > 1`) is a real
%% divergence — must produce a warning, not an error.
validate_against_cldr_divergence(_Config) ->
    Result = erli18n_plural:validate_against_cldr(<<"fr">>, eng()),
    ?assertMatch({warning, {plural_divergence, <<"fr">>, _, _}}, Result),
    {warning, {plural_divergence, _Locale, Hdr, Cldr}} = Result,
    ?assertEqual(eng(), Hdr),
    ?assert(is_binary(Cldr)).

%% Finding #17: the load path keeps the header AST already compiled by
%% `compile/1` and must reuse it for the (informational) CLDR divergence
%% check. `validate_against_cldr_ast/2` takes the compiled bundle and is
%% the variant the loader calls — it must agree, case for case, with the
%% binary-string `validate_against_cldr/2` for ok, divergence, and
%% unknown-locale outcomes (header always wins at runtime, PSD-004).
validate_against_cldr_ast_matches_binary_api(_Config) ->
    Cases = [
        %% {Locale, HeaderBinary}
        {<<"en">>, eng()},
        {<<"fr">>, fre()},
        %% English rule declared for French is a real divergence.
        {<<"fr">>, eng()},
        %% Russian 3-form canonical header.
        {<<"ru">>, <<
            "nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : "
            "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2;"
        >>},
        %% Portuguese (CLDR `n > 1`) matched and diverging.
        {<<"pt">>, <<"nplurals=2; plural=n > 1;">>},
        {<<"pt">>, eng()},
        %% Locale absent from the CLDR table — both must early-return ok.
        {<<"qq_QQ">>, eng()}
    ],
    lists:foreach(
        fun({Locale, Header}) ->
            {ok, Compiled} = erli18n_plural:compile(Header),
            Expected = erli18n_plural:validate_against_cldr(Locale, Header),
            Actual = erli18n_plural:validate_against_cldr_ast(Locale, Compiled),
            ?assertEqual(
                normalise_divergence(Expected),
                normalise_divergence(Actual),
                {Locale, Header}
            )
        end,
        Cases
    ).

%% Both APIs return the divergence payload with the locale and two binary
%% rule strings; the AST variant must surface the same locale and the same
%% header binary (the `raw` field of the compiled bundle). We compare the
%% shape that the loader actually consumes.
normalise_divergence(ok) ->
    ok;
normalise_divergence({warning, {plural_divergence, Loc, _Hdr, _Cldr}}) ->
    %% Compare on locale only for the divergence tag — both variants must
    %% agree on WHETHER it diverges and on WHICH locale, which is what the
    %% loader keys on. (The header/cldr binaries are asserted separately in
    %% the dedicated tests above.)
    {warning, plural_divergence, Loc}.

%% Finding #17 (core regression): the loader already compiled the header
%% via `compile/1` and the CLDR table is a static constant — so checking
%% divergence with the COMPILED bundle must NOT recompile the header a
%% second time, nor compile a CLDR rule on the hot path. We trace every
%% call to `erli18n_plural:compile/1` while running the AST-based check and
%% assert ZERO further compiles happen. Against the pre-fix code (which has
%% no AST variant and re-parses through `split_rule -> compile`), this test
%% cannot even compile/link the call — and once the variant exists but is
%% naive, the trace count is non-zero. The fixed code precomputes the CLDR
%% ASTs and reuses the passed-in bundle, so the count is 0.
validate_against_cldr_ast_no_recompile(_Config) ->
    %% Divergent case for a CLDR-listed locale exercises the full compare
    %% path (both nplurals and expr are inspected, CLDR side is consulted).
    {ok, Compiled} = erli18n_plural:compile(eng()),
    %% Warm any one-time memoised CLDR-AST table BEFORE we start counting,
    %% so the first-load amortised cost is not attributed to the per-load
    %% divergence check we are measuring.
    _ = erli18n_plural:validate_against_cldr_ast(<<"fr">>, Compiled),
    Count = count_plural_compiles(fun() ->
        erli18n_plural:validate_against_cldr_ast(<<"fr">>, Compiled)
    end),
    ?assertEqual(
        0,
        Count,
        {header_recompiled_on_divergence_path, Count}
    ).

%% Count calls to `erli18n_plural:compile/1` made (in any process) while
%% `Fun` runs, using OTP call tracing — no external mocking dependency.
count_plural_compiles(Fun) ->
    Self = self(),
    Collector = spawn(fun() -> compile_trace_loop(Self, 0) end),
    erlang:trace(all, true, [call, {tracer, Collector}]),
    erlang:trace_pattern(
        {erli18n_plural, compile, 1}, true, [global]
    ),
    try
        Fun()
    after
        erlang:trace_pattern({erli18n_plural, compile, 1}, false, [global]),
        erlang:trace(all, false, [call])
    end,
    Collector ! {count, self()},
    receive
        {compile_count, N} -> N
    after 5000 ->
        ct:fail(trace_collector_timeout)
    end.

compile_trace_loop(Owner, N) ->
    receive
        {trace, _Pid, call, {erli18n_plural, compile, _Args}} ->
            compile_trace_loop(Owner, N + 1);
        {count, From} ->
            From ! {compile_count, N};
        _Other ->
            compile_trace_loop(Owner, N)
    end.

%% =========================
%% Error reporting
%% =========================

syntax_error_unclosed_paren(_Config) ->
    Bad = <<"nplurals=2; plural=(n != 1;">>,
    ?assertMatch(
        {error, {syntax_error, _, _}},
        erli18n_plural:compile(Bad)
    ).

syntax_error_invalid_op(_Config) ->
    Bad = <<"nplurals=2; plural=n @ 1;">>,
    ?assertMatch(
        {error, _},
        erli18n_plural:compile(Bad)
    ).

missing_nplurals(_Config) ->
    Bad = <<"plural=n != 1;">>,
    ?assertMatch(
        {error, {missing_nplurals, _}},
        erli18n_plural:compile(Bad)
    ).

missing_plural_expr(_Config) ->
    Bad = <<"nplurals=2;">>,
    ?assertMatch(
        {error, {missing_plural_expr, _}},
        erli18n_plural:compile(Bad)
    ).

nplurals_out_of_range(_Config) ->
    Bad = <<"nplurals=10000; plural=0;">>,
    ?assertMatch(
        {error, {nplurals_out_of_range, 10000}},
        erli18n_plural:compile(Bad)
    ).

%% =========================
%% Convenience entry point
%% =========================

plural_by_po_header_convenience(_Config) ->
    ?assertEqual(
        {ok, 1},
        erli18n_plural:plural_by_po_header(eng(), 5)
    ),
    ?assertEqual(
        {ok, 0},
        erli18n_plural:plural_by_po_header(eng(), 1)
    ),
    %% Error path also propagates.
    ?assertMatch(
        {error, _},
        erli18n_plural:plural_by_po_header(
            <<"nplurals=2; plural=(n;">>, 0
        )
    ).

%% =========================
%% Operator semantics
%% =========================

%% Custom valid header exercising arithmetic precedence:
%%   (2 + 3) * 4 = 20  vs.  2 + 3 * 4 = 14
operator_precedence_arithmetic(_Config) ->
    C1 = compile_ok(<<"nplurals=21; plural=(2 + 3) * 4;">>),
    ?assertEqual(20, erli18n_plural:evaluate(C1, 0)),
    C2 = compile_ok(<<"nplurals=15; plural=2 + 3 * 4;">>),
    ?assertEqual(14, erli18n_plural:evaluate(C2, 0)).

%% Left-associativity for `-`: 1 - 2 - 3 must be -4 not 2.
%% (NPlurals must be > result; we declare 1000 which is the cap.)
operator_associativity(_Config) ->
    %% Use small calculation that produces a non-negative form index.
    %% 10 - 5 - 2 = 3 (left-assoc) vs 7 (right-assoc).
    C = compile_ok(<<"nplurals=10; plural=10 - 5 - 2;">>),
    ?assertEqual(3, erli18n_plural:evaluate(C, 0)).

%% Nested ternary: right-associative per C.
%% `n==0 ? 0 : n==1 ? 1 : 2`
ternary_nested(_Config) ->
    C = compile_ok(<<"nplurals=3; plural=n==0 ? 0 : n==1 ? 1 : 2;">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 0)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(2, erli18n_plural:evaluate(C, 2)),
    ?assertEqual(2, erli18n_plural:evaluate(C, 5)).

%% Short-circuit OR: when the left side is truthy, the right side
%% (which would crash) must not be evaluated.
bool_short_circuit_or(_Config) ->
    C = compile_ok(<<"nplurals=2; plural=n==0 || (10/n) > 1;">>),
    %% N=0 → left is true → right not evaluated, no division by zero.
    ?assertEqual(1, erli18n_plural:evaluate(C, 0)).

%% Short-circuit AND: when the left side is false, the right side
%% (which would crash) must not be evaluated.
bool_short_circuit_and(_Config) ->
    C = compile_ok(<<"nplurals=2; plural=n!=0 && (10/n) > 1;">>),
    %% N=0 → left is false → right not evaluated, no division by zero.
    ?assertEqual(0, erli18n_plural:evaluate(C, 0)),
    %% N=5 → left true, right also true (10/5 = 2 > 1) → 1.
    ?assertEqual(1, erli18n_plural:evaluate(C, 5)),
    %% N=20 → left true, right false (10/20 = 0, not > 1) → 0.
    ?assertEqual(0, erli18n_plural:evaluate(C, 20)).

%% !N inverts truthiness: !0 = 1, !1 = 0, !5 = 0.
not_operator(_Config) ->
    C = compile_ok(<<"nplurals=2; plural=!n;">>),
    ?assertEqual(1, erli18n_plural:evaluate(C, 0)),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(0, erli18n_plural:evaluate(C, 5)).

%% Relational operators each return 0/1.
relational_ops(_Config) ->
    [
        begin
            Bin = <<"nplurals=2; plural=", Expr/binary, ";">>,
            ?assertEqual(
                Expected,
                erli18n_plural:evaluate(compile_ok(Bin), N)
            )
        end
     || {Expr, N, Expected} <-
            [
                {<<"n < 5">>, 3, 1},
                {<<"n < 5">>, 5, 0},
                {<<"n > 5">>, 7, 1},
                {<<"n > 5">>, 3, 0},
                {<<"n <= 5">>, 5, 1},
                {<<"n >= 5">>, 5, 1},
                {<<"n == 0">>, 0, 1},
                {<<"n == 0">>, 1, 0},
                {<<"n != 0">>, 1, 1}
            ]
    ].

%% Modulo follows C semantics (truncation toward zero, matches Erlang rem).
modulo_c_semantics(_Config) ->
    C = compile_ok(<<"nplurals=10; plural=n % 10;">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 0)),
    ?assertEqual(3, erli18n_plural:evaluate(C, 13)),
    ?assertEqual(9, erli18n_plural:evaluate(C, 99)),
    ?assertEqual(0, erli18n_plural:evaluate(C, 100)).

%% Arabic has 6 plural forms. CLDR vetting set:
%%   N=0   → 0 (zero)
%%   N=1   → 1 (one)
%%   N=2   → 2 (two)
%%   N=3   → 3 (few)
%%   N=11  → 4 (many)
%%   N=100 → 5 (other)
arabic_six_forms(_Config) ->
    C = compile_ok(ar()),
    ?assertEqual(6, maps:get(nplurals, C)),
    ?assertEqual(0, erli18n_plural:evaluate(C, 0)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(2, erli18n_plural:evaluate(C, 2)),
    ?assertEqual(3, erli18n_plural:evaluate(C, 3)),
    ?assertEqual(3, erli18n_plural:evaluate(C, 10)),
    ?assertEqual(4, erli18n_plural:evaluate(C, 11)),
    ?assertEqual(5, erli18n_plural:evaluate(C, 100)).

%% Polish: similar to Russian but special-cases N=1.
polish_three_forms(_Config) ->
    C = compile_ok(pl()),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 2)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 3)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 4)),
    ?assertEqual(2, erli18n_plural:evaluate(C, 5)),
    ?assertEqual(2, erli18n_plural:evaluate(C, 11)),
    ?assertEqual(2, erli18n_plural:evaluate(C, 12)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 22)).

%% Tolerate generous whitespace in both header and expression body.
whitespace_tolerance(_Config) ->
    Header = <<"  nplurals  =  2  ;  plural  =  n != 1  ;  ">>,
    C = compile_ok(Header),
    ?assertEqual(2, maps:get(nplurals, C)),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 2)).

%% A malformed .po that produces a form index outside [0, NPlurals)
%% must NOT crash the caller — per finding #1 (plural-eval-throws-per-
%% lookup-dos), `evaluate/2` is the hot path of every ngettext lookup,
%% so it has to be total. The reference runtime (GNU libintl
%% `dcigettext.c` / `plural_lookup`) clamps an out-of-range index to
%% form 0 ("this should never happen" -> clamp, NOT crash) rather than
%% raising. We mirror that: any value outside [0, NPlurals) clamps to 0.
form_out_of_range_clamps_to_zero(_Config) ->
    %% Header declares 2 forms but `n + 4` returns 4 at N=0 — out of
    %% range. The rule depends on `n`, so it is NOT statically rejected
    %% at compile (that path is covered by
    %% compile_rejects_statically_unsafe_rule/1); it reaches the runtime
    %% clamp instead. N=0 -> 4 -> clamp to 0.
    C = compile_ok(<<"nplurals=2; plural=n + 4;">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 0)),
    %% A negative form index (`n - 1` at N=0 -> -1) also clamps to 0,
    %% not a crash. nplurals must exceed any legitimate result, so we
    %% declare 3 and feed N=0 -> n - 1 = -1 -> clamp to 0.
    CNeg = compile_ok(<<"nplurals=3; plural=n - 1;">>),
    ?assertEqual(0, erli18n_plural:evaluate(CNeg, 0)),
    %% In-range results are returned unchanged.
    ?assertEqual(2, erli18n_plural:evaluate(CNeg, 3)).

%% Division / modulo by zero in an untrusted plural rule must NOT raise
%% `badarith` in the caller (finding #1, failure mode (a)). The total
%% evaluator coerces a zero divisor to a defined result (C UB pinned to
%% 0) so the lookup degrades gracefully instead of killing the request
%% process. The whole expression result is still clamped into range.
divide_by_zero_clamps_no_crash(_Config) ->
    %% Divisor that is zero only for a specific N — `n / (n - 5)` at N=5.
    %% The divisor depends on `n`, so this is NOT statically rejected at
    %% compile (a literal `/ 0` would be — see
    %% compile_rejects_statically_unsafe_rule/1); it reaches the runtime
    %% guard `eval_div/2`, which pins the zero-divisor result to 0.
    CDiv = compile_ok(<<"nplurals=2; plural=n / (n - 5);">>),
    ?assertEqual(0, erli18n_plural:evaluate(CDiv, 5)),
    %% and well-defined elsewhere: N=15 -> 15 / 10 = 1.
    ?assertEqual(1, erli18n_plural:evaluate(CDiv, 15)),
    %% Modulo by a dynamically-zero divisor — `n % (n - 5)` at N=5 —
    %% likewise degrades via `eval_rem/2` instead of raising badarith.
    CRem = compile_ok(<<"nplurals=2; plural=n % (n - 5);">>),
    ?assertEqual(0, erli18n_plural:evaluate(CRem, 5)),
    %% N=7 -> 7 % 2 = 1 (in range).
    ?assertEqual(1, erli18n_plural:evaluate(CRem, 7)).

%% `evaluate_checked/2` is the structured, honest sibling of the total
%% `evaluate/2`: callers that want to OBSERVE an unsafe rule as data
%% (rather than have it silently clamped) get `{ok, Index}` on success
%% and `{error, plural_eval_error()}` on division-by-zero / out-of-range.
evaluate_checked_reports_anomalies(_Config) ->
    %% Well-formed rule: {ok, Index}.
    COk = compile_ok(eng()),
    ?assertEqual({ok, 0}, erli18n_plural:evaluate_checked(COk, 1)),
    ?assertEqual({ok, 1}, erli18n_plural:evaluate_checked(COk, 2)),
    %% Out-of-range form (dynamic — `n + 4` at N=0 -> 4) reported as a
    %% structured error rather than clamped or crashed.
    COor = compile_ok(<<"nplurals=2; plural=n + 4;">>),
    ?assertEqual(
        {error, {form_out_of_range, 4, 2}},
        erli18n_plural:evaluate_checked(COor, 0)
    ),
    %% Division by zero (dynamic — divisor is 0 only at N=5) -> structured
    %% error naming the operator.
    CDiv = compile_ok(<<"nplurals=2; plural=n / (n - 5);">>),
    ?assertEqual(
        {error, {division_by_zero, '/'}},
        erli18n_plural:evaluate_checked(CDiv, 5)
    ),
    CRem = compile_ok(<<"nplurals=2; plural=n % (n - 5);">>),
    ?assertEqual(
        {error, {division_by_zero, '%'}},
        erli18n_plural:evaluate_checked(CRem, 5)
    ),
    %% And the same rules return {ok, Index} where well-defined.
    ?assertEqual({ok, 1}, erli18n_plural:evaluate_checked(CDiv, 15)).

%% Layer 3 (static rejection at load): a rule that is STATICALLY
%% guaranteed to fault — a literal division by zero or a constant form
%% provably out of range — is rejected by `compile/1` with a structured
%% `{unsafe_plural_rule, _}` error, so the poisoned catalog is refused
%% at `ensure_loaded` time rather than loading as `{ok, _}`.
compile_rejects_statically_unsafe_rule(_Config) ->
    %% Literal division by zero.
    ?assertMatch(
        {error, {unsafe_plural_rule, {division_by_zero, '/'}}},
        erli18n_plural:compile(<<"nplurals=2; plural=n / 0;">>)
    ),
    ?assertMatch(
        {error, {unsafe_plural_rule, {division_by_zero, '%'}}},
        erli18n_plural:compile(<<"nplurals=2; plural=n % 0;">>)
    ),
    %% Constant form index provably out of range.
    ?assertMatch(
        {error, {unsafe_plural_rule, {form_out_of_range, 5, 2}}},
        erli18n_plural:compile(<<"nplurals=2; plural=5;">>)
    ).

%% =========================
%% Finding #2 — compile is O(n) and bounded (plural-compile-superlinear)
%% =========================

%% A `Plural-Forms` expression whose byte-length exceeds the parser cap
%% is rejected up front with a structured `{expr_too_long, Size, Max}`
%% error — the catalog is refused at `ensure_loaded` time rather than
%% triggering the O(n^2) parse and freezing the gen_server. NPlurals
%% stays in range so the rejection comes from the length bound, not the
%% nplurals sanity check. The real-world most-complex rule (Arabic) is
%% ~98 bytes, so any legitimate catalog is far below the cap.
compile_rejects_oversized_expr(_Config) ->
    %% `n+n+...+n` repeated until well past ?PLURAL_EXPR_MAX_BYTES (2048).
    Body = repeat_join(<<"n">>, <<"+">>, 4000),
    Header = <<"nplurals=2; plural=", Body/binary, ";">>,
    ?assertMatch(
        {error, {expr_too_long, _, _}},
        erli18n_plural:compile(Header)
    ),
    %% The reported size/limit are coherent: Size > Max.
    {error, {expr_too_long, Size, Max}} = erli18n_plural:compile(Header),
    ?assert(is_integer(Size) andalso is_integer(Max) andalso Size > Max).

%% A deeply nested expression (within the byte cap) that would otherwise
%% recurse unbounded — `(((...n...)))` — is rejected with a structured
%% `{expr_too_deep, Depth, Pos}` error, bounding parser (and downstream
%% evaluator) stack growth. We keep the body under the byte cap so the
%% depth guard, not the length guard, is what fires.
compile_rejects_deeply_nested_expr(_Config) ->
    %% 600 nested parens around `n` is ~1201 bytes (< 2048 cap) but far
    %% deeper than ?PLURAL_EXPR_MAX_DEPTH (64).
    Depth = 600,
    Opens = binary:copy(<<"(">>, Depth),
    Closes = binary:copy(<<")">>, Depth),
    Body = <<Opens/binary, "n", Closes/binary>>,
    ?assert(byte_size(Body) < 2048),
    Header = <<"nplurals=2; plural=", Body/binary, ";">>,
    ?assertMatch(
        {error, {expr_too_deep, _, _}},
        erli18n_plural:compile(Header)
    ).

%% Regression for the O(n^2) `skip_ws_st/1` equality match: compiling a
%% large-but-trivial VALID expression must stay within a generous linear
%% time budget. Before the fix a ~390 KB expression froze the parser for
%% seconds; a regression to the quadratic match would blow this budget by
%% orders of magnitude. With the finding #9 node cap (?AST_MAX_NODES =
%% 256) the largest expression that still compiles to `{ok, _}` is a
%% 128-term chain (255 nodes); we use exactly that — the biggest valid
%% input — so the parser still runs the full O(n) per-token scan rather
%% than short-circuiting on a length/node guard, and assert it returns
%% well under 50 ms. (Larger byte inputs are covered by
%% `compile_rejects_complex_expr` / `compile_rejects_oversized_expr`,
%% which assert the fail-closed rejection also returns quickly.)
compile_pathological_input_is_linear(_Config) ->
    %% `n+n+...+n` (no leading whitespace) is the exact shape that
    %% triggered the quadratic full-binary `=:=` in skip_ws_st/1. 128
    %% terms => 2*128-1 = 255 AST nodes, the most the node cap permits.
    Terms = 128,
    Body = repeat_join(<<"n">>, <<"+">>, Terms),
    ?assert(byte_size(Body) =< 2048),
    Header = <<"nplurals=2; plural=", Body/binary, ";">>,
    {Micros, Result} = timer:tc(fun() -> erli18n_plural:compile(Header) end),
    ?assertMatch({ok, _}, Result),
    ?assert(
        Micros < 50_000,
        lists:flatten(
            io_lib:format("compile took ~p us (budget 50000 us)", [Micros])
        )
    ).

%% =========================
%% Finding #9 — compile bounds AST node count (plural-bignum-cpu-dos)
%% =========================

%% A wide, flat operator chain (`n*n*...*n`) stays UNDER the byte cap and
%% UNDER the recursion-depth cap (the chain is left-associative, so it
%% does not nest the parser), yet it builds an AST with thousands of nodes.
%% `evaluate/2` would walk that whole tree — and grow an `n^k` bignum — on
%% EVERY ngettext call (uncached per-lookup amplification). The node-count
%% cap (`?AST_MAX_NODES`) rejects it at compile time with a structured
%% `{expr_too_complex, Nodes, Max}` error, complementing finding #2's byte
%% and depth caps. The real-world most-complex rule (Russian/Arabic) has
%% ~39 nodes, so the cap leaves generous headroom for any legitimate rule.
compile_rejects_complex_expr(_Config) ->
    %% 1000-factor multiply chain: ~1999 bytes (< 2048 byte cap) and a
    %% single multiplicative level (< 64 depth cap), so neither the
    %% length nor the depth guard fires — only the node-count guard does.
    Factors = 1000,
    Body = repeat_join(<<"n">>, <<"*">>, Factors),
    ?assert(byte_size(Body) =< 2048),
    Header = <<"nplurals=2; plural=", Body/binary, ";">>,
    {Micros, Result} = timer:tc(fun() -> erli18n_plural:compile(Header) end),
    ?assertMatch({error, {expr_too_complex, _, _}}, Result),
    %% The node guard short-circuits, so even the rejection path is fast.
    ?assert(
        Micros < 50_000,
        lists:flatten(
            io_lib:format("compile took ~p us (budget 50000 us)", [Micros])
        )
    ),
    %% The reported node count / limit are coherent: Nodes > Max.
    {error, {expr_too_complex, Nodes, Max}} = Result,
    ?assert(is_integer(Nodes) andalso is_integer(Max) andalso Nodes > Max).

%% The node-count cap must not reject any legitimate rule. The most
%% complex real-world rules (Arabic 6-form, Russian/Ukrainian 3-form,
%% Slovenian 4-form) sit far under ?AST_MAX_NODES; they must still
%% compile cleanly to `{ok, _}`.
compile_accepts_real_world_rules_under_node_cap(_Config) ->
    Arabic =
        <<
            "nplurals=6; plural=n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : "
            "n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5;"
        >>,
    Russian =
        <<
            "nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : "
            "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2;"
        >>,
    Slovenian =
        <<
            "nplurals=4; plural=n%100==1 ? 0 : n%100==2 ? 1 : "
            "n%100==3 || n%100==4 ? 2 : 3;"
        >>,
    ?assertMatch({ok, _}, erli18n_plural:compile(Arabic)),
    ?assertMatch({ok, _}, erli18n_plural:compile(Russian)),
    ?assertMatch({ok, _}, erli18n_plural:compile(Slovenian)).

%% Build `Item Sep Item Sep ... Item` with Count items. Used to
%% synthesise the pathological-but-valid plural expressions above
%% without embedding a multi-KB literal in the source.
repeat_join(Item, _Sep, 1) ->
    Item;
repeat_join(Item, Sep, Count) when Count > 1 ->
    Tail = repeat_join(Item, Sep, Count - 1),
    <<Item/binary, Sep/binary, Tail/binary>>.

%% =========================
%% Header malformed paths (parser tokenizer)
%% =========================

%% `nplurals=` with no digits is treated as missing, not as `0`.
%% Exercises the empty-digits branch in extract_nplurals/1.
empty_nplurals_value(_Config) ->
    ?assertMatch(
        {error, {missing_nplurals, _}},
        erli18n_plural:compile(<<"nplurals=; plural=n != 1;">>)
    ).

%% `plural=` followed by only whitespace / nothing trims to empty and
%% reports missing_plural_expr (distinct from "no plural= at all").
%% Also exercises trim_trailing reaching its base case N=0.
empty_plural_value(_Config) ->
    ?assertMatch(
        {error, {missing_plural_expr, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=;">>)
    ),
    %% Whitespace-only body also trims to empty.
    ?assertMatch(
        {error, {missing_plural_expr, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=   ;">>)
    ).

%% Headers without a trailing `;` after the plural expression are
%% accepted (lenient per GNU gettext practice) — exercises the
%% take_until_semicolon_or_end "end of binary" branch.
no_trailing_semicolon(_Config) ->
    C = compile_ok(<<"nplurals=2; plural=n != 1">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 2)).

%% A `\n` in the body terminates the plural expression (line
%% terminator inside multi-line PO headers).
header_with_newline_terminator(_Config) ->
    C = compile_ok(<<"nplurals=2; plural=n != 1\nignored after newline">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 5)).

%% First occurrence of `nplurals` is a bare word with no `=` after it;
%% parser must skip past and find the real `nplurals=` later in the
%% header. Exercises the not_found branch of skip_to_equals (re-iterates
%% the search) plus the `;` boundary predicate.
field_without_equals_then_real_field(_Config) ->
    Header = <<"nplurals foo;nplurals=2;plural=n != 1;">>,
    C = compile_ok(Header),
    ?assertEqual(2, maps:get(nplurals, C)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 0)).

%% A non-`=`, non-whitespace char immediately after the field name is
%% rejected by skip_to_equals/1 (exercises its `_` clause).
field_with_non_delim_after_name(_Config) ->
    %% `nplurals!2` does not equal-bind nplurals; the parser keeps
    %% scanning, finds no real `nplurals=`, reports missing.
    ?assertMatch(
        {error, {missing_nplurals, _}},
        erli18n_plural:compile(<<"nplurals!2; plural=0;">>)
    ).

%% Header ends exactly at the field name with no `=` (empty tail) —
%% exercises skip_to_equals(<<>>) -> not_found.
field_at_end_of_input(_Config) ->
    ?assertMatch(
        {error, {missing_nplurals, _}},
        erli18n_plural:compile(<<"nplurals">>)
    ).

%% A literal `\t` to the left of `plural` qualifies as a field
%% boundary. Exercises is_header_delim($\t).
header_tab_delim(_Config) ->
    C = compile_ok(<<"nplurals=2;\tplural=n != 1;">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 3)).

%% Newline boundary between fields (real-world multi-line PO header).
header_newline_delim(_Config) ->
    C = compile_ok(<<"nplurals=2;\nplural=n != 1;">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 7)).

%% Carriage-return boundary (Windows-style line endings in PO files).
header_cr_delim(_Config) ->
    C = compile_ok(<<"nplurals=2;\rplural=n != 1;">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 2)).

%% `;` directly preceding the field name (no whitespace) — exercises
%% is_header_delim($;) explicitly via the field boundary check.
header_semicolon_delim_no_space(_Config) ->
    C = compile_ok(<<"nplurals=2;plural=n != 1;">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 8)).

%% =========================
%% Parser syntax errors
%% =========================

%% Ternary `?` without matching `:` must produce a syntax_error
%% mentioning the expected colon.
ternary_missing_colon(_Config) ->
    ?assertMatch(
        {error, {syntax_error, {expected, $:, _}, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=n ? 1;">>)
    ).

%% `n` is a single-char identifier; any further identifier char (here,
%% `x`) makes the lexeme illegal.
unknown_identifier_after_n(_Config) ->
    ?assertMatch(
        {error, {syntax_error, {unknown_identifier_after_n, $x}, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=nx;">>)
    ),
    %% Underscore also qualifies as an identifier char.
    ?assertMatch(
        {error, {syntax_error, {unknown_identifier_after_n, _}, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=n_;">>)
    ).

%% A character that is neither digit, `n`, `(`, nor a recognised
%% operator triggers the unexpected_char branch of parse_primary.
unexpected_char_at_primary(_Config) ->
    ?assertMatch(
        {error, {syntax_error, {unexpected_char, $@}, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=@;">>)
    ).

%% An incomplete expression where the parser runs out of input while
%% looking for a primary produces unexpected_eof.
unexpected_eof_at_primary(_Config) ->
    %% `n +` parses `n`, expects multiplicative after `+`, hits EOF.
    ?assertMatch(
        {error, {syntax_error, unexpected_eof, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=n +">>)
    ),
    %% Lone `!` is unary without an operand.
    ?assertMatch(
        {error, {syntax_error, unexpected_eof, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=!">>)
    ).

%% `!=` in the unary slot (no left operand) — parse_unary peeks `!`,
%% sees `!=` ahead, and falls through to parse_primary which then
%% surfaces the syntax error on `=`.
not_followed_by_neq(_Config) ->
    ?assertMatch(
        {error, {syntax_error, _, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=!=n;">>)
    ).

%% Expression with exactly one byte remaining at a point where
%% the parser calls peek2 — exercises the `<<_>>` clause of peek2.
%% Wrapping `n != 1` in parens leaves a single `)` byte at the point
%% inner parser tails call peek2, while the outer paren consumer sees
%% it as the closer.
peek2_with_single_byte_remaining(_Config) ->
    C = compile_ok(<<"nplurals=2; plural=(n != 1);">>),
    ?assertEqual(0, erli18n_plural:evaluate(C, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(C, 5)).

%% A bare `<` at end-of-input forces parse_relational_tail's fallback
%% peek_byte branch (since peek2 returns eof) before parse_additive
%% throws unexpected_eof.
relational_lt_single_byte(_Config) ->
    ?assertMatch(
        {error, {syntax_error, _, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=n<">>)
    ).

%% Same for `>` — exercises the parse_relational_tail `>` fallback.
relational_gt_single_byte(_Config) ->
    ?assertMatch(
        {error, {syntax_error, _, _}},
        erli18n_plural:compile(<<"nplurals=2; plural=n>">>)
    ).

%% =========================
%% CLDR + validation paths
%% =========================

%% A locale with no CLDR entry yields `ok` from validate_against_cldr
%% (we cannot validate, so we do not warn).
validate_against_unknown_locale_is_ok(_Config) ->
    ?assertEqual(
        ok,
        erli18n_plural:validate_against_cldr(
            <<"qq_QQ">>, eng()
        )
    ),
    %% Also when the header itself is malformed — the early-return on
    %% unknown locale wins.
    ?assertEqual(
        ok,
        erli18n_plural:validate_against_cldr(
            <<"unknown_zz">>, <<"garbage header">>
        )
    ).

%% A known locale paired with an unparseable header makes split_rule
%% return error and ast_equivalent fall through to its `false` arm;
%% the caller sees `{warning, ...}` rather than crashing.
validate_against_cldr_with_bad_header(_Config) ->
    Result = erli18n_plural:validate_against_cldr(
        <<"en">>, <<"bogus garbage no equals">>
    ),
    ?assertMatch({warning, {plural_divergence, <<"en">>, _, _}}, Result).

%% A locale whose base language is also absent from the CLDR table
%% returns `undefined`, exercising the second `lookup_locale` arm
%% inside cldr_rule/1.
cldr_rule_hyphen_region_unknown(_Config) ->
    ?assertEqual(undefined, erli18n_plural:cldr_rule(<<"qq-QQ">>)),
    ?assertEqual(undefined, erli18n_plural:cldr_rule(<<"zz_ZZ">>)).
