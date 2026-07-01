-module(rebar3_erli18n_prv_extract).

-moduledoc """
`rebar3 erli18n extract` — walk the project's abstract forms and write one
`.pot` per domain.

For every `.erl` file in each project app's `src/` dir, the provider runs
`rebar3_erli18n_extract_forms:scan_file/2` (one epp pass + keyword spec),
groups the resulting entries by domain, deduplicates by `{Context, Msgid}`
(merging each duplicate's `#:` references in source order), and serializes
each domain to `priv/gettext/<Domain>.pot` via `rebar3_erli18n_po_meta`.

The `.pot` is the extraction template: every `msgstr` is empty,
references are emitted as `#:` lines, and the keys are the source strings
(source-string-as-key). Dynamic (non-literal) call sites produce no entry,
so the template never carries a key the code cannot actually request.
""".

%% This module implements the rebar3 `provider` contract (`init/1`, `do/1`,
%% `format_error/1`); it is registered via `providers:create([{module, ?MODULE}, ...])`
%% in `init/1`. The `-behaviour(provider)` attribute is intentionally omitted:
%% the `provider` behaviour ships inside the rebar3 escript (stripped of
%% debug_info and not on Hex), so neither dialyzer nor eqwalizer can load its
%% callback info standalone — the attribute would only yield false
%% "behaviour/callback not available" diagnostics for a contract the exports
%% already satisfy.

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, extract).
-define(NAMESPACE, erli18n).
-define(DEPS, [{default, compile}]).

-doc "Register the `extract` provider under the `erli18n` namespace.".
-spec init(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()}.
init(State) ->
    Provider = rebar3_erli18n_host:create_provider([
        {name, ?PROVIDER},
        {namespace, ?NAMESPACE},
        {module, ?MODULE},
        {bare, true},
        {deps, ?DEPS},
        {example, "rebar3 erli18n extract"},
        {opts, rebar3_erli18n_common:common_opts()},
        {short_desc, "Extract translatable strings from Erlang source into .pot templates."},
        {desc,
            "Walk the project's abstract forms (via epp, not text scanning) for erli18n "
            "facade-family call sites, pull compile-time-constant msgid/msgid_plural/msgctxt "
            "literals into one .pot per domain (source-string-as-key), and emit #: source "
            "references. Dynamic (non-literal) keys are skipped, never errored."}
    ]),
    {ok, rebar3_erli18n_host:add_provider(State, Provider)}.

-doc "Run extraction and write the `.pot` templates.".
-spec do(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()} | {error, string()}.
do(State) ->
    case rebar3_erli18n_common:extract_project(State) of
        {ok, ByDomain} ->
            case write_pots(State, ByDomain) of
                ok -> {ok, State};
                {error, Reason} -> {error, format_error(Reason)}
            end;
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

-doc "Render a provider error to a human string.".
-spec format_error(term()) -> string().
format_error(Reason) ->
    rebar3_erli18n_common:format_error(Reason).

%% =========================
%% Writing
%% =========================

-spec write_pots(
    rebar3_erli18n_host:state(), #{atom() => [rebar3_erli18n_common:dedup_entry()]}
) -> ok | {error, {write_failed, file:filename_all(), term()}}.
write_pots(State, ByDomain) ->
    PotDir = rebar3_erli18n_common:pot_dir(State),
    case filelib:ensure_path(PotDir) of
        ok ->
            write_each_pot(maps:to_list(ByDomain), PotDir);
        {error, Reason} ->
            {error, {write_failed, PotDir, Reason}}
    end.

%% Write each domain's `.pot`, short-circuiting to `{error, {write_failed, ...}}`
%% on the first filesystem failure so `do/1` surfaces a clean provider error
%% instead of a `badmatch` crash on the `file:write_file/2` return.
-spec write_each_pot(
    [{atom(), [rebar3_erli18n_common:dedup_entry()]}], file:filename_all()
) -> ok | {error, {write_failed, file:filename_all(), term()}}.
write_each_pot([], _PotDir) ->
    ok;
write_each_pot([{Domain, Entries} | Rest], PotDir) ->
    Catalog = rebar3_erli18n_common:entries_to_pot(Entries),
    Bytes = rebar3_erli18n_po_meta:dump(Catalog),
    Path = filename:join(PotDir, atom_to_list(Domain) ++ ".pot"),
    case file:write_file(Path, Bytes) of
        ok ->
            rebar3_erli18n_host:info("erli18n: wrote ~ts (~b entries)", [Path, length(Entries)]),
            write_each_pot(Rest, PotDir);
        {error, Reason} ->
            {error, {write_failed, Path, Reason}}
    end.
