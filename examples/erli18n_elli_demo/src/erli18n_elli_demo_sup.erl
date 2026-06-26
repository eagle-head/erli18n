-module(erli18n_elli_demo_sup).

-moduledoc """
Top-level supervisor owning the Elli listener as a single supervised child.

Elli is started as an `elli_middleware` stack: `erli18n_elli` runs FIRST (a
preprocess-only middleware that negotiates and sets the locale), and the real
`erli18n_elli_demo_handler` runs LAST. `erli18n_elli` exports only `preprocess/2`
(not `handle/2`), so `elli_middleware` skips its handle phase and it never
intercepts the real handler.
""".

-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(PORT, 8081).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ElliOpts = [
        {callback, elli_middleware},
        {callback_args, [
            {mods, [
                %% Per-middleware options are the second element of the
                %% `{Mod, Args}` pair. Every key is optional; this is the
                %% explicit form of the default precedence.
                {erli18n_elli, #{sources => [query, cookie, header]}},
                {erli18n_elli_demo_handler, []}
            ]}
        ]},
        {port, ?PORT}
    ],
    Child = #{
        id => elli,
        start => {elli, start_link, [ElliOpts]}
    },
    {ok, {#{strategy => one_for_one, intensity => 1, period => 5}, [Child]}}.
