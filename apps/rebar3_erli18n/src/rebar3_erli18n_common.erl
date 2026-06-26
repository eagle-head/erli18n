-module(rebar3_erli18n_common).

-moduledoc """
Shared plumbing for the `extract`/`merge`/`check`/`report` providers.

Centralizes the parts that would otherwise be duplicated across the four
providers: the common getopt option set, project source discovery + the
abstract-form walk, deduplication of extracted call sites into catalog
entries (merging `#:` references), `.pot`/`.po` directory resolution, and a
uniform `format_error/1`. Keeping this in one module makes the providers
thin wrappers and lets a single suite cover the walk/dedup logic to 100%.

## Catalog layout

The `.pot` templates live in `priv/gettext/<Domain>.pot`; the translated
catalogs in `priv/gettext/<Locale>/LC_MESSAGES/<Domain>.po`. This mirrors
the runtime loader's default path (`erli18n:default_po_path/3`) so a
project's extracted templates and loaded catalogs share one tree.
""".

-export([
    common_opts/0,
    pot_dir/1,
    po_path/3,
    extract_project/1,
    entries_to_pot/1,
    dedup_entries/1,
    runtime_lib_path/0,
    format_lib_path/1,
    maybe_log_runtime_lib_path/0,
    format_error/1
]).

-export_type([dedup_entry/0]).

-doc """
A deduplicated catalog entry: one logical `{Domain, Context, Msgid}` with
all the `#:` references that pointed at it (in first-seen source order).
`kind`/`plural` come from the first occurrence.
""".
-type dedup_entry() :: #{
    domain := atom(),
    kind := rebar3_erli18n_keywords:kind(),
    context := undefined | binary(),
    msgid := binary(),
    plural := undefined | binary(),
    references := [reference_ref()]
}.

-doc "A `#:` source reference: a relative source path and a 1-based line.".
-type reference_ref() :: {file:filename(), pos_integer()}.

-doc """
The getopt option spec shared by the providers.

`--domain` restricts the operation to a single domain; `--locale` selects a
target locale (merge/report); `--names-only` switches `check` to the laxer
msgid-set comparison; `--pot-dir` overrides the default `priv/gettext` root.
""".
-spec common_opts() ->
    [{atom(), char() | undefined, string(), atom() | tuple(), string()}].
common_opts() ->
    [
        {domain, $d, "domain", string, "Restrict to a single gettext domain (default: all)."},
        {locale, $l, "locale", string, "Target locale (merge/report)."},
        {names_only, undefined, "names-only", boolean,
            "check: compare only the msgid set, ignoring #: reference drift."},
        {pot_dir, undefined, "pot-dir", string,
            "Catalog root directory (default: <app>/priv/gettext)."}
    ].

%% =========================
%% Path resolution
%% =========================

-doc """
The `.pot` template directory: `<RootApp>/priv/gettext` (or the
`--pot-dir` override). The first project app is treated as the root.
""".
-spec pot_dir(rebar3_erli18n_host:state()) -> file:filename().
pot_dir(State) ->
    Args = rebar3_erli18n_host:parsed_args(State),
    case proplists:get_value(pot_dir, Args) of
        undefined -> default_pot_dir(State);
        Dir -> Dir
    end.

-spec default_pot_dir(rebar3_erli18n_host:state()) -> file:filename().
default_pot_dir(State) ->
    AppDir = root_app_dir(State),
    filename:join([AppDir, "priv", "gettext"]).

-doc """
The `.po` path for `{Domain, Locale}`:
`<pot_dir>/<Locale>/LC_MESSAGES/<Domain>.po`.
""".
-spec po_path(rebar3_erli18n_host:state(), atom(), string()) -> file:filename().
po_path(State, Domain, Locale) ->
    filename:join([
        pot_dir(State), Locale, "LC_MESSAGES", atom_to_list(Domain) ++ ".po"
    ]).

-spec root_app_dir(rebar3_erli18n_host:state()) -> file:filename().
root_app_dir(State) ->
    case rebar3_erli18n_host:project_apps(State) of
        [App | _] -> rebar3_erli18n_host:app_dir(App);
        [] -> rebar3_erli18n_host:state_dir(State)
    end.

%% =========================
%% Project extraction
%% =========================

-doc """
Walk every project app's `src/` and extract all recognized call sites,
grouped and deduplicated by domain.

Returns `{ok, #{Domain => [dedup_entry()]}}`, or the first
`{error, Reason}` an `epp` parse raised. Each domain's entry list is sorted
by `{Context, Msgid}` for deterministic, diff-stable output.
""".
-spec extract_project(rebar3_erli18n_host:state()) ->
    {ok, #{atom() => [dedup_entry()]}} | {error, term()}.
extract_project(State) ->
    maybe_log_runtime_lib_path(),
    Apps = rebar3_erli18n_host:project_apps(State),
    IncludeDirs = include_dirs(Apps),
    Files = lists:flatmap(fun app_src_files/1, Apps),
    case extract_files(Files, IncludeDirs, []) of
        {ok, Raw} ->
            {ok, group_and_dedup(Raw)};
        {error, _} = Err ->
            Err
    end.

%% =========================
%% Cross-package load-path diagnostic
%% =========================

-doc """
The loaded location of the `erli18n_po` runtime module, as `code:which/1`
sees it at the moment of the call — `non_existing` if the module is not on
the code path, `preloaded`/`cover_compiled` for those special cases, or the
absolute `.beam` path otherwise.

This is the structural proof of the plugin -> lib load path. Every provider
reaches `erli18n_po:parse/1`, `erli18n_po:dump/1`, and
`erli18n_po:escape_string/1` across the published `{deps, [erli18n]}`
boundary. In a downstream consumer that surfaces the unpublished lib via
`_checkouts/erli18n`, this resolves under the consumer's
`_build/<profile>/checkouts/erli18n/ebin/erli18n_po.beam`, demonstrating
that the checkout (not a Hex fetch) backs the cross-package calls. See
`apps/rebar3_erli18n/README.md` ("Proven cross-package load path").
""".
-spec runtime_lib_path() -> non_existing | cover_compiled | preloaded | file:filename().
runtime_lib_path() ->
    code:which(erli18n_po).

-doc """
When the `ERLI18N_DIAG_LOADPATH` OS environment variable is set, log the
loaded `erli18n_po` path through the rebar3 logger at provider-run time, so
the cross-package load path can be captured from a real
`rebar3 erli18n {extract,merge,check,report}` run. A no-op (returns `ok`,
emits nothing) when the variable is unset, so it adds no output to ordinary
runs.
""".
-spec maybe_log_runtime_lib_path() -> ok.
maybe_log_runtime_lib_path() ->
    case os:getenv("ERLI18N_DIAG_LOADPATH") of
        false ->
            ok;
        _ ->
            rebar3_erli18n_host:info(
                "erli18n: runtime lib erli18n_po loaded from ~ts",
                [format_lib_path(runtime_lib_path())]
            )
    end.

-doc """
Render a `code:which/1` result as a printable string: the `.beam` path
verbatim when loaded, or the special atom (`non_existing`, `preloaded`,
`cover_compiled`) spelled out so the diagnostic line is unambiguous about
WHY the cross-package module is not a concrete path.
""".
-spec format_lib_path(non_existing | cover_compiled | preloaded | file:filename()) -> string().
format_lib_path(Path) when is_list(Path) -> Path;
format_lib_path(Atom) when is_atom(Atom) -> atom_to_list(Atom).

-spec extract_files([file:filename()], [file:filename()], [Acc]) ->
    {ok, [rebar3_erli18n_extract_forms:extracted()]} | {error, term()}
when
    Acc :: rebar3_erli18n_extract_forms:extracted().
extract_files([], _IncludeDirs, Acc) ->
    {ok, lists:reverse(Acc)};
extract_files([File | Rest], IncludeDirs, Acc) ->
    RelFile = rel_source(File),
    %% One epp pass per file (`scan_file/2` derives the domain AND the entries
    %% together), so there is a single error site — a file `epp` cannot open.
    case rebar3_erli18n_extract_forms:scan_file(File, IncludeDirs) of
        {ok, _Domain, Entries} ->
            Relocated = [reref(E, RelFile) || E <- Entries],
            extract_files(Rest, IncludeDirs, lists:reverse(Relocated, Acc));
        {error, Reason} ->
            {error, {parse_failed, File, Reason}}
    end.

%% Rewrite an extracted entry's reference to use the relative source path
%% (stable across machines / build dirs in `#:` lines).
-spec reref(rebar3_erli18n_extract_forms:extracted(), file:filename()) ->
    rebar3_erli18n_extract_forms:extracted().
reref(#{reference := {_AbsFile, Line}} = E, RelFile) ->
    E#{reference := {RelFile, Line}}.

%% Reduce a source path to a project-relative one for `#:` lines: keep
%% everything from the `src/` segment onward (every file the extractor sees
%% comes from `app_src_files/1`'s `<app>/src/**/*.erl` wildcard, so the path
%% always contains a `src` segment). Source paths from the wildcard are flat
%% strings, so the rejoined relative path is a string without any conversion.
-spec rel_source(file:filename()) -> file:filename().
rel_source(File) ->
    Kept = drop_until_src(filename:split(File)),
    filename:join(Kept).

%% Drop leading path segments up to (and keeping) the first `src`. The
%% extractor only ever passes `<app>/src/...` paths, so a `src` segment is
%% always present; a path without one is a contract violation that crashes
%% here explicitly rather than silently mis-keying a reference.
-spec drop_until_src([file:name_all()]) -> [file:name_all()].
drop_until_src(["src" | _] = Rest) -> Rest;
drop_until_src([_ | Rest]) -> drop_until_src(Rest).

-spec include_dirs([rebar3_erli18n_host:app_info()]) -> [file:filename()].
include_dirs(Apps) ->
    lists:flatmap(
        fun(App) ->
            Dir = rebar3_erli18n_host:app_dir(App),
            [filename:join(Dir, "include"), filename:join(Dir, "src"), Dir]
        end,
        Apps
    ).

-spec app_src_files(rebar3_erli18n_host:app_info()) -> [file:filename()].
app_src_files(App) ->
    SrcDir = filename:join(rebar3_erli18n_host:app_dir(App), "src"),
    filelib:wildcard(filename:join(SrcDir, "**/*.erl")).

%% =========================
%% Grouping and deduplication
%% =========================

-spec group_and_dedup([rebar3_erli18n_extract_forms:extracted()]) ->
    #{atom() => [dedup_entry()]}.
group_and_dedup(Raw) ->
    ByDomain = lists:foldl(
        fun(#{domain := Domain} = E, Acc) ->
            maps:update_with(Domain, fun(L) -> [E | L] end, [E], Acc)
        end,
        #{},
        Raw
    ),
    maps:map(fun(_Domain, Entries) -> dedup_entries(lists:reverse(Entries)) end, ByDomain).

-doc """
Collapse a domain's raw extracted entries into deduplicated catalog
entries, keyed by `{Context, Msgid}`, merging each duplicate's reference.

References are kept in first-seen order with duplicates removed; the entry
list is returned sorted by `{Context, Msgid}` for deterministic output.
""".
-spec dedup_entries([rebar3_erli18n_extract_forms:extracted()]) -> [dedup_entry()].
dedup_entries(Entries) ->
    Map = lists:foldl(fun dedup_one/2, #{}, Entries),
    Sorted = lists:sort(
        fun(#{context := C1, msgid := M1}, #{context := C2, msgid := M2}) ->
            {norm_ctx(C1), M1} =< {norm_ctx(C2), M2}
        end,
        maps:values(Map)
    ),
    [finalize_refs(E) || E <- Sorted].

-spec dedup_one(rebar3_erli18n_extract_forms:extracted(), Acc) -> Acc when
    Acc :: #{{undefined | binary(), binary()} => dedup_entry()}.
dedup_one(#{context := Ctx, msgid := Msgid, reference := Ref} = E, Acc) ->
    Key = {Ctx, Msgid},
    case maps:find(Key, Acc) of
        {ok, #{references := Refs} = Existing} ->
            Acc#{Key := Existing#{references := [Ref | Refs]}};
        error ->
            Acc#{
                Key => #{
                    domain => maps:get(domain, E),
                    kind => maps:get(kind, E),
                    context => Ctx,
                    msgid => Msgid,
                    plural => maps:get(plural, E),
                    references => [Ref]
                }
            }
    end.

%% References accumulate newest-first; reverse to source order and dedup.
-spec finalize_refs(dedup_entry()) -> dedup_entry().
finalize_refs(#{references := Refs} = E) ->
    Ordered = lists:reverse(Refs),
    E#{references := dedup_keep_order(Ordered, [], #{})}.

%% Keep the first occurrence of each reference, preserving order.
-spec dedup_keep_order([Ref], [Ref], #{Ref => true}) -> [Ref] when Ref :: reference_ref().
dedup_keep_order([], Acc, _Seen) ->
    lists:reverse(Acc);
dedup_keep_order([H | T], Acc, Seen) ->
    case maps:is_key(H, Seen) of
        true -> dedup_keep_order(T, Acc, Seen);
        false -> dedup_keep_order(T, [H | Acc], Seen#{H => true})
    end.

-spec norm_ctx(undefined | binary()) -> binary().
norm_ctx(undefined) -> <<>>;
norm_ctx(Ctx) -> Ctx.

%% =========================
%% .pot construction
%% =========================

-doc """
Build a `rebar3_erli18n_po_meta:catalog()` (`.pot` template) from a domain's
deduplicated entries: an empty header, every `msgstr` empty, references as
`#:` lines.
""".
-spec entries_to_pot([dedup_entry()]) -> rebar3_erli18n_po_meta:catalog().
entries_to_pot(Entries) ->
    #{
        header => pot_header(),
        entries => [to_meta_entry(E) || E <- Entries]
    }.

-spec pot_header() -> binary().
pot_header() ->
    <<
        "Project-Id-Version: \n"
        "MIME-Version: 1.0\n"
        "Content-Type: text/plain; charset=UTF-8\n"
        "Content-Transfer-Encoding: 8bit\n"
    >>.

-spec to_meta_entry(dedup_entry()) -> rebar3_erli18n_po_meta:meta_entry().
to_meta_entry(#{
    kind := singular, context := Ctx, msgid := Msgid, references := Refs
}) ->
    #{
        body => {singular, Ctx, Msgid, <<>>},
        references => Refs
    };
to_meta_entry(#{
    kind := plural, context := Ctx, msgid := Msgid, plural := Plural, references := Refs
}) ->
    #{
        body => {plural, Ctx, Msgid, Plural, [{0, <<>>}, {1, <<>>}]},
        references => Refs
    }.

%% =========================
%% Errors
%% =========================

-doc "Render a shared provider error to a human-readable string.".
-spec format_error(term()) -> string().
format_error({parse_failed, File, Reason}) ->
    lists:flatten(io_lib:format("erli18n: failed to parse ~ts: ~p", [File, Reason]));
format_error({drift, Summary}) ->
    lists:flatten(io_lib:format("erli18n: catalog drift detected~n~ts", [Summary]));
format_error({po_parse_failed, Path, Reason}) ->
    lists:flatten(io_lib:format("erli18n: failed to parse ~ts: ~p", [Path, Reason]));
format_error({write_failed, Path, Reason}) ->
    lists:flatten(io_lib:format("erli18n: cannot write ~ts: ~p", [Path, Reason]));
format_error(Reason) ->
    lists:flatten(io_lib:format("erli18n: ~p", [Reason])).
