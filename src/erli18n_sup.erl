-module(erli18n_sup).

-moduledoc """
Supervisor raiz do erli18n. Usa a estratégia `rest_for_one` e ordena os
filhos como `[erli18n_table_owner, erli18n_server]`: o dono da tabela ETS
(heir) sobe antes do worker, de modo que um crash do worker preserva os
catálogos carregados. Intensidade `{5, 10}` fixa nesta v0.1 (AMB-002).
""".

-behaviour(supervisor).

-export([start_link/0, init/1]).

-doc """
Inicia o supervisor raiz registrado localmente sob o nome do módulo.
Retorna `{ok, Pid}` em sucesso. Encaminha para `supervisor:start_link/3`.
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
Callback `supervisor:init/1`. Define a estratégia `rest_for_one` com
intensidade `5` em período `10` s e devolve dois filhos permanentes nesta
ordem (load-bearing): `erli18n_table_owner` (dono/heir da tabela ETS) e
`erli18n_server` (worker/writer). Inverter a ordem reintroduziria o bug de
perda de catálogos no crash do worker.
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
