%%% =====================================================================
%%% Common Test suite for `erli18n_table_owner` — the ETS owner/heir
%%% process behind the catalog table's crash durability.
%%%
%%% The owner registers a fixed name and creates a fixed-name ETS table, so
%%% these cases run with the `erli18n` application STOPPED and drive a
%%% standalone owner directly through its gen_server protocol (claim, casts,
%%% DOWN / ETS-TRANSFER handoff messages, code change, stop), asserting the
%%% observable replies and resulting state — input -> output, never the
%%% internals.
%%% =====================================================================
-module(erli18n_table_owner_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("erli18n.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    unknown_call_returns_error/1,
    malformed_claim_returns_error/1,
    cast_is_ignored/1,
    claim_dead_worker_keeps_table/1,
    second_claim_drops_previous_monitor/1,
    down_then_transfer_reclaims_and_logs/1,
    claim_table_api_hands_over/1,
    safe_size_tolerates_vanished_table/1,
    stray_message_is_ignored/1,
    code_change_keeps_state/1,
    clean_stop/1,
    server_init_times_out_when_handoff_fails/1
]).

all() ->
    [
        unknown_call_returns_error,
        malformed_claim_returns_error,
        cast_is_ignored,
        claim_dead_worker_keeps_table,
        second_claim_drops_previous_monitor,
        down_then_transfer_reclaims_and_logs,
        claim_table_api_hands_over,
        safe_size_tolerates_vanished_table,
        stray_message_is_ignored,
        code_change_keeps_state,
        clean_stop,
        server_init_times_out_when_handoff_fails
    ].

init_per_suite(Config) ->
    %% Free the registered name and the named ETS table.
    _ = application:stop(erli18n),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    {ok, Pid} = erli18n_table_owner:start_link(),
    [{owner, Pid} | Config].

end_per_testcase(_TC, Config) ->
    Owner = ?config(owner, Config),
    case is_process_alive(Owner) of
        true -> gen_server:stop(Owner);
        false -> ok
    end,
    %% If a test left the table with a still-living worker, the owner's death
    %% did not destroy it (the worker is the proprietor); kill that owner so
    %% the next test starts from a clean slate.
    case ets:info(?ETS_TABLE, owner) of
        undefined ->
            ok;
        TabOwner ->
            exit(TabOwner, kill),
            wait_table_gone(50)
    end,
    ok.

%% =========================
%% Cases
%% =========================

unknown_call_returns_error(Config) ->
    Owner = ?config(owner, Config),
    ?assertEqual({error, unknown_call}, gen_server:call(Owner, {ping, foo})),
    ?assertEqual({error, unknown_call}, gen_server:call(Owner, totally_unknown)).

malformed_claim_returns_error(Config) ->
    %% A `{claim, NotAPid}` fails the `is_pid` guard and falls to the
    %% catch-all rather than crashing.
    Owner = ?config(owner, Config),
    ?assertEqual({error, unknown_call}, gen_server:call(Owner, {claim, not_a_pid})).

cast_is_ignored(Config) ->
    Owner = ?config(owner, Config),
    Before = sys:get_state(Owner),
    gen_server:cast(Owner, anything),
    %% A synchronous round-trip proves the process survived and ignored it.
    ?assertEqual({error, unknown_call}, gen_server:call(Owner, ping)),
    ?assertEqual(Before, sys:get_state(Owner)).

claim_dead_worker_keeps_table(Config) ->
    %% Claiming an already-dead worker: give_away raises badarg, the owner
    %% catches it, drops the monitor, keeps the table, and still replies ok.
    Owner = ?config(owner, Config),
    Dead = spawn(fun() -> ok end),
    wait_dead(Dead, 50),
    ?assertEqual(ok, gen_server:call(Owner, {claim, Dead})),
    ?assertEqual(undefined, worker_of(Owner)).

second_claim_drops_previous_monitor(Config) ->
    %% First claim hands the table to A (A becomes proprietor). A second claim
    %% (A still alive) makes the owner drop A's stale monitor before the next
    %% give_away — which then fails (the owner no longer holds the table), so
    %% the worker resets to undefined. The point under test is the stale-monitor
    %% reclaim on the second claim.
    Owner = ?config(owner, Config),
    A = spawn_waiter(),
    ?assertEqual(ok, gen_server:call(Owner, {claim, A})),
    ?assertMatch({A, _}, worker_of(Owner)),
    B = spawn_waiter(),
    ?assertEqual(ok, gen_server:call(Owner, {claim, B})),
    ?assertEqual(undefined, worker_of(Owner)),
    stop_waiter(A),
    stop_waiter(B).

down_then_transfer_reclaims_and_logs(Config) ->
    %% Deliver a worker `'DOWN'` BEFORE the `'ETS-TRANSFER'` (a legal ordering).
    %% The DOWN resets the worker to undefined; the subsequent transfer then
    %% re-arms with no monitor to drop and logs the reclaimed size. The info log
    %% level is raised so the size argument is actually evaluated.
    Owner = ?config(owner, Config),
    ok = logger:set_module_level(erli18n_table_owner, info),
    try
        W = spawn_waiter(),
        ?assertEqual(ok, gen_server:call(Owner, {claim, W})),
        {W, Mon} = worker_of(Owner),
        Owner ! {'DOWN', Mon, process, W, killed},
        sync(Owner),
        ?assertEqual(undefined, worker_of(Owner)),
        %% The table id is the named table; the transfer message matches the
        %% owner's heir clause and re-arms it.
        Owner ! {'ETS-TRANSFER', ?ETS_TABLE, W, ?ETS_HEIR_DATA},
        sync(Owner),
        ?assertEqual(undefined, worker_of(Owner)),
        %% The table is intact after the reclaim.
        ?assert(is_integer(ets:info(?ETS_TABLE, size))),
        stop_waiter(W)
    after
        logger:unset_module_level(erli18n_table_owner)
    end.

claim_table_api_hands_over(Config) ->
    %% The worker-side `claim_table/0` (calls the registered owner with its own
    %% pid) hands the table over to the caller.
    Owner = ?config(owner, Config),
    Parent = self(),
    W = spawn(fun() ->
        R = erli18n_table_owner:claim_table(),
        Parent ! {claimed, self(), R},
        receive
            stop -> ok
        end
    end),
    receive
        {claimed, W, R} -> ?assertEqual(ok, R)
    after 1000 ->
        ct:fail(no_claim)
    end,
    ?assertMatch({W, _}, worker_of(Owner)),
    stop_waiter(W).

safe_size_tolerates_vanished_table(Config) ->
    %% The reclaim log reads the table size tolerantly: if the table has
    %% vanished by the time the heir logs (a race the owner must survive), the
    %% size degrades to 0 instead of crashing the owner — otherwise an owner
    %% crash would lose the catalog. Simulated by a worker that claims the
    %% table and deletes it before a transfer message is processed.
    Owner = ?config(owner, Config),
    ok = logger:set_module_level(erli18n_table_owner, info),
    try
        Parent = self(),
        W = spawn(fun() ->
            ok = erli18n_table_owner:claim_table(),
            true = ets:delete(?ETS_TABLE),
            Parent ! deleted,
            receive
                stop -> ok
            end
        end),
        receive
            deleted -> ok
        after 1000 -> ct:fail(no_delete)
        end,
        Owner ! {'ETS-TRANSFER', ?ETS_TABLE, W, ?ETS_HEIR_DATA},
        sync(Owner),
        ?assert(is_process_alive(Owner)),
        stop_waiter(W)
    after
        logger:unset_module_level(erli18n_table_owner)
    end.

stray_message_is_ignored(Config) ->
    Owner = ?config(owner, Config),
    Before = sys:get_state(Owner),
    Owner ! some_random_message,
    sync(Owner),
    ?assertEqual(Before, sys:get_state(Owner)).

code_change_keeps_state(Config) ->
    %% The state shape is stable across versions: code_change returns it
    %% unchanged.
    Owner = ?config(owner, Config),
    %% `sys:get_state/1` is typed `term()`; cast to the callback's state() at
    %% the boundary.
    State = eqwalizer:dynamic_cast(sys:get_state(Owner)),
    ?assertEqual({ok, State}, erli18n_table_owner:code_change(old_vsn, State, extra)).

clean_stop(Config) ->
    Owner = ?config(owner, Config),
    ?assertEqual(ok, gen_server:stop(Owner)),
    ?assertNot(is_process_alive(Owner)).

server_init_times_out_when_handoff_fails(Config) ->
    %% The worker side of the protocol: `erli18n_server:init/1` claims the
    %% table from the owner and then blocks on the `'ETS-TRANSFER'`. If the
    %% owner is no longer the table's proprietor — modelled here by a prior
    %% worker holding it — `give_away/3` raises, so NO transfer is delivered.
    %% Rather than hang forever, init must crash with `ets_handoff_timeout`
    %% after the bounded 5s guard, which `start_link/0` surfaces as
    %% `{error, Reason}`. This pins that bounded-wait failure path.
    Owner = ?config(owner, Config),
    Holder = spawn_waiter(),
    ?assertEqual(ok, gen_server:call(Owner, {claim, Holder})),
    ?assertMatch({Holder, _}, worker_of(Owner)),
    %% start_link/0 links us to the worker; its failed init crashes with the
    %% timeout reason, so we trap exits to read the {error, Reason} return
    %% without the racing link signal taking the test process down, then flush
    %% the link EXIT the crash leaves behind.
    Old = process_flag(trap_exit, true),
    try
        ?assertMatch(
            {error, {{ets_handoff_timeout, ?ETS_TABLE}, _}},
            erli18n_server:start_link()
        ),
        receive
            {'EXIT', _Pid, {ets_handoff_timeout, ?ETS_TABLE}} -> ok
        after 1000 -> ok
        end
    after
        process_flag(trap_exit, Old)
    end,
    stop_waiter(Holder).

%% =========================
%% Helpers
%% =========================

%% The owner's state is `#{table := _, worker := Worker}`; read the worker.
worker_of(Owner) ->
    #{worker := Worker} = sys:get_state(Owner),
    Worker.

%% A synchronous round-trip flushes any preceding async messages the owner
%% has been sent (the reply only comes after they are processed).
sync(Owner) ->
    {error, unknown_call} = gen_server:call(Owner, sync_probe),
    ok.

%% A worker that simply waits to be told to stop (eligible for give_away:
%% alive, local, not the owner).
spawn_waiter() ->
    spawn(fun Loop() ->
        receive
            stop -> ok;
            _ -> Loop()
        end
    end).

stop_waiter(Pid) ->
    Pid ! stop,
    ok.

wait_dead(_Pid, 0) ->
    ct:fail(process_still_alive);
wait_dead(Pid, N) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(10),
            wait_dead(Pid, N - 1)
    end.

wait_table_gone(0) ->
    ok;
wait_table_gone(N) ->
    case ets:info(?ETS_TABLE, owner) of
        undefined ->
            ok;
        _ ->
            timer:sleep(10),
            wait_table_gone(N - 1)
    end.
