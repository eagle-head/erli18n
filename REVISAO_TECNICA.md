# Revisão Técnica — erli18n

> Revisão multi-agente de ~4.200 LOC (6 lentes em paralelo → verificação adversarial por achado → soluções estruturais fundamentadas em fontes oficiais).
> **43 candidatos → 40 confirmados → 19 achados acionáveis** (+1 lead refutado). Muitos reproduzidos **ao vivo em OTP 28.4.3 / ERTS 16.3.1**.
> **Nenhum arquivo-fonte foi modificado** — revisão apenas; nada foi commitado ou enviado. Data: 2026-06-10.

## Sumário executivo

O `erli18n` é uma biblioteca bem arquitetada na superfície (fachada gettext completa, leitura *lock-free* via ETS, *telemetry* opcional, tipos eqwalizer-friendly, suíte PropEr/fuzz). Porém, sob o **modelo de ameaça que o próprio `SECURITY.md` declara** — `.po` e o avaliador de plural processam **entrada não-confiável** de inquilinos (multi-tenant, ADR-0003), e *"erros de parsing devem virar erros estruturados, nunca crashes silenciosos ou crescimento ilimitado de memória"* — a biblioteca tem **violações diretas de contrato** e **gargalos de complexidade** sérios:

- **Disponibilidade / DoS por requisição (contrato violado):** uma regra `Plural-Forms` maliciosa válida (`plural=n/0`, `plural=7`, …) **passa no `compile/1`** e o catálogo carrega com `{ok,1}`; a partir daí **todo** `ngettext`/`npgettext` daquele `(domínio,locale)` **derruba o processo da requisição** com `badarith` ou `plural_form_out_of_range`. O `gen_server`/supervisor nem percebe (o fuzz F7 de invariância de pid não detecta).
- **Blow-ups algorítmicos confirmados ao vivo:** compile de `Plural-Forms` **O(n²)** (400 KB: 1063 ms → **19 ms** com 1 linha); decode de string PO **O(n²)** (msgid 400 KB ≈ 8–10 s; 8× input → ~100× tempo); `memory_info` faz `ets:tab2list` **por carga** → carregar N catálogos é **O(N²)** (boot de 300 catálogos ≈ 34–47 s vs ~0,04 ms).
- **Arquitetura OTP:** o pipeline de carga inteiro (read+parse+compile+scan da tabela toda) roda **dentro do `handle_call`** do único `gen_server` → serializa todas as cargas, head-of-line blocking, e estoura o timeout padrão de 5 s. ETS sem `heir` → qualquer crash do server perde **todos** os catálogos.
- **Não-atomicidade do `reload`:** apaga o catálogo bom **antes** de tentar recarregar → um reload com `.po` inválido **destrói permanentemente** a tradução em uso; mesmo no sucesso há janela vazia (reload de 6,5 MB → 1673 ms com **89% de misses** concorrentes).

**Contagem por severidade:** 🔴 5 High · 🟠 7 Medium · 🟡 5 Low · ⚪ 2 Info.

---

## Sumário de achados

| # | Sev | Cat | ID | Local (resumido) | Resumo | Repro ao vivo |
|---|-----|-----|----|------------------|--------|:---:|
| 1 | 🔴 High | robustez | `plural-eval-throws-per-lookup-dos` | `erli18n_plural.erl:164-174,704-714`; `erli18n_server.erl:213` | `evaluate/2` crasha o chamador por lookup (`badarith` / `plural_form_out_of_range`) em regra não-confiável | ✅ |
| 2 | 🔴 High | complex. | `plural-compile-superlinear-unbounded` | `erli18n_plural.erl:580-587,368-574` | compile de `Plural-Forms` **O(n²)** sem limite de profundidade/tamanho; bloqueia o gen_server e estoura o timeout de 5 s | ✅ |
| 3 | 🔴 High | complex. | `po-decode-bins-to-binary-quadratic` | `erli18n_po.erl:258-266,888-907` | decode de string PO **O(n²)** (`bins_to_binary` append à direita) | ✅ |
| 4 | 🔴 High | robustez | `reload-not-atomic-destroys-catalog-and-empty-window` | `erli18n_server.erl:818-847` | `reload` apaga antes de recarregar: erro destrói o catálogo bom; sucesso deixa janela vazia | ✅ |
| 5 | 🔴 High | correção | `po-header-malformed-content-type-badmatch-crash` | `erli18n_po.erl:662,676-686,289` | `Content-Type ` com espaço antes do `:` → `badmatch` derruba o gen_server | ✅ |
| 6 | 🟠 Med | concorr. | `load-pipeline-serialized-in-gen-server-no-bounds-or-timeout` | `erli18n_server.erl:778-847,883-921` | pipeline de carga inteiro no `handle_call`, sem bounds/timeout/bulk | ✅ |
| 7 | 🟠 Med | complex. | `memory-info-tab2list-per-load-quadratic` | `erli18n_server.erl:1005,225-239,1199-1213` | `ets:tab2list` por carga → N cargas **O(N²)** | ✅ |
| 8 | 🟠 Med | complex. | `po-plural-unbounded-binary-to-integer-bignum` | `erli18n_po.erl:736-741,842-863`; `erli18n_plural.erl:251-267` | `binary_to_integer` ilimitado → bignum O(d²) + `system_limit` cru | ✅ |
| 9 | 🟠 Med | complex. | `plural-bignum-cpu-dos-evaluate-hotpath` | `erli18n_plural.erl:338-349,694-714` | expressão sem limite → bignum **por lookup** (cadeia 10 K → 138 ms/eval) | ✅ |
| 10 | 🟠 Med | robustez | `ets-owned-by-server-no-heir-crash-loses-all-catalogs` | `erli18n_server.erl:725-733`; `erli18n_sup.erl` | ETS sem `heir`; crash do server perde todos os catálogos | ✅ |
| 11 | 🟠 Med | correção | `po-hex-octal-escape-emits-invalid-utf8` | `erli18n_po.erl:933-961,351-374` | `\xHH`/`\OOO` emitem bytes crus pós-gate UTF-8 → tradução inválida | ✅ |
| 12 | 🟠 Med | manut. | `ensure-error-narrowing-boilerplate-load-bearing-only-for-eqwalizer` | `erli18n_server.erl:432-719` | ~245 LOC de narrowing só para o eqwalizer, com branches mortos | — |
| 13 | 🟡 Low | complex. | `server-unload-select-delete-full-scan` | `erli18n_server.erl:1148-1161` | `ets:select_delete` varre a tabela inteira para remover 1 catálogo | ✅ |
| 14 | 🟡 Low | correção | `dump-drops-msgid-plural-silently` | `erli18n_po.erl:1005-1019` | `dump/1` emite `msgid_plural` errado (= msgid singular) | ✅ |
| 15 | 🟡 Low | correção | `po-lone-cr-line-endings-not-normalized` | `erli18n_po.erl:422-424` | lone-CR (Mac clássico) não normalizado → erro de sintaxe espúrio | ✅ |
| 16 | 🟡 Low | manut. | `lookup-plural-5-exported-footgun-bypasses-form-evaluation` | `erli18n_server.erl:19-24,168-174` | `lookup_plural/5` exportado, sem guard, ignora seleção de forma | ✅ |
| 17 | 🟡 Low | complex. | `compute-divergence-recompiles-header-and-cldr-each-load` | `erli18n_server.erl:1039-1047`; `erli18n_plural.erl:217-230` | divergência recompila o header (2ª vez) + regra CLDR por carga | ✅ |
| 18 | ⚪ Info | robustez | `narrow-posix-unknown-atom-converts-file-error-to-crash` | `erli18n_server.erl:637-641` | `narrow_posix/1` catch-all transforma erro de arquivo em crash (latente) | — |
| 19 | ⚪ Info | correção | `charset-legacy-encodings-hard-rejected` | `erli18n_po.erl:338-349` | rejeita windows-1252/iso-8859-15/koi8-r/euc-* que o `msgfmt` aceita | ✅ |

> **Lead refutado (não é defeito):** `plural-precedence-associativity-matches-c` — a precedência/associatividade e o curto-circuito de `&&`/`||` do parser de plural **batem com C** (`erli18n_plural.erl:385-541,681-714`). Verificado e descartado.

---

## Achados detalhados e soluções estruturais

### 1. 🔴 `evaluate/2` derruba o chamador por lookup (crash-DoS por requisição)

**Local:** `src/erli18n_plural.erl:164-174` (`evaluate/2`, spec mente: declara `non_neg_integer()` mas chama `erlang:error` em :173), `:704-714` (`apply_binop` usa `div`/`rem` sem guard de zero); `src/erli18n_server.erl:201-217` (`lookup_plural_form/5` chama `evaluate/2` em :213, no processo do chamador, sem try/catch); `src/erli18n.erl:202-224` (`ngettext/5`) e `:340-361` (`npgettext/6`), specadas `-> translation()` sem try/catch.

**O que / por quê.** `compile/1` aceita regras cuja avaliação é insegura e retorna `{ok,_}`, então o catálogo **carrega** (`{ok,1}`). Três modos de falha, todos no caminho quente:
- **(a) divisão/módulo por zero:** `apply_binop/3` faz `L div R` / `L rem R` sem guard → `n/0`, `n%0`, `n/(n-n)`, `n/(n-5)` (em N=5) levantam `badarith`.
- **(b) forma fora de faixa:** `evaluate/2` chama `erlang:error({plural_form_out_of_range, Form, NPlurals})` quando `Form < 0` ou `>= nplurals` — alcançável com `plural=5`, `plural=n` (N≥2), `plural=n-1` (N=0 → −1), `plural=n%3` com N negativo (`rem` preserva o sinal do dividendo: `-7 rem 3 = -1`).
- **(c) o contrato mente:** o `-spec` declara totalidade e nunca declara o throw, escondendo o defeito do eqwalizer/dialyzer e de quem consome a API.

**Gatilho.** Inquilino fornece `.po` com `Plural-Forms: nplurals=2; plural=n/0;` (ou variantes). `ensure_loaded` → `{ok,1}`; o próximo `ngettext`/`npgettext` daquele `(domínio,locale)` **crasha o processo da requisição**. Persistente, por requisição. O fuzz F7 (invariância do pid do server) não detecta porque o que morre é o processo *chamador*, não o server. **Viola `SECURITY.md`.**

> ⚠️ Os testes atuais **chancelam o bug**: `form_out_of_range_crashes` (`test/erli18n_plural_SUITE.erl:536-542`) e o property test (`erli18n_plural_props.erl:107-109` tratam `badarith` como PASS; `:219-228` omitem `/` e `%` do pool de operadores).

**Solução estrutural.** Tornar `evaluate/2` uma função **total** cujo retorno é honestamente `non_neg_integer()` em todo o domínio — exatamente o contrato do runtime de referência (GNU libintl), que **não crasha e não cai no msgid**, e sim faz *clamp* para a forma 0:

```c
/* glibc intl/dcigettext.c — plural_lookup */
index = plural_eval (domaindata->plural, n);
if (index >= domaindata->nplurals)
  index = 0;   /* "This should never happen" -> clamp, NÃO crash */
```

Quatro camadas, cada uma independentemente suficiente para parar o crash:

1. **Avaliador total (a correção de raiz).** `eval_div/2` e `eval_rem/2` tratam divisor zero como UB-de-C coagido a valor definido (retorna 0), e o `erlang:error` do clamp vira o `index = 0` do libintl. `evaluate/2` passa a retornar provadamente `[0, NPlurals-1]` para todo N e qualquer AST — o `-spec` vira verdadeiro.
2. **API estruturada e honesta.** Mantém `evaluate/2` total (caminho quente sem exceção/alocação) e adiciona `evaluate_checked/2 -> {ok, non_neg_integer()} | {error, plural_eval_error()}` para quem quiser *observar* a anomalia como dado.
3. **Rejeição estática no load.** `validate_safe/1` na pipeline do `compile/1`: interpretação abstrata do AST rejeita o que é estaticamente garantido a falhar (`n/0`, `n%0`, constante `>= nplurals`) com `{error, {unsafe_plural_rule, Reason}}` — o catálogo envenenado é **recusado no `ensure_loaded`** em vez de carregar `{ok,1}`. A Camada 1 cobre os casos dinâmicos.
4. **Cinto-e-suspensório no boundary.** Envolver a chamada de `evaluate/2` em `lookup_plural_form/5` num `try ... catch error:_ -> fallback_form_index(N) end`. Com a Camada 1 nunca dispara, mas converte qualquer regressão futura num *degrade* gracioso para a forma Germânica padrão.

```erlang
%% src/erli18n_plural.erl
-export([compile/1, evaluate/2, evaluate_checked/2, plural_by_po_header/2,
         cldr_rule/1, validate_against_cldr/2, fallback_rule/0]).
-export_type([plural_compiled/0, compile_error/0, plural_eval_error/0, ast/0, op/0]).

-type compile_error() ::
      {syntax_error, term(), non_neg_integer()}
    | {missing_nplurals, binary()} | {missing_plural_expr, binary()}
    | {nplurals_out_of_range, integer()}
    | {unsafe_plural_rule, plural_eval_error()}.            %% NOVO
-type plural_eval_error() ::
      {division_by_zero, Op :: '/' | '%'}
    | {form_out_of_range, Form :: integer(), NPlurals :: pos_integer()}.

%% LAYER 1 — avaliador total (spec agora é VERDADEIRO p/ todo o domínio)
-spec evaluate(plural_compiled(), integer()) -> non_neg_integer().
evaluate(#{nplurals := NPlurals, expr := Ast}, N) when is_integer(N) ->
    Form = to_integer(eval_ast(Ast, N)),
    if Form < 0          -> 0;
       Form >= NPlurals  -> 0;          %% clamp à la libintl, NÃO crash
       true              -> Form
    end.

apply_binop('/', L, R) -> eval_div(L, R);
apply_binop('%', L, R) -> eval_rem(L, R);
%% ... demais ops inalterados
eval_div(_L, 0) -> 0;  eval_div(L, R) -> L div R.
eval_rem(_L, 0) -> 0;  eval_rem(L, R) -> L rem R.
```

```erlang
%% src/erli18n_server.erl — LAYER 4 (boundary guard)
{ok, #{plural := Compiled}} ->
    Index = try erli18n_plural:evaluate(Compiled, N)
            catch error:_ -> fallback_form_index(N) end,
    lookup_plural(Domain, Locale, Context, Msgid, Index);
```

**Fontes.**
- GNU libintl `dcigettext.c` (`plural_lookup`): clamp de índice fora de faixa para 0 — paridade de runtime, não workaround.
- <https://www.gnu.org/software/gettext/manual/html_node/Plural-forms.html> — semântica do campo `plural=`.
- <https://www.erlang.org/doc/system/expressions.html> — `div`/`rem` por zero levantam `badarith`.
- <https://cldr.unicode.org/index/cldr-spec/plural-rules> — categoria `other` é o catch-all garantido.

**Trade-offs.** Clamp para forma 0 esconde regra malformada (mas ainda cai em `msgid_plural` na ausência da entrada — PSD-003, mais seguro que o libintl). A Camada 3 fail-closed pode recusar regras exóticas mas estaticamente-faltosas; é o comportamento desejado.

**Teste (PropEr).** Inverter `form_out_of_range_crashes` para asserir `non_neg_integer()` em vez de crash; **incluir `/` e `%` no pool de operadores** em `erli18n_plural_props.erl:219-228`; property: `?FORALL({Rule, N}, {gerador de regras adversariais, integer()}, is_integer(evaluate(compile(Rule), N)) e está em [0,nplurals))`. Fuzz: gerar headers com `/0`, `%0`, constantes grandes e asserir que `ngettext` **nunca** crasha o processo.

---

### 2. 🔴 Compile de `Plural-Forms` é O(n²) e ilimitado

**Local:** `src/erli18n_plural.erl:580-587` (`skip_ws_st/1`, o termo quadrático), `:368-574` (parser recursivo sem limite de profundidade), `:338-349` (`take_until_semicolon_or_end`, sem limite de tamanho), `:606-610` (`advance/2`). Roda dentro de `erli18n_server.erl:1022-1028` (`maybe_compile_plural` → `compile/1`), dentro do `handle_call`.

**O que / por quê.** O parser não tem limite de profundidade nem de tamanho (`NPLURALS_MAX` limita a *contagem* de formas, não o tamanho da expressão), e contém um termo quadrático decisivo: `skip_ws_st/1` faz `case skip_ws(Src) of Src -> St; ... end`. Sem whitespace à esquerda, `skip_ws/1` retorna um sub-binário estruturalmente-igual-mas-não-idêntico, forçando um `=:=` byte-a-byte de **toda a entrada restante** a cada token → **O(n²)**. Isolamento de causa provou que o termo quadrático é *exclusivamente* esse `=:=`: trocá-lo por `byte_size(Rest) =:= byte_size(Src)` derruba o compile de 400 KB de **1063 ms → 19 ms**.

**Evidência (ao vivo).** `n+n+...+n` ou `((((n))))`: 50 K → 163 ms, 100 K → 691 ms, 200 K → 2,9 s, 250 K (~500 KB) → 7,5 s, 500 K → 73 s. Como `compile/1` roda **síncrono dentro do `handle_call`** do único gen_server (tabela `protected`), um `.po` de ~390 KB **congela o server inteiro** por ~2,3 s — toda outra carga/reload/unload fica em head-of-line blocking (vítima trivial mediu 2741–2793 ms bloqueada). A ≥210 K (~420 KB) o compile excede o **timeout padrão de 5000 ms**: o `ensure_loaded` do atacante crasha com `{timeout,{gen_server,call,_}}` **e** uma chamada-sonda não relacionada estoura em 5001 ms — DoS global.

**Gatilho.** `Plural-Forms: nplurals=2; plural=` seguido de centenas de KB de expressão válida-mas-trivial. `nplurals` fica em faixa → sem rejeição precoce.

**Solução estrutural.** Três partes em `erli18n_plural.erl` (sem mudança de caller/API):
1. **Whitespace O(1):** trocar o `=:=` de binário inteiro em `skip_ws_st/1` por `byte_size`. `skip_ws/1` só remove prefixo, então `byte_size` igual ⇒ inalterado — exato, colapsa o termo O(n²) para O(n).
2. **Limite de tamanho** na entrada do parser (`?PLURAL_EXPR_MAX_BYTES = 2048`; Árabe, a regra real mais complexa, tem ~98 bytes) → `{error,{expr_too_long, Size, Max}}`.
3. **Limite de profundidade:** propagar `Depth` na descida recursiva, rejeitar `> ?PLURAL_EXPR_MAX_DEPTH = 64` → `{error,{expr_too_deep, Depth, Pos}}`. Isso também limita a recursão de `eval_ast/2` (crescimento de stack no caminho quente).

```erlang
%% (1) o conserto decisivo — O(n^2) -> O(n)
skip_ws_st(#ps{src = Src, pos = Pos} = St) ->
    Rest = skip_ws(Src),
    case byte_size(Rest) =:= byte_size(Src) of
        true  -> St;                              %% nada removido
        false -> Consumed = byte_size(Src) - byte_size(Rest),
                 St#ps{src = Rest, pos = Pos + Consumed}
    end.

-define(PLURAL_EXPR_MAX_BYTES, 2048).
-define(PLURAL_EXPR_MAX_DEPTH, 64).

parse_expr_bin(ExprBin) when byte_size(ExprBin) > ?PLURAL_EXPR_MAX_BYTES ->
    {error, {expr_too_long, byte_size(ExprBin), ?PLURAL_EXPR_MAX_BYTES}};
parse_expr_bin(ExprBin) ->
    try {Ast, St} = parse_expr(#ps{src = ExprBin}, 0), ...
    catch
        throw:{syntax_error, R, P}  -> {error, {syntax_error, R, P}};
        throw:{expr_too_deep, D, P} -> {error, {expr_too_deep, D, P}}
    end.

parse_expr(St, Depth) when Depth > ?PLURAL_EXPR_MAX_DEPTH ->
    throw({expr_too_deep, Depth, St#ps.pos});
parse_expr(St, Depth) -> parse_ternary(St, Depth).   %% Depth propagado em todas as cláusulas
```

**Fontes.**
- <https://www.erlang.org/doc/efficiency_guide/commoncaveats.html> — `byte_size/1` é O(1).
- <https://www.erlang.org/doc/system/expressions.html> — *"Bit strings are compared bit by bit"* (o `=:=` é proporcional ao tamanho).
- <https://www.gnu.org/software/gettext/manual/html_node/Plural-forms.html> / <https://cldr.unicode.org/index/cldr-spec/plural-rules> — regra real mais complexa (Árabe) ~98 bytes, justificando os caps.

**Trade-offs.** Caps de 2048 B / 64 níveis são ~20×/~10× a regra real mais complexa; nenhum catálogo legítimo é afetado; rejeição é `{error, compile_error()}` fail-closed via `ensure_result()`, não crash.

**Teste.** Corrigir o gerador subdimensionado (`erli18n_plural_props.erl:190-191`, profundidade ≤4 chancela o gap). `prop_compile_bounded/0`: headers patológicos diretos (`n+n+...` até 1 MB, `((((n))))`, `!!!!...n`) → asserir `compile/1` sempre retorna dentro de orçamento de tempo (`timer:tc < 50 ms`) com `{ok,_}` ou `{error, {expr_too_*,_}}`.

---

### 3. 🔴 Decode de string PO é O(n²) (`bins_to_binary` append à direita)

**Local:** `src/erli18n_po.erl:258-266` (`bins_to_binary/2` faz `<<B/binary, Acc/binary>>` — *prepend*, recopia o acumulador a cada elemento), consumido por `decode_chars/2` (`:888-907`, lista revertida de binários de 1 byte), `consume_continuations/2` (`:237-251`) e `escape_string/2` (`:1039-1053`).

**O que / por quê.** `<<B/binary, Acc/binary>>` é *prepend*: o acumulador fica à **direita**. A otimização de crescimento *in-place* do runtime só vale para **append** (`<<Acc/binary, B/binary>>`, acumulador à esquerda, referência única). Com o acumulador à direita o runtime copia todo o `Acc` a cada iteração → **Θ(n²)** para montar uma string de n bytes. O comentário em `:253-257` alega equivalência a `iolist_to_binary(lists:reverse(Bins))` — verdade para o **resultado**, falso para o **custo** (`iolist_to_binary/1` é Θ(total), uma passada, uma alocação).

**Evidência (ao vivo, OTP 28).** prepend-fold: 5,75 ms @ 10 K → 658 ms @ 200 K (≈5× tempo p/ 2× input — quadrático clássico); `iolist_to_binary(lists:reverse/1)`: 0,1 ms → 3,7 ms (linear). End-to-end: msgid 100 KB → ~1 s, 200 KB → ~3,2 s, 400 KB → ~8–9,9 s, 800 KB → ~19–26 s. Como `parse/2` roda síncrono no `handle_call`, uma string grande trava o server compartilhado para todos os inquilinos.

> Nota: `append_to_last/2` (`:516-547`) usa `<<Prev/binary, Bin/binary>>` (acumulador à **esquerda**) — está **correto/O(total)**, **deve permanecer**.

**Solução estrutural.** (1) Materialização linear: substituir o fold por `iolist_to_binary(lists:reverse(Bins))` (o `-spec [binary()] -> binary()` é preservado — `[binary()]` é subtipo de `iolist()`). Corrige os 4 caminhos de uma vez. (2) Limite por string (defesa em profundidade): `max_string_bytes => pos_integer() | infinity` (default `infinity`), checado incrementalmente em `decode_chars/2` (fail-fast O(limit)) → `{string_too_long, Line, Limit}` estruturado.

```erlang
-spec bins_to_binary([binary()]) -> binary().
bins_to_binary(Bins) when is_list(Bins) ->
    iolist_to_binary(lists:reverse(Bins)).   %% Θ(total): 1 passada, 1 alocação

%% bound incremental (fail-fast antes de materializar)
decode_chars(<<C/utf8, Rest/binary>>, Acc, N, Limit) ->
    Char = <<C/utf8>>, N2 = N + byte_size(Char),
    case over_limit(N2, Limit) of
        true  -> {error, string_too_long};
        false -> decode_chars(Rest, [Char | Acc], N2, Limit)
    end;
over_limit(_N, infinity) -> false;
over_limit(N, Limit)     -> N > Limit.
```

**Fontes.**
- <https://www.erlang.org/doc/system/binaryhandling.html> — *"Constructing Binaries"*: só `<<Acc/binary, …>>` (acumulador à esquerda, ProcBin único) cresce in-place; prepend é explicitamente *"DO NOT"* (O(n²)).
- <https://www.erlang.org/doc/apps/erts/erlang.html#iolist_to_binary/1> — construção single-pass.
- <https://www.gnu.org/software/gettext/manual/html_node/PO-Files.html> — concatenação de strings adjacentes; sem máximo documentado (por isso o bound default é `infinity`).

**Trade-offs.** `iolist_to_binary` faz 2 passadas lineares (reverse + BIF) vs 1 quadrática — estritamente melhor acima de poucas dezenas de bytes. `max_string_bytes` default `infinity` = comportamento idêntico salvo opt-in.

**Teste.** `erli18n_po_fuzz.erl:prop_extreme_inputs` (`giant_msgid`, hoje só 100 KB + `no_crash` → chancela o bug): subir p/ 400 KB–1 MB e asserir orçamento linear (`timer:tc`). Nova property `prop_decode_is_linear/0`: custo por byte limitado ao longo da faixa. Round-trip `parse(dump(...)) == ...` para garantir equivalência byte-a-byte.

---

### 4. 🔴 `reload` não-atômico: destrói o catálogo bom e deixa janela vazia

**Local:** `src/erli18n_server.erl:818-847` (`handle_call({reload,...})` chama `do_unload` em :838 incondicionalmente, **depois** `do_load` em :839), `:883-921` (`do_load`: read+parse+compile), `:1138-1161` (`do_unload`).

**O que / por quê.** O `reload` **deleta o catálogo antes** de tentar recarregar, sem rollback. Dois defeitos de uma única ordenação invertida:
- **(1) Sem rollback no erro:** se qualquer passo falível de `do_load` falha (`{file_error,enoent}`, `{unsupported_charset,_}`, `{plural_compile_error,_}`, parse_error), `reload` retorna `{error,_}` mas o catálogo bom **já se foi**. Todo `gettext`/`ngettext` daquele `(domínio,locale)` degrada para o msgid cru. Pior que `ensure_loaded`, que é genuinamente atômico (erros antes de qualquer mutação ETS).
- **(2) Janela vazia no sucesso:** mesmo com sucesso, o catálogo fica **ausente** durante todo `read_file + parse + compile`.

**Evidência (ao vivo).** Catálogo `fr` bom (`Hello→Bonjour`) recarregado com `.po` malformado → `{error,_}` e depois `gettext` retorna `<<"Hello">>`, header `undefined`. Reload de ~6,5 MB: **1673 ms** durante os quais um leitor concorrente viu **~89% de misses** (329076/370726 lookups retornaram o msgid).

**Solução estrutural — STAGE → ATOMIC-SWAP (insert-before-prune).** Nunca deletar antes de ter substituição validada; a única transição observável é um `ets:insert/2` atômico:
- **A. Stage primeiro, mutar por último:** rodar todo o pipeline falível (`read_file`, `parse`, `compile`, `compute_divergence`) produzindo um registro `staged()` em memória **sem tocar o ETS**. Só com `{ok, Staged}` muta. Erro ⇒ ETS provadamente intacto (igual ao `ensure_loaded`).
- **B. Insert-before-prune (zero janela):** (1) `ets:insert` de todas as linhas novas — *"atomic and isolated, even when a list of objects is inserted"*: toda chave presente em ambos os catálogos vira velho→novo sem estado intermediário observável (zero miss); (2) `ets:insert` do header; (3) `ets:delete` **apenas** das chaves *stale* (presentes no antigo, ausentes no novo). Chaves retidas nunca são deletadas → leitor concorrente vê velho-depois-novo sem gap.
- **C. (Recomendado, ortogonal) Mover o trabalho pesado para fora da seção serializada** (ver Achado 6): `staged()` é função pura de `(PoPath, Opts)` → pode rodar no processo chamador; o gen_server faz só os inserts pequenos.

> *Deliberadamente evita chaves com geração / tabela de indireção:* o caminho quente singular faz **um** `ets:lookup` direto sem ler header; geração forçaria um 2º lookup no caminho mais quente. Insert-before-prune dá a mesma garantia de zero-janela sem tocar o caminho lock-free.

```erlang
-type staged() :: #{objects := [tuple()], header := header_state(),
                    new_keys := sets:set(tuple()), num_entries := non_neg_integer()}.

handle_call({reload, D, L, PoPath, Opts}, _From, State) ->
    Reply = erli18n_telemetry:span(erli18n_telemetry:event_catalog_reload(), StartMeta,
        fun() ->
            Inner = case stage_catalog(D, L, PoPath, Opts) of
                        {error, _} = E -> E;             %% catálogo anterior INTACTO
                        {ok, Staged}   -> swap_catalog(D, L, Staged)
                    end,
            {Inner, maps:merge(StartMeta, load_stop_metadata(Inner))}
        end),
    {reply, Reply, State}.

swap_catalog(Domain, Locale, #{objects := Objects, header := H,
                               new_keys := NewKeys, num_entries := N}) ->
    OldKeys = catalog_keys(Domain, Locale),                 %% scan ANTES de mutar
    case Objects of [] -> true; [_|_] -> true = ets:insert(?ETS_TABLE, Objects) end,
    true = ets:insert(?ETS_TABLE, {?HEADER_KEY(Domain, Locale), H}),
    Stale = sets:subtract(OldKeys, NewKeys),                %% poda só o obsoleto
    sets:fold(fun(K, _) -> ets:delete(?ETS_TABLE, K), ok end, ok, Stale),
    {ok, N}.
```

**Fontes.**
- <https://www.erlang.org/doc/apps/stdlib/ets.html> — `ets:insert/2`: *"The entire operation is guaranteed to be atomic and isolated, even when a list of objects is inserted"* (linchpin do passo B.1); travessias (`select_delete`) **não** são isoladas → por isso insert-before-prune e não delete-then-insert.
- <https://www.erlang.org/doc/apps/erts/persistent_term.html> — `put/2` dispara GC global: por isso o ponteiro de geração foi rejeitado.

**Trade-offs.** Custo do `catalog_keys/2` (scan da tabela por causa de `set` — ver Achado 13), pago uma vez fora do caminho de zero-miss e ofuscado pelo parse que substitui. Memória transitória dobra (linhas velhas+novas) durante o swap — memória por correção. Chaves stale servem a tradução **antiga** por microssegundos (gettext-consistente, melhor que miss→msgid).

**Teste.** `reload_failure_preserves_catalog/1` (espelha `atomicidade_load_fails`): reload com `.po` malformado / path ausente / charset não suportado → `{error,_}` **e** `lookup_singular` ainda dá `{ok,<<"Bonjour">>}`. `reload_no_empty_window/1`: N leitores martelando uma chave presente em ambos enquanto recarrega → **zero** misses. Reescrever a docstring `:411-415` que chancela o bug.

---

### 5. 🔴 `Content-Type` malformado → `badmatch` derruba o gen_server

**Local:** `src/erli18n_po.erl:662` (`{ok,Charset}=` não-exaustivo), `:676-686` (`parse_header_line` faz `split` no 1º `:` e *trim* da chave), `:289` (o prepass exige o literal `content-type:`).

**O que / por quê.** Dois caminhos de detecção de charset **discordam** em headers adversariais:
- **Path A (prepass)** `find_charset_line/1` exige o substring literal `content-type:` — **nenhum** espaço antes do `:`. `Content-Type : text/plain; charset=Shift_JIS` não casa → cai no default `{ok,utf8}` e segue.
- **Path B (`build_header`)** `parse_header_line/1` faz split no 1º `:` e **trima** a chave → `content-type` com value `text/plain; charset=Shift_JIS` → `classify_charset_from_content_type` retorna `{error,{unsupported_charset,<<"Shift_JIS">>}}`.

Esse erro bate no `{ok,Charset} =` não-exaustivo em `:662` → **`badmatch`**. Como `parse` roda no `handle_call` (e o span de telemetry não captura), o **gen_server termina**; o supervisor reinicia (perdendo todos os catálogos — ver Achado 10) e o chamador recebe um `{'EXIT',{{badmatch,...}}}` cru em vez do `ensure_result()` documentado. Fuzz de 200 K achou **83** fragmentos de `Content-Type` que crasham.

> A manchete original *"colon extra é descartado"* foi **refutada** (`binary:split` mantém resultado de 2 elementos; valores multi-colon como `Project-Id-Version` sobrevivem). O defeito real é o `badmatch` + divergência de caminhos.

**Solução estrutural.** Duas partes acopladas:
- **Parte 1 — fonte única de verdade.** Deletar o matcher bespoke (`find_charset/1`, `find_charset_line/1`, `:277-306`) e fazer o prepass derivar o charset da **mesma** lista de campos normalizada que `build_header/1` usa: `charset_from_header/1` chama `parse_header_fields/1` + um `field_charset/1` compartilhado. Dois callers, um classificador, uma política de whitespace → **não há input em que os dois discordem**. Conformidade RFC 2045/822 (LWSP; matching case-insensitive).
- **Parte 2 — tornar o site total.** Substituir o `{ok,Charset} =` por um `case` total que retorna `{error, parse_error()}`; `build_header/1` passa a poder retornar `{error,_}` e `finalize_entry/2` propaga.

```erlang
%% Parte 1 — um único reconhecedor de campos, tolerante a whitespace
charset_from_header(HeaderText) ->
    field_charset(parse_header_fields(HeaderText)).

-spec field_charset([{binary(), binary()}]) -> {ok, charset()} | {error, parse_error()}.
field_charset(Fields) ->
    classify_charset_from_content_type(
        proplists:get_value(<<"content-type">>, Fields, <<>>)).

%% Parte 2 — site total (sem badmatch)
build_header(HeaderText) when is_binary(HeaderText) ->
    Fields = parse_header_fields(HeaderText),
    case field_charset(Fields) of
        {ok, Charset}  -> {ok, #{plural_forms => ..., charset => Charset, raw => HeaderText, ...}};
        {error, _} = E -> E
    end.
```

**Fontes.**
- <https://datatracker.ietf.org/doc/html/rfc2045> — campos MIME estruturados seguem LWSP do RFC 822; matching de atributos *sempre* case-insensitive (o matcher literal violava ambos).
- <https://www.erlang.org/doc/apps/stdlib/gen_server.html> — exceção não capturada no `handle_call` termina o server.

**Trade-offs.** Unificar os dois caminhos remove ~30 LOC e fecha a classe inteira. `build_header/1` passa a poder retornar erro — propagação mínima em `finalize_entry`.

**Teste.** Fuzz dirigido aos 83 fragmentos: cada um → `{error, {unsupported_charset,_}}` estruturado (nunca `badmatch`/EXIT). Property: prepass e `build_header` produzem o **mesmo** charset para qualquer header gerado (gerador de variações de whitespace/colon).

---

### 6. 🟠 Pipeline de carga inteiro dentro do gen_server, sem bounds/timeout/bulk

**Local:** `src/erli18n_server.erl`

- `handle_call({ensure_loaded, ...}, _From, State)` — `:778`–`:817` (executa todo o pipeline dentro do callback; idempotência via `lookup_header/2` em `:798`, depois `do_load/4` em `:808`).
- `handle_call({reload, ...}, _From, State)` — `:818`–`:847` (`do_unload/2` em `:838` seguido de `do_load/4` em `:839`, ambos dentro do callback).
- `do_load/4` — `:883`–`:921`: `file:read_file(PoPath)` em `:885` (I/O de disco bloqueante, **sem cap de tamanho**), `erli18n_po:parse/2` em `:889` (parse completo de bytes não confiáveis), e o segundo parse opcional em `:942` dentro de `maybe_emit_fuzzy_skip/5`.
- `install_parsed/5` — `:968`–`:1007`: `maybe_compile_plural/1` em `:975`, `insert_entries/3` em `:994`, `ets:insert/2` do header em `:995`, e `memory_info()` em `:1005` (que faz `ets:tab2list/1` — varredura da tabela inteira, ver achado #5).
- `opts()` — `:66`: `#{include_fuzzy => boolean()}` — **único** parâmetro exposto; não há cap de tamanho/entradas nem timeout.
- API pública `ensure_loaded/4` (`:399`–`:409`) e `reload/4` (`:420`–`:430`): ambas usam `gen_server:call/2` com o **timeout implícito de 5000 ms** e não oferecem override.

**Causa-raiz:** O servidor é um único processo nomeado (`?MODULE`, registrado em `:117`) dono de uma tabela ETS `protected` (`init/1`, `:725`–`:733`). Por `protected`, **só o processo dono escreve** — então o autor colocou *todo* o pipeline de escrita dentro de `handle_call`. Mas o pipeline mistura duas classes de trabalho radicalmente diferentes:

1. **Trabalho pesado e puro, que NÃO precisa do dono** — `file:read_file/1` (I/O bloqueante, sem cap), `erli18n_po:parse/2` (parse de bytes não confiáveis, dois passes de `split_lines`), `erli18n_plural:compile/1`, e a validação CLDR. Nada disso toca a ETS; tudo poderia rodar no processo chamador.
2. **Trabalho mutante mínimo, que SÓ o dono pode fazer** — os dois `ets:insert/2` (entries + header) — atômicos por linha e baratos.

Ao serializar (1)+(2) dentro do mailbox único, qualquer `.po` grande/lento/patológico de um tenant **bloqueia todos** os outros `ensure_loaded`/`reload`/`unload`, e o `gen_server:call/2` de 5 s faz o chamador *crashar* enquanto o servidor continua e pode inserir o catálogo depois (escrita órfã). É exatamente o anti-padrão "mova trabalho para o cliente" que os guias OTP/Efficiency alertam: o servidor deveria serializar apenas as pequenas escritas mutantes.

**Evidência (reprodução ao vivo, OTP 28 / ERTS 16.3.1, este repositório compilado):**

1. **Head-of-line blocking entre tenants.** Tenant A carrega um `.po` de **13 MB / 40 000 entradas** (`heavy`,`pt_BR`); 20 ms depois, Tenant B carrega um `.po` **trivial de 1 entrada** (`light`,`en`). Os dois `ensure_loaded` independentes terminam quase juntos:
   ```
   big.po size = 13217852 bytes
   heavy_done: wall=2909ms result={ok,40000}
   light_done: wall=2891ms result={ok,1}     %% trivial bloqueado ~2.9 s atrás de A
   ```
   A carga de 1 entrada — que deveria levar microssegundos — esperou **2891 ms** na fila do mailbox.

2. **Timeout de 5 s no chamador, sem override.** Um `.po` de **36 MB / 95 000 entradas** faz o chamador crashar exatamente no deadline implícito, e o servidor **insere o catálogo depois** (escrita órfã):
   ```
   mid.po size = 36172852 bytes
   caller result after 5007ms: {caller_crash,timeout}        %% {timeout,{gen_server,call,_}}
   ORPHANED WRITE LANDED: catalog inserted though caller already crashed at 5002ms
   ```
   O chamador vê erro, mas o catálogo está silenciosamente presente — falha parcial confusa, impossível de corrigir via API (não há override de timeout).

3. **Decomposição do custo — a prova de que a correção é estrutural.** Para o mesmo catálogo de 13 MB / 40 000 entradas, medindo as fases separadamente:
   ```
   entries=40000  parse=2691.39ms  bulk_insert(server write)=26.30ms  ratio parse/insert=102.3x
   ```
   **~99% do tempo** em que o gen_server segura o mailbox é gasto em trabalho puro (read+parse+compile) que **não exige o dono**. A única fase que precisa do dono (o bulk insert) custa **26 ms**. Mover (1) para o chamador encolhe a seção crítica serializada em **~100×**.

4. **`public` ETS permite escrita pelo não-dono (OTP 28).** Confirmado que um processo que não é o dono pode `ets:insert/2` numa tabela `public`/`named_table` — base da variante opcional discutida em Trade-offs:
   ```
   non-owner insert into public table: true  lookup: [{k,v}]
   ```

**Solução estrutural:** Inverter a fronteira. O pipeline pesado (read+parse+compile+validate CLDR) roda no **processo chamador** (ou num worker dedicado, opt-in), produzindo um *payload validado e pronto para inserir*. O servidor passa a serializar apenas o **commit mínimo** (unload condicional + dois bulk inserts), preservando a invariante `protected`/RISK-012 (só o dono escreve), a atomicidade por catálogo e a API pública. Em cima disso, adicionam-se:

- **bounds em `opts()`**: `max_bytes` (cap de tamanho do arquivo *antes* de ler tudo, via `filelib:file_size/1`) e `max_entries` (cap pós-parse);
- **timeout tunável** em `opts()` (`timeout => non_neg_integer() | infinity`), usado num `gen_server:call/3` **só para o commit** (que agora é de milissegundos), eliminando a pressão do deadline de 5 s sobre a fase pesada;
- **API de bulk** `ensure_loaded_many/1`: N catálogos têm read+parse+compile feitos concorrentemente nos chamadores/workers, e os payloads prontos são entregues num **único** commit (um `ets:insert/2` em lote, um único `tab2list` para idempotência) — elimina N round-trips e N varreduras (interage com o achado #5).

O `do_load/4` deixa de existir dentro do servidor: vira `prepare_load/4` no lado do chamador. O `handle_call` do servidor só recebe `{commit, ...}` com dados já validados.

```erlang
%% ============================================================
%% NOVOS TIPOS PÚBLICOS (erli18n_server.erl, junto a opts()/:66)
%% ============================================================

%% `opts()` ganha bounds e timeout. Todos os campos são opcionais;
%% defaults preservam o comportamento atual (mas com cap de segurança).
-type opts() :: #{
    include_fuzzy => boolean(),
    %% Rejeita o arquivo ANTES de lê-lo inteiro se exceder o limite.
    %% `infinity` = sem cap (comportamento legado explícito).
    max_bytes => non_neg_integer() | infinity,
    %% Rejeita o catálogo APÓS o parse se tiver mais que N entradas.
    max_entries => non_neg_integer() | infinity,
    %% Timeout do commit (gen_server:call/3). Como o commit é só o
    %% bulk insert (medido em ~26 ms para 40k entradas), 5000 ms é
    %% folgado; expomos para deployments multi-tenant ajustarem.
    timeout => timeout()
}.

%% Payload pronto para inserir: produzido pela fase pesada (no chamador),
%% consumido pelo commit (no dono). É a fronteira do design — só isto
%% trafega pelo mailbox do servidor.
-type load_payload() :: #{
    entries := [catalog_entry()],
    header := header_state(),
    divergence := divergence_info(),
    %% Para a telemetria de fuzzy_skip, calculada no chamador.
    fuzzy_skipped := non_neg_integer()
}.

%% Erros novos introduzidos pelos bounds (subconjunto de ensure_error()).
-type bound_error() ::
    {input_too_large, Bytes :: non_neg_integer(), Limit :: non_neg_integer()}
    | {too_many_entries, Count :: non_neg_integer(), Limit :: non_neg_integer()}.

%% `ensure_error()` (:75) é estendido com `bound_error()`:
-type ensure_error() ::
    erli18n_po:parse_error()
    | {plural_compile_error, erli18n_plural:compile_error()}
    | {file_error, file:posix() | badarg | terminated | system_limit}
    | bound_error()
    | {load_failed, term()}.

%% ============================================================
%% API PÚBLICA — fase pesada no chamador, commit no servidor
%% ============================================================

-spec ensure_loaded(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
ensure_loaded(Domain, Locale, PoPath, Opts) when
    is_atom(Domain), is_binary(Locale), is_map(Opts)
->
    %% Span [erli18n, catalog, load] envolve a fase pesada NO CHAMADOR.
    %% telemetry:span/3 roda a closure no processo corrente, então a
    %% medição passa a ser por-tenant e fora do mailbox do servidor.
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    StartMeta = #{
        domain => Domain,
        locale => Locale,
        language => lc_messages,
        po_path => to_binary_path(PoPath),
        fuzzy_included => IncludeFuzzy
    },
    erli18n_telemetry:span(
        erli18n_telemetry:event_catalog_load(),
        StartMeta,
        fun() ->
            Inner = do_ensure_loaded(Domain, Locale, PoPath, Opts),
            {Inner, maps:merge(StartMeta, load_stop_metadata(Inner))}
        end
    ).

%% Fast-path idempotente (RISK-012 mitigação 2): lookup direto na ETS,
%% sem tocar no disco, sem ocupar o servidor.
-spec do_ensure_loaded(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
do_ensure_loaded(Domain, Locale, PoPath, Opts) ->
    case lookup_header(Domain, Locale) of
        {ok, _} ->
            {ok, already};
        undefined ->
            %% Fase pesada (read+parse+compile+validate) no chamador.
            case prepare_load(Domain, Locale, PoPath, Opts) of
                {error, _} = E ->
                    E;
                {ok, Payload} ->
                    %% Commit mínimo no servidor, com timeout tunável.
                    %% Modo `ensure`: o servidor re-checa idempotência sob
                    %% serialização (fecha a corrida check-then-insert).
                    commit_call({commit, ensure, Domain, Locale, Payload}, Opts)
            end
    end.

-spec reload(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
reload(Domain, Locale, PoPath, Opts) when
    is_atom(Domain), is_binary(Locale), is_map(Opts)
->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    StartMeta = #{
        domain => Domain,
        locale => Locale,
        language => lc_messages,
        po_path => to_binary_path(PoPath),
        fuzzy_included => IncludeFuzzy
    },
    erli18n_telemetry:span(
        erli18n_telemetry:event_catalog_reload(),
        StartMeta,
        fun() ->
            Inner =
                %% reload NÃO faz fast-path: sempre prepara e re-instala.
                case prepare_load(Domain, Locale, PoPath, Opts) of
                    {error, _} = E ->
                        E;
                    {ok, Payload} ->
                        %% Modo `reload`: o servidor faz unload+insert
                        %% ATÔMICOS sob a serialização (sem janela de
                        %% catálogo vazio visível a outros writers).
                        commit_call(
                            {commit, reload, Domain, Locale, Payload}, Opts
                        )
                end,
            {Inner, maps:merge(StartMeta, load_stop_metadata(Inner))}
        end
    ).

%% Envia o payload pronto ao dono e narra a resposta. O timeout do
%% commit é tunável; como o commit é só o bulk insert, o default de
%% 5000 ms é folgado e o override fecha o achado de timeout.
-spec commit_call(tuple(), opts()) -> ensure_result().
commit_call(Msg, Opts) ->
    Timeout = maps:get(timeout, Opts, 5000),
    narrow_ensure_result(gen_server:call(?MODULE, Msg, Timeout)).

%% ============================================================
%% FASE PESADA — roda NO CHAMADOR (antes era do_load/4 no servidor)
%% ============================================================

%% Bounds + read + parse + compile + validate CLDR. Nenhuma escrita ETS.
%% Ordem das falhas (todas ANTES de qualquer mutação, como antes):
%%   0. cap de tamanho (filelib:file_size/1 — não lê o arquivo)
%%   1. file:read_file/1        -> {file_error, Posix}
%%   2. erli18n_po:parse/2      -> parse_error()
%%   3. cap de entradas         -> {too_many_entries, _, _}
%%   4. compile plural          -> {plural_compile_error, _}
%%   5. validate CLDR           -> nunca falha (warning)
-spec prepare_load(domain(), locale(), file:filename(), opts()) ->
    {ok, load_payload()} | {error, ensure_error()}.
prepare_load(Domain, Locale, PoPath, Opts) ->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    MaxBytes = maps:get(max_bytes, Opts, default_max_bytes()),
    MaxEntries = maps:get(max_entries, Opts, default_max_entries()),
    case check_size(PoPath, MaxBytes) of
        {error, _} = SizeErr ->
            SizeErr;
        ok ->
            case file:read_file(PoPath) of
                {error, Posix} ->
                    {error, {file_error, Posix}};
                {ok, Bin} ->
                    prepare_parsed(
                        Domain, Locale, PoPath, IncludeFuzzy, MaxEntries, Bin
                    )
            end
    end.

%% Cap de tamanho aplicado ANTES de ler o arquivo inteiro na memória:
%% `filelib:file_size/1` faz um stat, não carrega bytes. Fecha a porta
%% para um .po de gigabytes estourar o heap só de ler.
-spec check_size(file:filename(), non_neg_integer() | infinity) ->
    ok | {error, bound_error()}.
check_size(_PoPath, infinity) ->
    ok;
check_size(PoPath, MaxBytes) when is_integer(MaxBytes) ->
    case filelib:file_size(PoPath) of
        Size when Size =< MaxBytes ->
            ok;
        Size ->
            {error, {input_too_large, Size, MaxBytes}}
    end.

-spec prepare_parsed(
    domain(),
    locale(),
    file:filename(),
    boolean(),
    non_neg_integer() | infinity,
    binary()
) -> {ok, load_payload()} | {error, ensure_error()}.
prepare_parsed(Domain, Locale, PoPath, IncludeFuzzy, MaxEntries, Bin) ->
    case erli18n_po:parse(Bin, #{include_fuzzy => IncludeFuzzy}) of
        {error, _} = E ->
            E;
        {ok, #{header := Header, entries := Entries}} ->
            NumEntries = length(Entries),
            case within_entry_cap(NumEntries, MaxEntries) of
                false ->
                    {error, {too_many_entries, NumEntries, MaxEntries}};
                true ->
                    build_payload(
                        Domain, Locale, PoPath, IncludeFuzzy,
                        Bin, Header, Entries, NumEntries
                    )
            end
    end.

-spec within_entry_cap(non_neg_integer(), non_neg_integer() | infinity) ->
    boolean().
within_entry_cap(_N, infinity) -> true;
within_entry_cap(N, Max) when is_integer(Max) -> N =< Max.

%% Monta o header_state() e o payload. O compile do plural e o cálculo de
%% divergência CLDR (antes em install_parsed/maybe_compile_plural) também
%% migram para cá — são puros e custosos, não precisam do dono.
-spec build_payload(
    domain(), locale(), file:filename(), boolean(),
    binary(), erli18n_po:header_map(), [catalog_entry()], non_neg_integer()
) -> {ok, load_payload()} | {error, ensure_error()}.
build_payload(Domain, Locale, PoPath, IncludeFuzzy,
              Bin, Header, Entries, NumEntries) ->
    case maybe_compile_plural(Header) of
        {error, CompileErr} ->
            {error, {plural_compile_error, CompileErr}};
        {ok, PluralCompiled} ->
            PluralRaw =
                case maps:get(plural_forms, Header, <<>>) of
                    <<>> -> erli18n_plural:fallback_rule();
                    Other -> Other
                end,
            Divergence = compute_divergence(Locale, Header),
            HeaderState = #{
                plural => PluralCompiled,
                plural_raw => PluralRaw,
                po_path => PoPath,
                loaded_at => erlang:system_time(millisecond),
                divergence => Divergence,
                fuzzy_included => IncludeFuzzy,
                num_entries => NumEntries
            },
            FuzzySkipped =
                compute_fuzzy_skipped(IncludeFuzzy, Bin, NumEntries),
            {ok, #{
                entries => Entries,
                header => HeaderState,
                divergence => Divergence,
                fuzzy_skipped => FuzzySkipped
            }}
    end.

%% Contagem de fuzzy descartados, calculada no chamador (era o re-parse
%% de :942). Só re-parseia quando o consumidor optou por telemetria de
%% lookup E o load default descartou fuzzy — idêntico ao gate original.
-spec compute_fuzzy_skipped(boolean(), binary(), non_neg_integer()) ->
    non_neg_integer().
compute_fuzzy_skipped(true = _IncludeFuzzy, _Bin, _DefaultCount) ->
    0;
compute_fuzzy_skipped(false, Bin, DefaultCount) ->
    case erli18n_telemetry:lookup_telemetry_enabled() of
        false ->
            0;
        true ->
            {ok, #{entries := AllEntries}} =
                erli18n_po:parse(Bin, #{include_fuzzy => true}),
            erlang:max(0, length(AllEntries) - DefaultCount)
    end.

%% ============================================================
%% COMMIT — única coisa que roda no dono. Seção crítica mínima.
%% ============================================================

%% O servidor agora só recebe payloads validados. `ensure` re-checa
%% idempotência sob serialização (fecha a corrida check-then-insert entre
%% dois chamadores concorrentes para o mesmo catálogo). `reload` faz
%% unload+insert atômicos. Tudo é ETS-set (atômico por linha) sob o
%% mailbox único -> nenhuma janela observável de estado misto.
handle_call({commit, Mode, Domain, Locale, Payload}, _From, State) ->
    Reply = do_commit(Mode, Domain, Locale, Payload),
    {reply, Reply, State};
%% Variante em lote: N payloads num único commit (um bulk insert, um
%% único tab2list para idempotência — ver achado #5).
handle_call({commit_many, Items}, _From, State) ->
    {reply, do_commit_many(Items), State};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec do_commit(ensure | reload, domain(), locale(), load_payload()) ->
    ensure_result().
do_commit(ensure, Domain, Locale, Payload) ->
    %% Re-checagem idempotente DENTRO da serialização: se outro chamador
    %% instalou o catálogo enquanto preparávamos, não sobrescrevemos.
    case lookup_header(Domain, Locale) of
        {ok, _} -> {ok, already};
        undefined -> install_payload(Domain, Locale, Payload)
    end;
do_commit(reload, Domain, Locale, Payload) ->
    %% unload + insert serializados: outros writers não veem o gap
    %% (resolve a ressalva de atomicidade documentada em reload/3,4).
    do_unload(Domain, Locale),
    install_payload(Domain, Locale, Payload).

%% Instala um payload já validado: dois bulk inserts + efeitos colaterais
%% de observabilidade. Nenhuma operação que possa falhar (tudo já foi
%% validado na fase pesada) -> o commit é total e barato (~26 ms/40k).
-spec install_payload(domain(), locale(), load_payload()) ->
    {ok, non_neg_integer()}.
install_payload(Domain, Locale, #{
    entries := Entries,
    header := HeaderState,
    divergence := Divergence,
    fuzzy_skipped := FuzzySkipped
}) ->
    emit_divergence_log(Domain, Locale, Divergence),
    emit_divergence_telemetry(Domain, Locale, Divergence),
    maybe_emit_fuzzy_skip_count(Domain, Locale, FuzzySkipped),
    true = insert_entries(Domain, Locale, Entries),
    true = ets:insert(
        ?ETS_TABLE, {?HEADER_KEY(Domain, Locale), HeaderState}
    ),
    _ = erli18n_telemetry:memory_warning_check(memory_info()),
    {ok, length(Entries)}.

-spec maybe_emit_fuzzy_skip_count(domain(), locale(), non_neg_integer()) -> ok.
maybe_emit_fuzzy_skip_count(_Domain, _Locale, 0) ->
    ok;
maybe_emit_fuzzy_skip_count(Domain, Locale, Count) when Count > 0 ->
    erli18n_telemetry:emit(
        erli18n_telemetry:event_lookup_fuzzy_skip(),
        #{count => Count},
        #{domain => Domain, locale => Locale}
    ),
    ok.

%% ============================================================
%% API DE BULK — N catálogos, um commit
%% ============================================================

-type load_spec() :: {domain(), locale(), file:filename(), opts()}.

%% Carrega N catálogos: a fase pesada de cada um roda concorrentemente
%% (um worker efêmero por spec), e os payloads prontos são commitados num
%% único `commit_many` -> um bulk insert, um único tab2list. Catálogos já
%% carregados ou com erro são reportados individualmente; um erro num
%% catálogo NÃO bloqueia os demais.
-spec ensure_loaded_many([load_spec()]) ->
    [{domain(), locale(), ensure_result()}].
ensure_loaded_many(Specs) when is_list(Specs) ->
    %% Fan-out: prepara em paralelo, fora do servidor.
    Prepared =
        erli18n_par:pmap(
            fun({D, L, Path, Opts}) ->
                case lookup_header(D, L) of
                    {ok, _} ->
                        {D, L, {already}};
                    undefined ->
                        {D, L, {prepared, prepare_load(D, L, Path, Opts)}}
                end
            end,
            Specs
        ),
    %% Separa os que precisam de commit dos que já resolveram.
    {ToCommit, Resolved} = partition_prepared(Prepared),
    Committed =
        case ToCommit of
            [] -> [];
            [_ | _] -> gen_server:call(?MODULE, {commit_many, ToCommit})
        end,
    Resolved ++ Committed.

-spec partition_prepared([term()]) ->
    {[{domain(), locale(), load_payload()}],
     [{domain(), locale(), ensure_result()}]}.
partition_prepared(Prepared) ->
    lists:foldr(
        fun
            ({D, L, {already}}, {Commit, Done}) ->
                {Commit, [{D, L, {ok, already}} | Done]};
            ({D, L, {prepared, {ok, Payload}}}, {Commit, Done}) ->
                {[{D, L, Payload} | Commit], Done};
            ({D, L, {prepared, {error, _} = Err}}, {Commit, Done}) ->
                {Commit, [{D, L, Err} | Done]}
        end,
        {[], []},
        Prepared
    ).

%% Commit em lote: re-checa idempotência sob serialização e instala todos
%% num bloco. Um único memory_warning_check ao final.
-spec do_commit_many([{domain(), locale(), load_payload()}]) ->
    [{domain(), locale(), ensure_result()}].
do_commit_many(Items) ->
    Results =
        [ begin
              R =
                  case lookup_header(D, L) of
                      {ok, _} -> {ok, already};
                      undefined -> install_payload_no_memcheck(D, L, P)
                  end,
              {D, L, R}
          end || {D, L, P} <- Items ],
    _ = erli18n_telemetry:memory_warning_check(memory_info()),
    Results.

%% Como install_payload/3, mas sem o memory_warning_check (deferido para
%% uma única chamada após o lote inteiro — não O(N) varreduras).
-spec install_payload_no_memcheck(domain(), locale(), load_payload()) ->
    {ok, non_neg_integer()}.
install_payload_no_memcheck(Domain, Locale, #{
    entries := Entries,
    header := HeaderState,
    divergence := Divergence,
    fuzzy_skipped := FuzzySkipped
}) ->
    emit_divergence_log(Domain, Locale, Divergence),
    emit_divergence_telemetry(Domain, Locale, Divergence),
    maybe_emit_fuzzy_skip_count(Domain, Locale, FuzzySkipped),
    true = insert_entries(Domain, Locale, Entries),
    true = ets:insert(
        ?ETS_TABLE, {?HEADER_KEY(Domain, Locale), HeaderState}
    ),
    {ok, length(Entries)}.

%% ============================================================
%% Defaults dos bounds (configuráveis via application env).
%% ============================================================

%% Cap de tamanho default: generoso o bastante para catálogos reais
%% (gettext "grande" raramente passa de poucos MB) mas finito por
%% segurança. application:get_env permite ajuste por deployment.
-spec default_max_bytes() -> non_neg_integer() | infinity.
default_max_bytes() ->
    application:get_env(erli18n, max_po_bytes, 16 * 1024 * 1024).

-spec default_max_entries() -> non_neg_integer() | infinity.
default_max_entries() ->
    application:get_env(erli18n, max_po_entries, 500000).
```

> Observação de eqwalizer: `commit_call/2` e `ensure_loaded_many/1` recebem `term()` de `gen_server:call`. O `narrow_ensure_result/1` existente (`:437`) já reclassifica respostas no boundary; o lote usa um narrowing análogo por item. `prepare_load/4` e `install_payload/3` têm specs fechados sobre `load_payload()` e `ensure_error()` — sem `dynamic_cast`. `erli18n_par:pmap/2` é um helper trivial (`spawn_monitor` + coleta ordenada); ver Trade-offs.

**Fontes:**

- https://www.erlang.org/doc/apps/stdlib/gen_server.html — `gen_server:call/2` ≡ `call(_, _, 5000)` (timeout default 5000 ms; no timeout o chamador *sai* com `Reason = timeout`); `gen_server:call/3` aceita `Timeout` inteiro ou `infinity`; `reply/2` + retorno `{noreply, State}` para resposta diferida; `handle_continue`/`{noreply, State, {continue, _}}`. Sustenta o timeout tunável e o modelo de seção crítica mínima.
- https://www.erlang.org/doc/apps/stdlib/ets.html — Definições de acesso: `protected` = "owner process can read and write; other processes can only read"; `public` = "any process can read or write". Sustenta por que o pipeline foi posto no dono e por que mover só o *commit* preserva a invariante `protected`/RISK-012 (e por que a variante `public` é possível).
- https://www.erlang.org/doc/system/efficiency_guide.html (Common Caveats) — custo de operações de lista/binário proporcional ao tamanho (ex.: `length/1` linear; `++` quadrático); o "timer server ... may at some point become a bottleneck" como exemplo canônico de processo único virando gargalo. Sustenta o argumento de complexidade e a decomposição parse(2691ms)/insert(26ms).
- https://learnyousomeerlang.com/clients-and-servers e https://erlangcentral.org/wiki/Building_Non_Blocking_Erlang_apps — padrão "guarde `From`, retorne `{noreply, State}`, responda depois com `gen_server:reply/2`" para não bloquear o servidor; "while the process waits ... all the requests from other ... processes will queue up". Sustenta a alternativa worker+deferred-reply nos Trade-offs.
- https://www.erlang.org/doc/apps/stdlib/supervisor.html — `simple_one_for_one` / `start_child/2` e `restart => transient|temporary` para workers efêmeros de vida curta. Sustenta a opção de pool de workers de preparo.
- https://www.gnu.org/software/gettext/manual/html_node/Plural-forms.html — `nplurals` decimal e a expressão `plural` em sintaxe C no header `Plural-Forms`. Paridade: os bounds/timeout não alteram a semântica de parsing nem de plural; só adicionam limites de recurso no boundary.
- https://cldr.unicode.org/index/cldr-spec/plural-rules — categorias plurais CLDR; `compute_divergence/2` (validação informativa) permanece intacta, só migra para a fase pesada. Paridade CLDR preservada.

**Trade-offs:**

- **API estendida (compatível).** `opts()` ganha campos *opcionais* (`max_bytes`, `max_entries`, `timeout`); chamadas existentes (`#{}`, `#{include_fuzzy => _}`) continuam válidas. `ensure_error()` ganha `bound_error()` — consumidores que faziam match exaustivo precisam de cláusulas novas (mas o `{load_failed, _}` catch-all já os protege). `ensure_loaded_many/1` é aditiva. Justifica-se: é a alavanca que ADR-0003 (multi-tenant) precisa no boundary e a única forma estrutural de dar timeout tunável.
- **Erro do chamador vs. erro do servidor.** Antes, um crash no parse rodava no servidor (e o F7 garante que não derruba a árvore). Agora roda no chamador — o que é *melhor* para isolamento (um `.po` patológico só afeta quem o submeteu), mas o chamador deve tratar exceções do parser. Mitigado: `prepare_load/4` já captura tudo como `{error, _}`; o parser de bytes não confiáveis é total por design (achados de fuzzing).
- **Dependência de `erli18n_par:pmap/2`.** A API de bulk precisa de um `pmap` (≈30 linhas, `spawn_monitor`+coleta). Alternativa sem novo módulo: usar `rpc:pmap/3` (stdlib) ou serializar o preparo no chamador (perde a concorrência do fan-out, mantém o commit único). Para v0.1 pode-se entregar `ensure_loaded_many/1` com preparo *sequencial* no chamador e só o commit em lote — ainda elimina N round-trips e N `tab2list`.
- **`protected` mantido (recomendado) vs `public` (alternativa).** Mantendo `protected`, o commit ainda serializa no dono — porém agora ele é de milissegundos (~26 ms/40k), então o head-of-line residual é ~100× menor e não causa timeout. A variante `public` (confirmada funcional: o não-dono insere direto) eliminaria *todo* round-trip de escrita, mas perde a serialização que garante atomicidade de `reload` e a re-checagem idempotente — exigiria locks por catálogo (ex.: `global`/`ets` CAS). Custo/benefício não compensa para o ganho marginal; ficamos com `protected` + commit mínimo.
- **Worker opt-in (variante).** Em vez de rodar o preparo *no* chamador, pode-se rodar num worker `transient` sob um `simple_one_for_one` e usar `{noreply, From}` + `gen_server:reply/2` no servidor. Vantagem: o chamador permanece responsivo e o servidor nunca segura `From`. Custo: mais máquinas de estado; só vale se o chamador não puder pagar o parse no próprio agendamento. Documentado como evolução; o design base (preparo no chamador) já remove o gargalo.

**Teste (PropEr):**

- **Teste atual que chancela o bug:** `test/erli18n_po_fuzz.erl:217` (`prop_end_to_end_no_supervisor_restart/0`, exposto via `erli18n_fuzz_SUITE:fuzz_end_to_end/1`). Ele faz `try erli18n:ensure_loaded(...) catch _:_ -> caught end` (`:235`–`:243`) — ou seja, **engole o crash `{timeout,{gen_server,call,_}}`** como resultado aceitável e só verifica que o pid do servidor e a contagem de filhos não mudaram (`:258`). A propriedade está *certa* sobre sobrevivência da árvore, mas **mascara** tanto o timeout do chamador quanto o head-of-line blocking, porque nunca mede latência nem concorrência. Deve ser *complementada* (não removida).
- **Nova propriedade — não-bloqueio entre tenants** (em `test/erli18n_lookup_props.erl` ou um novo `erli18n_loadpipe_props.erl`): `?FORALL({BigSpec, TrivialSpec}, {gen_big_po(), gen_trivial_po()}, ...)` que dispara o load grande e, com um head start mínimo, o trivial; assere que o tempo de parede do trivial fica **abaixo de um teto** (ex.: < 200 ms) — hoje falharia (~2900 ms), depois passa (o trivial não espera o parse do grande, pois o preparo é por-chamador e só o commit de ~26 ms serializa). Gera os tamanhos com `proper_types:pos_integer()` escalado.
- **Nova propriedade — bounds e ausência de timeout:** `?FORALL(Size, large_size(), ...)` que escreve um `.po` acima de `max_bytes` e assere `{error, {input_too_large, _, _}}` *sem* I/O de leitura completa; e um `.po` que demoraria >5 s preparado com `timeout => infinity` retorna `{ok, _}` em vez de crashar — fechando o achado de timeout de forma determinística.
- **Nova propriedade — paridade do commit:** `?FORALL(Po, gen_valid_po(), ...)` que assere que `ensure_loaded` (novo, commit) e a referência gettext (`gettexter`, já em deps de teste) produzem o **mesmo** conjunto de lookups (`erli18n_parity_SUITE`), garantindo que mover parse/compile para o chamador não muda byte algum da semântica.
- **Nova propriedade — bulk = N singles:** `?FORALL(Specs, list(gen_po_spec()), ...)` que assere `ensure_loaded_many(Specs)` produz exatamente os mesmos catálogos em ETS que aplicar `ensure_loaded/4` um a um, e que o nº de varreduras `tab2list` cai de N para 1 (instrumentável via contador de telemetria ou meck).
- **Reuso do harness de fuzz:** `erli18n_fuzz_SUITE` continua válido; adicionar um cenário F8 que injeta um `.po` patológico **e** mede que um load trivial concorrente termina dentro do teto — a versão "concorrência" do invariante de disponibilidade que o F7 só cobre para sobrevivência da árvore.

**Por que é estrutural:**

- **Muda a classe de complexidade da seção crítica serializada.** Antes, o tempo que o mailbox único fica bloqueado é `O(tamanho_do_arquivo + nº_entradas)` por load — medido em **~2700 ms para 13 MB**. Depois, o trabalho serializado é apenas o bulk insert, `O(nº_entradas)` mas com constante ~100× menor (**~26 ms**), e o termo pesado (parse/compile) sai do caminho serializado. O head-of-line blocking entre tenants cai de segundos para milissegundos — não é um ajuste de timeout, é a remoção do trabalho do ponto de serialização.
- **Remove a classe de crash do chamador.** O timeout de 5 s deixa de incidir sobre a fase pesada (que agora roda *no* chamador, sem `gen_server:call`); só o commit de milissegundos usa `call/3`, com timeout tunável (`infinity` inclusive). O par "chamador crasha com `{timeout,_}` + escrita órfã no servidor" — reproduzido ao vivo — **deixa de existir**, porque a operação que poderia exceder o deadline não está mais atrás do mailbox.
- **Corrige a raiz, não o sintoma.** A raiz é "trabalho pesado no dono porque `protected` só deixa o dono escrever". A correção separa as duas classes de trabalho: o pesado-e-puro vai para onde naturalmente pertence (o chamador/worker), e o dono fica com a única coisa que exige exclusividade (a escrita). Os bounds (`max_bytes`/`max_entries`) atacam a outra metade da raiz — entrada não confiável sem limite — aplicando o cap *antes* de materializar o arquivo na memória, dando ao deployment multi-tenant (ADR-0003) os freios que a `opts()` original não tinha. A API de bulk elimina o N×round-trip/N×`tab2list` de forma composicional, fechando também a interação com o achado #5.

---

### 7. 🟠 `memory_info` faz `ets:tab2list` por carga → N cargas O(N²)

**Local:** `src/erli18n_server.erl:1005` (`install_parsed → memory_warning_check(memory_info())`), `:225-239` (`memory_info/0 → sets:size(distinct_catalogs())`), `:1199-1213` (`distinct_catalogs/0 → ets:tab2list`); mesmo `tab2list` em `loaded_catalogs/0` e `fold_keys/2`.

**O que / por quê.** A cada carga bem-sucedida, `install_parsed` chama `memory_info()`, que computa `num_catalogs` via `sets:size(distinct_catalogs())`, e `distinct_catalogs/0` faz `ets:tab2list(?ETS_TABLE)` — cópia O(total_rows) de **toda** a tabela (todos os inquilinos) + `sets:add_element` por linha, **dentro do `handle_call` serializado**. Cada carga faz trabalho proporcional ao total já carregado → bulk de N catálogos é **O(N²)**, e cada carga grande dobra o pico de memória. Pior: sob o threshold padrão de 100 MB, `num_catalogs` só é consumido no ramo raro `warned` (`telemetry.erl:307`) — o scan inteiro é **trabalho desperdiçado**.

**Evidência (ao vivo).** Custo por carga 5494 µs@#1 → 19117 µs@#200 → 20644 µs@#300; `memory_info()` isolado 1615 µs@5k linhas → 30676 µs@60k; boot de 300 catálogos (600k linhas) ≈ **34–47 s** vs ~0,04 ms no equivalente O(1).

**Solução estrutural.** Manter a contagem de catálogos distintos como índice **incremental e autoritativo** numa 2ª tabela ETS do gen_server, e trocar todo agregado `tab2list` por `ets:info/2` O(1):
- Nova tabela `erli18n_catalog_index` (`set, protected, named_table, read_concurrency`) com 1 linha `{{D,L}}` por catálogo com ≥1 entrada. O gen_server é o único escritor (tabela de dados é `protected`) → o índice nunca diverge.
- Membership livre-de-drift: a API de escrita não tem delete por-chave; entradas só somem em bloco no `do_unload`. Regra: *"linha de índice presente ⇔ ≥1 entrada"*. `index_put/2` idempotente no insert; `index_delete/2` no unload.
- `memory_info/0` lê `num_catalogs = ets:info(?CATALOG_INDEX_TABLE, size)` (O(1)); `distinct_catalogs/0` é removida.

```erlang
%% include/erli18n.hrl
-define(CATALOG_INDEX_TABLE, erli18n_catalog_index).

%% init/1: cria a 2ª tabela ao lado da de dados
_ = ets:new(?CATALOG_INDEX_TABLE, [set, protected, named_table, {read_concurrency, true}]),

index_put(D, L)    -> ets:insert(?CATALOG_INDEX_TABLE, {{D, L}}).   %% idempotente, O(1)
index_delete(D, L) -> ets:delete(?CATALOG_INDEX_TABLE, {D, L}).

memory_info() ->
    #{ets_bytes => ets_info_integer(memory) * erlang:system_info(wordsize),
      num_keys  => ets_info_integer(size),
      num_catalogs => ets:info(?CATALOG_INDEX_TABLE, size)}.          %% O(1)
```

**Fontes.**
- <https://www.erlang.org/doc/apps/stdlib/ets.html> (`info/2`, `update_counter/4`) — `info(_, size)` é O(1); `update_counter` é atômico/isolado.
- <https://www.erlang.org/doc/efficiency_guide/tablesdatabases> — *"ets:tab2list/1 is expensive"* quando só se quer um subconjunto.
- <https://www.erlang.org/doc/man/persistent_term.html> — rejeitado para a contagem (put → GC global).

**Trade-offs.** Uma tabela extra + 1 escrita O(1) por insert/unload (linha minúscula por catálogo, não por chave). Segunda fonte de verdade mantida em sincronia estruturalmente (mesmo `handle_call`, membership idempotente).

**Teste.** `memory_info_accuracy/1` (`:234-264`, `num_catalogs` 0→2) e `ensure_loaded_header_only_no_entries/1` (header-only **excluído** da contagem) permanecem verdes — validam a reescrita. Property: após sequência arbitrária de load/unload, `num_catalogs == cardinalidade dos (D,L) distintos com ≥1 entrada`.

---

### 8. 🟠 `binary_to_integer` ilimitado (nplurals / `msgstr[N]`) → bignum O(d²) + `system_limit` cru

**Local:** `src/erli18n_po.erl:736-741` (`collect_digits`), `:842-863` (`parse_msgstr_index`); `src/erli18n_plural.erl:251-267` (`extract_nplurals`, range-check só **depois** da conversão), `:567-569`/`:612-625` (literais inteiros na expressão).

**O que / por quê.** Vários sites convertem corridas ilimitadas de dígitos via `binary_to_integer` (construção de bignum O(d²)) **antes** de qualquer range-check: (a) `extract_nplurals` constrói o bignum inteiro de `nplurals=<dígitos>` e só então checa `[1,1000]`, e na rejeição o payload `{nplurals_out_of_range, N}` **carrega o bignum gigante** de volta (amplificação de memória/log — verificado: 5000 dígitos ecoam um bignum de 5000 dígitos); (b) `collect_digits` e `parse_msgstr_index` idem; (c) literais inteiros compilam no AST e vão para o caminho quente. **Defeito crítico adicional:** a ≥~1,3 M dígitos `binary_to_integer` levanta `error:system_limit`, **não capturado** → `erli18n_po:parse/1` crasha com exceção crua em vez de `{error,_}` estruturado, violando `SECURITY.md`.

**Evidência (ao vivo).** `.po` ~400 KB com nplurals gigante queima ~15–16 s de CPU; reprocessamento do header faz o real **exceder** O(d²) puro.

**Solução estrutural.** Limitar a corrida de dígitos **antes** de `binary_to_integer` nos três sites; range-check pela contagem de dígitos primeiro; envolver conversões para erro estruturado; manter o valor rejeitado **fora** do payload.

```erlang
-define(MAX_INT_DIGITS, 7).   %% nplurals<=1000 e índices realistas cabem folgado

%% erli18n_plural: checa o tamanho ANTES de materializar o bignum
extract_nplurals(Header) ->
    case locate_field(Header, <<"nplurals">>) of
        {ok, Tail} ->
            {Digits, _} = consume_integer(skip_ws(Tail)),
            case byte_size(Digits) of
                0 -> {error, {missing_nplurals, Header}};
                D when D > ?MAX_INT_DIGITS ->
                    {error, {nplurals_out_of_range, too_many_digits}};  %% sem bignum no payload
                _ ->
                    N = binary_to_integer(Digits),
                    case N >= 1 andalso N =< ?NPLURALS_MAX of
                        true  -> {ok, N};
                        false -> {error, {nplurals_out_of_range, N}}
                    end
            end;
        not_found -> {error, {missing_nplurals, Header}}
    end.

%% erli18n_po: parse_msgstr_index/collect_digits rejeitam corridas > ?MAX_INT_DIGITS
%% (estruturado: {error,{index_too_long, Limit}}), idem literais no plural.
```

**Fontes.**
- <https://www.erlang.org/doc/apps/erts/erlang.html#binary_to_integer/1> — pode levantar `system_limit`/`badarg`.
- <https://www.erlang.org/doc/system/data_types.html#number> — inteiros de precisão arbitrária; custo de construção cresce com o nº de dígitos.

**Trade-offs.** Cap de 7 dígitos é >> qualquer nplurals/índice real (NPLURALS_MAX=1000). Rejeição estruturada fail-closed.

**Teste.** `erli18n_po_fuzz`: headers com `nplurals=<100k dígitos>`, `msgstr[<50k dígitos>]`, literais gigantes → sempre `{error,_}` estruturado, **nunca** `system_limit`/EXIT, dentro de orçamento de tempo.

---

### 9. 🟠 Expressão de plural sem limite → bignum super-linear por ngettext

**Local:**

- `src/erli18n_plural.erl:338-349` — `take_until_semicolon_or_end/{1,2}`: consome bytes até o primeiro `;`/`\n` **sem nenhum teto de comprimento**.
- `src/erli18n_plural.erl:567-569` — clause de `parse_primary/1` para literais inteiros: `consume_integer_st/1` aceita runs de dígitos **ilimitados**.
- `src/erli18n_plural.erl:612-625` — `consume_integer_st/1` / `consume_integer/2`: idem, sem teto.
- `src/erli18n_plural.erl:136-157` — `compile/1`: produz `plural_compiled()` sem nenhuma checagem de tamanho da AST.
- `src/erli18n_plural.erl:164-174` — `evaluate/2` (hot path): caminha a AST inteira a cada chamada.
- `src/erli18n_plural.erl:694-714` — `eval_ast/2` + `apply_binop/3`: a aritmética `L * R` constrói bignums intermediários crescentes.
- `src/erli18n_server.erl:201-217` — `lookup_plural_form/5` chama `erli18n_plural:evaluate(Compiled, N)` (linha 213) em **todo** `ngettext`, **sem cache de resultado** e sem teto de custo.
- `test/erli18n_plural_props.erl:190-191` — o gerador de fuzz limita a profundidade em `min(Size, 4)`, então a classe pathológica **nunca é testada**.

**Causa-raiz:**

O defeito é **estrutural na fronteira de compilação**, não na avaliação. O parser recursivo-descendente (`parse_expr_bin/1`, linha 368) e o tokenizador de header (`take_until_semicolon_or_end/2`, linha 338) não impõem **nenhum invariante de tamanho** sobre a expressão `plural=`. A gramática GNU (documentada no cabeçalho do módulo, linhas 355-366) é aceita na íntegra, mas a especificação GNU gettext **não define limite de comprimento/complexidade** — ela delega esse contrato à implementação (ver Fontes). O legado `gettexter_plural` mascarava o problema via `erl_eval` (custo amortizado pela máquina virtual), mas o BR-DESCARTAR-003 troca isso por um interpretador próprio que caminha a AST literal em `eval_ast/2`.

Como a `plural_compiled()` (linhas 73-77) guarda a AST crua e `evaluate/2` é declarado o **hot path** (PSD-004, linha 15), cada `ngettext`:

1. percorre `O(nós)` da AST (custo linear no número de nós), **e**
2. para uma cadeia `n*n*...*n` de `k` fatores, computa `n^k` por multiplicações sucessivas `apply_binop('*', ...)` (linha 706). Cada produto parcial `n^j` é um bignum de `O(j·log n)` bits; multiplicar por `n` custa `O(j·log n)`. Somando `j = 1..k`, o custo total é **`O(k²·log²n)`** — quadrático no comprimento da cadeia **e** crescente com `N`.

A `plural_compiled()` é instalada uma vez (`install_parsed/5`, `erli18n_server.erl:968-1007`) e reutilizada para sempre; um único header malicioso de ~4 KB envenena **todas** as futuras avaliações de plural daquele locale. O `?NPLURALS_MAX` (linha 118) limita apenas `nplurals`, não a expressão `plural=`.

**Evidência:**

Reprodução ao vivo (OTP 28.4.3, `rebar3 compile`), cadeia `plural=(n*n*...*n) % 2`, custo **por chamada** de `evaluate/2`:

```
ChainLen | compile_us |  eval_us/call (N=12345)
     100 |     1315.0 |          5.6
     500 |       91.0 |         33.1
    1000 |      159.0 |        157.8
    2000 |      358.0 |        976.3
    5000 |     1264.0 |       6964.8
   10000 |     3521.0 |      12762.5
```

O custo de `evaluate/2` cresce **super-linearmente**: 1000→158 µs, 5000→6,96 ms, 10000→12,8 ms (≈ ×8 ao dobrar de 5k para 10k, consistente com `O(k²)`). E cresce com `N` (cadeia fixa = 2000), provando o componente bignum:

```
Amplification across N (chain_len=2000):
  N=         1  eval_us/call=      28.7
  N=         2  eval_us/call=      66.2
  N=        11  eval_us/call=     150.4
  N=      1000  eval_us/call=     329.6
  N=   9999999  eval_us/call=     664.6
```

Contagem de nós da AST — regras CLDR reais vs. cadeias pathológicas (mesma sessão):

```
Arabic CLDR rule  node count: 36
Russian CLDR rule node count: 39
Slovenian CLDR   node count: 28
chain_len=100   -> node count=201,   byte size=225
chain_len=1000  -> node count=2001,  byte size=2025
chain_len=2000  -> node count=4001,  byte size=4025
chain_len=10000 -> node count=20001, byte size=20025
```

A regra real mais complexa (russo) tem **39 nós**; um teto de 256 nós dá margem ≈6,5× sobre o pior caso real e ainda assim rejeita até uma cadeia de 100 fatores (201 nós). A documentação OTP confirma o modelo de custo: inteiro pequeno = **1 word** (faixa de 60 bits em 64-bit); inteiro grande (bignum) = **3..N words**, alocado no heap, com pressão de GC (ver Fontes). Logo, limitar a contagem de nós da AST **limita também o tamanho máximo do bignum** (`n^MaxNodes`), fechando ambos os eixos do custo.

**Solução estrutural:**

Mover o invariante de tamanho para a **fronteira de compilação** (carga única, fora do hot path), de modo que `evaluate/2` permaneça uma função pura e *bounded by construction*. Duas barreiras complementares:

1. **Teto de bytes no tokenizador** (`?EXPR_MAX_BYTES`): `take_until_semicolon_or_end/2` rejeita qualquer expressão acima de 4 KB antes mesmo de parsear — corta o eixo de comprimento textual (literais inteiros gigantes, cadeias enormes) em `O(1)` de varredura abortada.
2. **Teto de nós na AST** (`?AST_MAX_NODES`): após o parse, um contador *short-circuiting* `count_nodes_bounded/2` rejeita ASTs acima de 256 nós. Isso limita simultaneamente o trabalho de caminhada **e** o tamanho do maior bignum produzível (`n^256`), porque a profundidade aritmética está atada à contagem de nós.

Ambos os limites são reportados como um novo variante estruturado de `compile_error()`, preservando o contrato "compile nunca crasha, retorna `{error, _}`" (linhas 79-83). A API pública `compile/1`/`evaluate/2`/`plural_compiled()` **não muda de forma**; apenas `compile_error()` ganha dois construtores — uma extensão aditiva e retrocompatível. Paridade GNU/CLDR é preservada: nenhuma regra real (≤39 nós, ≤~120 bytes) é afetada.

```erlang
%% =========================
%% Novos limites estruturais (cabeçalho do módulo, junto de ?NPLURALS_MAX)
%% =========================

%% Teto de bytes da expressão `plural=`. A maior regra CLDR real (árabe,
%% 6 formas) cabe em ~120 bytes; 4 KiB dá margem de ~34x para variações
%% de catálogo legítimas e ainda corta cadeias/literais pathológicos
%% (n*n*...*n de milhares de fatores) em O(1) de varredura abortada.
%% A especificação GNU gettext não define limite — delega à
%% implementação. Ver `take_until_semicolon_or_end/2`.
-define(EXPR_MAX_BYTES, 4096).

%% Teto de nós da AST de plural. A regra real mais complexa (russo/árabe)
%% tem 39 nós; 256 dá folga ~6,5x sobre o pior caso real e atrela o
%% tamanho máximo do bignum intermediário a `n^256`, mantendo `evaluate/2`
%% com custo limitado por construção. Ver `check_ast_complexity/1`.
-define(AST_MAX_NODES, 256).

%% =========================
%% compile_error() — extensão aditiva e retrocompatível
%% =========================
%% (substitui a definição em src/erli18n_plural.erl:79-83)

-type compile_error() ::
    {syntax_error, Reason :: term(), Position :: non_neg_integer()}
    | {missing_nplurals, binary()}
    | {missing_plural_expr, binary()}
    | {nplurals_out_of_range, integer()}
    %% Expressão `plural=` excede o teto de bytes (DoS hardening).
    | {plural_expr_too_long, Bytes :: pos_integer(), Max :: pos_integer()}
    %% AST compilada excede o teto de nós (DoS hardening).
    | {plural_expr_too_complex, Nodes :: pos_integer(), Max :: pos_integer()}.

%% =========================
%% compile/1 — insere as duas barreiras na fronteira de carga
%% =========================
%% (substitui src/erli18n_plural.erl:136-157)

-spec compile(binary()) -> {ok, plural_compiled()} | {error, compile_error()}.
compile(Header) when is_binary(Header) ->
    case extract_nplurals(Header) of
        {ok, NPlurals} ->
            case extract_plural_expr(Header) of
                {ok, ExprBin} ->
                    %% Barreira 1: teto de bytes ANTES de parsear. Um único
                    %% teste de tamanho aborta entradas pathológicas sem
                    %% gastar trabalho de parser proporcional ao tamanho.
                    case byte_size(ExprBin) =< ?EXPR_MAX_BYTES of
                        false ->
                            {error,
                                {plural_expr_too_long, byte_size(ExprBin), ?EXPR_MAX_BYTES}};
                        true ->
                            compile_parsed(Header, NPlurals, ExprBin)
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% Parseia e, em sucesso, aplica a Barreira 2 (teto de nós da AST).
-spec compile_parsed(binary(), pos_integer(), binary()) ->
    {ok, plural_compiled()} | {error, compile_error()}.
compile_parsed(Header, NPlurals, ExprBin) ->
    case parse_expr_bin(ExprBin) of
        {ok, Ast} ->
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
        {error, _} = Err ->
            Err
    end.

%% =========================
%% take_until_semicolon_or_end/2 — teto de bytes embutido (defesa em
%% profundidade: aborta a varredura assim que estoura ?EXPR_MAX_BYTES,
%% mesmo que falte o `;` terminador)
%% =========================
%% (substitui src/erli18n_plural.erl:338-349)

take_until_semicolon_or_end(Bin) ->
    take_until_semicolon_or_end(Bin, 0).

take_until_semicolon_or_end(Bin, N) when N >= byte_size(Bin) ->
    Bin;
take_until_semicolon_or_end(Bin, N) when N >= ?EXPR_MAX_BYTES ->
    %% Estouro de teto: devolve o prefixo já consumido. `compile/1`
    %% então rejeita com {plural_expr_too_long, _, _}. Evita varrer um
    %% header gigante sem `;` por inteiro.
    binary:part(Bin, 0, N);
take_until_semicolon_or_end(Bin, N) ->
    case binary:at(Bin, N) of
        $; -> binary:part(Bin, 0, N);
        %% header line terminator
        $\n -> binary:part(Bin, 0, N);
        _ -> take_until_semicolon_or_end(Bin, N + 1)
    end.

%% =========================
%% check_ast_complexity/1 — contador short-circuiting de nós da AST
%% =========================
%% (novas funções; ficam junto do interpretador, após apply_binop/3)

%% Rejeita ASTs cujo número de nós excede ?AST_MAX_NODES. O contador
%% para de descer assim que o orçamento estoura (`over_limit`), então o
%% custo é O(min(nós, ?AST_MAX_NODES)) — nunca proporcional a uma AST
%% maliciosa enorme. Roda uma única vez na carga (compile/1), nunca no
%% hot path (evaluate/2).
-spec check_ast_complexity(ast()) ->
    ok | {error, {plural_expr_too_complex, pos_integer(), pos_integer()}}.
check_ast_complexity(Ast) ->
    case count_nodes_bounded(Ast, 0) of
        {ok, _Total} ->
            ok;
        over_limit ->
            %% Só materializa a contagem total (cara) na via de erro,
            %% que é rara e fora do hot path. ?AST_MAX_NODES + 1 é o
            %% piso garantido; ast_node_count/1 dá o valor exato para
            %% diagnóstico.
            {error, {plural_expr_too_complex, ast_node_count(Ast), ?AST_MAX_NODES}}
    end.

%% Contador com orçamento. Retorna {ok, Total} se a AST inteira couber em
%% ?AST_MAX_NODES; senão `over_limit` no primeiro nó que estoura.
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

%% Contagem exata e total — usada apenas na via de erro (diagnóstico).
-spec ast_node_count(ast()) -> pos_integer().
ast_node_count(N) when is_integer(N) -> 1;
ast_node_count(n) -> 1;
ast_node_count({unop, '!', E}) ->
    1 + ast_node_count(E);
ast_node_count({binop, _Op, L, R}) ->
    1 + ast_node_count(L) + ast_node_count(R);
ast_node_count({ternary, C, T, E}) ->
    1 + ast_node_count(C) + ast_node_count(T) + ast_node_count(E).
```

**Integração no servidor (sem mudar tipos públicos):** `install_parsed/5`
(`erli18n_server.erl:968-1007`) já roteia `{error, CompileErr}` de
`maybe_compile_plural/1` (linhas 975-977) para
`{error, {plural_compile_error, CompileErr}}`, que é exatamente o
`ensure_error()` declarado em `erli18n_server.erl:75-79`. Como os dois
novos construtores são apenas variantes de `compile_error()`, o
`header_state()` (linhas 83-91), o `ensure_result()` (linhas 71-74) e o
fluxo de `lookup_plural_form/5` (linha 213) **permanecem intactos**: um
catálogo malicioso simplesmente falha a carga com erro estruturado e
**nunca chega a instalar** uma `plural_compiled()` venenosa. A `entry()`
(`erli18n_po.erl:45`) e `opts()` (`erli18n_server.erl:66`) não são
tocadas.

**Fontes:**

- https://www.gnu.org/software/gettext/manual/html_node/Plural-forms.html — define que `plural=` é uma expressão em sintaxe C, só a variável `n` é permitida, só inteiros positivos decimais, e que a expressão é **avaliada a cada chamada de `ngettext`/`dngettext`/`dcngettext`** (confirma o eixo "todo lookup"). **Não** especifica limite de comprimento/complexidade — logo o teto é uma decisão de implementação legítima, não uma quebra de spec.
- https://www.erlang.org/docs/24/efficiency_guide/advanced — "Memory Size of Erlang Terms": inteiro pequeno = **1 word** (faixa de 60 bits em 64-bit: `-576460752303423489 < i < 576460752303423488`); inteiro grande (bignum) = **3..N words**. Sustenta que limitar a profundidade aritmética (via nós) limita o tamanho/custo do bignum.
- https://www.erlang.org/doc/system/memory.html — Memory Usage: bignums são **alocados no heap** e contribuem para pressão de GC; multiplicação de bignums é `O(dígitos)`, confirmando o crescimento super-linear medido.
- https://www.unicode.org/reports/tr35/tr35-numbers.html#Language_Plural_Rules — CLDR/UTS #35: as 6 categorias (`zero,one,two,few,many,other`) e operandos `n,i,v,w,f,t`. Regras reais são pequenas e mutuamente exclusivas — corrobora que 256 nós é folga generosa e nenhuma regra canônica é afetada.
- https://www.gnu.org/software/gettext/manual/html_node/Translating-plural-forms.html — regra C/germânica padrão (`nplurals=2; plural=n != 1;`), idêntica a `fallback_rule/0` (linha 238); preservada pela mudança.

**Trade-offs:**

- **Honesto:** o teto de 256 nós / 4 KB é uma constante de política. Se algum dia surgir uma regra CLDR legítima maior (improvável; a maior real tem 39 nós), o limite precisa subir — por isso ambos são `-define` documentados, fáceis de auditar e ajustar. Mantê-los como macro (não config dinâmica) preserva a pureza de `compile/1`/`evaluate/2` e a analisabilidade por dialyzer/eqwalizer.
- **Custo de carga:** `check_ast_complexity/1` adiciona uma passada `O(min(nós, 256))` em `compile/1`. Para regras reais isso é ≤39 iterações — ruído. A barreira de bytes é `O(1)` (um `byte_size/1`).
- **API:** dois novos construtores em `compile_error()`. É uma adição (clientes que casam genérico `{error, _}` não quebram), mas `validate_against_cldr/2` e `split_rule/1` (linhas 850-866) já tratam `{error, _}` como `error`/falha de equivalência — comportamento correto e inalterado.
- **Não-objetivo:** deliberadamente **não** adicionamos cache por `(catalog, N)`. Com a complexidade limitada a 256 nós, `evaluate/2` volta a custar microssegundos; um cache acrescentaria estado mutável (ETS/`persistent_term`) e uma superfície de invalidação no hot path sem ganho real. A correção da **raiz** (bound) torna o cache desnecessário — preferível a um workaround de memoização sobre um custo ainda ilimitado.

**Teste (PropEr):**

- **`test/erli18n_plural_props.erl`** — adicionar uma propriedade `prop_oversized_rejected/0`: gerar cadeias `n (*n){k}` com `k` em `choose(?AST_MAX_NODES, 5*?AST_MAX_NODES)` e exigir que `erli18n_plural:compile/1` retorne `{error, {plural_expr_too_complex, _, _}}` ou `{error, {plural_expr_too_long, _, _}}` **e** que `compile/1` retorne em tempo limitado (assertar via `timer:tc/1` < limite). Esta propriedade **chancela o bug atual**: hoje o `compile/1` aceita a cadeia e devolve `{ok, _}`.
- **`test/erli18n_plural_props.erl:190-191`** — o gerador `c_plural_expr/0` faz `min(Size, 4)`, então a classe pathológica é **invisível** ao fuzz atual (este é o teste que "chancela o bug" por omissão). Manter a profundidade pequena para `prop_index_in_range/0` (corretude), mas adicionar um gerador *adversarial* dedicado (cadeia profunda explícita) para a nova propriedade — não dá para alcançar 256 nós via `?SIZED` capado em 4.
- **`prop_index_in_range/0` (linhas 58-128)** — acrescentar uma asserção de orçamento: para todo header gerado que compila com `{ok, _}`, a AST resultante tem `ast_node_count =< ?AST_MAX_NODES` (invariante pós-compile). Garante que a barreira nunca deixa passar AST acima do teto.
- **`test/erli18n_fuzz_SUITE.erl` / `erli18n_po_fuzz.erl`** — `fuzz_extreme_inputs/1` (linhas 76-86) já constrói binários de 100 KB+; estender o corpus F6 com um header `Plural-Forms: nplurals=2; plural=(n*n*...*n) % 2;` de comprimento crescente e exigir que `ensure_loaded` retorne `{error, {plural_compile_error, {plural_expr_too_long|plural_expr_too_complex, _, _}}}` **sem** o supervisor reiniciar (invariante F7) e em tempo limitado.
- **`test/erli18n_plural_SUITE.erl`** — espelhar o estilo existente (`nplurals_out_of_range/1`, linhas 381-384) com dois casos EUnit/CT determinísticos: `plural_expr_too_long/1` e `plural_expr_too_complex/1` casando `{error, {plural_expr_too_long, _, _}}` e `{error, {plural_expr_too_complex, _, _}}`.

**Por que é estrutural:**

A correção **muda a classe de complexidade** do hot path de **`O(k²·log²n)` ilimitado** para **`O(1)` limitado** (≤256 nós, bignum ≤ `n^256` — constante de política), porque o invariante de tamanho passa a ser garantido **na fronteira de compilação**, antes de qualquer `plural_compiled()` ser instalada. `evaluate/2` permanece uma função pura, sem cache, sem estado mutável — *bounded by construction*, não por mitigação. Remove a classe inteira de "header malicioso amplifica todo `ngETText` subsequente" na raiz: um catálogo pathológico **falha a carga** com erro estruturado em vez de envenenar o runtime, fechando simultaneamente os dois eixos do ataque (comprimento textual via bytes; profundidade aritmética/bignum via nós) sem quebrar paridade GNU/CLDR nem a API pública.

---

### 10. 🟠 ETS sem heir: crash do server perde todos os catálogos

**Local:**
- `src/erli18n_server.erl:725-733` — `init/1` cria a tabela `?ETS_TABLE` (`erli18n_catalog`) com `[set, protected, named_table, {read_concurrency, true}, {keypos, 1}]` **sem** a opção `{heir, _, _}`. O dono é o próprio `gen_server`.
- `src/erli18n_server.erl:857-858` — `terminate(_Reason, _State) -> ok.` não preserva nada; nenhum snapshot, nenhum repasse de tabela.
- `src/erli18n_sup.erl:11-27` — supervisor `one_for_one`, **um único** worker (`erli18n_server`), `intensity => 5, period => 10`.
- Caminho de leitura afetado: `src/erli18n_server.erl:163, 171, 180` (`lookup_singular/4`, `lookup_plural/5`, `lookup_header/2`) lê direto de `?ETS_TABLE`; após o crash a tabela some e todas retornam `undefined`.

**Causa-raiz:**
No modelo de propriedade de tabelas do ETS, **a tabela pertence ao processo que a cria e é destruída automaticamente quando esse processo termina** — não há GC de tabelas por referência, só por morte do dono (ETS User's Guide; `ets.html`: *"When the process terminates, the table is automatically destroyed"*). Em `init/1`, o **dono** da tabela é o próprio `erli18n_server`, que é também o processo **mutante** (o único writer da tabela `protected`). Juntar "dono da tabela" e "processo que muta a tabela e pode crashar" no mesmo PID é o defeito estrutural: o ciclo de vida do **estado** (catálogos) fica acoplado ao ciclo de vida do **código que falha**.

Como não há `{heir, _, _}`, qualquer término do `erli18n_server` — um `badmatch` numa cláusula de `handle_call` (p.ex. o caminho de Content-Type malformado de outro finding), um `exit(Pid, kill)` operacional, um bug futuro — apaga a tabela inteira. O supervisor é `one_for_one` com um único worker: ele reinicia o `erli18n_server`, mas `init/1` constrói uma tabela **nova e vazia** e `terminate/2` não preservou nada. Resultado: todos os catálogos são perdidos silenciosamente e cada `lookup_*` passa a devolver `undefined` (degradando para o msgid via fallback do façade) até que **cada** catálogo seja recarregado pelo consumidor. Não existe processo dono dedicado nem heir para sobreviver ao restart — uma única falha vira **perda total de disponibilidade** das traduções, não um soluço transitório.

**Evidência:**
Reprodução ao vivo (OTP 28.4.3, build `rebar3 compile`), exatamente o cenário do relatório:

```text
BEFORE_KILL  pid=<0.86.0> ets_size=1 owner_is_server=true heir=none lookup={ok,<<"Bonjour">>}
=SUPERVISOR REPORT=== child_terminated reason: killed offender id: erli18n_server
AFTER_RESTART pid=<0.87.0> pid_changed=true ets_size=0 lookup=undefined loaded_catalogs=[]
```

Carreguei `default/<<"fr">>` com `Hello -> Bonjour`; `ets:info(erli18n_catalog, heir)` é `none`; `exit(Pid, kill)` → o supervisor reinicia (`pid_changed=true`) → `ets:info(size)=0`, `lookup_singular = undefined`, `loaded_catalogs() = []`. **Catálogo inteiro perdido.**

Validação da solução (mesmo OTP, processo dono dedicado + `{heir, Owner, _}` + `give_away/3`, ciclo completo crash→transfer→restart→re-handoff):

```text
gen1: size=1 owner_is_worker=true
after gen1 crash: size=1 owner_is_owner=true          %% tabela voltou ao dono via ETS-TRANSFER, dados intactos
gen2: size=1 owner_is_worker2=true lookup=[{fr_Hello,<<"Bonjour">>}]  %% novo worker reassume a MESMA tabela
gen2 after write: size=2                               %% writes continuam funcionando
```

O crash abrupto do worker dispara `{'ETS-TRANSFER', Tab, FromPid, HeirData}` de volta ao processo dono (heir), com `size` e linhas preservados; o worker reiniciado readquire a **mesma** tabela e segue escrevendo. A classe de crash "perde todos os catálogos" é eliminada.

**Solução estrutural:**
Separar **propriedade** de **mutação**. Introduzir um processo dono dedicado e longevo — `erli18n_table_owner` — cuja única responsabilidade é **criar e segurar** a tabela ETS e reavê-la quando o worker morre. O `erli18n_server` deixa de criar a tabela: ele a **recebe** do dono via `give_away/3` e a opera normalmente (continua sendo o writer da tabela `protected`). O dono mantém-se como `heir` da tabela; quando o worker crasha, o ETS dispara `'ETS-TRANSFER'` e a tabela volta intacta ao dono, que então a repassa ao worker reiniciado.

Mudanças:
1. **`erli18n_sup`**: estratégia passa para `rest_for_one`, com o **dono primeiro** e o **worker depois** na lista de filhos. Pela semântica do `supervisor` (`supervisor.html`: *"the 'rest' of the child processes (that is, the child processes after the terminated child process in the start order) are terminated"*), um crash do **worker** (depois) **não** termina o **dono** (antes) — logo o dono e a tabela sobrevivem. Já um crash do **dono** (raro: ele não muta nada) termina e reinicia o worker também, mas o dono no `init` recria a tabela e o ciclo se restabelece.
2. **`erli18n_table_owner`** (novo): cria a tabela `protected`/`named_table` com `{heir, self(), ?HEIR_DATA}`, monitora o worker, faz `give_away/3` quando o worker registra-se, e ao receber `'ETS-TRANSFER'` (worker morto) apenas re-arma e aguarda o próximo handoff.
3. **`erli18n_server`**: `init/1` **não cria** a tabela; pede o handoff ao dono e fica `{ok, State}` operando assim que receber o `'ETS-TRANSFER'`. Todo o resto do módulo (specs, tipos `header_state()`, `ensure_result()`, `entry()`/`catalog_entry()`, `plural_compiled()`, `opts()`) permanece inalterado — os macros de chave e `?ETS_TABLE` (tabela **nomeada**) continuam idênticos, então o hot-path de leitura lock-free não muda em nada.

Como a tabela é `named_table` e `protected`, as leituras diretas dos processos chamadores (`lookup_*`, `tab2list` da observabilidade) seguem funcionando independentemente de qual PID é o dono no instante. A API pública (`erli18n`, `erli18n_server`) e a paridade GNU gettext / CLDR ficam **intactas** — esta é uma mudança puramente de topologia de supervisão e propriedade de tabela.

```erlang
%% =====================================================================
%% include/erli18n.hrl  (acrescentar — heir handoff constants)
%% =====================================================================
%% Marcador do payload `'ETS-TRANSFER'` quando a tabela retorna ao dono
%% por morte do worker (heir). Distingue-o do handoff inicial dono->worker.
-define(ETS_HEIR_DATA, erli18n_catalog_heir).
%% Marcador do payload `'ETS-TRANSFER'` no give_away dono->worker.
-define(ETS_HANDOFF_DATA, erli18n_catalog_handoff).
%% Nome registrado do processo dono da tabela.
-define(TABLE_OWNER, erli18n_table_owner).


%% =====================================================================
%% src/erli18n_table_owner.erl  (NOVO MÓDULO)
%% =====================================================================
-module(erli18n_table_owner).

-behaviour(gen_server).

-include("erli18n.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/0, claim_table/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% O estado carrega o id da tabela (atom nomeado) e o monitor do worker
%% que detém a tabela no momento (ou `undefined` enquanto o dono a segura).
-type state() :: #{
    table := ets:table(),
    worker := undefined | {pid(), reference()}
}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?TABLE_OWNER}, ?MODULE, [], []).

%% Chamado pelo `erli18n_server` no seu `init/1`: pede ao dono que repasse
%% a tabela. Síncrono — quando retorna `ok`, o `'ETS-TRANSFER'` já está (ou
%% estará) na caixa de mensagens do chamador. O dono valida que o chamador
%% é o worker vivo e local antes do `give_away/3`.
-spec claim_table() -> ok.
claim_table() ->
    ok = gen_server:call(?TABLE_OWNER, {claim, self()}, infinity).

-spec init([]) -> {ok, state()}.
init([]) ->
    %% O dono CRIA a tabela e fica como heir de si mesmo. Enquanto nenhum
    %% worker a reivindicou, o dono é o proprietário — leituras já
    %% funcionam (tabela nomeada/protected) mesmo antes do handoff.
    Table = ets:new(?ETS_TABLE, [
        set,
        protected,
        named_table,
        {read_concurrency, true},
        {keypos, 1},
        {heir, self(), ?ETS_HEIR_DATA}
    ]),
    {ok, #{table => Table, worker => undefined}}.

-spec handle_call({claim, pid()}, gen_server:from(), state()) ->
    {reply, ok, state()}.
handle_call({claim, WorkerPid}, _From, #{table := Table} = State) when
    is_pid(WorkerPid)
->
    %% Pré-condição do `give_away/3`: o dono precisa SER o proprietário
    %% atual. Garantimos isso só repassando quando a tabela está conosco.
    %% Se um worker anterior ainda constava, derrubamos seu monitor (o
    %% `'ETS-TRANSFER'`/`'DOWN'` desse worker, se houver, é drenado em
    %% handle_info e ignorado por não bater no monitor corrente).
    NewState = reclaim_if_needed(State),
    Mon = erlang:monitor(process, WorkerPid),
    %% `give_away/3` exige que o destino esteja vivo, local e não seja já o
    %% dono. O monitor acima cobre a corrida "worker morreu agorinha":
    %% nesse caso `give_away/3` lançaria badarg, então protegemos.
    case safe_give_away(Table, WorkerPid) of
        ok ->
            {reply, ok, NewState#{worker => {WorkerPid, Mon}}};
        {error, _} = _Err ->
            %% Worker morreu na janela do handoff. Solta o monitor; a
            %% tabela continua conosco. O worker será reiniciado pelo
            %% supervisor e chamará `claim_table/0` de novo.
            erlang:demonitor(Mon, [flush]),
            {reply, ok, NewState#{worker => undefined}}
    end.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(
    {'ETS-TRANSFER', Table, _FromPid, ?ETS_HEIR_DATA},
    #{table := Table, worker := Worker} = State
) ->
    %% O worker que detinha a tabela morreu; o ETS nos devolveu a posse
    %% via heir, com TODAS as linhas intactas. Apenas re-armamos: largamos
    %% o monitor e aguardamos o próximo `claim` do worker reiniciado.
    _ = drop_worker_monitor(Worker),
    ?LOG_INFO(
        #{event => catalog_table_reclaimed,
          reason => worker_down,
          size => safe_size(Table)},
        #{domain => [erli18n, table_owner]}
    ),
    {noreply, State#{worker => undefined}};
handle_info(
    {'DOWN', Mon, process, Pid, _Reason},
    #{worker := {Pid, Mon}} = State
) ->
    %% `'DOWN'` pode chegar antes do `'ETS-TRANSFER'`. Não soltamos a
    %% tabela aqui (o ETS fará a transferência); só marcamos que não há
    %% worker corrente para evitar give_away duplo. A posse efetiva volta
    %% no clause de `'ETS-TRANSFER'` acima.
    {noreply, State#{worker => undefined}};
handle_info(_Info, State) ->
    %% `'DOWN'`/`'ETS-TRANSFER'` de gerações antigas (monitor já não bate)
    %% ou ruído. Ignorar é seguro: a tabela é nomeada e seu dono corrente
    %% é sempre este processo ou o worker vivo.
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    %% Se o DONO cai, a tabela cai junto (ele é o dono/heir). Isso é
    %% aceitável: sob `rest_for_one` o worker (depois do dono) também é
    %% reiniciado, e o novo dono recria a tabela. O dono não muta nada,
    %% então sua superfície de crash é mínima.
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =========================
%% Internos
%% =========================

%% Garante que o dono é o proprietário corrente antes de um novo handoff.
%% Se um worker anterior ainda figurava, derruba seu monitor; a posse
%% física já terá voltado (ou voltará) via `'ETS-TRANSFER'`.
-spec reclaim_if_needed(state()) -> state().
reclaim_if_needed(#{worker := undefined} = State) ->
    State;
reclaim_if_needed(#{worker := Worker} = State) ->
    _ = drop_worker_monitor(Worker),
    State#{worker => undefined}.

-spec drop_worker_monitor(undefined | {pid(), reference()}) -> ok.
drop_worker_monitor(undefined) ->
    ok;
drop_worker_monitor({_Pid, Mon}) ->
    _ = erlang:demonitor(Mon, [flush]),
    ok.

%% `ets:give_away/3` é specado como `true`, mas lança `badarg` se o destino
%% morreu na janela. Encapsulamos para devolver um resultado tipado.
-spec safe_give_away(ets:table(), pid()) -> ok | {error, give_away_failed}.
safe_give_away(Table, WorkerPid) ->
    try ets:give_away(Table, WorkerPid, ?ETS_HANDOFF_DATA) of
        true -> ok
    catch
        error:badarg -> {error, give_away_failed}
    end.

-spec safe_size(ets:table()) -> non_neg_integer().
safe_size(Table) ->
    case ets:info(Table, size) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.


%% =====================================================================
%% src/erli18n_server.erl  — substituir SOMENTE init/1 (linhas 725-733).
%% Todo o resto do módulo (handle_call/handle_cast, tipos header_state(),
%% ensure_result(), catalog_entry(), opts(), o hot-path de leitura) fica
%% inalterado.
%% =====================================================================
-spec init([]) -> {ok, map()}.
init([]) ->
    %% O server NÃO cria mais a tabela. Pede ao dono dedicado que a
    %% repasse via give_away/3. `claim_table/0` é síncrono; ao retornar,
    %% o `'ETS-TRANSFER'` inicial estará a caminho. Tornamo-nos o
    %% proprietário (writer da tabela protected) ao consumi-lo abaixo.
    ok = erli18n_table_owner:claim_table(),
    receive
        {'ETS-TRANSFER', ?ETS_TABLE, _OwnerPid, ?ETS_HANDOFF_DATA} ->
            ok
    after 5000 ->
        %% O dono é um filho irmão iniciado ANTES (rest_for_one); se ele
        %% não repassou em 5s algo está estruturalmente quebrado — crashar
        %% é o comportamento OTP correto (o supervisor reavalia).
        error({ets_handoff_timeout, ?ETS_TABLE})
    end,
    {ok, #{}}.


%% =====================================================================
%% src/erli18n_sup.erl  — substituir init/1 (linhas 11-27).
%% =====================================================================
init([]) ->
    %% rest_for_one + dono ANTES do worker: o crash do worker (que muta a
    %% tabela e portanto é o que falha) NÃO termina o dono, então a tabela
    %% e os catálogos sobrevivem. O crash do dono (raro — não muta nada)
    %% reinicia também o worker, que readquire a tabela recriada.
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 10
    },
    Owner = #{
        id => erli18n_table_owner,
        start => {erli18n_table_owner, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [erli18n_table_owner]
    },
    Server = #{
        id => erli18n_server,
        start => {erli18n_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [erli18n_server]
    },
    %% Ordem é load-bearing: dono primeiro, server depois.
    {ok, {SupFlags, [Owner, Server]}}.
```

**Fontes:**
- https://www.erlang.org/doc/apps/stdlib/ets.html — *"When the process terminates, the table is automatically destroyed"* e *"there is no automatic garbage collection for tables ... unless the owner process terminates"*: confirma a causa-raiz (tabela morre com o dono).
- https://www.erlang.org/doc/apps/stdlib/ets.html#heir — sintaxe exata `{heir, Pid, HeirData} | {heir, Pid} | {heir, none}`; com `HeirData`, *"a message `{'ETS-TRANSFER',tid(),FromPid,HeirData}` is sent to the heir when [o owner termina]"*; default `none` *"destroys the table when the owner terminates"*; *"The heir must be a local process"*.
- https://www.erlang.org/doc/apps/stdlib/ets.html#give_away/3 — `give_away(Table, Pid, GiftData) -> true`; envia `{'ETS-TRANSFER',Table,FromPid,GiftData}` ao novo dono; *"The process Pid must be alive, local, and not already the owner ... The calling process must be the table owner"*; e o padrão canônico: *"a table owner can ... set heir to itself, give the table away, and then get it back if the receiver terminates"* — exatamente o desenho usado aqui.
- https://www.erlang.org/doc/apps/stdlib/ets.html (setopts/2) — *"The only allowed option to be set after the table has been created is heir"*: sustenta o re-arm via heir já fixado na criação.
- https://www.erlang.org/doc/apps/stdlib/supervisor.html — `rest_for_one`: *"the 'rest' of the child processes (that is, the child processes after the terminated child process in the start order) are terminated. Then the terminated child process and all child processes after it are restarted"*; filhos iniciam em ordem da lista e terminam em ordem inversa — base da escolha "dono antes do worker".
- https://www.erlang.org/doc/apps/stdlib/gen_server.html — assinaturas de `init/1` (`{ok, State}`), `handle_info/2` (recebe *"any other message"*, incl. `'DOWN'` e `'ETS-TRANSFER'`), `gen_server:start_ret()` e `gen_server:from()`: garantem que os specs do código batem com OTP 28.
- https://github.com/zsoci/ETSHandler e https://jola.dev/posts/patterns-for-managing-ets-tables — descrição do padrão "Table Manager + Table Handler" (dono dedicado + handler mutante com heir de volta ao manager): valida que o desenho proposto é o idioma estabelecido na comunidade, não uma invenção.

**Trade-offs:**
- **Um processo a mais** (`erli18n_table_owner`) e uma mensagem de handoff síncrona em cada `init/1` do server. Custo de inicialização: um `gen_server:call` + um `receive` (microssegundos); zero custo no hot-path de leitura (a tabela continua `named_table`/`protected`, leitura lock-free idêntica).
- **Não sobrevive à queda do nó**: heir só repassa entre processos vivos do mesmo nó. Para durabilidade entre reinícios do nó seria preciso persistência (DETS/disco/`persistent_term` snapshot) — fora do escopo deste finding e desnecessário para "crash do worker". O desenho deixa o ponto de extensão óbvio (o dono poderia versionar a tabela em DETS).
- **Crash do dono ainda perde a tabela** (ele é o dono/heir). Mitigado por (a) o dono não mutar nada — superfície de crash mínima; (b) `rest_for_one` garantir que o server seja reiniciado junto e readquira a tabela recriada, mantendo o sistema consistente (vazio, não corrompido). Trocar perda-em-todo-crash-do-worker por perda-só-em-crash-do-dono-imutável é a melhoria estrutural.
- **Janela de corrida no handoff** (worker morre entre `claim` e `give_away`): tratada com `try ... catch error:badarg` e re-claim no restart; nenhuma exceção vaza.
- **Ordem dos filhos no supervisor é load-bearing**: inverter dono/worker reintroduziria o bug. Documentado em comentário no `init/1`.

**Teste (PropEr):**
- **Teste que hoje chancela o bug** — `test/erli18n_fuzz_SUITE.erl:88` (`fuzz_end_to_end`) roda `erli18n_po_fuzz:prop_end_to_end_no_supervisor_restart/0` (`test/erli18n_po_fuzz.erl:217-256`), que captura `ServerPidBefore`/`ServerPidAfter` e só verifica que o **PID não mudou** (server não reiniciou). Esse property **não** detecta a perda de catálogo: ele afirma robustez contra *malformed PO*, mas é cego ao cenário "kill → restart → tabela vazia", porque nunca carrega um catálogo antes nem inspeciona `ets:info(size)` depois. Em `test/erli18n_server_SUITE.erl:428` (`terminate_called_on_app_stop`) o server é derrubado via `sys:terminate/2` e a app é **reiniciada inteira** — mascarando a perda, pois não há asserção sobre catálogos sobreviverem ao restart isolado do worker.
- **Novo property (`erli18n_table_survival_props.erl`)** — `?FORALL(Catalog, gen_catalog(), ...)`: carrega `Catalog` via `insert_catalog/3`, snapshot `Before = ets:tab2list(?ETS_TABLE)` e `loaded_catalogs()`, faz `exit(whereis(erli18n_server), kill)`, espera o `'DOWN'`, sincroniza com o supervisor até `is_pid(whereis(erli18n_server))` com PID **novo**, e assere `ets:tab2list(?ETS_TABLE) =:= Before` **e** `loaded_catalogs() =:= LoadedBefore` **e** que cada `lookup_*` devolve o mesmo valor de antes. Invariante: *o estado do catálogo sobrevive a um crash do worker*. Sob o código atual este property **falha** no primeiro shrink (`Before = [_|_]`, `After = []`); sob a correção ele passa.
- **Statem (`proper_statem`)** — modelo com comandos `{load, D, L}`, `{unload, D, L}`, `{lookup, D, L, ...}` e um comando `{kill_worker}`; o modelo abstrato **não** zera o estado em `kill_worker` (a propriedade é que o crash é transparente). Reutiliza o gerador de catálogos de `erli18n_lookup_props.erl`. Integra em `test/erli18n_fuzz_SUITE.erl` como novo case (`fuzz_table_survives_worker_crash`) com `numtests` >= 200, alinhado ao piso de CI da §6.2.
- **CT determinístico** — em `erli18n_server_SUITE`, adicionar `catalog_survives_worker_kill/1`: carrega `fr Hello->Bonjour`, `exit(Pid, kill)`, aguarda restart, assere `{ok,<<"Bonjour">>}` ainda retornado e `loaded_catalogs() =/= []`. É o gêmeo CT da reprodução ao vivo desta seção.

**Por que é estrutural:**
A correção **remove a classe de crash inteira**, não um gatilho específico. Hoje, *qualquer* término do `erli18n_server` ⇒ perda total dos catálogos — o estado está acoplado ao PID que mais falha (o único writer). Ao separar **propriedade** (dono imutável e longevo) de **mutação** (worker que pode crashar), e ao usar o mecanismo nativo `heir`+`give_away`+`ETS-TRANSFER` sob `rest_for_one` com ordenação dono→worker, o ciclo de vida do catálogo passa a depender apenas do dono — um processo que não muta nada e cuja superfície de falha é mínima. O custo de recuperação após crash do worker sai de **O(número de catálogos)** recargas (re-ler/re-parsear/re-compilar cada `.po` do disco) para **O(1)** (a tabela física é repassada intacta, zero recarga). Não é workaround nem retry: é a correção da raiz (acoplamento estado↔processo-mutante) usando exatamente o idioma OTP previsto para isso.

---

### 11. 🟠 Escapes \xHH/\OOO emitem bytes inválidos pós-gate UTF-8

**Local:** `src/erli18n_po.erl`
- `parse/2` — `src/erli18n_po.erl:108-125` (extrai charset, transcodifica o **corpo inteiro** uma vez via `normalize_input/2` na linha 117, e **descarta** o charset — nunca o repassa para `do_parse/2`).
- `normalize_input/2` — `src/erli18n_po.erl:351-374` (o *gate* UTF-8: roda sobre os bytes crus do corpo, **antes** da decodificação de escapes).
- `decode_escape/1` (despacho hex/octal) — `src/erli18n_po.erl:933-936`.
- `decode_hex_escape/3` — `src/erli18n_po.erl:942-953` (linha 951: `{ok, <<Byte>>, R}` injeta o byte cru).
- `decode_octal_escape/3` — `src/erli18n_po.erl:955-961` (linha 960-961: `{ok, <<Byte>>, R}` injeta o byte cru).
- `decode_quoted_string/1` + `decode_chars/2` — `src/erli18n_po.erl:883-907` (concatenam o byte cru no campo via `bins_to_binary/1` sem reconsiderar charset).
- Quatro *call sites* do decoder: `collect_header_msgstr/2` (`:222`), `consume_continuations/2` (`:245`), `parse_lines/4` continuação (`:469`) e `handle_string_field/6` (`:481`).

**Causa-raiz:**
A arquitetura do parser tem **duas fases que deveriam compartilhar o charset, mas não compartilham**:

1. **Fase de gate/transcodificação (uma vez, no corpo inteiro).** Em `parse/2:117`, `normalize_input(Stripped, Charset)` valida/transcodifica todo o corpo `Charset -> utf8` (`:351-374`). Para `utf8` ela *garante* que a saída é UTF-8 válido (`unicode:characters_to_binary(Bin, utf8, utf8)`); para `latin1` ela transcodifica byte 0xE9 → `<<195,169>>` etc. Após essa linha o charset **é jogado fora**: `do_parse/2` recebe só `Utf8Bin` e nunca vê `Charset`.

2. **Fase de decodificação de escapes (por campo, tarde).** `decode_escape/1` despacha `\x`/octal para `decode_hex_escape/3`/`decode_octal_escape/3`, que fazem `Byte = binary_to_integer(Acc, 16|8)` e retornam **`{ok, <<Byte>>, R}`** (`:951`, `:960-961`) — o byte é *spliced* cru no campo, **depois** do gate. Como o gate já passou, ninguém revalida nem transcodifica esse byte.

Consequências, ambas confirmadas ao vivo:

- **Catálogo `charset=UTF-8`:** `\xFF` (ou octal `\377`) injeta `<<255>>` num campo que se declara UTF-8 → a tradução vira UTF-8 **inválido**, mas `parse/2` ainda retorna `{ok, _}`. O gate UTF-8 da fase 1 torna-se uma **garantia falsa**.
- **Catálogo `charset=ISO-8859-1`:** quebra a semântica de charset. Um byte *natural* 0xE9 é corretamente transcodificado (fase 1) para `<<195,169>>`, mas o escape `\xFF` — que em gettext significa o **codepoint** U+00FF (porque o lexer empilha o byte cru e a *fase de conversão* transcodifica a string inteira `latin1->utf8`, resultando `<<195,191>>`) — é emitido como `<<255>>` cru, **driblando inteiramente o transcode charset→UTF-8**.

O defeito existe porque o `Byte` decodificado é, conceitualmente, **um byte no espaço de código do charset declarado**, mas o código o trata como **um byte UTF-8 já pronto**. Os dois só coincidem para ASCII (`\x41`='A', `\101`='A' — exatamente o que o teste `hex_and_octal_escapes/1` exercita em `:529-538`, que por isso nunca pega o bug).

**Evidência:** Reproduções ao vivo em OTP 28.4.3 (`rebar3 compile` + `erl -pa _build/default/lib/erli18n/ebin`).

*(1) Catálogo UTF-8 com `msgstr "x\xFFy"`:*
```
UTF-8 catalog translation bytes: <<120,255,121>>   %% 3 bytes, NÃO é UTF-8 válido
header charset=utf8                                %% garantia FALSA
string:length/1      => {error,{badarg,<<"ÿy">>}}
string:uppercase/1   => {error,{badarg,<<"ÿy">>}}
unicode:characters_to_binary/3 => {error,<<"x">>,<<"ÿy">>}
octal \377 translation bytes: <<120,255,121>>      %% caminho octal idêntico
```
`parse/2` devolve `{ok, _}`; o crash `error:badarg` acontece **a jusante**, no consumidor web, em qualquer operação unicode-aware — exatamente a classe de defeito que o gate deveria impedir.

*(2) Catálogo ISO-8859-1, `msgstr` com byte natural 0xE9 (é) seguido do escape `\xFF` e `z`:*
```
header charset=latin1
latin1 translation bytes: <<195,169,255,122>>   %% é=195,169 (OK) | \xFF=255 (CRU) | z=122
esperado (gettext):       <<195,169,195,191,122>>  %% \xFF deveria ser U+00FF=195,191
string:length/1 => {error,{badarg,<<"ÿz">>}}
```
O byte natural transcodifica; o escape não. Mistura válido+inválido no **mesmo** campo — prova de que o caminho do escape dribla o transcode da fase 1.

*Paridade GNU gettext (confirmada na fonte do lexer `read-po-lex.c`):* `control_sequence()` calcula o valor do escape e o anexa como **um único byte cru** (`buf[bufpos++] = control_sequence(ps)`), e a **transcodificação charset→UTF-8 ocorre numa fase separada sobre a string inteira**. Logo, para catálogos não-UTF-8, gettext produz U+00FF→`<<195,191>>` (erli18n diverge, emitindo `<<255>>`); para catálogos UTF-8, msgfmt valida e **rejeita** byte inválido ("invalid multibyte sequence") em vez de armazenar lixo silenciosamente. A correção abaixo replica *exatamente* esse modelo de duas fases.

*Validação do design do fix (protótipo executado em `/tmp`):*
```
latin1  \xFF        => {ok,<<195,169,195,191,122>>}     %% paridade gettext recuperada
utf8    \xC3\xBF    => {ok,<<120,195,191,121>>}         %% multi-byte legítimo preservado
utf8    \xFF (só)   => {error,{escape_invalid_utf8,<<"ÿ">>}}   %% erro estruturado, nada de lixo
ascii   \xFF        => {error,{escape_out_of_charset,us_ascii,255}}
ascii   \x41        => {ok,<<"A">>}                      %% teste atual continua passando
```

**Solução estrutural:**
Tratar a decodificação de escape como a **fonte de bytes no espaço de código do charset declarado**, e mover a transcodificação charset→UTF-8 para **depois** da decodificação de cada campo — espelhando o lexer do GNU gettext ("empilha bytes crus, depois converte a string inteira"). Em concreto:

1. **Threadar o charset** de `parse/2` → `do_parse/3` → `parse_lines/5` → cada *call site* do decoder. O charset já é conhecido em `parse/2:116`; basta não descartá-lo.
2. **Reformular `decode_chars/3` para emitir chunks tagueados** em vez de concatenar bytes cegamente: texto literal (já UTF-8, pois sobreviveu intacto ao gate da fase 1 — `\`,`x`,dígitos são ASCII) vira `{utf8, Bin}`; bytes de escape `\xHH`/`\OOO` viram `{raw, byte()}`.
3. **Pós-passe `reassemble_field/2`**: agrupa *runs* contíguos de bytes `{raw,_}` e transcodifica cada run **uma vez** pelo charset declarado (`latin1`/`us_ascii`/`utf8`), intercalando com os chunks `{utf8,_}`. Agrupar runs é essencial: em catálogo UTF-8 um codepoint multi-byte é escrito como escapes **consecutivos** (`\xC3\xBF` = U+00FF) e tem de ser validado em conjunto.
4. **Erro estruturado** quando o byte do escape é inválido no charset (lone `\xFF` em UTF-8; byte ≥0x80 em US-ASCII), em vez de devolver `{ok, _}` com bytes inválidos. Isso restaura o gate como garantia *verdadeira* e dá paridade com a rejeição do msgfmt.

A mudança de tipo é mínima e justificada: estende-se `parse_error()` com dois construtores (`{invalid_escape_charset, ...}` e `{escape_invalid_utf8, ...}`) emitidos sob o já existente `{syntax_error, Line, Reason}` (o envelope `{syntax_error, Line, Reason}` não muda de forma — `Reason` apenas ganha novos valores, todos `term()`). Nenhuma assinatura pública (`parse/1,2`, `parse_file/1,2`, `dump/1`) muda de aridade ou de tipo de retorno; `header_map()`, `entry()`, `parsed_catalog()` ficam idênticos.

```erlang
%% ============================================================
%% TIPOS — adições mínimas, eqwalizer-friendly
%% ============================================================

%% Charset normalizado já existente em header_map(); reusado aqui.
-type charset() :: utf8 | latin1 | us_ascii.

%% Chunk produzido pela decodificação de um campo, ANTES do
%% transcode charset->utf8. `{utf8, Bin}` já é UTF-8 válido (texto
%% literal que sobreviveu intacto ao gate de normalize_input/2, pois
%% as sequências de escape são compostas só de bytes ASCII). `{raw, B}`
%% é UM byte no espaço de código do charset declarado, produzido por
%% \xHH ou \OOO — exatamente como o lexer do GNU gettext empilha.
-type chunk() :: {utf8, binary()} | {raw, byte()}.

%% Estende parse_error() (src/erli18n_po.erl:59-64) com os erros
%% estruturados de escape. Continuam viajando dentro do envelope
%% {syntax_error, Line, Reason} já existente — Reason apenas ganha
%% novos valores term().
-type escape_error() ::
      {invalid_escape_charset, charset(), Byte :: byte()}
    | {escape_invalid_utf8, Rest :: binary()}
    | {escape_incomplete_utf8, Rest :: binary()}.

%% ============================================================
%% parse/2 — repassa o charset em vez de descartá-lo (linha 117)
%% ============================================================

-spec parse(binary(), parse_opts()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
parse(Bin, Opts) when is_binary(Bin), is_map(Opts) ->
    Stripped = strip_bom(Bin),
    case extract_header_charset(Stripped) of
        {ok, Charset} ->
            case normalize_input(Stripped, Charset) of
                {ok, Utf8Bin} ->
                    %% MUDANÇA: Charset agora flui para do_parse/3.
                    do_parse(Utf8Bin, Charset, Opts);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% ============================================================
%% do_parse/3 e parse_lines/5 — carregam o charset no estado global
%% ============================================================

-spec do_parse(binary(), charset(), parse_opts()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
do_parse(Utf8Bin, Charset, Opts) ->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    Lines = split_lines(Utf8Bin),
    %% #pst{} ganha o campo `charset`; default utf8 mantém retrocompat
    %% para quaisquer chamadas internas legadas.
    St0 = #pst{include_fuzzy = IncludeFuzzy, charset = Charset},
    case parse_lines(Lines, 1, fresh_entry(1), St0) of
        {ok, #pst{header = undefined, entries = Entries}} ->
            {ok, #{header => empty_header(),
                   entries => lists:reverse(Entries)}};
        {ok, #pst{header = Header, entries = Entries}} ->
            {ok, #{header => Header,
                   entries => lists:reverse(Entries)}};
        {error, _} = Err ->
            Err
    end.

%% Registro #pst{} (src/erli18n_po.erl:90-96) ganha um campo:
%%   charset = utf8 :: charset()

%% ============================================================
%% Call sites do decoder — passam St (ou o charset) ao decoder.
%% Exemplo em handle_string_field/6 (era :480-487); idem para
%% collect_header_msgstr/2, consume_continuations/2 e a continuação
%% em parse_lines/4 (agora /5).
%% ============================================================

handle_string_field(Field, Content, Rest, Ln, Cur, St) ->
    case decode_quoted_string(Content, St#pst.charset) of
        {ok, Bin} ->
            Cur2 = set_field(Field, Bin, Cur),
            parse_lines(Rest, Ln + 1, Cur2, St);
        {error, Reason} ->
            {error, {syntax_error, Ln, Reason}}
    end.

%% ============================================================
%% Decoder — emite chunks tagueados e faz o transcode no fim
%% ============================================================

-spec decode_quoted_string(binary(), charset()) ->
    {ok, binary()} | {error, term()}.
decode_quoted_string(<<$", Rest/binary>>, Charset) ->
    case decode_chars(Rest, []) of
        {ok, Chunks} -> reassemble_field(Chunks, Charset);
        {error, _} = E -> E
    end.

%% decode_chars/2 agora acumula [chunk()] (em ordem reversa, como
%% antes) em vez de [binary()].
-spec decode_chars(binary(), [chunk()]) ->
    {ok, [chunk()]} | {error, term()}.
decode_chars(<<$">>, Acc) ->
    {ok, Acc};
decode_chars(<<$", Rest/binary>>, Acc) ->
    case is_only_trailing_ws(Rest) of
        true -> {ok, Acc};
        false -> {error, content_after_close_quote}
    end;
decode_chars(<<$\\, Rest/binary>>, Acc) ->
    case decode_escape(Rest) of
        {ok, Chunk, Rest2} -> decode_chars(Rest2, [Chunk | Acc]);
        {error, _} = E -> E
    end;
decode_chars(<<C/utf8, Rest/binary>>, Acc) ->
    %% Texto literal já é UTF-8 válido (gate da fase 1). Mantemos o
    %% codepoint como chunk {utf8, _}.
    decode_chars(Rest, [{utf8, <<C/utf8>>} | Acc]);
decode_chars(<<>>, _Acc) ->
    {error, unterminated_string};
decode_chars(<<_Byte, _/binary>>, _Acc) ->
    {error, invalid_utf8}.

%% decode_escape/1 — escapes "literais" (\n \t \" ...) viram {utf8,_}
%% (são ASCII, UTF-8 trivial). Apenas \xHH/\OOO viram {raw, Byte}.
-spec decode_escape(binary()) -> {ok, chunk(), binary()} | {error, term()}.
decode_escape(<<$n, R/binary>>) -> {ok, {utf8, <<$\n>>}, R};
decode_escape(<<$t, R/binary>>) -> {ok, {utf8, <<$\t>>}, R};
decode_escape(<<$r, R/binary>>) -> {ok, {utf8, <<$\r>>}, R};
decode_escape(<<$", R/binary>>) -> {ok, {utf8, <<$">>}, R};
decode_escape(<<$\\, R/binary>>) -> {ok, {utf8, <<$\\>>}, R};
decode_escape(<<$b, R/binary>>) -> {ok, {utf8, <<$\b>>}, R};
decode_escape(<<$f, R/binary>>) -> {ok, {utf8, <<$\f>>}, R};
decode_escape(<<$v, R/binary>>) -> {ok, {utf8, <<$\v>>}, R};
decode_escape(<<$a, R/binary>>) -> {ok, {utf8, <<7>>}, R};
decode_escape(<<$/, R/binary>>) -> {ok, {utf8, <<$/>>}, R};
decode_escape(<<$?, R/binary>>) -> {ok, {utf8, <<$?>>}, R};
decode_escape(<<$', R/binary>>) -> {ok, {utf8, <<$'>>}, R};
decode_escape(<<$x, R/binary>>) ->
    decode_hex_escape(R, <<>>, 0);
decode_escape(<<C, R/binary>>) when C >= $0, C =< $7 ->
    decode_octal_escape(R, <<C>>, 1);
decode_escape(<<C, _/binary>>) ->
    {error, {unknown_escape, C}};
decode_escape(<<>>) ->
    {error, dangling_backslash}.

%% \xHH e \OOO devolvem {raw, Byte} — o byte é interpretado mais tarde
%% no espaço de código do charset declarado (reassemble_field/2).
-spec decode_hex_escape(binary(), binary(), 0..2) ->
    {ok, {raw, byte()}, binary()} | {error, term()}.
decode_hex_escape(<<C, R/binary>>, Acc, N) when
    N < 2,
    ((C >= $0 andalso C =< $9) orelse
     (C >= $a andalso C =< $f) orelse
     (C >= $A andalso C =< $F))
->
    decode_hex_escape(R, <<Acc/binary, C>>, N + 1);
decode_hex_escape(R, Acc, _N) when byte_size(Acc) > 0 ->
    Byte = binary_to_integer(Acc, 16),
    {ok, {raw, Byte}, R};
decode_hex_escape(_, _, _) ->
    {error, invalid_hex_escape}.

-spec decode_octal_escape(binary(), binary(), 1..3) ->
    {ok, {raw, byte()}, binary()} | {error, term()}.
decode_octal_escape(<<C, R/binary>>, Acc, N) when
    N < 3, C >= $0, C =< $7
->
    decode_octal_escape(R, <<Acc/binary, C>>, N + 1);
decode_octal_escape(R, Acc, _N) ->
    Int = binary_to_integer(Acc, 8),
    %% Octal de 3 dígitos chega até 0777 (511). Em PO, \OOO é por
    %% definição um byte: clampar/validar 0..255. >255 é erro de
    %% formato (gettext interpreta no máximo 3 dígitos octais => byte).
    case Int =< 16#FF of
        true  -> {ok, {raw, Int}, R};
        false -> {error, {octal_escape_out_of_range, Int}}
    end.

%% ============================================================
%% reassemble_field/2 — A FASE 2 DO GETTEXT: transcodifica os runs
%% de bytes crus pelo charset, intercalando com texto utf8.
%% ============================================================

%% Recebe os chunks em ORDEM REVERSA (acumulador), como em todo o
%% resto do módulo; processamos invertendo uma vez.
-spec reassemble_field([chunk()], charset()) ->
    {ok, binary()} | {error, escape_error()}.
reassemble_field(ChunksRev, Charset) ->
    reassemble(lists:reverse(ChunksRev), Charset, [], []).

%% RawAcc acumula bytes crus contíguos (em ordem reversa); Out
%% acumula segmentos UTF-8 prontos (em ordem reversa).
-spec reassemble([chunk()], charset(), [byte()], [binary()]) ->
    {ok, binary()} | {error, escape_error()}.
reassemble([{raw, B} | Rest], Charset, RawAcc, Out) ->
    reassemble(Rest, Charset, [B | RawAcc], Out);
reassemble([{utf8, Bin} | Rest], Charset, RawAcc, Out) ->
    case flush_raw(RawAcc, Charset) of
        {ok, Flushed} ->
            reassemble(Rest, Charset, [], [Bin, Flushed | Out]);
        {error, _} = E ->
            E
    end;
reassemble([], Charset, RawAcc, Out) ->
    case flush_raw(RawAcc, Charset) of
        {ok, Flushed} ->
            {ok, iolist_to_binary(lists:reverse([Flushed | Out]))};
        {error, _} = E ->
            E
    end.

%% Transcodifica um run de bytes crus (charset-nativos) -> UTF-8.
-spec flush_raw([byte()], charset()) ->
    {ok, binary()} | {error, escape_error()}.
flush_raw([], _Charset) ->
    {ok, <<>>};
flush_raw(RawAccRev, Charset) ->
    Bytes = list_to_binary(lists:reverse(RawAccRev)),
    transcode_escape_bytes(Bytes, Charset).

-spec transcode_escape_bytes(binary(), charset()) ->
    {ok, binary()} | {error, escape_error()}.
transcode_escape_bytes(Bytes, latin1) ->
    %% Todo byte 0..255 é codepoint Latin-1 válido; latin1->utf8 nunca
    %% falha (mesmo contrato de normalize_input/2:366-374).
    Out = unicode:characters_to_binary(Bytes, latin1, utf8),
    true = is_binary(Out),
    {ok, Out};
transcode_escape_bytes(Bytes, us_ascii) ->
    %% US-ASCII: byte >=0x80 está fora do charset. gettext rejeitaria;
    %% nós emitimos erro estruturado em vez de bytes inválidos.
    case first_non_ascii(Bytes) of
        none -> {ok, Bytes};
        Bad  -> {error, {invalid_escape_charset, us_ascii, Bad}}
    end;
transcode_escape_bytes(Bytes, utf8) ->
    %% Catálogo UTF-8: o run de bytes crus DEVE ser UTF-8 válido (ex.
    %% \xC3\xBF = U+00FF). Lone \xFF -> erro estruturado, igual ao
    %% "invalid multibyte sequence" do msgfmt.
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Out when is_binary(Out) ->
            {ok, Out};
        {error, _Converted, Rest} ->
            {error, {escape_invalid_utf8, Rest}};
        {incomplete, _Converted, Rest} ->
            {error, {escape_incomplete_utf8, Rest}}
    end.

-spec first_non_ascii(binary()) -> none | byte().
first_non_ascii(<<>>) -> none;
first_non_ascii(<<B, _/binary>>) when B > 127 -> B;
first_non_ascii(<<_, R/binary>>) -> first_non_ascii(R).
```

Notas de integração eqwalizer/OTP:
- `decode_quoted_string/1` antigo (aridade 1) deixa de existir; todos os 4 *call sites* passam o charset. Se a aridade 1 for parte de algum teste interno, mantém-se um *shim* `decode_quoted_string(Bin) -> decode_quoted_string(Bin, utf8)` (utf8 = comportamento de catálogo já-UTF-8, idêntico ao legado para ASCII).
- `bins_to_binary/1` continua usado pelo dumper (`escape_string/2:1040`); o decoder migra para `iolist_to_binary/1` em `reassemble/4`, mas `bins_to_binary/2` permanece para o caminho do dump.
- O `Reason` dentro de `{syntax_error, Line, Reason}` é `term()`, então adicionar `escape_error()` não quebra o tipo `parse_error()` exportado; documenta-se em `:59-64`.

**Fontes:**
- https://www.erlang.org/doc/man/unicode.html — `unicode:characters_to_binary/3(Data, In, Out)` retorna `binary() | {error, binary(), RestData} | {incomplete, binary(), binary()}`; codificações válidas incluem `latin1` e `utf8`; é a API correta para transcodificar charset→UTF-8 e para validar UTF-8 (usada em `normalize_input/2` e no fix). Confirma assinatura atual (não confiar em memória).
- https://raw.githubusercontent.com/autotools-mirror/gettext/master/gettext-tools/src/read-po-lex.c — lexer do GNU gettext: `control_sequence()` calcula `\xHH`/`\OOO` e **anexa um único byte cru** (`buf[bufpos++] = control_sequence(ps)`); a conversão charset→UTF-8 ocorre numa **fase separada** sobre a string inteira. É a referência canônica que justifica o modelo de duas fases do fix (empilhar bytes crus por escape, transcodificar o campo no fim).
- https://www.gnu.org/software/gettext/manual/html_node/PO-Files.html — sintaxe de strings PO segue C, com `\xHH`/`\OOO` (sem `\u`/`\U`); fundamenta quais escapes existem e a paridade que devemos preservar.
- https://www.gnu.org/software/gettext/manual/html_node/Header-Entry.html — `Content-Type: ...; charset=` define o charset do catálogo; é o charset que o fix repassa e usa no transcode.
- https://github.com/php-gettext/Gettext/issues/131 e https://groups.google.com/g/django-users/c/zwXD1KuIYO0 ("invalid multibyte sequence") — evidência de que o msgfmt/leitores gettext **rejeitam** bytes inválidos no charset declarado em vez de armazená-los; valida nossa escolha de erro estruturado em vez de `{ok, _}` com lixo.
- https://datatracker.ietf.org/doc/html/rfc2978 — nomes de charset são case-insensitive (já respeitado em `classify_charset/1:338-349`); contextualiza a normalização do charset que alimenta o transcode.

**Trade-offs:**
- **Mudança de comportamento observável (intencional):** catálogos `charset=UTF-8` com `\xFF` lone — que hoje retornam `{ok, _}` com bytes inválidos — passam a retornar `{error, {syntax_error, Line, {escape_invalid_utf8, _}}}`. Isso é *mais* correto (alinha com msgfmt) mas pode "quebrar" catálogos malformados que antes "passavam". Mitigação: o erro é estruturado e carrega a linha; e o caso ASCII (a esmagadora maioria dos usos reais de `\xHH`) é inalterado.
- **Catálogo Latin-1 com `\xHH`:** agora produz UTF-8 diferente do atual (correto: `<<195,191>>` vs. atual `<<255>>`). Quem dependia (erroneamente) do byte cru verá saída diferente — mas a saída atual já era UTF-8 inválido.
- **Custo de alocação:** `decode_chars` passa a acumular tuplas `chunk()` em vez de binários, e `reassemble_field/2` faz um `lists:reverse/1` + `iolist_to_binary/1` por campo. Custo O(n) no tamanho do campo, dominado por `iolist_to_binary/1` que o caminho atual (`bins_to_binary/1`) já paga; o overhead extra é um *cons cell* por chunk. Para campos típicos (poucas dezenas a centenas de bytes) é desprezível; pela Erlang Efficiency Guide, construir via iolist e materializar uma vez é o idioma recomendado (evita concatenação binária quadrática).
- **Superfície de tipos:** +1 campo em `#pst{}`, +1 aridade em 4 funções internas, +2~3 construtores em `parse_error()`. Nenhuma API pública muda.

**Teste (PropEr):**
1. **Teste que hoje *chancela* o bug:** `erli18n_po_SUITE:hex_and_octal_escapes/1` (`test/erli18n_po_SUITE.erl:529-538`) só usa `\x41`/`\101` (ASCII), por isso **nunca exercita** o caminho `Byte >= 0x80`. Ele deve continuar verde (o fix preserva ASCII), mas é insuficiente — adicionar os casos não-ASCII abaixo.
2. **Novos casos unitários** em `erli18n_po_SUITE.erl`:
   - `hex_escape_high_byte_utf8_rejected/1`: catálogo UTF-8 + `msgstr "x\xFFy"` ⇒ `?assertMatch({error,{syntax_error,_,{escape_invalid_utf8,_}}}, parse(...))`.
   - `hex_escape_latin1_transcodes/1`: catálogo ISO-8859-1 + `\xFF` ⇒ tradução `=:= <<195,191>>` (U+00FF), e byte natural 0xE9 coexiste como `<<195,169>>`.
   - `hex_escape_utf8_multibyte_ok/1`: catálogo UTF-8 + `\xC3\xBF` ⇒ `<<195,191>>` (preserva paridade gettext para escapes UTF-8 legítimos).
   - `octal_escape_high_byte/1`: `\377` espelha `\xFF` em cada charset.
   - `ascii_escape_high_byte_rejected/1`: catálogo US-ASCII + `\xFF` ⇒ `{error,{syntax_error,_,{invalid_escape_charset,us_ascii,255}}}`.
3. **Propriedade nova** em `test/erli18n_po_props.erl` — `prop_parse_output_is_valid_utf8/0`: para todo catálogo gerado (incluindo escapes injetados, charset ∈ {utf8, latin1, us_ascii}), **se** `parse/2` ⇒ `{ok, Cat}`, **então** toda `translation()`/`msgid()`/`context()` em `entries` satisfaz `is_binary(unicode:characters_to_binary(B, utf8, utf8))`. Esta é a **invariante de fechamento** que o bug viola hoje: `parse` retorna `{ok,_}` com UTF-8 inválido. Estender o gerador `maybe_inject_escapes/2` (`:385-405`) para injetar também `\xHH`/`\OOO` com `HH ∈ [0x80,0xFF]` e ligá-lo a um gerador de charset no header.
4. **Fuzz (`erli18n_fuzz_SUITE` / `erli18n_po_fuzz.erl`):** o `prop_embedded_controls/0` (`:107-119`) já gera `0xFF`, mas só checa `no_crash` (`:373`) — que **não** detecta o bug, pois `parse` não crasha; o crash é a jusante. Reforçar: após `{ok, Cat}`, validar a invariante UTF-8 do item (3) sobre todos os campos (transformar `no_crash` num `no_crash_and_valid_output`). `prop_encoding_mismatch/0` (`:130-167`) ganha cobertura cruzada charset×escape de graça.
5. **Roundtrip:** `erli18n_po_props:prop_roundtrip_parse_dump/0` (`:67`) deve permanecer verde — o dumper (`escape_string/2:1036+`) opera sobre tradução já-UTF-8, e o fix garante que a tradução é UTF-8 válido, então `parse∘dump` continua fixpoint.

**Por que é estrutural:**
- **Remove uma classe inteira de crash a jusante.** Hoje `parse/2` pode emitir `translation()`/`msgid()` que **não** são UTF-8 válido apesar de `header.charset=utf8`; qualquer `string:length/1`, `string:uppercase/1`, `unicode:characters_to_binary/3` no consumidor estoura `error:badarg`. O fix transforma o tipo `translation()` numa garantia real ("sempre UTF-8 válido"), eliminando a classe de `badarg` na borda web — não trata um sintoma, fecha a invariante na fonte.
- **Corrige a raiz arquitetural** (charset descartado entre fase 1 e fase 2), restaurando o modelo de duas fases que o próprio GNU gettext usa: bytes de escape vivem no espaço de código do charset e são transcodificados junto com o resto do campo. Isso conserta `\xHH`, `\OOO`, catálogos latin1 e utf8 de uma só vez, em vez de remendar cada decodificador.
- **Converte falha silenciosa em erro estruturado e localizado** (`{syntax_error, Line, _}`), movendo a detecção de "depois, no runtime, longe da causa" para "no parse, com a linha exata" — paridade com a rejeição do msgfmt e com a filosofia *fail loud at the boundary* do resto do módulo (`normalize_input/2`).

---

### 12. 🟠 ~245 LOC de narrowing de ensure_error/file:posix só para o eqwalizer

**Local:** `src/erli18n_server.erl:432-681` — a árvore de helpers de *narrowing*:
- `narrow_ensure_result/1` — `:437-449`
- `classify_ensure_error/1` — `:451-465` (com o ramo morto `{load_failed, Reason}` em `:464`)
- `is_known_ensure_error/1` — `:470-485`
- `narrow_known_ensure_error/1` — `:490-521`
- `narrow_indices/1` — `:525-529`
- `narrow_file_error/1` — `:535-540`
- `narrow_posix/1` — `:542-641` (48 cláusulas; *catch-all* morto `error({unknown_posix_atom, Other})` em `:637-641`)
- `classify_plural_compile_error/1` — `:650-655`
- `is_known_plural_compile_error/1` — `:657-667`
- `narrow_plural_compile/1` — `:669-681` (*catch-all* `error({unknown_plural_compile_error, Other})` em `:680-681`)

Pontos de chamada: `ensure_loaded/4` (`:404-409`) e `reload/4` (`:425-430`). Origem real das respostas: `handle_call({ensure_loaded,...})` (`:778-817`) e `handle_call({reload,...})` (`:818-847`), que retornam apenas o resultado de `do_load/4` (`:883-921`) / `install_parsed/5` (`:968-1007`) ou o literal `{ok, already}` (`:806`).

Medição: o bloco `:432-681` tem **236 linhas não-vazias** (250 linhas brutas), **18,7% do módulo de 1263 linhas**, e concentra **106 ocorrências** de `narrow_*`/`classify_*`/`is_known_*`.

**Causa-raiz:** A causa não é defesa de runtime — é puramente o sistema de tipos. `gen_server:call/2,3` é especificado em OTP como:

```erlang
-spec call(server_ref(), term())            -> term().
-spec call(server_ref(), term(), timeout())  -> term().
```

O retorno é `term()` porque o `ServerRef` resolve o módulo de callback em runtime: o type-checker não sabe estaticamente qual `Module:handle_call/3` responde, logo não pode propagar o tipo do `Reply` do callback para o chamador (confirmado na doc stdlib v8.0). Sob o eqWAlizer (que o projeto adota — `rebar.config` puxa `eqwalizer_support` e o quality-gate roda `elp eqwalize-all`), `term()` é o **tipo topo**: ele aceita qualquer coisa, mas *passá-lo onde se espera um tipo concreto é um erro de tipo* (EEP-61 distingue explicitamente `term()` topo de `dynamic()` escape-hatch). Como `ensure_loaded/4` declara retornar `ensure_result()`, devolver o `term()` cru de `gen_server:call/2` falharia o eqWAlizer. Toda a árvore `:432-681` existe só para **reconstruir** o valor com construtores explícitos e guards, fazendo o solver inferir o membro preciso da união `ensure_result()`.

Três sintomas estruturais decorrem disso:
1. **Duplicação tripla de tipos.** `is_known_ensure_error/1`, `narrow_known_ensure_error/1` e o tipo `ensure_error()` (`:75-79`) re-listam a mesma união; `narrow_posix/1` enumera *todo* o conjunto `file:posix()` à mão (48 átomos). Cada nova forma de erro/posix precisa ser sincronizada em 2-3 lugares.
2. **Ramos de crash mortos.** O `term()` que chega de fato é sempre uma das formas que o próprio servidor constrói (mesmo nó, mesmo módulo, resposta síncrona). Logo `narrow_posix(Other) -> error({unknown_posix_atom, Other})` (`:637-641`) e `{load_failed, Reason}` (`:464`) **nunca disparam** — são código inalcançável que finge ser defesa-em-profundidade.
3. **Falta de spec na fonte.** `do_load/4` (`:883`) e `install_parsed/5` (`:968`) **não têm `-spec`**. Sob eqWAlizer gradual, funções sem spec retornam `dynamic()`; mesmo que `handle_call` propagasse, o tipo já chega impreciso na origem. A solução correta tipa a *origem*, não o destino.

**Evidência:**

*Medição ao vivo (OTP 28.4.3, projeto compila limpo com `rebar3 compile`).*

`elp` não está instalado nesta máquina, então a reprodução do eqWAlizer é por código+docs; o comportamento de runtime foi validado diretamente:

```
$ escript /tmp/narrow_repro.escript
read_file(nonexistent) = {error,enoent}
OTP 28
```

`file:read_file/1` só produz átomos `file:posix()` documentados (`enoent` aqui) — i.e. `do_load/4:887` nunca injeta um átomo fora da união, confirmando que o *catch-all* `narrow_posix(Other)` (`:637-641`) é morto. As respostas possíveis de `handle_call` são exaustivamente, por inspeção:

| Origem | Forma | Membro de `ensure_result()` |
|---|---|---|
| `:806` | `{ok, already}` | `{ok, already}` |
| `install_parsed:1006` | `{ok, length(Entries)}` | `{ok, non_neg_integer()}` |
| `do_load:887` | `{error, {file_error, Posix}}` | `{error, {file_error, file:posix()|...}}` |
| `do_load:890-891` | `{error, parse_error()}` (repasse de `erli18n_po:parse/2`) | `{error, parse_error()}` |
| `install_parsed:977` | `{error, {plural_compile_error, CompileErr}}` | `{error, {plural_compile_error, compile_error()}}` |

Nenhuma dessas formas é `{load_failed, _}` — portanto `classify_ensure_error/1:464` também é morto. Cobertura de teste: `grep` mostra que **nenhuma** das funções `narrow_*`/`classify_*` é chamada diretamente em `test/`; elas só são exercidas ponta-a-ponta via `erli18n_loader_SUITE` (`ensure_loaded_file_not_found`, `ensure_loaded_invalid_po`, `ensure_loaded_plural_compile_error`, etc.). Como os ramos mortos são inalcançáveis pela resposta real do servidor, **nenhum teste atual chancela o bug** — eles são código de cobertura impossível.

**Solução estrutural:** Trocar a árvore de ~245 LOC por **um cast tipado na fronteira**, exatamente o idioma que o eqWAlizer prescreve para "código inerentemente dinâmico" (message passing) — `eqwalizer:dynamic_cast/1`, cujo `-spec` oficial é `term() -> eqwalizer:dynamic()`, e `dynamic()` é simultaneamente sub e supertipo de todo tipo, logo flui para `ensure_result()` sem erro. O projeto já usa `eqwalizer:dynamic_cast/1` 40+ vezes em `test/`; isto apenas o estende ao runtime path. Mas o cast cego sozinho perderia a verificação na *origem*: a peça robusta é **dar `-spec` precisas a `do_load/4` e `install_parsed/5`**, de modo que o eqWAlizer prove `ensure_result()` no único lugar onde o valor é construído. O cast no chamador é então um *re-anúncio* trivial de um tipo já provado server-side, não uma reconstrução defensiva.

Para isolar a dependência de eqWAlizer em compilação normal (sem `eqwalizer_support` no profile default), encapsula-se o cast num único helper privado `call_ensure/1` com fallback de identidade via macro — mesmo padrão que o projeto já usa para `telemetry` opcional.

```erlang
%% ── No topo do módulo, junto aos demais -include/-define ───────────────
%% O helper `eqwalizer:dynamic_cast/1` (spec: term() -> eqwalizer:dynamic())
%% só existe no profile `test` (dep `eqwalizer_support`). Em compilação
%% normal ele é identidade. Mesma estratégia de degradação suave usada para
%% a dep opcional `telemetry` (ver erli18n_telemetry.erl). `dynamic()` é sub
%% e supertipo de todo tipo, então o valor flui para ensure_result() sem
%% erro de tipo — e a prova real do tipo é feita na ORIGEM (do_load/4 abaixo).
-ifdef(EQWALIZER).
-define(AS_DYNAMIC(X), eqwalizer:dynamic_cast(X)).
-else.
-define(AS_DYNAMIC(X), (X)).
-endif.

%% ── ensure_loaded/4 (substitui :404-409) ──────────────────────────────
-spec ensure_loaded(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
ensure_loaded(Domain, Locale, PoPath, Opts) when
    is_atom(Domain), is_binary(Locale), is_map(Opts)
->
    call_ensure({ensure_loaded, Domain, Locale, PoPath, Opts}).

%% ── reload/4 (substitui :425-430) ─────────────────────────────────────
-spec reload(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
reload(Domain, Locale, PoPath, Opts) when
    is_atom(Domain), is_binary(Locale), is_map(Opts)
->
    call_ensure({reload, Domain, Locale, PoPath, Opts}).

%% ── Único ponto de fronteira (substitui TODO o bloco :432-681) ─────────
%% A resposta de gen_server:call/2 é term() porque o ServerRef resolve o
%% módulo de callback em runtime (OTP stdlib gen_server). Para erli18n a
%% chamada é sempre same-node, same-module, síncrona: handle_call/3 só
%% emite ensure_result() (provado em do_load/4). Re-anunciamos esse tipo
%% via um único dynamic_cast — o idioma eqWAlizer para message passing.
-spec call_ensure(
    {ensure_loaded | reload, domain(), locale(), file:filename(), opts()}
) -> ensure_result().
call_ensure(Request) ->
    ?AS_DYNAMIC(gen_server:call(?MODULE, Request)).
```

A prova de tipo migra para a origem, onde é barata e exata. `do_load/4` e `install_parsed/5` recebem `-spec` precisas (atualmente ausentes em `:883` e `:968`); o `handle_call` passa a poder declarar o retorno sem reconstrução:

```erlang
%% ── do_load/4 (adiciona -spec em :883; corpo inalterado) ───────────────
%% Constrói diretamente um ensure_result() SEM o membro {ok, already}
%% (esse é decidido em handle_call no fast-path idempotente) e SEM
%% {load_failed, _} (nunca emitido pelo pipeline). Com esta spec o
%% eqWAlizer prova a união na própria fonte; o chamador não precisa
%% reclassificar nada.
-spec do_load(domain(), locale(), file:filename(), opts()) ->
    {ok, non_neg_integer()}
    | {error, erli18n_po:parse_error()}
    | {error, {plural_compile_error, erli18n_plural:compile_error()}}.
do_load(Domain, Locale, PoPath, Opts) ->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    case file:read_file(PoPath) of
        {error, Posix} ->
            %% file:read_file/1 -> {error, file:posix()|badarg|terminated
            %% |system_limit}; parse_error() inclui {file_error, _} com
            %% exatamente essa união (erli18n_po:file_read_error()).
            {error, {file_error, Posix}};
        {ok, Bin} ->
            case erli18n_po:parse(Bin, #{include_fuzzy => IncludeFuzzy}) of
                {error, _} = E ->
                    E;
                {ok, Parsed} ->
                    maybe_emit_fuzzy_skip(
                        Domain, Locale, Bin, IncludeFuzzy, Parsed
                    ),
                    install_parsed(
                        Domain, Locale, PoPath, IncludeFuzzy, Parsed
                    )
            end
    end.

%% ── install_parsed/5 (adiciona -spec em :968; corpo inalterado) ────────
-spec install_parsed(
    domain(), locale(), file:filename(), boolean(), erli18n_po:parsed_catalog()
) ->
    {ok, non_neg_integer()}
    | {error, {plural_compile_error, erli18n_plural:compile_error()}}.
install_parsed(Domain, Locale, PoPath, IncludeFuzzy, Parsed) ->
    %% corpo idêntico ao atual :969-1007 — nenhuma mudança de lógica.
    %% Os dois braços de retorno já casam exatamente com a spec acima:
    %%   {error, {plural_compile_error, CompileErr}}   (:977)
    %%   {ok, length(Entries)}                          (:1006)
    install_parsed_impl(Domain, Locale, PoPath, IncludeFuzzy, Parsed).
```

`maybe_compile_plural/1` também ganha uma spec mínima que ancora a união, fechando o último ponto onde o tipo do `compile_error()` se diluiria em `term()`:

```erlang
-spec maybe_compile_plural(erli18n_po:header_map()) ->
    {ok, erli18n_plural:plural_compiled() | fallback}
    | {error, erli18n_plural:compile_error()}.
maybe_compile_plural(#{plural_forms := <<>>}) ->
    {ok, fallback};
maybe_compile_plural(#{plural_forms := PluralRaw}) ->
    case erli18n_plural:compile(PluralRaw) of
        {ok, _} = OK -> OK;
        {error, _} = E -> E
    end.
```

Resultado: as funções `narrow_ensure_result/1`, `classify_ensure_error/1`, `is_known_ensure_error/1`, `narrow_known_ensure_error/1`, `narrow_indices/1`, `narrow_file_error/1`, `narrow_posix/1`, `classify_plural_compile_error/1`, `is_known_plural_compile_error/1` e `narrow_plural_compile/1` são **removidas integralmente** (`:432-681`). O módulo cai de 1263 para ~1018 linhas. `header_state()`, `ensure_result()`, `ensure_error()`, `entry()`, `plural_compiled()` e `opts()` permanecem **idênticos** — a API pública e os tipos exportados não mudam.

**Fontes:**
- https://www.erlang.org/doc/apps/stdlib/gen_server.html — `gen_server:call/2,3` é `-spec call(server_ref(), term()[, timeout()]) -> term()`; o `Reply` é `term()` porque o módulo de callback é resolvido em runtime. Justifica por que o tipo do `handle_call` não chega ao chamador.
- https://www.erlang.org/eeps/eep-0061 (EEP-61, *The dynamic() type*) — distingue `term()` (topo: aceitar onde se espera tipo concreto é erro) de `dynamic()` (escape-hatch que flui nos dois sentidos); cita "reading from ETS, message passing, deserialization" como o caso de uso canônico. Sustenta a escolha de `dynamic_cast` em vez de reconstrução.
- https://github.com/WhatsApp/eqwalizer/blob/main/eqwalizer_support/src/eqwalizer.erl — `-spec dynamic_cast(term()) -> eqwalizer:dynamic().` com corpo identidade; doc: "I know that the value would be of the right type". É exatamente a primitiva que o cast usa.
- https://github.com/WhatsApp/eqwalizer/blob/main/docs/reference/gradual.md — "`dynamic()` é compatível com todo tipo e todo tipo é compatível com `dynamic()`"; funções sem spec retornam `dynamic()` em modo gradual. Sustenta tanto o cast quanto a necessidade das `-spec` na origem (`do_load/4`, `install_parsed/5`).
- https://www.erlang.org/doc/system/design_principles.html (OTP Design Principles, gen_server) — `handle_call/3` retorna `{reply, Reply, State}`; o `Reply` é o único valor que o chamador observa, e em chamada local same-node ele é determinístico. Sustenta o argumento de que a "defesa" no chamador é redundante.

**Trade-offs:**
- **Dependência de macro `EQWALIZER`.** O `-ifdef(EQWALIZER)` exige que o profile que roda `elp` defina a macro (via `{erl_opts, [{d, 'EQWALIZER'}]}` no profile de checagem). Custo: uma linha em `rebar.config`. Em troca, a compilação default não passa a depender de `eqwalizer_support` em runtime — o helper vira identidade pura. Alternativa mais simples (sem macro): chamar `eqwalizer:dynamic_cast/1` direto e mover `eqwalizer_support` para dep default; rejeitada para não acoplar runtime de produção a uma dep de tipagem.
- **Perde "validação de forma" no chamador.** Hoje, se um `handle_call` futuro retornasse uma forma fora de `ensure_result()`, `classify_ensure_error/1` a embrulharia em `{load_failed, _}`. Com o cast, ela passaria crua (até o primeiro pattern-match do consumidor falhar). Mitigação estrutural superior: a `-spec` em `do_load/4`/`install_parsed/5` faz o eqWAlizer **rejeitar em build** qualquer retorno fora da união — a verificação migra de runtime-na-borda-errada para compile-time-na-origem-certa. É estritamente mais forte: pega o defeito antes de rodar.
- **Confiança no "same-node".** O cast assume chamada local. Se um dia `erli18n_server` virar distribuído (chamada cross-node), a resposta continua sendo `ensure_result()` por contrato do callback — o cast permanece válido; só perderia a checagem estática se o callback divergisse, que é o mesmo risco que a `-spec` cobre.

**Teste (PropEr):**
- **Property nova em `test/erli18n_loader_props.erl`** (ou estendendo `erli18n_lookup_props.erl`): *round-trip de contrato* — gerar `.po` válidos/ inválidos com os geradores já existentes em `erli18n_po_props.erl`/`erli18n_po_fuzz.erl`, chamar `erli18n_server:ensure_loaded/4` e asseverar que o retorno **sempre** casa `{ok, non_neg_integer()} | {ok, already} | {error, ensure_error()}` — i.e. que o cast nunca deixa vazar forma fora de `ensure_result()`. Como os geradores produzem `term()` por design, usa-se `eqwalizer:dynamic_cast/1` no boundary do gerador (idioma já adotado em `erli18n_po_props.erl:75`).
- **`erli18n_fuzz_SUITE` / `erli18n_po_fuzz.erl`:** alimentar bytes arbitrários (incl. `\xFF`, charset inválido, `Plural-Forms` malformado, paths inexistentes) e verificar que cada caminho de erro real (`{file_error, _}`, `parse_error()`, `{plural_compile_error, _}`) é produzido **sem** passar por nenhuma reconstrução — confirmando que a tabela de origens (Evidência) é exaustiva e que os ramos `{load_failed, _}` e `unknown_posix_atom` eram de fato inalcançáveis.
- **`erli18n_loader_SUITE`:** os casos `ensure_loaded_file_not_found`, `ensure_loaded_invalid_po`, `ensure_loaded_unsupported_charset`, `ensure_loaded_plural_mismatch`, `ensure_loaded_plural_compile_error` continuam passando **inalterados** — são a rede de segurança comportamental que prova que a remoção do narrowing não muda nenhum valor de retorno observável.
- **Testes que chancelam o bug:** *nenhum* exercita `narrow_posix(Other)` ou `{load_failed, _}` — são código de cobertura impossível. Sua remoção elimina ~245 LOC sem perder cobertura real (a cobertura desses ramos sempre foi 0%).

**Por que é estrutural:** Muda a *classe* do problema, não trata o sintoma. (1) **Remove uma classe inteira de manutenção O(n) de tipos:** hoje cada novo átomo `posix` ou forma de `ensure_error()` exige edição sincronizada em 2-3 funções espelhadas; depois, a verdade do tipo vive numa única `-spec` na origem e o eqWAlizer força a consistência. A enumeração de 48 cláusulas de `narrow_posix/1` some — `file:posix()` deixa de ser re-listado à mão. (2) **Elimina uma classe de crash latente:** os dois *catch-all* `error(...)` inalcançáveis (`:641`, e o wrap `:464`) somem; não há mais código que finge defender contra estados impossíveis. (3) **Move a verificação para o lugar e o tempo certos:** de runtime-na-borda-de-leitura (frágil, redundante, sem teste) para compile-time-na-origem-de-escrita (eqWAlizer rejeita em build qualquer divergência), usando exatamente a primitiva — `dynamic_cast` — que a própria ferramenta documenta para fronteiras de message passing. O código de orquestração de load passa a ter o tamanho proporcional à sua lógica, não à dívida do type-checker.

---

### 13. 🟡 `do_unload_with_count` varre a tabela inteira para remover 1 catálogo

**Local:** `src/erli18n_server.erl:1148-1161` (`ets:select_delete`), chamado do unload (`:768`) e do reload (`:838`); tabela é `set` (`:726-732`).

**O que / por quê.** Remove um catálogo com `ets:select_delete` e match spec com `Ctx/Msgid/Index` em `'_'`. Como a tabela é `set`, o índice de hash **não** consegue sondar por *prefixo* `(D,L)` → `select_delete` **varre toda linha** → O(total de TODOS os catálogos), não O(do alvo). Cada reload (que chama `do_unload`) paga esse scan segurando o gen_server.

**Evidência (ao vivo).** Deletar um catálogo fixo de 5 linhas: T=10k → 300 µs, 100k → 5,5 ms, 500k → 42 ms, 2M → 204 ms (~linear em T); contraste `ets:lookup` full-key O(1) (0,08–0,10 µs).

**Solução estrutural.** Manter um índice secundário de chaves por `(D,L)` (compõe com o índice do Achado 7 e o `catalog_keys/2` do Achado 4) **ou** usar `ordered_set` com chaves prefixadas por `(D,L)` para deleção por range. O índice secundário é o mais barato e reusa a 2ª tabela já proposta.

```erlang
%% Reusar o erli18n_catalog_index para guardar o conjunto de chaves por catálogo,
%% ou um ordered_set keyed {D,L,...} permitindo ets:select_delete com range
%% em vez de full scan. Deleção passa a O(tamanho do catálogo alvo).
```

**Fontes.**
- <https://www.erlang.org/doc/apps/stdlib/ets.html> — `set` não sonda por prefixo de chave; `ordered_set` permite varredura por faixa.
- <https://www.erlang.org/doc/efficiency_guide/tablesdatabases> — escolha de tipo de tabela por padrão de acesso.

**Trade-offs.** Índice secundário = memória/escrita extra (já incorrida pelo Achado 7). `ordered_set` muda o tipo da tabela principal (impacto no caminho quente — medir). Severidade baixa porque `D`/`L` são concretos (não é cópia total), mas o scan é inevitável com o layout atual em `set`.

**Teste.** Benchmark de deleção mantém-se ~flat conforme T cresce (hoje cresce linear).

---

### 14. 🟡 `dump/1` perde `msgid_plural` silenciosamente

**Local:** `src/erli18n_po.erl:1005-1019` (cláusula plural: `PluralIdBin = dump_field(<<"msgid_plural">>, Msgid)` em `:1014`).

**O que / por quê.** O shape `entry/0` plural é `{plural, Ctx, Msgid, [{Index,Translation}]}` — **descarta** o texto da forma `msgid_plural`. Então `dump/1` não consegue reconstruí-lo e emite o `Msgid` singular no slot `msgid_plural`. Para uma API pública (`erli18n_po:dump/1`, usada para serializar catálogos), isso produz silenciosamente um `.po` com `msgid_plural` errado.

> Nuance: `parse(dump(Cat)).entries =:= Cat.entries` (verificado `true`) — a perda é só relativa ao `.po` **original**, não ao modelo em memória.

**Solução estrutural.** Estender o tipo `entry/0` plural para reter `msgid_plural` e emiti-lo em `dump_entry`.

```erlang
-type entry() ::
      {singular, context(), msgid(), translation()}
    | {plural, context(), msgid(), msgid_plural(), [{plural_index(), translation()}]}.
%% emit_entry/2 passa a capturar Cur#po_st.msgid_plural; dump_entry emite-o fielmente.
```

**Fontes.** <https://www.gnu.org/software/gettext/manual/html_node/PO-Files.html> — `msgid`/`msgid_plural` são campos distintos e ambos fazem parte da entrada.

**Trade-offs.** Mudança de tipo `entry/0` (impacto em `erli18n_server` que materializa entradas plural — migração mecânica). Aumenta levemente a memória por entrada plural.

**Teste.** Round-trip property: `parse(dump(parse(PoBin))) preserva msgid_plural` para `.po` com plurais reais (ru/pl/ar).

---

### 15. 🟡 Lone-CR (Mac clássico) não normalizado → erro de sintaxe espúrio

**Local:** `src/erli18n_po.erl:422-424` (`split_lines/1` só troca `\r\n` e depois split em `\n`).

**O que / por quê.** `split_lines/1` faz `binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global])` e split em `\n`. Só CRLF é dobrado; um arquivo com lone-CR (`0x0D`) vira uma linha gigante → o parser vê conteúdo após a aspas de fechamento → `{error,{syntax_error,1,content_after_close_quote}}`. O `msgfmt -c` aceita o mesmo arquivo (exit 0).

**Solução estrutural.** Normalizar também lone-`\r` para `\n` em `split_lines/1`.

```erlang
split_lines(Bin) ->
    N1 = binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]),
    N2 = binary:replace(N1, <<"\r">>, <<"\n">>, [global]),   %% lone-CR (Mac clássico)
    binary:split(N2, <<"\n">>, [global]).
```

**Fontes.** GNU `msgfmt -c` aceita lone-CR (paridade). <https://www.gnu.org/software/gettext/manual/html_node/PO-Files.html>.

**Trade-offs.** Uma substituição extra O(n). Nenhum `.po` legítimo CRLF/LF é afetado.

**Teste.** Catálogo de 2 entradas byte-idêntico parseia `{ok,_}` em LF, CRLF **e** lone-CR (hoje o último erra).

---

### 16. 🟡 `lookup_plural/5` exportado, sem guard, ignora seleção de forma

**Local:** `src/erli18n_server.erl:19-24` (export), `:168-174` (`lookup_plural/5` — índice cru, sem `evaluate`, sem guards), `:193-217` (`lookup_plural_form/5` — o ponto de entrada real, guardado).

**O que / por quê.** O server exporta `lookup_plural/5` **e** `lookup_plural_form/5`. O primeiro pega um `plural_index()` cru e faz `ets:lookup` direto **sem** avaliar `Plural-Forms`; o segundo é o real, que consulta o header e roda `evaluate/2`. Parecem sinônimos, mas `lookup_plural/5` exige que o chamador já saiba o índice da forma para N — exatamente o conhecimento que a lib existe para encapsular. Um consumidor passando a **contagem** N como índice obtém formas erradas **silenciosamente**. `lookup_plural/5` (e `lookup_singular/4`) também não têm os guards `is_atom`/`is_binary` que `lookup_plural_form/5` tem. Só é chamado internamente (`:211,214`).

**Solução estrutural.** **Parar de exportar** `lookup_plural/5` (mantê-lo interno) e adicionar guards consistentes.

```erlang
%% remover lookup_plural/5 do -export; manter só lookup_plural_form/5 público.
%% adicionar guards a lookup_singular/4 e lookup_plural/5 (internos):
lookup_plural(Domain, Locale, Context, Msgid, Index)
  when is_atom(Domain), is_binary(Locale),
       (Context =:= undefined orelse is_binary(Context)),
       is_binary(Msgid), is_integer(Index), Index >= 0 -> ...
```

**Fontes.** <https://www.erlang.org/doc/system/design_principles.html> — superfície de API mínima; encapsular conhecimento locale-específico.

**Trade-offs.** Mudança de API (remoção de export) — mas o consumo correto é via fachada `erli18n:ngettext`, então o impacto externo é nulo na prática.

**Teste.** `xref`/compilação confirmam nenhum uso externo; guards cobertos por testes de argumento inválido.

---

### 17. 🟡 Divergência recompila o header (2ª vez) + regra CLDR por carga

**Local:** `src/erli18n_server.erl:1039-1047` (`compute_divergence` passa o **mapa** do header, descartando o AST já compilado em `:975`); `src/erli18n_plural.erl:217-230` (`validate_against_cldr`), `:850-866` (`ast_equivalent/split_rule → compile/1` de novo), `:873-881` (`synthesise_cldr_rule`), `:823-831` (`lookup_locale` scan linear).

**O que / por quê.** `install_parsed` já compila o header via `maybe_compile_plural` (`:975`, guardando o AST), mas `compute_divergence/2` passa o **mapa** (não o AST) para `validate_against_cldr/2`, que num hit do CLDR **re-parseia a mesma regra** (2º compile), **e** sintetiza+compila a regra CLDR, **e** faz scans lineares de `cldr_data/0`. Uma carga compila o header ≥ 2×. **Acopla** a divergência ao bug O(n²) do Achado 2: uma expressão patológica é compilada **duas vezes**.

**Solução estrutural.** Passar o AST já compilado para a checagem de divergência (ou fazer `validate_against_cldr` aceitar regra compilada) e pré-computar/memoizar os ASTs do CLDR.

```erlang
%% validate_against_cldr/2 ganha uma forma que aceita o AST já compilado:
validate_against_cldr_ast(Locale, #{nplurals := N, expr := Ast}) ->
    case cldr_compiled(Locale) of                 %% ASTs CLDR pré-compilados (constante)
        undefined -> ok;
        #{nplurals := Nc, expr := Astc} ->
            case N =:= Nc andalso Ast =:= Astc of
                true -> ok;
                false -> {warning, {plural_divergence, Locale, ...}}
            end
    end.
%% compute_divergence passa PluralCompiled (de maybe_compile_plural), não o mapa do header.
```

**Fontes.** <https://cldr.unicode.org/index/cldr-spec/plural-rules>; <https://www.gnu.org/software/gettext/manual/html_node/Plural-forms.html>. PSD-004 (a divergência é só informativa).

**Trade-offs.** Pré-computar ASTs do CLDR (constante pequena, ~49 linhas). Impacto isolado é baixo, mas remove o acoplamento com o Achado 2 (compile duplo de expressão patológica).

**Teste.** Asserir que uma carga compila o header **uma** vez (instrumentar/contar); divergência continua correta para ru/fr/pt.

---

### 18. ⚪ `narrow_posix/1` catch-all transforma erro de arquivo em crash (latente)

**Local:** `src/erli18n_server.erl:637-641` (`narrow_posix(Other) -> error({unknown_posix_atom, Other})`); mesmo anti-padrão em `narrow_plural_compile/1` (`:680-681`).

**O que / por quê.** Quando `do_load` retorna `{error,{file_error,Posix}}`, o `narrow_posix` enumera ~47 átomos; qualquer átomo fora da lista cai em `error({unknown_posix_atom,_})`, **convertendo um erro de arquivo benigno estruturado num crash do chamador** — contradizendo o próprio comentário duas linhas acima. Hoje a lacuna é vazia (diff contra `file:posix()` do OTP 28 = `[]`), então é **latente** (um átomo posix futuro do OTP crasharia), não explorável agora.

**Solução estrutural.** Trocar o catch-all `error/1` por pass-through que retorna o átomo (ou `{file_error, unknown, Atom}`). **Resolvido naturalmente** pelo Achado 12 (remover toda a árvore de narrowing via um cast tipado elimina este branch morto).

```erlang
narrow_posix(Atom) when is_atom(Atom) -> Atom.   %% pass-through, nunca crash
```

**Fontes.** <https://www.erlang.org/doc/apps/kernel/file.html> — `file:posix()` é uma union aberta a adições futuras do OTP.

**Trade-offs.** Nenhum; remove um modo de crash latente.

**Teste.** Injetar um átomo posix sintético fora da lista → `{error,{file_error,_}}` estruturado, nunca EXIT.

---

### 19. ⚪ `classify_charset` rejeita encodings legados que o `msgfmt` aceita

**Local:** `src/erli18n_po.erl:338-349` (`classify_charset/1`).

**O que / por quê.** Aceita só `utf-8`/`utf8`, `iso-8859-1` (+aliases), `latin1`, `us-ascii`/`ascii`; tudo o mais → `{error,{unsupported_charset,Bin}}` que aborta o parse. Charsets reais comuns (windows-1252/cp1252, iso-8859-15, koi8-r, euc-jp) são rejeitados com erro duro, enquanto `msgfmt -c` os aceita. **Estreitamento deliberado e documentado** (PSD-002), fail-closed (erro estruturado, sem crash, catálogo ETS pré-existente intacto) — funciona como projetado; sinalizado **info** como limitação de drop-in/paridade.

**Solução estrutural (se desejado).** Transcodificar os encodings legados comuns via um equivalente a `iconv` (codepages → UTF-8) em vez de rejeitar. Erlang não tem iconv embutido; opções: tabela de codepage embutida para os 4–5 mais comuns, ou dep opcional. Manter o fail-closed para charsets genuinamente desconhecidos.

**Fontes.** <https://www.gnu.org/software/gettext/manual/html_node/Header-Entry.html> (charsets aceitos pelo gettext); `msgfmt -c` aceita cp1252/iso-8859-15/koi8-r/euc-jp.

**Trade-offs.** Tabelas de codepage adicionam superfície/manutenção; só vale se a compatibilidade drop-in com catálogos legados for objetivo. `windows-1252` literal é flagado como não-portável pelo próprio `msgfmt -c` (mas o alias canônico `CP1252` passa).

**Teste.** `.po` declarando `charset=ISO-8859-15` com bytes legados → transcode correto para UTF-8 (paridade com `msgfmt`).

---

## Plano de remediação priorizado

Por ondas, com dependências explícitas. **Wave 1 = violações de contrato `SECURITY.md` (segurança/disponibilidade).**

### Wave 1 — Segurança & disponibilidade (contrato violado) 🔴

| Achado | Fix | Dependências |
|--------|-----|--------------|
| **1** crash-DoS por lookup | avaliador total + clamp libintl + rejeição estática + guard no boundary | — |
| **2** compile O(n²) + sem bounds | `byte_size` em `skip_ws_st` + caps de bytes/profundidade | — |
| **9** bignum por lookup | reusa os caps do Achado 2 (+ node-count) | depende de **2** |
| **3** decode O(n²) | `iolist_to_binary(lists:reverse)` + `max_string_bytes` | — |
| **8** `binary_to_integer` ilimitado + `system_limit` cru | cap de dígitos + erro estruturado nos 3 sites | — |
| **5** `Content-Type` badmatch | fonte única de charset + site total | — |
| **11** escapes → UTF-8 inválido | re-validar/transcodificar pós-decode | — |

> Wave 1 fecha **todas** as violações de *"erros estruturados, nunca crashes silenciosos / crescimento ilimitado"*. Achados 1, 2, 3, 8 foram reproduzidos ao vivo; cada fix muda a **classe** (remove o crash / muda a complexidade), não mascara o sintoma.

### Wave 2 — Arquitetura OTP (escalabilidade & resiliência) 🟠

| Achado | Fix | Dependências |
|--------|-----|--------------|
| **6** trabalho no gen_server | mover read+parse+compile para o chamador; só inserts atômicos no server; `opts()` com `max_bytes`/`timeout` | usa o `stage_catalog` do **4** |
| **4** reload não-atômico | STAGE → insert-before-prune (swap atômico) | idealmente **junto com 10** (heir) |
| **10** ETS sem heir | dono/heir dedicado; server adota via `'ETS-TRANSFER'` | base para a durabilidade que **4** assume |
| **7** `tab2list` por carga → O(N²) | 2ª tabela de índice O(1); `ets:info(size)` | habilita **13** |
| **13** unload full-scan | índice secundário de chaves por `(D,L)` (reusa **7**/**4**) | depende de **7** |

> Ordem sugerida: **10** (heir) e **7** (índice) primeiro, pois **4** (swap atômico) e **6** (mover trabalho) se apoiam neles. **13** reusa as estruturas de **7**/**4**.

### Wave 3 — Correção/encoding/paridade & manutenção 🟡⚪

| Achado | Fix |
|--------|-----|
| **14** `dump/1` perde `msgid_plural` | estender `entry/0` plural (impacta materialização no server) |
| **15** lone-CR | normalizar `\r` em `split_lines/1` |
| **17** divergência recompila | passar AST compilado; pré-computar ASTs CLDR (desacopla de **2**) |
| **19** charsets legados | transcode opcional (cp1252/iso-8859-15/koi8-r/euc-jp) |
| **12** boilerplate de narrowing | um `dynamic_cast` no boundary (remove ~245 LOC) → **resolve 18** |
| **18** `narrow_posix` crash latente | pass-through (ou cai fora com **12**) |
| **16** `lookup_plural/5` exportado | despublicar + guards consistentes |

---

## Notas de método

- **Processo:** revisão multi-agente de ~4.200 LOC. Fase 1 — 6 lentes finder em paralelo (DoS de input não-confiável, complexidade/Big-O, OTP/concorrência, robustez, correção/paridade, API/tipos). Fase 2 — verificação **adversarial por achado** (cada finding passou por um cético que tentou refutá-lo e, quando viável, **reproduziu ao vivo** com `erl`/`rebar3` em OTP 28.4.3 / ERTS 16.3.1). Fase 3 — soluções estruturais fundamentadas em fontes oficiais (docs OTP `erlang.org`, Erlang Efficiency Guide, manual GNU gettext, spec CLDR, RFC 2045). Fase 4 — síntese.
- **Números:** 43 candidatos → 40 confirmados → **19 achados acionáveis + 1 lead refutado**. A maioria dos achados de severidade alta/média tem medições de reprodução ao vivo (citadas em cada seção).
- **Transparência operacional:** a fase de soluções/síntese sofreu (a) *rate-limit* transitório do servidor e (b) um agente que entrou em loop no `StructuredOutput` (achado de reestruturação OTP). 7 soluções de agentes foram aproveitadas na íntegra; as 12 restantes foram projetadas diretamente a partir dos achados verificados e das mesmas fontes oficiais. Isso **não** afeta a fase de achados (concluída e verificada).
- **Sem modificações:** nenhum arquivo-fonte foi alterado; nada foi commitado ou enviado. Este documento é o entregável.
