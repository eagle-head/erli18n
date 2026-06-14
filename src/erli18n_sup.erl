-module(erli18n_sup).

-moduledoc """
Root supervisor of the erli18n application tree.

## What it is and what it solves

This is the library's only supervisor: it is the process started by
`erli18n_app:start/2` and the root of the OTP tree. Its sole
responsibility is to keep alive — and in the right order — the two
processes that underpin the translation runtime:

- `erli18n_table_owner` — the dedicated, long-lived owner of the ETS
  catalog table (`erli18n_catalog`). It creates the table, holds itself
  as its `heir`, and hands it to the worker via `ets:give_away/3`.
- `erli18n_server` — the worker/writer. It receives the table from the
  owner in its `init/1` and serializes all writes (load/reload/unload of
  catalogs) through its `gen_server`.

The reader goes through neither of these processes: `lookup_*` reads
straight from the `protected`/`named_table` ETS table from the calling
process, without blocking. This tree exists only to guarantee the
table's **ownership** and **durability**, not to mediate the read hot
path.

## Mental model (owner/heir and why order matters)

The heart of the design — and the reason this module is not trivial OTP
plumbing — is the separation between **ownership** (who holds the ETS
table) and **mutation** (who writes to it). The table is destroyed by
ETS the instant its owner dies; if the owner were the worker itself (the
process most prone to crashing, since it is the one that mutates the
table), any crash would wipe out **all** loaded catalogs, turning a
transient hiccup into total loss of translation availability until the
consumer reloads each catalog (Finding #10,
`ets-owned-by-server-no-heir-crash-loses-all-catalogs`).

The solution has two pieces that work together:

1. A **dedicated owner** (`erli18n_table_owner`) that creates the table
   with `{heir, self(), _}` and never mutates it — therefore it almost
   never crashes.
2. A `rest_for_one` supervision topology with the **owner first** and
   the **worker second** in the child list.

By the semantics of `rest_for_one`, when a child dies only the children
that come **after** it in the start order are restarted. Since the
worker comes after the owner:

- **Worker crash** (common): the owner — which comes before — is not
  terminated. ETS fires `'ETS-TRANSFER'` and returns the table intact
  to the owner (which is the `heir`); the restarted worker reacquires
  the **same** table via a fresh `give_away/3`. No catalog is lost.
- **Owner crash** (rare, since it mutates nothing): `rest_for_one`
  restarts the owner and, in cascade, the worker. The owner recreates
  the table in its `init/1` and the handoff cycle is re-established. The
  catalogs are lost only in this rare case.

Inverting the order of the children reintroduces the Finding #10 bug:
that is why the order in `init/1` is load-bearing, not cosmetic.

## Fixed configuration in this v0.1

The restart intensity is `{intensity => 5, period => 10}` (at most 5
restarts in 10 seconds before the supervisor gives up) and is hardcoded
in this version by a decision recorded in AMB-002 — it is not
configurable via `application:get_env/2`. Both children are `permanent`
with `shutdown => 5000`.

## When a dev touches this module

Almost never directly. Library consumers call
`application:ensure_all_started(erli18n)`, which brings up the
application and, through it, this supervisor. Touching things here only
makes sense when altering the tree's topology (adding/removing a child,
changing strategy or intensity). Before any change to the **order** of
the `ChildSpecs`, re-read the mental model section above.

## Quickstart

```erlang
1> {ok, _Started} = application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> whereis(erli18n_sup) =/= undefined.
true
3> [Id || {Id, _Pid, _Type, _Mods} <- supervisor:which_children(erli18n_sup)].
[erli18n_table_owner,erli18n_server]
```

The list in `_Started` may vary: `erli18n.app.src` declares `telemetry`
in `optional_applications`, so if the optional app is present and has not
yet been started, it shows up alongside (e.g.:
`{ok, [telemetry, erli18n]}`). `kernel` and `stdlib` are already up and
never enter that list. That is why the example matches `{ok, _Started}`
instead of comparing the output literally.

## Key functions

- `start_link/0` — entry point, called by `erli18n_app:start/2`.
- `init/1` — the `supervisor` callback; defines the strategy, intensity,
  and the `ChildSpecs` in the load-bearing order.
""".

-behaviour(supervisor).

-export([start_link/0, init/1]).

-doc """
Starts the root supervisor, registered locally as `erli18n_sup`.

The tree's entry point: it is what `erli18n_app:start/2` calls. It
delegates to `supervisor:start_link/3` with `{local, ?MODULE}`, which
makes the supervisor respond to the name `erli18n_sup` (usable in
`supervisor:which_children/1`, `whereis/1`, etc.) and invokes `init/1`
to assemble the children.

## Return

- `{ok, Pid}` — the supervisor and both children
  (`erli18n_table_owner` and `erli18n_server`) started successfully.
- `{error, {already_started, Pid}}` — a process is already registered
  under `erli18n_sup` (the application is already up). Starting the
  application twice via OTP does not reach here; this only shows up in
  manual calls.
- `{error, {shutdown, _}}` — some child failed in its own `init/1`
  (e.g.: the worker's `claim_table/0` handoff did not complete). The
  supervisor unwinds what came up and propagates the error.

It crashes (linked to the caller) only if there is a programming error
in the construction of the `ChildSpecs` in `init/1` — which, in this
module, is static and does not depend on external input.

## Example

```erlang
1> {ok, Pid} = erli18n_sup:start_link().
{ok,<0.215.0>}
2> Pid =:= whereis(erli18n_sup).
true
3> erli18n_sup:start_link().
{error,{already_started,<0.215.0>}}
```

The third call demonstrates the failure mode described above: with the
supervisor already registered under `erli18n_sup`, a second manual
`start_link/0` returns `{error, {already_started, Pid}}` with the `Pid`
of the existing process — without tearing down or restarting anything.

See also `init/1` for the definition of the tree this function installs.
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
The `c:supervisor:init/1` callback — defines the shape of the
supervision tree.

Called once by `start_link/0` (via `supervisor:start_link/3`). It
receives the `[]` argument passed in `start_link/0` and returns
`{ok, {SupFlags, ChildSpecs}}`. It is purely declarative: it builds maps
and has no side effects nor error paths of its own.

## SupFlags

- `strategy => rest_for_one` — load-bearing. Guarantees that a worker
  crash (which comes **after** the owner in the order) does not bring
  down the owner, and that an owner crash (which comes **before**) also
  restarts the worker in cascade. See the mental model in the
  `-moduledoc` for the why.
- `intensity => 5`, `period => 10` — at most 5 restarts in 10 seconds;
  on exceeding it, the supervisor gives up and propagates the failure
  upward. Fixed values in this v0.1 (AMB-002), not configurable.

## ChildSpecs (the ORDER is load-bearing)

The returned list is `[Owner, Server]`, in exactly this order:

1. `erli18n_table_owner` — `permanent`, `worker`, `shutdown => 5000`.
   Owner/`heir` of the `erli18n_catalog` ETS table. It comes up first so
   it exists and holds the table before the worker requests the handoff.
   The handoff/reclaim mechanics that sustain the table's survival on a
   worker crash live in `erli18n_table_owner:handle_info/2` (the
   `'ETS-TRANSFER'` clause that matches `?ETS_HEIR_DATA` and revives the
   table) and in `erli18n_table_owner:handle_call/3` (the defensive
   owner->worker `ets:give_away/3`, via `safe_give_away/2`); that is
   where the claim that no catalog is lost is validated.
2. `erli18n_server` — `permanent`, `worker`, `shutdown => 5000`.
   The catalog writer. In its `init/1` it calls
   `erli18n_table_owner:claim_table/0` to receive the table via
   `ets:give_away/3`; that is why it depends on the owner already being
   up.

**Inverting the order reintroduces Finding #10**
(`ets-owned-by-server-no-heir-crash-loses-all-catalogs`): with the
worker before the owner, a worker crash would start terminating the
owner in cascade (`rest_for_one` semantics), the table would be
destroyed, and all loaded catalogs would be lost.

## Return

Always `{ok, {SupFlags, ChildSpecs}}`. There is no error clause: a
malformed `ChildSpec` would be a programming bug detected by the
`supervisor` while validating the tree, not a runtime failure mode.

## Example

```erlang
1> {ok, {SupFlags, Children}} = erli18n_sup:init([]).
2> maps:get(strategy, SupFlags).
rest_for_one
3> [maps:get(id, C) || C <- Children].
[erli18n_table_owner,erli18n_server]
```

See also `start_link/0`, which installs this tree.
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
