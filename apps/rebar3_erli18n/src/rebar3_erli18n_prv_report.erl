-module(rebar3_erli18n_prv_report).

-moduledoc """
`rebar3 erli18n report` — per-`(Domain, Locale)` translation-completeness
report.

For each domain (and each locale found under the catalog root, or the one
named by `--locale`), it parses the `.po`, counts how many entries are
translated vs untranslated, and prints a deterministic table. An entry is
"translated" when its `msgstr` (singular) or every plural form is non-empty;
`#, fuzzy` entries are reported separately because `erli18n_po:parse` drops
them by default — so the count reflects what the RUNTIME would actually
serve.

The output format is fixed and exact:

```
erli18n translation report
==========================

domain: default
  pt_BR   12/15 translated  (3 missing)
  es      15/15 translated  (0 missing)
```
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

-define(PROVIDER, report).
-define(NAMESPACE, erli18n).
-define(DEPS, []).

-doc "Register the `report` provider under the `erli18n` namespace.".
-spec init(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()}.
init(State) ->
    Provider = rebar3_erli18n_host:create_provider([
        {name, ?PROVIDER},
        {namespace, ?NAMESPACE},
        {module, ?MODULE},
        {bare, true},
        {deps, ?DEPS},
        {example, "rebar3 erli18n report"},
        {opts, rebar3_erli18n_common:common_opts()},
        {short_desc, "Report translation completeness per (Domain, Locale)."},
        {desc,
            "For each domain and locale, parse the .po and report how many entries are "
            "translated vs missing. Counts reflect what the runtime serves (fuzzy entries are "
            "dropped on load)."}
    ]),
    {ok, rebar3_erli18n_host:add_provider(State, Provider)}.

-doc "Build and print the completeness report.".
-spec do(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()} | {error, string()}.
do(State) ->
    PotDir = rebar3_erli18n_common:pot_dir(State),
    Domains = domains(State, PotDir),
    case build_report(PotDir, Domains, locale_filter(State)) of
        {ok, Text} ->
            rebar3_erli18n_host:console("~ts", [Text]),
            {ok, State};
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

-doc "Render a provider error to a human string.".
-spec format_error(term()) -> string().
format_error(Reason) ->
    rebar3_erli18n_common:format_error(Reason).

%% =========================
%% Report construction (pure)
%% =========================

-spec locale_filter(rebar3_erli18n_host:state()) -> all | string().
locale_filter(State) ->
    Args = rebar3_erli18n_host:parsed_args(State),
    case proplists:get_value(locale, Args) of
        undefined -> all;
        Locale -> Locale
    end.

%% Domains to report (as NAME STRINGS, never atoms — report only displays
%% and path-builds them, so converting to a runtime atom would needlessly
%% risk atom-table growth on attacker-controlled `.pot` filenames):
%% `--domain` if given, else every `*.pot` under the root.
-spec domains(rebar3_erli18n_host:state(), file:filename()) -> [string()].
domains(State, PotDir) ->
    Args = rebar3_erli18n_host:parsed_args(State),
    case proplists:get_value(domain, Args) of
        undefined -> discover_domains(PotDir);
        D -> [D]
    end.

%% `filelib:wildcard/1` yields string paths, and `filename:basename/2` of a
%% string is a string, so the domain NAMES are plain strings. The `is_list`
%% assertion narrows `file:filename_all()` to `string()` for the typed
%% return; a binary basename cannot arise from a string wildcard path and
%% would crash explicitly rather than be silently kept.
-spec discover_domains(file:filename()) -> [string()].
discover_domains(PotDir) ->
    Pots = filelib:wildcard(filename:join(PotDir, "*.pot")),
    lists:sort([basename_string(P) || P <- Pots]).

-spec basename_string(string()) -> string().
basename_string(Path) ->
    Name = filename:basename(Path, ".pot"),
    true = is_list(Name),
    Name.

-doc false.
-spec build_report(file:filename(), [string()], all | string()) ->
    {ok, binary()} | {error, term()}.
build_report(PotDir, Domains, LocaleFilter) ->
    DomainBlocks = [domain_block(PotDir, D, LocaleFilter) || D <- Domains],
    case collect(DomainBlocks, []) of
        {ok, Blocks} ->
            Body = lists:join(~"\n", Blocks),
            {ok, iolist_to_binary([header(), Body, ~"\n"])};
        {error, _} = Err ->
            Err
    end.

-spec collect([{ok, binary()} | {error, term()}], [binary()]) ->
    {ok, [binary()]} | {error, term()}.
collect([], Acc) -> {ok, lists:reverse(Acc)};
collect([{ok, B} | Rest], Acc) -> collect(Rest, [B | Acc]);
collect([{error, _} = Err | _], _Acc) -> Err.

-spec header() -> binary().
header() ->
    ~"erli18n translation report\n==========================\n\n".

-spec domain_block(file:filename(), string(), all | string()) ->
    {ok, binary()} | {error, term()}.
domain_block(PotDir, Domain, LocaleFilter) ->
    Locales = locales_for(PotDir, LocaleFilter),
    case locale_lines(PotDir, Domain, Locales, []) of
        {ok, Lines} ->
            Head = iolist_to_binary([~"domain: ", str_to_binary(Domain), ~"\n"]),
            {ok, iolist_to_binary([Head, Lines])};
        {error, _} = Err ->
            Err
    end.

%% Narrow `unicode:characters_to_binary/1` of a domain NAME string to a
%% binary for display. Domain names are valid char data, so it never fails.
-spec str_to_binary(string()) -> binary().
str_to_binary(Str) ->
    %% Domain names are valid UTF-8 char data, so the conversion always
    %% yields a binary; the `is_binary` assertion narrows the result and a
    %% non-binary (impossible here) crashes explicitly.
    Bin = unicode:characters_to_binary(Str),
    true = is_binary(Bin),
    Bin.

-spec locales_for(file:filename(), all | string()) -> [string()].
locales_for(_PotDir, Locale) when is_list(Locale) ->
    [Locale];
locales_for(PotDir, all) ->
    Dirs = filelib:wildcard(filename:join(PotDir, "*")),
    Locales = [
        filename:basename(D)
     || D <- Dirs, filelib:is_dir(filename:join(D, "LC_MESSAGES"))
    ],
    lists:sort(Locales).

-spec locale_lines(file:filename(), string(), [string()], [binary()]) ->
    {ok, binary()} | {error, term()}.
locale_lines(_PotDir, _Domain, [], Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
locale_lines(PotDir, Domain, [Locale | Rest], Acc) ->
    Path = filename:join([PotDir, Locale, "LC_MESSAGES", Domain ++ ".po"]),
    case count_translated(Path) of
        {ok, Total, Translated} ->
            Line = format_line(Locale, Total, Translated),
            locale_lines(PotDir, Domain, Rest, [Line | Acc]);
        {error, enoent} ->
            Line = format_missing(Locale),
            locale_lines(PotDir, Domain, Rest, [Line | Acc]);
        {error, Reason} ->
            {error, {po_parse_failed, Path, Reason}}
    end.

%% Count total vs translated entries in a `.po`. An entry is translated when
%% its singular `msgstr` is non-empty, or (plural) every form is non-empty.
-spec count_translated(file:filename()) ->
    {ok, non_neg_integer(), non_neg_integer()} | {error, term()}.
count_translated(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case erli18n_po:parse(Bin) of
                {ok, #{entries := Entries}} ->
                    Total = length(Entries),
                    Translated = length([E || E <- Entries, is_translated(E)]),
                    {ok, Total, Translated};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec is_translated(erli18n_po:entry()) -> boolean().
is_translated({singular, _Ctx, _Msgid, Tr}) ->
    Tr =/= <<>>;
is_translated({plural, _Ctx, _Msgid, _Plural, Forms}) ->
    Forms =/= [] andalso lists:all(fun({_Idx, Tr}) -> Tr =/= <<>> end, Forms).

%% A right-padded locale column keeps the table aligned for the common case.
-spec format_line(string(), non_neg_integer(), non_neg_integer()) -> binary().
format_line(Locale, Total, Translated) ->
    Missing = Total - Translated,
    iolist_to_binary(
        io_lib:format(
            "  ~-8s ~b/~b translated  (~b missing)~n",
            [Locale, Translated, Total, Missing]
        )
    ).

-spec format_missing(string()) -> binary().
format_missing(Locale) ->
    iolist_to_binary(io_lib:format("  ~-8s (no catalog)~n", [Locale])).
