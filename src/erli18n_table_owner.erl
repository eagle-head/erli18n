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

%% The state carries the (named) table and the monitor of the worker that
%% currently holds it (`undefined' while the owner holds it).
-type state() :: #{
    table := ets:table(),
    worker := undefined | {pid(), reference()}
}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?TABLE_OWNER}, ?MODULE, [], []).

%% Called by `erli18n_server' in its own `init/1': asks the owner to hand
%% the table over via `give_away/3'. Synchronous — once it returns `ok'
%% the initial `'ETS-TRANSFER'' is (or is about to be) in the caller's
%% mailbox. The owner only gives the table to a live, local worker.
-spec claim_table() -> ok.
claim_table() ->
    ok = gen_server:call(?TABLE_OWNER, {claim, self()}, infinity).

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

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

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

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    %% If the OWNER goes down the table goes with it (it is the
    %% owner/heir). That is acceptable: under `rest_for_one' the worker
    %% (after the owner) is restarted too, and the new owner recreates the
    %% table. The owner mutates nothing, so its crash surface is minimal.
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =========================
%% Internal
%% =========================

%% Ensure the owner is the current proprietor before a new handoff. If a
%% previous worker still figured, drop its monitor; physical ownership has
%% already returned (or will return) via `'ETS-TRANSFER''.
-spec reclaim_if_needed(state()) -> state().
reclaim_if_needed(#{worker := undefined} = State) ->
    State;
reclaim_if_needed(#{worker := Worker} = State) ->
    _ = drop_worker_monitor(Worker),
    State#{worker => undefined}.

-spec drop_worker_monitor(undefined | {pid(), reference()}) -> ok.
drop_worker_monitor(undefined) ->
    ok;
drop_worker_monitor({_Pid, Mon}) ->
    _ = erlang:demonitor(Mon, [flush]),
    ok.

%% `ets:give_away/3' is specced as `true', but raises `badarg' if the
%% target died in the window. Wrap it to return a typed result.
-spec safe_give_away(ets:table(), pid()) -> ok | {error, give_away_failed}.
safe_give_away(Table, WorkerPid) ->
    try ets:give_away(Table, WorkerPid, ?ETS_HANDOFF_DATA) of
        true -> ok
    catch
        error:badarg -> {error, give_away_failed}
    end.

-spec safe_size(ets:table()) -> non_neg_integer().
safe_size(Table) ->
    case ets:info(Table, size) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.
