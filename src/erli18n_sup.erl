-module(erli18n_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Supervisor intensity {5, 10} hardcoded in v0.1 per AMB-002.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    ChildSpecs = [
        #{
            id => erli18n_server,
            start => {erli18n_server, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erli18n_server]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
