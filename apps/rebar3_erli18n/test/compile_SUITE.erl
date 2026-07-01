-module(compile_SUITE).

-moduledoc """
In-node tests for the `rebar3 erli18n compile` provider
(`rebar3_erli18n_prv_compile`).

Mirrors `providers_SUITE`: builds a REAL `rebar_state` with a throwaway project
app in `priv_dir` (plus its `rebar.config` `erli18n` key) and drives the
provider's `init/1`/`do/1` directly, NO shell-out. The catalogs are written as
`.po` files under the project's `priv/gettext` tree, exactly where the provider
discovers them.

The central obligation is END-TO-END PARITY: codegen -> load ->
`erli18n:register_compiled_catalogs/1` -> lookup must equal the runtime
`erli18n:ensure_loaded/3` of the SAME `.po` under the SAME fuzzy policy. The
suite also pins carrier generation, the `.gitignore`, the already-compiled
plural, the optional eqwalizer nowarn, divergence handling, orphan pruning,
the `pt_BR` vs `pt-BR` collision abort, the `--check` dry run, and the
broken-plural abort.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    init_registers_under_erli18n/1,
    generates_one_carrier_per_catalog/1,
    writes_gitignore_star/1,
    carrier_carries_parsed_entries_and_compiled_plural/1,
    default_carrier_has_eqwalizer_nowarn/1,
    nowarn_false_omits_nowarn_line/1,
    parity_default_fuzzy_policy/1,
    parity_include_fuzzy_true/1,
    divergent_po_warns_at_build_and_is_register_quiet/1,
    deleting_po_prunes_carrier_on_recompile/1,
    collision_pt_br_vs_pt_dash_br_aborts/1,
    check_dry_run_writes_nothing_and_fails_on_violation/1,
    broken_plural_aborts_loudly/1,
    over_entry_cap_aborts_and_writes_nothing/1,
    at_entry_cap_builds/1,
    over_byte_cap_aborts_before_read/1,
    infinity_caps_disable_the_bounds/1
]).

%% `compile_and_load/1` is the dynamic-module load helper: `compile:file`/
%% `code:load_binary` return wide union types eqwalizer cannot statically
%% narrow, so quarantine it with a static annotation — the same zero-runtime-dep
%% pattern used in the runtime modules `erli18n_server`/`erli18n_pt_store`.
%% (A wild attribute must precede the first function definition.)
-eqwalizer({nowarn_function, compile_and_load/1}).

all() ->
    [
        init_registers_under_erli18n,
        generates_one_carrier_per_catalog,
        writes_gitignore_star,
        carrier_carries_parsed_entries_and_compiled_plural,
        default_carrier_has_eqwalizer_nowarn,
        nowarn_false_omits_nowarn_line,
        parity_default_fuzzy_policy,
        parity_include_fuzzy_true,
        divergent_po_warns_at_build_and_is_register_quiet,
        deleting_po_prunes_carrier_on_recompile,
        collision_pt_br_vs_pt_dash_br_aborts,
        check_dry_run_writes_nothing_and_fails_on_violation,
        broken_plural_aborts_loudly,
        over_entry_cap_aborts_and_writes_nothing,
        at_entry_cap_builds,
        over_byte_cap_aborts_before_read,
        infinity_caps_disable_the_bounds
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    ok.

init_per_testcase(TC, Config) ->
    Proj = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    SrcDir = filename:join([Proj, "src"]),
    ok = filelib:ensure_path(SrcDir),
    unload_all(),
    [{proj, Proj}, {src_dir, SrcDir} | Config].

end_per_testcase(_TC, _Config) ->
    unload_all(),
    ok.

%% =========================
%% Tests
%% =========================

init_registers_under_erli18n(_Config) ->
    St0 = rebar_state:new(),
    {ok, St1} = rebar3_erli18n_prv_compile:init(St0),
    Names = [
        providers:impl(P)
     || P <- rebar_state:providers(St1), providers:namespace(P) =:= erli18n
    ],
    ?assert(lists:member(compile, Names)).

generates_one_carrier_per_catalog(Config) ->
    write_po(Config, "fr", "default", simple_po()),
    write_po(Config, "de", "default", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    Carriers = carriers(Config),
    ?assertEqual(2, length(Carriers)),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"de">>))).

writes_gitignore_star(Config) ->
    write_po(Config, "fr", "default", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    GitIgnore = filename:join(gen_dir(Config), ".gitignore"),
    ?assert(filelib:is_file(GitIgnore)),
    {ok, Body} = file:read_file(GitIgnore),
    ?assertEqual(<<"*\n">>, Body).

carrier_carries_parsed_entries_and_compiled_plural(Config) ->
    %% A .po with a real (non-fallback) Plural-Forms header bakes an
    %% ALREADY-compiled plural map (not the `fallback` sentinel, not a raw
    %% string) and the ALREADY-parsed entries into catalog/0.
    write_po(Config, "fr", "default", plural_po(<<"nplurals=2; plural=(n > 1);">>)),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    Mod = compile_and_load(carrier_path(Config, default, <<"fr">>)),
    {Domain, Locale, Entries, Header} = Mod:catalog(),
    ?assertEqual(default, Domain),
    ?assertEqual(<<"fr">>, Locale),
    %% Entries are the already-parsed erli18n_po:entry() tuples.
    ?assert(
        lists:member(
            {plural, undefined, <<"file">>, <<"files">>, [{0, <<"fichier">>}, {1, <<"fichiers">>}]},
            Entries
        )
    ),
    %% The plural is an ALREADY-compiled bundle (a map with nplurals/expr/raw),
    %% so boot does NO plural compile.
    Plural = maps:get(plural, Header),
    ?assert(is_map(Plural)),
    ?assertEqual(2, maps:get(nplurals, Plural)),
    ?assert(maps:is_key(expr, Plural)).

default_carrier_has_eqwalizer_nowarn(Config) ->
    write_po(Config, "fr", "default", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    {ok, Src} = file:read_file(carrier_path(Config, default, <<"fr">>)),
    ?assertNotEqual(nomatch, binary:match(Src, <<"-eqwalizer({nowarn_function, {catalog, 0}})">>)).

nowarn_false_omits_nowarn_line(Config) ->
    write_po(Config, "fr", "default", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}, {gen_eqwalizer_nowarn, false}]),
    {ok, Src} = file:read_file(carrier_path(Config, default, <<"fr">>)),
    ?assertEqual(nomatch, binary:match(Src, <<"nowarn_function">>)),
    %% The precise spec is still emitted.
    ?assertNotEqual(
        nomatch, binary:match(Src, <<"-spec catalog() -> erli18n_server:compiled_spec().">>)
    ).

parity_default_fuzzy_policy(Config) ->
    %% codegen -> load -> register_compiled_catalogs -> lookup must equal the
    %% runtime ensure_loaded of the SAME .po under the DEFAULT fuzzy policy
    %% (fuzzy entries dropped). The .po carries a translated singular, a
    %% translated plural, and a #, fuzzy entry that BOTH paths must drop.
    Po = write_po(Config, "fr", "default", fuzzy_po()),
    assert_parity(Config, default, <<"fr">>, Po, #{}, [], [{compiled_catalogs, true}]).

parity_include_fuzzy_true(Config) ->
    %% Same parity, but BOTH paths include fuzzy entries: runtime via
    %% ensure_loaded opts, compiled via {include_fuzzy, true} config. The fuzzy
    %% entry's translation now resolves identically on both sides.
    Po = write_po(Config, "fr", "default", fuzzy_po()),
    assert_parity(
        Config,
        default,
        <<"fr">>,
        Po,
        #{include_fuzzy => true},
        [<<"Draft">>],
        [{compiled_catalogs, true}, {include_fuzzy, true}]
    ).

divergent_po_warns_at_build_and_is_register_quiet(Config) ->
    %% A French catalog whose header rule (n != 1) diverges from CLDR (n > 1).
    %% The build bakes the divergence into the carrier header, but boot-time
    %% registration emits ZERO [erli18n, plural, divergence_warning] telemetry
    %% (boot-quiet): the divergence lives in the header, not in a per-catalog
    %% boot burst.
    write_po(Config, "fr", "default", plural_po(<<"nplurals=2; plural=(n != 1);">>)),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    Mod = compile_and_load(carrier_path(Config, default, <<"fr">>)),
    {_D, _L, _E, Header} = Mod:catalog(),
    %% The divergence was computed and baked at BUILD time.
    ?assertMatch({plural_divergence, _, _}, maps:get(divergence, Header)),

    %% Registering the carrier emits NO divergence telemetry.
    Ref = make_ref(),
    HandlerId = {?MODULE, Ref},
    Self = self(),
    ok = telemetry:attach(
        HandlerId,
        [erli18n, plural, divergence_warning],
        fun(_Event, _Measure, _Meta, _Cfg) -> Self ! {div_event, Ref} end,
        undefined
    ),
    try
        App = register_via_app(Mod),
        try
            %% The catalog is installed and serves the divergent rule.
            ?assertMatch({ok, _}, erli18n_server:lookup_header(default, <<"fr">>))
        after
            cleanup_app(App)
        end
    after
        telemetry:detach(HandlerId)
    end,
    receive
        {div_event, Ref} -> ct:fail(register_emitted_divergence_telemetry)
    after 200 ->
        ok
    end.

deleting_po_prunes_carrier_on_recompile(Config) ->
    write_po(Config, "fr", "default", simple_po()),
    write_po(Config, "de", "default", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"de">>))),
    %% Delete the German .po, recompile: its carrier is pruned, the French one
    %% survives.
    ok = file:delete(po_path(Config, "de", "default")),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    ?assertNot(filelib:is_file(carrier_path(Config, default, <<"de">>))),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))).

collision_pt_br_vs_pt_dash_br_aborts(Config) ->
    %% Two directory spellings of the SAME canonical locale (pt_BR and pt-BR)
    %% both resolve to the catalog (default, <<"pt_BR">>), colliding on one
    %% carrier module name — an ambiguous source tree the provider aborts on.
    write_po(Config, "pt_BR", "default", simple_po()),
    write_po(Config, "pt-BR", "default", simple_po()),
    Result = run(Config, [], [{compiled_catalogs, true}]),
    ?assertMatch({error, _}, Result),
    {error, Msg} = Result,
    ?assert(string:find(Msg, "collides") =/= nomatch).

check_dry_run_writes_nothing_and_fails_on_violation(Config) ->
    %% --check is a dry run: it generates NOTHING, but it still enforces the key
    %% check (strict), so a call site missing from the compiled catalog makes it
    %% fail with a non-zero {error, _}.
    write_consumer(Config, gettext_module([<<"Present">>, <<"Absent">>])),
    %% The catalog defines only "Present" — "Absent" is a call site with no key.
    write_po(Config, "fr", "default", po([singular(<<"Present">>, <<"Presente">>)])),
    Result = run(Config, [{check, true}], [{compiled_catalogs, true}]),
    ?assertMatch({error, _}, Result),
    {error, Msg} = Result,
    ?assert(string:find(Msg, "missing") =/= nomatch),
    %% Nothing was written: no carrier, no gen dir.
    ?assertNot(filelib:is_file(carrier_path(Config, default, <<"fr">>))),
    ?assertEqual([], carriers(Config)).

broken_plural_aborts_loudly(Config) ->
    %% A .po whose Plural-Forms header cannot compile aborts the build loudly
    %% (plural_compile_error_at_codegen), never emitting a malformed carrier.
    write_po(Config, "fr", "default", plural_po(<<"nplurals=; plural=;">>)),
    Result = run(Config, [], [{compiled_catalogs, true}]),
    ?assertMatch({error, _}, Result),
    {error, Msg} = Result,
    ?assert(string:find(Msg, "plural") =/= nomatch),
    ?assertNot(filelib:is_file(carrier_path(Config, default, <<"fr">>))).

%% A catalog whose parsed entry count exceeds `{max_entries, N}` aborts the
%% build loudly (`too_many_entries`) and writes NO carrier — the same entry cap
%% `erli18n_server` enforces at register time, applied here at BUILD time so a
%% catalog can never carry more than the runtime would accept.
over_entry_cap_aborts_and_writes_nothing(Config) ->
    write_po(Config, "fr", "default", many_singulars_po(3)),
    Result = run(Config, [], [{compiled_catalogs, true}, {max_entries, 2}]),
    ?assertMatch({error, _}, Result),
    {error, Msg} = Result,
    ?assert(string:find(Msg, "too_many_entries") =/= nomatch),
    ?assertNot(filelib:is_file(carrier_path(Config, default, <<"fr">>))),
    ?assertEqual([], carriers(Config)).

%% A catalog whose entry count is EXACTLY at the cap builds normally: the bound
%% is inclusive (reject only strictly over).
at_entry_cap_builds(Config) ->
    write_po(Config, "fr", "default", many_singulars_po(2)),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}, {max_entries, 2}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))).

%% A `.po` larger than `{max_po_bytes, N}` aborts loudly (`input_too_large`)
%% BEFORE the file is read into memory (a `filelib:file_size/1` pre-check), so a
%% pathological file fails fast with a clear error rather than an OOM. A tiny cap
%% against any real `.po` exercises the pre-read guard without a huge fixture.
over_byte_cap_aborts_before_read(Config) ->
    write_po(Config, "fr", "default", simple_po()),
    Result = run(Config, [], [{compiled_catalogs, true}, {max_po_bytes, 8}]),
    ?assertMatch({error, _}, Result),
    {error, Msg} = Result,
    ?assert(string:find(Msg, "input_too_large") =/= nomatch),
    ?assertNot(filelib:is_file(carrier_path(Config, default, <<"fr">>))),
    ?assertEqual([], carriers(Config)).

%% `infinity` disables each cap: a many-entry catalog read under a tiny finite
%% cap would abort, but `{max_entries, infinity}`/`{max_po_bytes, infinity}`
%% builds it — the escape hatch for trusted, internal catalogs.
infinity_caps_disable_the_bounds(Config) ->
    write_po(Config, "fr", "default", many_singulars_po(3)),
    {ok, _} = run(Config, [], [
        {compiled_catalogs, true},
        {max_entries, infinity},
        {max_po_bytes, infinity}
    ]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))).

%% =========================
%% Parity harness
%% =========================

%% Load the .po the RUNTIME way, capture lookups, unload; then run the provider,
%% load + register the carrier, capture lookups; assert byte-for-byte parity.
%% `ExtraFuzzy` is the list of fuzzy-only msgids to additionally probe.
assert_parity(Config, Domain, Locale, Po, EnsureOpts, ExtraFuzzy, CfgProps) ->
    Probes = [<<"Hello">> | ExtraFuzzy],
    %% Runtime side.
    {ok, _} = erli18n:ensure_loaded(Domain, Locale, Po, EnsureOpts),
    Runtime = #{
        singulars => [{M, erli18n:gettext(Domain, M, Locale)} || M <- Probes],
        plural1 => erli18n:ngettext(Domain, <<"file">>, <<"files">>, 1, Locale),
        plural2 => erli18n:ngettext(Domain, <<"file">>, <<"files">>, 2, Locale)
    },
    ok = erli18n:unload(Domain, Locale),

    %% Compiled side.
    {ok, _} = run(Config, [], CfgProps),
    Mod = compile_and_load(carrier_path(Config, Domain, Locale)),
    App = register_via_app(Mod),
    try
        Compiled = #{
            singulars => [{M, erli18n:gettext(Domain, M, Locale)} || M <- Probes],
            plural1 => erli18n:ngettext(Domain, <<"file">>, <<"files">>, 1, Locale),
            plural2 => erli18n:ngettext(Domain, <<"file">>, <<"files">>, 2, Locale)
        },
        ?assertEqual(Runtime, Compiled)
    after
        cleanup_app(App)
    end.

%% =========================
%% State + run helpers
%% =========================

%% A rebar_state with one project app at the test project dir, the given parsed
%% args, and the given `erli18n` rebar.config key.
state(Config, Args, CfgProps) ->
    Proj = ?config(proj, Config),
    {ok, App} = rebar_app_info:new(myapp, "0.1.0", Proj),
    St0 = rebar_state:new(),
    St1 = rebar_state:project_apps(St0, [App]),
    St2 = rebar_state:command_parsed_args(St1, {Args, []}),
    rebar_state:set(St2, erli18n, CfgProps).

run(Config, Args, CfgProps) ->
    rebar3_erli18n_prv_compile:do(state(Config, Args, CfgProps)).

%% =========================
%% Carrier load + register
%% =========================

%% Compile a generated carrier .erl under the project's strict erl_opts and load
%% it, returning the module. A warning in the generated source fails here.
compile_and_load(Path) ->
    Opts = [
        binary,
        debug_info,
        return_errors,
        warnings_as_errors,
        warn_unused_vars,
        warn_shadow_vars,
        warn_obsolete_guard
    ],
    case compile:file(Path, Opts) of
        {ok, Mod, Beam} ->
            _ = code:purge(Mod),
            {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Beam),
            Mod;
        Other ->
            ct:fail({carrier_compile_failed, Path, Other})
    end.

%% Register a loaded carrier through the documented façade door
%% `erli18n:register_compiled_catalogs/1`, by exposing it via a throwaway
%% application's module list (which `erli18n_compiled:discover/1` reads).
register_via_app(Mod) ->
    App = list_to_atom("cc_app_" ++ atom_to_list(Mod)),
    _ = application:unload(App),
    ok = application:load(
        {application, App, [
            {description, "throwaway carrier host"},
            {vsn, "0"},
            {modules, [Mod]},
            {registered, []},
            {applications, [kernel, stdlib]},
            {env, []}
        ]}
    ),
    _ = erli18n:register_compiled_catalogs(App),
    App.

cleanup_app(App) ->
    _ = application:unload(App),
    ok.

%% =========================
%% Catalog fixtures
%% =========================

%% A minimal valid .po header carrying a Plural-Forms rule (or none).
po_header(none) ->
    <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"MIME-Version: 1.0\\n\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Content-Transfer-Encoding: 8bit\\n\"\n"
        "\n"
    >>;
po_header(PluralForms) ->
    iolist_to_binary([
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"MIME-Version: 1.0\\n\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Content-Transfer-Encoding: 8bit\\n\"\n"
        "\"Plural-Forms: ",
        PluralForms,
        "\\n\"\n"
        "\n"
    ]).

po(BodyEntries) ->
    iolist_to_binary([po_header(none) | BodyEntries]).

po_with_plural(PluralForms, BodyEntries) ->
    iolist_to_binary([po_header(PluralForms) | BodyEntries]).

singular(Msgid, Msgstr) ->
    ["msgid \"", Msgid, "\"\nmsgstr \"", Msgstr, "\"\n\n"].

fuzzy_singular(Msgid, Msgstr) ->
    ["#, fuzzy\nmsgid \"", Msgid, "\"\nmsgstr \"", Msgstr, "\"\n\n"].

plural_entry() ->
    [
        "msgid \"file\"\n"
        "msgid_plural \"files\"\n"
        "msgstr[0] \"fichier\"\n"
        "msgstr[1] \"fichiers\"\n\n"
    ].

%% A simple singular-only catalog.
simple_po() ->
    po([singular(<<"Hello">>, <<"Bonjour">>)]).

%% A singular-only catalog with `N` distinct entries, for the entry-cap bounds.
many_singulars_po(N) ->
    po([
        singular(iolist_to_binary(["Msg", integer_to_list(I)]), <<"t">>)
     || I <- lists:seq(1, N)
    ]).

%% A catalog with a singular plus a 2-form plural, under the given rule.
plural_po(PluralForms) ->
    po_with_plural(PluralForms, [singular(<<"Hello">>, <<"Bonjour">>), plural_entry()]).

%% A catalog mixing a translated singular, a translated plural, and a fuzzy
%% entry (dropped by default, kept under include_fuzzy).
fuzzy_po() ->
    po_with_plural(
        <<"nplurals=2; plural=(n > 1);">>,
        [
            singular(<<"Hello">>, <<"Bonjour">>),
            plural_entry(),
            fuzzy_singular(<<"Draft">>, <<"Brouillon">>)
        ]
    ).

%% =========================
%% Consumer source (for the key check)
%% =========================

write_consumer(Config, Body) ->
    File = filename:join(?config(src_dir, Config), "myapp_strings.erl"),
    ok = file:write_file(File, Body),
    File.

gettext_module(Msgids) ->
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

%% =========================
%% Paths
%% =========================

pot_dir(Config) ->
    filename:join([?config(proj, Config), "priv", "gettext"]).

gen_dir(Config) ->
    filename:join([?config(proj, Config), "src", "erli18n_gen"]).

po_path(Config, Locale, Domain) ->
    filename:join([pot_dir(Config), Locale, "LC_MESSAGES", Domain ++ ".po"]).

write_po(Config, Locale, Domain, Content) ->
    Path = po_path(Config, Locale, Domain),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Content),
    Path.

carrier_path(Config, Domain, Locale) ->
    %% `module_name/2` takes a BINARY domain and returns a BINARY name; the test
    %% call sites pass an atom domain, so read its name with `atom_to_binary`
    %% (interns nothing) and build the path from the binary module name.
    Mod = rebar3_erli18n_codegen:module_name(atom_to_binary(Domain, utf8), Locale),
    filename:join(gen_dir(Config), binary_to_list(Mod) ++ ".erl").

carriers(Config) ->
    filelib:wildcard(filename:join(gen_dir(Config), "erli18n_cc_*.erl")).

%% =========================
%% Misc
%% =========================

unload_all() ->
    [ok = erli18n_server:unload(D, L) || {D, L, _N} <- erli18n_server:loaded_catalogs()],
    ok.
