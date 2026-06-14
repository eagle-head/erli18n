%%% =====================================================================
%%% Property-based tests for `erli18n_plural` — C-expression evaluator
%%% soundness (property P3).
%%%
%%% Claim (P3): for every well-formed GNU plural expression `Expr` and
%%% every integer `N`, the chosen form index is within `[0, Nplurals-1]`.
%%%
%%% Strategy: a random C-expression generator can produce values outside
%%% `[0, Nplurals)`. The GNU plural specification (see GNU gettext §11.2.6
%%% "Additional functions for plural forms") leaves it to the catalog
%%% author to keep the rule in range; out-of-range outputs are a bug in
%%% the `.po` file, not in the evaluator. To isolate the evaluator's
%%% behaviour we wrap the generated expression in
%%%   `((EXPR) % Nplurals + Nplurals) % Nplurals`
%%% which is mathematically guaranteed to fall in `[0, Nplurals)`
%%% regardless of `EXPR` (Erlang `rem` matches C99 `%` — see GNU gettext
%%% manual §11.2.6 and PSD-008 / `erli18n_plural.erl` comments). The
%%% double-modulo handles the case where `EXPR` is negative, which Erlang
%%% `rem` would otherwise propagate.
%%%
%%% References:
%%%   * Hughes, "QuickCheck", ICFP 2000.
%%%   * Papadakis et al., PADL 2011 —
%%%     https://proper-testing.github.io/papers/proper_acm.pdf
%%%   * PropEr docs — https://hexdocs.pm/proper/
%%%   * GNU gettext §11.2.6 "Additional functions for plural forms" —
%%%     https://www.gnu.org/software/gettext/manual/html_node/Plural-forms.html
%%% =====================================================================
-module(erli18n_plural_props).

-include_lib("proper/include/proper.hrl").

-export([
    prop_index_in_range/0,
    prop_compile_or_error/0,
    prop_compile_bounded/0,
    prop_compile_node_bounded/0
]).

%% Generators
-export([c_plural_expr/0, c_plural_expr/1, c_op/0]).

%% =========================
%% Properties
%% =========================

%% P3 — index in range.
%%
%% We bound the expression depth at 4 to keep generator pathologies in
%% check (PropEr's default size growth would otherwise produce trees too
%% large to evaluate in reasonable time for some of the deeper
%% combinations).
%%
%% N is drawn from a representative population: small integers (the
%% real-world common case), bignums (validates the evaluator does not
%% silently overflow), and negatives (legacy GNU plural rules are
%% defined over non-negative N, but the runtime may receive a `-1` from
%% a buggy consumer — the evaluator must degrade gracefully and not
%% crash).
prop_index_in_range() ->
    ?FORALL(
        {NPluralsGen, ExprAstGen, NGen},
        {pos_integer_small(), c_plural_expr(), n_population()},
        begin
            %% PropEr generators are statically typed as `term()` by
            %% eqwalizer (their runtime payload is opaque). Cast at the
            %% property boundary to the documented generator contracts
            %% — `pos_integer_small/0` yields `pos_integer()`,
            %% `n_population/0` yields `integer()`, and `c_plural_expr/0`
            %% yields the recursive AST consumed by `ast_to_text/1`.
            NPlurals = eqwalizer:dynamic_cast(NPluralsGen),
            ExprAst = eqwalizer:dynamic_cast(ExprAstGen),
            N = eqwalizer:dynamic_cast(NGen),
            ExprText = ast_to_text(ExprAst),
            Wrapped = wrap_in_range(ExprText, NPlurals),
            Header =
                <<"nplurals=", (integer_to_binary(NPlurals))/binary, "; plural=", Wrapped/binary,
                    ";">>,
            try erli18n_plural:plural_by_po_header(Header, N) of
                {ok, Idx} when
                    is_integer(Idx),
                    Idx >= 0,
                    Idx < NPlurals
                ->
                    true;
                {ok, Other} ->
                    ct:pal(
                        "P3 out-of-range: NPlurals=~p Expr=~s N=~p Idx=~p~n",
                        [NPlurals, ExprText, N, Other]
                    ),
                    false;
                {error, {unsafe_plural_rule, _}} ->
                    %% Layer 3 static rejection (finding #1): the
                    %% generator can emit a rule that is *statically*
                    %% guaranteed to fault (e.g. a literal `x / 0`
                    %% subtree). `compile/1` rejecting it fail-closed is
                    %% the desired behaviour — the poisoned catalog never
                    %% loads — so this is a PASS, not a parser bug.
                    true;
                {error, Reason} ->
                    %% Any OTHER compile-error on a syntactically valid
                    %% generated expression indicates a parser bug.
                    ct:pal(
                        "P3 compile-error: NPlurals=~p Expr=~s N=~p err=~p~n",
                        [NPlurals, ExprText, N, Reason]
                    ),
                    false
            catch
                Class:Reason:Stack ->
                    %% Finding #1 (plural-eval-throws-per-lookup-dos):
                    %% `evaluate/2` is the hot path of every ngettext
                    %% lookup and MUST be total. A malformed rule — even
                    %% one containing division/modulo by zero, now that
                    %% `/` and `%` are in the operator pool — must clamp
                    %% (to form 0 / a defined value), never crash the
                    %% caller. So ANY exception here is a property
                    %% violation, including the `badarith` that the old
                    %% test treated as a PASS.
                    ct:pal(
                        "P3 evaluate/2 must be total but crashed: ~p:~p~n~p~n"
                        "Expr=~s N=~p~n",
                        [Class, Reason, Stack, ExprText, N]
                    ),
                    false
            end
        end
    ).

%% Companion property: `compile/1` on a randomly generated expression
%% either succeeds or returns a structured `{error, _}` — never crashes.
prop_compile_or_error() ->
    ?FORALL(
        {NPluralsGen, ExprAstGen},
        {pos_integer_small(), c_plural_expr()},
        begin
            %% Same generator-boundary cast as in `prop_index_in_range/0`.
            NPlurals = eqwalizer:dynamic_cast(NPluralsGen),
            ExprAst = eqwalizer:dynamic_cast(ExprAstGen),
            ExprText = ast_to_text(ExprAst),
            Header =
                <<"nplurals=", (integer_to_binary(NPlurals))/binary, "; plural=", ExprText/binary,
                    ";">>,
            case erli18n_plural:compile(Header) of
                {ok, #{nplurals := NP, expr := _, raw := _}} when
                    NP =:= NPlurals
                ->
                    true;
                {error, _Compile} ->
                    true;
                _Other ->
                    false
            end
        end
    ).

%% Finding #2 (plural-compile-superlinear-unbounded). `compile/1` runs
%% inside the single catalog gen_server's `handle_call` on UNTRUSTED `.po`
%% input, so a pathological-but-valid `Plural-Forms` expression must
%% never make it superlinear or unbounded. Two regressions are guarded:
%%
%%   * the O(n^2) `skip_ws_st/1` full-binary `=:=` (a flat `n+n+...+n`
%%     chain with no leading whitespace is the exact trigger);
%%   * unbounded recursion depth on `(((...n...)))` / `!!!...n`.
%%
%% This property feeds adversarial headers (UP TO ~1 MB, far past the
%% size/depth the byte-cap permits) DIRECTLY to `compile/1` and asserts
%% that it always returns within a strict per-call time budget with
%% EITHER `{ok, _}` (small enough to compile) OR a structured
%% `{error, {expr_too_long | expr_too_deep, ...}}` rejection — never a
%% crash, never an open-ended run. The old generator capped AST depth at
%% 4 (`c_plural_expr/1`), so it could never reach the sizes that exposed
%% the quadratic/unbounded behaviour; this property closes that gap by
%% generating the pathological shapes directly rather than via the AST
%% grammar.
prop_compile_bounded() ->
    ?FORALL(
        HeaderGen,
        patho_header(),
        begin
            Header = eqwalizer:dynamic_cast(HeaderGen),
            {Micros, Result} = timer:tc(fun() ->
                erli18n_plural:compile(Header)
            end),
            BudgetOk = Micros < 50_000,
            ShapeOk =
                case Result of
                    {ok, #{nplurals := _, expr := _, raw := _}} ->
                        true;
                    {error, {expr_too_long, Size, Max}} when
                        is_integer(Size), is_integer(Max), Size > Max
                    ->
                        true;
                    {error, {expr_too_deep, Depth, Pos}} when
                        is_integer(Depth), is_integer(Pos)
                    ->
                        true;
                    %% Finding #9: a wide flat chain (e.g. `n+n+...+n`)
                    %% can stay under BOTH the byte cap and the depth cap
                    %% yet exceed the AST node-count cap; the node guard
                    %% rejecting it fail-closed is a fine outcome too.
                    {error, {expr_too_complex, Nodes, NMax}} when
                        is_integer(Nodes), is_integer(NMax), Nodes > NMax
                    ->
                        true;
                    %% A pathological body can also be a plain syntax
                    %% error (e.g. unbalanced parens once truncated by the
                    %% byte cap); that is a fine fail-closed outcome too.
                    {error, {syntax_error, _, _}} ->
                        true;
                    Other ->
                        ct:pal(
                            "prop_compile_bounded unexpected result: ~p~n"
                            "header size=~p~n",
                            [Other, byte_size(Header)]
                        ),
                        false
                end,
            case BudgetOk of
                true ->
                    ok;
                false ->
                    ct:pal(
                        "prop_compile_bounded budget blown: ~p us "
                        "(budget 50000) for header size=~p~n",
                        [Micros, byte_size(Header)]
                    )
            end,
            BudgetOk andalso ShapeOk
        end
    ).

%% Finding #9 (plural-bignum-cpu-dos-evaluate-hotpath). The byte/depth
%% caps from finding #2 do NOT bound the AST NODE COUNT: a wide flat
%% operator chain (`n*n*...*n`) stays under the byte cap and at a single
%% recursion level, yet compiles to thousands of AST nodes. `evaluate/2`
%% then walks that whole tree — and grows an `n^k` bignum — on every
%% ngettext lookup, with no result cache (the per-LOOKUP amplification
%% axis, distinct from the COMPILE-time blow-up of finding #2).
%%
%% This property generates wide multiply chains whose node count spans
%% both sides of ?AST_MAX_NODES (256) and asserts the post-compile
%% invariant: `compile/1` EITHER returns `{ok, _}` with a bounded AST
%% (node_count =< 256) OR rejects fail-closed with a structured
%% `{error, {expr_too_complex, Nodes, Max}}` (or, for the largest bodies,
%% `{expr_too_long, _, _}` once the byte cap is also crossed). It must
%% never return `{ok, _}` carrying an unbounded AST, and must return
%% within a strict per-call time budget. This property CHANCELS THE
%% CURRENT BUG: today compile accepts a 1000-factor chain and returns
%% `{ok, _}` with ~1999 nodes.
prop_compile_node_bounded() ->
    ?FORALL(
        FactorsGen,
        oneof([10, 100, 200, 256, 300, 1000, 4000]),
        begin
            Factors = eqwalizer:dynamic_cast(FactorsGen),
            Body = multiply_chain(Factors),
            Header =
                <<"nplurals=2; plural=", Body/binary, ";">>,
            {Micros, Result} = timer:tc(fun() ->
                erli18n_plural:compile(Header)
            end),
            BudgetOk = Micros < 50_000,
            ShapeOk =
                case Result of
                    {ok, #{expr := Ast}} ->
                        %% Accepted only when the AST is provably bounded.
                        ast_node_count(Ast) =< 256;
                    {error, {expr_too_complex, Nodes, Max}} when
                        is_integer(Nodes), is_integer(Max), Nodes > Max
                    ->
                        true;
                    {error, {expr_too_long, Size, Max}} when
                        is_integer(Size), is_integer(Max), Size > Max
                    ->
                        true;
                    Other ->
                        ct:pal(
                            "prop_compile_node_bounded unexpected: ~p "
                            "(factors=~p, body bytes=~p)~n",
                            [Other, Factors, byte_size(Body)]
                        ),
                        false
                end,
            BudgetOk andalso ShapeOk
        end
    ).

%% =========================
%% Generators
%% =========================

%% Pathological-but-syntactically-plausible `Plural-Forms` headers. Each
%% wraps an adversarial expression body whose SIZE/DEPTH is drawn well
%% past the parser's caps so the property exercises both the length guard
%% and the depth guard, plus the O(n) whitespace scan on the largest
%% accepted inputs. Sizes range from "comfortably under the cap" to ~1 MB.
patho_header() ->
    ?LET(
        {NPluralsGen, BodyGen},
        {oneof([1, 2, 3, 6]), patho_body()},
        %% PropEr generator payloads are statically `term()` (opaque to
        %% eqwalizer); cast at the boundary to the documented contracts —
        %% `NPlurals` is a `pos_integer()`, `Body` a `binary()` produced
        %% by `build_patho/2`.
        build_patho_header(
            eqwalizer:dynamic_cast(NPluralsGen),
            eqwalizer:dynamic_cast(BodyGen)
        )
    ).

-spec build_patho_header(pos_integer(), binary()) -> binary().
build_patho_header(NPlurals, Body) ->
    <<"nplurals=", (integer_to_binary(NPlurals))/binary, "; plural=", Body/binary, ";">>.

%% A single adversarial expression body. `Count` spans both sides of the
%% byte/depth caps so compile/1 must take each guarded branch.
patho_body() ->
    ?LET(
        {ShapeGen, CountGen},
        {oneof([flat_add, nested_paren, bang_chain]), oneof([10, 100, 1000, 10_000, 100_000])},
        build_patho(
            eqwalizer:dynamic_cast(ShapeGen),
            eqwalizer:dynamic_cast(CountGen)
        )
    ).

%% `n+n+...+n` — the exact flat shape that triggered the O(n^2)
%% `skip_ws_st/1` equality match (no leading whitespace per token).
-spec build_patho(flat_add | nested_paren | bang_chain, non_neg_integer()) ->
    binary().
build_patho(flat_add, Count) ->
    Tail = binary:copy(<<"+n">>, max(Count - 1, 0)),
    <<"n", Tail/binary>>;
%% `(((...n...)))` — unbounded recursion depth.
build_patho(nested_paren, Count) ->
    Opens = binary:copy(<<"(">>, Count),
    Closes = binary:copy(<<")">>, Count),
    <<Opens/binary, "n", Closes/binary>>;
%% `!!!...n` — unbounded unary recursion depth.
build_patho(bang_chain, Count) ->
    Bangs = binary:copy(<<"!">>, Count),
    <<Bangs/binary, "n">>.

%% `n*n*...*n` with `Factors` factors. Left-associative, so it stays at a
%% single multiplicative recursion level (under the depth cap) but its AST
%% has 2*Factors-1 nodes — the exact shape that inflates per-lookup
%% `evaluate/2` cost in finding #9.
-spec multiply_chain(pos_integer()) -> binary().
multiply_chain(Factors) when Factors >= 1 ->
    Tail = binary:copy(<<"*n">>, max(Factors - 1, 0)),
    <<"n", Tail/binary>>.

%% Count the nodes of a compiled plural AST (the internal representation
%% returned by `erli18n_plural:compile/1`). Mirrors the bound enforced by
%% `compile/1`; used to assert the post-compile invariant.
-spec ast_node_count(term()) -> pos_integer().
ast_node_count(N) when is_integer(N) -> 1;
ast_node_count(n) -> 1;
ast_node_count({unop, '!', E}) -> 1 + ast_node_count(E);
ast_node_count({binop, _Op, L, R}) -> 1 + ast_node_count(L) + ast_node_count(R);
ast_node_count({ternary, C, T, E}) -> 1 + ast_node_count(C) + ast_node_count(T) + ast_node_count(E).

%% A small positive integer for nplurals. Real-world locales top out at
%% 6 (Arabic); we mirror that range so the property exercises every
%% real-world arity.
pos_integer_small() ->
    oneof([1, 2, 3, 4, 5, 6]).

%% N population: typical user-facing counts plus stress cases. Bignums
%% (10^15) and negatives both included so the evaluator's bignum path
%% and its handling of `-1`-style buggy inputs are covered.
n_population() ->
    oneof([
        0,
        1,
        2,
        3,
        5,
        11,
        100,
        1000,
        1_000_000_000_000_000,
        -1,
        -100,
        ?LET(I, integer(), I)
    ]).

%% Recursive grammar generator for valid C-style plural expressions.
%% Depth-bounded at 4 to keep generation tractable. We use
%% `?SIZED` so PropEr can shrink toward smaller, more diagnosable
%% counter-examples.
c_plural_expr() ->
    ?SIZED(Size, c_plural_expr(min(Size, 4))).

c_plural_expr(0) ->
    oneof([
        {var, n},
        {lit, choose(0, 100)}
    ]);
c_plural_expr(Size) ->
    Smaller = c_plural_expr(Size - 1),
    weighted_union([
        {2, {var, n}},
        {2, {lit, choose(0, 100)}},
        {6,
            ?LET(
                {Op, L, R},
                {c_op(), Smaller, Smaller},
                {binop, Op, L, R}
            )},
        {2, ?LET(E, Smaller, {unop, '!', E})},
        {2,
            ?LET(
                {C, T, E},
                {Smaller, Smaller, Smaller},
                {ternary, C, T, E}
            )},
        {2, ?LET(E, Smaller, {paren, E})}
    ]).

%% Binary operators. We INCLUDE `/` and `%` in the random pool: per
%% finding #1 (plural-eval-throws-per-lookup-dos) the evaluator must be
%% total, so a generated subtree like `n / (n - n)` (division by zero)
%% must clamp to a defined value rather than raise `badarith`. The
%% property below asserts no exception escapes `evaluate/2`, so these
%% two operators directly exercise the zero-divisor guard
%% (`eval_div/2` / `eval_rem/2`).
c_op() ->
    oneof(['+', '-', '*', '/', '%', '==', '!=', '<', '>', '<=', '>=', '&&', '||']).

%% =========================
%% AST -> text
%% =========================
%%
%% Round-trip the generated AST back to a C source string and feed that
%% to the evaluator. This is the "external" interface — we deliberately
%% avoid calling `erli18n_plural`'s internal AST evaluator directly, so
%% the property covers parse + evaluate end-to-end.

ast_to_text({var, n}) ->
    <<"n">>;
ast_to_text({lit, N}) when is_integer(N) ->
    integer_to_binary(N);
ast_to_text({unop, '!', E}) ->
    <<"!(", (ast_to_text(E))/binary, ")">>;
ast_to_text({binop, Op, L, R}) ->
    OpBin = atom_to_binary(Op, utf8),
    <<"(", (ast_to_text(L))/binary, " ", OpBin/binary, " ", (ast_to_text(R))/binary, ")">>;
ast_to_text({ternary, C, T, E}) ->
    <<"(", (ast_to_text(C))/binary, " ? ", (ast_to_text(T))/binary, " : ", (ast_to_text(E))/binary,
        ")">>;
ast_to_text({paren, E}) ->
    <<"(", (ast_to_text(E))/binary, ")">>.

%% Force the expression result into `[0, NPlurals)`. The outer
%% `+ NPlurals) % NPlurals` is a Euclidean-modulus trick: for any
%% integer `x`, `((x % m) + m) % m` is a non-negative residue. Without
%% it, Erlang `rem` (== C99 `%`) preserves the sign of the dividend
%% and would let counter-examples leak through with negative indices.
wrap_in_range(Expr, NPlurals) ->
    NBin = integer_to_binary(NPlurals),
    <<"((", Expr/binary, ") % ", NBin/binary, " + ", NBin/binary, ") % ", NBin/binary>>.
