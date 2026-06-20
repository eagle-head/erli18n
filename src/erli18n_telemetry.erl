-module(erli18n_telemetry).

-moduledoc """
erli18n observability surface: a thin wrapper over the `:telemetry` library
that centralizes the event names and shields call sites from the absence of
the optional dependency.

## What it is and what problem it solves

`telemetry` is an **optional** dependency of erli18n (declared via
`optional_applications`, OTP 24+): the lib works with or without it. This
module is the only layer that knows this. It solves three problems for the
rest of the code base:

- **Safe indirection.** Call sites (`erli18n_server`, the lookup hot path)
  call `emit/3`/`span/3` without ever testing whether `telemetry` is present.
  When the lib is not loaded, both become no-ops — zero crash, zero noise —
  instead of scattering `case code:ensure_loaded(...)` everywhere.
- **Name contract.** All erli18n event names live here, exposed as pre-typed
  `event_*/0` functions. A rename or audit is a one-file change. The names are
  the **public contract** of observability (convention
  `[<lib>, <operation>, <phase>]`, in the style of `Phoenix.Logger`).
- **Overhead and security policy.** The high-frequency lookup events
  (`miss`/`fuzzy_skip`) are opt-in (flag `emit_lookup_telemetry`, default
  `false`) — this minimizes both the cost and the risk of leaking msgid
  content in a multi-tenant scenario. The `memory_warning` is rate-limited: at
  most one emission per configured window.

## Mental model

Think of two layers, both **lock-free from any process**:

- **Telemetry detection (sticky-positive cache).** The first call performs
  `code:ensure_loaded(telemetry)`, which walks the code server. If it loads,
  the `true` result is stored in `persistent_term` and stays sticky for the
  rest of the VM's lifetime (telemetry does not unload at runtime). If it does
  **not** load, the `false` result is **not** cached: that way, if the
  consumer brings telemetry up mid-flight (`application:start(telemetry)`),
  the next emission already sees it. The price of this choice is, at most, one
  `code:ensure_loaded/1` per emission while telemetry is absent
  (microseconds), and zero per emission once present.
- **Configuration via `application:get_env/3`.** The flags
  (`emit_lookup_telemetry`, `memory_warning_threshold`,
  `memory_warning_rate_limit_seconds`) are read on every call — a direct read
  in the application controller's ETS (~100 ns). There is no per-process state
  and no caching of these flags.

Trusted vs untrusted: the rate-limit `persistent_term` key is **private** to
this module. The functions narrow its value at the boundary; if something
outside reuses the key and writes a non-integer, the code crashes explicitly
instead of operating on garbage. Invalid configuration values (non-boolean,
negative integer) also crash with `{invalid_config, ...}` — a loud, visible
failure, never silent.

## When a dev touches this module

- **Observability consumer** (attaches handlers): use the `event_*/0` names in
  `telemetry:attach/4`. Do not call `emit/3`/`span/3` directly — erli18n is
  what emits.
- **Core maintainer** (`erli18n_server`, hot path): call `span/3` to
  instrument operations with start/stop (load/reload), `emit/3` for pointwise
  events, and `lookup_telemetry_enabled/0` to gate the lookup events before
  building expensive payloads. The loader calls `memory_warning_check/1`.

## Quickstart (consumer)

```erlang
%% Attach a handler to the catalog-load events:
1> telemetry:attach_many(
..     <<"erli18n-log">>,
..     [erli18n_telemetry:event_catalog_load(),
..      erli18n_telemetry:event_catalog_load() ++ [stop]],
..     fun(Event, Measurements, Meta, _Cfg) ->
..         io:format("~p ~p ~p~n", [Event, Measurements, Meta])
..     end,
..     undefined).
ok
%% Lookup events are opt-in; enable them explicitly:
2> application:set_env(erli18n, emit_lookup_telemetry, true).
ok
3> erli18n_telemetry:lookup_telemetry_enabled().
true
```

## Key functions

- Emission: `emit/3` (pointwise), `span/3` (start/stop/exception).
- Event names: `event_catalog_load/0`, `event_catalog_reload/0`,
  `event_catalog_unload/0`, `event_lookup_miss/0`, `event_lookup_fuzzy_skip/0`,
  `event_locale_fallback/0`, `event_plural_divergence/0`,
  `event_catalog_memory_warning/0`.
- Configuration/gating: `lookup_telemetry_enabled/0`,
  `memory_warning_threshold/0`, `memory_warning_rate_limit_seconds/0`,
  `memory_warning_check/1`.

## References

- Library: <https://github.com/beam-telemetry/telemetry>
- Hexdocs: <https://hexdocs.pm/telemetry/>
- `span/3`: <https://hexdocs.pm/telemetry/telemetry.html#span-3>
- Naming convention `[<lib>, <operation>, <phase>]`:
  <https://hexdocs.pm/phoenix/Phoenix.Logger.html>
- `persistent_term` (lock-free, copy-free across processes):
  <https://www.erlang.org/doc/man/persistent_term.html>
""".

%% ============================================================================
%%  erli18n_telemetry — thin wrapper over the `:telemetry` library.
%%
%%  Responsibilities:
%%
%%    * Encapsulate the runtime presence/absence of the `telemetry` module
%%      so call sites never have to branch. If `telemetry` is not loaded,
%%      `emit/3` and `span/3` are no-ops (zero crash, zero noise).
%%
%%    * Centralize all `erli18n` event names (`[erli18n, catalog, load]`,
%%      etc.) so a future rename or audit is a one-file change. The event
%%      names are the **public contract** of the lib's observability
%%      surface (naming convention and catalogue of events).
%%
%%    * Provide opt-in/opt-out gating for high-frequency events
%%      (lookup miss / fuzzy_skip) via the `emit_lookup_telemetry`
%%      application env flag. Always-on events bypass the gate (overhead
%%      policy).
%%
%%    * Provide a rate-limited memory-warning check used by the loader
%%      to emit `[erli18n, catalog, memory_warning]` at most once per
%%      configured window (RISK-011 mitigation 2: "once per crossing
%%      event, not on every tick").
%%
%%  References:
%%
%%    * Library:   https://github.com/beam-telemetry/telemetry
%%    * Hexdocs:   https://hexdocs.pm/telemetry/
%%    * span/3:    https://hexdocs.pm/telemetry/telemetry.html#span-3
%%    * Phoenix:   https://hexdocs.pm/phoenix/Phoenix.Logger.html — naming
%%                 convention `[<lib>, <operation>, <phase>]` source.
%%
%%  Performance note (`code:ensure_loaded/1` cache):
%%
%%    The first call walks the code path to confirm whether `telemetry`
%%    is loadable; subsequent calls hit a `persistent_term` entry
%%    (~sub-microsecond, lock-free, copy-free across processes — see
%%    https://www.erlang.org/doc/man/persistent_term.html). The cache is
%%    invalidated only when the result is `false` (in case the consumer
%%    starts telemetry mid-flight); positive results are sticky for the
%%    VM's lifetime.
%% ============================================================================

%% Emission API.
-export([emit/3, span/3]).

%% Convenience: pre-typed event names.
-export([
    event_catalog_load/0,
    event_catalog_reload/0,
    event_catalog_unload/0,
    event_lookup_miss/0,
    event_lookup_fuzzy_skip/0,
    event_locale_fallback/0,
    event_plural_divergence/0,
    event_catalog_memory_warning/0
]).

%% Configuration / gating.
-export([
    lookup_telemetry_enabled/0,
    memory_warning_threshold/0,
    memory_warning_rate_limit_seconds/0,
    memory_warning_check/1
]).

%% Test-only — exposed so the SUITE can reset the persistent_term cache
%% between cases. Not in the documented API surface.
-export([reset_caches/0]).

-export_type([
    event_name/0,
    measurements/0,
    metadata/0,
    span_fun/0,
    span_result/0
]).

%% =========================
%% Types
%% =========================

-doc """
Name of a telemetry event: a list of atoms in the format
`[<lib>, <operation>, <phase>]` (e.g. `[erli18n, catalog, load]`). It is the
type returned by all `event_*/0` functions and the one accepted by
`emit/3`/`span/3`. The list contains the atoms of the erli18n vocabulary and
admits a free `atom()` in the tail for extensions (e.g. the `start`/`stop`
suffix that `span/3` appends).
""".
%% Event name shapes.
-type event_name() ::
    [
        erli18n
        | catalog
        | lookup
        | plural
        | locale
        | load
        | reload
        | unload
        | miss
        | fuzzy_skip
        | fallback
        | divergence_warning
        | memory_warning
        | atom()
    ].

-doc """
Map of an event's numeric **measurements** (e.g. `#{duration => N}`,
`#{ets_bytes => N}`). Structurally it is just a `map()`; the telemetry
convention is that measurements are aggregable values, distinct from
qualitative metadata.
""".
-type measurements() :: map().

-doc """
Map of an event's qualitative **metadata** (e.g. domain, locale,
`domain_locales_sample` sample). Structurally it is just a `map()`; it carries
context, not aggregable values.
""".
-type metadata() :: map().

-doc """
Body of a span: a fun/0 that **must** return `{Result, StopMetadata}`, per the
contract of `telemetry:span/3`. `Result` is propagated back by `span/3`;
`StopMetadata` is merged into the `stop` event's metadata (or discarded on the
no-op path, when telemetry is absent).
""".
%% Span body must return `{Result, StopMetadata}` per
%% https://hexdocs.pm/telemetry/telemetry.html#span-3.
-type span_fun() :: fun(() -> {term(), metadata()}).

-doc "Return value of `span/3`: the `Result` produced by `span_fun/0`.".
-type span_result() :: term().

%% =========================
%% Cache keys (persistent_term)
%% =========================

%% Sticky-true cache for the loaded check.
-define(LOADED_KEY, {?MODULE, telemetry_loaded}).
%% Rate-limit anchor for memory_warning emission.
-define(MEM_WARN_LAST_KEY, {?MODULE, memory_warning_last_emit}).

%% =========================
%% Event names
%% =========================

-doc """
Event prefix of a catalog's **load span** (`ensure_loaded`):
`[erli18n, catalog, load]`. Since it is a span prefix (via `span/3`), the
events actually emitted have the `start`/`stop`/`exception` suffix appended.

```erlang
1> erli18n_telemetry:event_catalog_load().
[erli18n,catalog,load]
```

Siblings: `event_catalog_reload/0`, `event_catalog_unload/0`.
""".
-spec event_catalog_load() -> event_name().
event_catalog_load() ->
    [erli18n, catalog, load].

-doc """
Event prefix of a catalog's **atomic reload span**:
`[erli18n, catalog, reload]`. As a span prefix, it receives the
`start`/`stop`/`exception` suffix at runtime.

```erlang
1> erli18n_telemetry:event_catalog_reload().
[erli18n,catalog,reload]
```

Siblings: `event_catalog_load/0`, `event_catalog_unload/0`.
""".
-spec event_catalog_reload() -> event_name().
event_catalog_reload() ->
    [erli18n, catalog, reload].

-doc """
Name of the pointwise catalog **unload** event:
`[erli18n, catalog, unload]`. Emitted via `emit/3` (not a span).

```erlang
1> erli18n_telemetry:event_catalog_unload().
[erli18n,catalog,unload]
```

Siblings: `event_catalog_load/0`, `event_catalog_reload/0`.
""".
-spec event_catalog_unload() -> event_name().
event_catalog_unload() ->
    [erli18n, catalog, unload].

-doc """
Name of the **lookup miss** event (key not found in the catalog):
`[erli18n, lookup, miss]`. A **high-frequency** event and therefore **opt-in**
— only emitted when `lookup_telemetry_enabled/0` returns `true`. Keeping the
default off also avoids exposing msgid content in a multi-tenant scenario.

```erlang
1> erli18n_telemetry:event_lookup_miss().
[erli18n,lookup,miss]
```

Sibling: `event_lookup_fuzzy_skip/0`. Gate: `lookup_telemetry_enabled/0`.
""".
-spec event_lookup_miss() -> event_name().
event_lookup_miss() ->
    [erli18n, lookup, miss].

-doc """
Name of the **fuzzy entry skip** event in lookup (an entry marked
`#, fuzzy` in the `.po`, which gettext ignores): `[erli18n, lookup, fuzzy_skip]`.
A **high-frequency** event, **opt-in** under the same flag as the misses
(`lookup_telemetry_enabled/0`).

```erlang
1> erli18n_telemetry:event_lookup_fuzzy_skip().
[erli18n,lookup,fuzzy_skip]
```

Sibling: `event_lookup_miss/0`. Gate: `lookup_telemetry_enabled/0`.
""".
-spec event_lookup_fuzzy_skip() -> event_name().
event_lookup_fuzzy_skip() ->
    [erli18n, lookup, fuzzy_skip].

-doc """
Name of the **locale fallback** event: `[erli18n, locale, fallback]`. Emitted
(Phase 2) when an exact-locale lookup MISSES but the opt-in canonicalization-
aware fallback chain resolves the translation from a less-specific or
canonicalized locale (`pt_BR` → `pt`). The low-frequency, interesting signal
"a non-exact locale served a translation" — distinct from a true
`[erli18n, lookup, miss]` (whole chain missed).

**Opt-in** under the SAME flag as the lookup events
(`lookup_telemetry_enabled/0`): fallback resolution is by construction a
sub-event of a lookup miss, so it shares the switch and the multi-tenant
msgid-exposure policy. Off the exact-hit path entirely.

Measurements: `#{count => 1, chain_depth => non_neg_integer()}` (depth = the
0-based position in the chain of the candidate that hit). Metadata:
`#{domain, requested_locale, resolved_locale, function, context}`.

```erlang
1> erli18n_telemetry:event_locale_fallback().
[erli18n,locale,fallback]
```

Gate: `lookup_telemetry_enabled/0`. Sibling: `event_lookup_miss/0`.
""".
-spec event_locale_fallback() -> event_name().
event_locale_fallback() ->
    [erli18n, locale, fallback].

-doc """
Name of the **plural divergence warning** event:
`[erli18n, plural, divergence_warning]`. Emitted at load time when the
`Plural-Forms` rule in the `.po` header diverges from the CLDR rule inlined for
the locale (an informative validation — the `.po` header remains the source of
truth at runtime). Always on (does not go through the lookup flag).

```erlang
1> erli18n_telemetry:event_plural_divergence().
[erli18n,plural,divergence_warning]
```
""".
-spec event_plural_divergence() -> event_name().
event_plural_divergence() ->
    [erli18n, plural, divergence_warning].

-doc """
Name of the **memory warning** event: `[erli18n, catalog, memory_warning]`.
Emitted by `memory_warning_check/1` when the catalogs' ETS usage crosses
`memory_warning_threshold/0`, **rate-limited** to at most one emission per
`memory_warning_rate_limit_seconds/0`. Always on (does not go through the
lookup flag).

```erlang
1> erli18n_telemetry:event_catalog_memory_warning().
[erli18n,catalog,memory_warning]
```

Emitter: `memory_warning_check/1`.
""".
-spec event_catalog_memory_warning() -> event_name().
event_catalog_memory_warning() ->
    [erli18n, catalog, memory_warning].

%% =========================
%% Emission
%% =========================

%% Pointwise emit. Safe no-op when `telemetry` is unavailable. The naked
%% `erlang:apply/3` indirection is intentional: dialyzer treats the call
%% as an unknown remote function when `telemetry` is genuinely absent
%% from the PLT, which matches the runtime story exactly.
-doc """
Emits a **pointwise** telemetry event (no start/stop semantics; for that use
`span/3`).

Parameters:
- `EventName` — the event name, typically one of the `event_*/0` (e.g.
  `event_catalog_unload/0`). Must be a list.
- `Measurements` — map of numeric/aggregable measurements. Must be a map.
- `Metadata` — map of qualitative metadata. Must be a map.

Behavior and return: if `telemetry` is loaded (see the sticky detection in the
moduledoc), it delegates to `telemetry:execute/3`; otherwise it is a **safe
no-op**. On both paths it always returns `ok` — the result of
`telemetry:execute/3` is discarded on purpose.

Failure modes: the clause is guarded (`is_list`/`is_map`/`is_map`); calling
with the wrong types results in `function_clause` (caller crash). The
`erlang:apply(telemetry, execute, ...)` indirection is **intentional**: it
makes dialyzer treat the call as an unknown remote function when `telemetry`
is genuinely absent from the PLT, mirroring the runtime story.

```erlang
1> erli18n_telemetry:emit(
..     erli18n_telemetry:event_catalog_unload(),
..     #{count => 1},
..     #{domain => my_domain, locale => <<"fr">>}).
ok
```

The no-op path does not depend on `telemetry` being **loaded in memory**, but
on `telemetry` being **absent from the code path** — detection (see
`telemetry_loaded/0` / moduledoc) uses `code:ensure_loaded(telemetry)`, which
would load the module from the code path if it existed there. In other words:
`code:is_loaded(telemetry) =:= false` does **not** make `emit/3` a no-op (the
module would still be loaded and the event emitted). The no-op only occurs when
the `telemetry` app is not in the release/code path; in that scenario the same
call returns `ok` without emitting anything.

Sibling: `span/3` (events with start/stop).
""".
-spec emit(event_name(), measurements(), metadata()) -> ok.
emit(EventName, Measurements, Metadata) when
    is_list(EventName), is_map(Measurements), is_map(Metadata)
->
    case telemetry_loaded() of
        true ->
            _ = erlang:apply(
                telemetry,
                execute,
                [EventName, Measurements, Metadata]
            ),
            ok;
        false ->
            ok
    end.

%% Span emit. Matches the `:telemetry.span/3` contract:
%%   * Emits `EventPrefix ++ [start]` with measurements
%%     `#{monotonic_time, system_time}` and StartMetadata.
%%   * Runs Fun, which must return `{Result, StopMetadata}`.
%%   * Emits `EventPrefix ++ [stop]` with measurements
%%     `#{monotonic_time, duration}` and (StartMetadata merged with
%%     StopMetadata).
%%   * On exception, emits `EventPrefix ++ [exception]` instead of stop,
%%     with `#{kind, reason, stacktrace}` merged into StartMetadata.
%%
%% Reference: https://hexdocs.pm/telemetry/telemetry.html#span-3.
%%
%% Always-on path (telemetry loaded): we delegate to `:telemetry.span/3`
%% to avoid duplicating the implementation, which keeps measurement
%% semantics byte-equal to what `:telemetry` users expect.
%%
%% No-op path (telemetry absent): we still run Fun (otherwise the lib
%% would behave differently with vs without telemetry — unacceptable).
%% We discard StopMetadata because there's nothing to emit it to.
-doc """
Runs `Fun` instrumented as a telemetry **span**, following the contract of
`telemetry:span/3` (events with start, stop, and exception).

Parameters:
- `EventPrefix` — the event prefix (e.g. `event_catalog_load/0`). Telemetry
  appends `start`/`stop`/`exception` to this prefix. Must be a list.
- `StartMetadata` — metadata already available in the `start` event (and
  merged into `stop`). Must be a map.
- `Fun` — the span body, a fun/0 that **MUST** return `{Result, StopMetadata}`
  (see `span_fun/0`).

Contract semantics (path with telemetry loaded): emits
`EventPrefix ++ [start]` with measurements `#{monotonic_time, system_time}`;
runs `Fun`; emits `EventPrefix ++ [stop]` with `#{monotonic_time, duration}`
and `StartMetadata` merged with `StopMetadata`. If `Fun` raises an exception,
it emits `EventPrefix ++ [exception]` (with `#{kind, reason, stacktrace}` in
the metadata) instead of `stop`, and the exception re-propagates. It delegates
to `telemetry:span/3` to keep the measurements byte-equal to what `:telemetry`
users expect.

No-op path semantics (telemetry absent): it **still runs `Fun`** — otherwise
the lib would behave differently with vs without telemetry, which is
unacceptable — and discards `StopMetadata` (there is nowhere to emit it). No
event is emitted.

Return: on both paths, the `Result` produced by `Fun` (see `span_result/0`).

Failure modes: guarded clause (`is_list`/`is_map`/`is_function(Fun, 0)`); wrong
types => `function_clause`. If `Fun` does not return a `{Result, StopMetadata}`
tuple, both paths crash, but **asymmetrically** with respect to the events
already emitted:
- **No-op path (telemetry absent):** crashes with `badmatch` at
  `{Result, _StopMetadata} = Fun()` **before** any emission — no event goes
  out (consistent with the no-op never emitting anything).
- **Path with telemetry:** `telemetry:span/3` has already emitted the
  `EventPrefix ++ [start]` event **before** inspecting `Fun`'s return, so the
  consumer sees an **orphan** `start` (without a matching `stop` or
  `exception`) followed by the crash inside the `telemetry` lib itself when
  matching the invalid shape. This is exactly the symptom to look for when
  debugging `start` events without a `stop`.

```erlang
1> erli18n_telemetry:span(
..     erli18n_telemetry:event_catalog_load(),
..     #{domain => my_domain, locale => <<"fr">>},
..     fun() ->
..         Result = do_load(),           %% instrumented work
..         {Result, #{entries => 128}}   %% {Result, StopMetadata}
..     end).
Result
```

Sibling: `emit/3` (pointwise events).
""".
-spec span(event_name(), metadata(), span_fun()) -> span_result().
span(EventPrefix, StartMetadata, Fun) when
    is_list(EventPrefix), is_map(StartMetadata), is_function(Fun, 0)
->
    case telemetry_loaded() of
        true ->
            erlang:apply(
                telemetry,
                span,
                [EventPrefix, StartMetadata, Fun]
            );
        false ->
            {Result, _StopMetadata} = Fun(),
            Result
    end.

%% =========================
%% Configuration / gating
%% =========================

%% Opt-in flag for the high-frequency lookup events.
%%
%% `application:get_env/3` lookup is an ETS-direct read in the OTP
%% application controller (~100 ns), comparable to telemetry's own no-op
%% overhead. The flag eliminates the overhead of an attached handler, not
%% the overhead of looking up the flag — that is the theoretical limit of
%% the design.
-doc """
Gate for the high-frequency lookup events (`event_lookup_miss/0` and
`event_lookup_fuzzy_skip/0`). Call sites call this function **before** building
expensive payloads, so that the overhead only exists when the operator opts in.

Reads the app env `emit_lookup_telemetry` (default `false` — opt-in, also for
multi-tenant security reasons). The read is a direct access to the application
controller's ETS (~100 ns); this function does **not** eliminate the overhead
of looking up the flag itself, only that of having handlers attached — it is
the theoretical limit of the design.

Return and failure modes: `true` for `true`, `false` for `false`. Any **other**
configured value is a configuration error and triggers an explicit crash with
`error({invalid_config, {erli18n, emit_lookup_telemetry, Other, expected,
boolean}})` — a loud, visible failure, never a silent "treat as false".

```erlang
1> erli18n_telemetry:lookup_telemetry_enabled().
false
2> application:set_env(erli18n, emit_lookup_telemetry, true).
ok
3> erli18n_telemetry:lookup_telemetry_enabled().
true
4> application:set_env(erli18n, emit_lookup_telemetry, "yes").
ok
5> erli18n_telemetry:lookup_telemetry_enabled().
** exception error: {invalid_config,{erli18n,emit_lookup_telemetry,"yes",expected,boolean}}
```

Siblings (config): `memory_warning_threshold/0`,
`memory_warning_rate_limit_seconds/0`.
""".
-spec lookup_telemetry_enabled() -> boolean().
lookup_telemetry_enabled() ->
    case application:get_env(erli18n, emit_lookup_telemetry, false) of
        true -> true;
        false -> false;
        Other -> error({invalid_config, {erli18n, emit_lookup_telemetry, Other, expected, boolean}})
    end.

%% Bytes threshold for memory_warning. Default 100 MiB (104857600).
-doc """
Threshold, in **bytes**, of the catalogs' ETS usage above which
`event_catalog_memory_warning/0` becomes eligible. Compared against `ets_bytes`
inside `memory_warning_check/1` with a strict `>` (equaling the threshold does
**not** fire).

Reads the app env `memory_warning_threshold` (default `104857600`, 100 MiB).

Return and failure modes: a valid `non_neg_integer()`. Any value that is not an
integer `>= 0` (negative, non-integer) triggers a crash with
`error({invalid_config, {erli18n, memory_warning_threshold, Other, expected,
non_neg_integer}})`.

```erlang
1> erli18n_telemetry:memory_warning_threshold().
104857600
2> application:set_env(erli18n, memory_warning_threshold, 52428800).
ok
3> erli18n_telemetry:memory_warning_threshold().
52428800
4> application:set_env(erli18n, memory_warning_threshold, -1).
ok
5> erli18n_telemetry:memory_warning_threshold().
** exception error: {invalid_config,{erli18n,memory_warning_threshold,-1,expected,non_neg_integer}}
```

Consumer: `memory_warning_check/1`. Sibling: `memory_warning_rate_limit_seconds/0`.
""".
-spec memory_warning_threshold() -> non_neg_integer().
memory_warning_threshold() ->
    case application:get_env(erli18n, memory_warning_threshold, 104857600) of
        N when is_integer(N), N >= 0 -> N;
        Other ->
            error(
                {invalid_config,
                    {erli18n, memory_warning_threshold, Other, expected, non_neg_integer}}
            )
    end.

%% Window (seconds) between successive memory_warning emits.
-doc """
Window, in **seconds**, between successive emissions of
`event_catalog_memory_warning/0`. Even if the threshold is crossed on every
load, `memory_warning_check/1` only re-emits after this window has elapsed
since the last emission (mitigation: "once per crossing event, not on every
tick").

Reads the app env `memory_warning_rate_limit_seconds` (default `60`).

Return and failure modes: a valid `non_neg_integer()`. A value that is not an
integer `>= 0` triggers a crash with `error({invalid_config, {erli18n,
memory_warning_rate_limit_seconds, Other, expected, non_neg_integer}})`. A
value of `0` makes every crossing re-emit (a degenerate window, with no
effective rate limit).

```erlang
1> erli18n_telemetry:memory_warning_rate_limit_seconds().
60
2> application:set_env(erli18n, memory_warning_rate_limit_seconds, 300).
ok
3> erli18n_telemetry:memory_warning_rate_limit_seconds().
300
```

Consumer: `memory_warning_check/1`. Sibling: `memory_warning_threshold/0`.
""".
-spec memory_warning_rate_limit_seconds() -> non_neg_integer().
memory_warning_rate_limit_seconds() ->
    case application:get_env(erli18n, memory_warning_rate_limit_seconds, 60) of
        N when is_integer(N), N >= 0 -> N;
        Other ->
            error(
                {invalid_config,
                    {erli18n, memory_warning_rate_limit_seconds, Other, expected, non_neg_integer}}
            )
    end.

%% Inspect the given memory_info and emit a single memory_warning event
%% if the threshold is crossed and the rate-limit window has elapsed.
%%
%% Returns:
%%   * `not_warned`     — threshold not crossed.
%%   * `rate_limited`   — threshold crossed but a warning was already
%%     emitted within the rate-limit window.
%%   * `warned`         — a `[erli18n, catalog, memory_warning]` event
%%     was just emitted.
%%
%% Rate-limit storage uses `persistent_term` so the check is lock-free
%% from any process. The cost of storing a single integer is one VM
%% global GC at update time — acceptable because the update only happens
%% on actual emit (rare, by design).
-doc """
Inspects the `MemInfo` memory snapshot and emits **at most one**
`event_catalog_memory_warning/0`, deciding among not-warning, suppressing by
rate-limit, or warning. Called by the loader (`erli18n_server`) at the end of a
successful load.

Parameter:
- `MemInfo` — a snapshot map. The keys read are `ets_bytes` (ETS usage, the
  trigger; default `0` if absent), `num_catalogs` and `num_keys` (only used in
  the measurement when warning; default `0`). Must be a map, otherwise
  `function_clause`.

Decision logic:
1. If `ets_bytes` is **not** `>` `memory_warning_threshold/0`, returns
   `not_warned` (strict `>` comparison).
2. Otherwise, if the `memory_warning_rate_limit_seconds/0` window has **not**
   yet elapsed since the last emission, returns `rate_limited` without emitting.
3. Otherwise, writes the current instant to the anchor, builds the sample and
   emits via `emit/3`, returning `warned`.

Side effects: the rate-limit anchor is a **private** key in `persistent_term`
(lock-free from any process), updated **only** on an actual emission.
Rewriting the key via `persistent_term:put/2` may trigger GC work proportional
to the processes that still hold references to the **previous** value of this
key — not an unconditional global full GC of the VM. Here that is cheap (the
previous value is a single timestamp integer, with no long-lived holders) and,
moreover, it only happens on the `warned` path (rare, by design), so the cost
is acceptable. The payload of the warned event has:
- measurements `#{ets_bytes, threshold_bytes, num_catalogs, num_keys}`;
- metadata `#{domain_locales_sample => [...]}`, a sample of up to 10
  `{Domain, Locale}` pairs (payload bound in a multi-tenant deployment),
  collected by `collect_domain_locales_sample/0`.

Failure modes: if `ets_bytes` or the counters are non-numeric, the `>` or the
construction of the measurements crash. If the `persistent_term` anchor holds a
non-integer (someone reusing the private key — a contract violation), the
boundary crashes with `{invalid_persistent_term, ...}` instead of operating on
garbage.

```erlang
%% Below the default threshold (100 MiB): nothing happens.
1> erli18n_telemetry:memory_warning_check(#{ets_bytes => 1024}).
not_warned
%% Above the threshold: the first call warns...
2> erli18n_telemetry:memory_warning_check(
..     #{ets_bytes => 209715200, num_catalogs => 3, num_keys => 4096}).
warned
%% ...and the next one, within the rate-limit window, is suppressed.
3> erli18n_telemetry:memory_warning_check(#{ets_bytes => 209715200}).
rate_limited
```

Config: `memory_warning_threshold/0`, `memory_warning_rate_limit_seconds/0`.
Event: `event_catalog_memory_warning/0`. In tests, `reset_caches/0` zeroes the
anchor.
""".
-spec memory_warning_check(map()) -> not_warned | rate_limited | warned.
memory_warning_check(MemInfo) when is_map(MemInfo) ->
    Threshold = memory_warning_threshold(),
    Bytes = maps:get(ets_bytes, MemInfo, 0),
    case Bytes > Threshold of
        false ->
            not_warned;
        true ->
            Now = erlang:system_time(second),
            Window = memory_warning_rate_limit_seconds(),
            %% `persistent_term:get/2` returns `term()`. The value under
            %% `?MEM_WARN_LAST_KEY` is only ever written by this module
            %% with `persistent_term:put(?MEM_WARN_LAST_KEY, Now)` where
            %% `Now = erlang:system_time(second) :: integer()`, and the
            %% default we pass is the integer `0`. Narrow at the boundary
            %% so arithmetic is type-checked; a non-integer would mean
            %% someone is reusing our private key — contract violation,
            %% crash explicitly.
            Last =
                case persistent_term:get(?MEM_WARN_LAST_KEY, 0) of
                    L when is_integer(L) -> L;
                    Other ->
                        error(
                            {invalid_persistent_term,
                                {?MEM_WARN_LAST_KEY, Other, expected, integer}}
                        )
                end,
            case (Now - Last) < Window of
                true ->
                    rate_limited;
                false ->
                    persistent_term:put(?MEM_WARN_LAST_KEY, Now),
                    Sample = collect_domain_locales_sample(),
                    emit(
                        event_catalog_memory_warning(),
                        #{
                            ets_bytes => Bytes,
                            threshold_bytes => Threshold,
                            num_catalogs => maps:get(num_catalogs, MemInfo, 0),
                            num_keys => maps:get(num_keys, MemInfo, 0)
                        },
                        %% The memory_warning metadata carries
                        %% `domain_locales_sample`: up to 10
                        %% `{Domain, Locale}` tuples to bound payload
                        %% size in multi-tenant deployments.
                        %% `erli18n_server:loaded_catalogs/0` is a
                        %% caller-process ETS scan — safe to call from
                        %% any process, including the server itself,
                        %% because it never re-enters the gen_server.
                        #{domain_locales_sample => Sample}
                    ),
                    warned
            end
    end.

-doc """
Internal. Collects the `domain_locales_sample` sample for the
`memory_warning`: up to 10 `{Domain, Locale}` pairs from the loaded catalogs.

Invariants and safety for the maintainer:
- Guarded by `erlang:function_exported(erli18n_server, loaded_catalogs, 0)`: if
  the server is not present (e.g. module not loaded in isolated tests), it
  returns `[]` instead of crashing.
- `erli18n_server:loaded_catalogs/0` is an ETS scan in the **caller process** —
  safe to call from any process, **including the gen_server itself**, because
  it never re-enters the `gen_server` (no deadlock risk).
- No ordering: the order is whatever the ETS scan returns. The contract is an
  observability sample, it does not require determinism, and sorting would only
  add cost. The limit of 10 (`lists:sublist/2`) bounds the payload size in a
  multi-tenant deployment.
""".
%% Sample up to 10 (Domain, Locale) tuples. Order is whatever ETS scan
%% returns; we don't sort because the spec doesn't require determinism
%% and sorting would add overhead at no benefit for an observability
%% sample.
collect_domain_locales_sample() ->
    case erlang:function_exported(erli18n_server, loaded_catalogs, 0) of
        true ->
            Catalogs = erli18n_server:loaded_catalogs(),
            Pairs = [{D, L} || {D, L, _N} <- Catalogs],
            lists:sublist(Pairs, 10);
        false ->
            []
    end.

%% =========================
%% Test-only helpers
%% =========================

%% Clear both caches so a test can simulate a fresh VM. Not part of the
%% documented API.
-doc """
Test-only: erases the two `persistent_term` keys of this module — the sticky
"telemetry loaded" cache (`?LOADED_KEY`) and the memory_warning rate-limit
anchor (`?MEM_WARN_LAST_KEY`) — simulating a fresh VM between test cases. It is
not part of the documented API surface (do not rely on it in production). It
always returns `ok`.

Useful for making deterministic the tests of `memory_warning_check/1` (which
switches from `warned` to `rate_limited` depending on the anchor) and those of
telemetry detection.

```erlang
1> erli18n_telemetry:reset_caches().
ok
```
""".
-spec reset_caches() -> ok.
reset_caches() ->
    _ = persistent_term:erase(?LOADED_KEY),
    _ = persistent_term:erase(?MEM_WARN_LAST_KEY),
    ok.

%% =========================
%% Internal
%% =========================

-doc """
Internal. Cached "is telemetry loadable?" detection — the heart of the
no-op-safe contract that `emit/3` and `span/3` consult.

Cache protocol (sticky-positive) for the maintainer:
- **Positive hit:** if `?LOADED_KEY` already holds `true` in `persistent_term`,
  returns `true` directly (~sub-microsecond, lock-free).
- **First call / not yet resolved:** performs `code:ensure_loaded(telemetry)`,
  which walks the code server. On `{module, telemetry}`, it writes `true` to
  the cache (sticky for the VM's lifetime — telemetry does not unload at
  runtime) and returns `true`.
- **Absent:** returns `false` **without** caching. This is deliberate: if the
  consumer brings telemetry up later (`application:start(telemetry)`), the next
  call re-checks and starts to see it. Negative caching would be cheaper in the
  absent case, but it would break on-the-fly enablement and contradict the
  "safe no-op, never crashes" contract.

Cost: at most one `code:ensure_loaded/1` per emission while telemetry is absent
(microseconds); zero per emission once present. `reset_caches/0` erases
`?LOADED_KEY` to force re-detection in tests.
""".
%% Cached "is telemetry loaded?" check.
%%
%% First call: `code:ensure_loaded/1` walks the code server. On success
%% we cache `true` permanently — telemetry doesn't unload at runtime.
%% On failure (module not found, not loadable) we return `false`
%% WITHOUT caching, so that if the consumer brings telemetry up later
%% (`application:start(telemetry)`) the next call observes it.
%%
%% Trade-off: positive-only caching costs at most one
%% `code:ensure_loaded/1` per emit while telemetry is absent
%% (microseconds), and zero per emit once present. Negative caching
%% would be cheaper in the absent case but would prevent on-the-fly
%% enablement, contradicting the "no-op safe, never crashes" contract.
telemetry_loaded() ->
    case persistent_term:get(?LOADED_KEY, undefined) of
        true ->
            true;
        undefined ->
            case code:ensure_loaded(telemetry) of
                {module, telemetry} ->
                    persistent_term:put(?LOADED_KEY, true),
                    true;
                _ ->
                    false
            end
    end.
