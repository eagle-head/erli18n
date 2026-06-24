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
supervision tree, with ONE cleanup responsibility on shutdown. The
load-bearing complexity lives **one hop ahead**:

- `start/2` calls `erli18n_sup:start_link/0` and returns the supervisor's
  `{ok, Pid}` *raw*, unwrapped. That `Pid` becomes the pid of the
  application that the `application_controller` goes on to monitor.
- The real topology lives in `erli18n_sup`: a `one_for_one` strategy with
  a single child — `erli18n_server` (worker/writer). The catalogs live in
  `persistent_term` (see `erli18n_pt_store`), which is owned by the
  **runtime**, not by any process, so a crash of the worker loses no
  catalog and the tree needs no table owner, no heir, and no child
  ordering. See `erli18n_sup`.
- **`stop/1` has real work: it erases the catalogs.** `persistent_term`
  is node-global and is NOT cleared when the application stops, so without
  an explicit erase a stop/start cycle would leave stale catalogs behind
  (and a fresh start would see them as already loaded). `stop/1` calls
  `erli18n_pt_store:erase_all/0` to remove every `{erli18n_catalog, _, _}`
  term. This module reads no `application:get_env/2`: the `env` defaults
  (`emit_lookup_telemetry`, `memory_warning_threshold`,
  `memory_warning_rate_limit_seconds`) are declared in `erli18n.app.src`
  and consumed by `erli18n_telemetry` — never here.
- The ordered shutdown of the child (including the worker's `terminate/2`)
  is the supervision tree's job, triggered by the `application_controller`
  *before* it calls `stop/1`. By the time `stop/1` runs the worker is
  already down, but the catalogs it installed still live in
  `persistent_term` — which is exactly why `stop/1` must erase them here.

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
  `erli18n_sup:start_link/0` already documents) when the `erli18n_server`
  child fails its own `init/1`. That is the term the maintainer will see and
  match on. An error here makes `ensure_all_started/1` fail and the
  application does not come up — the correct OTP behavior, with no masking.

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
Callback `c:application:stop/1`: erases the loaded catalogs on shutdown.

The `application_controller` calls `stop/1` **after** having already torn
down the supervision tree (terminating `erli18n_server`, which runs its own
`terminate/2`). The worker is down by now, but the catalogs it installed
still live in `persistent_term`, which is node-global and is NOT cleared
when the application stops. So this callback calls
`erli18n_pt_store:erase_all/0` to remove every `{erli18n_catalog, _, _}`
term — otherwise a stop/start cycle would leak stale catalogs (and a fresh
start would treat them as already loaded). It returns `ok`.

## Parameters

- `State` — the value that `start/2` would have returned as the second
  element of `{ok, Pid, State}`. Since `start/2` returns the 2-tuple
  `{ok, Pid}` (without `State`), it is the `application_controller` that
  substitutes `[]` for the `State` when calling this callback: when `start/2`
  uses the `{ok, Pid}` form instead of `{ok, Pid, State}`, the controller
  normalizes the missing state to `[]`. That is why the argument here is
  `[]`. **Ignored**: the cleanup target (`persistent_term`) is node-global,
  not carried in `State`.

## Return

- `ok` — always. `erli18n_pt_store:erase_all/0` returns the count of erased
  catalogs (used only for observability/tests); this callback discards it and
  returns the OTP-mandated `ok`. It has no error path: `erase_all/0` is total.

## Example

```erlang
1> application:ensure_all_started(erli18n).
{ok,[erli18n]}
2> application:stop(erli18n).
ok
3> whereis(erli18n_sup).
undefined
```

Sibling function: `start/2`. The shutdown of the child belongs to the
supervision tree: see `erli18n_sup`.
""".
stop(_State) ->
    %% `persistent_term' is node-global and NOT cleared on application stop;
    %% erase every catalog so a stop/start cycle does not leak stale state.
    %% The returned count is for observability/tests only — discard it and
    %% return the OTP-mandated `ok'.
    _ErasedCount = erli18n_pt_store:erase_all(),
    ok.
