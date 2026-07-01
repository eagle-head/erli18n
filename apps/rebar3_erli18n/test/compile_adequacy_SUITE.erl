-module(compile_adequacy_SUITE).

-moduledoc """
Regression suite for the `rebar3 erli18n compile` provider: pins the
boundaries the functional `compile_SUITE` does not, so a regression in the
opt-in gate, the policy precedence, the `key_check` normalisation, the default
fuzzy exclusion, or the co-registration of the other four providers fails here.

- The opt-in master gate: with `{compiled_catalogs, true}` ABSENT (and with
  `false`) the provider is a no-op that writes NOTHING — exercising the
  `get_config/3` read of a missing and a present-but-false key.
- `--no-key-check` overrides `--strict` (precedence).
- An unknown `{key_check, _}` atom normalises to `warn` (no crash, no build
  failure on a missing key).
- The default fuzzy policy EXCLUDES `#, fuzzy` entries from the generated
  carrier.
- The other four providers (`extract`/`merge`/`check`/`report`) behave
  identically with `compile` registered alongside.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    absent_gate_is_noop_writes_nothing/1,
    false_gate_is_noop_writes_nothing/1,
    no_key_check_overrides_strict/1,
    unknown_key_check_normalizes_to_warn/1,
    default_excludes_fuzzy_entries/1,
    scoped_build_preserves_other_domain_carrier/1,
    invalid_compiled_domains_aborts_loudly/1,
    four_providers_unaffected_by_fifth/1,
    %% Config-partition fallbacks (misconfig degradation) + rare scoping paths.
    non_list_config_is_noop/1,
    non_boolean_include_fuzzy_uses_default/1,
    non_list_gen_dir_uses_default/1,
    absolute_gen_dir_used_verbatim/1,
    relative_gen_dir_without_project_apps_uses_state_dir/1,
    compiled_domains_list_scopes_build/1,
    non_list_compiled_domains_aborts/1,
    cli_domain_intersects_config_scope/1,
    %% I/O error paths (root-proof filesystem faults).
    gen_dir_under_regular_file_fails/1,
    carrier_path_is_directory_fails/1,
    po_path_is_directory_read_fails/1,
    malformed_po_parse_fails/1,
    orphan_carrier_undeletable_prune_fails/1,
    %% Folded key check: extract failure, unknown domain, strict-from-config.
    extract_project_error_propagates/1,
    call_site_domain_absent_from_universe_skipped/1,
    key_check_strict_config_policy/1
]).

%% `compile_and_load/1` is the dynamic-module load helper: `compile:file`/
%% `code:load_binary` return wide union types eqwalizer cannot statically
%% narrow, so quarantine it with a static annotation — the same zero-runtime-dep
%% pattern used in the runtime modules `erli18n_server`/`erli18n_pt_store`.
%% (A wild attribute must precede the first function definition.)
-eqwalizer({nowarn_function, compile_and_load/1}).

all() ->
    [
        absent_gate_is_noop_writes_nothing,
        false_gate_is_noop_writes_nothing,
        no_key_check_overrides_strict,
        unknown_key_check_normalizes_to_warn,
        default_excludes_fuzzy_entries,
        scoped_build_preserves_other_domain_carrier,
        invalid_compiled_domains_aborts_loudly,
        four_providers_unaffected_by_fifth,
        non_list_config_is_noop,
        non_boolean_include_fuzzy_uses_default,
        non_list_gen_dir_uses_default,
        absolute_gen_dir_used_verbatim,
        relative_gen_dir_without_project_apps_uses_state_dir,
        compiled_domains_list_scopes_build,
        non_list_compiled_domains_aborts,
        cli_domain_intersects_config_scope,
        gen_dir_under_regular_file_fails,
        carrier_path_is_directory_fails,
        po_path_is_directory_read_fails,
        malformed_po_parse_fails,
        orphan_carrier_undeletable_prune_fails,
        extract_project_error_propagates,
        call_site_domain_absent_from_universe_skipped,
        key_check_strict_config_policy
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    ok.

init_per_testcase(TC, Config) ->
    Proj = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    SrcDir = filename:join([Proj, "src"]),
    ok = filelib:ensure_path(SrcDir),
    [{proj, Proj}, {src_dir, SrcDir} | Config].

end_per_testcase(_TC, _Config) ->
    [ok = erli18n_server:unload(D, L) || {D, L, _N} <- erli18n_server:loaded_catalogs()],
    ok.

%% =========================
%% Opt-in master gate (get_config/3 exercised)
%% =========================

absent_gate_is_noop_writes_nothing(Config) ->
    %% No `compiled_catalogs` key at all: get_config/3 returns the [] default,
    %% the provider is a no-op and writes nothing — even though a .po exists.
    write_po(Config, "fr", "default", simple_po()),
    {ok, _} = run(Config, [], []),
    ?assertNot(filelib:is_dir(gen_dir(Config))),
    ?assertEqual([], carriers(Config)).

false_gate_is_noop_writes_nothing(Config) ->
    %% Present but false: still a no-op.
    write_po(Config, "fr", "default", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, false}]),
    ?assertNot(filelib:is_dir(gen_dir(Config))),
    ?assertEqual([], carriers(Config)).

%% =========================
%% Policy precedence + normalisation
%% =========================

no_key_check_overrides_strict(Config) ->
    %% A call site ("Absent") with no compiled key WOULD fail under strict, but
    %% --no-key-check takes precedence over --strict, so the build SUCCEEDS and
    %% still generates the carrier.
    write_consumer(Config, gettext_module([<<"Present">>, <<"Absent">>])),
    write_po(Config, "fr", "default", po([singular(<<"Present">>, <<"Presente">>)])),
    {ok, _} = run(Config, [{strict, true}, {no_key_check, true}], [{compiled_catalogs, true}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))).

unknown_key_check_normalizes_to_warn(Config) ->
    %% An unknown {key_check, _} atom degrades to warn: a missing key is logged,
    %% not fatal, so the build succeeds and the carrier is generated.
    write_consumer(Config, gettext_module([<<"Present">>, <<"Absent">>])),
    write_po(Config, "fr", "default", po([singular(<<"Present">>, <<"Presente">>)])),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}, {key_check, banana}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))).

default_excludes_fuzzy_entries(Config) ->
    %% include_fuzzy defaults to false: a #, fuzzy entry is dropped from the
    %% generated carrier's entries (parity with msgfmt / the runtime default).
    write_po(Config, "fr", "default", fuzzy_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    Mod = compile_and_load(carrier_path(Config, default, <<"fr">>)),
    {_D, _L, Entries, _H} = Mod:catalog(),
    Msgids = [element(3, E) || E <- Entries],
    ?assert(lists:member(<<"Hello">>, Msgids)),
    ?assertNot(lists:member(<<"Draft">>, Msgids)).

%% =========================
%% Scope safety (prune + config validation)
%% =========================

scoped_build_preserves_other_domain_carrier(Config) ->
    %% A full build generates carriers for BOTH domains; a later SCOPED build
    %% (--domain default) must NOT prune the `errors` carrier whose .po is
    %% intact. Pruning is a whole-tree step reserved for full builds, so a
    %% partial rebuild never deletes the out-of-scope domain's carrier.
    write_po(Config, "fr", "default", simple_po()),
    write_po(Config, "fr", "errors", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))),
    ?assert(filelib:is_file(carrier_path(Config, errors, <<"fr">>))),
    %% Scoped rebuild of `default` only — the `errors` carrier survives.
    {ok, _} = run(Config, [{domain, "default"}], [{compiled_catalogs, true}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))),
    ?assert(filelib:is_file(carrier_path(Config, errors, <<"fr">>))).

invalid_compiled_domains_aborts_loudly(Config) ->
    %% A string typo in {compiled_domains, [...]} (["default"] instead of the
    %% atom [default]) is a config error: the build FAILS LOUDLY and deletes
    %% NOTHING, rather than silently scoping to [] and pruning every carrier.
    write_po(Config, "fr", "default", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    Carrier = carrier_path(Config, default, <<"fr">>),
    ?assert(filelib:is_file(Carrier)),
    {error, Msg} = run(
        Config, [], [{compiled_catalogs, true}, {compiled_domains, ["default"]}]
    ),
    ?assert(is_list(Msg)),
    ?assertNotEqual(nomatch, string:find(Msg, "compiled_domains")),
    %% No silent wipe: the previously generated carrier is untouched.
    ?assert(filelib:is_file(Carrier)).

%% =========================
%% The four pre-existing providers are unaffected
%% =========================

four_providers_unaffected_by_fifth(Config) ->
    %% With `compile` registered alongside them, extract -> merge -> check ->
    %% report behave identically: extract writes the .pot, merge creates the
    %% .po, check passes against the fresh catalog, report runs.
    write_consumer(Config, gettext_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(base_state(Config, [])),
    ?assert(filelib:is_file(filename:join([pot_dir(Config), "default.pot"]))),
    {ok, _} = rebar3_erli18n_prv_merge:do(base_state(Config, [{locale, "pt_BR"}])),
    ?assert(filelib:is_file(po_path(Config, "pt_BR", "default"))),
    {ok, _} = rebar3_erli18n_prv_check:do(base_state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_report:do(base_state(Config, [])).

%% =========================
%% State + run helpers
%% =========================

base_state(Config, Args) ->
    Proj = ?config(proj, Config),
    {ok, App} = rebar_app_info:new(myapp, "0.1.0", Proj),
    St0 = rebar_state:new(),
    St1 = rebar_state:project_apps(St0, [App]),
    rebar_state:command_parsed_args(St1, {Args, []}).

state(Config, Args, CfgProps) ->
    rebar_state:set(base_state(Config, Args), erli18n, CfgProps).

run(Config, Args, CfgProps) ->
    rebar3_erli18n_prv_compile:do(state(Config, Args, CfgProps)).

%% =========================
%% Carrier load
%% =========================

compile_and_load(Path) ->
    Opts = [binary, debug_info, return_errors, warnings_as_errors],
    case compile:file(Path, Opts) of
        {ok, Mod, Beam} ->
            _ = code:purge(Mod),
            {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Beam),
            Mod;
        Other ->
            ct:fail({carrier_compile_failed, Path, Other})
    end.

%% =========================
%% Fixtures + paths
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

po_header() ->
    <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"MIME-Version: 1.0\\n\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Content-Transfer-Encoding: 8bit\\n\"\n"
        "\n"
    >>.

po(BodyEntries) ->
    iolist_to_binary([po_header() | BodyEntries]).

singular(Msgid, Msgstr) ->
    ["msgid \"", Msgid, "\"\nmsgstr \"", Msgstr, "\"\n\n"].

fuzzy_singular(Msgid, Msgstr) ->
    ["#, fuzzy\nmsgid \"", Msgid, "\"\nmsgstr \"", Msgstr, "\"\n\n"].

simple_po() ->
    po([singular(<<"Hello">>, <<"Bonjour">>)]).

fuzzy_po() ->
    po([singular(<<"Hello">>, <<"Bonjour">>), fuzzy_singular(<<"Draft">>, <<"Brouillon">>)]).

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
%% Config-partition fallbacks + I/O error paths
%% =========================
%%
%% These pin the compile provider's defensive branches with STRUCTURAL tests:
%% real misconfiguration values threaded through the public `do/1`, and real
%% filesystem conditions (a path that is a directory, a parent that is a
%% regular file) to force `file:read_file`/`write_file`/`delete` errors —
%% root-proof, unlike a `chmod`-based fault a privileged CI bypasses.

%% -- Config-partition fallbacks --

non_list_config_is_noop(Config) ->
    %% A non-list `erli18n` config (a misconfiguration) degrades to all-defaults
    %% via config/1, so `compiled_catalogs` is absent and do/1 is a no-op.
    write_po(Config, "fr", "default", simple_po()),
    St = rebar_state:set(base_state(Config, []), erli18n, not_a_proplist),
    ?assertMatch({ok, _}, rebar3_erli18n_prv_compile:do(St)),
    ?assertEqual([], carriers(Config)).

non_boolean_include_fuzzy_uses_default(Config) ->
    %% A non-boolean {include_fuzzy, _} degrades to the default (false) via
    %% cfg_bool/3, so a `#, fuzzy` entry is still excluded and the build succeeds.
    write_po(Config, "fr", "default", fuzzy_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}, {include_fuzzy, not_a_boolean}]),
    Mod = compile_and_load(carrier_path(Config, default, <<"fr">>)),
    {_D, _L, Entries, _H} = Mod:catalog(),
    Msgids = [element(3, E) || E <- Entries],
    ?assert(lists:member(<<"Hello">>, Msgids)),
    ?assertNot(lists:member(<<"Draft">>, Msgids)).

non_list_gen_dir_uses_default(Config) ->
    %% A non-list {gen_dir, _} degrades to the default "src/erli18n_gen".
    write_po(Config, "fr", "default", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}, {gen_dir, not_a_list}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))).

absolute_gen_dir_used_verbatim(Config) ->
    %% An absolute {gen_dir, _} is used verbatim (no root-dir join).
    write_po(Config, "fr", "default", simple_po()),
    AbsGen = filename:join(?config(priv_dir, Config), "abs_gen_dir"),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}, {gen_dir, AbsGen}]),
    Mod = rebar3_erli18n_codegen:module_name(<<"default">>, <<"fr">>),
    ?assert(filelib:is_file(filename:join(AbsGen, binary_to_list(Mod) ++ ".erl"))).

relative_gen_dir_without_project_apps_uses_state_dir(Config) ->
    %% With NO project apps, a relative gen_dir resolves against the state dir
    %% (root_dir/1's [] branch). Drive a bare state whose --pot-dir points at a
    %% fixture with one catalog and whose state dir is a writable temp.
    Fixture = filename:join(?config(priv_dir, Config), "bare_pot"),
    PoPath = filename:join([Fixture, "fr", "LC_MESSAGES", "default.po"]),
    ok = filelib:ensure_dir(PoPath),
    ok = file:write_file(PoPath, simple_po()),
    StateDir = filename:join(?config(priv_dir, Config), "bare_state"),
    ok = filelib:ensure_path(StateDir),
    St0 = rebar_state:dir(rebar_state:new(), StateDir),
    St1 = rebar_state:command_parsed_args(St0, {[{pot_dir, Fixture}], []}),
    St = rebar_state:set(St1, erli18n, [{compiled_catalogs, true}]),
    ?assertMatch({ok, _}, rebar3_erli18n_prv_compile:do(St)),
    Mod = rebar3_erli18n_codegen:module_name(<<"default">>, <<"fr">>),
    ?assert(
        filelib:is_file(
            filename:join([StateDir, "src", "erli18n_gen", binary_to_list(Mod) ++ ".erl"])
        )
    ).

compiled_domains_list_scopes_build(Config) ->
    %% {compiled_domains, [default]} (base_scope's atom-list branch) scopes
    %% codegen to `default`; the `errors` catalog is not built.
    write_po(Config, "fr", "default", simple_po()),
    write_po(Config, "fr", "errors", simple_po()),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}, {compiled_domains, [default]}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))),
    ?assertNot(filelib:is_file(carrier_path(Config, errors, <<"fr">>))).

non_list_compiled_domains_aborts(Config) ->
    %% A non-list, non-`all` {compiled_domains, _} is a config error (base_scope's
    %% Other branch): the build FAILS LOUDLY rather than scoping to nothing.
    write_po(Config, "fr", "default", simple_po()),
    {error, Msg} = run(Config, [], [{compiled_catalogs, true}, {compiled_domains, not_a_list}]),
    ?assert(is_list(Msg)),
    ?assertNotEqual(nomatch, string:find(Msg, "compiled_domains")).

cli_domain_intersects_config_scope(Config) ->
    %% --domain intersects a {compiled_domains, [..]} config scope
    %% (apply_cli_domain's {only, _} branch): config [default, errors] with
    %% --domain default builds only `default`.
    write_po(Config, "fr", "default", simple_po()),
    write_po(Config, "fr", "errors", simple_po()),
    {ok, _} = run(
        Config,
        [{domain, "default"}],
        [{compiled_catalogs, true}, {compiled_domains, [default, errors]}]
    ),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))),
    ?assertNot(filelib:is_file(carrier_path(Config, errors, <<"fr">>))).

%% -- I/O error paths (root-proof filesystem faults) --

gen_dir_under_regular_file_fails(Config) ->
    %% gen_dir whose PARENT is a regular file: ensure_path -> {error, enotdir},
    %% surfaced as a build error (ensure_gen_dir -> chain -> maybe_write -> do/1).
    write_po(Config, "fr", "default", simple_po()),
    Blocker = filename:join(?config(priv_dir, Config), "gen_blocker_file"),
    ok = file:write_file(Blocker, <<>>),
    GenUnderFile = filename:join(Blocker, "erli18n_gen"),
    ?assertMatch(
        {error, _},
        run(Config, [], [{compiled_catalogs, true}, {gen_dir, GenUnderFile}])
    ).

carrier_path_is_directory_fails(Config) ->
    %% The carrier output path pre-exists as a DIRECTORY: file:write_file ->
    %% {error, eisdir}, surfaced by write_modules -> do/1.
    write_po(Config, "fr", "default", simple_po()),
    ok = filelib:ensure_path(gen_dir(Config)),
    ok = filelib:ensure_path(carrier_path(Config, default, <<"fr">>)),
    ?assertMatch({error, _}, run(Config, [], [{compiled_catalogs, true}])).

po_path_is_directory_read_fails(Config) ->
    %% A discovered `*.po` that is actually a DIRECTORY: file:read_file ->
    %% {error, eisdir}, surfaced by build_one -> do/1.
    ok = filelib:ensure_path(po_path(Config, "fr", "default")),
    ?assertMatch({error, _}, run(Config, [], [{compiled_catalogs, true}])).

malformed_po_parse_fails(Config) ->
    %% A `.po` with an unknown escape (\q): erli18n_po:parse -> {error, _},
    %% surfaced by build_one -> do/1 as a loud build failure.
    write_po(Config, "fr", "default", po([["msgid \"Hi\"\nmsgstr \"\\q\"\n\n"]])),
    ?assertMatch({error, _}, run(Config, [], [{compiled_catalogs, true}])).

orphan_carrier_undeletable_prune_fails(Config) ->
    %% A full build prunes orphaned carriers; an orphan that is a non-empty
    %% DIRECTORY cannot be file:delete'd -> {error, _}, surfaced by delete_all.
    write_po(Config, "fr", "default", simple_po()),
    ok = filelib:ensure_path(gen_dir(Config)),
    OrphanDir = filename:join(gen_dir(Config), "erli18n_cc_ghost__zz.erl"),
    ok = filelib:ensure_path(OrphanDir),
    ok = file:write_file(filename:join(OrphanDir, "keep"), <<>>),
    ?assertMatch({error, _}, run(Config, [], [{compiled_catalogs, true}])).

%% -- Folded key check: extract failure, unknown domain, strict-from-config --

extract_project_error_propagates(Config) ->
    %% The folded key check extracts the project's call sites; a source path that
    %% `epp:open` cannot open (here a `*.erl` that is actually a DIRECTORY) makes
    %% extract_project/1 fail, surfaced by run_key_check (carriers are written
    %% first, then the check fails loudly). A mere syntax error would NOT do it —
    %% the extractor skips unparseable forms; only an unopenable file errors.
    write_po(Config, "fr", "default", simple_po()),
    ConsumerAsDir = filename:join(?config(src_dir, Config), "myapp_strings.erl"),
    ok = filelib:ensure_path(ConsumerAsDir),
    ?assertMatch({error, _}, run(Config, [], [{compiled_catalogs, true}])).

call_site_domain_absent_from_universe_skipped(Config) ->
    %% A call site in a domain with NO compiled catalog (dgettext(ghost, _)) is
    %% dropped from the atom-keyed universe (atom_keyed_universe's `error`
    %% branch) and never flagged, so the warn-policy build succeeds.
    write_po(Config, "fr", "default", simple_po()),
    write_consumer(Config, <<
        "-module(myapp_strings).\n"
        "-export([f/0]).\n"
        "f() -> erli18n:dgettext(ghost, <<\"X\">>).\n"
    >>),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))).

key_check_strict_config_policy(Config) ->
    %% {key_check, strict} in config (no CLI override) resolves via
    %% normalize_policy(strict); with every call-site key present the strict
    %% check passes and the build succeeds.
    write_consumer(Config, gettext_module([<<"Present">>])),
    write_po(Config, "fr", "default", po([singular(<<"Present">>, <<"Presente">>)])),
    {ok, _} = run(Config, [], [{compiled_catalogs, true}, {key_check, strict}]),
    ?assert(filelib:is_file(carrier_path(Config, default, <<"fr">>))).
