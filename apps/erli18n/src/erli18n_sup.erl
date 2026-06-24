-module(erli18n_sup).

-moduledoc """
Root supervisor of the erli18n application tree.

## What it is and what it solves

This is the library's only supervisor: it is the process started by
`erli18n_app:start/2` and the root of the OTP tree. Its sole
responsibility is to keep alive the single process that underpins the
translation runtime:

- `erli18n_server` — the worker/writer. It serializes all writes
  (load/reload/unload of catalogs) through its `gen_server` and is the
  ONLY process that mutates `persistent_term`.

The reader goes through neither this supervisor nor the worker:
`lookup_*` reads straight from `persistent_term` in the calling process,
without blocking. This tree exists only to keep the writer alive, not to
mediate the read hot path.

## Mental model (why a single worker is enough now)

The catalogs are stored in `persistent_term` (see `erli18n_pt_store`),
which is owned by the **runtime**, not by any process. A persistent term
is not destroyed when the process that installed it dies. So a crash of
the worker loses NOTHING: every loaded catalog survives untouched, and
the restarted worker resumes serializing writes against the surviving
terms.

This is a structural simplification over the previous ETS design. ETS
destroyed a table the instant its owner died, so the old tree needed a
dedicated table owner holding the table as its `heir`, plus a
`rest_for_one` topology with the owner started before the worker, so that
a worker crash returned the table to the owner via `'ETS-TRANSFER'`
instead of wiping every catalog (Finding #10). `persistent_term` makes
that whole subsystem unnecessary: there is no table to own, no heir, no
handoff, and therefore no ordering constraint between children. The tree
collapses to a single worker under `one_for_one`.

## Fixed configuration

The restart intensity is `{intensity => 5, period => 10}` (at most 5
restarts in 10 seconds before the supervisor gives up) and is hardcoded
by a decision recorded in AMB-002 — it is not configurable via
`application:get_env/2`. The single child is `permanent` with
`shutdown => 5000`.

## When a dev touches this module

Almost never directly. Library consumers call
`application:ensure_all_started(erli18n)`, which brings up the
application and, through it, this supervisor. Touching things here only
makes sense when altering the tree's topology (adding/removing a child,
changing strategy or intensity).

## Quickstart

```erlang
1> {ok, _Started} = application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> whereis(erli18n_sup) =/= undefined.
true
3> [Id || {Id, _Pid, _Type, _Mods} <- supervisor:which_children(erli18n_sup)].
[erli18n_server]
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
  and the single child spec.
""".

-behaviour(supervisor).

-export([start_link/0, init/1]).

-doc """
Starts the root supervisor, registered locally as `erli18n_sup`.

The tree's entry point: it is what `erli18n_app:start/2` calls. It
delegates to `supervisor:start_link/3` with `{local, ?MODULE}`, which
makes the supervisor respond to the name `erli18n_sup` (usable in
`supervisor:which_children/1`, `whereis/1`, etc.) and invokes `init/1`
to assemble the child.

## Return

- `{ok, Pid}` — the supervisor and its `erli18n_server` child started
  successfully.
- `{error, {already_started, Pid}}` — a process is already registered
  under `erli18n_sup` (the application is already up). Starting the
  application twice via OTP does not reach here; this only shows up in
  manual calls.
- `{error, {shutdown, _}}` — the child failed in its own `init/1`. The
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

%% Supervisor intensity {5, 10} hardcoded per AMB-002.
%%
%% `one_for_one' with a single worker child. The catalogs live in
%% `persistent_term' (runtime-owned), so a crash of the worker loses no
%% catalog and there is no owner-first ordering to preserve: the
%% `rest_for_one' + table-owner topology that Finding #10
%% (ets-owned-by-server-no-heir-crash-loses-all-catalogs) required under
%% ETS is gone with the ETS storage.
-doc """
The `c:supervisor:init/1` callback — defines the shape of the
supervision tree.

Called once by `start_link/0` (via `supervisor:start_link/3`). It
receives the `[]` argument passed in `start_link/0` and returns
`{ok, {SupFlags, ChildSpecs}}`. It is purely declarative: it builds maps
and has no side effects nor error paths of its own.

## SupFlags

- `strategy => one_for_one` — a crash of the worker restarts only the
  worker. There is no owner to keep alive ahead of it and no ordering
  constraint, because the catalogs live in runtime-owned
  `persistent_term` and survive a worker crash untouched.
- `intensity => 5`, `period => 10` — at most 5 restarts in 10 seconds;
  on exceeding it, the supervisor gives up and propagates the failure
  upward. Fixed values (AMB-002), not configurable.

## ChildSpecs

A single child: `erli18n_server` — `permanent`, `worker`,
`shutdown => 5000`. The catalog writer. In its `init/1` it has nothing
to claim (no ETS table, no handoff): the catalogs are already in
`persistent_term`, so `init/1` just returns an empty state.

## Return

Always `{ok, {SupFlags, ChildSpecs}}`. There is no error clause: a
malformed `ChildSpec` would be a programming bug detected by the
`supervisor` while validating the tree, not a runtime failure mode.

## Example

```erlang
1> {ok, {SupFlags, Children}} = erli18n_sup:init([]).
2> maps:get(strategy, SupFlags).
one_for_one
3> [maps:get(id, C) || C <- Children].
[erli18n_server]
```

See also `start_link/0`, which installs this tree.
""".
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    %% The catalog writer. The catalogs live in `persistent_term'
    %% (runtime-owned), so the worker has nothing to claim on `init/1' and
    %% a crash loses no catalog.
    Server = #{
        id => erli18n_server,
        start => {erli18n_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [erli18n_server]
    },
    ChildSpecs = [Server],
    {ok, {SupFlags, ChildSpecs}}.
