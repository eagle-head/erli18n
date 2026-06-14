-module(erli18n_app).

-moduledoc """
The erli18n library's `application` callback: the OTP entry point
that brings the process tree up and down.

## What it is and what problem it solves

This is the module pointed to by `{mod, {erli18n_app, []}}` in
`erli18n.app.src`. When someone runs `application:ensure_all_started(erli18n)`
(or the release boot), OTP calls `start/2` here, and when the application
stops, it calls `stop/1`. There is nothing erli18n-specific in it beyond
delegating: it exists because the `application_controller` requires a
callback module, not because there is any i18n logic to run at boot.

## Mental model (for the maintainer)

Think of this module as the thinnest possible shell around the
supervision tree. All the load-bearing complexity lives **one hop ahead**:

- `start/2` calls `erli18n_sup:start_link/0` and returns the supervisor's
  `{ok, Pid}` *raw*, unwrapped. That `Pid` becomes the pid of the
  application that the `application_controller` goes on to monitor.
- The real topology lives in `erli18n_sup`: a `rest_for_one` strategy with
  two children in load-bearing order — `erli18n_table_owner` (owner/heir of
  the ETS table) **before** `erli18n_server` (worker/writer). A crash of the
  worker does not take down the owner, so the `erli18n_catalog` table and all
  loaded catalogs survive the restart and are re-handed-over via
  `ETS-TRANSFER`. This is a bug fix, not an accidental detail: see
  `erli18n_sup` and Finding #10 of the technical review.
- **This module's own state: zero.** It does not touch ETS, does not touch
  the process dictionary, and neither reads nor writes `application:get_env/2`.
  The `env` defaults (`emit_lookup_telemetry`, `memory_warning_threshold`,
  `memory_warning_rate_limit_seconds`) are declared in `erli18n.app.src`
  and consumed by `erli18n_telemetry` — never here.
- That is why `stop/1` ignores the `State` and returns `ok`: there is no
  resource to release at this level. The ordered shutdown of the children
  (including the `terminate/2` of the worker and of the owner) is the
  responsibility of the supervision tree, triggered by the
  `application_controller` *after* `stop/1` returns.

## When a dev touches this module

Almost never directly. The normal path is:

- **Library consumer:** runs `application:ensure_all_started(erli18n)` and
  moves on to `erli18n:gettext/3`, `erli18n_server:ensure_loaded/3`, etc.
  Does not import this module.
- **Maintainer:** touches this only if the *shape* of the boot changes — for
  example, starting to read `Args` from `{mod, {erli18n_app, Args}}`, doing
  one-shot setup at start, or handling `Type` (`normal` vs takeover/failover
  in a distributed scenario). Today both arguments are ignored on
  purpose. If you are going to add a new top-level process, the place is
  `erli18n_sup:init/1`, not here — `start/2` should stay a one-liner.

## Quickstart

```erlang
1> {ok, Started} = application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> lists:member(erli18n, Started).
true
3> is_pid(whereis(erli18n_sup)).
true
4> is_pid(whereis(erli18n_server)).
true
5> application:stop(erli18n).
ok
```

> The exact list in `{ok, Started}` depends on the environment. Since
> `telemetry` is declared in `optional_applications` in `erli18n.app.src`,
> if it is present but not yet started, `ensure_all_started/1` brings it
> up too and includes it in the list (e.g. `{ok,[telemetry,erli18n]}`). The
> literal `{ok,[erli18n]}` above holds when `telemetry` is absent or already
> up; that is why the robust test is `lists:member(erli18n, Started)`, not
> a comparison against the whole list.

See `start/2` and `stop/1` for the semantics of each callback.
""".

-behaviour(application).

-export([start/2, stop/1]).

-doc """
Callback `c:application:start/2`: brings up the root supervision tree.

Delegates raw to `erli18n_sup:start_link/0` and returns the supervisor's
`{ok, Pid}` without any wrapping. That `Pid` is the pid that the
`application_controller` adopts as the pid of the `erli18n` application and
goes on to monitor; when it dies, the application is considered terminated.

## Parameters

- `Type` — the start type that OTP passes (`normal` on a regular boot;
  `{takeover, Node}` / `{failover, Node}` in distributed applications).
  **Ignored**: the erli18n boot is identical in any mode, so there is no
  branching on `Type`.
- `Args` — the term from `{mod, {erli18n_app, Args}}` in `erli18n.app.src`,
  today `[]`. **Ignored**: no boot configuration is read here (the runtime
  defaults live in `env` and are read by `erli18n_telemetry`, not by this
  callback).

## Return

- `{ok, Pid}` — on success, passed through directly from `erli18n_sup:start_link/0`.
- Any `{error, Reason}` coming from below **propagates intact**: this
  callback has no `try`/`catch` and no fallback. The normal case of a child
  failing at boot is an `{error, {shutdown, Reason}}` — the form that
  `supervisor:start_link/3` returns (and which the *Return* section of
  `erli18n_sup:start_link/0` already documents) when a child fails its own
  `init/1`, e.g. `erli18n_table_owner` failing to create the ETS table
  or `erli18n_server` failing to claim it. That is the term the
  maintainer will see and match on. An error here makes `ensure_all_started/1`
  fail and the application does not come up — the correct OTP behavior, with
  no masking.

## Example

```erlang
1> {ok, Started} = application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> lists:member(erli18n, Started).
true
3> SupPid = whereis(erli18n_sup), is_pid(SupPid).
true
```

> The literal `{ok,[erli18n]}` on line 1 holds when `telemetry` (declared
> in `optional_applications`) is absent or already started; if it gets
> brought up now, it also appears in the list. Hence the `lists:member/2`
> instead of comparing the whole list.

Sibling function: `stop/1`. Topology started: `erli18n_sup:init/1`.
""".
start(_Type, _Args) ->
    erli18n_sup:start_link().

-doc """
Callback `c:application:stop/1`: post-shutdown cleanup point — a no-op here.

The `application_controller` calls `stop/1` **after** having already torn
down the supervision tree (terminating the children in reverse start order:
`erli18n_server` before `erli18n_table_owner`, each running its own
`terminate/2`). By the time control reaches here, no resource of this module
is left to release, because it created none — no ETS, no process
dictionary, no ports. That is why the body is just `ok`.

## Parameters

- `State` — the value that `start/2` would have returned as the second
  element of `{ok, Pid, State}`. Since `start/2` returns the 2-tuple
  `{ok, Pid}` (without `State`), it is the `application_controller` that
  substitutes `[]` for the `State` when calling this callback: when `start/2`
  uses the `{ok, Pid}` form instead of `{ok, Pid, State}`, the controller
  normalizes the missing state to `[]`. That is why the argument here is
  `[]`. **Ignored** either way: there is no state to undo.

## Return

- `ok` — always. This callback has no error path and no crash path: it is
  total and does not inspect the argument.

## Example

```erlang
1> application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> application:stop(erli18n).
ok
3> whereis(erli18n_sup).
undefined
```

Sibling function: `start/2`. The shutdown of the children belongs to the
supervision tree: see `erli18n_sup`.
""".
stop(_State) ->
    ok.
