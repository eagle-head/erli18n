-module(erli18n_cowboy_demo_sup).

-moduledoc """
Minimal top-level supervisor. The Cowboy listener runs under `ranch`'s own
supervision tree (started by `cowboy:start_clear/3` in the app callback), so this
supervisor carries no children — it exists only to satisfy the `application`
behaviour's `start/2 -> {ok, Pid}` contract.
""".

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 1, period => 5}, []}}.
