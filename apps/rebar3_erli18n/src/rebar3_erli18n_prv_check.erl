-module(rebar3_erli18n_prv_check).

-moduledoc """
`rebar3 erli18n check` — fail the build when the `.pot` templates are stale.

This is the `mix gettext --check-up-to-date` experience for Erlang: it
re-extracts the project and compares the result against the committed
`.pot` files. By DEFAULT it detects FULL drift — both the msgid set AND the
`#:` references — so a moved or renamed call site is caught, matching the
Elixir behaviour. The laxer `--names-only` mode compares only the msgid set
(stable against pure line-churn) for teams that find reference drift noisy.

Because extraction is literal-only, a legitimately dynamic (non-literal)
key is never extracted into the `.pot` in the first place, so it can never
produce a false drift failure in either mode — the dynamic-key guarantee.
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

-define(PROVIDER, check).
-define(NAMESPACE, erli18n).
-define(DEPS, [{default, compile}]).

-doc "Register the `check` provider under the `erli18n` namespace.".
-spec init(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()}.
init(State) ->
    Provider = rebar3_erli18n_host:create_provider([
        {name, ?PROVIDER},
        {namespace, ?NAMESPACE},
        {module, ?MODULE},
        {bare, true},
        {deps, ?DEPS},
        {example, "rebar3 erli18n check"},
        {opts, rebar3_erli18n_common:common_opts()},
        {short_desc, "Fail the build when committed .pot templates are out of date (CI gate)."},
        {desc,
            "Re-extract the project and compare against the committed .pot files. Defaults to "
            "full drift detection (msgids AND #: references), the mix gettext --check-up-to-date "
            "experience. Pass --names-only for the laxer msgid-set-only comparison. Legitimately "
            "dynamic keys are never extracted, so they never cause a false failure."}
    ]),
    {ok, rebar3_erli18n_host:add_provider(State, Provider)}.

-doc "Run the freshness check; error (non-zero exit) on drift.".
-spec do(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()} | {error, string()}.
do(State) ->
    case rebar3_erli18n_common:extract_project(State) of
        {ok, ByDomain} ->
            NamesOnly = names_only(State),
            case check_all(State, ByDomain, NamesOnly) of
                ok ->
                    rebar3_erli18n_host:info("erli18n: catalogs up to date", []),
                    {ok, State};
                {drift, Summary} ->
                    {error, format_error({drift, Summary})}
            end;
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

-doc "Render a provider error to a human string.".
-spec format_error(term()) -> string().
format_error(Reason) ->
    rebar3_erli18n_common:format_error(Reason).

%% =========================
%% Comparison
%% =========================

-spec names_only(rebar3_erli18n_host:state()) -> boolean().
names_only(State) ->
    Args = rebar3_erli18n_host:parsed_args(State),
    proplists:get_value(names_only, Args, false) =:= true.

%% Check every domain reachable from EITHER side: the freshly-extracted
%% domains AND the domains that already have a committed `.pot` on disk. The
%% union is what catches a domain whose call sites ALL vanished — fresh
%% extraction drops its key, but the stale `.pot` is still on disk, so it must
%% still be compared (and reported as drift, since the fresh side is now an
%% empty catalog). Comparing only `ByDomain` would silently skip it.
%%
%% Domains are keyed by their `.pot` NAME (the basename sans extension, a
%% string) rather than as atoms: the fresh side's atom keys are mapped to
%% their names with `atom_to_list/1` (no new atoms), and the disk side yields
%% names straight from the filenames. Nothing here ever calls `list_to_atom/1`
%% on a filesystem-derived basename, so an arbitrary set of stray `*.pot`
%% files cannot exhaust the atom table.
-spec check_all(rebar3_erli18n_host:state(), #{atom() => [Entry]}, boolean()) ->
    ok | {drift, binary()}
when
    Entry :: rebar3_erli18n_common:dedup_entry().
check_all(State, ByDomain, NamesOnly) ->
    PotDir = rebar3_erli18n_common:pot_dir(State),
    ByName = maps:fold(
        fun(Domain, Entries, Acc) -> Acc#{atom_to_list(Domain) => Entries} end,
        #{},
        ByDomain
    ),
    Names = all_domain_names(ByName, PotDir),
    Drifts = lists:foldl(
        fun(Name, Acc) ->
            %% A domain present on disk but absent from the fresh extraction
            %% defaults to an empty entry list, so its committed `.pot` is
            %% compared against an empty catalog and reports drift.
            Entries = maps:get(Name, ByName, []),
            case check_one(PotDir, Name, Entries, NamesOnly) of
                ok -> Acc;
                {drift, Msg} -> [Msg | Acc]
            end
        end,
        [],
        Names
    ),
    case Drifts of
        [] -> ok;
        _ -> {drift, iolist_to_binary(lists:join(~"\n", lists:reverse(Drifts)))}
    end.

%% The sorted union of the freshly-extracted domain NAMES and the names with a
%% committed `<Name>.pot` under `PotDir`. Sorting keeps the drift report
%% deterministic regardless of map/dir iteration order.
-spec all_domain_names(#{string() => [Entry]}, file:filename()) -> [string()] when
    Entry :: rebar3_erli18n_common:dedup_entry().
all_domain_names(ByName, PotDir) ->
    Fresh = maps:keys(ByName),
    OnDisk = committed_pot_names(PotDir),
    lists:usort(Fresh ++ OnDisk).

%% The names of the committed `<Name>.pot` templates directly under `PotDir`
%% (the `*.pot` basenames, sans extension, as strings). A missing directory
%% yields `[]`.
-spec committed_pot_names(file:filename()) -> [string()].
committed_pot_names(PotDir) ->
    %% `filelib:wildcard/2` yields the matching basenames as `[string()]`
    %% relative to PotDir; drop the trailing ".pot" with a string-preserving
    %% slice. (We avoid `filename:basename/2`, whose `file:name_all()` return
    %% type loses string-ness under eqwalizer.) A missing PotDir yields `[]`.
    [lists:sublist(N, length(N) - length(".pot")) || N <- filelib:wildcard("*.pot", PotDir)].

-spec check_one(file:filename(), string(), [Entry], boolean()) -> ok | {drift, binary()} when
    Entry :: rebar3_erli18n_common:dedup_entry().
check_one(PotDir, Name, Entries, NamesOnly) ->
    Path = filename:join(PotDir, Name ++ ".pot"),
    Fresh = rebar3_erli18n_po_meta:dump(rebar3_erli18n_common:entries_to_pot(Entries)),
    case file:read_file(Path) of
        {ok, Committed} ->
            compare(Name, Path, Committed, Fresh, NamesOnly);
        {error, enoent} ->
            {drift, drift_msg(Name, Path, "missing .pot (run `rebar3 erli18n extract`)")}
    end.

%% Full mode: byte-comparison of the metadata-aware dump (msgids + refs).
%% Names-only mode: compare just the sorted msgid set, ignoring references.
-spec compare(string(), file:filename(), binary(), binary(), boolean()) -> ok | {drift, binary()}.
compare(Name, Path, Committed, Fresh, false) ->
    case normalize(Committed) =:= normalize(Fresh) of
        true -> ok;
        false -> {drift, drift_msg(Name, Path, "out of date (msgid or reference changed)")}
    end;
compare(Name, Path, Committed, Fresh, true) ->
    case {msgid_set(Committed), msgid_set(Fresh)} of
        {{ok, Set}, {ok, Set}} ->
            ok;
        _ ->
            %% Either the sets differ or the committed file is unparseable —
            %% both are drift.
            {drift, drift_msg(Name, Path, "out of date (msgid set changed)")}
    end.

%% Normalize trailing whitespace so a committed file with/without a final
%% newline does not false-fail the byte compare.
-spec normalize(binary()) -> binary().
normalize(Bin) ->
    string:trim(Bin, trailing, "\n").

%% The set of {Context, Msgid} keys in a `.po`/`.pot`, ignoring everything
%% else (references, translations, header). Used by `--names-only`. An
%% unparseable input yields `parse_error`, which never equals an `{ok, _}`
%% set, so it is treated as drift by the caller.
-spec msgid_set(binary()) -> {ok, [{undefined | binary(), binary()}]} | parse_error.
msgid_set(Bin) ->
    case erli18n_po:parse(Bin) of
        {ok, #{entries := Entries}} ->
            {ok, lists:sort([key_of(E) || E <- Entries])};
        {error, _} ->
            parse_error
    end.

-spec key_of(erli18n_po:entry()) -> {undefined | binary(), binary()}.
key_of({singular, Ctx, Msgid, _}) -> {Ctx, Msgid};
key_of({plural, Ctx, Msgid, _, _}) -> {Ctx, Msgid}.

-spec drift_msg(string(), file:filename(), string()) -> binary().
drift_msg(Name, Path, Why) ->
    iolist_to_binary(
        io_lib:format("  ~ts (~ts): ~ts", [Name ++ ".pot", Path, Why])
    ).
