-module(erli18n_telemetry).

-moduledoc """
Superfície de observabilidade do erli18n: wrapper fino sobre a biblioteca
`:telemetry` que centraliza os nomes de evento e protege os call sites contra
a ausência da dependência opcional.

## O que é e que problema resolve

`telemetry` é uma dependência **opcional** do erli18n (declarada via
`optional_applications`, OTP 24+): a lib funciona com ou sem ela. Esse módulo
é a única camada que sabe disso. Ele resolve três problemas para o resto da
base de código:

- **Indireção segura.** Os call sites (`erli18n_server`, hot path de lookup)
  chamam `emit/3`/`span/3` sem nunca testar se `telemetry` está presente.
  Quando a lib não está carregada, ambas viram no-ops — zero crash, zero
  ruído — em vez de espalhar `case code:ensure_loaded(...)` por toda parte.
- **Contrato de nomes.** Todos os nomes de evento do erli18n vivem aqui,
  expostos como funções `event_*/0` pré-tipadas. Um rename ou auditoria é uma
  mudança de um arquivo. Os nomes são o **contrato público** da observabilidade
  (convenção `[<lib>, <operação>, <fase>]`, ao estilo `Phoenix.Logger`).
- **Política de overhead e segurança.** Os eventos de lookup de alta
  frequência (`miss`/`fuzzy_skip`) são opt-in (flag `emit_lookup_telemetry`,
  default `false`) — isso minimiza tanto o custo quanto o risco de vazar
  conteúdo de msgid em cenário multi-tenant. O `memory_warning` é
  rate-limited: no máximo uma emissão por janela configurada.

## Modelo mental

Pense em duas camadas, ambas **lock-free a partir de qualquer processo**:

- **Detecção de telemetry (cache positivo-sticky).** A primeira chamada faz
  `code:ensure_loaded(telemetry)`, que caminha o code server. Se carregar, o
  resultado `true` é gravado em `persistent_term` e fica sticky pelo resto da
  vida da VM (telemetry não descarrega em runtime). Se **não** carregar, o
  resultado `false` **não** é cacheado: assim, se o consumidor subir o
  telemetry mid-flight (`application:start(telemetry)`), a próxima emissão já
  enxerga. O preço dessa escolha é, no máximo, um `code:ensure_loaded/1` por
  emissão enquanto o telemetry está ausente (microssegundos), e zero por
  emissão depois de presente.
- **Configuração via `application:get_env/3`.** As flags (`emit_lookup_telemetry`,
  `memory_warning_threshold`, `memory_warning_rate_limit_seconds`) são lidas a
  cada chamada — um read direto no ETS do application controller (~100 ns).
  Não há estado por processo nem caching dessas flags.

Confiável vs não-confiável: a chave `persistent_term` do rate-limit é
**privada** deste módulo. As funções narram seu valor no boundary; se algo de
fora reusar a chave e gravar um não-inteiro, o código crasha explicitamente em
vez de operar sobre lixo. Valores de configuração inválidos (não-booleano,
inteiro negativo) também crasham com `{invalid_config, ...}` — falha alta e
visível, nunca silenciosa.

## Quando um dev encosta neste módulo

- **Consumidor de observabilidade** (anexa handlers): use os nomes de
  `event_*/0` em `telemetry:attach/4`. Não chame `emit/3`/`span/3` diretamente
  — quem emite é o erli18n.
- **Mantenedor do core** (`erli18n_server`, hot path): chame `span/3` para
  instrumentar operações com início/fim (load/reload), `emit/3` para eventos
  pontuais, e `lookup_telemetry_enabled/0` para fazer gate dos eventos de
  lookup antes de montar payloads caros. O loader chama `memory_warning_check/1`.

## Quickstart (consumidor)

```erlang
%% Anexe um handler aos eventos de carga de catálogo:
1> telemetry:attach_many(
..     <<"erli18n-log">>,
..     [erli18n_telemetry:event_catalog_load(),
..      erli18n_telemetry:event_catalog_load() ++ [stop]],
..     fun(Event, Measurements, Meta, _Cfg) ->
..         io:format("~p ~p ~p~n", [Event, Measurements, Meta])
..     end,
..     undefined).
ok
%% Eventos de lookup são opt-in; habilite-os explicitamente:
2> application:set_env(erli18n, emit_lookup_telemetry, true).
ok
3> erli18n_telemetry:lookup_telemetry_enabled().
true
```

## Funções-chave

- Emissão: `emit/3` (pontual), `span/3` (start/stop/exception).
- Nomes de evento: `event_catalog_load/0`, `event_catalog_reload/0`,
  `event_catalog_unload/0`, `event_lookup_miss/0`, `event_lookup_fuzzy_skip/0`,
  `event_plural_divergence/0`, `event_catalog_memory_warning/0`.
- Configuração/gating: `lookup_telemetry_enabled/0`,
  `memory_warning_threshold/0`, `memory_warning_rate_limit_seconds/0`,
  `memory_warning_check/1`.

## Referências

- Biblioteca: <https://github.com/beam-telemetry/telemetry>
- Hexdocs: <https://hexdocs.pm/telemetry/>
- `span/3`: <https://hexdocs.pm/telemetry/telemetry.html#span-3>
- Convenção de nomes `[<lib>, <operação>, <fase>]`:
  <https://hexdocs.pm/phoenix/Phoenix.Logger.html>
- `persistent_term` (lock-free, copy-free entre processos):
  <https://www.erlang.org/doc/man/persistent_term.html>
""".

%% ============================================================================
%%  erli18n_telemetry — thin wrapper over the `:telemetry` library.
%%
%%  Responsibilities:
%%
%%    * Encapsulate the runtime presence/absence of the `telemetry` module
%%      so call sites never have to branch. If `telemetry` is not loaded,
%%      `emit/3` and `span/3` are no-ops (zero crash, zero noise).
%%
%%    * Centralize all `erli18n` event names (`[erli18n, catalog, load]`,
%%      etc.) so a future rename or audit is a one-file change. The event
%%      names are the **public contract** of the lib's observability
%%      surface — see observability.md §3 (naming convention) and §4
%%      (catalogue of events).
%%
%%    * Provide opt-in/opt-out gating for high-frequency events
%%      (lookup miss / fuzzy_skip) via the `emit_lookup_telemetry`
%%      application env flag. Always-on events bypass the gate. See
%%      observability.md §6 (overhead policy).
%%
%%    * Provide a rate-limited memory-warning check used by the loader
%%      to emit `[erli18n, catalog, memory_warning]` at most once per
%%      configured window (RISK-011 mitigation 2: "uma vez por evento de
%%      cruzamento, não a cada tick"). See observability.md §4 (memory
%%      warning schema).
%%
%%  References:
%%
%%    * Library:   https://github.com/beam-telemetry/telemetry
%%    * Hexdocs:   https://hexdocs.pm/telemetry/
%%    * span/3:    https://hexdocs.pm/telemetry/telemetry.html#span-3
%%    * Phoenix:   https://hexdocs.pm/phoenix/Phoenix.Logger.html — naming
%%                 convention `[<lib>, <operation>, <phase>]` source.
%%
%%  Performance note (`code:ensure_loaded/1` cache):
%%
%%    The first call walks the code path to confirm whether `telemetry`
%%    is loadable; subsequent calls hit a `persistent_term` entry
%%    (~sub-microsecond, lock-free, copy-free across processes — see
%%    https://www.erlang.org/doc/man/persistent_term.html). The cache is
%%    invalidated only when the result is `false` (in case the consumer
%%    starts telemetry mid-flight); positive results are sticky for the
%%    VM's lifetime.
%% ============================================================================

%% Emission API.
-export([emit/3, span/3]).

%% Convenience: pre-typed event names.
-export([
    event_catalog_load/0,
    event_catalog_reload/0,
    event_catalog_unload/0,
    event_lookup_miss/0,
    event_lookup_fuzzy_skip/0,
    event_plural_divergence/0,
    event_catalog_memory_warning/0
]).

%% Configuration / gating.
-export([
    lookup_telemetry_enabled/0,
    memory_warning_threshold/0,
    memory_warning_rate_limit_seconds/0,
    memory_warning_check/1
]).

%% Test-only — exposed so the SUITE can reset the persistent_term cache
%% between cases. Not in the documented API surface.
-export([reset_caches/0]).

-export_type([
    event_name/0,
    measurements/0,
    metadata/0,
    span_fun/0,
    span_result/0
]).

%% =========================
%% Types
%% =========================

-doc """
Nome de um evento de telemetry: uma lista de átomos no formato
`[<lib>, <operação>, <fase>]` (ex.: `[erli18n, catalog, load]`). É o tipo
retornado por todas as funções `event_*/0` e o aceito por `emit/3`/`span/3`.
A lista contém os átomos do vocabulário do erli18n e admite `atom()` livre na
cauda para extensões (ex.: o sufixo `start`/`stop` que o `span/3` anexa).
""".
%% Event name shapes per observability.md §5.
-type event_name() ::
    [
        erli18n
        | catalog
        | lookup
        | plural
        | load
        | reload
        | unload
        | miss
        | fuzzy_skip
        | divergence_warning
        | memory_warning
        | atom()
    ].

-doc """
Mapa de **medições** numéricas de um evento (ex.: `#{duration => N}`,
`#{ets_bytes => N}`). Numericamente é só um `map()`; a convenção telemetry é
que medições são valores agregáveis, distintos dos metadados qualitativos.
""".
-type measurements() :: map().

-doc """
Mapa de **metadados** qualitativos de um evento (ex.: domínio, locale, amostra
`domain_locales_sample`). Numericamente é só um `map()`; carrega contexto, não
valores agregáveis.
""".
-type metadata() :: map().

-doc """
Corpo de um span: uma fun/0 que **deve** retornar `{Result, StopMetadata}`,
conforme o contrato de `telemetry:span/3`. `Result` é propagado de volta por
`span/3`; `StopMetadata` é mesclado nos metadados do evento `stop` (ou
descartado no caminho no-op, quando telemetry está ausente).
""".
%% Span body must return `{Result, StopMetadata}` per
%% https://hexdocs.pm/telemetry/telemetry.html#span-3.
-type span_fun() :: fun(() -> {term(), metadata()}).

-doc "Valor de retorno de `span/3`: o `Result` produzido pela `span_fun/0`.".
-type span_result() :: term().

%% =========================
%% Cache keys (persistent_term)
%% =========================

%% Sticky-true cache for the loaded check.
-define(LOADED_KEY, {?MODULE, telemetry_loaded}).
%% Rate-limit anchor for memory_warning emission.
-define(MEM_WARN_LAST_KEY, {?MODULE, memory_warning_last_emit}).

%% =========================
%% Event names
%% =========================

-doc """
Prefixo de evento do **span de carga** de um catálogo (`ensure_loaded`):
`[erli18n, catalog, load]`. Como é prefixo de span (via `span/3`), os eventos
realmente emitidos têm o sufixo `start`/`stop`/`exception` anexado.

```erlang
1> erli18n_telemetry:event_catalog_load().
[erli18n,catalog,load]
```

Irmãos: `event_catalog_reload/0`, `event_catalog_unload/0`.
""".
-spec event_catalog_load() -> event_name().
event_catalog_load() ->
    [erli18n, catalog, load].

-doc """
Prefixo de evento do **span de recarga atômica** de um catálogo:
`[erli18n, catalog, reload]`. Como prefixo de span, recebe sufixo
`start`/`stop`/`exception` em runtime.

```erlang
1> erli18n_telemetry:event_catalog_reload().
[erli18n,catalog,reload]
```

Irmãos: `event_catalog_load/0`, `event_catalog_unload/0`.
""".
-spec event_catalog_reload() -> event_name().
event_catalog_reload() ->
    [erli18n, catalog, reload].

-doc """
Nome do evento pontual de **descarregamento** de catálogo:
`[erli18n, catalog, unload]`. Emitido via `emit/3` (não é span).

```erlang
1> erli18n_telemetry:event_catalog_unload().
[erli18n,catalog,unload]
```

Irmãos: `event_catalog_load/0`, `event_catalog_reload/0`.
""".
-spec event_catalog_unload() -> event_name().
event_catalog_unload() ->
    [erli18n, catalog, unload].

-doc """
Nome do evento de **miss de lookup** (chave não encontrada no catálogo):
`[erli18n, lookup, miss]`. Evento de **alta frequência** e portanto **opt-in**
— só é emitido quando `lookup_telemetry_enabled/0` retorna `true`. Manter o
default desligado também evita expor conteúdo de msgid em cenário multi-tenant.

```erlang
1> erli18n_telemetry:event_lookup_miss().
[erli18n,lookup,miss]
```

Irmão: `event_lookup_fuzzy_skip/0`. Gate: `lookup_telemetry_enabled/0`.
""".
-spec event_lookup_miss() -> event_name().
event_lookup_miss() ->
    [erli18n, lookup, miss].

-doc """
Nome do evento de **skip de entrada fuzzy** no lookup (entrada marcada
`#, fuzzy` no `.po`, que o gettext ignora): `[erli18n, lookup, fuzzy_skip]`.
Evento de **alta frequência**, **opt-in** sob a mesma flag dos misses
(`lookup_telemetry_enabled/0`).

```erlang
1> erli18n_telemetry:event_lookup_fuzzy_skip().
[erli18n,lookup,fuzzy_skip]
```

Irmão: `event_lookup_miss/0`. Gate: `lookup_telemetry_enabled/0`.
""".
-spec event_lookup_fuzzy_skip() -> event_name().
event_lookup_fuzzy_skip() ->
    [erli18n, lookup, fuzzy_skip].

-doc """
Nome do evento de **aviso de divergência de plural**:
`[erli18n, plural, divergence_warning]`. Emitido na carga quando a regra
`Plural-Forms` do header do `.po` diverge da regra CLDR inlinada para o locale
(validação informativa — o header do `.po` continua sendo a fonte de verdade
em runtime). Sempre ligado (não passa pela flag de lookup).

```erlang
1> erli18n_telemetry:event_plural_divergence().
[erli18n,plural,divergence_warning]
```
""".
-spec event_plural_divergence() -> event_name().
event_plural_divergence() ->
    [erli18n, plural, divergence_warning].

-doc """
Nome do evento de **aviso de memória**: `[erli18n, catalog, memory_warning]`.
Emitido por `memory_warning_check/1` quando o uso de ETS dos catálogos cruza
`memory_warning_threshold/0`, **rate-limited** a no máximo uma emissão por
`memory_warning_rate_limit_seconds/0`. Sempre ligado (não passa pela flag de
lookup).

```erlang
1> erli18n_telemetry:event_catalog_memory_warning().
[erli18n,catalog,memory_warning]
```

Emissor: `memory_warning_check/1`.
""".
-spec event_catalog_memory_warning() -> event_name().
event_catalog_memory_warning() ->
    [erli18n, catalog, memory_warning].

%% =========================
%% Emission
%% =========================

%% Pointwise emit. Safe no-op when `telemetry` is unavailable. The naked
%% `erlang:apply/3` indirection is intentional: dialyzer treats the call
%% as an unknown remote function when `telemetry` is genuinely absent
%% from the PLT, which matches the runtime story exactly.
-doc """
Emite um evento **pontual** de telemetry (sem semântica de início/fim; para
isso use `span/3`).

Parâmetros:
- `EventName` — nome do evento, tipicamente um dos `event_*/0` (ex.:
  `event_catalog_unload/0`). Deve ser uma lista.
- `Measurements` — mapa de medições numéricas/agregáveis. Deve ser um mapa.
- `Metadata` — mapa de metadados qualitativos. Deve ser um mapa.

Comportamento e retorno: se `telemetry` está carregado (ver detecção sticky no
moduledoc), delega para `telemetry:execute/3`; senão é um **no-op seguro**. Em
ambos os caminhos retorna sempre `ok` — o resultado de `telemetry:execute/3` é
descartado de propósito.

Modos de falha: a cláusula é guardada (`is_list`/`is_map`/`is_map`); chamar com
tipos errados resulta em `function_clause` (crash do chamador). A indireção
`erlang:apply(telemetry, execute, ...)` é **intencional**: faz o dialyzer tratar
a chamada como função remota desconhecida quando `telemetry` está de fato
ausente do PLT, espelhando a história de runtime.

```erlang
1> erli18n_telemetry:emit(
..     erli18n_telemetry:event_catalog_unload(),
..     #{count => 1},
..     #{domain => my_domain, locale => <<"fr">>}).
ok
```

O caminho no-op não depende de `telemetry` estar **carregado na memória**, e
sim de `telemetry` estar **ausente do code path** — a detecção (ver
`telemetry_loaded/0` / moduledoc) usa `code:ensure_loaded(telemetry)`, que
carregaria o módulo do code path se ele existisse lá. Ou seja:
`code:is_loaded(telemetry) =:= false` **não** torna `emit/3` um no-op (o
módulo ainda seria carregado e o evento emitido). O no-op só ocorre quando a
app `telemetry` não está no release/code path; nesse cenário a mesma chamada
retorna `ok` sem emitir nada.

Irmão: `span/3` (eventos com início/fim).
""".
-spec emit(event_name(), measurements(), metadata()) -> ok.
emit(EventName, Measurements, Metadata) when
    is_list(EventName), is_map(Measurements), is_map(Metadata)
->
    case telemetry_loaded() of
        true ->
            _ = erlang:apply(
                telemetry,
                execute,
                [EventName, Measurements, Metadata]
            ),
            ok;
        false ->
            ok
    end.

%% Span emit. Matches the `:telemetry.span/3` contract:
%%   * Emits `EventPrefix ++ [start]` with measurements
%%     `#{monotonic_time, system_time}` and StartMetadata.
%%   * Runs Fun, which must return `{Result, StopMetadata}`.
%%   * Emits `EventPrefix ++ [stop]` with measurements
%%     `#{monotonic_time, duration}` and (StartMetadata merged with
%%     StopMetadata).
%%   * On exception, emits `EventPrefix ++ [exception]` instead of stop,
%%     with `#{kind, reason, stacktrace}` merged into StartMetadata.
%%
%% Reference: https://hexdocs.pm/telemetry/telemetry.html#span-3.
%%
%% Always-on path (telemetry loaded): we delegate to `:telemetry.span/3`
%% to avoid duplicating the implementation, which keeps measurement
%% semantics byte-equal to what `:telemetry` users expect.
%%
%% No-op path (telemetry absent): we still run Fun (otherwise the lib
%% would behave differently with vs without telemetry — unacceptable).
%% We discard StopMetadata because there's nothing to emit it to.
-doc """
Executa `Fun` instrumentada como um **span** de telemetry, seguindo o contrato
de `telemetry:span/3` (eventos com início, fim e exceção).

Parâmetros:
- `EventPrefix` — prefixo do evento (ex.: `event_catalog_load/0`). O telemetry
  anexa `start`/`stop`/`exception` a esse prefixo. Deve ser uma lista.
- `StartMetadata` — metadados disponíveis já no evento `start` (e mesclados no
  `stop`). Deve ser um mapa.
- `Fun` — corpo do span, uma fun/0 que **DEVE** retornar `{Result, StopMetadata}`
  (ver `span_fun/0`).

Semântica do contrato (caminho com telemetry carregado): emite
`EventPrefix ++ [start]` com medições `#{monotonic_time, system_time}`; roda
`Fun`; emite `EventPrefix ++ [stop]` com `#{monotonic_time, duration}` e
`StartMetadata` mesclado com `StopMetadata`. Se `Fun` levanta exceção, emite
`EventPrefix ++ [exception]` (com `#{kind, reason, stacktrace}` no metadado) em
vez de `stop`, e a exceção re-propaga. Delega a `telemetry:span/3` para manter
as medições byte-iguais ao que usuários de `:telemetry` esperam.

Semântica do caminho no-op (telemetry ausente): **ainda executa `Fun`** — caso
contrário a lib se comportaria diferente com e sem telemetry, o que é
inaceitável — e descarta `StopMetadata` (não há para onde emitir). Nenhum
evento é emitido.

Retorno: em ambos os caminhos, o `Result` produzido por `Fun` (ver
`span_result/0`).

Modos de falha: cláusula guardada (`is_list`/`is_map`/`is_function(Fun, 0)`);
tipos errados ⇒ `function_clause`. Se `Fun` não retornar uma tupla
`{Result, StopMetadata}`, os dois caminhos crasham, mas de forma **assimétrica**
quanto aos eventos já emitidos:
- **Caminho no-op (telemetry ausente):** crasha com `badmatch` em
  `{Result, _StopMetadata} = Fun()` **antes** de qualquer emissão — nenhum
  evento sai (consistente com o no-op nunca emitir nada).
- **Caminho com telemetry:** o `telemetry:span/3` já emitiu o evento
  `EventPrefix ++ [start]` **antes** de inspecionar o retorno de `Fun`, então
  o consumidor vê um `start` **órfão** (sem `stop` nem `exception`
  correspondente) seguido do crash dentro da própria lib `telemetry` ao casar
  o formato inválido. É exatamente o sintoma a procurar ao depurar eventos
  `start` sem `stop`.

```erlang
1> erli18n_telemetry:span(
..     erli18n_telemetry:event_catalog_load(),
..     #{domain => my_domain, locale => <<"fr">>},
..     fun() ->
..         Result = do_load(),           %% trabalho instrumentado
..         {Result, #{entries => 128}}   %% {Result, StopMetadata}
..     end).
Result
```

Irmão: `emit/3` (eventos pontuais).
""".
-spec span(event_name(), metadata(), span_fun()) -> span_result().
span(EventPrefix, StartMetadata, Fun) when
    is_list(EventPrefix), is_map(StartMetadata), is_function(Fun, 0)
->
    case telemetry_loaded() of
        true ->
            erlang:apply(
                telemetry,
                span,
                [EventPrefix, StartMetadata, Fun]
            );
        false ->
            {Result, _StopMetadata} = Fun(),
            Result
    end.

%% =========================
%% Configuration / gating
%% =========================

%% Opt-in flag for the high-frequency lookup events.
%%
%% `application:get_env/3` lookup is an ETS-direct read in the OTP
%% application controller (~100 ns), comparable to telemetry's own no-op
%% overhead. See observability.md §6 ("a flag elimina o overhead de
%% handler attached, não o overhead de lookup da flag — esse é o limite
%% teórico do design").
-doc """
Gate dos eventos de lookup de alta frequência (`event_lookup_miss/0` e
`event_lookup_fuzzy_skip/0`). Os call sites chamam esta função **antes** de
montar payloads caros, para que o overhead só exista quando o operador opta por
isso.

Lê a app env `emit_lookup_telemetry` (default `false` — opt-in, também por
razão de segurança multi-tenant). O read é um acesso direto ao ETS do
application controller (~100 ns); essa função **não** elimina o overhead de
lookup da própria flag, só o de ter handlers anexados — é o limite teórico do
design.

Retorno e modos de falha: `true` para `true`, `false` para `false`. Qualquer
**outro** valor configurado é erro de configuração e provoca crash explícito
com `error({invalid_config, {erli18n, emit_lookup_telemetry, Other, expected,
boolean}})` — falha alta e visível, nunca um silencioso "tratar como false".

```erlang
1> erli18n_telemetry:lookup_telemetry_enabled().
false
2> application:set_env(erli18n, emit_lookup_telemetry, true).
ok
3> erli18n_telemetry:lookup_telemetry_enabled().
true
4> application:set_env(erli18n, emit_lookup_telemetry, "yes").
ok
5> erli18n_telemetry:lookup_telemetry_enabled().
** exception error: {invalid_config,{erli18n,emit_lookup_telemetry,"yes",expected,boolean}}
```

Irmãs (config): `memory_warning_threshold/0`,
`memory_warning_rate_limit_seconds/0`.
""".
-spec lookup_telemetry_enabled() -> boolean().
lookup_telemetry_enabled() ->
    case application:get_env(erli18n, emit_lookup_telemetry, false) of
        true -> true;
        false -> false;
        Other -> error({invalid_config, {erli18n, emit_lookup_telemetry, Other, expected, boolean}})
    end.

%% Bytes threshold for memory_warning. Default 100 MiB matches the
%% sys.config example in observability.md §4.
-doc """
Limiar, em **bytes**, de uso de ETS dos catálogos acima do qual o
`event_catalog_memory_warning/0` fica elegível. Comparado contra `ets_bytes`
dentro de `memory_warning_check/1` com `>` estrito (igualar o limiar **não**
dispara).

Lê a app env `memory_warning_threshold` (default `104857600`, 100 MiB — bate
com o exemplo de `sys.config` da observabilidade).

Retorno e modos de falha: um `non_neg_integer()` válido. Qualquer valor que não
seja inteiro `>= 0` (negativo, não-inteiro) provoca crash com
`error({invalid_config, {erli18n, memory_warning_threshold, Other, expected,
non_neg_integer}})`.

```erlang
1> erli18n_telemetry:memory_warning_threshold().
104857600
2> application:set_env(erli18n, memory_warning_threshold, 52428800).
ok
3> erli18n_telemetry:memory_warning_threshold().
52428800
4> application:set_env(erli18n, memory_warning_threshold, -1).
ok
5> erli18n_telemetry:memory_warning_threshold().
** exception error: {invalid_config,{erli18n,memory_warning_threshold,-1,expected,non_neg_integer}}
```

Consumidor: `memory_warning_check/1`. Irmã: `memory_warning_rate_limit_seconds/0`.
""".
-spec memory_warning_threshold() -> non_neg_integer().
memory_warning_threshold() ->
    case application:get_env(erli18n, memory_warning_threshold, 104857600) of
        N when is_integer(N), N >= 0 -> N;
        Other ->
            error(
                {invalid_config,
                    {erli18n, memory_warning_threshold, Other, expected, non_neg_integer}}
            )
    end.

%% Window (seconds) between successive memory_warning emits.
-doc """
Janela, em **segundos**, entre emissões sucessivas do
`event_catalog_memory_warning/0`. Mesmo que o limiar seja cruzado a cada carga,
`memory_warning_check/1` só re-emite depois que esta janela decorre desde a
última emissão (mitigação: "uma vez por evento de cruzamento, não a cada tick").

Lê a app env `memory_warning_rate_limit_seconds` (default `60`).

Retorno e modos de falha: um `non_neg_integer()` válido. Valor que não seja
inteiro `>= 0` provoca crash com `error({invalid_config, {erli18n,
memory_warning_rate_limit_seconds, Other, expected, non_neg_integer}})`. Um
valor `0` faz cada cruzamento re-emitir (janela degenerada, sem rate-limit
efetivo).

```erlang
1> erli18n_telemetry:memory_warning_rate_limit_seconds().
60
2> application:set_env(erli18n, memory_warning_rate_limit_seconds, 300).
ok
3> erli18n_telemetry:memory_warning_rate_limit_seconds().
300
```

Consumidor: `memory_warning_check/1`. Irmã: `memory_warning_threshold/0`.
""".
-spec memory_warning_rate_limit_seconds() -> non_neg_integer().
memory_warning_rate_limit_seconds() ->
    case application:get_env(erli18n, memory_warning_rate_limit_seconds, 60) of
        N when is_integer(N), N >= 0 -> N;
        Other ->
            error(
                {invalid_config,
                    {erli18n, memory_warning_rate_limit_seconds, Other, expected, non_neg_integer}}
            )
    end.

%% Inspect the given memory_info and emit a single memory_warning event
%% if the threshold is crossed and the rate-limit window has elapsed.
%%
%% Returns:
%%   * `not_warned`     — threshold not crossed.
%%   * `rate_limited`   — threshold crossed but a warning was already
%%     emitted within the rate-limit window.
%%   * `warned`         — a `[erli18n, catalog, memory_warning]` event
%%     was just emitted.
%%
%% Rate-limit storage uses `persistent_term` so the check is lock-free
%% from any process. The cost of storing a single integer is one VM
%% global GC at update time — acceptable because the update only happens
%% on actual emit (rare, by design).
-doc """
Inspeciona o snapshot de memória `MemInfo` e emite **no máximo um**
`event_catalog_memory_warning/0`, decidindo entre não-avisar, suprimir por
rate-limit, ou avisar. Chamado pelo loader (`erli18n_server`) ao fim de uma
carga bem-sucedida.

Parâmetro:
- `MemInfo` — mapa-snapshot. As chaves lidas são `ets_bytes` (uso de ETS, o
  gatilho; default `0` se ausente), `num_catalogs` e `num_keys` (só usadas na
  medição quando avisa; default `0`). Deve ser um mapa, senão `function_clause`.

Lógica de decisão:
1. Se `ets_bytes` **não** for `>` `memory_warning_threshold/0`, retorna
   `not_warned` (comparação `>` estrita).
2. Senão, se a janela `memory_warning_rate_limit_seconds/0` ainda **não**
   decorreu desde a última emissão, retorna `rate_limited` sem emitir.
3. Senão, grava o instante atual na âncora, monta a amostra e emite via
   `emit/3`, retornando `warned`.

Efeitos colaterais: a âncora de rate-limit é uma chave **privada** em
`persistent_term` (lock-free a partir de qualquer processo), atualizada
**apenas** na emissão efetiva. Reescrever a chave via `persistent_term:put/2`
pode disparar trabalho de GC proporcional aos processos que ainda seguram
referências ao valor **anterior** dessa chave — não um full GC global
incondicional da VM. Aqui isso é barato (o valor anterior é um único inteiro
de timestamp, sem holders de longa vida) e, além disso, só acontece no caminho
`warned` (raro, por design), então o custo é aceitável. O payload do evento
avisado tem:
- medições `#{ets_bytes, threshold_bytes, num_catalogs, num_keys}`;
- metadado `#{domain_locales_sample => [...]}`, uma amostra de até 10 pares
  `{Domain, Locale}` (limite de payload em deploy multi-tenant), coletada por
  `collect_domain_locales_sample/0`.

Modos de falha: se `ets_bytes` ou os contadores forem não-numéricos, o `>` ou a
construção das medições crasham. Se a âncora `persistent_term` contiver um
não-inteiro (alguém reusando a chave privada — violação de contrato), o boundary
crasha com `{invalid_persistent_term, ...}` em vez de operar sobre lixo.

```erlang
%% Abaixo do limiar padrão (100 MiB): nada acontece.
1> erli18n_telemetry:memory_warning_check(#{ets_bytes => 1024}).
not_warned
%% Acima do limiar: primeira chamada avisa...
2> erli18n_telemetry:memory_warning_check(
..     #{ets_bytes => 209715200, num_catalogs => 3, num_keys => 4096}).
warned
%% ...e a próxima, dentro da janela de rate-limit, é suprimida.
3> erli18n_telemetry:memory_warning_check(#{ets_bytes => 209715200}).
rate_limited
```

Config: `memory_warning_threshold/0`, `memory_warning_rate_limit_seconds/0`.
Evento: `event_catalog_memory_warning/0`. Em testes, `reset_caches/0` zera a
âncora.
""".
-spec memory_warning_check(map()) -> not_warned | rate_limited | warned.
memory_warning_check(MemInfo) when is_map(MemInfo) ->
    Threshold = memory_warning_threshold(),
    Bytes = maps:get(ets_bytes, MemInfo, 0),
    case Bytes > Threshold of
        false ->
            not_warned;
        true ->
            Now = erlang:system_time(second),
            Window = memory_warning_rate_limit_seconds(),
            %% `persistent_term:get/2` returns `term()`. The value under
            %% `?MEM_WARN_LAST_KEY` is only ever written by this module
            %% with `persistent_term:put(?MEM_WARN_LAST_KEY, Now)` where
            %% `Now = erlang:system_time(second) :: integer()`, and the
            %% default we pass is the integer `0`. Narrow at the boundary
            %% so arithmetic is type-checked; a non-integer would mean
            %% someone is reusing our private key — contract violation,
            %% crash explicitly.
            Last =
                case persistent_term:get(?MEM_WARN_LAST_KEY, 0) of
                    L when is_integer(L) -> L;
                    Other ->
                        error(
                            {invalid_persistent_term,
                                {?MEM_WARN_LAST_KEY, Other, expected, integer}}
                        )
                end,
            case (Now - Last) < Window of
                true ->
                    rate_limited;
                false ->
                    persistent_term:put(?MEM_WARN_LAST_KEY, Now),
                    Sample = collect_domain_locales_sample(),
                    emit(
                        event_catalog_memory_warning(),
                        #{
                            ets_bytes => Bytes,
                            threshold_bytes => Threshold,
                            num_catalogs => maps:get(num_catalogs, MemInfo, 0),
                            num_keys => maps:get(num_keys, MemInfo, 0)
                        },
                        %% observability.md §4.2 memory_warning metadata
                        %% calls for `domain_locales_sample`: up to 10
                        %% `{Domain, Locale}` tuples to bound payload
                        %% size in multi-tenant deployments.
                        %% `erli18n_server:loaded_catalogs/0` is a
                        %% caller-process ETS scan — safe to call from
                        %% any process, including the server itself,
                        %% because it never re-enters the gen_server.
                        #{domain_locales_sample => Sample}
                    ),
                    warned
            end
    end.

-doc """
Interno. Coleta a amostra `domain_locales_sample` do `memory_warning`: até 10
pares `{Domain, Locale}` dos catálogos carregados.

Invariantes e segurança para o mantenedor:
- Guarda por `erlang:function_exported(erli18n_server, loaded_catalogs, 0)`: se
  o servidor não estiver presente (ex.: módulo não carregado em testes
  isolados), retorna `[]` em vez de crashar.
- `erli18n_server:loaded_catalogs/0` é um scan ETS no **processo chamador** —
  seguro de chamar de qualquer processo, **inclusive do próprio gen_server**,
  porque nunca re-entra no `gen_server` (sem risco de deadlock).
- Sem ordenação: a ordem é a que o scan ETS devolve. O contrato é uma amostra de
  observabilidade, não exige determinismo, e ordenar só agregaria custo. O
  limite de 10 (`lists:sublist/2`) limita o tamanho do payload em deploy
  multi-tenant.
""".
%% Sample up to 10 (Domain, Locale) tuples. Order is whatever ETS scan
%% returns; we don't sort because the spec doesn't require determinism
%% and sorting would add overhead at no benefit for an observability
%% sample.
collect_domain_locales_sample() ->
    case erlang:function_exported(erli18n_server, loaded_catalogs, 0) of
        true ->
            Catalogs = erli18n_server:loaded_catalogs(),
            Pairs = [{D, L} || {D, L, _N} <- Catalogs],
            lists:sublist(Pairs, 10);
        false ->
            []
    end.

%% =========================
%% Test-only helpers
%% =========================

%% Clear both caches so a test can simulate a fresh VM. Not part of the
%% documented API.
-doc """
Apenas para testes: apaga as duas chaves em `persistent_term` deste módulo — o
cache sticky de "telemetry carregada" (`?LOADED_KEY`) e a âncora de rate-limit
do memory_warning (`?MEM_WARN_LAST_KEY`) — simulando uma VM nova entre casos de
teste. Não faz parte da superfície de API documentada (não confie nela em
produção). Retorna sempre `ok`.

Útil para tornar determinísticos os testes de `memory_warning_check/1` (que
muda de `warned` para `rate_limited` conforme a âncora) e os de detecção de
telemetry.

```erlang
1> erli18n_telemetry:reset_caches().
ok
```
""".
-spec reset_caches() -> ok.
reset_caches() ->
    _ = persistent_term:erase(?LOADED_KEY),
    _ = persistent_term:erase(?MEM_WARN_LAST_KEY),
    ok.

%% =========================
%% Internal
%% =========================

-doc """
Interno. Detecção cacheada de "telemetry está carregável?" — o coração do
contrato no-op-safe que `emit/3` e `span/3` consultam.

Protocolo do cache (positivo-sticky) para o mantenedor:
- **Hit positivo:** se `?LOADED_KEY` já vale `true` em `persistent_term`,
  retorna `true` direto (~sub-microssegundo, lock-free).
- **Primeira chamada / ainda não resolvido:** faz `code:ensure_loaded(telemetry)`,
  que caminha o code server. Em `{module, telemetry}`, grava `true` no cache
  (sticky pela vida da VM — telemetry não descarrega em runtime) e retorna
  `true`.
- **Ausente:** retorna `false` **sem** cachear. É deliberado: se o consumidor
  subir o telemetry depois (`application:start(telemetry)`), a próxima chamada
  re-checa e passa a enxergar. Caching negativo seria mais barato no caso
  ausente, mas quebraria a habilitação on-the-fly e contradiria o contrato
  "no-op seguro, nunca crasha".

Custo: no máximo um `code:ensure_loaded/1` por emissão enquanto telemetry está
ausente (microssegundos); zero por emissão depois de presente. `reset_caches/0`
apaga `?LOADED_KEY` para forçar re-detecção em testes.
""".
%% Cached "is telemetry loaded?" check.
%%
%% First call: `code:ensure_loaded/1` walks the code server. On success
%% we cache `true` permanently — telemetry doesn't unload at runtime.
%% On failure (module not found, not loadable) we return `false`
%% WITHOUT caching, so that if the consumer brings telemetry up later
%% (`application:start(telemetry)`) the next call observes it.
%%
%% Trade-off documented in observability.md §11: positive-only caching
%% costs at most one `code:ensure_loaded/1` per emit while telemetry is
%% absent (microseconds), and zero per emit once present. Negative
%% caching would be cheaper in the absent case but would prevent
%% on-the-fly enablement, contradicting the "no-op safe, never crashes"
%% contract.
telemetry_loaded() ->
    case persistent_term:get(?LOADED_KEY, undefined) of
        true ->
            true;
        undefined ->
            case code:ensure_loaded(telemetry) of
                {module, telemetry} ->
                    persistent_term:put(?LOADED_KEY, true),
                    true;
                _ ->
                    false
            end
    end.
