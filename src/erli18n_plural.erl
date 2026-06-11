-module(erli18n_plural).

-moduledoc """
Avaliador e validador das regras de plural do gettext/CLDR usadas pelo
erli18n.

Compila a expressão C do cabeçalho `Plural-Forms:` de um `.po`
(`nplurals=N; plural=EXPR;`) num pequeno AST e a avalia para escolher a
forma plural de um dado N — é o que sustenta `ngettext`/`npgettext`. O
cabeçalho do `.po` é a fonte-de-verdade em runtime (PSD-004); a tabela
CLDR embutida (~45 locales, `cldr_rule/1`) é consultada apenas no load
para emitir avisos de divergência e como fallback quando o cabeçalho
falta.

Endurecido para entrada não-confiável (ADR-0003): `compile/1` roda
fail-closed com limites de tamanho/profundidade/nós e rejeita regras
estaticamente faltosas, enquanto `evaluate/2` é TOTAL (nunca levanta) —
faz clamp à forma 0 e coage divisão/módulo por zero a 0, espelhando o
runtime do GNU libintl.
""".

%% Evaluator for the GNU gettext `Plural-Forms:` header C-expression
%% (per https://www.gnu.org/software/gettext/manual/gettext.html#Translating-plural-forms)
%% and CLDR-canonical-rule validator
%% (per https://cldr.unicode.org/index/cldr-spec/plural-rules,
%% source data: cldr-json/cldr-core/supplemental/plurals.json in
%% https://github.com/unicode-org/cldr-json).
%%
%% Design source-of-truth:
%%
%%   * PSD-004 (po_semantics_decisions.md) — the `.po` `Plural-Forms` header
%%     is the runtime source-of-truth; CLDR is consulted only at load-time
%%     for divergence warnings, and as fallback when the header is absent.
%%     Therefore `evaluate/2` is the **hot path** and must never touch CLDR.
%%
%%   * PSD-008 (po_semantics_decisions.md) — degenerate plural rules
%%     (`nplurals=1; plural=0;`, used by ja/zh/ko/vi/th) must round-trip
%%     through compile/evaluate as a literal integer expression. The
%%     grammar therefore accepts integer literals as valid primary terms.
%%
%%   * BR-DESCARTAR-003 (discard_log.md) — the GNU Plural-Forms evaluation
%%     capability is preserved from the legacy `gettexter_plural` module.
%%     The Yecc/Leex/erl_syntax/erl_eval pipeline (~231 LOC) is dropped,
%%     but the C-truthy operator semantics and recursive walker shape are
%%     refactored here into a single recursive-descent parser + interpreter.
%%
%%   * paradigm_decision.md §E3 — hybrid wrapper: local recursive-descent
%%     evaluator in the hot path; CLDR table only out of the hot path.
%%
%% Implementation notes:
%%
%%   * No Yecc, no Leex, no dynamic Erlang code generation — the evaluator
%%     interprets a small AST so dialyzer can reason about everything.
%%   * Operators follow C precedence/associativity. Short-circuit semantics
%%     are honoured for `&&` and `||` so that expressions guarded against
%%     division by zero (e.g. `n != 0 && (10/n) > 1`) behave as in C.
%%   * Modulo (`%`) uses Erlang `rem`, which matches C99 truncation toward
%%     zero — the only behaviour `.po` plural rules ever rely on.
%%   * Division by zero in untrusted `.po` input is handled, not
%%     propagated (finding #1, plural-eval-throws-per-lookup-dos):
%%     `evaluate/2` is TOTAL on the per-request hot path. A zero divisor
%%     is pinned to 0 (`eval_div/2` / `eval_rem/2`) and an out-of-range
%%     form is clamped to 0, matching GNU libintl's `dcigettext.c`
%%     instead of raising `badarith`. Statically-faulty rules are
%%     rejected up front by `compile/1`; `evaluate_checked/2` surfaces
%%     the anomaly as data for callers that want to observe it.
%%   * CLDR data is hard-coded inline (~45 locales, see `cldr_rule/1`).
%%     For v0.1 the alternatives were rejected:
%%
%%       - Option B: external hex dep (e.g. ex_cldr). Heavyweight, pulls
%%         Elixir interop, not justified for a single-table lookup.
%%       - Option C: priv/cldr_plurals.eterm generated from upstream JSON.
%%         Useful for future maintenance and explicitly documented in this
%%         file's `cldr_data/0` docstring as the v0.2+ direction.

%% Public API.
-export([
    compile/1,
    evaluate/2,
    evaluate_checked/2,
    plural_by_po_header/2,
    cldr_rule/1,
    validate_against_cldr/2,
    validate_against_cldr_ast/2,
    fallback_rule/0
]).

-export_type([
    plural_compiled/0,
    compile_error/0,
    plural_eval_error/0,
    ast/0,
    op/0
]).

%% =========================
%% Types
%% =========================

-type plural_compiled() :: #{
    nplurals := pos_integer(),
    expr := ast(),
    raw := binary()
}.

-type compile_error() ::
    {syntax_error, Reason :: term(), Position :: non_neg_integer()}
    | {missing_nplurals, binary()}
    | {missing_plural_expr, binary()}
    | {nplurals_out_of_range, integer()}
    %% Layer 3 (finding #1): a rule that is STATICALLY guaranteed to
    %% fault — a literal division/modulo by zero, or a constant form
    %% index provably outside [0, NPlurals) — is rejected at load time
    %% so the poisoned catalog is refused by `ensure_loaded` rather than
    %% loading as `{ok, _}` and crashing every later lookup.
    | {unsafe_plural_rule, plural_eval_error()}
    %% Finding #2 (plural-compile-superlinear-unbounded): the parser
    %% runs on untrusted `.po` input inside the catalog gen_server's
    %% `handle_call`. An expression longer than `?PLURAL_EXPR_MAX_BYTES`
    %% or nested deeper than `?PLURAL_EXPR_MAX_DEPTH` is rejected
    %% fail-closed so a pathological-but-valid rule cannot make compile
    %% superlinear/unbounded and freeze the server.
    | {expr_too_long, Size :: non_neg_integer(), Max :: pos_integer()}
    | {expr_too_deep, Depth :: pos_integer(), Position :: non_neg_integer()}
    %% Finding #9 (plural-bignum-cpu-dos-evaluate-hotpath): the byte and
    %% depth caps above do not bound the AST NODE COUNT, so a wide flat
    %% operator chain (`n*n*...*n`) can still compile to thousands of
    %% nodes that `evaluate/2` walks — growing an `n^k` bignum — on every
    %% lookup. An AST above `?AST_MAX_NODES` is rejected fail-closed so
    %% the per-lookup cost stays O(1)-bounded by construction.
    | {expr_too_complex, Nodes :: pos_integer(), Max :: pos_integer()}
    %% Finding #8 (po-plural-unbounded-binary-to-integer-bignum): the
    %% `nplurals=<digits>` run is capped by DIGIT COUNT before any
    %% `binary_to_integer` materialises the bignum. The rejected value is
    %% deliberately kept OUT of the payload (only the digit count and the
    %% cap are reported) so a thousands-digit adversarial run cannot
    %% amplify memory/logs, and the >=~1.3M-digit `system_limit` path is
    %% never reached.
    | {nplurals_too_many_digits, Digits :: pos_integer(), Max :: pos_integer()}.

%% Anomaly observed while evaluating a compiled plural rule. Surfaced as
%% data by `evaluate_checked/2` and as the payload of a Layer 3
%% `{unsafe_plural_rule, _}` compile rejection. The total `evaluate/2`
%% never raises these — it clamps instead (libintl parity).
-type plural_eval_error() ::
    {division_by_zero, '/' | '%'}
    | {form_out_of_range, Form :: integer(), NPlurals :: pos_integer()}.

%% literal
-type ast() ::
    integer()
    %% variable n
    | n
    | {binop, op(), ast(), ast()}
    | {unop, '!', ast()}
    | {ternary, ast(), ast(), ast()}.

-type op() ::
    '+'
    | '-'
    | '*'
    | '/'
    | '%'
    | '=='
    | '!='
    | '<'
    | '>'
    | '<='
    | '>='
    | '&&'
    | '||'.

%% Internal parser state — carries the remaining input and absolute byte
%% offset (for surfacing diagnostic positions in syntax errors).
-record(ps, {
    src :: binary(),
    pos = 0 :: non_neg_integer()
}).

%% Sanity bound for nplurals. Real-world locales top out at 6 (Arabic).
%% Any header declaring more than a thousand forms is malformed input.
-define(NPLURALS_MAX, 1000).

%% Maximum number of decimal digits accepted for the `nplurals=<digits>`
%% field (finding #8, po-plural-unbounded-binary-to-integer-bignum). The
%% range check is `[1, ?NPLURALS_MAX=1000]`, so 4 digits already covers
%% every legal value; 7 leaves generous headroom for realistic indices
%% while keeping the bignum tiny. Capping by digit COUNT *before*
%% `binary_to_integer` means a thousands-digit adversarial run is
%% rejected in O(1) without ever materialising an O(d^2) bignum or
%% reaching the >=~1.3M-digit `error:system_limit` path.
-define(MAX_INT_DIGITS, 7).

%% Bounds for the `Plural-Forms` expression itself (finding #2,
%% plural-compile-superlinear-unbounded). `?NPLURALS_MAX` bounds the
%% form COUNT, not the expression SIZE, so without these the parser is
%% unbounded in both byte-length and recursion depth on untrusted input.
%%
%%   * `?PLURAL_EXPR_MAX_BYTES` — the real-world most-complex rule
%%     (Arabic) is ~98 bytes; 2048 is ~20x headroom, so no legitimate
%%     catalog is affected, while a multi-KB adversarial expression is
%%     rejected before it can be parsed.
%%   * `?PLURAL_EXPR_MAX_DEPTH` — Arabic's nesting depth is well under
%%     10; 64 is ~6x headroom and also bounds the recursion depth of the
%%     hot-path `eval_ast/2` walker (stack growth per lookup).
-define(PLURAL_EXPR_MAX_BYTES, 2048).
-define(PLURAL_EXPR_MAX_DEPTH, 64).

%% Bound on the number of nodes in the compiled plural AST (finding #9,
%% plural-bignum-cpu-dos-evaluate-hotpath). Complements the byte/depth
%% caps above, which do NOT bound the node count: a wide, flat operator
%% chain (`n*n*...*n`) stays under both — it is left-associative, so it
%% does not nest the parser, and ~1000 factors fit inside 2048 bytes —
%% yet it compiles to ~2000 AST nodes. `evaluate/2` walks that whole tree
%% (and grows an `n^k` bignum) on EVERY ngettext lookup, with no result
%% cache, so the per-lookup cost is super-linear in the chain length and
%% grows with N. Bounding the node count at compile time keeps the
%% installed AST small, so `evaluate/2`'s cost is O(1)-bounded by
%% construction. The real-world most-complex rule (Russian/Arabic) has
%% ~39 nodes; 256 is ~6.5x headroom, so no legitimate catalog is
%% affected, while a pathological chain is rejected before it can poison
%% every later evaluation.
-define(AST_MAX_NODES, 256).

%% Identifier-character predicate, used to reject malformed bare words
%% like `nx`. Macro so the parser inlines the test in a guard.
-define(IS_IDENT(C),
    ((C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $_)
).

%% =========================
%% Public API
%% =========================

-doc """
Compila a expressão do cabeçalho `Plural-Forms:` de um `.po` num bundle
`plural_compiled()` (mapa `nplurals`/`expr`/`raw`) reutilizado por cada
`evaluate/2`.

`Header` é a string do cabeçalho (`nplurals=N; plural=EXPR;`); os campos
são localizados de forma tolerante a espaços. Retorna `{ok, Compiled}` ou
`{error, compile_error()}`, sempre fail-closed (nunca levanta), pois roda
sobre `.po` não-confiável dentro do `handle_call` do gen_server.

Rejeições estruturais relevantes:
- `{expr_too_long, Size, Max}` — expressão acima de `?PLURAL_EXPR_MAX_BYTES`
  (2048), recusada antes do parsing;
- `{expr_too_deep, Depth, Pos}` — aninhamento acima de
  `?PLURAL_EXPR_MAX_DEPTH` (64);
- `{expr_too_complex, Nodes, Max}` — AST com mais nós que `?AST_MAX_NODES`
  (256), barrando cadeias planas largas (`n*n*...*n`) que cresceriam um
  bignum por lookup;
- `{unsafe_plural_rule, Reason}` — regra ESTATICAMENTE faltosa: divisão/
  módulo por divisor constante 0, ou regra constante cuja forma cai fora
  de `[0, NPlurals)`. Casos que só falham para um N específico ficam para
  o clamp dinâmico de `evaluate/2`;
- `{nplurals_too_many_digits, _, _}`, `{nplurals_out_of_range, _}`,
  `{missing_nplurals, _}`, `{missing_plural_expr, _}` e `{syntax_error,
  Reason, Pos}` para os demais defeitos do cabeçalho.
""".
-spec compile(binary()) -> {ok, plural_compiled()} | {error, compile_error()}.
compile(Header) when is_binary(Header) ->
    case extract_nplurals(Header) of
        {ok, NPlurals} ->
            case extract_plural_expr(Header) of
                {ok, ExprBin} ->
                    case parse_expr_bin(ExprBin) of
                        {ok, Ast} ->
                            compile_validated(Header, NPlurals, Ast);
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% Apply the two load-time validation barriers to a successfully parsed
%% AST and, on success, materialise the `plural_compiled()` bundle.
%%
%%   * Layer 3 (finding #1): reject rules that are STATICALLY guaranteed
%%     to fault (literal div/mod by zero, constant out-of-range form)
%%     before they can be stored and crash every later lookup.
%%   * Node-count cap (finding #9): reject an AST above `?AST_MAX_NODES`
%%     so a wide flat chain cannot make `evaluate/2` walk thousands of
%%     nodes (and grow a large bignum) on every lookup. Run once here at
%%     load time, never on the hot path.
-spec compile_validated(binary(), pos_integer(), ast()) ->
    {ok, plural_compiled()} | {error, compile_error()}.
compile_validated(Header, NPlurals, Ast) ->
    case validate_safe(Ast, NPlurals) of
        ok ->
            case check_ast_complexity(Ast) of
                ok ->
                    {ok, #{
                        nplurals => NPlurals,
                        expr => Ast,
                        raw => Header
                    }};
                {error, _} = Err ->
                    Err
            end;
        {error, EvalErr} ->
            {error, {unsafe_plural_rule, EvalErr}}
    end.

%% Evaluate a compiled plural rule for a particular N. Pure function on
%% the hot path — no allocations beyond the return value. Negative N is
%% accepted; the C runtime in libintl applies abs() on the integer, but
%% gettext .po rules are all defined over non-negative N. We pass N
%% through unchanged so the rule's own semantics decide.
%%
%% TOTALITY (finding #1, plural-eval-throws-per-lookup-dos). `.po` input
%% is untrusted (ADR-0003) and this function runs in the CALLER process
%% on every `ngettext`/`npgettext` lookup, so it MUST NOT raise. Two
%% failure modes that a malformed rule could otherwise trigger are
%% neutralised here, matching the GNU libintl runtime:
%%
%%   * division / modulo by zero — `eval_div/2` and `eval_rem/2` coerce
%%     a zero divisor to a defined value (C undefined behaviour pinned to
%%     0) instead of letting Erlang `div`/`rem` raise `badarith`.
%%   * out-of-range form index — clamped to form 0, exactly as
%%     `dcigettext.c` (`plural_lookup`) does: `if (index >= nplurals)
%%     index = 0;` ("this should never happen" -> clamp, NOT crash).
%%
%% The `-spec` is therefore HONEST: the result is provably
%% `non_neg_integer()` for every N and every AST. Callers that want to
%% OBSERVE the anomaly as data use `evaluate_checked/2` instead.
-doc """
Avalia uma regra de plural compilada para um dado `N` e devolve o índice
da forma plural — função TOTAL do caminho quente, usada por cada
`ngettext`/`npgettext`.

`Compiled` é o bundle de `compile/1`; `N` é a contagem (inteiro, pode ser
negativo — a regra decide a semântica). O retorno é sempre um
`non_neg_integer()` em `[0, NPlurals)`: a regra é interpretada e o
resultado coagido a inteiro.

Nunca levanta, mesmo sobre regra malformada (paridade com GNU libintl):
divisão/módulo por zero é coagida a 0 (`eval_div/2`/`eval_rem/2` em vez de
deixar `div`/`rem` lançar `badarith`) e uma forma fora de `[0, NPlurals)`
sofre clamp para 0 (`if index >= nplurals -> index = 0`).
""".
-spec evaluate(plural_compiled(), integer()) -> non_neg_integer().
evaluate(#{nplurals := NPlurals, expr := Ast}, N) when is_integer(N) ->
    Form = to_integer(eval_ast(Ast, N)),
    clamp_form(Form, NPlurals).

-doc """
Irmã estruturada de `evaluate/2`: em vez de fazer clamp silencioso,
reporta uma regra malformada como dado para que o consumidor possa
logar/alertar.

`Compiled` e `N` são como em `evaluate/2`. Retorna `{ok, Form}` com a
forma em `[0, NPlurals)`, ou `{error, plural_eval_error()}`:
`{division_by_zero, '/' | '%'}` quando o divisor avaliado é 0, ou
`{form_out_of_range, Form, NPlurals}` quando a forma sai da faixa. Mantém
o curto-circuito de `&&`/`||` (um divisor zero atrás de ramo falso não é
reportado) e, como `evaluate/2`, é total — nunca levanta.
""".
-spec evaluate_checked(plural_compiled(), integer()) ->
    {ok, non_neg_integer()} | {error, plural_eval_error()}.
evaluate_checked(#{nplurals := NPlurals, expr := Ast}, N) when is_integer(N) ->
    case eval_ast_checked(Ast, N) of
        {error, _} = Err ->
            Err;
        {ok, Value} ->
            Form = to_integer(Value),
            case Form >= 0 andalso Form < NPlurals of
                true -> {ok, Form};
                false -> {error, {form_out_of_range, Form, NPlurals}}
            end
    end.

%% Clamp a candidate form index into [0, NPlurals) à la libintl. NPlurals
%% is `pos_integer()` (validated at compile), so 0 is always a valid
%% form.
-spec clamp_form(integer(), pos_integer()) -> non_neg_integer().
clamp_form(Form, NPlurals) when Form >= 0, Form < NPlurals ->
    Form;
clamp_form(_Form, _NPlurals) ->
    0.

-doc """
Conveniência que compila e avalia num só passo: dado o cabeçalho bruto
`Header` e a contagem `N`, retorna `{ok, Form}` ou propaga o
`{error, compile_error()}` de `compile/1`.

Recompila a cada chamada, então é para uso pontual; no caminho quente,
chame `compile/1` uma vez no load e reuse o bundle com `evaluate/2`.
""".
-spec plural_by_po_header(binary(), integer()) ->
    {ok, non_neg_integer()} | {error, compile_error()}.
plural_by_po_header(Header, N) when is_binary(Header), is_integer(N) ->
    case compile(Header) of
        {ok, Compiled} -> {ok, evaluate(Compiled, N)};
        {error, _} = E -> E
    end.

-doc """
Procura a expressão canônica CLDR de plural para `Locale` na tabela
embutida.

Retorna `{ok, Expr}`, onde `Expr` é o binário da expressão C de plural
equivalente à regra CLDR daquele locale, ou `undefined` se nem o locale
nem sua língua-base estiverem na tabela. O casamento é sensível a
maiúsculas; tags de região caem na língua-base quando a própria região
não está listada (ex.: `fr_CA` -> `fr`).
""".
-spec cldr_rule(binary()) -> {ok, binary()} | undefined.
cldr_rule(Locale) when is_binary(Locale) ->
    case lookup_locale(Locale) of
        {ok, _N, Expr} ->
            {ok, Expr};
        undefined ->
            case base_locale(Locale) of
                Locale ->
                    undefined;
                Base ->
                    case lookup_locale(Base) of
                        {ok, _N2, Expr2} -> {ok, Expr2};
                        undefined -> undefined
                    end
            end
    end.

%% Compare a `.po` header expression against the CLDR canonical rule for
%% the given locale. Returns `ok` if the parsed ASTs are structurally
%% identical (whitespace-insensitive) or `{warning, _}` if they diverge
%% in a way that would affect runtime form selection. Per PSD-004 the
%% header always wins at runtime — this only produces observability.
%%
-doc """
Compara a expressão de plural do cabeçalho `HeaderRule` (forma bruta)
contra a regra canônica CLDR de `Locale`, produzindo apenas
observabilidade — em runtime o cabeçalho sempre vence (PSD-004).

Compila `HeaderRule` UMA vez e delega a `validate_against_cldr_ast/2`.
Retorna `ok` quando os ASTs `(nplurals, expr)` são estruturalmente
iguais (insensível a espaços/parênteses) ou quando o locale não tem
entrada CLDR; retorna
`{warning, {plural_divergence, Locale, HeaderRule, CldrRaw}}` quando
divergem — inclusive quando o cabeçalho é inválido mas o locale consta no
CLDR.

Ponto de entrada de conveniência para quem só tem o cabeçalho bruto. O
loader de catálogo, que já guarda o bundle compilado, deve usar
`validate_against_cldr_ast/2` para não recompilar o cabeçalho no load.
""".
-spec validate_against_cldr(binary(), binary()) ->
    ok
    | {warning, {plural_divergence, binary(), binary(), binary()}}.
validate_against_cldr(Locale, HeaderRule) when
    is_binary(Locale), is_binary(HeaderRule)
->
    case compile(HeaderRule) of
        {ok, Compiled} ->
            validate_against_cldr_ast(Locale, Compiled);
        {error, _} ->
            %% An unparseable header has no AST to compare. Before
            %% finding #17 this still produced a `{warning, _}` for a
            %% CLDR-listed locale (the header could not match the
            %% canonical rule), so preserve that observable behaviour.
            case cldr_compiled(Locale) of
                undefined -> ok;
                #{raw := CldrRaw} -> {warning, {plural_divergence, Locale, HeaderRule, CldrRaw}}
            end
    end.

%% AST-based sibling of `validate_against_cldr/2`. Takes the ALREADY
%% compiled header bundle (`plural_compiled()`) and compares it against
%% the CLDR canonical rule for the locale without recompiling anything:
%%
%%   * the header AST is reused as-is (the loader compiled it once via
%%     `compile/1` and keeps it in the catalog map);
%%   * the CLDR rule is taken from a one-time, memoised table of compiled
%%     ASTs (`cldr_compiled/1`), so no CLDR rule is parsed/synthesised on
%%     the load path either.
%%
%% Equivalence is structural on `(nplurals, expr-AST)` — exactly what the
%% old `ast_equivalent/2` computed, but with both sides already parsed.
%% The warning payload keeps the raw header string (the bundle's `raw`
%% field) and the raw CLDR expression, matching `validate_against_cldr/2`.
-doc """
Variante baseada em AST de `validate_against_cldr/2`: recebe o bundle JÁ
compilado (`plural_compiled()`) e compara contra a regra CLDR de `Locale`
sem recompilar nada (finding #17).

Reusa o AST do cabeçalho como está e toma o lado CLDR de uma tabela
memoizada de bundles compilados, então nenhuma regra é re-parseada no
load. Retorna `ok` se os pares `(nplurals, expr)` coincidem ou se o locale
não tem entrada CLDR; caso contrário
`{warning, {plural_divergence, Locale, HeaderRaw, CldrRaw}}`, com o
cabeçalho bruto (campo `raw` do bundle) e a expressão CLDR bruta.
""".
-spec validate_against_cldr_ast(binary(), plural_compiled()) ->
    ok
    | {warning, {plural_divergence, binary(), binary(), binary()}}.
validate_against_cldr_ast(Locale, #{nplurals := NH, expr := EH, raw := HeaderRaw}) when
    is_binary(Locale)
->
    case cldr_compiled(Locale) of
        undefined ->
            %% Locale has no CLDR entry; we cannot validate. Treat as ok
            %% — the loader has nothing meaningful to log.
            ok;
        #{nplurals := NC, expr := EC, raw := CldrRaw} ->
            case NH =:= NC andalso EH =:= EC of
                true -> ok;
                false -> {warning, {plural_divergence, Locale, HeaderRaw, CldrRaw}}
            end
    end.

-doc """
Regra de plural de fallback usada quando um catálogo `.po` não traz
nenhum cabeçalho `Plural-Forms:` (entrada degenerada mas tolerada).

Retorna `<<"nplurals=2; plural=n != 1;">>` — o default Germânico do C/
inglês citado pelo manual do GNU gettext (§"Plural forms").
""".
-spec fallback_rule() -> binary().
fallback_rule() ->
    <<"nplurals=2; plural=n != 1;">>.

%% =========================
%% Header tokenization
%% =========================

%% Extract the integer following `nplurals=`. Tolerant of surrounding
%% whitespace and the trailing semicolon. Returns
%% `{error, {missing_nplurals, _}}` when the field is not present, and
%% `{error, {nplurals_out_of_range, N}}` when N is outside the sanity
%% range [1, ?NPLURALS_MAX].
-spec extract_nplurals(binary()) ->
    {ok, pos_integer()} | {error, compile_error()}.
extract_nplurals(Header) ->
    case locate_field(Header, <<"nplurals">>) of
        {ok, Tail} ->
            {Digits, _} = consume_integer(skip_ws(Tail)),
            case byte_size(Digits) of
                0 ->
                    {error, {missing_nplurals, Header}};
                D when D > ?MAX_INT_DIGITS ->
                    %% Finding #8: cap by DIGIT COUNT before
                    %% `binary_to_integer` materialises the bignum, and
                    %% keep the rejected value OUT of the payload (only
                    %% the digit count + cap are reported) to avoid
                    %% memory/log amplification and the system_limit path.
                    {error, {nplurals_too_many_digits, D, ?MAX_INT_DIGITS}};
                _ ->
                    N = binary_to_integer(Digits),
                    case N >= 1 andalso N =< ?NPLURALS_MAX of
                        true -> {ok, N};
                        false -> {error, {nplurals_out_of_range, N}}
                    end
            end;
        not_found ->
            {error, {missing_nplurals, Header}}
    end.

%% Extract the raw expression following `plural=`, stripping the trailing
%% semicolon and surrounding whitespace. The returned binary still needs
%% to be fed to the recursive-descent parser.
-spec extract_plural_expr(binary()) ->
    {ok, binary()} | {error, compile_error()}.
extract_plural_expr(Header) ->
    case locate_field(Header, <<"plural">>) of
        {ok, Tail} ->
            ExprRaw = take_until_semicolon_or_end(Tail),
            case trim(ExprRaw) of
                <<>> -> {error, {missing_plural_expr, Header}};
                Trimmed -> {ok, Trimmed}
            end;
        not_found ->
            {error, {missing_plural_expr, Header}}
    end.

%% Locate `Field=` (case-sensitive — GNU gettext spec keeps these names
%% lower-case) in Header and return the bytes immediately after the `=`.
locate_field(Header, Field) ->
    %% Walk the header looking for `Field` followed (after optional
    %% whitespace) by `=`. We require either start-of-string or a
    %% delimiter (whitespace or `;`) before `Field` so that we do not
    %% match `nplurals` inside `intplurals` or similar.
    locate_field(Header, Field, 0).

locate_field(Bin, Field, Offset) ->
    case binary:match(Bin, Field, [{scope, {Offset, byte_size(Bin) - Offset}}]) of
        nomatch ->
            not_found;
        {Start, Len} ->
            case is_field_boundary_left(Bin, Start) of
                true ->
                    Tail0 = binary:part(
                        Bin,
                        Start + Len,
                        byte_size(Bin) - (Start + Len)
                    ),
                    case skip_to_equals(Tail0) of
                        {ok, Tail1} -> {ok, Tail1};
                        not_found -> locate_field(Bin, Field, Start + Len)
                    end;
                false ->
                    locate_field(Bin, Field, Start + Len)
            end
    end.

is_field_boundary_left(_Bin, 0) ->
    true;
is_field_boundary_left(Bin, Start) ->
    Prev = binary:at(Bin, Start - 1),
    is_header_delim(Prev).

is_header_delim($\s) -> true;
is_header_delim($\t) -> true;
is_header_delim($\n) -> true;
is_header_delim($\r) -> true;
is_header_delim($;) -> true;
is_header_delim(_) -> false.

skip_to_equals(<<>>) ->
    not_found;
skip_to_equals(<<$=, Rest/binary>>) ->
    {ok, Rest};
skip_to_equals(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t ->
    skip_to_equals(Rest);
skip_to_equals(_) ->
    not_found.

take_until_semicolon_or_end(Bin) ->
    take_until_semicolon_or_end(Bin, 0).

take_until_semicolon_or_end(Bin, N) when N >= byte_size(Bin) ->
    Bin;
take_until_semicolon_or_end(Bin, N) ->
    case binary:at(Bin, N) of
        $; -> binary:part(Bin, 0, N);
        %% header line terminator
        $\n -> binary:part(Bin, 0, N);
        _ -> take_until_semicolon_or_end(Bin, N + 1)
    end.

%% =========================
%% Recursive-descent parser
%% =========================
%%
%% Grammar (precedence low -> high), per GNU manual §"Plural forms":
%%
%%   expr        := ternary
%%   ternary     := lor ('?' expr ':' expr)?      (right-assoc)
%%   lor         := land ('||' land)*             (left-assoc)
%%   land        := equality ('&&' equality)*     (left-assoc)
%%   equality    := relational (('==' | '!=') relational)*
%%   relational  := additive (('<' | '>' | '<=' | '>=') additive)*
%%   additive    := multiplicative (('+' | '-') multiplicative)*
%%   multiplicative := unary (('*' | '/' | '%') unary)*
%%   unary       := '!' unary | primary
%%   primary     := INTEGER | 'n' | '(' expr ')'

-spec parse_expr_bin(binary()) ->
    {ok, ast()} | {error, compile_error()}.
%% Finding #2: reject an over-long expression BEFORE parsing it, so a
%% multi-KB adversarial rule never reaches the recursive descent.
parse_expr_bin(ExprBin) when byte_size(ExprBin) > ?PLURAL_EXPR_MAX_BYTES ->
    {error, {expr_too_long, byte_size(ExprBin), ?PLURAL_EXPR_MAX_BYTES}};
parse_expr_bin(ExprBin) ->
    try
        {Ast, St} = parse_expr(#ps{src = ExprBin}, 0),
        case skip_ws_st(St) of
            #ps{src = <<>>} ->
                {ok, Ast};
            St2 ->
                %% Trailing garbage (e.g. unbalanced `)` or stray token).
                {error, {syntax_error, {trailing_input, St2#ps.src}, St2#ps.pos}}
        end
    catch
        throw:{syntax_error, Reason, Pos} ->
            {error, {syntax_error, Reason, Pos}};
        %% Finding #2: recursion-depth guard tripped — fail closed with a
        %% structured error rather than parsing an unbounded-depth tree.
        throw:{expr_too_deep, Depth, Pos} ->
            {error, {expr_too_deep, Depth, Pos}}
    end.

%% `Depth` is propagated through every recursive-descent clause and
%% checked at each new nesting level (finding #2). It bounds both the
%% parser's stack and — because the AST it builds is no deeper than the
%% recursion — the hot-path `eval_ast/2` walker's stack per lookup.
parse_expr(St, Depth) when Depth > ?PLURAL_EXPR_MAX_DEPTH ->
    throw({expr_too_deep, Depth, St#ps.pos});
parse_expr(St, Depth) ->
    parse_ternary(St, Depth).

parse_ternary(St0, Depth) ->
    {Cond, St1} = parse_lor(St0, Depth),
    St2 = skip_ws_st(St1),
    case peek_byte(St2) of
        {ok, $?} ->
            St3 = advance(St2, 1),
            {Then, St4} = parse_expr(St3, Depth + 1),
            St5 = skip_ws_st(St4),
            case peek_byte(St5) of
                {ok, $:} ->
                    St6 = advance(St5, 1),
                    {Else, St7} = parse_expr(St6, Depth + 1),
                    {{ternary, Cond, Then, Else}, St7};
                _ ->
                    throw({syntax_error, {expected, $:, peek_byte(St5)}, St5#ps.pos})
            end;
        _ ->
            {Cond, St1}
    end.

parse_lor(St0, Depth) ->
    {Left, St1} = parse_land(St0, Depth),
    parse_lor_tail(Left, St1, Depth).

parse_lor_tail(Left, St0, Depth) ->
    St1 = skip_ws_st(St0),
    case peek2(St1) of
        {ok, $|, $|} ->
            St2 = advance(St1, 2),
            {Right, St3} = parse_land(St2, Depth + 1),
            parse_lor_tail({binop, '||', Left, Right}, St3, Depth);
        _ ->
            {Left, St0}
    end.

parse_land(St0, Depth) ->
    {Left, St1} = parse_equality(St0, Depth),
    parse_land_tail(Left, St1, Depth).

parse_land_tail(Left, St0, Depth) ->
    St1 = skip_ws_st(St0),
    case peek2(St1) of
        {ok, $&, $&} ->
            St2 = advance(St1, 2),
            {Right, St3} = parse_equality(St2, Depth + 1),
            parse_land_tail({binop, '&&', Left, Right}, St3, Depth);
        _ ->
            {Left, St0}
    end.

parse_equality(St0, Depth) ->
    {Left, St1} = parse_relational(St0, Depth),
    parse_equality_tail(Left, St1, Depth).

parse_equality_tail(Left, St0, Depth) ->
    St1 = skip_ws_st(St0),
    case peek2(St1) of
        {ok, $=, $=} ->
            St2 = advance(St1, 2),
            {Right, St3} = parse_relational(St2, Depth + 1),
            parse_equality_tail({binop, '==', Left, Right}, St3, Depth);
        {ok, $!, $=} ->
            St2 = advance(St1, 2),
            {Right, St3} = parse_relational(St2, Depth + 1),
            parse_equality_tail({binop, '!=', Left, Right}, St3, Depth);
        _ ->
            {Left, St0}
    end.

parse_relational(St0, Depth) ->
    {Left, St1} = parse_additive(St0, Depth),
    parse_relational_tail(Left, St1, Depth).

parse_relational_tail(Left, St0, Depth) ->
    St1 = skip_ws_st(St0),
    case peek2(St1) of
        {ok, $<, $=} ->
            St2 = advance(St1, 2),
            {Right, St3} = parse_additive(St2, Depth + 1),
            parse_relational_tail({binop, '<=', Left, Right}, St3, Depth);
        {ok, $>, $=} ->
            St2 = advance(St1, 2),
            {Right, St3} = parse_additive(St2, Depth + 1),
            parse_relational_tail({binop, '>=', Left, Right}, St3, Depth);
        {ok, $<, _} ->
            St2 = advance(St1, 1),
            {Right, St3} = parse_additive(St2, Depth + 1),
            parse_relational_tail({binop, '<', Left, Right}, St3, Depth);
        {ok, $>, _} ->
            St2 = advance(St1, 1),
            {Right, St3} = parse_additive(St2, Depth + 1),
            parse_relational_tail({binop, '>', Left, Right}, St3, Depth);
        _ ->
            {Left, St0}
    end.

parse_additive(St0, Depth) ->
    {Left, St1} = parse_multiplicative(St0, Depth),
    parse_additive_tail(Left, St1, Depth).

parse_additive_tail(Left, St0, Depth) ->
    St1 = skip_ws_st(St0),
    case peek_byte(St1) of
        {ok, $+} ->
            St2 = advance(St1, 1),
            {Right, St3} = parse_multiplicative(St2, Depth + 1),
            parse_additive_tail({binop, '+', Left, Right}, St3, Depth);
        {ok, $-} ->
            St2 = advance(St1, 1),
            {Right, St3} = parse_multiplicative(St2, Depth + 1),
            parse_additive_tail({binop, '-', Left, Right}, St3, Depth);
        _ ->
            {Left, St0}
    end.

parse_multiplicative(St0, Depth) ->
    {Left, St1} = parse_unary(St0, Depth),
    parse_multiplicative_tail(Left, St1, Depth).

parse_multiplicative_tail(Left, St0, Depth) ->
    St1 = skip_ws_st(St0),
    case peek_byte(St1) of
        {ok, $*} ->
            St2 = advance(St1, 1),
            {Right, St3} = parse_unary(St2, Depth + 1),
            parse_multiplicative_tail({binop, '*', Left, Right}, St3, Depth);
        {ok, $/} ->
            St2 = advance(St1, 1),
            {Right, St3} = parse_unary(St2, Depth + 1),
            parse_multiplicative_tail({binop, '/', Left, Right}, St3, Depth);
        {ok, $%} ->
            St2 = advance(St1, 1),
            {Right, St3} = parse_unary(St2, Depth + 1),
            parse_multiplicative_tail({binop, '%', Left, Right}, St3, Depth);
        _ ->
            {Left, St0}
    end.

parse_unary(St0, Depth) when Depth > ?PLURAL_EXPR_MAX_DEPTH ->
    throw({expr_too_deep, Depth, St0#ps.pos});
parse_unary(St0, Depth) ->
    St1 = skip_ws_st(St0),
    case peek_byte(St1) of
        {ok, $!} ->
            %% Disambiguate against `!=` (handled in parse_equality).
            case peek2(St1) of
                {ok, $!, $=} ->
                    parse_primary(St1, Depth);
                _ ->
                    St2 = advance(St1, 1),
                    {Inner, St3} = parse_unary(St2, Depth + 1),
                    {{unop, '!', Inner}, St3}
            end;
        _ ->
            parse_primary(St1, Depth)
    end.

parse_primary(St0, Depth) ->
    St1 = skip_ws_st(St0),
    case peek_byte(St1) of
        {ok, $(} ->
            St2 = advance(St1, 1),
            {Inner, St3} = parse_expr(St2, Depth + 1),
            St4 = skip_ws_st(St3),
            case peek_byte(St4) of
                {ok, $)} ->
                    {Inner, advance(St4, 1)};
                _ ->
                    throw({syntax_error, {unclosed_paren, peek_byte(St4)}, St4#ps.pos})
            end;
        {ok, $n} ->
            %% `n` is a single-character identifier; the GNU grammar
            %% does not permit multi-character identifiers in plural
            %% expressions.
            St2 = advance(St1, 1),
            case peek_byte(St2) of
                {ok, C} when ?IS_IDENT(C) ->
                    throw({syntax_error, {unknown_identifier_after_n, C}, St2#ps.pos});
                _ ->
                    {n, St2}
            end;
        {ok, D} when D >= $0, D =< $9 ->
            {Digits, St2} = consume_integer_st(St1),
            {binary_to_integer(Digits), St2};
        {ok, C} ->
            throw({syntax_error, {unexpected_char, C}, St1#ps.pos});
        eof ->
            throw({syntax_error, unexpected_eof, St1#ps.pos})
    end.

%% =========================
%% Parser state helpers
%% =========================

%% Finding #2 (plural-compile-superlinear-unbounded): dispatch on a
%% `byte_size/1` comparison, NOT a full-binary `=:=` match. `skip_ws/1`
%% only ever strips a leading prefix, so when nothing is consumed the
%% result is byte-for-byte equal and `byte_size(Rest) =:= byte_size(Src)`
%% is exact. Matching `case skip_ws(Src) of Src -> ...` instead forced a
%% byte-by-byte comparison of the whole remaining input on every token
%% (the binaries are structurally equal but not identical), which made
%% the parser O(n^2). `byte_size/1` is O(1), collapsing it to O(n).
skip_ws_st(#ps{src = Src, pos = Pos} = St) ->
    Rest = skip_ws(Src),
    case byte_size(Rest) =:= byte_size(Src) of
        true ->
            St;
        false ->
            Consumed = byte_size(Src) - byte_size(Rest),
            St#ps{src = Rest, pos = Pos + Consumed}
    end.

skip_ws(<<C, Rest/binary>>) when
    C =:= $\s;
    C =:= $\t;
    C =:= $\n;
    C =:= $\r
->
    skip_ws(Rest);
skip_ws(Bin) ->
    Bin.

peek_byte(#ps{src = <<>>}) -> eof;
peek_byte(#ps{src = <<B, _/binary>>}) -> {ok, B}.

peek2(#ps{src = <<>>}) -> eof;
peek2(#ps{src = <<_>>}) -> eof;
peek2(#ps{src = <<A, B, _/binary>>}) -> {ok, A, B}.

advance(#ps{src = Src, pos = Pos} = St, N) ->
    St#ps{
        src = binary:part(Src, N, byte_size(Src) - N),
        pos = Pos + N
    }.

consume_integer_st(#ps{src = Src, pos = Pos}) ->
    {Digits, Rest} = consume_integer(Src),
    Len = byte_size(Digits),
    {Digits, #ps{src = Rest, pos = Pos + Len}}.

consume_integer(Bin) -> consume_integer(Bin, 0).

consume_integer(Bin, N) when N >= byte_size(Bin) ->
    {Bin, <<>>};
consume_integer(Bin, N) ->
    case binary:at(Bin, N) of
        D when D >= $0, D =< $9 -> consume_integer(Bin, N + 1);
        _ -> {binary:part(Bin, 0, N), binary:part(Bin, N, byte_size(Bin) - N)}
    end.

trim(Bin) -> trim_trailing(trim_leading(Bin)).

trim_leading(<<C, Rest/binary>>) when
    C =:= $\s;
    C =:= $\t;
    C =:= $\n;
    C =:= $\r
->
    trim_leading(Rest);
trim_leading(Bin) ->
    Bin.

trim_trailing(Bin) ->
    Size = byte_size(Bin),
    trim_trailing(Bin, Size).

trim_trailing(_Bin, 0) ->
    <<>>;
trim_trailing(Bin, N) ->
    case binary:at(Bin, N - 1) of
        C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
            trim_trailing(Bin, N - 1);
        _ ->
            binary:part(Bin, 0, N)
    end.

%% =========================
%% Interpreter (hot path)
%% =========================

%% C-truthy coercion (from legacy gettexter_plural to_boolean/1).
%% `0` is false, any other integer is true. Boolean inputs are passed
%% through to keep short-circuit interop in `eval_ast/2` clean.
-spec to_boolean(integer() | boolean()) -> boolean().
to_boolean(true) -> true;
to_boolean(false) -> false;
to_boolean(0) -> false;
to_boolean(N) when is_integer(N) -> true.

%% Reverse coercion: booleans returned by `&&`/`||`/`!`/comparison ops
%% must materialize as 0 or 1 on the way out (since plural form indices
%% are integers).
-spec to_integer(integer() | boolean()) -> integer().
to_integer(true) -> 1;
to_integer(false) -> 0;
to_integer(N) when is_integer(N) -> N.

%% Walker. Returns either an integer (arithmetic result) or a boolean
%% (comparison / logical result) — the caller coerces as needed.
-spec eval_ast(ast(), integer()) -> integer() | boolean().
eval_ast(N, _N) when is_integer(N) ->
    N;
eval_ast(n, N) ->
    N;
eval_ast({unop, '!', E}, N) ->
    not to_boolean(eval_ast(E, N));
eval_ast({binop, '&&', L, R}, N) ->
    %% Short-circuit per C semantics: if L is false, do not evaluate R.
    case to_boolean(eval_ast(L, N)) of
        false -> false;
        true -> to_boolean(eval_ast(R, N))
    end;
eval_ast({binop, '||', L, R}, N) ->
    case to_boolean(eval_ast(L, N)) of
        true -> true;
        false -> to_boolean(eval_ast(R, N))
    end;
eval_ast({binop, Op, L, R}, N) ->
    LV = to_integer(eval_ast(L, N)),
    RV = to_integer(eval_ast(R, N)),
    apply_binop(Op, LV, RV);
eval_ast({ternary, C, T, E}, N) ->
    case to_boolean(eval_ast(C, N)) of
        true -> eval_ast(T, N);
        false -> eval_ast(E, N)
    end.

-spec apply_binop(op(), integer(), integer()) -> integer() | boolean().
apply_binop('+', L, R) -> L + R;
apply_binop('-', L, R) -> L - R;
apply_binop('*', L, R) -> L * R;
apply_binop('/', L, R) -> eval_div(L, R);
apply_binop('%', L, R) -> eval_rem(L, R);
apply_binop('==', L, R) -> L =:= R;
apply_binop('!=', L, R) -> L =/= R;
apply_binop('<', L, R) -> L < R;
apply_binop('>', L, R) -> L > R;
apply_binop('<=', L, R) -> L =< R;
apply_binop('>=', L, R) -> L >= R.

%% Total division / modulo (finding #1, Layer 1). A zero divisor is C
%% undefined behaviour; rather than let Erlang `div`/`rem` raise
%% `badarith` in the caller process, we pin the result to 0 — the
%% expression result is still clamped into range afterwards. Real `.po`
%% rules never divide by a value that reaches zero (they guard with
%% short-circuit `&&`/`||`), so this only ever fires on malformed input.
-spec eval_div(integer(), integer()) -> integer().
eval_div(_L, 0) -> 0;
eval_div(L, R) -> L div R.

-spec eval_rem(integer(), integer()) -> integer().
eval_rem(_L, 0) -> 0;
eval_rem(L, R) -> L rem R.

%% =========================
%% Checked interpreter (finding #1, Layer 2)
%% =========================
%%
%% Mirror of `eval_ast/2` that surfaces the two unsafe conditions as
%% structured data instead of clamping: division/modulo by zero and
%% (handled by the caller `evaluate_checked/2`) an out-of-range form.
%% Short-circuit semantics for `&&`/`||` are preserved, so a zero
%% divisor guarded behind a false branch is never reported — matching
%% the dynamic evaluator. Total: never raises.

-spec eval_ast_checked(ast(), integer()) ->
    {ok, integer() | boolean()} | {error, plural_eval_error()}.
eval_ast_checked(N, _N) when is_integer(N) ->
    {ok, N};
eval_ast_checked(n, N) ->
    {ok, N};
eval_ast_checked({unop, '!', E}, N) ->
    case eval_ast_checked(E, N) of
        {ok, V} -> {ok, not to_boolean(V)};
        {error, _} = Err -> Err
    end;
eval_ast_checked({binop, '&&', L, R}, N) ->
    case eval_ast_checked(L, N) of
        {error, _} = Err ->
            Err;
        {ok, LV} ->
            case to_boolean(LV) of
                false -> {ok, false};
                true -> to_boolean_checked(eval_ast_checked(R, N))
            end
    end;
eval_ast_checked({binop, '||', L, R}, N) ->
    case eval_ast_checked(L, N) of
        {error, _} = Err ->
            Err;
        {ok, LV} ->
            case to_boolean(LV) of
                true -> {ok, true};
                false -> to_boolean_checked(eval_ast_checked(R, N))
            end
    end;
eval_ast_checked({binop, Op, L, R}, N) ->
    case eval_ast_checked(L, N) of
        {error, _} = ErrL ->
            ErrL;
        {ok, LV0} ->
            case eval_ast_checked(R, N) of
                {error, _} = ErrR ->
                    ErrR;
                {ok, RV0} ->
                    apply_binop_checked(Op, to_integer(LV0), to_integer(RV0))
            end
    end;
eval_ast_checked({ternary, C, T, E}, N) ->
    case eval_ast_checked(C, N) of
        {error, _} = Err ->
            Err;
        {ok, CV} ->
            case to_boolean(CV) of
                true -> eval_ast_checked(T, N);
                false -> eval_ast_checked(E, N)
            end
    end.

%% Coerce the right operand of a short-circuit op to a boolean result,
%% propagating any error from the underlying evaluation.
-spec to_boolean_checked({ok, integer() | boolean()} | {error, plural_eval_error()}) ->
    {ok, boolean()} | {error, plural_eval_error()}.
to_boolean_checked({error, _} = Err) -> Err;
to_boolean_checked({ok, V}) -> {ok, to_boolean(V)}.

-spec apply_binop_checked(op(), integer(), integer()) ->
    {ok, integer() | boolean()} | {error, plural_eval_error()}.
apply_binop_checked('/', _L, 0) -> {error, {division_by_zero, '/'}};
apply_binop_checked('%', _L, 0) -> {error, {division_by_zero, '%'}};
apply_binop_checked(Op, L, R) -> {ok, apply_binop(Op, L, R)}.

%% =========================
%% Static safety validation (finding #1, Layer 3)
%% =========================
%%
%% Reject — at compile/load time — rules that are STATICALLY guaranteed
%% to fault for every N, so the poisoned catalog is refused by
%% `ensure_loaded` instead of loading as `{ok, _}` and crashing each
%% later lookup. We only reject what is *provably* faulty regardless of
%% input; conditions that fault only for a specific N (e.g. `n / (n-5)`)
%% are left to the dynamic clamp in Layer 1.
%%
%% Two static faults are detected:
%%   * a `/` or `%` whose divisor is a constant subexpression (no `n`)
%%     evaluating to 0 — fails for all N;
%%   * a fully-constant rule (no `n` anywhere) whose value lands outside
%%     [0, NPlurals) — selects a non-existent form for all N.

-spec validate_safe(ast(), pos_integer()) -> ok | {error, plural_eval_error()}.
validate_safe(Ast, NPlurals) ->
    case static_div_zero(Ast) of
        {error, _} = Err ->
            Err;
        ok ->
            case is_constant(Ast) of
                false ->
                    %% Depends on N — Layer 1 covers any dynamic fault.
                    ok;
                true ->
                    %% N is irrelevant for a constant rule; 0 is a fine
                    %% probe. A constant out-of-range result is a static
                    %% fault. We evaluate the AST directly (not via
                    %% evaluate_checked/2) to avoid materialising a partial
                    %% plural_compiled() map just for the probe.
                    static_form_in_range(Ast, NPlurals)
            end
    end.

%% Probe a constant rule's form index and reject it if it lands outside
%% [0, NPlurals). `static_div_zero/1` has already cleared the AST of
%% division-by-zero, so the only error reachable here is an out-of-range
%% form; the {error, _} arm just propagates any future eval anomaly.
-spec static_form_in_range(ast(), pos_integer()) -> ok | {error, plural_eval_error()}.
static_form_in_range(Ast, NPlurals) ->
    case eval_ast_checked(Ast, 0) of
        {ok, Value} ->
            Form = to_integer(Value),
            case Form >= 0 andalso Form < NPlurals of
                true -> ok;
                false -> {error, {form_out_of_range, Form, NPlurals}}
            end;
        {error, _} = Err ->
            Err
    end.

%% Walk the AST for a `/` or `%` whose divisor is statically zero. The
%% divisor counts as statically zero only when it is constant (contains
%% no `n`) and evaluates to 0 — a divisor that depends on N is not a
%% static fault.
-spec static_div_zero(ast()) -> ok | {error, plural_eval_error()}.
static_div_zero(N) when is_integer(N) ->
    ok;
static_div_zero(n) ->
    ok;
static_div_zero({unop, '!', E}) ->
    static_div_zero(E);
static_div_zero({binop, Op, L, R}) when Op =:= '/'; Op =:= '%' ->
    case static_div_zero(L) of
        {error, _} = Err ->
            Err;
        ok ->
            case static_div_zero(R) of
                {error, _} = Err -> Err;
                ok -> check_static_divisor(Op, R)
            end
    end;
static_div_zero({binop, _Op, L, R}) ->
    case static_div_zero(L) of
        {error, _} = Err -> Err;
        ok -> static_div_zero(R)
    end;
static_div_zero({ternary, C, T, E}) ->
    case static_div_zero(C) of
        {error, _} = Err ->
            Err;
        ok ->
            case static_div_zero(T) of
                {error, _} = Err -> Err;
                ok -> static_div_zero(E)
            end
    end.

-spec check_static_divisor('/' | '%', ast()) -> ok | {error, plural_eval_error()}.
check_static_divisor(Op, Divisor) ->
    case is_constant(Divisor) of
        false ->
            ok;
        true ->
            case eval_ast_checked(Divisor, 0) of
                {ok, V} ->
                    case to_integer(V) of
                        0 -> {error, {division_by_zero, Op}};
                        _ -> ok
                    end;
                %% A nested static div-by-zero inside the divisor is
                %% already reported by the recursive walk above.
                {error, _} = Err ->
                    Err
            end
    end.

%% True when the AST contains no reference to the variable `n`, so its
%% value is independent of the lookup count.
-spec is_constant(ast()) -> boolean().
is_constant(N) when is_integer(N) -> true;
is_constant(n) -> false;
is_constant({unop, '!', E}) -> is_constant(E);
is_constant({binop, _Op, L, R}) -> is_constant(L) andalso is_constant(R);
is_constant({ternary, C, T, E}) -> is_constant(C) andalso is_constant(T) andalso is_constant(E).

%% =========================
%% AST node-count cap (finding #9, plural-bignum-cpu-dos-evaluate-hotpath)
%% =========================
%%
%% Reject — at compile/load time — an AST whose node count exceeds
%% `?AST_MAX_NODES`. The byte and depth caps from finding #2 do not bound
%% the node count, so a wide flat operator chain (`n*n*...*n`, ~2000 nodes
%% inside the 2048-byte cap, at a single recursion level) would otherwise
%% be installed and walked by `evaluate/2` — growing an `n^k` bignum — on
%% every ngettext lookup. Capping the node count keeps the installed AST
%% small so `evaluate/2`'s cost is bounded by construction (largest
%% intermediate bignum is `n^?AST_MAX_NODES`). Runs once on the load path,
%% never on the hot path.

%% Short-circuiting node-count guard: stops descending as soon as the
%% budget is blown, so its cost is O(min(nodes, ?AST_MAX_NODES)) — never
%% proportional to a pathologically large AST.
-spec check_ast_complexity(ast()) ->
    ok | {error, {expr_too_complex, pos_integer(), pos_integer()}}.
check_ast_complexity(Ast) ->
    case count_nodes_bounded(Ast, 0) of
        {ok, _Total} ->
            ok;
        over_limit ->
            %% Only the (rare, off-hot-path) error branch pays for the
            %% exact total — used purely for diagnostics.
            {error, {expr_too_complex, ast_node_count(Ast), ?AST_MAX_NODES}}
    end.

%% Budgeted counter. Returns `{ok, Total}` if the whole AST fits within
%% `?AST_MAX_NODES`, otherwise `over_limit` at the first node that blows
%% the budget.
-spec count_nodes_bounded(ast(), non_neg_integer()) ->
    {ok, non_neg_integer()} | over_limit.
count_nodes_bounded(_Ast, Acc) when Acc > ?AST_MAX_NODES ->
    over_limit;
count_nodes_bounded(N, Acc) when is_integer(N) ->
    {ok, Acc + 1};
count_nodes_bounded(n, Acc) ->
    {ok, Acc + 1};
count_nodes_bounded({unop, '!', E}, Acc) ->
    count_nodes_bounded(E, Acc + 1);
count_nodes_bounded({binop, _Op, L, R}, Acc) ->
    case count_nodes_bounded(L, Acc + 1) of
        over_limit -> over_limit;
        {ok, Acc1} -> count_nodes_bounded(R, Acc1)
    end;
count_nodes_bounded({ternary, C, T, E}, Acc) ->
    case count_nodes_bounded(C, Acc + 1) of
        over_limit ->
            over_limit;
        {ok, Acc1} ->
            case count_nodes_bounded(T, Acc1) of
                over_limit -> over_limit;
                {ok, Acc2} -> count_nodes_bounded(E, Acc2)
            end
    end.

%% Exact, total node count — used only on the error branch for diagnostic
%% reporting (`{expr_too_complex, Nodes, Max}`).
-spec ast_node_count(ast()) -> pos_integer().
ast_node_count(N) when is_integer(N) ->
    1;
ast_node_count(n) ->
    1;
ast_node_count({unop, '!', E}) ->
    1 + ast_node_count(E);
ast_node_count({binop, _Op, L, R}) ->
    1 + ast_node_count(L) + ast_node_count(R);
ast_node_count({ternary, C, T, E}) ->
    1 + ast_node_count(C) + ast_node_count(T) + ast_node_count(E).

%% =========================
%% CLDR canonical rules
%% =========================
%%
%% Hard-coded subset of the CLDR `plurals.json` data
%% (cldr-json/cldr-core/supplemental/plurals.json in
%% https://github.com/unicode-org/cldr-json,
%% retrieved 2026-05 — see also https://cldr.unicode.org/index/cldr-spec/plural-rules
%% for the rule language). Each row is `{Locale, NPlurals, ExprBin}`
%% where `ExprBin` is the C-style plural expression that, when paired
%% with `nplurals=NPlurals`, produces the canonical CLDR rule.
%%
%% Region-tagged locales (e.g. `pt_BR`) are included where CLDR
%% diverges from the base language (e.g. `pt` is European Portuguese
%% with `n != n` (sic — n!=0 && n!=1; this codifies the simple
%% historical `n > 1`), while `pt_BR` matches the legacy `n > 1`).
%% Locales not listed fall back to the base language tag via
%% `cldr_rule/1`.
%%
%% v0.1 strategy (Option A — hard-coded):
%%   Pros: zero deps, byte-equal control over what ships, easy to audit.
%%   Cons: requires manual sync on each CLDR release.
%%
%% v0.2+ direction (Option C): generate `priv/cldr_plurals.eterm` from
%% upstream JSON via an escript. Not done in v0.1 to keep the surface
%% small and reviewable.

cldr_data() ->
    [
        %% Germanic / Romance singular vs. plural (n != 1)
        {<<"en">>, 2, <<"n != 1">>},
        {<<"en_US">>, 2, <<"n != 1">>},
        {<<"en_GB">>, 2, <<"n != 1">>},
        {<<"de">>, 2, <<"n != 1">>},
        {<<"de_AT">>, 2, <<"n != 1">>},
        {<<"de_CH">>, 2, <<"n != 1">>},
        {<<"nl">>, 2, <<"n != 1">>},
        {<<"sv">>, 2, <<"n != 1">>},
        {<<"da">>, 2, <<"n != 1">>},
        {<<"no">>, 2, <<"n != 1">>},
        {<<"nb">>, 2, <<"n != 1">>},
        {<<"nn">>, 2, <<"n != 1">>},
        {<<"fi">>, 2, <<"n != 1">>},
        {<<"es">>, 2, <<"n != 1">>},
        {<<"es_MX">>, 2, <<"n != 1">>},
        {<<"es_ES">>, 2, <<"n != 1">>},
        {<<"it">>, 2, <<"n != 1">>},
        {<<"el">>, 2, <<"n != 1">>},
        {<<"bg">>, 2, <<"n != 1">>},
        {<<"hu">>, 2, <<"n != 1">>},
        {<<"tr">>, 2, <<"n != 1">>},
        {<<"he">>, 2, <<"n != 1">>},
        {<<"fa">>, 2, <<"n != 1">>},
        {<<"hi">>, 2, <<"n != 1">>},
        {<<"et">>, 2, <<"n != 1">>},
        %% French family: 0 and 1 are singular, 2+ plural
        {<<"fr">>, 2, <<"n > 1">>},
        {<<"fr_FR">>, 2, <<"n > 1">>},
        {<<"fr_CA">>, 2, <<"n > 1">>},
        {<<"pt">>, 2, <<"n > 1">>},
        {<<"pt_BR">>, 2, <<"n > 1">>},
        {<<"pt_PT">>, 2, <<"n != 1">>},
        %% Slavic 3-form (one / few / many) family
        {<<"ru">>, 3, <<
            "n%10==1 && n%100!=11 ? 0 : "
            "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2"
        >>},
        {<<"uk">>, 3, <<
            "n%10==1 && n%100!=11 ? 0 : "
            "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2"
        >>},
        {<<"sr">>, 3, <<
            "n%10==1 && n%100!=11 ? 0 : "
            "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2"
        >>},
        {<<"hr">>, 3, <<
            "n%10==1 && n%100!=11 ? 0 : "
            "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2"
        >>},
        {<<"pl">>, 3, <<
            "n==1 ? 0 : "
            "n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2"
        >>},
        {<<"cs">>, 3, <<"(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2">>},
        {<<"sk">>, 3, <<"(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2">>},
        {<<"sl">>, 4, <<
            "n%100==1 ? 0 : n%100==2 ? 1 : "
            "n%100==3 || n%100==4 ? 2 : 3"
        >>},
        {<<"ro">>, 3, <<"n==1 ? 0 : (n==0 || (n%100>0 && n%100<20)) ? 1 : 2">>},
        %% Asian degenerate (PSD-008): single form
        {<<"ja">>, 1, <<"0">>},
        {<<"ko">>, 1, <<"0">>},
        {<<"vi">>, 1, <<"0">>},
        {<<"th">>, 1, <<"0">>},
        {<<"zh">>, 1, <<"0">>},
        {<<"zh_CN">>, 1, <<"0">>},
        {<<"zh_TW">>, 1, <<"0">>},
        {<<"zh_HK">>, 1, <<"0">>},
        %% Arabic 6-form
        {<<"ar">>, 6, <<
            "n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : "
            "n%100>=3 && n%100<=10 ? 3 : "
            "n%100>=11 ? 4 : 5"
        >>}
    ].

lookup_locale(Locale) ->
    lookup_locale(Locale, cldr_data()).

lookup_locale(_Locale, []) ->
    undefined;
lookup_locale(Locale, [{Locale, N, Expr} | _]) ->
    {ok, N, Expr};
lookup_locale(Locale, [_ | Rest]) ->
    lookup_locale(Locale, Rest).

%% Strip the region tag from a locale (`pt_BR` -> `pt`, `zh-Hant` ->
%% `zh`). Accepts both `_` and `-` as separators per BCP47 leniency.
base_locale(Locale) ->
    case binary:match(Locale, [<<"_">>, <<"-">>]) of
        nomatch -> Locale;
        {Pos, _Len} -> binary:part(Locale, 0, Pos)
    end.

%% =========================
%% CLDR equivalence check (pre-compiled)
%% =========================
%%
%% Divergence is checked structurally on the parsed ASTs (nplurals + expr
%% AST), so it is whitespace and paren-noise insensitive — `(n != 1)`
%% matches `n != 1`. Finding #17: the loader already compiled the header
%% AST, so `validate_against_cldr_ast/2` reuses it; the CLDR side is taken
%% from a one-time MEMOISED table of compiled bundles (`cldr_compiled/1`)
%% instead of re-parsing the canonical rule on every load. This removes
%% the second header compile (and the per-load CLDR synthesise+compile +
%% linear scans) that the old `ast_equivalent/split_rule` path incurred,
%% and decouples divergence from the plural-compile O(n^2) bug (a
%% pathological header is compiled once, not twice).

%% persistent_term key for the memoised CLDR AST table. The table is a
%% constant (~49 rows of static literals) so a single global cache is
%% sound: it is content-addressed by the module and never invalidated.
-define(CLDR_COMPILED_KEY, {?MODULE, cldr_compiled_table}).

%% Compiled CLDR bundle for a locale, with region fallback identical to
%% `cldr_rule/1` (`fr_BE` -> `fr`). Returns the same `plural_compiled()`
%% shape as `compile/1` so the AST can be compared directly; `raw` carries
%% the CLDR canonical EXPRESSION binary (matching the old
%% `validate_against_cldr/2` warning payload, which used `cldr_rule/1`'s
%% expr). `undefined` when neither the locale nor its base is in the table.
-spec cldr_compiled(binary()) -> plural_compiled() | undefined.
cldr_compiled(Locale) when is_binary(Locale) ->
    Table = cldr_compiled_table(),
    case maps:find(Locale, Table) of
        {ok, Bundle} ->
            Bundle;
        error ->
            case base_locale(Locale) of
                Locale ->
                    undefined;
                Base ->
                    maps:get(Base, Table, undefined)
            end
    end.

%% Return the memoised locale -> compiled-bundle map, building it exactly
%% once per node and caching it in `persistent_term`. `cldr_data/0` is a
%% static, trusted constant whose every expression is a canonical CLDR
%% rule, so each `compile/1` here is guaranteed to succeed; a malformed
%% row would be a build-time defect in this module and is surfaced
%% immediately (the bad row is simply dropped from the table, so it falls
%% back to "no CLDR entry" rather than crashing the loader).
-spec cldr_compiled_table() -> #{binary() => plural_compiled()}.
cldr_compiled_table() ->
    case persistent_term:get(?CLDR_COMPILED_KEY, undefined) of
        undefined ->
            Table = build_cldr_compiled_table(),
            persistent_term:put(?CLDR_COMPILED_KEY, Table),
            Table;
        Table when is_map(Table) ->
            %% `persistent_term:get/2` is typed `term()`; the only writer
            %% is the clause above, so this branch is the cache hit.
            eqwalizer:dynamic_cast(Table)
    end.

-spec build_cldr_compiled_table() -> #{binary() => plural_compiled()}.
build_cldr_compiled_table() ->
    lists:foldl(
        fun({Locale, N, Expr}, Acc) ->
            Header = <<
                "nplurals=",
                (integer_to_binary(N))/binary,
                "; plural=",
                Expr/binary,
                ";"
            >>,
            case compile(Header) of
                {ok, #{nplurals := NC, expr := Ast}} ->
                    %% Store the raw CLDR EXPRESSION (not the synthesised
                    %% header) as `raw`, to match the legacy warning
                    %% payload that surfaced `cldr_rule/1`'s expr.
                    Acc#{Locale => #{nplurals => NC, expr => Ast, raw => Expr}};
                {error, _} ->
                    %% A canonical CLDR row that fails to compile is a
                    %% defect in `cldr_data/0`; skip it so the locale
                    %% degrades to "no CLDR entry" instead of poisoning
                    %% the cache.
                    Acc
            end
        end,
        #{},
        cldr_data()
    ).
