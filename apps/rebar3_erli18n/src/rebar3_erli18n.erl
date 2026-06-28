-module(rebar3_erli18n).

-moduledoc """
rebar3 plugin entry point for erli18n catalog tooling.

`init/1` is the single hook rebar3 calls when it loads the plugin. It chains
the four providers' own `init/1` functions, each of which registers its
provider under the `erli18n` namespace, so that after load the project has:

- `rebar3 erli18n extract` — walk abstract forms into `.pot` templates;
- `rebar3 erli18n merge`   — msgmerge-style `.po` sync;
- `rebar3 erli18n check`   — CI gate that fails on `.pot` drift;
- `rebar3 erli18n report`  — per-`(Domain, Locale)` completeness.

The plugin is a SEPARATE Hex package from the runtime `erli18n` library and
depends on it (`{deps,[{erli18n,"~> 0.6"}]}`, `{applications,[...,erli18n]}`),
pointing plugin -> lib — the same direction as `rebar3_gpb_plugin` -> `gpb`.
The providers reuse the published PO read/serialize API (`erli18n_po:parse/1`,
`erli18n_po:dump/1`, `erli18n_po:escape_string/1`) across that boundary.
Consumers opt in with `{plugins,[rebar3_erli18n]}` in their own
`rebar.config`. Compile-time `.po`->BEAM codegen is out of scope for this
plugin: lookups resolve catalogs at runtime, so no codegen provider is shipped.
""".

-export([init/1]).

-doc """
Register the four `erli18n`-namespace providers.

Threads `rebar_state:t()` through each provider's `init/1` in turn, so a
failure in any one short-circuits the chain.
""".
-spec init(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()}.
init(State0) ->
    Providers = [
        rebar3_erli18n_prv_extract,
        rebar3_erli18n_prv_merge,
        rebar3_erli18n_prv_check,
        rebar3_erli18n_prv_report
    ],
    lists:foldl(
        fun(Mod, {ok, StateAcc}) -> Mod:init(StateAcc) end,
        {ok, State0},
        Providers
    ).
