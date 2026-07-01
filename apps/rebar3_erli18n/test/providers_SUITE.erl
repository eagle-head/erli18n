-module(providers_SUITE).

-moduledoc """
In-node tests for the five providers, `rebar3_erli18n_common`, and
`rebar3_erli18n_host`.

rebar3 runs Common Test in a node where its own modules (`rebar_state`,
`rebar_app_info`, `providers`) are on the code path, so the suite builds a
REAL `rebar_state` with a throwaway project app and calls each provider's
`init/1`/`do/1` directly. This exercises the rebar3 glue against a genuine
state (so it is cover-counted) without shelling out.

Each case scaffolds a temp app whose `src/` calls the erli18n facade, then
runs extract/merge/check/report through the provider functions and asserts
the catalog files and the drift/obsolete/fuzzy/report behaviour.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2]).
-export([
    init_registers_providers/1,
    extract_writes_pot/1,
    extract_dedups_references/1,
    check_passes_when_fresh/1,
    check_fails_on_drift/1,
    check_fails_on_missing_pot/1,
    check_names_only_ignores_line_churn/1,
    check_fails_when_domain_call_sites_vanish/1,
    merge_creates_and_preserves/1,
    merge_obsoletes_removed/1,
    merge_fuzzy_renamed/1,
    merge_requires_locale/1,
    merge_plural_carryover/1,
    merge_fuzzy_plural/1,
    merge_shape_change_drops_translation/1,
    merge_old_po_parse_error/1,
    merge_invalid_utf8_po_fails_soft/1,
    report_invalid_utf8_po_fails_soft/1,
    check_invalid_utf8_pot_reports_drift/1,
    merge_wrapped_msgid_carries_over/1,
    merge_large_old_po_obsoletes_rest/1,
    merge_take_by_msgid_not_first/1,
    merge_fuzzy_cross_shape/1,
    merge_two_domains_one_fails/1,
    report_format/1,
    report_missing_catalog/1,
    report_explicit_domain/1,
    report_counts_translated_plural/1,
    report_unparseable_po/1,
    extract_pot_dir_override/1,
    extract_parse_error/1,
    merge_extract_error/1,
    merge_po_path_unreadable/1,
    check_extract_error/1,
    check_names_only_plural/1,
    check_parse_error/1,
    check_names_only_drift/1,
    report_empty_project_apps/1,
    previous_of_all_clauses/1,
    previous_of_is_documented/1,
    format_error_strings/1,
    runtime_lib_reachable_at_provider_run/1,
    check_drift_cycle_in_load_context/1
]).

all() ->
    [
        init_registers_providers,
        extract_writes_pot,
        extract_dedups_references,
        check_passes_when_fresh,
        check_fails_on_drift,
        check_fails_on_missing_pot,
        check_names_only_ignores_line_churn,
        check_fails_when_domain_call_sites_vanish,
        merge_creates_and_preserves,
        merge_obsoletes_removed,
        merge_fuzzy_renamed,
        merge_requires_locale,
        merge_plural_carryover,
        merge_fuzzy_plural,
        merge_shape_change_drops_translation,
        merge_old_po_parse_error,
        merge_invalid_utf8_po_fails_soft,
        report_invalid_utf8_po_fails_soft,
        check_invalid_utf8_pot_reports_drift,
        merge_wrapped_msgid_carries_over,
        merge_large_old_po_obsoletes_rest,
        merge_take_by_msgid_not_first,
        merge_fuzzy_cross_shape,
        merge_two_domains_one_fails,
        report_format,
        report_missing_catalog,
        report_explicit_domain,
        report_counts_translated_plural,
        report_unparseable_po,
        extract_pot_dir_override,
        extract_parse_error,
        merge_extract_error,
        merge_po_path_unreadable,
        check_extract_error,
        check_names_only_plural,
        check_parse_error,
        check_names_only_drift,
        report_empty_project_apps,
        previous_of_all_clauses,
        previous_of_is_documented,
        format_error_strings,
        runtime_lib_reachable_at_provider_run,
        check_drift_cycle_in_load_context
    ].

init_per_testcase(TC, Config) ->
    Proj = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    SrcDir = filename:join([Proj, "src"]),
    ok = filelib:ensure_path(SrcDir),
    [{proj, Proj}, {src_dir, SrcDir} | Config].

%% =========================
%% State construction
%% =========================

%% Build a rebar_state whose single project app lives at the test project
%% dir, with the given parsed args (a proplist).
state(Config, Args) ->
    Proj = ?config(proj, Config),
    {ok, App} = rebar_app_info:new(myapp, "0.1.0", Proj),
    St0 = rebar_state:new(),
    St1 = rebar_state:project_apps(St0, [App]),
    rebar_state:command_parsed_args(St1, {Args, []}).

write_consumer(Config, Body) ->
    File = filename:join(?config(src_dir, Config), "myapp_strings.erl"),
    ok = file:write_file(File, Body),
    File.

greet_module(Msgids) ->
    Funs = [
        ["f", integer_to_list(N), "() -> erli18n:gettext(<<\"", M, "\">>).\n"]
     || {N, M} <- lists:zip(lists:seq(1, length(Msgids)), Msgids)
    ],
    Exports = string:join(
        ["f" ++ integer_to_list(N) ++ "/0" || N <- lists:seq(1, length(Msgids))],
        ", "
    ),
    iolist_to_binary([
        "-module(myapp_strings).\n",
        "-export([",
        Exports,
        "]).\n",
        Funs
    ]).

%% A consumer module whose single string is an ngettext plural pair.
plural_module(Singular, Plural) ->
    iolist_to_binary([
        "-module(myapp_strings).\n",
        "-export([p/1]).\n",
        "p(N) -> erli18n:ngettext(<<\"",
        Singular,
        "\">>, <<\"",
        Plural,
        "\">>, N).\n"
    ]).

pot_path(Config, Domain) ->
    filename:join([?config(proj, Config), "priv", "gettext", Domain ++ ".pot"]).

po_path(Config, Locale, Domain) ->
    filename:join([
        ?config(proj, Config), "priv", "gettext", Locale, "LC_MESSAGES", Domain ++ ".po"
    ]).

%% Copy an adversarial `.po` fixture from `providers_SUITE_data/` into the
%% project's `{Locale, Domain}` catalog slot, so the providers read it through
%% the SAME `po_path/3` the real `merge`/`report` commands consult. Returns the
%% destination path so the caller can assert the post-merge file.
install_po_fixture(Config, Locale, Domain, Fixture) ->
    Src = filename:join(?config(data_dir, Config), Fixture),
    Dest = po_path(Config, Locale, Domain),
    ok = filelib:ensure_dir(Dest),
    {ok, _} = file:copy(Src, Dest),
    Dest.

%% Run `Fun` with this process's group leader swapped for a capturing I/O
%% server, returning everything the providers wrote to the console as one
%% UTF-8 binary. `rebar3_erli18n_host:console/2` -> `rebar_api:console/2`
%% writes to the caller's group leader, so this captures the REAL report text
%% the `rebar3 erli18n report` command prints — exercised through `do/1`, not a
%% private builder. The group leader is always restored, even on a crash.
capture_console(Fun) ->
    OldGL = group_leader(),
    Server = spawn_link(fun() -> console_io_loop([]) end),
    group_leader(Server, self()),
    try
        Fun()
    after
        group_leader(OldGL, self())
    end,
    Server ! {get, self()},
    receive
        {console_data, Data} -> Data
    after 5000 ->
        ct:fail(console_capture_timeout)
    end.

%% A minimal I/O server: accumulates `put_chars` requests (the only kind the
%% report path emits) and replies `ok`, answering anything else with a benign
%% error so a stray request can never hang the captured call.
console_io_loop(Buf) ->
    receive
        {io_request, From, ReplyAs, {put_chars, _Enc, Chars}} ->
            From ! {io_reply, ReplyAs, ok},
            console_io_loop([Chars | Buf]);
        {io_request, From, ReplyAs, {put_chars, _Enc, M, F, A}} ->
            From ! {io_reply, ReplyAs, ok},
            console_io_loop([apply(M, F, A) | Buf]);
        {io_request, From, ReplyAs, _Other} ->
            From ! {io_reply, ReplyAs, {error, enotsup}},
            console_io_loop(Buf);
        {get, From} ->
            From ! {console_data, iolist_to_binary(lists:reverse(Buf))}
    end.

%% =========================
%% Tests
%% =========================

init_registers_providers(_Config) ->
    %% The plugin entry chains all five provider inits, ALL under the erli18n
    %% namespace. Collect ONLY the erli18n-namespace providers' impl names, so
    %% the count assertion below cannot be fooled by same-named providers in
    %% other namespaces.
    St0 = rebar_state:new(),
    {ok, St1} = rebar3_erli18n:init(St0),
    Names = [
        providers:impl(P)
     || P <- rebar_state:providers(St1), providers:namespace(P) =:= erli18n
    ],
    lists:foreach(
        fun(N) -> ?assert(lists:member(N, Names)) end,
        [extract, merge, check, report, compile]
    ),
    %% A plain lists:member check cannot catch a MISSING compile registration
    %% (the other four would still pass); pin the exact erli18n-namespace count
    %% so dropping any provider — compile included — fails the test.
    ?assertEqual(5, length(Names)).

extract_writes_pot(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>, <<"Goodbye">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    Pot = pot_path(Config, "default"),
    ?assert(filelib:is_file(Pot)),
    {ok, Bytes} = file:read_file(Pot),
    ?assert(binary:match(Bytes, <<"msgid \"Hello\"">>) =/= nomatch),
    ?assert(binary:match(Bytes, <<"msgid \"Goodbye\"">>) =/= nomatch),
    ?assert(binary:match(Bytes, <<"#: ">>) =/= nomatch).

extract_dedups_references(Config) ->
    %% The same msgid called twice -> ONE entry with TWO references.
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([a/0, b/0]).\n",
            "a() -> erli18n:gettext(<<\"Repeated\">>).\n",
            "b() -> erli18n:gettext(<<\"Repeated\">>).\n"
        ])
    ),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, Bytes} = file:read_file(pot_path(Config, "default")),
    %% Exactly one msgid line for "Repeated".
    Matches = binary:matches(Bytes, <<"msgid \"Repeated\"">>),
    ?assertEqual(1, length(Matches)),
    %% Two reference lines.
    ?assertEqual(2, length(binary:matches(Bytes, <<"#: ">>))).

check_passes_when_fresh(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_check:do(state(Config, [])).

check_fails_on_drift(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    %% Change the msgid -> the committed .pot is stale.
    write_consumer(Config, greet_module([<<"Hi there">>])),
    ?assertMatch({error, _}, rebar3_erli18n_prv_check:do(state(Config, []))).

check_fails_on_missing_pot(Config) ->
    %% Source has a string but no .pot has been written -> drift.
    write_consumer(Config, greet_module([<<"Hello">>])),
    ?assertMatch({error, _}, rebar3_erli18n_prv_check:do(state(Config, []))).

check_names_only_ignores_line_churn(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>, <<"Bye">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    %% Shift the calls down (reference churn) without changing the msgid set.
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([a/0, b/0]).\n",
            "%% padding line\n%% padding line\n",
            "a() -> erli18n:gettext(<<\"Hello\">>).\n",
            "b() -> erli18n:gettext(<<\"Bye\">>).\n"
        ])
    ),
    %% Full check fails (references moved), names-only passes.
    ?assertMatch({error, _}, rebar3_erli18n_prv_check:do(state(Config, []))),
    {ok, _} = rebar3_erli18n_prv_check:do(state(Config, [{names_only, true}])).

check_fails_when_domain_call_sites_vanish(Config) ->
    %% Two domains are extracted, so BOTH alpha.pot and beta.pot are committed.
    %% When every beta call site later disappears from the source, fresh
    %% extraction no longer yields a `beta` domain at all — but the stale
    %% beta.pot is still on disk. check must STILL compare it (against the now
    %% empty extraction) and report drift, not silently pass.
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([a/0, b/0]).\n",
            "a() -> erli18n:dgettext(alpha, <<\"In alpha\">>).\n",
            "b() -> erli18n:dgettext(beta, <<\"In beta\">>).\n"
        ])
    ),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    ?assert(filelib:is_file(pot_path(Config, "alpha"))),
    ?assert(filelib:is_file(pot_path(Config, "beta"))),
    %% Fresh against the committed catalogs: check passes.
    {ok, _} = rebar3_erli18n_prv_check:do(state(Config, [])),

    %% Drop EVERY beta call site (alpha is untouched). beta vanishes from the
    %% fresh extraction, but beta.pot is still on disk -> drift, in both the
    %% default (full) and the --names-only modes.
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([a/0]).\n",
            "a() -> erli18n:dgettext(alpha, <<\"In alpha\">>).\n"
        ])
    ),
    ?assertMatch({error, _}, rebar3_erli18n_prv_check:do(state(Config, []))),
    ?assertMatch(
        {error, _}, rebar3_erli18n_prv_check:do(state(Config, [{names_only, true}]))
    ),

    %% Add the beta call site back: fresh extraction matches the committed
    %% beta.pot again, so check passes.
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([a/0, b/0]).\n",
            "a() -> erli18n:dgettext(alpha, <<\"In alpha\">>).\n",
            "b() -> erli18n:dgettext(beta, <<\"In beta\">>).\n"
        ])
    ),
    {ok, _} = rebar3_erli18n_prv_check:do(state(Config, [])).

merge_creates_and_preserves(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    ?assert(filelib:is_file(Po)),
    %% Translate, re-merge, translation survives.
    {ok, Bytes} = file:read_file(Po),
    Translated = binary:replace(
        Bytes, <<"msgid \"Hello\"\nmsgstr \"\"">>, <<"msgid \"Hello\"\nmsgstr \"Ola\"">>
    ),
    ok = file:write_file(Po, Translated),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Po),
    ?assert(binary:match(After, <<"msgstr \"Ola\"">>) =/= nomatch).

merge_obsoletes_removed(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>, <<"Goodbye">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    %% Drop "Goodbye" from the source, re-extract, re-merge -> #~ obsolete.
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(po_path(Config, "pt_BR", "default")),
    ?assert(binary:match(After, <<"#~">>) =/= nomatch).

merge_fuzzy_renamed(Config) ->
    %% Translate an entry, then rename its msgid slightly -> the new msgid is
    %% fuzzy-matched and carries the old translation + #| previous-msgid.
    write_consumer(Config, greet_module([<<"Sign in now">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    Translated = binary:replace(
        Bytes,
        <<"msgid \"Sign in now\"\nmsgstr \"\"">>,
        <<"msgid \"Sign in now\"\nmsgstr \"Entrar agora\"">>
    ),
    ok = file:write_file(Po, Translated),
    %% Rename the msgid (close enough for jaro >= 0.8).
    write_consumer(Config, greet_module([<<"Sign in now!">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Po),
    ?assert(binary:match(After, <<"#, fuzzy">>) =/= nomatch),
    ?assert(binary:match(After, <<"#| msgid \"Sign in now\"">>) =/= nomatch),
    ?assert(binary:match(After, <<"msgstr \"Entrar agora\"">>) =/= nomatch).

merge_requires_locale(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    %% No --locale -> a clean error, not a crash.
    ?assertMatch({error, _}, rebar3_erli18n_prv_merge:do(state(Config, []))).

merge_plural_carryover(Config) ->
    %% A plural .pot entry whose msgid is unchanged carries the old plural
    %% forms across a re-merge.
    write_consumer(Config, plural_module(<<"one file">>, <<"many files">>)),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    T = binary:replace(
        Bytes,
        <<"msgstr[0] \"\"\nmsgstr[1] \"\"">>,
        <<"msgstr[0] \"um arquivo\"\nmsgstr[1] \"muitos arquivos\"">>
    ),
    ok = file:write_file(Po, T),
    %% Re-extract + re-merge: the translated forms survive.
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Po),
    ?assert(binary:match(After, <<"msgstr[0] \"um arquivo\"">>) =/= nomatch),
    ?assert(binary:match(After, <<"msgstr[1] \"muitos arquivos\"">>) =/= nomatch).

merge_fuzzy_plural(Config) ->
    %% A removed plural entry is fuzzy-matched to a renamed plural entry,
    %% carrying its forms and emitting a `#| msgid_plural` previous hint.
    write_consumer(Config, plural_module(<<"one message">>, <<"many messages">>)),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    T = binary:replace(
        Bytes,
        <<"msgstr[0] \"\"\nmsgstr[1] \"\"">>,
        <<"msgstr[0] \"uma mensagem\"\nmsgstr[1] \"muitas mensagens\"">>
    ),
    ok = file:write_file(Po, T),
    %% Rename the plural msgid slightly (jaro >= 0.8).
    write_consumer(Config, plural_module(<<"one message!">>, <<"many messages">>)),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Po),
    ?assert(binary:match(After, <<"#, fuzzy">>) =/= nomatch),
    ?assert(binary:match(After, <<"#| msgid_plural \"many messages\"">>) =/= nomatch),
    ?assert(binary:match(After, <<"uma mensagem">>) =/= nomatch).

merge_shape_change_drops_translation(Config) ->
    %% Old .po has the msgid as SINGULAR; the fresh .pot has the SAME msgid as
    %% PLURAL. The shape mismatch drops the stale translation, keeping the
    %% fresh plural shape untranslated.
    write_consumer(Config, greet_module([<<"item">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    ok = file:write_file(
        Po,
        binary:replace(
            Bytes, <<"msgid \"item\"\nmsgstr \"\"">>, <<"msgid \"item\"\nmsgstr \"item-pt\"">>
        )
    ),
    %% Now make "item" a PLURAL msgid in source.
    write_consumer(Config, plural_module(<<"item">>, <<"items">>)),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Po),
    %% The fresh plural shape is present, untranslated (no carried singular).
    ?assert(binary:match(After, <<"msgid_plural \"items\"">>) =/= nomatch),
    ?assert(binary:match(After, <<"item-pt">>) =:= nomatch).

merge_old_po_parse_error(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    %% Corrupt the existing .po so the merge's parse of it fails.
    Po = po_path(Config, "pt_BR", "default"),
    ok = file:write_file(Po, <<"msgid \"x\"\nmsgstr ">>),
    ?assertMatch(
        {error, _}, rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}]))
    ).

%% #19: an old `.po` whose body bytes do not match its declared UTF-8 charset
%% (the `adversarial_invalid_utf8.po` fixture carries a raw `0xFF 0xFE` in a
%% msgstr). `erli18n_po:parse` rejects it with a structured
%% `{charset_conversion, ...}`, so `merge` must surface a clean `{error, _}`
%% (no crash, no silent partial write), naming the offending file.
merge_invalid_utf8_po_fails_soft(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    install_po_fixture(Config, "pt_BR", "default", "adversarial_invalid_utf8.po"),
    Result = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    ?assertMatch({error, _}, Result),
    {error, Msg} = Result,
    %% The structured error names the file and the charset_conversion reason.
    ?assert(string:find(Msg, "failed to parse") =/= nomatch),
    ?assert(string:find(Msg, "charset_conversion") =/= nomatch).

%% #19: the SAME invalid-UTF-8 catalog read through `report`. Counting entries
%% must also fail soft: `report` returns a structured `{error, _}` rather than
%% crashing on the unparseable bytes.
report_invalid_utf8_po_fails_soft(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    install_po_fixture(Config, "pt_BR", "default", "adversarial_invalid_utf8.po"),
    Result = rebar3_erli18n_prv_report:do(state(Config, [{locale, "pt_BR"}])),
    ?assertMatch({error, _}, Result),
    {error, Msg} = Result,
    ?assert(string:find(Msg, "charset_conversion") =/= nomatch).

%% #19: an invalid-UTF-8 committed `.pot` must make `check` report DRIFT (the
%% structured `{error, _}` the CI gate exits non-zero on), never crash — in
%% BOTH the default byte-compare mode and the `--names-only` parse-based mode.
%% Full mode differs from the fresh (valid) dump byte-for-byte; names-only's
%% parse of the committed file yields `parse_error`, which never equals the
%% fresh msgid set. Either way: drift, not a stacktrace.
check_invalid_utf8_pot_reports_drift(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    %% Overwrite the freshly-extracted committed .pot with the invalid-UTF-8
    %% fixture (copied into the .pot slot, so it is read through the same path).
    Pot = pot_path(Config, "default"),
    Src = filename:join(?config(data_dir, Config), "adversarial_invalid_utf8.po"),
    ok = filelib:ensure_dir(Pot),
    {ok, _} = file:copy(Src, Pot),
    ?assertMatch({error, _}, rebar3_erli18n_prv_check:do(state(Config, []))),
    ?assertMatch(
        {error, _}, rebar3_erli18n_prv_check:do(state(Config, [{names_only, true}]))
    ).

%% #19: a line-wrapped (`"Sign in " "to your account"`) old msgid is decoded to
%% the SAME binary as the unwrapped fresh `.pot` msgid, so the merge treats it
%% as the exact same key and carries its translation over — no fuzzy, no
%% obsolete. This pins the documented wrapping-insensitive msgid equality.
merge_wrapped_msgid_carries_over(Config) ->
    write_consumer(Config, greet_module([<<"Sign in to your account">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    Dest = install_po_fixture(Config, "pt_BR", "default", "adversarial_wrapped_msgid.po"),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Dest),
    %% The wrapped key matched exactly, so its translation is preserved...
    ?assert(binary:match(After, <<"msgstr \"Entrar na sua conta\"">>) =/= nomatch),
    %% ...and the entry is NOT demoted to obsolete nor flagged fuzzy.
    ?assertEqual(nomatch, binary:match(After, <<"#~">>)),
    ?assertEqual(nomatch, binary:match(After, <<"#, fuzzy">>)).

%% #19: a larger old `.po` (60 translated entries) exercises the `read_old`
%% parse path at scale. Only `key_0` is still a call site, so it is carried
%% over (translation kept) and the other 59 keys are demoted to `#~` obsolete
%% entries — a structured, no-crash, no-data-loss result.
merge_large_old_po_obsoletes_rest(Config) ->
    write_consumer(Config, greet_module([<<"key_0">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    Dest = install_po_fixture(Config, "pt_BR", "default", "adversarial_large_old.po"),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Dest),
    %% The surviving key keeps its translation...
    ?assert(binary:match(After, <<"msgid \"key_0\"\nmsgstr \"val_0\"">>) =/= nomatch),
    %% ...and every other key is demoted to a #~ obsolete entry (59 of them,
    %% each emitting one `#~ msgid` and one `#~ msgstr` line).
    ?assertEqual(59, length(binary:matches(After, <<"#~ msgid">>))),
    %% The carried-over key_0 is NOT itself obsoleted.
    ?assertEqual(nomatch, binary:match(After, <<"#~ msgid \"key_0\"">>)).

merge_take_by_msgid_not_first(Config) ->
    %% Two removed entries; the fuzzy match is the SECOND one, so the
    %% take-by-msgid helper walks past the first candidate.
    write_consumer(Config, greet_module([<<"alpha">>, <<"omega zzz">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    ok = file:write_file(
        Po,
        binary:replace(
            Bytes,
            <<"msgid \"omega zzz\"\nmsgstr \"\"">>,
            <<"msgid \"omega zzz\"\nmsgstr \"omega-pt\"">>
        )
    ),
    %% Replace both with a rename close to the SECOND removed msgid only.
    write_consumer(Config, greet_module([<<"omega zzz!">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Po),
    ?assert(binary:match(After, <<"omega-pt">>) =/= nomatch).

merge_fuzzy_cross_shape(Config) ->
    %% Old .po has the msgid as a translated SINGULAR; the fresh .pot renames
    %% it slightly AND makes it PLURAL. The fuzzy match pairs them, but the
    %% shape differs, so the stale singular translation is dropped (the fresh
    %% plural shape stays untranslated) while still emitting #, fuzzy + #|.
    write_consumer(Config, greet_module([<<"Remove the entry">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    ok = file:write_file(
        Po,
        binary:replace(
            Bytes,
            <<"msgid \"Remove the entry\"\nmsgstr \"\"">>,
            <<"msgid \"Remove the entry\"\nmsgstr \"Remover\"">>
        )
    ),
    %% Rename + change to plural (close enough for jaro >= 0.8).
    write_consumer(Config, plural_module(<<"Remove the entry!">>, <<"Remove the entries">>)),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Po),
    ?assert(binary:match(After, <<"#, fuzzy">>) =/= nomatch),
    %% The stale singular translation must NOT carry onto the plural shape.
    ?assert(binary:match(After, <<"msgstr \"Remover\"">>) =:= nomatch),
    ?assert(binary:match(After, <<"msgid_plural \"Remove the entries\"">>) =/= nomatch).

merge_two_domains_one_fails(Config) ->
    %% Two domains, BOTH target .po paths blocked by a directory. Whatever
    %% order `maps:fold` visits them, the first merge fails and the second is
    %% then seen with an `{error, _}` accumulator — exercising the fold's
    %% error-carry clause.
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([a/0, b/0]).\n",
            "a() -> erli18n:dgettext(alpha, <<\"In alpha\">>).\n",
            "b() -> erli18n:dgettext(beta, <<\"In beta\">>).\n"
        ])
    ),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    ok = filelib:ensure_path(po_path(Config, "pt_BR", "alpha")),
    ok = filelib:ensure_path(po_path(Config, "pt_BR", "beta")),
    ?assertMatch(
        {error, _}, rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}]))
    ).

report_format(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>, <<"Bye">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    %% Before translating anything, both entries are missing: the captured
    %% console text shows the fixed header and a `0/2 translated (2 missing)`
    %% line for pt_BR — asserted byte-for-byte so a regression in the report
    %% format fails the test (not just `{ok, _}`).
    Untranslated = capture_console(fun() ->
        {ok, _} = rebar3_erli18n_prv_report:do(state(Config, []))
    end),
    ?assertEqual(
        <<
            "erli18n translation report\n"
            "==========================\n"
            "\n"
            "domain: default\n"
            "  pt_BR    0/2 translated  (2 missing)\n"
            %% Two trailing newlines beyond the last report line: one is
            %% `build_report/3`'s body terminator, the other is the `~n`
            %% `rebar_api:console/2` appends to the format string.
            "\n"
            "\n"
        >>,
        Untranslated
    ),
    %% Translate ONE of the two; the next report must read exactly 1/2.
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    Translated = binary:replace(
        Bytes, <<"msgid \"Bye\"\nmsgstr \"\"">>, <<"msgid \"Bye\"\nmsgstr \"Tchau\"">>
    ),
    ok = file:write_file(Po, Translated),
    Text = capture_console(fun() ->
        {ok, _} = rebar3_erli18n_prv_report:do(state(Config, []))
    end),
    ?assertEqual(
        <<
            "erli18n translation report\n"
            "==========================\n"
            "\n"
            "domain: default\n"
            "  pt_BR    1/2 translated  (1 missing)\n"
            "\n"
            "\n"
        >>,
        Text
    ).

report_missing_catalog(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    %% A locale with no catalog -> report runs cleanly (no crash) AND prints the
    %% deterministic `(no catalog)` line for that locale, asserted exactly.
    Text = capture_console(fun() ->
        {ok, _} = rebar3_erli18n_prv_report:do(state(Config, [{locale, "es"}]))
    end),
    ?assertEqual(
        <<
            "erli18n translation report\n"
            "==========================\n"
            "\n"
            "domain: default\n"
            "  es       (no catalog)\n"
            "\n"
            "\n"
        >>,
        Text
    ).

report_explicit_domain(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    %% report with an explicit --domain: the captured text reports only that
    %% domain, with the single untranslated entry as `0/1 (1 missing)`.
    Text = capture_console(fun() ->
        {ok, _} = rebar3_erli18n_prv_report:do(state(Config, [{domain, "default"}]))
    end),
    ?assertEqual(
        <<
            "erli18n translation report\n"
            "==========================\n"
            "\n"
            "domain: default\n"
            "  pt_BR    0/1 translated  (1 missing)\n"
            "\n"
            "\n"
        >>,
        Text
    ).

report_counts_translated_plural(Config) ->
    %% A plural entry that is fully translated must count as translated.
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([p/1]).\n",
            "p(N) -> erli18n:ngettext(<<\"one cat\">>, <<\"many cats\">>, N).\n"
        ])
    ),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    %% Fill both plural forms.
    T = binary:replace(
        Bytes,
        <<"msgstr[0] \"\"\nmsgstr[1] \"\"">>,
        <<"msgstr[0] \"um gato\"\nmsgstr[1] \"muitos gatos\"">>
    ),
    ok = file:write_file(Po, T),
    %% A fully-translated plural entry must count as ONE translated entry, so
    %% the report reads `1/1 translated (0 missing)` — asserted exactly to lock
    %% the plural-counting (fuzzy-drop / both-forms-non-empty) behavior.
    Text = capture_console(fun() ->
        {ok, _} = rebar3_erli18n_prv_report:do(state(Config, []))
    end),
    ?assertEqual(
        <<
            "erli18n translation report\n"
            "==========================\n"
            "\n"
            "domain: default\n"
            "  pt_BR    1/1 translated  (0 missing)\n"
            "\n"
            "\n"
        >>,
        Text
    ).

report_unparseable_po(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    %% Corrupt the .po so erli18n_po:parse fails -> report returns an error.
    Po = po_path(Config, "pt_BR", "default"),
    ok = file:write_file(Po, <<"msgid \"x\"\nmsgstr ">>),
    ?assertMatch({error, _}, rebar3_erli18n_prv_report:do(state(Config, []))).

extract_pot_dir_override(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    Custom = filename:join(?config(proj, Config), "custom_catalogs"),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [{pot_dir, Custom}])),
    ?assert(filelib:is_file(filename:join(Custom, "default.pot"))).

extract_parse_error(Config) ->
    %% The source wildcard matches `*.erl`; a DIRECTORY named `weird.erl`
    %% matches but `epp:open` fails with `eisdir`, exercising the provider's
    %% parse-error surfacing path (never a silent crash).
    write_consumer(Config, greet_module([<<"Hello">>])),
    DirErl = filename:join(?config(src_dir, Config), "weird.erl"),
    ok = filelib:ensure_path(DirErl),
    ?assertMatch({error, _}, rebar3_erli18n_prv_extract:do(state(Config, []))).

check_parse_error(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    %% Corrupt the committed .pot so --names-only's parse of it fails -> drift.
    Pot = pot_path(Config, "default"),
    ok = file:write_file(Pot, <<"msgid \"x\"\nmsgstr ">>),
    ?assertMatch({error, _}, rebar3_erli18n_prv_check:do(state(Config, [{names_only, true}]))).

check_names_only_drift(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    %% Add a NEW msgid (the set changes) -> --names-only also reports drift.
    write_consumer(Config, greet_module([<<"Hello">>, <<"World">>])),
    ?assertMatch(
        {error, _}, rebar3_erli18n_prv_check:do(state(Config, [{names_only, true}]))
    ).

%% A state with a single project app but a `src/` containing a directory
%% named like a source file, so the source wildcard matches it and the
%% extract pass fails (epp `eisdir`).
bad_src_state(Config) ->
    DirErl = filename:join(?config(src_dir, Config), "weird.erl"),
    ok = filelib:ensure_path(DirErl),
    state(Config, [{locale, "pt_BR"}]).

merge_extract_error(Config) ->
    %% extract_project fails -> merge surfaces the error.
    ?assertMatch({error, _}, rebar3_erli18n_prv_merge:do(bad_src_state(Config))).

merge_po_path_unreadable(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    %% Make the target .po path a DIRECTORY so read_old's file:read_file
    %% returns a non-enoent error (eisdir) -> merge surfaces it.
    Po = po_path(Config, "pt_BR", "default"),
    ok = filelib:ensure_path(Po),
    ?assertMatch(
        {error, _}, rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}]))
    ).

check_extract_error(Config) ->
    %% extract_project fails -> check surfaces the error.
    DirErl = filename:join(?config(src_dir, Config), "weird.erl"),
    ok = filelib:ensure_path(DirErl),
    ?assertMatch({error, _}, rebar3_erli18n_prv_check:do(state(Config, []))).

check_names_only_plural(Config) ->
    %% A plural .pot entry exercises the names-only key_of plural clause.
    write_consumer(Config, plural_module(<<"one dog">>, <<"many dogs">>)),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_check:do(state(Config, [{names_only, true}])).

report_empty_project_apps(Config) ->
    %% A state with NO project apps -> pot_dir falls back to the state dir;
    %% report runs cleanly over an empty catalog tree.
    St0 = rebar_state:new(),
    St1 = rebar_state:dir(St0, ?config(proj, Config)),
    St2 = rebar_state:command_parsed_args(St1, {[], []}),
    {ok, _} = rebar3_erli18n_prv_report:do(St2).

previous_of_all_clauses(_Config) ->
    %% White-box: `previous_of/1` is total over `erli18n_po:entry()`. Exercise
    %% all three clauses, including the `{plural, _, _, undefined, _}` shape
    %% that parse never yields but the type permits (so the match stays
    %% exhaustive for eqwalizer/dialyzer).
    ?assertEqual(
        {undefined, <<"m">>},
        rebar3_erli18n_prv_merge:previous_of(
            {singular, undefined, <<"m">>, <<"t">>}
        )
    ),
    ?assertEqual(
        {<<"c">>, <<"m">>},
        rebar3_erli18n_prv_merge:previous_of(
            {plural, <<"c">>, <<"m">>, undefined, [{0, <<"t">>}]}
        )
    ),
    ?assertEqual(
        {undefined, <<"m">>, <<"mp">>},
        rebar3_erli18n_prv_merge:previous_of(
            {plural, undefined, <<"m">>, <<"mp">>, [{0, <<"t0">>}, {1, <<"t1">>}]}
        )
    ).

previous_of_is_documented(_Config) ->
    %% `previous_of/1` is a build-tool internal exported only for white-box
    %% testing, so it lands on ex_doc's public surface. Assert it carries a
    %% rendered `-doc` (a non-empty EEP-48 Docs chunk entry), not a bare `%%`
    %% comment that ex_doc would surface as undocumented.
    %%
    %% Read the "Docs" chunk from the ON-DISK .beam rather than via
    %% `code:get_doc/1`: under `ct --cover` the module is cover-compiled, for
    %% which `code:which/1` returns the atom `cover_compiled` and `code:get_doc/1`
    %% fails with `{error, cover_compiled}` on OTP 27 (it happens to resolve on
    %% OTP 28). `cover:is_compiled/1` hands back the original .beam path, so we
    %% read the exact same native Docs chunk ex_doc renders from, on every OTP
    %% and whether or not coverage is enabled.
    Mod = rebar3_erli18n_prv_merge,
    BeamFile =
        case code:which(Mod) of
            cover_compiled ->
                {file, F} = cover:is_compiled(Mod),
                F;
            F when is_list(F) ->
                F
        end,
    {ok, {Mod, [{"Docs", DocsBin}]}} = beam_lib:chunks(BeamFile, ["Docs"]),
    {docs_v1, _Anno, _Lang, _Fmt, _ModDoc, _Meta, Docs} = binary_to_term(DocsBin),
    [Doc] =
        [D || {{function, previous_of, 1}, _A, _Sig, D, _M} <- Docs],
    %% A documented function yields a language-keyed map of doc strings; an
    %% undocumented export yields the atom `none` (and a hidden one `hidden`).
    ?assert(is_map(Doc)),
    EnDoc = maps:get(<<"en">>, Doc),
    ?assert(byte_size(EnDoc) > 0),
    %% The doc states the white-box-only / not-published intent (#8).
    ?assertNotEqual(nomatch, binary:match(EnDoc, <<"white-box">>)),
    ?assertNotEqual(nomatch, binary:match(EnDoc, <<"not part of any published">>)).

format_error_strings(_Config) ->
    %% Each provider renders its errors to a flat string.
    ?assert(is_list(rebar3_erli18n_prv_extract:format_error(some_reason))),
    ?assert(is_list(rebar3_erli18n_prv_merge:format_error(locale_required))),
    ?assert(is_list(rebar3_erli18n_prv_check:format_error({drift, <<"x">>}))),
    ?assert(is_list(rebar3_erli18n_prv_report:format_error({po_parse_failed, "p", boom}))).

runtime_lib_reachable_at_provider_run(Config) ->
    %% The plugin -> lib load path, asserted at ACTUAL provider-run time. The
    %% diagnostic env var makes `extract:do/1` log the resolved `erli18n_po`
    %% path through the rebar3 host logger as it runs; the same `runtime_lib_path/0`
    %% the provider consults is asserted here to be a live cross-package edge.
    write_consumer(Config, greet_module([<<"Hello">>])),
    true = os:putenv("ERLI18N_DIAG_LOADPATH", "1"),
    try
        %% The provider runs `maybe_log_runtime_lib_path/0` from inside do/1.
        {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
        %% At provider-run time the runtime lib is reachable (never
        %% `non_existing`) and its published API is callable from this node —
        %% the same edge `prv_check`/`prv_merge`/`prv_report` exercise via
        %% `erli18n_po:parse/dump/escape_string`. A `non_existing` here would be
        %% the `undef erli18n_po:dump/1` failure the separate-package boundary
        %% must rule out.
        Which = rebar3_erli18n_common:runtime_lib_path(),
        ?assertNotEqual(non_existing, Which),
        ?assertEqual(<<"a">>, erli18n_po:escape_string(<<"a">>))
    after
        true = os:unsetenv("ERLI18N_DIAG_LOADPATH")
    end.

check_drift_cycle_in_load_context(Config) ->
    %% The deliberate negative-drift integration test that mirrors the
    %% production gate's FAIL-on-drift -> PASS-when-fresh cycle, run through the
    %% SAME provider entry points (`prv_extract:do/1`, `prv_check:do/1`) the
    %% `rebar3 erli18n check` command drives.
    %%
    %% This MUST run in the consumer/plugin load context so a load-path
    %% regression FAILS THE TEST EXPLICITLY rather than masquerading as drift.
    %% We assert that up front: `runtime_lib_path/0` —
    %% the very `code:which(erli18n_po)` `extract_project/1` consults before it
    %% calls `erli18n_po:dump/1` — is NOT `non_existing`. If the cross-package
    %% `{deps, [erli18n]}` edge ever regressed, `check`'s `do/1` would
    %% `undef`-crash inside `extract_project` -> `dump` (a CT error, not an
    %% `{error, drift}` value), so the drift assertions below can NEVER pass on a
    %% missing lib — a fake-drift impossibility this guard makes explicit.
    ?assertNotEqual(non_existing, rebar3_erli18n_common:runtime_lib_path()),

    %% 1. Fresh: extract writes the .pot, check passes (the committed catalog
    %%    matches the call sites).
    write_consumer(Config, greet_module([<<"Sign in">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_check:do(state(Config, [])),

    %% 2. Drift: ADD a new literal call site WITHOUT re-extracting. The
    %%    committed .pot is now stale, so check FAILS with a structured drift
    %%    error (not a crash). Because the load-context guard above proved the
    %%    lib is reachable, this `{error, _}` can only be genuine drift.
    write_consumer(Config, greet_module([<<"Sign in">>, <<"Sign out">>])),
    DriftResult = rebar3_erli18n_prv_check:do(state(Config, [])),
    ?assertMatch({error, _}, DriftResult),
    {error, DriftMsg} = DriftResult,
    ?assert(string:find(DriftMsg, "out of date") =/= nomatch),

    %% 3. Regenerate: re-extract against the new call sites; check passes again.
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_check:do(state(Config, [])).
