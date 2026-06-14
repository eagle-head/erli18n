#!/usr/bin/env escript
%%! -noshell
%%
%% Reads the `{ex_doc, Opts}` block from a rebar.config and writes an ex_doc
%% `--config` file. rebar.config stays the single source of truth for the doc
%% options; this only translates them into the format the ex_doc escript wants
%% (binaries, lower-cased `main`, etc.), mirroring rebar3_ex_doc:to_ex_doc_format/1
%% for the subset of options this project uses.
%%
%% Usage: ex_doc_config.escript <rebar.config> <out.config>

main([RebarConfig, OutFile]) ->
    {ok, Terms} = file:consult(RebarConfig),
    Opts = proplists:get_value(ex_doc, Terms, []),
    Config = convert(Opts),
    Body = ["%% coding: utf-8\n" | [io_lib:format("~p.~n", [P]) || P <- Config]],
    ok = file:write_file(OutFile, Body);
main(_) ->
    io:format(standard_error, "usage: ex_doc_config.escript <rebar.config> <out.config>~n", []),
    halt(2).

convert(Opts) ->
    lists:filtermap(
        fun
            ({extras, Extras}) ->
                {true, {extras, [to_bin(E) || E <- Extras]}};
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

to_bin(B) when is_binary(B) -> B;
to_bin(L) -> iolist_to_binary(L).
