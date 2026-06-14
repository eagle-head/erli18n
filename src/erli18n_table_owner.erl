%% @doc Dedicated owner of the `?ETS_TABLE' catalog table.
%%
%% Finding #10 (ets-owned-by-server-no-heir-crash-loses-all-catalogs):
%% the catalog table used to be created and owned by `erli18n_server',
%% which is also the only process that mutates it and therefore the
%% process most likely to crash. ETS destroys a table when its owner
%% dies, so any crash of the worker took every loaded catalog with it.
%%
%% This module separates table *ownership* from table *mutation*. Its
%% sole responsibility is to create the table, hold it as its own `heir',
%% give it away to the worker, and reclaim it (with all rows intact) when
%% the worker dies. The worker stays the only writer (the table is
%% `protected'); the owner never mutates the catalog, so its crash
%% surface is minimal.
%%
%% Topology (see `erli18n_sup'): `rest_for_one' with the owner started
%% BEFORE the worker. A worker crash does not terminate the owner (it
%% comes earlier in the start order), so the table survives and is handed
%% back to the restarted worker. An owner crash (rare — it mutates
%% nothing) restarts the worker too, and the owner recreates the table on
%% the way back up.
-module(erli18n_table_owner).

-moduledoc """
Dono dedicado e longevo da tabela ETS de catálogos (`?ETS_TABLE`), o
`heir` que faz os catálogos carregados sobreviverem a um crash do worker.

## O que é e que problema resolve

O ETS destrói uma tabela quando seu *dono* (owner) morre. Antes deste
módulo, a tabela de catálogos era criada e possuída pelo próprio
`erli18n_server` — que também é o único processo que a muta e, portanto, o
mais propenso a crashar. Qualquer término do worker (um `badmatch` numa
cláusula, um `exit(Pid, kill)` operacional, um bug futuro) levava junto
TODOS os catálogos carregados: o supervisor reiniciava o worker, mas ele
ressurgia com uma tabela nova e vazia, e cada `lookup_*` passava a devolver
o msgid cru até que cada catálogo fosse recarregado pelo consumidor. Uma
falha transitória virava perda total de disponibilidade das traduções
(Finding #10, `ets-owned-by-server-no-heir-crash-loses-all-catalogs`).

Este módulo separa *propriedade* de *mutação*. Sua única
responsabilidade é: criar a tabela, segurá-la como seu próprio `heir`,
entregá-la (`give_away`) ao worker e reavê-la — com todas as linhas
intactas — quando o worker morre, re-armando para a próxima reivindicação.

## Escopo: o que sobrevive vs. o que é reconstruído

Este owner preserva apenas a tabela de DADOS (`?ETS_TABLE`,
`erli18n_catalog`) — as linhas de catálogo. O `erli18n` mantém uma SEGUNDA
tabela, o índice O(1) por catálogo (`?CATALOG_INDEX_TABLE`,
`erli18n_catalog_index`), que NÃO é gerida por este módulo: ela é estado
privado do worker (`erli18n_server`), `protected` e owned por ele, e por
isso MORRE junto com o worker num crash. Não há heir para o índice de
propósito: ele é estado barato e derivável, reconstruído em
`erli18n_server:init/1` (via `rebuild_catalog_index/0`) a partir das linhas
sobreviventes da tabela de dados — um único passo O(linhas), nunca no
hot-path de carga. Em resumo: o padrão heir aqui salva os DADOS de
tradução; o índice de aceleração é re-derivado deles no boot do worker.

## Modelo mental

- *Propriedade vs. mutação.* O dono possui a tabela mas nunca escreve nela.
  O worker (`erli18n_server`) é o único *writer*. A tabela é `protected`:
  só o dono corrente escreve; qualquer processo lê. Como o dono nada muta,
  sua superfície de crash é mínima — ele praticamente nunca cai.
- *Quem é o dono ao longo do tempo.* No boot, o dono cria a tabela e é o
  proprietário (leituras já funcionam). Ao reivindicação do worker, a
  propriedade passa para o worker via `ets:give_away/3`. Quando o worker
  morre, o ETS devolve a propriedade ao dono (o `heir`) automaticamente,
  com todas as linhas preservadas. O dono re-arma e aguarda o próximo
  `claim` do worker reiniciado.
- *Tabela nomeada e leituras lock-free.* A tabela é `named_table`, então o
  hot-path de leitura do `erli18n` acessa-a pelo nome (`?ETS_TABLE`),
  direto do processo chamador, sem passar por nenhum gen_server. A troca de
  dono entre worker e heir é transparente para os leitores — o nome nunca
  muda.
- *Dois marcadores de transferência.* `?ETS_HANDOFF_DATA` rotula o
  give_away deliberado dono->worker; `?ETS_HEIR_DATA` rotula o retorno
  automático worker-morto->dono (reclaim do heir). Cada receptor casa
  exatamente a transferência que espera.
- *Topologia load-bearing.* Sob a estratégia `rest_for_one` do
  `erli18n_sup`, o dono sobe ANTES do worker. Um crash do worker não
  derruba o dono (ele vem antes na ordem de start), então a tabela
  sobrevive; um crash do dono reinicia o worker também, e o novo dono
  recria a tabela do zero. Inverter a ordem reintroduz o Finding #10.

## Quando um dev encosta neste módulo

Quase nunca, diretamente. O consumidor da biblioteca usa `erli18n` e
`erli18n_server` e não toca aqui. O único ponto de contato em produção é
`erli18n_server:init/1`, que chama `claim_table/0` para receber a tabela.
Você lê este módulo se: está depurando perda de catálogos após um crash,
mexendo na ordem de filhos do supervisor, ou investigando o evento de log
`catalog_table_reclaimed`.

## Quickstart (sob a árvore de supervisão real)

```erlang
1> application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> ok = erli18n_server:ensure_loaded(my_domain, <<"fr">>,
2>     <<"priv/locale/fr/LC_MESSAGES/my_domain.po">>).
ok
3> %% O dono é um processo registrado, vivo e separado do worker:
3> is_pid(whereis(erli18n_table_owner)).
true
4> ets:info(erli18n_catalog, owner) =:= whereis(erli18n_server).
true
5> ets:info(erli18n_catalog, heir) =:= whereis(erli18n_table_owner).
true
6> %% Mate o worker; o dono reaver a tabela e o worker reiniciado a reassume.
6> exit(whereis(erli18n_server), kill), timer:sleep(50).
ok
7> erli18n:gettext(my_domain, <<"Hello, world">>, <<"fr">>).
<<"Bonjour, monde">>
```

## Funções e callbacks-chave

- `start_link/0` — inicia o dono (chamado pelo `erli18n_sup`).
- `claim_table/0` — o worker pede a tabela ao dono (chamado em
  `erli18n_server:init/1`).
- `init/1` — cria a tabela ETS e fixa o dono como `heir`.
- `handle_call/3` — trata `{claim, WorkerPid}` e faz o give_away.
- `handle_info/2` — coração do padrão owner/heir: reclaim e `'DOWN'`.
""".

-behaviour(gen_server).

-include("erli18n.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/0, claim_table/0]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-doc """
Estado interno do dono. Carrega a tabela (nomeada) e o rastreamento do
worker que a segura no momento:

- `table` — a `ets:table()` de catálogos; constante por toda a vida do
  processo (recriada apenas se o dono em si reiniciar).
- `worker` — `{Pid, Mon}` enquanto um worker corrente segura a tabela
  (`Mon` é o monitor desse worker), ou `undefined` quando a propriedade
  está com o dono: no boot, antes do primeiro `claim`, e após reaver a
  tabela de um worker morto. O valor `undefined` é o gatilho que permite o
  próximo give_away sem risco de duplicidade.
""".
-type state() :: #{
    table := ets:table(),
    worker := undefined | {pid(), reference()}
}.

-doc """
Inicia o gen_server dono da tabela, registrado localmente sob
`?TABLE_OWNER` (`erli18n_table_owner`).

Chamado pelo `erli18n_sup` como o PRIMEIRO filho (antes do
`erli18n_server`), ordem que é load-bearing para o padrão owner/heir. Em
`init/1` o dono cria a tabela ETS de catálogos e fixa a si mesmo como
`heir`; ao retornar, a tabela já existe e está pronta para leituras e para
o primeiro `claim_table/0`.

## Retorno

O resultado padrão de `gen_server:start_link/4`: `{ok, Pid}` em sucesso. O
processo é registrado localmente, então `whereis(erli18n_table_owner)`
passa a resolver para `Pid`. Um segundo `start_link/0` com o nome já
registrado falharia com `{error, {already_started, Pid}}` — na prática isso
não acontece porque só o supervisor o inicia.

## Exemplo

```erlang
1> {ok, Pid} = erli18n_table_owner:start_link().
{ok,<0.200.0>}
2> Pid =:= whereis(erli18n_table_owner).
true
3> ets:info(erli18n_catalog, heir) =:= Pid.
true
```

Veja também `claim_table/0` (o worker reivindica a tabela) e `init/1` (a
criação da tabela).
""".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?TABLE_OWNER}, ?MODULE, [], []).

%% Called by `erli18n_server' in its own `init/1': asks the owner to hand
%% the table over via `give_away/3'. Synchronous — once it returns `ok'
%% the initial `'ETS-TRANSFER'' is (or is about to be) in the caller's
%% mailbox. The owner only gives the table to a live, local worker.
-doc """
Reivindica a tabela de catálogos: pede ao dono que a entregue via
`ets:give_away/3` para o processo chamador. Após o retorno, o chamador
torna-se o dono (writer) da tabela.

Chamada pelo `erli18n_server` dentro do próprio `init/1`, que então faz um
`receive` do `{'ETS-TRANSFER', ?ETS_TABLE, _OwnerPid, ?ETS_HANDOFF_DATA}`
para consumir a tabela. NÃO recebe argumentos: o destino do give_away é
sempre `self()` (o chamador), nunca um pid arbitrário — esse é o limite de
segurança que impede um processo de redirecionar a tabela para outro.

## Retorno

Sempre `ok` quando a call vinga (é um `gen_server:call/3` com timeout
`infinity`, casado contra `ok = ...`). Ao retornar, a mensagem
`{'ETS-TRANSFER', ...}` inicial já está — ou está prestes a estar — na
mailbox do chamador. A síncronia garante a ordem: o `ok` chega depois de o
dono ter disparado (ou ao menos enfileirado) o give_away.

## Modos de falha

- Se `whereis(erli18n_table_owner)` for `undefined` (dono não iniciado), a
  call falha com `noproc`. Sob a árvore de supervisão isso não ocorre: o
  dono é iniciado antes do worker (`rest_for_one`).
- Se o worker chamador morrer na janela entre o give_away e o consumo, o
  dono detecta o give_away falho — `ets:give_away/3` lança `badarg`, que
  `safe_give_away/2` converte em `{error, give_away_failed}` — e mantém a
  tabela consigo; veja `handle_call/3` e `safe_give_away/2`.
- `timeout` `infinity` é deliberado: o handoff é parte do boot e não deve
  ser cortado por um prazo arbitrário. O `erli18n_server` impõe seu próprio
  prazo de 5 s no `receive` do `'ETS-TRANSFER'` e crasha se estourar.

## Exemplo

```erlang
1> %% Executado de dentro do processo que vai virar dono da tabela:
1> ok = erli18n_table_owner:claim_table().
ok
2> receive {'ETS-TRANSFER', erli18n_catalog, _Owner, _Tag} -> got_table end.
got_table
3> ets:info(erli18n_catalog, owner) =:= self().
true
```

Veja também `handle_call/3` (lado do dono que atende ao `{claim, _}`) e
`start_link/0`.
""".
-spec claim_table() -> ok.
claim_table() ->
    ok = gen_server:call(?TABLE_OWNER, {claim, self()}, infinity).

-doc """
Callback `c:gen_server:init/1`. CRIA a tabela ETS de catálogos e devolve o
estado inicial sem worker.

## Comportamento

Cria `?ETS_TABLE` (`erli18n_catalog`) com as opções (cada uma
load-bearing):

- `set` — chaves únicas; uma linha por entrada de catálogo.
- `protected` — só o dono corrente escreve; qualquer processo lê. É o que
  preserva a invariante de writer único (RISK-012) mantendo o hot-path de
  leitura aberto a todos.
- `named_table` — acesso pelo átomo `erli18n_catalog`, para que os leitores
  e o worker reiniciado encontrem a MESMA tabela apesar das trocas de dono.
- `{read_concurrency, true}` — otimiza o padrão "muitas leituras
  concorrentes, escritas serializadas pelo worker".
- `{keypos, 1}` — a chave é o 1º elemento da tupla-linha.
- `{heir, self(), ?ETS_HEIR_DATA}` — o cerne do Finding #10: o dono é o
  herdeiro de si mesmo. Se o worker (futuro dono) morrer, o ETS devolve a
  tabela a ESTE processo carregando o marcador `?ETS_HEIR_DATA`.

Enquanto nenhum worker reivindicou a tabela, o dono é o proprietário e as
leituras já funcionam (tabela nomeada e protegida) — útil entre o boot do
dono e o primeiro `claim_table/0` do worker.

## Retorno

`{ok, #{table => Table, worker => undefined}}`. O `worker => undefined`
marca que a propriedade está com o dono e libera o primeiro give_away.

## Modos de falha

`ets:new/2` pode lançar `badarg` se a tabela nomeada já existir (p.ex. um
dono fantasma de uma geração anterior ainda viva) — o que sob a árvore de
supervisão não acontece, pois a tabela morre junto com seu dono. Um crash
aqui aborta o start do dono; o supervisor reavalia.

## Exemplo

Em produção `init/1` é chamado UMA vez, pelo `gen_server` no
`start_link/0`, sob a árvore de supervisão. O exemplo abaixo só funciona
num node "limpo", onde a tabela nomeada `erli18n_catalog` ainda NÃO existe
(ou seja, com a app `erli18n` parada e sem um dono/worker vivo). Chamar
`init([])` uma segunda vez, ou com a app já de pé, faz `ets:new/2` lançar
`badarg` por tabela nomeada duplicada (veja "Modos de falha" acima).

```erlang
1> {ok, State} = erli18n_table_owner:init([]).
{ok,#{table => erli18n_catalog,worker => undefined}}
2> ets:info(erli18n_catalog, protection).
protected
3> ets:info(erli18n_catalog, named_table).
true
```

Para inspecionar o dono com a app já iniciada, use o caminho via supervisor
(como o moduledoc faz com `whereis/1` e `ets:info/2`) em vez de chamar
`init/1` de novo.

Veja também `handle_info/2` (a cláusula `'ETS-TRANSFER'` que casa
`?ETS_HEIR_DATA`) e `terminate/2`.
""".
-spec init([]) -> {ok, state()}.
init([]) ->
    %% The owner CREATES the table and is its own heir. While no worker
    %% has claimed it, the owner is the proprietor — reads already work
    %% (named/protected table) even before the first handoff.
    Table = ets:new(?ETS_TABLE, [
        set,
        protected,
        named_table,
        {read_concurrency, true},
        {keypos, 1},
        {heir, self(), ?ETS_HEIR_DATA}
    ]),
    {ok, #{table => Table, worker => undefined}}.

-doc """
Callback `c:gen_server:handle_call/3`. Entrega a tabela ao worker que a
reivindica.

## Protocolo de mensagens

- `{claim, WorkerPid}` (de `claim_table/0`, com `WorkerPid = self()` do
  chamador) — o caminho central:
  1. `reclaim_if_needed/1` garante que o dono é o proprietário corrente,
     descartando o monitor de qualquer worker anterior (a posse física já
     voltou, ou voltará, via `'ETS-TRANSFER'`).
  2. monitora o novo `WorkerPid` para detectar sua morte futura.
  3. tenta `safe_give_away/2`. Se vinga (retorna `ok`), guarda
     `{WorkerPid, Mon}` em `worker` e responde `ok`. Se o worker morreu na
     janela de handoff, `safe_give_away/2` captura o `badarg` de
     `ets:give_away/3` e devolve `{error, give_away_failed}` (o átomo
     concreto que esta cláusula casa em `{error, _}`); então o dono solta o
     monitor, mantém a tabela consigo (`worker => undefined`) e mesmo assim
     responde `ok` — o supervisor reinicia o worker, que chamará
     `claim_table/0` de novo.
- Qualquer outra call — responde `{error, unknown_call}` sem alterar o
  estado. O dono não expõe outra API síncrona.

A guarda `is_pid(WorkerPid)` no cabeçalho da cláusula garante que um
`{claim, NaoPid}` malformado caia na cláusula catch-all e receba
`{error, unknown_call}` em vez de crashar.

## Invariante

Em ambos os desfechos do claim a call responde `ok`; o estado resultante
ou tem `worker => {Pid, Mon}` (handoff bem-sucedido) ou
`worker => undefined` (worker morreu na janela). Nunca fica com um monitor
órfão.

## Exemplo

```erlang
1> %% O worker chama isto indiretamente via claim_table/0:
1> ok = gen_server:call(erli18n_table_owner, {claim, self()}, infinity).
ok
2> gen_server:call(erli18n_table_owner, {ping, qualquer}).
{error,unknown_call}
```

Veja também `claim_table/0` (lado do worker), `reclaim_if_needed/1`,
`safe_give_away/2` e `handle_info/2`.
""".
-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, ok | {error, unknown_call}, state()}.
handle_call({claim, WorkerPid}, _From, #{table := Table} = State) when
    is_pid(WorkerPid)
->
    %% Precondition of `give_away/3': the owner must be the current
    %% proprietor. We only get here either at boot (owner holds it) or
    %% after a heir reclaim (owner holds it again). Any stale worker
    %% monitor is dropped first.
    NewState = reclaim_if_needed(State),
    Mon = erlang:monitor(process, WorkerPid),
    %% `give_away/3' requires the target to be alive, local, and not
    %% already the owner. The monitor above covers the "worker died in
    %% the handoff window" race: `give_away/3' would raise `badarg', so
    %% we guard it.
    case safe_give_away(Table, WorkerPid) of
        ok ->
            {reply, ok, NewState#{worker => {WorkerPid, Mon}}};
        {error, _} ->
            %% Worker died in the handoff window. Drop the monitor; the
            %% table stays with us. The supervisor will restart the
            %% worker and it will call `claim_table/0' again.
            _ = erlang:demonitor(Mon, [flush]),
            {reply, ok, NewState#{worker => undefined}}
    end;
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

-doc """
Callback `c:gen_server:handle_cast/2`. O dono não tem protocolo assíncrono:
ignora qualquer cast e mantém o estado inalterado. Existe apenas para
satisfazer o contrato do `gen_server` (toda mutação relevante é dirigida
por `handle_call/3` e `handle_info/2`).
""".
-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc """
Callback `c:gen_server:handle_info/2`. Coração do padrão owner/heir: é aqui
que a tabela retorna ao dono quando o worker morre.

## Protocolo de mensagens

- `{'ETS-TRANSFER', Table, _FromPid, ?ETS_HEIR_DATA}` — o worker que
  segurava a tabela morreu e o ETS devolveu a propriedade ao dono (o
  `heir`) com TODAS as linhas intactas. A cláusula casa só quando o
  `Table` recebido é o mesmo do estado e o marcador é `?ETS_HEIR_DATA`
  (distingue-o do give_away dono->worker). Solta o monitor do worker
  (`drop_worker_monitor/1`), emite o log `catalog_table_reclaimed` com o
  tamanho da tabela (via `safe_size/1`) e re-arma `worker => undefined`
  para o próximo `claim`.
- `{'DOWN', Mon, process, Pid, _Reason}` do worker corrente (casa apenas
  quando `worker` é exatamente `{Pid, Mon}`) — o `'DOWN'` pode chegar ANTES
  do `'ETS-TRANSFER'`. A cláusula deliberadamente NÃO toca na tabela (o ETS
  a transferirá de volta); apenas marca `worker => undefined` para evitar
  um give_away duplo. A posse efetiva retorna na cláusula de
  `'ETS-TRANSFER'` acima.
- Qualquer outra mensagem — ignorada com segurança. Inclui `'DOWN'` /
  `'ETS-TRANSFER'` de gerações antigas (cujo monitor já não casa o estado
  corrente) e ruído. É seguro descartar: a tabela é nomeada e seu dono é
  sempre este processo ou o worker vivo.

## Invariante / ordenação

As duas mensagens do ciclo de morte do worker (`'DOWN'` e
`'ETS-TRANSFER'`) podem chegar em qualquer ordem. O estado converge para
`worker => undefined` em ambos os caminhos; a tabela só é considerada
"reavida e logada" no clause de `'ETS-TRANSFER'`. O efeito colateral
observável é o log `catalog_table_reclaimed` (domínio
`[erli18n, table_owner]`).

## Exemplo

```erlang
1> %% Com o worker segurando a tabela, mate-o e observe o reclaim:
1> Worker = whereis(erli18n_server).
<0.205.0>
2> exit(Worker, kill), timer:sleep(50).
ok
3> %% A tabela voltou ao dono (e logo será repassada ao worker reiniciado):
3> ets:info(erli18n_catalog, owner) =/= Worker.
true
```

Veja também `init/1` (onde `?ETS_HEIR_DATA` é fixado como heir data),
`handle_call/3` (o give_away de volta ao worker reiniciado) e
`drop_worker_monitor/1`.
""".
-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(
    {'ETS-TRANSFER', Table, _FromPid, ?ETS_HEIR_DATA},
    #{table := Table, worker := Worker} = State
) ->
    %% The worker that held the table died; ETS handed ownership back to
    %% us (the heir) with ALL rows intact. Re-arm: drop the monitor and
    %% wait for the restarted worker's next `claim'.
    _ = drop_worker_monitor(Worker),
    ?LOG_INFO(
        #{
            event => catalog_table_reclaimed,
            reason => worker_down,
            size => safe_size(Table)
        },
        #{domain => [erli18n, table_owner]}
    ),
    {noreply, State#{worker => undefined}};
handle_info(
    {'DOWN', Mon, process, Pid, _Reason},
    #{worker := {Pid, Mon}} = State
) ->
    %% `'DOWN'' can arrive before `'ETS-TRANSFER''. We do NOT touch the
    %% table here (ETS will transfer it); we only mark that there is no
    %% current worker to avoid a double give_away. Effective ownership
    %% returns in the `'ETS-TRANSFER'' clause above.
    {noreply, State#{worker => undefined}};
handle_info(_Info, State) ->
    %% `'DOWN''/`'ETS-TRANSFER'' from older generations (monitor no
    %% longer matches) or noise. Ignoring is safe: the table is named and
    %% its current owner is always this process or the live worker.
    {noreply, State}.

-doc """
Callback `c:gen_server:terminate/2`. No-op — não há recurso externo a
liberar.

Se o DONO cai, a tabela cai com ele (ele é o dono/heir e o ETS destrói a
tabela com o dono). Isso é aceitável e por design: sob `rest_for_one` o
worker (posterior na ordem de start) é reiniciado junto, e o novo dono
recria a tabela vazia em `init/1` — os catálogos precisariam ser
recarregados, mas isso só ocorre num crash do dono, que é raro porque ele
nada muta (superfície de crash mínima). O caso comum — crash do worker — é
o que o padrão heir protege, e esse caminho não passa por aqui.

Não há retorno significativo; devolve `ok`.
""".
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    %% If the OWNER goes down the table goes with it (it is the
    %% owner/heir). That is acceptable: under `rest_for_one' the worker
    %% (after the owner) is restarted too, and the new owner recreates the
    %% table. The owner mutates nothing, so its crash surface is minimal.
    ok.

-doc """
Callback `c:gen_server:code_change/3`. Sem migração de estado: devolve
`{ok, State}` inalterado. O estado é um mapa simples
(`#{table, worker}`) cujo formato não mudou entre versões; existe apenas
para satisfazer o contrato do `gen_server` em hot code upgrades.
""".
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =========================
%% Internal
%% =========================

-doc """
Garante que o dono está pronto para um novo handoff, descartando o
rastreamento de qualquer worker anterior.

Chamada no início de cada `{claim, _}` em `handle_call/3`. Se `worker` já é
`undefined`, devolve o estado intacto. Caso ainda haja um `{Pid, Mon}`
remanescente, solta o monitor (`drop_worker_monitor/1`) e zera para
`worker => undefined`. A posse FÍSICA da tabela não é mexida aqui: ela já
voltou — ou voltará — ao dono via `'ETS-TRANSFER'`; esta função só limpa o
estado lógico para evitar um monitor órfão antes do próximo give_away.
""".
-spec reclaim_if_needed(state()) -> state().
reclaim_if_needed(#{worker := undefined} = State) ->
    State;
reclaim_if_needed(#{worker := Worker} = State) ->
    _ = drop_worker_monitor(Worker),
    State#{worker => undefined}.

-doc """
Solta o monitor de um worker, se houver. Para `undefined` é um no-op; para
`{_Pid, Mon}` chama `erlang:demonitor(Mon, [flush])` — o `flush` remove da
mailbox qualquer `'DOWN'` já enfileirado daquele monitor, evitando que uma
geração antiga dispare a cláusula `'DOWN'` de `handle_info/2`. Sempre
devolve `ok`. Usada por `reclaim_if_needed/1` e pela cláusula
`'ETS-TRANSFER'` de `handle_info/2`.
""".
-spec drop_worker_monitor(undefined | {pid(), reference()}) -> ok.
drop_worker_monitor(undefined) ->
    ok;
drop_worker_monitor({_Pid, Mon}) ->
    _ = erlang:demonitor(Mon, [flush]),
    ok.

-doc """
Embrulho defensivo sobre `ets:give_away/3`.

A spec de `ets:give_away/3` é `true`, mas ela LANÇA `error:badarg` se o
destino não está apto — destino morto, não-local, ou já o dono. O caso que
importa aqui é a corrida em que `WorkerPid` morre na janela entre o
`erlang:monitor/2` e o give_away. Em vez de deixar o `badarg` propagar e
crashar o dono (o que perderia a tabela!), capturamos e devolvemos um
resultado tipado:

- `ok` — o give_away vingou; a propriedade passou para `WorkerPid`, que
  recebe um `'ETS-TRANSFER'` marcado com `?ETS_HANDOFF_DATA`.
- `{error, give_away_failed}` — o destino não estava apto; a tabela
  permanece com o dono. `handle_call/3` então solta o monitor e mantém
  `worker => undefined`.

Manter o `badarg` contido aqui é o que torna o dono praticamente
imune a crash mesmo sob corridas de boot/restart.
""".
-spec safe_give_away(ets:table(), pid()) -> ok | {error, give_away_failed}.
safe_give_away(Table, WorkerPid) ->
    try ets:give_away(Table, WorkerPid, ?ETS_HANDOFF_DATA) of
        true -> ok
    catch
        error:badarg -> {error, give_away_failed}
    end.

-doc """
Lê `ets:info(Table, size)` de forma tolerante, para uso no log
`catalog_table_reclaimed`. Devolve o número de linhas quando `ets:info/2`
retorna um inteiro não-negativo; em qualquer outro caso (p.ex. a tabela ter
sumido numa corrida, fazendo `ets:info/2` devolver `undefined`) devolve `0`
em vez de crashar. O propósito é puramente observacional: o reclaim nunca
deve falhar por causa do cálculo do tamanho para o log.
""".
-spec safe_size(ets:table()) -> non_neg_integer().
safe_size(Table) ->
    case ets:info(Table, size) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.
