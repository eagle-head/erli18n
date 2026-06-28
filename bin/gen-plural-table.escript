#!/usr/bin/env escript
%% -*- erlang -*-
%%! -sname erli18n_gen_plural_table
%%
%% =====================================================================
%% gen-plural-table.escript — CLDR plural-table code generator.
%%
%% Reads the committed seed table
%%
%%     apps/erli18n/priv/gettext/plural_forms.eterm
%%
%% (a sorted list of `{Locale, NPlurals, PluralExpr}` rows) and regenerates
%% the runtime CLDR table inside
%%
%%     apps/erli18n/src/erli18n_plural.erl
%%
%% by replacing the `cldr_data/0` rows between the marker lines
%%
%%     %% BEGIN GENERATED CLDR TABLE
%%     ...
%%     %% END GENERATED CLDR TABLE
%%
%% The output is byte-for-byte deterministic, so running the generator
%% after editing only the seed leaves the rest of the module untouched and
%% keeps the build GREEN and behavior byte-identical (the rows are the same
%% `{Locale, NPlurals, Expr}` set; `erli18n_plural` consumes exactly this
%% generated list via `cldr_data/0`).
%%
%% Usage (run from the repository root or anywhere — paths are resolved
%% relative to this script's location):
%%
%%     escript bin/gen-plural-table.escript            # regenerate in place
%%     escript bin/gen-plural-table.escript --check    # verify, no write
%%
%% `--check` exits non-zero if the module is out of sync with the seed
%% (useful as a CI / pre-commit guard); the default mode rewrites the
%% module and reports whether anything changed.
%%
%% When the compiled `erli18n_plural` beam is reachable (the project has
%% been built with `rebar3 compile`), each seed expression is validated
%% through `erli18n_plural:compile/1` before code is emitted, so a seed row
%% that the runtime would reject is caught here instead of at load time.
%% All comments and content are en-US (repo standard).
%% =====================================================================

-mode(compile).

%% The full comment prefix is part of the marker so that prose references
%% to the "BEGIN/END GENERATED CLDR TABLE" markers (in doc strings and
%% comments) are NOT mistaken for the real markers.
-define(BEGIN_MARKER, "%% BEGIN GENERATED CLDR TABLE").
-define(END_MARKER, "%% END GENERATED CLDR TABLE").

%% Source line-length budget. Mirrors the `elvis` `line_length` limit (100)
%% for `apps/*/src`, so the emitted rows never trip the linter.
-define(MAX_LINE, 100).

%% Maximum bytes of a plural expression per wrapped string-literal line:
%% 12-space indent + the two surrounding quotes leaves 86 columns.
-define(CHUNK_MAX, 86).

main(Args) ->
    Check = lists:member("--check", Args),
    Root = repo_root(),
    SeedPath = filename:join([Root, "apps", "erli18n", "priv", "gettext", "plural_forms.eterm"]),
    TargetPath = filename:join([Root, "apps", "erli18n", "src", "erli18n_plural.erl"]),
    Rows = load_seed(SeedPath),
    Sorted = sort_rows(Rows),
    ok = validate_rows(Sorted, Root),
    Source = read_file(TargetPath),
    NewSource = splice(Source, render_block(Sorted), TargetPath),
    case Check of
        true ->
            case NewSource =:= Source of
                true ->
                    io:format("OK: ~ts is in sync with ~ts~n", [rel(TargetPath, Root), rel(SeedPath, Root)]),
                    halt(0);
                false ->
                    io:format(standard_error,
                              "DRIFT: ~ts is out of sync with the seed table.~n"
                              "Run: escript bin/gen-plural-table.escript~n",
                              [rel(TargetPath, Root)]),
                    halt(1)
            end;
        false ->
            case NewSource =:= Source of
                true ->
                    io:format("OK: ~ts already up to date (~p locales).~n",
                              [rel(TargetPath, Root), length(Sorted)]);
                false ->
                    ok = write_file(TargetPath, NewSource),
                    io:format("WROTE: regenerated CLDR table in ~ts (~p locales).~n",
                              [rel(TargetPath, Root), length(Sorted)])
            end,
            halt(0)
    end.

%% ---------------------------------------------------------------------
%% Path resolution
%% ---------------------------------------------------------------------

%% Resolve the repository root from this script's own location
%% (`<root>/bin/gen-plural-table.escript`), so the generator works
%% regardless of the caller's current working directory.
repo_root() ->
    Script = escript:script_name(),
    Abs = filename:absname(Script),
    BinDir = filename:dirname(Abs),
    filename:dirname(BinDir).

rel(Path, Root) ->
    case lists:prefix(Root ++ "/", Path) of
        true -> lists:nthtail(length(Root) + 1, Path);
        false -> Path
    end.

%% ---------------------------------------------------------------------
%% Seed loading and validation
%% ---------------------------------------------------------------------

load_seed(SeedPath) ->
    case file:consult(SeedPath) of
        {ok, [Rows]} when is_list(Rows) ->
            Rows;
        {ok, Terms} ->
            %% Tolerate a file written as one term per row as well as the
            %% canonical single-list form.
            lists:flatten(Terms);
        {error, Reason} ->
            abort("cannot read seed table ~ts: ~p", [SeedPath, Reason])
    end.

%% Sort by locale (byte order) and reject duplicate locales — the runtime
%% lookup is first-match, so a duplicate would silently shadow a row.
sort_rows(Rows) ->
    lists:foreach(fun check_shape/1, Rows),
    Sorted = lists:keysort(1, Rows),
    Locales = [L || {L, _, _} <- Sorted],
    case Locales -- lists:usort(Locales) of
        [] -> Sorted;
        Dups -> abort("duplicate locale(s) in seed table: ~p", [lists:usort(Dups)])
    end.

check_shape({Locale, N, Expr})
  when is_binary(Locale), is_integer(N), N >= 1, is_binary(Expr) ->
    %% The emitter wraps Locale/Expr in `<<"...">>`; a double quote in
    %% either would break the generated literal, so reject it up front.
    case has_quote(Locale) orelse has_quote(Expr) of
        true -> abort("locale/expression must not contain a double quote: ~p", [{Locale, Expr}]);
        false -> ok
    end;
check_shape(Other) ->
    abort("malformed seed row (expected {<<Locale>>, N, <<Expr>>}): ~p", [Other]).

has_quote(Bin) -> binary:match(Bin, <<"\"">>) =/= nomatch.

%% Validate each plural expression through the real compiler when the
%% `erli18n_plural` beam is reachable; otherwise emit a notice and rely on
%% the runtime/test guards. This catches a bad seed row at generation time.
validate_rows(Rows, Root) ->
    case ensure_plural_module(Root) of
        ok ->
            lists:foreach(
                fun({Locale, N, Expr}) ->
                    Header = <<"nplurals=", (integer_to_binary(N))/binary, "; plural=", Expr/binary, ";">>,
                    case erli18n_plural:compile(Header) of
                        {ok, _} -> ok;
                        {error, Why} ->
                            abort("seed row for ~ts does not compile (~p): ~ts",
                                  [Locale, Why, Header])
                    end
                end,
                Rows),
            ok;
        unavailable ->
            io:format(standard_error,
                      "NOTE: erli18n_plural beam not found; skipping compile "
                      "validation. Build first with `rebar3 compile` for full "
                      "checks.~n", []),
            ok
    end.

ensure_plural_module(Root) ->
    case code:ensure_loaded(erli18n_plural) of
        {module, erli18n_plural} ->
            ok;
        _ ->
            EbinGlob = filename:join([Root, "_build", "default", "lib", "*", "ebin"]),
            lists:foreach(fun(D) -> code:add_pathz(D) end, filelib:wildcard(EbinGlob)),
            case code:ensure_loaded(erli18n_plural) of
                {module, erli18n_plural} -> ok;
                _ -> unavailable
            end
    end.

%% ---------------------------------------------------------------------
%% Rendering
%% ---------------------------------------------------------------------

%% Render the generated region (between the marker lines): an explanatory
%% header and the `cldr_data/0` list literal, terminated with `].` so the
%% surrounding `cldr_data() ->` clause closes correctly.
render_block(Rows) ->
    Header =
        ["    %% Generated by bin/gen-plural-table.escript from\n",
         "    %% apps/erli18n/priv/gettext/plural_forms.eterm. Do not edit by hand;\n",
         "    %% edit the seed table and re-run the generator.\n",
         "    [\n"],
    RowLines = render_rows(Rows),
    lists:flatten([Header, RowLines, "    ].\n"]).

render_rows([]) ->
    [];
render_rows([Last]) ->
    [render_row(Last, "")];
render_rows([Row | Rest]) ->
    [render_row(Row, ",") | render_rows(Rest)].

%% Render a single row. The common case is one line; a row whose single
%% line would exceed the 100-column source limit (the long Slavic/Arabic
%% rules) is wrapped into a multi-line `<< "..." >>` binary whose adjacent
%% string literals concatenate to exactly the same bytes.
render_row({Locale, N, Expr}, Sep) ->
    L = binary_to_list(Locale),
    E = binary_to_list(Expr),
    Single = "        {<<\"" ++ L ++ "\">>, " ++ integer_to_list(N) ++
        ", <<\"" ++ E ++ "\">>}" ++ Sep,
    case length(Single) =< ?MAX_LINE of
        true ->
            Single ++ "\n";
        false ->
            Open = "        {<<\"" ++ L ++ "\">>, " ++ integer_to_list(N) ++ ", <<\n",
            ChunkLines = [["            \"", C, "\"\n"] || C <- chunk(E, ?CHUNK_MAX)],
            Close = "        >>}" ++ Sep ++ "\n",
            lists:flatten([Open, ChunkLines, Close])
    end.

%% Split a string into <= Max-byte chunks (used only for the wrapped rows).
chunk([], _Max) ->
    [];
chunk(Str, Max) when length(Str) =< Max ->
    [Str];
chunk(Str, Max) ->
    {Head, Tail} = lists:split(Max, Str),
    [Head | chunk(Tail, Max)].

%% ---------------------------------------------------------------------
%% Splicing
%% ---------------------------------------------------------------------

%% Replace everything strictly between the BEGIN and END marker lines with
%% the freshly rendered block, preserving the marker lines themselves.
splice(Source, Block, TargetPath) ->
    Lines = split_lines(Source),
    BeginIdx = find_marker(Lines, ?BEGIN_MARKER, TargetPath),
    EndIdx = find_marker(Lines, ?END_MARKER, TargetPath),
    case EndIdx > BeginIdx of
        true -> ok;
        false -> abort("~ts: END marker must follow BEGIN marker", [TargetPath])
    end,
    Before = lists:sublist(Lines, BeginIdx),
    After = lists:nthtail(EndIdx - 1, Lines),
    unicode:characters_to_binary([Before, Block, After]).

find_marker(Lines, Marker, TargetPath) ->
    find_marker(Lines, Marker, 1, TargetPath).

find_marker([], Marker, _N, TargetPath) ->
    abort("~ts: marker not found: ~ts", [TargetPath, Marker]);
find_marker([Line | Rest], Marker, N, TargetPath) ->
    case string:find(Line, Marker) of
        nomatch -> find_marker(Rest, Marker, N + 1, TargetPath);
        _ -> N
    end.

%% Split keeping the trailing "\n" on each line so the join is lossless.
split_lines(Bin) ->
    Parts = binary:split(Bin, <<"\n">>, [global]),
    add_newlines(Parts).

add_newlines([Last]) ->
    [Last];
add_newlines([Part | Rest]) ->
    [<<Part/binary, "\n">> | add_newlines(Rest)].

%% ---------------------------------------------------------------------
%% IO helpers
%% ---------------------------------------------------------------------

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> abort("cannot read ~ts: ~p", [Path, Reason])
    end.

write_file(Path, Data) ->
    case file:write_file(Path, Data) of
        ok -> ok;
        {error, Reason} -> abort("cannot write ~ts: ~p", [Path, Reason])
    end.

abort(Fmt, Args) ->
    io:format(standard_error, "ERROR: " ++ Fmt ++ "~n", Args),
    halt(2).
