#!/usr/bin/env escript
%%! -noshell
%%
%% Reads the `{ex_doc, Opts}` block from a rebar.config and writes an ex_doc
%% `--config` file. rebar.config stays the single source of truth for the doc
%% options; this only translates them into the format the ex_doc escript wants
%% (binaries, lower-cased `main`, etc.), mirroring rebar3_ex_doc:to_ex_doc_format/1
%% for the subset of options this project uses.
%%
%% The `{ex_doc, ...}` block now lives in the per-app `apps/<app>/rebar.config`
%% (the published package owns its own doc config). Its `{extras, ...}` entries
%% name the app's own files (`README.md`, `CHANGELOG.md`, `LICENSE`) as bare,
%% app-relative paths so the same list also satisfies the Hex tarball's
%% ?DEFAULT_FILES globbing. Because `gen_docs.sh` runs `ex_doc` from the repo
%% root (not the app dir), an optional <extras-base> prefix is joined onto every
%% `extras` path so they resolve to the app's copies, not the repo-root docs.
%%
%% Usage: ex_doc_config.escript <rebar.config> <out.config> [<extras-base>]

main([RebarConfig, OutFile]) ->
    main([RebarConfig, OutFile, ""]);
main([RebarConfig, OutFile, ExtrasBase]) ->
    {ok, Terms} = file:consult(RebarConfig),
    Opts = proplists:get_value(ex_doc, Terms, []),
    Config = convert(Opts, ExtrasBase),
    Body = ["%% coding: utf-8\n" | [io_lib:format("~p.~n", [P]) || P <- Config]],
    ok = file:write_file(OutFile, Body);
main(_) ->
    io:format(
        standard_error,
        "usage: ex_doc_config.escript <rebar.config> <out.config> [<extras-base>]~n",
        []
    ),
    halt(2).

convert(Opts, ExtrasBase) ->
    lists:filtermap(
        fun
            ({extras, Extras}) ->
                {true, {extras, [to_bin(join_base(ExtrasBase, E)) || E <- Extras]}};
            ({main, Main}) ->
                {true, {main, to_bin(string:lowercase(filename:rootname(Main)))}};
            ({source_url, Url}) ->
                {true, {source_url, to_bin(Url)}};
            ({api_reference, Bool}) when is_boolean(Bool) ->
                {true, {api_reference, Bool}};
            %% `prefix_ref_vsn_with_v` is consumed by gen_docs.sh (source-ref),
            %% not an ex_doc config key — drop it here.
            ({prefix_ref_vsn_with_v, _}) ->
                false;
            (_Other) ->
                false
        end,
        Opts
    ).

%% Join an extras path onto the base dir. An empty base leaves the path
%% unchanged (back-compatible with a 2-arg invocation); absolute paths are
%% never re-rooted.
join_base("", Path) ->
    Path;
join_base(<<>>, Path) ->
    Path;
join_base(Base, Path) ->
    PathStr = unicode:characters_to_list(Path),
    case filename:pathtype(PathStr) of
        absolute -> PathStr;
        _ -> filename:join(Base, PathStr)
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) -> iolist_to_binary(L).
