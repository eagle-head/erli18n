# API de Lookup

O modulo facade `erli18n` espelha a familia de macros do GNU gettext em C.
Esta pagina cobre as **quatro familias** de lookup — `gettext`, `ngettext`,
`pgettext`, `npgettext` — com suas assinaturas, o mapeamento para o gettext
C, as regras de fallback R1-R6 e o locale por processo.

## As quatro familias

| Familia | Proposito | Macro C analogo |
| --- | --- | --- |
| `gettext`   | Singular | `gettext` / `dgettext` / `dcgettext` |
| `ngettext`  | Plural | `ngettext` / `dngettext` / `dcngettext` |
| `pgettext`  | Singular contextual (`msgctxt`) | `pgettext` / `dpgettext` / `dcpgettext` |
| `npgettext` | Plural contextual | `npgettext` / `dnpgettext` / `dcnpgettext` |

### Tipos

```erlang
-type domain()       :: atom().
-type locale()       :: binary().
-type context()      :: undefined | binary().
-type msgid()        :: binary().
-type msgid_plural() :: binary().
-type translation()  :: binary().
```

## gettext — singular

```erlang
gettext(Msgid)                  -> translation().  %% R6
gettext(Domain, Msgid)          -> translation().
gettext(Domain, Msgid, Locale)  -> translation().
```

```erlang
%% Locale resolvido (process dict, senao default).
<<"Bonjour, monde">> = erli18n:gettext(my_domain, <<"Hello, world">>).

%% Locale explicito.
<<"Bonjour, monde">> =
    erli18n:gettext(my_domain, <<"Hello, world">>, <<"fr">>).
```

## ngettext — plural

```erlang
ngettext(Msgid, MsgidPlural, N)                 -> translation().
ngettext(Domain, Msgid, MsgidPlural, N)         -> translation().
ngettext(Domain, Msgid, MsgidPlural, N, Locale) -> translation().
```

`N` e um `integer()` arbitrario — aceita bignum e negativos;
`erli18n_plural:evaluate/2` e bignum-clean. A forma plural correta sai da
avaliacao do header `Plural-Forms` do `.po` ([ver Pluralizacao](/guide/pluralization)).

```erlang
<<"1 fichier">>   = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 1,  <<"fr">>).
<<"42 fichiers">> = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42, <<"fr">>).
```

## pgettext — singular contextual

```erlang
pgettext(Context, Msgid)                 -> translation().
pgettext(Domain, Context, Msgid)         -> translation().
pgettext(Domain, Context, Msgid, Locale) -> translation().
```

`Context` e `undefined | binary()`. O contexto (`msgctxt`) desambigua
homografos — a mesma string-fonte com significados diferentes.

```erlang
<<"Mai">>       = erli18n:pgettext(my_domain, <<"month">>, <<"May">>, <<"fr">>).
<<"peut-etre">> = erli18n:pgettext(my_domain, <<"verb">>,  <<"May">>, <<"fr">>).
```

::: warning Sem fallback context-aware
No miss (ou traducao vazia), `pgettext` cai para o `msgid` — ele **nao**
re-tenta com `Context = undefined`. Isso evita vazar silenciosamente a
traducao errada.
:::

## npgettext — plural contextual

```erlang
npgettext(Context, Msgid, MsgidPlural, N)                 -> translation().
npgettext(Domain, Context, Msgid, MsgidPlural, N)         -> translation().
npgettext(Domain, Context, Msgid, MsgidPlural, N, Locale) -> translation().
```

Combina contexto e plural; o fallback segue a regra R2 sobre o par
`msgid` / `msgid_plural` quando o lookup falha ou retorna vazio.

```erlang
T = erli18n:npgettext(my_domain, <<"email">>, <<"message">>, <<"messages">>, 3, <<"fr">>).
```

## Mapeamento gettext C (variantes d / dc)

Cada familia tem variantes `d` (domain-explicit) e `dc` (com categoria),
alinhadas com os nomes das macros do GNU gettext em C. Elas existem para
compatibilidade de codigo-fonte e sao **aliases** das funcoes base.

| erli18n | Macro C | Observacao |
| --- | --- | --- |
| `gettext/2` | `dgettext(domain, msgid)` | dominio explicito |
| `gettext/3` | `dcgettext(domain, msgid, LC_MESSAGES)` | categoria sempre `LC_MESSAGES` |
| `dgettext/2,3` | `dgettext` | alias de `gettext/2,3` |
| `dcgettext/3` | `dcgettext` | alias de `gettext/3` |
| `dngettext/4,5` | `dngettext` | alias de `ngettext/4,5` |
| `dcngettext/5` | `dcngettext` | alias de `ngettext/5` |
| `dpgettext/3,4` | `dpgettext` | alias de `pgettext/3,4` |
| `dcpgettext/4` | `dcpgettext` | alias de `pgettext/4` |
| `dnpgettext/5,6` | `dnpgettext` | alias de `npgettext/5,6` |
| `dcnpgettext/6` | `dcnpgettext` | alias de `npgettext/6` |

::: tip A categoria e sempre LC_MESSAGES
Em C, o argumento de categoria das macros `dc*` e um `int LC_MESSAGES`. Em
`erli18n` a categoria e sempre, implicitamente, `LC_MESSAGES` e **nao** e
modelada como parametro — nao modelamos `LC_NUMERIC` etc.
:::

## Regras de fallback R1-R6

Estas sao as regras de resolucao do lookup. Vem de BR-MIGRAR-001/002 e da
[PSD-003](/reference/psds).

| Regra | Onde aplica | Comportamento |
| --- | --- | --- |
| **R1** | `gettext` (singular) | Se o lookup retorna `{ok, T}` com `T =/= <<>>`, devolve `T`. Caso contrario (miss OU traducao vazia), cai no `msgid`. |
| **R2** | `ngettext` (plural) | No miss ou vazio: `N == 1` -> `msgid`; senao -> `msgid_plural`. Casa com a convencao C "Translating plural forms". |
| **R3** | `pgettext` (contextual) | Lookup com contexto explicito. No miss ou vazio, cai no `msgid`. **Sem** re-tentativa com `Context = undefined`. |
| **R4** | `npgettext` (contextual plural) | Contextual + plural. Fallback segue R2 sobre `msgid` / `msgid_plural`. |
| **R5** | resolucao de locale | `resolved_locale()`: usa o locale por processo se definido; senao cai no `default_locale/0` app-wide. |
| **R6** | aridade reduzida | `gettext(Msgid)` -> `gettext(textdomain(), Msgid, resolved_locale())`. Idem para as outras familias sem dominio/locale explicito. |

### O caso da traducao vazia (PSD-003)

`msgstr ""` num `.po` significa **"nao traduzido"**. O parser descarta essas
linhas, mas o runtime mantem um guard defensivo: uma traducao vazia
(`<<>>`) nunca chega a UI — o fallback (R1/R2) dispara como se fosse um
miss. Ver [PSD-003](/reference/psds).

```erlang
%% Sem catalogo carregado: R1 cai no proprio msgid.
<<"Hello, world">> = erli18n:gettext(<<"Hello, world">>).

%% Plural sem catalogo: R2 escolhe msgid ou msgid_plural por N.
<<"file">>  = erli18n:ngettext(<<"file">>, <<"files">>, 1).
<<"files">> = erli18n:ngettext(<<"file">>, <<"files">>, 42).
```

::: tip Fallback de N quando o header esta ausente
Se o catalogo nao traz header `Plural-Forms`, o lookup de plural usa o
default C/germanico: `N == 1` -> forma 0; senao -> forma 1. Ver
[Pluralizacao](/guide/pluralization).
:::

## Locale por processo (process dictionary)

Em vez de passar `Locale` em cada chamada, o locale corrente e **estado por
processo** guardado no process dictionary (convencao gettexter / ADR-0002).
Espelha o thread-local storage do libc gettext (`uselocale(3)`).

```erlang
%% Define o locale do processo atual (binario).
ok = erli18n:setlocale(<<"fr">>).

%% Le o locale corrente (undefined se nunca definido).
<<"fr">> = erli18n:which_locale().

%% As variantes sem locale agora resolvem via process dictionary.
<<"Bonjour, monde">> = erli18n:gettext(my_domain, <<"Hello, world">>).
```

::: warning O process dictionary NAO e herdado em spawn
O dicionario **nao** e herdado por `spawn/1`: cada novo processo comeca com
`which_locale() = undefined` e cai no `default_locale/0`. Se voce processa
requisicoes em processos efemeros, chame `setlocale/1` no inicio de cada um.
:::

### Defaults app-wide

```erlang
%% Locale default (fallback quando o processo nao definiu o seu). Default <<"en">>.
ok = erli18n:set_default_locale(<<"en">>).
<<"en">> = erli18n:default_locale().

%% Dominio default das variantes sem dominio. Default `default`.
ok = erli18n:textdomain(my_domain).
my_domain = erli18n:textdomain().
```

`default_locale/0` e `textdomain/0` saem de `application:get_env/2` (cache
no application controller, ~ns no hot path). Ambos validam o tipo na
fronteira: um valor mal configurado vira crash explicito em vez de surpresa
silenciosa downstream.

## Hot path: leitura lock-free

Os lookups (`gettext`, `ngettext`, ...) leem direto da ETS no **processo
chamador** — sem roundtrip ao `gen_server`. As escritas (load/reload/unload)
sao serializadas pelo dono da tabela. Assim nao ha gargalo de processo no
lado da leitura: 1 leitura de header + 1 leitura da entrada para plural; 1
leitura para singular.
