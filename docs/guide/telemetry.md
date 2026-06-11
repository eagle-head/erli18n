# Telemetry

`erli18n` emite **7 eventos** `:telemetry` para observabilidade. A
dependencia [`telemetry`](https://github.com/beam-telemetry/telemetry) e
**opcional** — declarada via `optional_applications` (OTP 25.3+). Quando ela
nao esta presente, `emit/3` e `span/3` sao no-ops: zero crash, zero ruido.
`erli18n` roda identico com ou sem `telemetry`.

::: tip Habilitar a observabilidade
Adicione `telemetry` as deps para que os eventos sejam efetivamente
emitidos:

```erlang
{deps, [
    {erli18n, "~> 0.1"},
    {telemetry, "~> 1.3"}
]}.
```
:::

## Os 7 eventos

| Evento | Quando | Gate |
| --- | --- | --- |
| `[erli18n, catalog, load]` | span de load de catalogo (`ensure_loaded`) | always-on |
| `[erli18n, catalog, reload]` | span de reload de catalogo | always-on |
| `[erli18n, catalog, unload]` | unload de catalogo | always-on |
| `[erli18n, lookup, miss]` | lookup sem traducao (cai no fallback) | opt-in |
| `[erli18n, lookup, fuzzy_skip]` | entradas fuzzy descartadas no load | opt-in |
| `[erli18n, plural, divergence_warning]` | header diverge do CLDR no load | always-on |
| `[erli18n, catalog, memory_warning]` | ETS cruza o threshold de memoria | always-on (rate-limited) |

A convencao de nomes segue `[<lib>, <operacao>, <fase>]` (mesma do
Phoenix). Os nomes de evento sao o **contrato publico** da superficie de
observabilidade.

### catalog load / reload (span)

`load` e `reload` sao **spans** (`:telemetry.span/3`): emitem
`...[start]`, depois `...[stop]` (ou `...[exception]`). A fase pesada
(read + parse + compile + validate) roda no processo chamador, **dentro** do
span, entao a medicao e por-tenant e fora da mailbox do servidor.

Metadados de start (ambos): `domain`, `locale`, `language` (`lc_messages`),
`po_path` (binario), `fuzzy_included` (boolean). O stop adiciona metadados
de resultado do load.

### catalog unload

Emitido no unload de um catalogo.

### lookup miss (opt-in)

Emitido quando um lookup nao acha traducao e cai no fallback (msgid /
msgid_plural). E **alta frequencia**, portanto opt-in (ver a flag abaixo).

- Measurements: `#{count => 1}`
- Metadata: `#{domain, locale, msgid, function, context}`

O campo `function` e o atom da familia (`gettext`, `ngettext`, `pgettext`,
`npgettext`); `context` permite distinguir misses de `pgettext` de misses de
`gettext` sem inferir a partir do atom.

### lookup fuzzy_skip (opt-in)

Emitido no load quando entradas marcadas `#, fuzzy` foram descartadas (o
default, paridade com `msgfmt`). A contagem e computada no chamador; o dono
da tabela so dispara o evento.

- Measurements: `#{count => Count}` (apenas quando `Count > 0`)
- Metadata: `#{domain, locale}`

### plural divergence_warning (always-on)

Emitido no load quando o header `Plural-Forms` diverge da regra CLDR
canonica do locale (ver [Pluralizacao](/guide/pluralization)). E
load-time/infrequente, por isso always-on.

- Measurements: `#{count => 1}`
- Metadata: `#{domain, locale, po_rule, cldr_rule}`

### catalog memory_warning (always-on, rate-limited)

Emitido quando o uso de memoria da ETS cruza o threshold configurado. E
**rate-limited**: no maximo uma vez por janela (default 60s), uma vez por
evento de cruzamento — nao a cada tick.

- Measurements: `#{ets_bytes, threshold_bytes, num_catalogs, num_keys}`
- Metadata: `#{domain_locales_sample => [{Domain, Locale}]}` (ate 10 tuplas,
  para limitar o payload em deployments multi-tenant)

Configuravel via application env:

```erlang
{erli18n, [
    {memory_warning_threshold, 104857600},        %% bytes (default 100 MiB)
    {memory_warning_rate_limit_seconds, 60}        %% janela (default 60s)
]}.
```

## A flag emit_lookup_telemetry

Os dois eventos de alta frequencia — `[erli18n, lookup, miss]` e
`[erli18n, lookup, fuzzy_skip]` — sao **opt-in** via a flag de application
env `emit_lookup_telemetry` (default `false`). Os eventos always-on
ignoram o gate.

```erlang
%% sys.config
{erli18n, [
    {emit_lookup_telemetry, true}
]}.
```

```erlang
%% Em runtime.
application:set_env(erli18n, emit_lookup_telemetry, true).
```

::: tip Por que opt-in
Com a flag OFF, a funcao de emissao retorna imediatamente — nenhum evento e
construido. A flag elimina o overhead de handler attached; o `get_env` em si
(uma leitura ETS-direta no application controller, ~100ns) e o limite
teorico do design.
:::

## Anexar handlers

Use a API padrao do `telemetry` para anexar um handler aos eventos do
`erli18n`.

```erlang
%% Anexa um handler a multiplos eventos de uma vez.
telemetry:attach_many(
    <<"erli18n-observer">>,
    [
        [erli18n, catalog, load, stop],
        [erli18n, catalog, reload, stop],
        [erli18n, lookup, miss],
        [erli18n, plural, divergence_warning],
        [erli18n, catalog, memory_warning]
    ],
    fun my_handler:handle/4,
    _Config = #{}
).
```

```erlang
%% A funcao de handler recebe (EventName, Measurements, Metadata, Config).
-module(my_handler).
-export([handle/4]).

handle([erli18n, lookup, miss], #{count := C}, Meta, _Config) ->
    #{domain := D, locale := L, msgid := M, function := F} = Meta,
    logger:warning("i18n miss ~p/~p ~p via ~p (x~p)", [D, L, M, F, C]);
handle([erli18n, catalog, memory_warning], Measurements, _Meta, _Config) ->
    #{ets_bytes := Bytes, threshold_bytes := Limit} = Measurements,
    logger:warning("erli18n ETS ~p bytes > ~p", [Bytes, Limit]);
handle(_Event, _Measurements, _Meta, _Config) ->
    ok.
```

::: warning Spans usam o sufixo de fase
Para `load` / `reload` (que sao spans), anexe a `[..., start]`,
`[..., stop]` e/ou `[..., exception]` — nao ao prefixo nu. Os demais eventos
sao pontuais e usam o nome exato listado acima.
:::

## Interop Elixir / Phoenix

A convencao de nomes `[<lib>, <operacao>, <fase>]` vem do Phoenix, entao os
eventos do `erli18n` se integram naturalmente ao pipeline de telemetria de
uma app Phoenix. Em Elixir, os nomes de evento sao listas de atoms
(`[:erli18n, :lookup, :miss]`) e a API e `:telemetry`.

```elixir
# lib/my_app/telemetry.ex — anexar via :telemetry
:telemetry.attach_many(
  "erli18n-observer",
  [
    [:erli18n, :catalog, :load, :stop],
    [:erli18n, :lookup, :miss],
    [:erli18n, :plural, :divergence_warning],
    [:erli18n, :catalog, :memory_warning]
  ],
  &MyApp.Telemetry.handle_erli18n/4,
  %{}
)
```

```elixir
def handle_erli18n([:erli18n, :lookup, :miss], measurements, metadata, _config) do
  Logger.warning("i18n miss: #{inspect(metadata)} #{inspect(measurements)}")
end
```

Voce tambem pode plugar os eventos numa `Telemetry.Metrics` dashboard
(LiveDashboard) declarando contadores/distribuicoes sobre, por exemplo,
`[:erli18n, :lookup, :miss]` (counter) ou `[:erli18n, :catalog, :load,
:stop]` (`duration`).
