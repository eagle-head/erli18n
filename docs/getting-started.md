# Getting Started

Este guia leva voce do zero ao primeiro `gettext` traduzido: instalar a
dependencia, iniciar a aplicacao, carregar um catalogo `.po` e fazer o
primeiro lookup.

`erli18n` exige **Erlang/OTP 25.3+** (o piso vem de `optional_applications`
e de APIs de inicializacao de supervisor introduzidas no 25.3).

## Instalacao

### Erlang (rebar3)

Adicione a dependencia ao `rebar.config`:

```erlang
{deps, [
    {erli18n, "~> 0.1"}
]}.
```

Para observabilidade via [`:telemetry`](https://github.com/beam-telemetry/telemetry)
(opcional — `erli18n` roda sem ela; os eventos so sao emitidos quando a
dependencia esta presente):

```erlang
{deps, [
    {erli18n, "~> 0.1"},
    {telemetry, "~> 1.3"}
]}.
```

### Elixir (Mix)

Adicione a dependencia a lista `deps/0` do seu `mix.exs`:

```elixir
defp deps do
  [
    {:erli18n, "~> 0.1"}
  ]
end
```

Com `:telemetry` opcional:

```elixir
defp deps do
  [
    {:erli18n, "~> 0.1"},
    {:telemetry, "~> 1.3"}
  ]
end
```

## Iniciar a aplicacao

`erli18n` e uma aplicacao OTP: o `gen_server` dono das tabelas ETS precisa
estar de pe antes de qualquer load ou lookup. Inicie-a (e suas dependencias)
no boot.

```erlang
{ok, _Started} = application:ensure_all_started(erli18n).
```

Em Elixir, declare `:erli18n` em `extra_applications` (ou deixe o Mix
iniciar via `deps`) e ela sobe automaticamente com a sua aplicacao:

```elixir
# mix.exs
def application do
  [
    extra_applications: [:erli18n]
  ]
end
```

## Primeiro gettext

Antes de carregar qualquer catalogo, o lookup faz **fallback para o
`msgid`** original. Isso significa que `gettext/1` sempre retorna algo
util, mesmo sem traducao carregada — perfeito para a lingua-fonte.

```erlang
%% Sem catalogo carregado: cai no fallback e devolve o proprio msgid.
%% msgid e sempre binario.
<<"Hello, world">> = erli18n:gettext(<<"Hello, world">>).
```

::: tip Tipos da API
- `domain` e um **atom** (ex.: `my_domain`).
- `locale`, `msgid` e a traducao retornada sao **binaries** (ex.: `<<"fr">>`, `<<"Hello, world">>`).
- O `N` de `ngettext` e um **integer** (aceita bignum e negativos).
:::

## Carregar um catalogo `.po`

Use `ensure_loaded/3` para carregar um catalogo para um par
`(dominio, locale)`. A operacao e atomica: faz parse do `.po`, compila a
expressao de plural, valida contra o CLDR e insere na ETS — tudo de uma vez.

```erlang
%% Domain = atom, Locale = binary, caminho = .po no filesystem.
ok = erli18n:ensure_loaded(my_domain, <<"fr">>,
    <<"priv/locale/fr/LC_MESSAGES/my_domain.po">>).
```

Voce tambem pode deixar `erli18n` resolver o caminho por convencao
(`<PrivDir>/locale/<Locale>/LC_MESSAGES/<Domain>.po`) a partir do `priv/`
de uma aplicacao:

```erlang
PoPath = erli18n:default_po_path(my_app, my_domain, <<"fr">>),
ok = erli18n:ensure_loaded(my_domain, <<"fr">>, PoPath).
```

Com o catalogo carregado, o lookup com dominio e locale explicitos devolve
a traducao:

```erlang
%% Lookup singular: gettext(Domain, Msgid, Locale).
<<"Bonjour, monde">> =
    erli18n:gettext(my_domain, <<"Hello, world">>, <<"fr">>).

%% Plural — o header Plural-Forms do .po e a fonte de verdade em runtime.
%% ngettext(Domain, Msgid, MsgidPlural, N, Locale); N e integer.
<<"1 fichier">> =
    erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 1, <<"fr">>).
<<"42 fichiers">> =
    erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42, <<"fr">>).

%% Contextual (msgctxt) — desambigua homografos.
<<"Mai">> =
    erli18n:pgettext(my_domain, <<"month">>, <<"May">>, <<"fr">>).
```

## setlocale: locale por processo

Em vez de passar `Locale` em toda chamada, defina o locale **do processo
atual** com `setlocale/1`. As variantes sem `Locale` explicito
(`gettext/1`, `gettext/2`, `ngettext/3`, ...) resolvem o locale a partir do
process dictionary; se nenhum estiver definido, caem no
`default_locale/0` (app-wide, default `<<"en">>`).

```erlang
%% Define o locale do processo atual (binario).
ok = erli18n:setlocale(<<"fr">>).

%% Confere o locale corrente do processo.
<<"fr">> = erli18n:which_locale().

%% Agora gettext/2 resolve o locale via process dictionary:
%% nao precisa mais passar <<"fr">> em cada chamada.
<<"Bonjour, monde">> = erli18n:gettext(my_domain, <<"Hello, world">>).
```

::: warning O process dictionary NAO e herdado em spawn
Cada novo processo comeca com `which_locale() = undefined` e cai no
`default_locale/0`. Se voce processa requisicoes em processos efemeros,
chame `setlocale/1` no inicio de cada um.
:::

Defaults app-wide podem ser ajustados via API ou `application` env:

```erlang
%% Locale default (fallback quando o processo nao definiu o seu).
ok = erli18n:set_default_locale(<<"en">>).

%% Dominio default para as variantes sem dominio (gettext/1, ngettext/3).
ok = erli18n:textdomain(my_domain).
```

## Proximos passos

- [Catalogos (.po / .pot)](/guide/catalogs) — formato, fixtures e workflow de extracao.
- [API de Lookup](/guide/lookup-api) — familia completa gettext / ngettext / pgettext / npgettext.
- [Pluralizacao](/guide/pluralization) — Plural-Forms, CLDR e divergencia.
- [Telemetry](/guide/telemetry) — os 7 eventos e como observa-los.
