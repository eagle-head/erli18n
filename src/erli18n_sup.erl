-module(erli18n_sup).

-moduledoc """
Supervisor raiz da árvore de aplicação do erli18n.

## O que é e o que resolve

Este é o único supervisor da biblioteca: é o processo iniciado por
`erli18n_app:start/2` e a raiz da árvore OTP. A sua única
responsabilidade é manter vivos — e na ordem certa — os dois processos
que sustentam o runtime de tradução:

- `erli18n_table_owner` — o dono dedicado e longevo da tabela ETS de
  catálogos (`erli18n_catalog`). Cria a tabela, mantém-se como `heir`
  dela e a entrega ao worker via `ets:give_away/3`.
- `erli18n_server` — o worker/writer. Recebe a tabela do dono no seu
  `init/1` e serializa todas as escritas (load/reload/unload de
  catálogos) através do seu `gen_server`.

O leitor não passa por nenhum destes processos: `lookup_*` lê direto da
tabela ETS `protected`/`named_table` a partir do processo chamador, sem
bloqueio. Esta árvore existe apenas para garantir **propriedade** e
**durabilidade** da tabela, não para mediar o hot path de leitura.

## Modelo mental (owner/heir e por que a ordem importa)

O coração do design — e o motivo de este módulo não ser plumbing OTP
trivial — é a separação entre **propriedade** (quem segura a tabela ETS)
e **mutação** (quem escreve nela). A tabela é destruída pelo ETS no
instante em que o seu dono morre; se o dono fosse o próprio worker (o
processo mais propenso a crashar, pois é quem muta a tabela), qualquer
crash apagaria **todos** os catálogos carregados, transformando um
soluço transitório em perda total de disponibilidade das traduções até
o consumidor recarregar cada catálogo (Finding #10,
`ets-owned-by-server-no-heir-crash-loses-all-catalogs`).

A solução tem duas peças que trabalham juntas:

1. Um **dono dedicado** (`erli18n_table_owner`) que cria a tabela com
   `{heir, self(), _}` e nunca a muta — logo, quase nunca crasha.
2. Uma topologia de supervisão `rest_for_one` com o **dono primeiro** e
   o **worker depois** na lista de filhos.

Pela semântica do `rest_for_one`, quando um filho morre apenas os
filhos que vêm **depois** dele na ordem de início são reiniciados. Como
o worker vem depois do dono:

- **Crash do worker** (comum): o dono — que vem antes — não é
  terminado. O ETS dispara `'ETS-TRANSFER'` e devolve a tabela intacta
  ao dono (que é o `heir`); o worker reiniciado readquire a **mesma**
  tabela via novo `give_away/3`. Nenhum catálogo é perdido.
- **Crash do dono** (raro, pois ele nada muta): o `rest_for_one`
  reinicia o dono e, em cascata, o worker. O dono recria a tabela no
  seu `init/1` e o ciclo de handoff se restabelece. Os catálogos se
  perdem só neste caso raro.

Inverter a ordem dos filhos reintroduz o bug do Finding #10: por isso a
ordem em `init/1` é load-bearing, não cosmética.

## Configuração fixa nesta v0.1

A intensidade de reinício é `{intensity => 5, period => 10}` (no máximo
5 reinícios em 10 segundos antes do supervisor desistir) e está
hardcoded nesta versão por decisão registrada na AMB-002 — não é
configurável via `application:get_env/2`. Ambos os filhos são
`permanent` com `shutdown => 5000`.

## Quando um dev encosta neste módulo

Quase nunca diretamente. Consumidores da biblioteca chamam
`application:ensure_all_started(erli18n)`, que sobe a aplicação e, por
ela, este supervisor. Mexer aqui só faz sentido ao alterar a topologia
da árvore (adicionar/remover um filho, mudar estratégia ou intensidade).
Antes de qualquer mexida na **ordem** dos `ChildSpecs`, releia a seção
do modelo mental acima.

## Quickstart

```erlang
1> {ok, _Started} = application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> whereis(erli18n_sup) =/= undefined.
true
3> [Id || {Id, _Pid, _Type, _Mods} <- supervisor:which_children(erli18n_sup)].
[erli18n_table_owner,erli18n_server]
```

A lista em `_Started` pode variar: o `erli18n.app.src` declara `telemetry`
em `optional_applications`, então, se a app opcional estiver presente e
ainda não tiver sido iniciada, ela aparece junto (ex.:
`{ok, [telemetry, erli18n]}`). `kernel` e `stdlib` já estão no ar e nunca
entram nessa lista. Por isso o exemplo casa com `{ok, _Started}` em vez de
comparar a saída literalmente.

## Funções-chave

- `start_link/0` — ponto de entrada, chamado por `erli18n_app:start/2`.
- `init/1` — callback do `supervisor`; define estratégia, intensidade e
  os `ChildSpecs` na ordem load-bearing.
""".

-behaviour(supervisor).

-export([start_link/0, init/1]).

-doc """
Inicia o supervisor raiz, registrado localmente como `erli18n_sup`.

Ponto de entrada da árvore: é o que `erli18n_app:start/2` chama. Delega
para `supervisor:start_link/3` com `{local, ?MODULE}`, o que faz o
supervisor responder pelo nome `erli18n_sup` (usável em
`supervisor:which_children/1`, `whereis/1`, etc.) e invoca `init/1` para
montar os filhos.

## Retorno

- `{ok, Pid}` — supervisor e ambos os filhos
  (`erli18n_table_owner` e `erli18n_server`) iniciaram com sucesso.
- `{error, {already_started, Pid}}` — já existe um processo registrado
  sob `erli18n_sup` (a aplicação já está no ar). Iniciar a aplicação
  duas vezes via OTP não chega aqui; isto só aparece em chamadas manuais.
- `{error, {shutdown, _}}` — algum filho falhou no próprio `init/1`
  (ex.: o handoff `claim_table/0` do worker não completou). O supervisor
  desfaz o que subiu e propaga o erro.

Crasha (link com o chamador) apenas se houver erro de programação na
construção dos `ChildSpecs` de `init/1` — o que, neste módulo, é
estático e não depende de entrada externa.

## Exemplo

```erlang
1> {ok, Pid} = erli18n_sup:start_link().
{ok,<0.215.0>}
2> Pid =:= whereis(erli18n_sup).
true
3> erli18n_sup:start_link().
{error,{already_started,<0.215.0>}}
```

A terceira chamada demonstra o modo de falha descrito acima: com o
supervisor já registrado sob `erli18n_sup`, um segundo `start_link/0`
manual retorna `{error, {already_started, Pid}}` com o `Pid` do processo
existente — sem derrubar nem reiniciar nada.

Veja também `init/1` para a definição da árvore que esta função instala.
""".
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Supervisor intensity {5, 10} hardcoded in v0.1 per AMB-002.
%%
%% Finding #10 (ets-owned-by-server-no-heir-crash-loses-all-catalogs):
%% `rest_for_one' with the table OWNER started before the WORKER. A crash
%% of the worker (the process that mutates the catalog table and thus the
%% one most likely to crash) does NOT terminate the owner (it comes
%% earlier in the start order), so the table and every loaded catalog
%% survive and are handed back to the restarted worker. A crash of the
%% owner (rare — it mutates nothing) restarts the worker too, and the
%% owner recreates the table on the way back up.
-doc """
Callback `c:supervisor:init/1` — define a forma da árvore de supervisão.

Chamado uma vez por `start_link/0` (via `supervisor:start_link/3`).
Recebe o argumento `[]` passado em `start_link/0` e devolve
`{ok, {SupFlags, ChildSpecs}}`. É puramente declarativo: monta mapas e
não tem efeitos colaterais nem caminhos de erro próprios.

## SupFlags

- `strategy => rest_for_one` — load-bearing. Garante que o crash do
  worker (que vem **depois** do dono na ordem) não derrube o dono, e que
  o crash do dono (que vem **antes**) reinicie também o worker em
  cascata. Ver o modelo mental no `-moduledoc` para o porquê.
- `intensity => 5`, `period => 10` — no máximo 5 reinícios em 10
  segundos; ao exceder, o supervisor desiste e propaga a falha para
  cima. Valores fixos nesta v0.1 (AMB-002), não configuráveis.

## ChildSpecs (a ORDEM é load-bearing)

A lista devolvida é `[Owner, Server]`, exatamente nesta ordem:

1. `erli18n_table_owner` — `permanent`, `worker`, `shutdown => 5000`.
   Dono/`heir` da tabela ETS `erli18n_catalog`. Sobe primeiro para
   existir e segurar a tabela antes de o worker pedir o handoff. A
   mecânica do handoff/reclaim que sustenta a sobrevivência da tabela
   no crash do worker vive em `erli18n_table_owner:handle_info/2` (a
   cláusula `'ETS-TRANSFER'` que casa `?ETS_HEIR_DATA` e reavida a
   tabela) e em `erli18n_table_owner:handle_call/3` (o
   `ets:give_away/3` defensivo dono->worker, via `safe_give_away/2`); é
   lá que se valida a afirmação de que nenhum catálogo é perdido.
2. `erli18n_server` — `permanent`, `worker`, `shutdown => 5000`.
   Writer dos catálogos. No seu `init/1` chama
   `erli18n_table_owner:claim_table/0` para receber a tabela via
   `ets:give_away/3`; por isso depende de o dono já estar no ar.

**Inverter a ordem reintroduz o Finding #10**
(`ets-owned-by-server-no-heir-crash-loses-all-catalogs`): com o worker
antes do dono, um crash do worker passaria a terminar o dono em cascata
(semântica do `rest_for_one`), a tabela seria destruída e todos os
catálogos carregados se perderiam.

## Retorno

Sempre `{ok, {SupFlags, ChildSpecs}}`. Não há cláusula de erro: um
`ChildSpec` malformado seria um bug de programação detectado pelo
`supervisor` ao validar a árvore, não um modo de falha em runtime.

## Exemplo

```erlang
1> {ok, {SupFlags, Children}} = erli18n_sup:init([]).
2> maps:get(strategy, SupFlags).
rest_for_one
3> [maps:get(id, C) || C <- Children].
[erli18n_table_owner,erli18n_server]
```

Veja também `start_link/0`, que instala esta árvore.
""".
init([]) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 10
    },
    %% The dedicated, long-lived table owner. Holds the ETS catalog table
    %% as its own `heir' and hands it to the worker via `give_away/3'.
    Owner = #{
        id => erli18n_table_owner,
        start => {erli18n_table_owner, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [erli18n_table_owner]
    },
    %% The catalog writer. Claims the table from the owner in its `init/1'.
    Server = #{
        id => erli18n_server,
        start => {erli18n_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [erli18n_server]
    },
    %% Order is load-bearing: owner first, server second. Inverting it
    %% would reintroduce the catalog-loss bug.
    ChildSpecs = [Owner, Server],
    {ok, {SupFlags, ChildSpecs}}.
