-module(erli18n_compiled_SUITE).

%% Functional Common Test suite for the consumer-side boot engine
%% `erli18n_compiled` (compile-time .po -> BEAM catalogs) and its façade door
%% `erli18n:register_compiled_catalogs/1`.
%%
%% Each case builds throwaway `erli18n_cc_*` carrier modules at runtime (per the
%% `erli18n_loader_SUITE` codegen precedent: build abstract forms, embed the
%% `compiled_spec()` literal via `erl_parse:abstract/2`, `compile:forms/2`, then
%% `code:load_binary/3`) and a throwaway application whose `modules` key lists
%% them, then drives `register/1` end to end and reads the catalogs back through
%% the lock-free `erli18n_server:lookup_*` hot path.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    register_installs_both_carriers/1,
    register_second_call_all_already/1,
    register_plural_carrier_is_evaluated/1,
    facade_register_compiled_catalogs_delegates/1,
    read_catalog_interns_no_atoms/1
]).

%% `build_carrier/3` is the dynamic-module load helper: `compile:forms`/
%% `code:load_binary` return wide union types eqwalizer cannot statically
%% narrow, so quarantine it with a static annotation — the same zero-runtime-dep
%% pattern used in the runtime modules `erli18n_server`/`erli18n_pt_store`.
%% (A wild attribute must precede the first function definition.)
-eqwalizer({nowarn_function, build_carrier/3}).

%% `compile_carrier/1` is the same dynamic-module load boundary (`compile:forms`/
%% `code:load_binary`), quarantined for the same reason.
-eqwalizer({nowarn_function, compile_carrier/1}).

all() ->
    [
        register_installs_both_carriers,
        register_second_call_all_already,
        register_plural_carrier_is_evaluated,
        facade_register_compiled_catalogs_delegates,
        read_catalog_interns_no_atoms
    ].

init_per_suite(Config) ->
    {ok, _Apps} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    ok.

init_per_testcase(_TC, Config) ->
    %% Start each case from a clean catalog set (mirror the loader suite).
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    Config.

end_per_testcase(_TC, _Config) ->
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    ok.

%% =========================
%% Test cases
%% =========================

%% Two carriers (different locales) listed in one throwaway app: a single
%% register/1 installs BOTH and both are queryable through the lock-free
%% read path.
register_installs_both_carriers(_Config) ->
    U = uniq(),
    ModFr = carrier_mod("fr", U),
    ModDe = carrier_mod("de", U),
    SpecFr =
        fallback_spec(default, ~"fr", [{singular, undefined, ~"Hello", ~"Bonjour"}], "fr.po"),
    SpecDe =
        fallback_spec(default, ~"de", [{singular, undefined, ~"Hello", ~"Hallo"}], "de.po"),
    ok = build_carrier(ModFr, true, SpecFr),
    ok = build_carrier(ModDe, true, SpecDe),
    App = load_app([ModFr, ModDe]),
    try
        Results = erli18n_compiled:register(App),
        ?assertEqual(2, length(Results)),
        ?assert(lists:member({default, ~"fr", {ok, 1}}, Results)),
        ?assert(lists:member({default, ~"de", {ok, 1}}, Results)),
        ?assertEqual(
            {ok, ~"Bonjour"},
            erli18n_server:lookup_singular(default, ~"fr", undefined, ~"Hello")
        ),
        ?assertEqual(
            {ok, ~"Hallo"},
            erli18n_server:lookup_singular(default, ~"de", undefined, ~"Hello")
        )
    after
        cleanup(App, [ModFr, ModDe])
    end.

%% Idempotency: a second register/1 of the same app reports {ok, already}
%% for every carrier (it reuses ensure_loaded semantics; nothing is
%% overwritten).
register_second_call_all_already(_Config) ->
    U = uniq(),
    ModFr = carrier_mod("fr", U),
    ModDe = carrier_mod("de", U),
    ok = build_carrier(
        ModFr, true, fallback_spec(default, ~"fr", [{singular, undefined, ~"k", ~"fr-k"}], "fr.po")
    ),
    ok = build_carrier(
        ModDe, true, fallback_spec(default, ~"de", [{singular, undefined, ~"k", ~"de-k"}], "de.po")
    ),
    App = load_app([ModFr, ModDe]),
    try
        First = erli18n_compiled:register(App),
        ?assert(lists:member({default, ~"fr", {ok, 1}}, First)),
        ?assert(lists:member({default, ~"de", {ok, 1}}, First)),
        Second = erli18n_compiled:register(App),
        ?assertEqual(
            [
                {default, ~"de", {ok, already}},
                {default, ~"fr", {ok, already}}
            ],
            lists:sort(Second)
        )
    after
        cleanup(App, [ModFr, ModDe])
    end.

%% A carrier baking a REAL compiled plural rule (n > 1) is registered and
%% the lock-free plural read evaluates it with NO boot-time compile.
register_plural_carrier_is_evaluated(_Config) ->
    U = uniq(),
    Mod = carrier_mod("pl", U),
    {ok, Compiled} = erli18n_plural:compile(~"nplurals=2; plural=(n > 1);"),
    Entries = [{plural, undefined, ~"file", ~"files", [{0, ~"fichier"}, {1, ~"fichiers"}]}],
    Spec =
        {default, ~"fr", Entries, #{
            plural => Compiled,
            plural_raw => ~"(n > 1)",
            po_path => "fr.po",
            divergence => none,
            fuzzy_included => false,
            num_entries => 1
        }},
    ok = build_carrier(Mod, true, Spec),
    App = load_app([Mod]),
    try
        ?assertEqual(
            [{default, ~"fr", {ok, 1}}],
            erli18n_compiled:register(App)
        ),
        ?assertEqual(
            {ok, ~"fichier"},
            erli18n_server:lookup_plural_form(default, ~"fr", undefined, ~"file", 1)
        ),
        ?assertEqual(
            {ok, ~"fichiers"},
            erli18n_server:lookup_plural_form(default, ~"fr", undefined, ~"file", 5)
        )
    after
        cleanup(App, [Mod])
    end.

%% The façade `erli18n:register_compiled_catalogs/1` is a thin delegate to
%% `erli18n_compiled:register/1` — same install, same return shape.
facade_register_compiled_catalogs_delegates(_Config) ->
    U = uniq(),
    Mod = carrier_mod("es", U),
    ok = build_carrier(
        Mod, true, fallback_spec(default, ~"es", [{singular, undefined, ~"Hi", ~"Hola"}], "es.po")
    ),
    App = load_app([Mod]),
    try
        ?assertEqual(
            [{default, ~"es", {ok, 1}}],
            erli18n:register_compiled_catalogs(App)
        ),
        ?assertEqual(
            {ok, ~"Hola"},
            erli18n_server:lookup_singular(default, ~"es", undefined, ~"Hi")
        )
    after
        cleanup(App, [Mod])
    end.

%% `read_catalog/1` is a pure literal read: it interns NO atom. A carrier built
%% from a FRESH binary domain has its domain atom interned by the COMPILER when
%% the carrier source is compiled; `read_catalog/1` then merely returns that
%% baked atom from the literal pool, leaving `atom_count` unchanged.
read_catalog_interns_no_atoms(_Config) ->
    U = uniq(),
    DomainBin = <<"zzrc_", (list_to_binary(U))/binary>>,
    %% Build a carrier by rendering source with the binary domain threaded
    %% through and letting `compile:forms` intern its dynamic atoms.
    Header = #{
        plural => fallback,
        plural_raw => ~"nplurals=2; plural=(n != 1);",
        po_path => "zz.po",
        divergence => none,
        fuzzy_included => false,
        num_entries => 1
    },
    Spec = {DomainBin, ~"en", [{singular, undefined, ~"Hello", ~"Hi"}], Header},
    {ModBin, Src} = rebar3_erli18n_codegen:render(Spec, #{}),
    Mod = compile_carrier(Src),
    ?assertEqual(ModBin, atom_to_binary(Mod, utf8)),
    try
        %% The compiler interned the domain atom from the carrier source, so it
        %% now exists — resolve it WITHOUT interning a fresh one.
        Domain = binary_to_existing_atom(DomainBin, utf8),
        Before = erlang:system_info(atom_count),
        {Domain2, _Locale, _Entries, _Hdr} = erli18n_compiled:read_catalog(Mod),
        ?assertEqual(Before, erlang:system_info(atom_count)),
        ?assertEqual(Domain, Domain2)
    after
        _ = code:purge(Mod),
        _ = code:delete(Mod)
    end.

%% =========================
%% Helpers
%% =========================

uniq() ->
    integer_to_list(erlang:unique_integer([positive])).

%% A carrier module atom name: prefixed `erli18n_cc_`, tagged + unique so
%% concurrent/sequential cases never collide.
carrier_mod(Tag, U) ->
    list_to_atom("erli18n_cc_" ++ Tag ++ "_" ++ U).

%% A throwaway app atom name.
app_name(U) ->
    list_to_atom("erli18n_cc_app_" ++ U).

fallback_spec(Domain, Locale, Entries, PoPath) ->
    {Domain, Locale, Entries, #{
        plural => fallback,
        plural_raw => ~"nplurals=2; plural=(n != 1);",
        po_path => PoPath,
        divergence => none,
        fuzzy_included => false,
        num_entries => length(Entries)
    }}.

%% Build, compile and load a carrier module that returns `Spec` from
%% `catalog/0`. When `WithMarker` is true the module declares the
%% `-erli18n_compiled_catalog(true)` marker attribute.
build_carrier(Mod, WithMarker, Spec) ->
    A = erl_anno:new(0),
    Marker =
        case WithMarker of
            true -> [{attribute, A, erli18n_compiled_catalog, true}];
            false -> []
        end,
    Forms =
        [{attribute, A, module, Mod}] ++
            Marker ++
            [
                {attribute, A, export, [{catalog, 0}]},
                {function, A, catalog, 0, [
                    {clause, A, [], [], [erl_parse:abstract(Spec, 0)]}
                ]}
            ],
    {ok, Mod, Bin} = compile:forms(Forms, [binary, debug_info, report_errors]),
    _ = code:purge(Mod),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Bin),
    ok.

%% Load a throwaway application whose `modules` key lists `Mods`, so
%% `application:get_key(App, modules)` resolves the carriers. Returns the app
%% atom (a unique name so cases never collide).
load_app(Mods) ->
    U = uniq(),
    App = app_name(U),
    AppSpec =
        {application, App, [
            {description, "erli18n compiled-catalog test app"},
            {vsn, "0.0.0"},
            {modules, Mods},
            {registered, []},
            {applications, [kernel, stdlib]}
        ]},
    ok = application:load(AppSpec),
    App.

cleanup(App, Mods) ->
    _ = application:unload(App),
    lists:foreach(
        fun(Mod) ->
            _ = code:purge(Mod),
            _ = code:delete(Mod)
        end,
        Mods
    ),
    ok.

%% Compile rendered carrier source (`rebar3_erli18n_codegen:render/2`) and load
%% it, returning the compiler-interned module atom. Mirrors the codegen suite's
%% load helper; used by `read_catalog_interns_no_atoms/1`.
compile_carrier(Src) ->
    Bin = unicode:characters_to_binary(Src),
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Bin)),
    Forms = split_forms(Tokens),
    case compile:forms(Forms, [binary, debug_info, return_errors]) of
        {ok, Mod, Beam} ->
            _ = code:purge(Mod),
            {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Beam),
            Mod;
        Other ->
            ct:fail({carrier_compile_failed, Other})
    end.

%% Split a flat token list into per-form abstract forms on `dot` tokens.
split_forms(Tokens) ->
    split_forms(Tokens, [], []).

split_forms([], _Acc, Forms) ->
    lists:reverse(Forms);
split_forms([{dot, _} = Dot | Rest], Acc, Forms) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([Dot | Acc])),
    split_forms(Rest, [], [Form | Forms]);
split_forms([Tok | Rest], Acc, Forms) ->
    split_forms(Rest, [Tok | Acc], Forms).
