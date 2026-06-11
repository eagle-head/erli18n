# Pluralizacao

A pluralizacao em `erli18n` e governada pelo modulo `erli18n_plural`, que
compila a expressao C do cabeçalho `Plural-Forms:` de um `.po` num pequeno
AST e a avalia em runtime para escolher a forma plural de um dado `N`. E o
que sustenta `ngettext` / `npgettext`.

::: tip O header do .po e a fonte de verdade
Por [PSD-004](/reference/psds), o cabeçalho `Plural-Forms` do `.po` e sempre
a fonte-de-verdade em **runtime**. A tabela CLDR embutida e consultada
apenas no **load**, para emitir avisos de divergencia (informativos) e como
fallback quando o cabeçalho falta.
:::

## Plural-Forms

O cabeçalho tem a forma:

```
Plural-Forms: nplurals=N; plural=EXPR;
```

onde `EXPR` e uma expressao C sobre a variavel `n` que retorna o **indice da
forma plural** (`0`-based). Exemplos canonicos:

```
# Ingles / alemao (2 formas: singular vs. plural)
Plural-Forms: nplurals=2; plural=n != 1;

# Frances / portugues do Brasil (0 e 1 sao singular)
Plural-Forms: nplurals=2; plural=n > 1;

# Japones / chines (forma unica, degenerado — PSD-008)
Plural-Forms: nplurals=1; plural=0;

# Russo (3 formas: one / few / many)
Plural-Forms: nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2;
```

## Compilacao

`compile/1` faz parse da expressao num AST e valida. E um parser
recursivo-descendente proprio — sem Yecc, sem Leex, sem geracao dinamica de
codigo Erlang. Operadores seguem precedencia/associatividade de C, com
short-circuit honrado para `&&` e `||`.

```erlang
{ok, Compiled} = erli18n_plural:compile(<<"nplurals=2; plural=n != 1;">>).
%% Compiled :: #{nplurals := pos_integer(), expr := ast(), raw := binary()}
```

### Endurecimento fail-closed (entrada nao-confiavel)

Como o `.po` e entrada nao-confiavel (ADR-0003), `compile/1` roda
**fail-closed** e rejeita regras estaticamente faltosas ou patologicas com
`compile_error()` estruturado:

| Erro | Causa |
| --- | --- |
| `{syntax_error, Reason, Position}` | expressao mal-formada |
| `{missing_nplurals, _}` / `{missing_plural_expr, _}` | campo ausente |
| `{nplurals_out_of_range, _}` | `nplurals` fora de `[1, 1000]` |
| `{nplurals_too_many_digits, Digits, Max}` | run de digitos de `nplurals` acima do cap (anti-bignum) |
| `{unsafe_plural_rule, _}` | regra estaticamente garantida a faltar — divisao/modulo literal por zero, ou indice de forma constante provavelmente fora de `[0, nplurals)` |
| `{expr_too_long, Size, Max}` | expressao acima de 2048 bytes |
| `{expr_too_deep, Depth, Position}` | aninhamento acima de 64 |
| `{expr_too_complex, Nodes, Max}` | contagem de nos do AST acima do cap (anti-DoS de bignum) |

Os caps existem porque o parser corre sobre `.po` nao-confiavel; sem eles,
uma expressao patologica-mas-valida poderia tornar o compile
superlinear/ilimitado ou fazer cada lookup crescer um bignum `n^k`.

## Avaliacao em runtime: evaluate/2

`evaluate/2` recebe o bundle compilado e o `N`, e retorna o indice da forma.
E o **hot path** — roda no processo chamador em cada `ngettext` /
`npgettext`.

```erlang
0 = erli18n_plural:evaluate(Compiled, 1).    %% forma singular
1 = erli18n_plural:evaluate(Compiled, 42).   %% forma plural
```

### Totalidade: total + clamp

`evaluate/2` e **TOTAL** — nunca levanta excecao. Isso e essencial porque
roda no hot path por requisicao sobre regras vindas de input nao-confiavel.
Dois modos de falha que uma regra mal-formada poderia disparar sao
neutralizados aqui, espelhando o runtime do GNU libintl (`dcigettext.c`):

- **Divisao / modulo por zero** — um divisor zero e coagido a `0` (em vez de
  deixar `div`/`rem` levantar `badarith`).
- **Indice de forma fora de faixa** — clampado para a forma `0`, exatamente
  como o libintl faz (`if (index >= nplurals) index = 0;`).

O `-spec` e portanto honesto: o resultado e provavelmente
`non_neg_integer()` para todo `N` e todo AST.

```erlang
%% N negativo e aceito; a regra decide a propria semantica.
%% N bignum tambem (evaluate/2 e bignum-clean).
_ = erli18n_plural:evaluate(Compiled, -3).
```

::: tip evaluate_checked/2 para observar a anomalia
Quem quer **observar** a anomalia como dado, em vez de clampar
silenciosamente, usa `evaluate_checked/2`. Tambem total (nunca levanta),
mas reporta `{error, plural_eval_error()}`:

```erlang
{ok, Form}                                    = erli18n_plural:evaluate_checked(Compiled, 5).
{error, {division_by_zero, '/' | '%'}}        = erli18n_plural:evaluate_checked(Bad, 0).
{error, {form_out_of_range, Form, NPlurals}}  = erli18n_plural:evaluate_checked(Bad2, 7).
```
:::

### Conveniencia: plural_by_po_header/2

`plural_by_po_header/2` compila e avalia de uma vez. Re-faz parse a cada
chamada — use apenas pontualmente; no hot path, `compile/1` uma vez no load
e guarde o resultado.

```erlang
{ok, 1} = erli18n_plural:plural_by_po_header(<<"nplurals=2; plural=n != 1;">>, 42).
```

## Cobertura CLDR

`erli18n` embute um subconjunto das regras canonicas do CLDR
(`cldr-core/supplemental/plurals.json`), com **49 entradas de locale**
cobrindo as familias principais: germanica/romanica (`n != 1`), francesa
(`n > 1`), eslava de 3 formas, degenerada asiatica (forma unica) e o arabe
de 6 formas. A tabela completa esta na [Referencia de Plural-Forms & CLDR](/reference/plurals).

```erlang
%% Regra CLDR canonica para um locale (com fallback de regiao: fr_CA -> fr).
{ok, <<"n > 1">>} = erli18n_plural:cldr_rule(<<"fr">>).
undefined          = erli18n_plural:cldr_rule(<<"xx">>).
```

Locales nao listados caem na tag de lingua base via `cldr_rule/1`
(ex.: `fr_BE` -> `fr`). Aceita tanto `_` quanto `-` como separador (leniencia
BCP47).

::: tip Direcao v0.2+
A tabela e hard-coded inline na v0.1 (zero deps, controle byte-a-byte do que
embarca, facil de auditar — ao custo de sync manual a cada release CLDR).
A direcao para v0.2+ e gerar `priv/cldr_plurals.eterm` a partir do JSON
upstream via escript.
:::

## Divergencia informativa vs. CLDR

No **load** do catalogo, `erli18n` compara o AST do header `Plural-Forms`
com a regra CLDR canonica do locale. A comparacao e **estrutural sobre os
ASTs** — insensivel a whitespace e parenteses: `(n != 1)` casa com `n != 1`.

- Se forem estruturalmente equivalentes (ou o locale nao constar no CLDR), a
  validacao retorna `ok` — sem divergencia.
- Se divergirem de forma que afetaria a selecao de forma em runtime, retorna
  `{warning, {plural_divergence, Locale, HeaderRule, CldrRule}}`.

```erlang
ok = erli18n_plural:validate_against_cldr(<<"fr">>, <<"nplurals=2; plural=n > 1;">>).

{warning, {plural_divergence, <<"fr">>, _Hdr, _Cldr}} =
    erli18n_plural:validate_against_cldr(<<"fr">>, <<"nplurals=2; plural=n != 1;">>).
```

::: warning A divergencia e apenas informativa
Por [PSD-004](/reference/psds), o header do `.po` **sempre vence em runtime**.
A divergencia nunca bloqueia o load — ela so produz observabilidade: um
`?LOG_WARNING` do OTP logger e o evento de telemetria
`[erli18n, plural, divergence_warning]` (ver [Telemetry](/guide/telemetry)).
:::

O loader, que ja guarda o bundle compilado, usa
`validate_against_cldr_ast/2` para nao recompilar o header no caminho de
load (a versao baseada em binario, `validate_against_cldr/2`, e a entrada de
conveniencia para quem so tem o header bruto).
