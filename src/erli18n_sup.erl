-module(erli18n_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

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
