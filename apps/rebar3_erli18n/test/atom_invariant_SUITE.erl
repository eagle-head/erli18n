-module(atom_invariant_SUITE).

-moduledoc """
Invariant-proof suite for the compile-time catalog machinery (.po -> BEAM).

The central invariant: NO atom-CREATING BIF — `binary_to_atom/1,2`,
`list_to_atom/1`, `binary_to_term/1,2` — is reachable from filesystem/CLI/runtime
input anywhere in the `rebar3_erli18n` plugin or the `erli18n` runtime
registration path. (`binary_to_existing_atom`/`list_to_existing_atom` are NOT
forbidden — they intern nothing.) The carrier's two dynamic atoms (its module
name and its domain) are interned ONLY by the COMPILER/loader from bounded
developer-controlled source text emitted by `rebar3_erli18n_codegen`.

This suite carries the guarantee with two AUTHORITATIVE static proofs and four
corroborating dynamic ones, all under plain Common Test (no ELP/eqWAlizer):

- (A) `no_atom_creating_bifs_in_plugin` — abstract-code scan over the COMPLETE,
  dynamically enumerated plugin module set plus `erli18n_compiled`/
  `erli18n_server`: ZERO bare or `erlang:`-remote call nodes to the three
  forbidden BIFs.
- (A2) `no_atom_creating_bif_edges_xref` — an xref call-graph cross-check: no
  edge into the forbidden BIFs has a guarded module as its source.
- (B) `render_does_not_intern_fresh_domain` / (B2) `render_does_not_intern_module_name`
  — direct witnesses that `render/2` and `module_name/2` leave a fresh domain
  and a fresh carrier module name UN-interned.
- (C) `render_creates_no_atoms` — a corroborating `atom_count` probe with a
  sensitivity anchor.
- (D) `plugin_pipeline_creates_no_atoms` /
  `plugin_pipeline_config_scope_creates_no_atoms` /
  `plugin_pipeline_all_scope_creates_no_atoms` — the discovery/scope pipeline
  interns nothing from a fresh filesystem domain name, across all three scope
  branches: the `--domain` CLI pin, the `{compiled_domains, _}` config scope,
  and the unrestricted all-scope.

A/A2/B/B2 carry the guarantee; C/D corroborate it.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    no_atom_creating_bifs_in_plugin/1,
    no_atom_creating_bif_edges_xref/1,
    render_does_not_intern_fresh_domain/1,
    render_does_not_intern_module_name/1,
    render_creates_no_atoms/1,
    plugin_pipeline_creates_no_atoms/1,
    plugin_pipeline_config_scope_creates_no_atoms/1,
    plugin_pipeline_all_scope_creates_no_atoms/1
]).

%% `xref_offenders/0` reads `xref:q/2`'s wide result, which eqwalizer cannot
%% statically narrow, so it is quarantined with a static `-eqwalizer` nowarn —
%% the zero-runtime-dep pattern used across the runtime modules and the other
%% plugin suites. (`assert_no_atom_creating_bif/1` needs no nowarn: it reads the
%% beam via `code:get_object_code/1` and matches the `abstract_code` chunk
%% explicitly, so eqwalizer narrows it.) A wild attribute must precede the first
%% function definition, so the block lives here.
-eqwalizer({nowarn_function, xref_offenders/0}).

%% The atom-CREATING BIFs forbidden on any filesystem/CLI/runtime-input path.
-define(FORBIDDEN_BIFS, [binary_to_atom, list_to_atom, binary_to_term]).

%% Number of fresh catalogs rendered in the `atom_count` probe (C), and of fresh
%% atoms interned by its sensitivity anchor.
-define(PROBE_K, 200).

all() ->
    [
        no_atom_creating_bifs_in_plugin,
        no_atom_creating_bif_edges_xref,
        render_does_not_intern_fresh_domain,
        render_does_not_intern_module_name,
        render_creates_no_atoms,
        plugin_pipeline_creates_no_atoms,
        plugin_pipeline_config_scope_creates_no_atoms,
        plugin_pipeline_all_scope_creates_no_atoms
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erli18n),
    _ = application:load(rebar3_erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%% =========================
%% (A) Static abstract-code scan — AUTHORITATIVE
%% =========================

%% Walk every form of every plugin module (dynamically enumerated) plus the two
%% runtime registration-path modules and assert ZERO call nodes — bare
%% `{call,_,{atom,_,F},_}` OR remote `{call,_,{remote,_,{atom,_,erlang},
%% {atom,_,F}},_}` — name a forbidden atom-creating BIF.
no_atom_creating_bifs_in_plugin(_Config) ->
    Plugin = plugin_modules(),
    %% GUARD-THE-GUARD: the dynamic enumeration must be non-empty AND must
    %% actually contain the modules this proof is about, so a broken enumeration
    %% (or a renamed module) fails loudly instead of vacuously passing.
    ?assert(Plugin =/= []),
    Required = [
        rebar3_erli18n_codegen,
        rebar3_erli18n_prv_compile,
        rebar3_erli18n_keycheck,
        rebar3_erli18n_common,
        rebar3_erli18n_extract_forms,
        rebar3_erli18n_keywords
    ],
    ?assert(lists:all(fun(F) -> lists:member(F, Plugin) end, Required)),
    Targets = Plugin ++ [erli18n_compiled, erli18n_server],
    lists:foreach(fun assert_no_atom_creating_bif/1, Targets).

%% Every module of the loaded `rebar3_erli18n` application EXCEPT the generated
%% `erli18n_cc_*` carriers (whose dynamic atoms are compiler-interned by design).
-spec plugin_modules() -> [module()].
plugin_modules() ->
    {ok, Ms} = application:get_key(rebar3_erli18n, modules),
    [M || M <- Ms, not lists:prefix("erli18n_cc_", atom_to_list(M))].

%% Load a module's `abstract_code` chunk and assert no form contains a call to a
%% forbidden BIF.
assert_no_atom_creating_bif(Mod) ->
    %% Read the ORIGINAL on-disk `.beam` via `code:get_object_code/1` rather than
    %% `code:which/1` + a file read: under `rebar3 ct --cover` (the gate lane)
    %% the module is cover-compiled, so `code:which/1` returns the atom
    %% `cover_compiled` (no file on disk) and `beam_lib` fails with `enoent`.
    %% `code:get_object_code/1` reads the unmodified `.beam` from the code path
    %% (cover instruments the in-memory module, never the on-disk file), so its
    %% `debug_info` `abstract_code` chunk is present whether or not cover is on.
    case code:get_object_code(Mod) of
        {Mod, Beam, _Filename} ->
            case beam_lib:chunks(Beam, [abstract_code]) of
                {ok, {Mod, [{abstract_code, {_Tag, Forms}}]}} ->
                    walk_forms(Mod, Forms);
                Other ->
                    ct:fail({no_abstract_code, Mod, Other})
            end;
        error ->
            ct:fail({no_object_code, Mod})
    end.

%% Recursively walk an abstract term, checking each tuple node for a forbidden
%% call and descending through every tuple element and list cell.
walk_forms(Mod, Term) when is_tuple(Term) ->
    assert_not_forbidden_call(Mod, Term),
    walk_forms(Mod, tuple_to_list(Term));
walk_forms(Mod, [H | T]) ->
    walk_forms(Mod, H),
    walk_forms(Mod, T);
walk_forms(_Mod, _Leaf) ->
    ok.

%% A bare local call to a forbidden BIF, or an `erlang:`-qualified remote call to
%% one, is a hard failure; anything else passes.
assert_not_forbidden_call(Mod, {call, _A, {atom, _B, Fun}, _Args}) ->
    fail_if_forbidden(Mod, Fun);
assert_not_forbidden_call(
    Mod, {call, _A, {remote, _B, {atom, _C, erlang}, {atom, _D, Fun}}, _Args}
) ->
    fail_if_forbidden(Mod, Fun);
assert_not_forbidden_call(_Mod, _Node) ->
    ok.

-spec fail_if_forbidden(module(), atom()) -> ok.
fail_if_forbidden(Mod, Fun) ->
    case lists:member(Fun, ?FORBIDDEN_BIFS) of
        true -> ct:fail({forbidden_atom_creating_bif, Mod, Fun});
        false -> ok
    end.

%% =========================
%% (A2) Xref call-graph cross-check — MANDATORY
%% =========================

%% No edge into any forbidden atom-creating BIF originates from a guarded module
%% (a `rebar3_erli18n*` plugin module, or `erli18n_compiled`/`erli18n_server`).
no_atom_creating_bif_edges_xref(_Config) ->
    ?assertEqual([], xref_offenders()).

%% The guarded-module sources of every call edge into the forbidden BIFs,
%% computed over the two project applications. An absent BIF vertex contributes
%% no edge (the query yields `{ok, []}`), so a clean graph yields `[]`.
xref_offenders() ->
    Server = erli18n_atom_invariant_xref,
    {ok, _} = xref:start(Server),
    try
        {ok, _} = xref:add_application(Server, code:lib_dir(rebar3_erli18n)),
        {ok, _} = xref:add_application(Server, code:lib_dir(erli18n)),
        Query =
            "E || (erlang:binary_to_atom/2 + erlang:list_to_atom/1 + "
            "erlang:binary_to_term/1 + erlang:binary_to_term/2)",
        {ok, Edges} = xref:q(Server, Query),
        lists:usort([Src || {{Src, _F, _A}, _To} <- Edges, is_guarded_module(Src)])
    after
        xref:stop(Server)
    end.

%% True for the modules the invariant covers: the plugin namespace plus the two
%% runtime registration-path modules.
-spec is_guarded_module(module()) -> boolean().
is_guarded_module(Mod) ->
    lists:prefix("rebar3_erli18n", atom_to_list(Mod)) orelse
        lists:member(Mod, [erli18n_compiled, erli18n_server]).

%% =========================
%% (B/B2) Direct render witnesses
%% =========================

%% Rendering a catalog whose domain has never been interned does NOT intern it:
%% `binary_to_existing_atom` of that fresh domain raises `badarg` both before AND
%% after `render/2` (the carrier's atom is interned by the compiler, never here).
render_does_not_intern_fresh_domain(_Config) ->
    _ = warm_up_render(),
    Uniq = uniq_bin(),
    Domain = <<"zzdom_", Uniq/binary>>,
    Locale = <<"zzloc_", Uniq/binary>>,
    ?assertError(badarg, binary_to_existing_atom(Domain, utf8)),
    Spec = {Domain, Locale, sample_entries(), fallback_header()},
    _ = rebar3_erli18n_codegen:render(Spec, #{}),
    ?assertError(badarg, binary_to_existing_atom(Domain, utf8)).

%% Direct witness: `module_name/2` returns a BINARY and interns no atom, so
%% the fresh carrier module name is un-interned before AND after a render.
render_does_not_intern_module_name(_Config) ->
    _ = warm_up_render(),
    Uniq = uniq_bin(),
    Domain = <<"zzdom2_", Uniq/binary>>,
    Locale = <<"zzloc2_", Uniq/binary>>,
    ModBin = rebar3_erli18n_codegen:module_name(Domain, Locale),
    ?assert(is_binary(ModBin)),
    ?assertError(badarg, binary_to_existing_atom(ModBin, utf8)),
    Spec = {Domain, Locale, sample_entries(), fallback_header()},
    _ = rebar3_erli18n_codegen:render(Spec, #{}),
    ?assertError(badarg, binary_to_existing_atom(ModBin, utf8)).

%% =========================
%% (C) Atom-count probe — CORROBORATING
%% =========================

%% After warming up every quoting branch, rendering `?PROBE_K` fresh catalogs
%% (WITHOUT compiling them) interns ZERO atoms. The sensitivity anchor proves the
%% probe can detect interning: the SAME number of fresh names, fed through
%% `binary_to_atom`, raises the count by at least `?PROBE_K`.
render_creates_no_atoms(_Config) ->
    _ = warm_up_all_branches(),
    erlang:garbage_collect(),
    Before = erlang:system_info(atom_count),
    lists:foreach(
        fun(I) ->
            U = integer_to_binary(I),
            Spec =
                {<<"zzc_", U/binary>>, <<"zzcl_", U/binary>>, sample_entries(), fallback_header()},
            _ = rebar3_erli18n_codegen:render(Spec, #{})
        end,
        lists:seq(1, ?PROBE_K)
    ),
    ?assertEqual(Before, erlang:system_info(atom_count)),
    %% SENSITIVITY ANCHOR.
    BeforeSens = erlang:system_info(atom_count),
    _ = [
        binary_to_atom(<<"zzsens_", (integer_to_binary(I))/binary>>, utf8)
     || I <- lists:seq(1, ?PROBE_K)
    ],
    ?assert(erlang:system_info(atom_count) - BeforeSens >= ?PROBE_K).

%% =========================
%% (D) Plugin pipeline probe — CORROBORATING
%% =========================

%% Driving the provider's discovery/scope/CLI-domain pipeline (`domain_name`,
%% `scope_domains`/`base_scope`, `apply_cli_domain`) over a FRESH filesystem
%% domain name interns NO atom: the measured `do/1` run leaves `atom_count`
%% unchanged and leaves the fresh domain un-interned. The provider is driven
%% through its only public entry point (`do/1`); the internal helpers are
%% exercised end to end by the real `.po` discovery it performs.
plugin_pipeline_creates_no_atoms(Config) ->
    %% Warm up the whole pipeline twice so every lazily-loaded module/atom is
    %% already interned before the measured run.
    _ = run_pipeline(Config, "warm1", <<"zzwarma">>),
    _ = run_pipeline(Config, "warm2", <<"zzwarmb">>),
    erlang:garbage_collect(),
    Uniq = uniq_bin(),
    Domain = <<"zzdomd_", Uniq/binary>>,
    ?assertError(badarg, binary_to_existing_atom(Domain, utf8)),
    Before = erlang:system_info(atom_count),
    {ok, _St} = run_pipeline(Config, "measured", Domain),
    ?assertEqual(Before, erlang:system_info(atom_count)),
    ?assertError(badarg, binary_to_existing_atom(Domain, utf8)).

%% Build a throwaway project under `priv_dir` carrying a single `.po` for the
%% fresh `Domain` (locale `en`), then run `rebar3_erli18n_prv_compile:do/1` with
%% the `--domain` CLI override set (so `apply_cli_domain` runs the binary path)
%% and the key check off (so nothing else interns from extraction).
run_pipeline(Config, Tag, Domain) ->
    Proj = filename:join(?config(priv_dir, Config), Tag),
    PoPath = filename:join([
        Proj, "priv", "gettext", "en", "LC_MESSAGES", binary_to_list(Domain) ++ ".po"
    ]),
    ok = filelib:ensure_dir(PoPath),
    ok = file:write_file(PoPath, sample_po()),
    {ok, App} = rebar_app_info:new(zz_invariant_app, "0.1.0", Proj),
    St0 = rebar_state:new(),
    St1 = rebar_state:project_apps(St0, [App]),
    Args = [{domain, binary_to_list(Domain)}],
    St2 = rebar_state:command_parsed_args(St1, {Args, []}),
    St3 = rebar_state:set(St2, erli18n, [{compiled_catalogs, true}, {key_check, off}]),
    rebar3_erli18n_prv_compile:do(St3).

%% Driving the provider with a `{compiled_domains, _}` config scope (and NO
%% `--domain`) interns NO atom: `base_scope` filters through its `{only, _}`
%% branch, in-scope domains render from binary names, and a fresh out-of-scope
%% filesystem domain is dropped without ever being interned. The in-scope
%% domains (`default`, `messages`) are literal atoms here, so they pre-exist;
%% the measurement proves nothing NEW is interned.
plugin_pipeline_config_scope_creates_no_atoms(Config) ->
    Scoped = fun(Tag, Domains) ->
        run_scoped(Config, Tag, Domains, [
            {compiled_catalogs, true}, {key_check, off}, {compiled_domains, [default, messages]}
        ])
    end,
    _ = Scoped("cfgwarm1", [<<"default">>, <<"messages">>]),
    _ = Scoped("cfgwarm2", [<<"default">>, <<"messages">>]),
    erlang:garbage_collect(),
    Uniq = uniq_bin(),
    Fresh = <<"zzcfg_", Uniq/binary>>,
    ?assertError(badarg, binary_to_existing_atom(Fresh, utf8)),
    Before = erlang:system_info(atom_count),
    {ok, _St} = Scoped("cfgmeasured", [<<"default">>, <<"messages">>, Fresh]),
    ?assertEqual(Before, erlang:system_info(atom_count)),
    ?assertError(badarg, binary_to_existing_atom(Fresh, utf8)).

%% Driving the provider with NO `compiled_domains` and NO `--domain` interns NO
%% atom: `base_scope` yields `all`, so discovery walks EVERY domain — including
%% a fresh filesystem name, which is rendered — yet interns nothing from it.
plugin_pipeline_all_scope_creates_no_atoms(Config) ->
    AllCfg = [{compiled_catalogs, true}, {key_check, off}],
    _ = run_scoped(Config, "allwarm1", [<<"default">>], AllCfg),
    _ = run_scoped(Config, "allwarm2", [<<"default">>], AllCfg),
    erlang:garbage_collect(),
    Uniq = uniq_bin(),
    Fresh = <<"zzall_", Uniq/binary>>,
    ?assertError(badarg, binary_to_existing_atom(Fresh, utf8)),
    Before = erlang:system_info(atom_count),
    {ok, _St} = run_scoped(Config, "allmeasured", [<<"default">>, Fresh], AllCfg),
    ?assertEqual(Before, erlang:system_info(atom_count)),
    ?assertError(badarg, binary_to_existing_atom(Fresh, utf8)).

%% Build a throwaway project carrying one `.po` per domain in `Domains` (locale
%% `en`) and run `rebar3_erli18n_prv_compile:do/1` with the given `erli18n`
%% config and NO `--domain` override, so `base_scope` drives the scope (`all`
%% or `{only, _}`) directly rather than the CLI pin.
run_scoped(Config, Tag, Domains, Cfg) ->
    Proj = filename:join(?config(priv_dir, Config), Tag),
    lists:foreach(
        fun(Domain) ->
            PoPath = filename:join([
                Proj, "priv", "gettext", "en", "LC_MESSAGES", binary_to_list(Domain) ++ ".po"
            ]),
            ok = filelib:ensure_dir(PoPath),
            ok = file:write_file(PoPath, sample_po())
        end,
        Domains
    ),
    {ok, App} = rebar_app_info:new(zz_invariant_app, "0.1.0", Proj),
    St0 = rebar_state:new(),
    St1 = rebar_state:project_apps(St0, [App]),
    St2 = rebar_state:command_parsed_args(St1, {[], []}),
    St3 = rebar_state:set(St2, erli18n, Cfg),
    rebar3_erli18n_prv_compile:do(St3).

%% =========================
%% Helpers
%% =========================

%% A process-unique binary suffix, so fresh domain/locale names never collide
%% with an atom interned by an earlier case or run.
-spec uniq_bin() -> binary().
uniq_bin() ->
    integer_to_binary(erlang:unique_integer([positive])).

%% A single singular entry — enough to exercise the entry-rendering path. The
%% `~"..."` sigil yields a proper UTF-8 binary regardless of source coding.
sample_entries() ->
    [{singular, undefined, ~"Hello", ~"Olá"}].

%% A `baked_header()` with the `fallback` plural (no Plural-Forms), so a render
%% performs no plural work and a pipeline run raises no divergence warning.
fallback_header() ->
    #{
        plural => fallback,
        plural_raw => <<"nplurals=2; plural=(n != 1);">>,
        po_path => "priv/gettext/en/LC_MESSAGES/zz.po",
        divergence => none,
        fuzzy_included => false,
        num_entries => 1
    }.

%% A minimal valid `.po` (no Plural-Forms header) for the pipeline probe.
sample_po() ->
    <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"MIME-Version: 1.0\\n\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Content-Transfer-Encoding: 8bit\\n\"\n"
        "\n"
        "msgid \"Hello\"\n"
        "msgstr \"Bonjour\"\n"
        "\n"
    >>.

%% Warm up `render/2` once (loading erl_pp/erl_parse/unicode and interning their
%% fixed atoms) before an atom-sensitive measurement.
warm_up_render() ->
    Spec = {<<"default">>, <<"en">>, sample_entries(), fallback_header()},
    rebar3_erli18n_codegen:render(Spec, #{}).

%% Warm up render across every quoting branch (reserved word, metachars, embedded
%% quote/backslash, unicode, control bytes, empty) and both eqwalizer options, so
%% the (C) probe measures a fully steady atom table.
warm_up_all_branches() ->
    Domains = [
        ~"default",
        ~"if",
        ~"my-app",
        ~"a'b",
        ~"a\\b",
        ~"café",
        ~"ключ",
        ~"",
        <<0, 9, 127>>
    ],
    [
        rebar3_erli18n_codegen:render({D, <<"en">>, sample_entries(), fallback_header()}, Opts)
     || D <- Domains, Opts <- [#{}, #{eqwalizer_nowarn => false}]
    ].
