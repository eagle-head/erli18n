-module(erli18n_compiled_adequacy_SUITE).

%% Boundary-pinning Common Test suite for the consumer-side boot engine
%% `erli18n_compiled`. Where `erli18n_compiled_SUITE` covers the happy path,
%% this suite pins the edges that the hard constraints demand:
%%
%%   * a marker-less `erli18n_cc_*` module is SKIPPED (prefix is not enough);
%%   * a non-prefixed module is SKIPPED even if it carries the marker;
%%   * an unknown/unloaded app crashes LOUDLY (never a silent empty result);
%%   * the ZERO-CARRIER cases (populated-but-none AND empty `{modules,[]}`) each
%%     emit EXACTLY ONE `?LOG_WARNING` tagged `erli18n_compiled_no_carriers` and
%%     return `[]`;
%%   * the READ PATH survives the carrier being purged+deleted after register
%%     (the catalog lives in `persistent_term`, not in the module);
%%   * a catalog already loaded at runtime is PRESERVED across a re-register
%%     (idempotent, no overwrite).

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
    marker_less_carrier_is_skipped/1,
    non_prefixed_marked_module_is_skipped/1,
    unknown_app_crashes_loudly/1,
    populated_but_no_carriers_warns_once/1,
    empty_modules_warns_once/1,
    read_path_survives_carrier_purge/1,
    runtime_catalog_preserved_across_register/1,
    confirm_catalog_unloadable_module_is_false/1,
    confirm_catalog_marker_value_agnostic/1
]).

%% logger handler callback used by with_log_capture/1.
-export([log/2]).

%% `build_carrier/3` is the dynamic-module load helper: `compile:forms`/
%% `code:load_binary` return wide union types eqwalizer cannot statically
%% narrow, so quarantine it with a static annotation — the same zero-runtime-dep
%% pattern used in the runtime modules `erli18n_server`/`erli18n_pt_store`.
%% (A wild attribute must precede the first function definition.)
-eqwalizer({nowarn_function, build_carrier/3}).
-eqwalizer({nowarn_function, build_carrier_with_marker/3}).

all() ->
    [
        marker_less_carrier_is_skipped,
        non_prefixed_marked_module_is_skipped,
        unknown_app_crashes_loudly,
        populated_but_no_carriers_warns_once,
        empty_modules_warns_once,
        read_path_survives_carrier_purge,
        runtime_catalog_preserved_across_register,
        confirm_catalog_unloadable_module_is_false,
        confirm_catalog_marker_value_agnostic
    ].

init_per_suite(Config) ->
    {ok, _Apps} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    ok.

init_per_testcase(_TC, Config) ->
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

%% A module with the `erli18n_cc_` prefix and an exported `catalog/0` but NO
%% `-erli18n_compiled_catalog` marker is NOT a carrier: register/1 confirms
%% no carriers, so it warns and installs nothing.
marker_less_carrier_is_skipped(_Config) ->
    U = uniq(),
    Mod = carrier_mod("nomark", U),
    Spec = fallback_spec(default, ~"zz", [{singular, undefined, ~"k", ~"v"}], "zz.po"),
    %% WithMarker = false.
    ok = build_carrier(Mod, false, Spec),
    App = load_app([Mod]),
    try
        ?assertEqual(false, erli18n_compiled:confirm_catalog(Mod)),
        {Result, Warnings} = with_log_capture(fun() -> erli18n_compiled:register(App) end),
        ?assertEqual([], Result),
        ?assertEqual(1, count_no_carrier_warnings(Warnings, App)),
        %% Nothing was installed.
        ?assertEqual(
            undefined, erli18n_server:lookup_singular(default, ~"zz", undefined, ~"k")
        )
    after
        cleanup(App, [Mod])
    end.

%% A module that DOES carry the marker but lacks the `erli18n_cc_` prefix is
%% never even considered (discover filters by prefix first).
non_prefixed_marked_module_is_skipped(_Config) ->
    U = uniq(),
    Mod = list_to_atom("notcarrier_" ++ U),
    Spec = fallback_spec(default, ~"zz", [{singular, undefined, ~"k", ~"v"}], "zz.po"),
    ok = build_carrier(Mod, true, Spec),
    App = load_app([Mod]),
    try
        %% confirm_catalog would say true (it has the marker), but discover
        %% never offers it because the name lacks the prefix.
        ?assertEqual(true, erli18n_compiled:confirm_catalog(Mod)),
        ?assertEqual([], erli18n_compiled:discover(App)),
        {Result, Warnings} = with_log_capture(fun() -> erli18n_compiled:register(App) end),
        ?assertEqual([], Result),
        ?assertEqual(1, count_no_carrier_warnings(Warnings, App)),
        ?assertEqual(
            undefined, erli18n_server:lookup_singular(default, ~"zz", undefined, ~"k")
        )
    after
        cleanup(App, [Mod])
    end.

%% An app atom that is not loaded crashes LOUDLY with the documented reason —
%% it must never degrade to a silent empty result.
unknown_app_crashes_loudly(_Config) ->
    App = list_to_atom("erli18n_cc_never_loaded_" ++ uniq()),
    ?assertEqual(undefined, application:get_key(App, modules)),
    ?assertError(
        {erli18n_compiled_app_not_loaded, App},
        erli18n_compiled:register(App)
    ),
    ?assertError(
        {erli18n_compiled_app_not_loaded, App},
        erli18n_compiled:discover(App)
    ).

%% Populated-but-none: the app's module list is non-empty but contains no
%% confirmed carriers -> EXACTLY ONE warning + [].
populated_but_no_carriers_warns_once(_Config) ->
    U = uniq(),
    %% A real, loaded, non-carrier module name (lists) plus a prefixed but
    %% marker-less module: neither is a carrier.
    Mod = carrier_mod("bare", U),
    ok = build_carrier(
        Mod, false, fallback_spec(default, ~"zz", [{singular, undefined, ~"k", ~"v"}], "zz.po")
    ),
    App = load_app([lists, Mod]),
    try
        {Result, Warnings} = with_log_capture(fun() -> erli18n_compiled:register(App) end),
        ?assertEqual([], Result),
        ?assertEqual(1, count_no_carrier_warnings(Warnings, App))
    after
        cleanup(App, [Mod])
    end.

%% Empty `{modules, []}`: still EXACTLY ONE warning + [] (never a silent
%% no-op).
empty_modules_warns_once(_Config) ->
    App = load_app([]),
    try
        {Result, Warnings} = with_log_capture(fun() -> erli18n_compiled:register(App) end),
        ?assertEqual([], Result),
        ?assertEqual(1, count_no_carrier_warnings(Warnings, App))
    after
        _ = application:unload(App)
    end.

%% `confirm_catalog/1` on a module that cannot be loaded (a name that resolves
%% to no object code) takes the `{error, _} -> false` branch: it is not a
%% carrier, never a crash. This is the load-failure partition the marker tests
%% (which build+load a real module) do not exercise.
confirm_catalog_unloadable_module_is_false(_Config) ->
    Mod = list_to_atom("erli18n_cc_never_exists_" ++ uniq()),
    false = (code:is_loaded(Mod) =/= false),
    ?assertEqual(false, erli18n_compiled:confirm_catalog(Mod)).

%% `confirm_catalog/1` is a PRESENCE check on the `-erli18n_compiled_catalog`
%% marker attribute, not a validator of its payload: any marker value confirms
%% the carrier. A carrier is confirmed regardless of whether the attribute
%% carries `true`, a descriptive proplist, an empty list, or a bare atom.
confirm_catalog_marker_value_agnostic(_Config) ->
    U = uniq(),
    Markers = [
        true,
        [{domain, default}, {locale, ~"en"}, {generator_vsn, ~"1"}],
        [],
        marker_present
    ],
    lists:foreach(
        fun({I, MarkerValue}) ->
            Mod = carrier_mod("mark" ++ integer_to_list(I), U),
            Spec = fallback_spec(
                default, ~"zz", [{singular, undefined, ~"k", ~"v"}], "zz.po"
            ),
            ok = build_carrier_with_marker(Mod, MarkerValue, Spec),
            try
                ?assertEqual(true, erli18n_compiled:confirm_catalog(Mod))
            after
                _ = code:purge(Mod),
                _ = code:delete(Mod)
            end
        end,
        lists:zip(lists:seq(1, length(Markers)), Markers)
    ).

%% READ-PATH PROOF: after register, purge+delete the carrier module entirely.
%% The catalog lives in persistent_term (owned by the runtime), so lookups
%% STILL succeed — the boot engine holds no reference to the carrier.
read_path_survives_carrier_purge(_Config) ->
    U = uniq(),
    Mod = carrier_mod("purge", U),
    ok = build_carrier(
        Mod,
        true,
        fallback_spec(default, ~"fr", [{singular, undefined, ~"Hello", ~"Bonjour"}], "fr.po")
    ),
    App = load_app([Mod]),
    try
        ?assertEqual([{default, ~"fr", {ok, 1}}], erli18n_compiled:register(App)),
        ?assertEqual(
            {ok, ~"Bonjour"},
            erli18n_server:lookup_singular(default, ~"fr", undefined, ~"Hello")
        ),
        %% Obliterate the carrier module.
        _ = code:purge(Mod),
        true = code:delete(Mod),
        _ = code:purge(Mod),
        ?assertEqual(false, code:is_loaded(Mod)),
        %% The catalog is untouched: the read path still serves it.
        ?assertEqual(
            {ok, ~"Bonjour"},
            erli18n_server:lookup_singular(default, ~"fr", undefined, ~"Hello")
        )
    after
        _ = application:unload(App),
        _ = code:purge(Mod),
        _ = code:delete(Mod)
    end.

%% A catalog already loaded at runtime (here via the server's own register
%% path with DIFFERENT entries) is PRESERVED across a re-register from a
%% carrier for the same (Domain, Locale): the carrier reports {ok, already}
%% and never overwrites the live runtime value.
runtime_catalog_preserved_across_register(_Config) ->
    U = uniq(),
    %% 1. Install a runtime catalog for (default, <<"runtime">>).
    RuntimeEntries = [{singular, undefined, ~"k", ~"RUNTIME"}],
    [{default, ~"runtime", {ok, 1}}] =
        erli18n_server:register_compiled_many([
            {default, ~"runtime", RuntimeEntries, #{
                plural => fallback,
                plural_raw => ~"nplurals=2; plural=(n != 1);",
                po_path => "runtime.po",
                divergence => none,
                fuzzy_included => false,
                num_entries => 1
            }}
        ]),
    %% 2. A carrier for the SAME (Domain, Locale) but a DIFFERENT value.
    Mod = carrier_mod("rt", U),
    ok = build_carrier(
        Mod,
        true,
        fallback_spec(default, ~"runtime", [{singular, undefined, ~"k", ~"CARRIER"}], "runtime.po")
    ),
    App = load_app([Mod]),
    try
        %% 3. register/1 reports already and does NOT overwrite.
        ?assertEqual(
            [{default, ~"runtime", {ok, already}}],
            erli18n_compiled:register(App)
        ),
        ?assertEqual(
            {ok, ~"RUNTIME"},
            erli18n_server:lookup_singular(default, ~"runtime", undefined, ~"k")
        )
    after
        cleanup(App, [Mod])
    end.

%% =========================
%% Helpers
%% =========================

uniq() ->
    integer_to_list(erlang:unique_integer([positive])).

carrier_mod(Tag, U) ->
    list_to_atom("erli18n_cc_" ++ Tag ++ "_" ++ U).

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

%% Build a confirmed carrier whose marker attribute carries an ARBITRARY value,
%% so a test can assert `confirm_catalog/1` is agnostic to the marker payload.
build_carrier_with_marker(Mod, MarkerValue, Spec) ->
    A = erl_anno:new(0),
    Forms =
        [
            {attribute, A, module, Mod},
            {attribute, A, erli18n_compiled_catalog, MarkerValue},
            {attribute, A, export, [{catalog, 0}]},
            {function, A, catalog, 0, [
                {clause, A, [], [], [erl_parse:abstract(Spec, 0)]}
            ]}
        ],
    {ok, Mod, Bin} = compile:forms(Forms, [binary, debug_info, report_errors]),
    _ = code:purge(Mod),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Bin),
    ok.

load_app(Mods) ->
    U = uniq(),
    App = app_name(U),
    AppSpec =
        {application, App, [
            {description, "erli18n compiled-catalog adequacy test app"},
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

%% Run Body/0 with a private logger handler installed at the warning level;
%% return {Result, CapturedWarnings}.
with_log_capture(Body) ->
    HandlerId = list_to_atom(
        "erli18n_compiled_log_capture_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Tab = ets:new(HandlerId, [public, duplicate_bag]),
    ok = logger:add_handler(HandlerId, ?MODULE, #{
        config => #{tab => Tab},
        level => warning
    }),
    try
        Result = Body(),
        Logs = [E || {_, E} <- ets:tab2list(Tab)],
        {Result, Logs}
    after
        _ = logger:remove_handler(HandlerId),
        ets:delete(Tab)
    end.

%% logger handler callback: capture each LogEvent into the configured table.
log(LogEvent, #{config := #{tab := Tab}}) ->
    ets:insert(Tab, {erlang:unique_integer(), LogEvent}),
    ok.

%% Count the captured warnings tagged `erli18n_compiled_no_carriers` for App.
count_no_carrier_warnings(Warnings, App) ->
    length([
        E
     || E <- Warnings,
        case E of
            #{msg := {report, #{event := erli18n_compiled_no_carriers, app := A}}} -> A =:= App;
            _ -> false
        end
    ]).
