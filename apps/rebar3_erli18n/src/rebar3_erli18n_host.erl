-module(rebar3_erli18n_host).

-moduledoc """
Single seam over the rebar3 HOST API.

Every call into rebar3's own modules (`providers`, `rebar_state`,
`rebar_api`, `rebar_app_info`) is funneled through this one module. Those
modules are supplied by the rebar3 escript at plugin-load time; they are NOT
a fetchable dependency (rebar3's built-in dep resources are git/hg/pkg only,
and there is no `rebar` package carrying them), so the static analysis tools
cannot load their definitions standalone.

Concentrating the host coupling here means every "this lives in the rebar3
host" annotation sits in this ONE module, and the providers plus the pure
logic modules call `rebar3_erli18n_host:*` (which IS defined) so they stay
free of host-API references and analyze cleanly with no per-site annotation.
The three analysis tools are satisfied as follows, all scoped to this seam:

- elp eqwalizer: a `% elp:ignore W0017` on each host call site below;
- dialyzer: a single function-scoped `-dialyzer({no_unknown, [...]})`;
- xref: a scoped `-ignore_xref([...])` (below) listing both this seam's own
  exported wrappers and the ten external rebar3 host `{M,F,A}` edges, so
  `undefined_function_calls`/`undefined_functions` stay active everywhere
  else. The companion `{xref_ignores,...}` in this app's `rebar.config`
  carries the same ten edges with the rejected-alternatives rationale. This
  is used instead of a `tools/rebar3_api/ebin` host-beam extraction.

The seam is also a genuine architectural win: it gives the providers a thin,
mockable boundary instead of reaching into rebar3 internals directly.
""".

-export([
    create_provider/1,
    add_provider/2,
    parsed_args/1,
    project_apps/1,
    state_dir/1,
    app_dir/1,
    info/2,
    console/2,
    warn/2,
    get_config/3
]).

%% Xref host-API resolution, scoped to this seam.
%%
%% `apps/*` is rebar3's default discovery root, so the umbrella's `rebar3 xref`
%% scans this plugin. Two kinds of edge must be ignored, both confined here:
%%
%%   * the ten external rebar3 host `{M,F,A}` edges — `providers:create/1`,
%%     `rebar_state:add_provider/2`, `rebar_state:command_parsed_args/1`,
%%     `rebar_state:project_apps/1`, `rebar_state:dir/1`,
%%     `rebar_state:get/3`, `rebar_app_info:dir/1`, `rebar_api:info/2`,
%%     `rebar_api:console/2`, `rebar_api:warn/2` — which live inside the
%%     rebar3 escript (not a fetchable Hex dep), so xref reports each as an
%%     undefined function;
%%   * this seam's own exported wrappers — they have no in-tree caller other
%%     than the providers, and xref's `locals_not_used`/export tracking would
%%     otherwise flag them while the plugin app is analyzed standalone.
%%
%% We ignore EXACTLY these edges and nothing else, so
%% `undefined_function_calls`/`undefined_functions` stay active for genuine
%% bugs in every other module (including this seam's own logic). The companion
%% `{xref_ignores,...}` in this app's `rebar.config` carries the same ten
%% external edges with the rejected-alternatives rationale. Together they
%% stand in for a `tools/rebar3_api/ebin` host-beam extraction path; the
%% ignore is load-bearing (removing it makes exactly these eight host calls
%% reappear as undefined) and not over-broad.
-ignore_xref([
    create_provider/1,
    add_provider/2,
    parsed_args/1,
    project_apps/1,
    state_dir/1,
    app_dir/1,
    info/2,
    console/2,
    warn/2,
    get_config/3,
    {providers, create, 1},
    {rebar_state, add_provider, 2},
    {rebar_state, command_parsed_args, 1},
    {rebar_state, project_apps, 1},
    {rebar_state, dir, 1},
    {rebar_state, get, 3},
    {rebar_app_info, dir, 1},
    {rebar_api, info, 2},
    {rebar_api, console, 2},
    {rebar_api, warn, 2}
]).

%% This module is the SOLE seam over the rebar3 host API. Those modules
%% (`providers`, `rebar_state`, `rebar_api`, `rebar_app_info`) live inside
%% the rebar3 escript — stripped of debug_info and not published to Hex — so
%% dialyzer cannot load their success typings and reports every call as an
%% `unknown` function. The calls ARE valid at plugin-load time (rebar3
%% provides them); suppressing `no_unknown` HERE — and only here, where the
%% coupling is deliberately concentrated — keeps the rest of the project
%% under the full `unknown` warning. The same posture as the `elp:ignore`
%% on these call sites for eqwalizer.
%%
%% elp's W0048 ("avoid the -dialyzer attribute") is a style preference; the
%% attribute is the documented, function-scoped way to express exactly this
%% host-API suppression, so the W0048 is ignored on this one line.
% elp:ignore W0048
-dialyzer(
    {no_unknown, [
        create_provider/1,
        add_provider/2,
        parsed_args/1,
        project_apps/1,
        state_dir/1,
        app_dir/1,
        info/2,
        console/2,
        warn/2,
        get_config/3
    ]}
).

-export_type([state/0, app_info/0, provider/0]).

-doc "Opaque rebar3 state handle (`rebar_state:t/0`).".
-type state() :: term().
-doc "Opaque rebar3 app-info handle (`rebar_app_info:t/0`).".
-type app_info() :: term().
-doc "Opaque rebar3 provider handle (`providers:t/0`).".
-type provider() :: term().

-doc "Create a rebar3 provider record from a property list.".
-spec create_provider([{atom(), term()}]) -> provider().
create_provider(Props) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    providers:create(Props).

-doc "Register a provider into the rebar3 state.".
-spec add_provider(state(), provider()) -> state().
add_provider(State, Provider) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    rebar_state:add_provider(State, Provider).

-doc "The parsed getopt args for the running command (the proplist half).".
-spec parsed_args(state()) -> [{atom(), term()}].
parsed_args(State) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    {Args, _Rest} = rebar_state:command_parsed_args(State),
    Args.

-doc "The project's top-level apps.".
-spec project_apps(state()) -> [app_info()].
project_apps(State) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    rebar_state:project_apps(State).

-doc "The base directory of the rebar3 state.".
-spec state_dir(state()) -> file:filename().
state_dir(State) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    rebar_state:dir(State).

-doc "The on-disk directory of an app.".
-spec app_dir(app_info()) -> file:filename().
app_dir(App) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    rebar_app_info:dir(App).

-doc "Emit an INFO-level message through the rebar3 logger.".
-spec info(io:format(), [term()]) -> ok.
info(Format, Args) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    rebar_api:info(Format, Args).

-doc "Print a message to the console through rebar3.".
-spec console(io:format(), [term()]) -> ok.
console(Format, Args) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    rebar_api:console(Format, Args).

-doc "Emit a WARN-level message through the rebar3 logger.".
-spec warn(io:format(), [term()]) -> ok.
warn(Format, Args) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    rebar_api:warn(Format, Args).

-doc """
Read a `rebar.config` key from the rebar3 state, falling back to `Default`
when the key is absent. This is the `rebar.config` reader the providers use
for plugin configuration.
""".
-spec get_config(state(), atom(), term()) -> term().
get_config(State, Key, Default) ->
    % elp:ignore W0017 (provided by the rebar3 host at plugin-load time)
    rebar_state:get(State, Key, Default).
