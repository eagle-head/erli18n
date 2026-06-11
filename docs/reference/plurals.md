# Plural-Forms & CLDR

Referencia das regras de plural CLDR embutidas no `erli18n`. A tabela e um
subconjunto hard-coded do CLDR (`cldr-core/supplemental/plurals.json`),
vinda de `erli18n_plural:cldr_data/0` em `src/erli18n_plural.erl`.

Cada linha e `{Locale, NPlurals, ExprBin}`, onde `ExprBin` e a expressao
C-style de plural que, pareada com `nplurals=NPlurals`, produz a regra
canonica do CLDR para aquele locale. A tabela tem **49 entradas de locale**.

::: tip Como a tabela e usada
A tabela e consultada apenas no **load**, para emitir avisos de divergencia
informativos (e como fallback quando o header falta). O header `Plural-Forms`
do `.po` e sempre a fonte de verdade em runtime — ver
[Pluralizacao](/guide/pluralization) e [PSD-004](/reference/psds).

Locales nao listados caem na tag de lingua base via `cldr_rule/1`
(ex.: `fr_BE` -> `fr`). Aceita `_` e `-` como separador de regiao.
:::

## Germanica / Romanica — `n != 1` (2 formas)

Singular para `n == 1`, plural para todo o resto.

| Locale | nplurals | plural |
| --- | --- | --- |
| `en` | 2 | `n != 1` |
| `en_US` | 2 | `n != 1` |
| `en_GB` | 2 | `n != 1` |
| `de` | 2 | `n != 1` |
| `de_AT` | 2 | `n != 1` |
| `de_CH` | 2 | `n != 1` |
| `nl` | 2 | `n != 1` |
| `sv` | 2 | `n != 1` |
| `da` | 2 | `n != 1` |
| `no` | 2 | `n != 1` |
| `nb` | 2 | `n != 1` |
| `nn` | 2 | `n != 1` |
| `fi` | 2 | `n != 1` |
| `es` | 2 | `n != 1` |
| `es_MX` | 2 | `n != 1` |
| `es_ES` | 2 | `n != 1` |
| `it` | 2 | `n != 1` |
| `el` | 2 | `n != 1` |
| `bg` | 2 | `n != 1` |
| `hu` | 2 | `n != 1` |
| `tr` | 2 | `n != 1` |
| `he` | 2 | `n != 1` |
| `fa` | 2 | `n != 1` |
| `hi` | 2 | `n != 1` |
| `et` | 2 | `n != 1` |

## Familia francesa — `n > 1` (2 formas)

`0` e `1` sao singular; `2+` plural.

| Locale | nplurals | plural |
| --- | --- | --- |
| `fr` | 2 | `n > 1` |
| `fr_FR` | 2 | `n > 1` |
| `fr_CA` | 2 | `n > 1` |
| `pt` | 2 | `n > 1` |
| `pt_BR` | 2 | `n > 1` |
| `pt_PT` | 2 | `n != 1` |

::: tip pt vs. pt_PT
`pt` e `pt_BR` usam `n > 1`; `pt_PT` (portugues europeu) usa `n != 1`. As
linhas com regiao constam na tabela exatamente onde o CLDR diverge da tag
base.
:::

## Eslava de 3 formas (one / few / many)

| Locale | nplurals | plural |
| --- | --- | --- |
| `ru` | 3 | `n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2` |
| `uk` | 3 | `n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2` |
| `sr` | 3 | `n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2` |
| `hr` | 3 | `n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2` |
| `pl` | 3 | `n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2` |
| `cs` | 3 | `(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2` |
| `sk` | 3 | `(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2` |

## Outras regras de multiplas formas

| Locale | nplurals | plural |
| --- | --- | --- |
| `sl` | 4 | `n%100==1 ? 0 : n%100==2 ? 1 : n%100==3 || n%100==4 ? 2 : 3` |
| `ro` | 3 | `n==1 ? 0 : (n==0 || (n%100>0 && n%100<20)) ? 1 : 2` |

## Asiatica degenerada — forma unica

`nplurals=1; plural=0;` — uma unica forma para todo `N` ([PSD-008](/reference/psds)).

| Locale | nplurals | plural |
| --- | --- | --- |
| `ja` | 1 | `0` |
| `ko` | 1 | `0` |
| `vi` | 1 | `0` |
| `th` | 1 | `0` |
| `zh` | 1 | `0` |
| `zh_CN` | 1 | `0` |
| `zh_TW` | 1 | `0` |
| `zh_HK` | 1 | `0` |

## Arabe — 6 formas

| Locale | nplurals | plural |
| --- | --- | --- |
| `ar` | 6 | `n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5` |

## API relacionada

```erlang
%% Regra CLDR canonica para um locale (com fallback de regiao).
{ok, <<"n > 1">>} = erli18n_plural:cldr_rule(<<"fr">>).
undefined          = erli18n_plural:cldr_rule(<<"xx">>).

%% Compara um header .po contra a regra CLDR (validacao informativa).
ok = erli18n_plural:validate_against_cldr(<<"fr">>, <<"nplurals=2; plural=n > 1;">>).
```

::: tip Estrategia de versionamento da tabela
v0.1 usa Option A (hard-coded): zero deps, controle byte-a-byte do que
embarca, facil de auditar — ao custo de sync manual a cada release CLDR. A
direcao v0.2+ (Option C) e gerar `priv/cldr_plurals.eterm` a partir do JSON
upstream via escript.
:::
