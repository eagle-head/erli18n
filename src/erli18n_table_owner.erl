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
Dedicated, long-lived owner of the catalog ETS table (`?ETS_TABLE`), the
`heir` that lets loaded catalogs survive a worker crash.

## What it is and what problem it solves

ETS destroys a table when its *owner* dies. Before this module, the catalog
table was created and owned by `erli18n_server` itself — which is also the
only process that mutates it and therefore the most likely to crash. Any
worker termination (a `badmatch` in a clause, an operational
`exit(Pid, kill)`, a future bug) took down ALL loaded catalogs with it: the
supervisor restarted the worker, but it came back with a fresh, empty
table, and every `lookup_*` started returning the raw msgid until each
catalog was reloaded by the consumer. A transient failure turned into a
total loss of translation availability (Finding #10,
`ets-owned-by-server-no-heir-crash-loses-all-catalogs`).

This module separates *ownership* from *mutation*. Its sole responsibility
is to create the table, hold it as its own `heir`, give it away
(`give_away`) to the worker, and reclaim it — with all rows intact — when
the worker dies, re-arming for the next claim.

## Scope: what survives vs. what is rebuilt

This owner preserves only the DATA table (`?ETS_TABLE`,
`erli18n_catalog`) — the catalog rows. `erli18n` keeps a SECOND table, the
O(1) per-catalog index (`?CATALOG_INDEX_TABLE`, `erli18n_catalog_index`),
which is NOT managed by this module: it is private state of the worker
(`erli18n_server`), `protected` and owned by it, and therefore DIES along
with the worker on a crash. There is deliberately no heir for the index: it
is cheap, derivable state, rebuilt in `erli18n_server:init/1` (via
`rebuild_catalog_index/0`) from the surviving rows of the data table — a
single O(rows) pass, never on the load hot-path. In short: the heir pattern
here saves the translation DATA; the acceleration index is re-derived from
it on worker boot.

## Mental model

- *Ownership vs. mutation.* The owner holds the table but never writes to
  it. The worker (`erli18n_server`) is the only *writer*. The table is
  `protected`: only the current owner writes; any process reads. Since the
  owner mutates nothing, its crash surface is minimal — it practically
  never goes down.
- *Who owns it over time.* At boot, the owner creates the table and is the
  proprietor (reads already work). On the worker's claim, ownership passes
  to the worker via `ets:give_away/3`. When the worker dies, ETS returns
  ownership to the owner (the `heir`) automatically, with all rows
  preserved. The owner re-arms and waits for the next `claim` from the
  restarted worker.
- *Named table and lock-free reads.* The table is `named_table`, so
  `erli18n`'s read hot-path accesses it by name (`?ETS_TABLE`), directly
  from the calling process, without going through any gen_server. The
  ownership swap between worker and heir is transparent to readers — the
  name never changes.
- *Two transfer markers.* `?ETS_HANDOFF_DATA` labels the deliberate
  give_away owner->worker; `?ETS_HEIR_DATA` labels the automatic return
  dead-worker->owner (heir reclaim). Each receiver matches exactly the
  transfer it expects.
- *Load-bearing topology.* Under `erli18n_sup`'s `rest_for_one` strategy,
  the owner starts BEFORE the worker. A worker crash does not bring down
  the owner (it comes earlier in the start order), so the table survives; an
  owner crash restarts the worker too, and the new owner recreates the
  table from scratch. Reversing the order reintroduces Finding #10.

## When a dev touches this module

Almost never, directly. The library consumer uses `erli18n` and
`erli18n_server` and does not touch here. The only point of contact in
production is `erli18n_server:init/1`, which calls `claim_table/0` to
receive the table. You read this module if: you are debugging catalog loss
after a crash, changing the supervisor's child order, or investigating the
`catalog_table_reclaimed` log event.

## Quickstart (under the real supervision tree)

```erlang
1> application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> ok = erli18n_server:ensure_loaded(my_domain, <<"fr">>,
2>     <<"priv/locale/fr/LC_MESSAGES/my_domain.po">>).
ok
3> %% The owner is a registered process, alive and separate from the worker:
3> is_pid(whereis(erli18n_table_owner)).
true
4> ets:info(erli18n_catalog, owner) =:= whereis(erli18n_server).
true
5> ets:info(erli18n_catalog, heir) =:= whereis(erli18n_table_owner).
true
6> %% Kill the worker; the owner reclaims the table and the restarted worker retakes it.
6> exit(whereis(erli18n_server), kill), timer:sleep(50).
ok
7> erli18n:gettext(my_domain, <<"Hello, world">>, <<"fr">>).
<<"Bonjour, monde">>
```

## Key functions and callbacks

- `start_link/0` — starts the owner (called by `erli18n_sup`).
- `claim_table/0` — the worker requests the table from the owner (called in
  `erli18n_server:init/1`).
- `init/1` — creates the ETS table and pins the owner as `heir`.
- `handle_call/3` — handles `{claim, WorkerPid}` and performs the give_away.
- `handle_info/2` — heart of the owner/heir pattern: reclaim and `'DOWN'`.
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
Internal state of the owner. Carries the (named) table and tracking of the
worker that currently holds it:

- `table` — the catalog `ets:table()`; constant for the whole life of the
  process (recreated only if the owner itself restarts).
- `worker` — `{Pid, Mon}` while a current worker holds the table (`Mon` is
  that worker's monitor), or `undefined` when ownership is with the owner:
  at boot, before the first `claim`, and after reclaiming the table from a
  dead worker. The `undefined` value is the trigger that enables the next
  give_away with no risk of duplication.
""".
-type state() :: #{
    table := ets:table(),
    worker := undefined | {pid(), reference()}
}.

-doc """
Starts the table owner gen_server, registered locally under
`?TABLE_OWNER` (`erli18n_table_owner`).

Called by `erli18n_sup` as the FIRST child (before `erli18n_server`), an
order that is load-bearing for the owner/heir pattern. In `init/1` the owner
creates the catalog ETS table and pins itself as `heir`; on return, the
table already exists and is ready for reads and for the first
`claim_table/0`.

## Return

The standard result of `gen_server:start_link/4`: `{ok, Pid}` on success.
The process is registered locally, so `whereis(erli18n_table_owner)`
resolves to `Pid`. A second `start_link/0` with the name already registered
would fail with `{error, {already_started, Pid}}` — in practice this does
not happen because only the supervisor starts it.

## Example

```erlang
1> {ok, Pid} = erli18n_table_owner:start_link().
{ok,<0.200.0>}
2> Pid =:= whereis(erli18n_table_owner).
true
3> ets:info(erli18n_catalog, heir) =:= Pid.
true
```

See also `claim_table/0` (the worker claims the table) and `init/1` (table
creation).
""".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?TABLE_OWNER}, ?MODULE, [], []).

%% Called by `erli18n_server' in its own `init/1': asks the owner to hand
%% the table over via `give_away/3'. Synchronous — once it returns `ok'
%% the initial `'ETS-TRANSFER'' is (or is about to be) in the caller's
%% mailbox. The owner only gives the table to a live, local worker.
-doc """
Claims the catalog table: asks the owner to hand it over via
`ets:give_away/3` to the calling process. After it returns, the caller
becomes the owner (writer) of the table.

Called by `erli18n_server` inside its own `init/1`, which then does a
`receive` of `{'ETS-TRANSFER', ?ETS_TABLE, _OwnerPid, ?ETS_HANDOFF_DATA}`
to consume the table. It takes NO arguments: the give_away target is always
`self()` (the caller), never an arbitrary pid — that is the safety boundary
that prevents a process from redirecting the table to another.

## Return

Always `ok` when the call succeeds (it is a `gen_server:call/3` with timeout
`infinity`, matched against `ok = ...`). On return, the initial
`{'ETS-TRANSFER', ...}` message is already — or is about to be — in the
caller's mailbox. The synchronicity guarantees ordering: the `ok` arrives
after the owner has fired (or at least enqueued) the give_away.

## Failure modes

- If `whereis(erli18n_table_owner)` is `undefined` (owner not started), the
  call fails with `noproc`. Under the supervision tree this does not occur:
  the owner is started before the worker (`rest_for_one`).
- If the calling worker dies in the window between the give_away and the
  consumption, the owner detects the failed give_away — `ets:give_away/3`
  raises `badarg`, which `safe_give_away/2` converts into
  `{error, give_away_failed}` — and keeps the table with itself; see
  `handle_call/3` and `safe_give_away/2`.
- The `infinity` `timeout` is deliberate: the handoff is part of boot and
  must not be cut short by an arbitrary deadline. `erli18n_server` enforces
  its own 5 s deadline on the `'ETS-TRANSFER'` `receive` and crashes if it
  overflows.

## Example

```erlang
1> %% Run from inside the process that will become the table owner:
1> ok = erli18n_table_owner:claim_table().
ok
2> receive {'ETS-TRANSFER', erli18n_catalog, _Owner, _Tag} -> got_table end.
got_table
3> ets:info(erli18n_catalog, owner) =:= self().
true
```

See also `handle_call/3` (the owner side that serves the `{claim, _}`) and
`start_link/0`.
""".
-spec claim_table() -> ok.
claim_table() ->
    ok = gen_server:call(?TABLE_OWNER, {claim, self()}, infinity).

-doc """
`c:gen_server:init/1` callback. CREATES the catalog ETS table and returns
the initial state with no worker.

## Behavior

Creates `?ETS_TABLE` (`erli18n_catalog`) with the options (each
load-bearing):

- `set` — unique keys; one row per catalog entry.
- `protected` — only the current owner writes; any process reads. This is
  what preserves the single-writer invariant (RISK-012) while keeping the
  read hot-path open to all.
- `named_table` — access by the atom `erli18n_catalog`, so that readers and
  the restarted worker find the SAME table despite ownership swaps.
- `{read_concurrency, true}` — optimizes the "many concurrent reads, writes
  serialized by the worker" pattern.
- `{keypos, 1}` — the key is the 1st element of the row tuple.
- `{heir, self(), ?ETS_HEIR_DATA}` — the core of Finding #10: the owner is
  its own heir. If the worker (future owner) dies, ETS returns the table to
  THIS process carrying the `?ETS_HEIR_DATA` marker.

While no worker has claimed the table, the owner is the proprietor and
reads already work (named, protected table) — useful between the owner's
boot and the worker's first `claim_table/0`.

## Return

`{ok, #{table => Table, worker => undefined}}`. The `worker => undefined`
marks that ownership is with the owner and unlocks the first give_away.

## Failure modes

`ets:new/2` may raise `badarg` if the named table already exists (e.g. a
ghost owner from a previous generation still alive) — which under the
supervision tree does not happen, since the table dies along with its
owner. A crash here aborts the owner's start; the supervisor re-evaluates.

## Example

In production `init/1` is called ONCE, by the `gen_server` in
`start_link/0`, under the supervision tree. The example below only works on
a "clean" node, where the named table `erli18n_catalog` does NOT yet exist
(i.e. with the `erli18n` app stopped and no owner/worker alive). Calling
`init([])` a second time, or with the app already up, makes `ets:new/2`
raise `badarg` for a duplicate named table (see "Failure modes" above).

```erlang
1> {ok, State} = erli18n_table_owner:init([]).
{ok,#{table => erli18n_catalog,worker => undefined}}
2> ets:info(erli18n_catalog, protection).
protected
3> ets:info(erli18n_catalog, named_table).
true
```

To inspect the owner with the app already started, use the path via the
supervisor (as the moduledoc does with `whereis/1` and `ets:info/2`)
instead of calling `init/1` again.

See also `handle_info/2` (the `'ETS-TRANSFER'` clause that matches
`?ETS_HEIR_DATA`) and `terminate/2`.
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
`c:gen_server:handle_call/3` callback. Hands the table over to the worker
that claims it.

## Message protocol

- `{claim, WorkerPid}` (from `claim_table/0`, with `WorkerPid = self()` of
  the caller) — the central path:
  1. `reclaim_if_needed/1` ensures the owner is the current proprietor,
     dropping the monitor of any previous worker (physical ownership has
     already returned, or will return, via `'ETS-TRANSFER'`).
  2. monitors the new `WorkerPid` to detect its future death.
  3. attempts `safe_give_away/2`. If it succeeds (returns `ok`), it stores
     `{WorkerPid, Mon}` in `worker` and replies `ok`. If the worker died in
     the handoff window, `safe_give_away/2` catches the `badarg` from
     `ets:give_away/3` and returns `{error, give_away_failed}` (the concrete
     atom this clause matches in `{error, _}`); then the owner drops the
     monitor, keeps the table with itself (`worker => undefined`), and still
     replies `ok` — the supervisor restarts the worker, which will call
     `claim_table/0` again.
- Any other call — replies `{error, unknown_call}` without changing the
  state. The owner exposes no other synchronous API.

The `is_pid(WorkerPid)` guard in the clause head ensures that a malformed
`{claim, NotAPid}` falls into the catch-all clause and gets
`{error, unknown_call}` instead of crashing.

## Invariant

In both outcomes of the claim the call replies `ok`; the resulting state
either has `worker => {Pid, Mon}` (successful handoff) or
`worker => undefined` (worker died in the window). It never ends up with an
orphan monitor.

## Example

```erlang
1> %% The worker calls this indirectly via claim_table/0:
1> ok = gen_server:call(erli18n_table_owner, {claim, self()}, infinity).
ok
2> gen_server:call(erli18n_table_owner, {ping, anything}).
{error,unknown_call}
```

See also `claim_table/0` (the worker side), `reclaim_if_needed/1`,
`safe_give_away/2`, and `handle_info/2`.
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
`c:gen_server:handle_cast/2` callback. The owner has no asynchronous
protocol: it ignores any cast and keeps the state unchanged. It exists only
to satisfy the `gen_server` contract (every relevant mutation is driven by
`handle_call/3` and `handle_info/2`).
""".
-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc """
`c:gen_server:handle_info/2` callback. Heart of the owner/heir pattern:
this is where the table returns to the owner when the worker dies.

## Message protocol

- `{'ETS-TRANSFER', Table, _FromPid, ?ETS_HEIR_DATA}` — the worker that held
  the table died and ETS returned ownership to the owner (the `heir`) with
  ALL rows intact. The clause matches only when the received `Table` is the
  same as in the state and the marker is `?ETS_HEIR_DATA` (which
  distinguishes it from the give_away owner->worker). It drops the worker's
  monitor (`drop_worker_monitor/1`), emits the `catalog_table_reclaimed` log
  with the table size (via `safe_size/1`), and re-arms `worker => undefined`
  for the next `claim`.
- `{'DOWN', Mon, process, Pid, _Reason}` from the current worker (matches
  only when `worker` is exactly `{Pid, Mon}`) — the `'DOWN'` may arrive
  BEFORE the `'ETS-TRANSFER'`. The clause deliberately does NOT touch the
  table (ETS will transfer it back); it only marks `worker => undefined` to
  avoid a double give_away. Effective ownership returns in the
  `'ETS-TRANSFER'` clause above.
- Any other message — safely ignored. This includes `'DOWN'` /
  `'ETS-TRANSFER'` from old generations (whose monitor no longer matches the
  current state) and noise. It is safe to discard: the table is named and
  its owner is always this process or the live worker.

## Invariant / ordering

The two messages of the worker death cycle (`'DOWN'` and `'ETS-TRANSFER'`)
may arrive in any order. The state converges to `worker => undefined` on
both paths; the table is only considered "reclaimed and logged" in the
`'ETS-TRANSFER'` clause. The observable side effect is the
`catalog_table_reclaimed` log (domain `[erli18n, table_owner]`).

## Example

```erlang
1> %% With the worker holding the table, kill it and observe the reclaim:
1> Worker = whereis(erli18n_server).
<0.205.0>
2> exit(Worker, kill), timer:sleep(50).
ok
3> %% The table returned to the owner (and will soon be handed to the restarted worker):
3> ets:info(erli18n_catalog, owner) =/= Worker.
true
```

See also `init/1` (where `?ETS_HEIR_DATA` is pinned as heir data),
`handle_call/3` (the give_away back to the restarted worker), and
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
`c:gen_server:terminate/2` callback. No-op — there is no external resource
to release.

If the OWNER goes down, the table goes with it (it is the owner/heir and ETS
destroys the table along with the owner). This is acceptable and by design:
under `rest_for_one` the worker (later in the start order) is restarted too,
and the new owner recreates the empty table in `init/1` — the catalogs would
need to be reloaded, but this only happens on an owner crash, which is rare
because it mutates nothing (minimal crash surface). The common case — a
worker crash — is what the heir pattern protects against, and that path does
not pass through here.

There is no meaningful return; it returns `ok`.
""".
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    %% If the OWNER goes down the table goes with it (it is the
    %% owner/heir). That is acceptable: under `rest_for_one' the worker
    %% (after the owner) is restarted too, and the new owner recreates the
    %% table. The owner mutates nothing, so its crash surface is minimal.
    ok.

-doc """
`c:gen_server:code_change/3` callback. No state migration: returns
`{ok, State}` unchanged. The state is a simple map (`#{table, worker}`)
whose shape has not changed between versions; it exists only to satisfy the
`gen_server` contract on hot code upgrades.
""".
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =========================
%% Internal
%% =========================

-doc """
Ensures the owner is ready for a new handoff, discarding the tracking of any
previous worker.

Called at the start of each `{claim, _}` in `handle_call/3`. If `worker` is
already `undefined`, it returns the state intact. If a `{Pid, Mon}` is still
left over, it drops the monitor (`drop_worker_monitor/1`) and resets to
`worker => undefined`. The PHYSICAL ownership of the table is not touched
here: it has already returned — or will return — to the owner via
`'ETS-TRANSFER'`; this function only cleans the logical state to avoid an
orphan monitor before the next give_away.
""".
-spec reclaim_if_needed(state()) -> state().
reclaim_if_needed(#{worker := undefined} = State) ->
    State;
reclaim_if_needed(#{worker := Worker} = State) ->
    _ = drop_worker_monitor(Worker),
    State#{worker => undefined}.

-doc """
Drops a worker's monitor, if any. For `undefined` it is a no-op; for
`{_Pid, Mon}` it calls `erlang:demonitor(Mon, [flush])` — the `flush`
removes from the mailbox any `'DOWN'` already enqueued from that monitor,
preventing an old generation from triggering the `'DOWN'` clause of
`handle_info/2`. Always returns `ok`. Used by `reclaim_if_needed/1` and by
the `'ETS-TRANSFER'` clause of `handle_info/2`.
""".
-spec drop_worker_monitor(undefined | {pid(), reference()}) -> ok.
drop_worker_monitor(undefined) ->
    ok;
drop_worker_monitor({_Pid, Mon}) ->
    _ = erlang:demonitor(Mon, [flush]),
    ok.

-doc """
Defensive wrapper over `ets:give_away/3`.

The spec of `ets:give_away/3` is `true`, but it RAISES `error:badarg` if the
target is not eligible — dead target, non-local, or already the owner. The
case that matters here is the race in which `WorkerPid` dies in the window
between `erlang:monitor/2` and the give_away. Instead of letting the
`badarg` propagate and crash the owner (which would lose the table!), we
catch it and return a typed result:

- `ok` — the give_away succeeded; ownership passed to `WorkerPid`, which
  receives an `'ETS-TRANSFER'` marked with `?ETS_HANDOFF_DATA`.
- `{error, give_away_failed}` — the target was not eligible; the table stays
  with the owner. `handle_call/3` then drops the monitor and keeps
  `worker => undefined`.

Keeping the `badarg` contained here is what makes the owner practically
crash-immune even under boot/restart races.
""".
-spec safe_give_away(ets:table(), pid()) -> ok | {error, give_away_failed}.
safe_give_away(Table, WorkerPid) ->
    try ets:give_away(Table, WorkerPid, ?ETS_HANDOFF_DATA) of
        true -> ok
    catch
        error:badarg -> {error, give_away_failed}
    end.

-doc """
Reads `ets:info(Table, size)` tolerantly, for use in the
`catalog_table_reclaimed` log. Returns the number of rows when `ets:info/2`
returns a non-negative integer; in any other case (e.g. the table having
vanished in a race, making `ets:info/2` return `undefined`) it returns `0`
instead of crashing. The purpose is purely observational: the reclaim must
never fail because of the size computation for the log.
""".
-spec safe_size(ets:table()) -> non_neg_integer().
safe_size(Table) ->
    case ets:info(Table, size) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.
