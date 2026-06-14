-module(erli18n_app).

-moduledoc """
Callback de `application` da biblioteca erli18n: o ponto de entrada OTP
que liga e desliga a árvore de processos.

## O que é e qual problema resolve

Este é o módulo apontado por `{mod, {erli18n_app, []}}` em
`erli18n.app.src`. Quando alguém roda `application:ensure_all_started(erli18n)`
(ou o release boot), o OTP chama `start/2` aqui, e quando a aplicação
para, chama `stop/1`. Não há nada de erli18n-específico nele além de
delegar: ele existe porque o `application_controller` exige um módulo de
callback, não porque haja lógica de i18n a executar no boot.

## Modelo mental (para o mantenedor)

Pense neste módulo como a casca mais fina possível em volta da árvore de
supervisão. Toda a complexidade load-bearing está **um pulo adiante**:

- `start/2` chama `erli18n_sup:start_link/0` e devolve o `{ok, Pid}` do
  supervisor raiz *cru*, sem embrulhar. Esse `Pid` vira o pid da
  aplicação que o `application_controller` passa a monitorar.
- A topologia real vive em `erli18n_sup`: estratégia `rest_for_one` com
  dois filhos em ordem load-bearing — `erli18n_table_owner` (dono/heir da
  tabela ETS) **antes** de `erli18n_server` (worker/writer). Um crash do
  worker não derruba o dono, então a tabela `erli18n_catalog` e todos os
  catálogos carregados sobrevivem ao restart e são reentregues via
  `ETS-TRANSFER`. Isso é correção de bug, não detalhe acidental: ver
  `erli18n_sup` e o Finding #10 da revisão técnica.
- **Estado próprio deste módulo: zero.** Não toca ETS, não toca
  dicionário de processo, não lê nem escreve `application:get_env/2`. Os
  defaults de `env` (`emit_lookup_telemetry`, `memory_warning_threshold`,
  `memory_warning_rate_limit_seconds`) são declarados em `erli18n.app.src`
  e consumidos por `erli18n_telemetry` — nunca aqui.
- Por isso `stop/1` ignora o `State` e devolve `ok`: não existe recurso a
  liberar neste nível. O encerramento ordenado dos filhos (incluindo o
  `terminate/2` do worker e do dono) é responsabilidade da árvore de
  supervisão, disparada pelo `application_controller` *depois* que
  `stop/1` retorna.

## Quando um dev encosta neste módulo

Quase nunca de forma direta. O caminho normal é:

- **Consumidor da lib:** roda `application:ensure_all_started(erli18n)` e
  segue para `erli18n:gettext/3`, `erli18n_server:ensure_loaded/3` etc.
  Não importa este módulo.
- **Mantenedor:** mexe aqui só se a *forma* do boot mudar — por exemplo,
  passar a ler `Args` de `{mod, {erli18n_app, Args}}`, fazer setup
  one-shot no start, ou tratar `Type` (`normal` vs takeover/failover em
  cenário distribuído). Hoje ambos os argumentos são ignorados de
  propósito. Se for adicionar um novo processo de topo, o lugar é
  `erli18n_sup:init/1`, não aqui — `start/2` deve continuar um one-liner.

## Quickstart

```erlang
1> {ok, Started} = application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> lists:member(erli18n, Started).
true
3> is_pid(whereis(erli18n_sup)).
true
4> is_pid(whereis(erli18n_server)).
true
5> application:stop(erli18n).
ok
```

> A lista exata em `{ok, Started}` depende do ambiente. Como `telemetry`
> está declarado em `optional_applications` no `erli18n.app.src`, se ela
> estiver presente mas ainda não iniciada, `ensure_all_started/1` a sobe
> junto e a inclui na lista (ex.: `{ok,[telemetry,erli18n]}`). O literal
> `{ok,[erli18n]}` acima vale quando `telemetry` está ausente ou já no
> ar; por isso o teste robusto é `lists:member(erli18n, Started)`, não
> uma comparação com a lista inteira.

Veja `start/2` e `stop/1` para a semântica de cada callback.
""".

-behaviour(application).

-export([start/2, stop/1]).

-doc """
Callback `c:application:start/2`: sobe a árvore de supervisão raiz.

Delega cru para `erli18n_sup:start_link/0` e devolve o `{ok, Pid}` do
supervisor sem nenhum embrulho. Esse `Pid` é o pid que o
`application_controller` adota como pid da aplicação `erli18n` e passa a
monitorar; quando ele morre, a aplicação é considerada terminada.

## Parâmetros

- `Type` — tipo de partida que o OTP passa (`normal` no boot comum;
  `{takeover, Node}` / `{failover, Node}` em aplicações distribuídas).
  **Ignorado**: o boot do erli18n é idêntico em qualquer modo, então não
  há ramificação por `Type`.
- `Args` — o termo de `{mod, {erli18n_app, Args}}` em `erli18n.app.src`,
  hoje `[]`. **Ignorado**: nenhuma configuração de boot é lida daqui (os
  defaults de runtime vivem em `env` e são lidos por `erli18n_telemetry`,
  não por este callback).

## Retorno

- `{ok, Pid}` — em sucesso, repassado direto de `erli18n_sup:start_link/0`.
- Qualquer `{error, Reason}` vindo de baixo **propaga intacto**: este
  callback não tem `try`/`catch` nem fallback. O caso normal de falha de
  um filho no boot é um `{error, {shutdown, Reason}}` — a forma que
  `supervisor:start_link/3` devolve (e que a seção *Retorno* de
  `erli18n_sup:start_link/0` já documenta) quando um filho falha o próprio
  `init/1`, p.ex. o `erli18n_table_owner` não conseguindo criar a tabela
  ETS ou o `erli18n_server` não conseguindo reclamá-la. É esse o termo que
  o mantenedor verá para casar. Um erro aqui faz `ensure_all_started/1`
  falhar e a aplicação não sobe — o comportamento OTP correto, sem
  mascaramento.

## Exemplo

```erlang
1> {ok, Started} = application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> lists:member(erli18n, Started).
true
3> SupPid = whereis(erli18n_sup), is_pid(SupPid).
true
```

> O literal `{ok,[erli18n]}` na linha 1 vale quando `telemetry` (declarada
> em `optional_applications`) está ausente ou já iniciada; se ela for
> subida agora, aparece também na lista. Daí o `lists:member/2` em vez de
> comparar a lista inteira.

Função irmã: `stop/1`. Topologia iniciada: `erli18n_sup:init/1`.
""".
start(_Type, _Args) ->
    erli18n_sup:start_link().

-doc """
Callback `c:application:stop/1`: ponto de limpeza pós-shutdown — no-op aqui.

O `application_controller` chama `stop/1` **depois** de já ter encerrado a
árvore de supervisão (terminando os filhos em ordem inversa de partida:
`erli18n_server` antes de `erli18n_table_owner`, cada um rodando seu
próprio `terminate/2`). Quando o controle chega aqui, não resta nenhum
recurso deste módulo a liberar, porque ele não criou nenhum — sem ETS, sem
dicionário de processo, sem ports. Por isso o corpo é apenas `ok`.

## Parâmetros

- `State` — o valor que `start/2` teria devolvido como segundo elemento de
  `{ok, Pid, State}`. Como `start/2` retorna a 2-tupla `{ok, Pid}` (sem
  `State`), é o `application_controller` que substitui o `State` por `[]`
  ao chamar este callback: quando o `start/2` usa a forma `{ok, Pid}` em
  vez de `{ok, Pid, State}`, o controller normaliza o estado ausente para
  `[]`. Por isso o argumento aqui é `[]`. **Ignorado** de qualquer forma:
  não há estado a desfazer.

## Retorno

- `ok` — sempre. Este callback não tem caminho de erro nem de crash: é
  total e não inspeciona o argumento.

## Exemplo

```erlang
1> application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> application:stop(erli18n).
ok
3> whereis(erli18n_sup).
undefined
```

Função irmã: `start/2`. O encerramento dos filhos é da árvore de
supervisão: ver `erli18n_sup`.
""".
stop(_State) ->
    ok.
