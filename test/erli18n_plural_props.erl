%%% =====================================================================
%%% Property-based tests for `erli18n_plural` — C-expression evaluator
%%% soundness (`parity_specs.md` §6.1 property P3).
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
    prop_compile_or_error/0
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

%% =========================
%% Generators
%% =========================

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
