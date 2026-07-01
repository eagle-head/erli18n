-module(erli18n_compiled).

-moduledoc """
Consumer-side boot engine for compile-time `.po` -> BEAM catalogs.

This module is the OPT-IN front door a consuming application calls — once, in its
own `start/2`, BEFORE starting its supervision tree — to register every catalog
that the `rebar3_erli18n` build-time codegen baked into generated BEAM modules.
A project that uses no compiled catalogs never calls `register/1`, never loads a
carrier module, and sees ZERO behavioural change: runtime `.po` loading via
`erli18n:ensure_loaded/3,4` stays the default.

## What a "carrier" is

The build-time codegen emits one generated module per catalog. Each carrier:

- has a module name prefixed `erli18n_cc_` (so discovery can find it from the
  consumer app's own module list without a registry);
- carries the marker attribute `-erli18n_compiled_catalog(...)` (so a module that
  merely shares the prefix is never mistaken for a carrier);
- exports `catalog/0` returning an `erli18n_server:compiled_spec()` — the
  ALREADY-parsed entries plus an ALREADY-compiled `Plural-Forms` rule. Boot does
  NO parse and NO plural compile: the heavy work happened at build time.

## How registration works

`register/1` resolves the carriers from the consumer app's OWN
`application:get_key(App, modules)` list (NOT a global scan), confirms each
carrier's marker, reads every `catalog/0`, and hands ALL specs to
`erli18n_server:register_compiled_many/1` in a SINGLE call — one serialized
write, the same critical section the `.po` loader uses. The catalogs then serve
through the lock-free `erli18n_server:lookup_*` hot path, untouched by this
module.

Registration is idempotent (it reuses `ensure_loaded` semantics): a catalog
already loaded — by a prior `register/1`, by `erli18n:ensure_loaded/3`, or by
`reload/3` — reports `{ok, already}` and is NOT overwritten.

## Failure modes (loud, never silent)

- The app atom is wrong or the app is not loaded
  (`application:get_key/2` -> `undefined`): crashes with
  `error({erli18n_compiled_app_not_loaded, App})`. This is a programming error
  (boot ordering / wrong atom), so it fails fast rather than degrading.
- The app IS loaded but no carriers are discovered (its module list is empty, or
  it has modules but none are confirmed carriers): emits ONE `?LOG_WARNING`
  tagged `erli18n_compiled_no_carriers` and returns `[]`. It is never a silent
  no-op — a missing-codegen misconfiguration is surfaced.

See `erli18n:register_compiled_catalogs/1` (the documented facade door),
`erli18n_server:register_compiled_many/1`, and `erli18n_server:compiled_spec()`.
""".

-include_lib("kernel/include/logger.hrl").

-export([
    register/1,
    discover/1,
    confirm_catalog/1,
    read_catalog/1
]).

%% Module-name prefix every generated carrier shares. Discovery filters the
%% consumer app's module list by this prefix BEFORE loading anything, so an
%% unrelated module is never force-loaded just to be inspected.
-define(CARRIER_PREFIX, "erli18n_cc_").

%% Marker attribute a genuine carrier declares (`-erli18n_compiled_catalog(...)').
%% Its presence — not its value — is the confirmation, so the codegen may evolve
%% the attribute's payload without breaking discovery.
-define(CARRIER_MARKER, erli18n_compiled_catalog).

-doc """
Registers every compiled catalog carried by application `App` and returns the
per-catalog install result.

Resolves the carrier modules from `App`'s OWN `application:get_key(App, modules)`
list, confirms each carrier's marker, reads every `catalog/0`, and installs ALL
specs through `erli18n_server:register_compiled_many/1` in a SINGLE serialized
write — boot does NO `.po` parse and NO plural compile. Returns
`[{Domain, Locale, ensure_result()}]`: a freshly installed catalog reports
`{ok, NumEntries}`, one already present reports `{ok, already}` (idempotent).

Call this ONCE, in the consuming app's `start/2`, BEFORE its supervision tree
starts, so the catalogs are live before any worker can look one up.

```erlang
%% my_app_app.erl
start(_Type, _Args) ->
    _ = erli18n:register_compiled_catalogs(my_app),
    my_app_sup:start_link().
```

Failure modes:
- `error({erli18n_compiled_app_not_loaded, App})` if `App` is not loaded (wrong
  atom, or `register/1` ran before the app was loaded) — a loud crash, see
  `discover/1`.
- ONE `?LOG_WARNING` (`erli18n_compiled_no_carriers`) and `[]` if `App` is loaded
  but carries no compiled catalogs — never a silent no-op.

See `discover/1`, `read_catalog/1`, and `erli18n_server:register_compiled_many/1`.
""".
-spec register(atom()) ->
    [{erli18n_server:domain(), erli18n_server:locale(), erli18n_server:ensure_result()}].
register(App) when is_atom(App) ->
    case discover(App) of
        [] ->
            %% Build the report as a plain, always-evaluated assignment rather
            %% than inline inside the `?LOG_WARNING(#{...})` macro: the macro
            %% wraps its argument in a level-guarded expression, so hoisting the
            %% multi-line map keeps it a straightforward, unconditional value.
            Report = #{
                event => erli18n_compiled_no_carriers,
                app => App,
                hint =>
                    "no erli18n_cc_* compiled-catalog carrier modules were "
                    "discovered for this application; if you expected compiled "
                    "catalogs, check that the rebar3_erli18n build-time codegen "
                    "ran for this app and that register/1 is called with the "
                    "correct application atom"
            },
            ?LOG_WARNING(Report),
            [];
        [_ | _] = Carriers ->
            Specs = [read_catalog(Mod) || Mod <- Carriers],
            erli18n_server:register_compiled_many(Specs)
    end.

-doc """
Discovers the confirmed compiled-catalog carrier modules of application `App`.

Reads `App`'s OWN module list via `application:get_key(App, modules)`, keeps the
modules whose name is prefixed `erli18n_cc_`, and confirms each one is a genuine
carrier (`confirm_catalog/1`). Returns the confirmed carrier modules (possibly
`[]`).

Crashes with `error({erli18n_compiled_app_not_loaded, App})` when
`application:get_key/2` returns `undefined` — i.e. `App` is not loaded. That is a
programming/boot-ordering error (a wrong atom, or discovery running before the
app is loaded), so it fails fast rather than masking the misconfiguration as an
empty result.

See `register/1` and `confirm_catalog/1`.
""".
-spec discover(atom()) -> [module()].
discover(App) when is_atom(App) ->
    case application:get_key(App, modules) of
        undefined ->
            error({erli18n_compiled_app_not_loaded, App});
        {ok, Mods} ->
            [Mod || Mod <- Mods, has_carrier_prefix(Mod), confirm_catalog(Mod)]
    end.

-doc """
Confirms that `Mod` is a genuine compiled-catalog carrier.

Ensures `Mod` is loaded (`code:ensure_loaded/1`) and then checks that it declares
the `-erli18n_compiled_catalog(...)` marker attribute. Returns `true` only when
both hold; a module that cannot be loaded, or that shares the `erli18n_cc_`
prefix but lacks the marker, returns `false` (and is skipped, never registered).

See `discover/1`.
""".
-spec confirm_catalog(module()) -> boolean().
confirm_catalog(Mod) when is_atom(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} ->
            has_marker(Mod);
        {error, _} ->
            false
    end.

-doc """
Reads the compiled spec a confirmed carrier `Mod` carries.

Performs the single dynamic `Mod:catalog()` apply, returning the
`erli18n_server:compiled_spec()` — the ALREADY-parsed entries plus the
ALREADY-compiled `Plural-Forms` rule — that `register/1` hands to
`erli18n_server:register_compiled_many/1`. Call only on a module already
confirmed by `confirm_catalog/1`.

See `register/1` and `erli18n_server:compiled_spec()`.
""".
-spec read_catalog(module()) -> erli18n_server:compiled_spec().
read_catalog(Mod) ->
    Mod:catalog().

%% =========================
%% Internal helpers
%% =========================

%% True when the module name carries the generated-carrier prefix. Filtering on
%% the name BEFORE loading keeps discovery from force-loading unrelated modules.
-spec has_carrier_prefix(module()) -> boolean().
has_carrier_prefix(Mod) ->
    lists:prefix(?CARRIER_PREFIX, atom_to_list(Mod)).

%% True when the (already-loaded) module declares the carrier marker attribute.
%% Presence is the confirmation; the attribute's value is intentionally not
%% inspected so the codegen may evolve it.
-spec has_marker(module()) -> boolean().
has_marker(Mod) ->
    Attrs = Mod:module_info(attributes),
    lists:keymember(?CARRIER_MARKER, 1, Attrs).
