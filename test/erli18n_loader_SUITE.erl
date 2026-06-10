-module(erli18n_loader_SUITE).

%% Common Test suite for the load orchestration (Parte 5) in
%% `erli18n_server`. Exercises `ensure_loaded/3,4`, `reload/3,4`,
%% `lookup_header/2`, `lookup_plural_form/5`, `which_keys/2`, and
%% `default_po_path/3`.
%%
%% Each test case carries the design citation (BR/PSD/RISK/AMB) in its
%% docstring so failures point straight at the spec.

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
    ensure_loaded_minimal_singular/1,
    ensure_loaded_plural_with_form_lookup/1,
    ensure_loaded_idempotent/1,
    ensure_loaded_file_not_found/1,
    ensure_loaded_invalid_po/1,
    ensure_loaded_unsupported_charset/1,
    ensure_loaded_plural_mismatch/1,
    ensure_loaded_no_plural_header_uses_fallback/1,
    ensure_loaded_fuzzy_dropped_by_default/1,
    ensure_loaded_fuzzy_included_with_opt/1,
    ensure_loaded_emits_cldr_divergence_warning/1,
    reload_replaces_catalog/1,
    reload_idempotency_bypassed/1,
    unload_removes_header_too/1,
    which_keys_returns_unique_msgids/1,
    default_po_path_convention/1,
    lookup_plural_form_with_fallback_locale/1,
    atomicidade_load_fails/1,
    ensure_loaded_plural_compile_error/1,
    ensure_loaded_header_only_no_entries/1,
    ensure_loaded_plural_empty_forms_list/1,
    ensure_loaded_accepts_binary_path/1,
    ensure_loaded_fuzzy_skip_with_lookup_telemetry/1,
    ensure_loaded_no_fuzzy_with_lookup_telemetry/1,
    lookup_plural_form_unloaded_catalog/1,
    which_keys_filters_other_catalogs/1
]).

%% Custom logger handler callback used by with_log_capture/1 to assert
%% on ?LOG_WARNING emission (CLDR divergence test).
-export([log/2]).

all() ->
    [
        ensure_loaded_minimal_singular,
        ensure_loaded_plural_with_form_lookup,
        ensure_loaded_idempotent,
        ensure_loaded_file_not_found,
        ensure_loaded_invalid_po,
        ensure_loaded_unsupported_charset,
        ensure_loaded_plural_mismatch,
        ensure_loaded_no_plural_header_uses_fallback,
        ensure_loaded_fuzzy_dropped_by_default,
        ensure_loaded_fuzzy_included_with_opt,
        ensure_loaded_emits_cldr_divergence_warning,
        reload_replaces_catalog,
        reload_idempotency_bypassed,
        unload_removes_header_too,
        which_keys_returns_unique_msgids,
        default_po_path_convention,
        lookup_plural_form_with_fallback_locale,
        atomicidade_load_fails,
        ensure_loaded_plural_compile_error,
        ensure_loaded_header_only_no_entries,
        ensure_loaded_plural_empty_forms_list,
        ensure_loaded_accepts_binary_path,
        ensure_loaded_fuzzy_skip_with_lookup_telemetry,
        ensure_loaded_no_fuzzy_with_lookup_telemetry,
        lookup_plural_form_unloaded_catalog,
        which_keys_filters_other_catalogs
    ].

init_per_suite(Config) ->
    {ok, _Apps} = application:ensure_all_started(erli18n),
    %% CT auto-resolves data_dir to test/<suite_name>_data per the CT
    %% convention. Fixtures live in test/erli18n_loader_SUITE_data/.
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
    ok.

%% =========================
%% Helpers
%% =========================

fixture(Config, Name) ->
    Dir = ?config(data_dir, Config),
    Path = filename:join(Dir, Name),
    case filelib:is_file(Path) of
        true -> Path;
        false -> ct:fail({fixture_missing, Path})
    end.

%% Run Body/0 with a custom logger handler installed; returns the list of
%% warning messages captured. Used by ensure_loaded_emits_cldr_divergence
%% to check that the load path emits a ?LOG_WARNING with the divergence
%% payload (per BR-MIGRAR-030).
with_log_capture(Body) ->
    HandlerId = list_to_atom(
        "erli18n_log_capture_" ++
            integer_to_list(
                erlang:unique_integer([positive])
            )
    ),
    Tab = ets:new(HandlerId, [public, duplicate_bag]),
    HandlerConfig = #{tab => Tab},
    ok = logger:add_handler(HandlerId, ?MODULE, #{
        config => HandlerConfig,
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

%% logger handler callback. Captures the LogEvent map into the configured
%% ETS table.
log(LogEvent, #{config := #{tab := Tab}}) ->
    ets:insert(Tab, {erlang:unique_integer(), LogEvent}),
    ok.

%% =========================
%% Test cases
%% =========================

%% Minimal: parse a .po with one singular entry, expect {ok, 1} and that
%% lookup_singular returns the translation. Uses locale <<"en">> so the
%% CLDR validation passes silently (the header rule matches the CLDR
%% canonical rule for English).
ensure_loaded_minimal_singular(Config) ->
    Path = fixture(Config, "minimal_en.po"),
    Result = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    ?assertEqual({ok, 1}, Result),
    ?assertEqual(
        {ok, <<"Bonjour">>},
        erli18n_server:lookup_singular(
            default,
            <<"en">>,
            undefined,
            <<"Hello">>
        )
    ),
    {ok, HeaderState} = erli18n_server:lookup_header(default, <<"en">>),
    ?assertEqual(Path, maps:get(po_path, HeaderState)),
    ?assertEqual(1, maps:get(num_entries, HeaderState)),
    ?assertEqual(false, maps:get(fuzzy_included, HeaderState)),
    ?assertEqual(none, maps:get(divergence, HeaderState)).

%% Plural entry: French rule (n > 1). N=0,1 -> form 0 (singular); N>=2 ->
%% form 1 (plural). Validates the lookup_plural_form integration.
ensure_loaded_plural_with_form_lookup(Config) ->
    Path = fixture(Config, "plural_fr.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"fr">>, Path),
    %% N=0: French treats 0 as singular -> form 0 -> "arbre".
    ?assertEqual(
        {ok, <<"arbre">>},
        erli18n_server:lookup_plural_form(
            default, <<"fr">>, undefined, <<"tree">>, 0
        )
    ),
    %% N=1: singular -> form 0 -> "arbre".
    ?assertEqual(
        {ok, <<"arbre">>},
        erli18n_server:lookup_plural_form(
            default, <<"fr">>, undefined, <<"tree">>, 1
        )
    ),
    %% N=2: plural -> form 1 -> "arbres".
    ?assertEqual(
        {ok, <<"arbres">>},
        erli18n_server:lookup_plural_form(
            default, <<"fr">>, undefined, <<"tree">>, 2
        )
    ),
    %% N=100: still plural.
    ?assertEqual(
        {ok, <<"arbres">>},
        erli18n_server:lookup_plural_form(
            default, <<"fr">>, undefined, <<"tree">>, 100
        )
    ).

%% RISK-012 mitigation 2: second ensure_loaded is a no-op fast-path.
%% Verifies via `loaded_at` timestamp: it does NOT change between calls.
ensure_loaded_idempotent(Config) ->
    Path = fixture(Config, "minimal_en.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"fr">>, Path),
    {ok, HeaderState1} = erli18n_server:lookup_header(default, <<"fr">>),
    LoadedAt1 = maps:get(loaded_at, HeaderState1),
    %% Wait > 1ms so a re-read would produce a different timestamp.
    timer:sleep(5),
    %% Second call: must be `{ok, already}` and must NOT mutate state.
    ?assertEqual(
        {ok, already},
        erli18n_server:ensure_loaded(default, <<"fr">>, Path)
    ),
    {ok, HeaderState2} = erli18n_server:lookup_header(default, <<"fr">>),
    LoadedAt2 = maps:get(loaded_at, HeaderState2),
    ?assertEqual(
        LoadedAt1,
        LoadedAt2,
        "loaded_at must be preserved on idempotent ensure_loaded"
    ).

ensure_loaded_file_not_found(_Config) ->
    Path =
        "/tmp/erli18n_loader_does_not_exist_" ++
            integer_to_list(erlang:unique_integer([positive])) ++ ".po",
    ?assertMatch(
        {error, {file_error, enoent}},
        erli18n_server:ensure_loaded(default, <<"fr">>, Path)
    ),
    %% Failure leaves ETS untouched.
    ?assertEqual(
        undefined,
        erli18n_server:lookup_header(default, <<"fr">>)
    ).

ensure_loaded_invalid_po(Config) ->
    Path = fixture(Config, "invalid_syntax.po"),
    Result = erli18n_server:ensure_loaded(default, <<"x">>, Path),
    ?assertMatch({error, {syntax_error, _, _}}, Result),
    ?assertEqual(undefined, erli18n_server:lookup_header(default, <<"x">>)).

%% PSD-002: SHIFT_JIS is not in {utf8, latin1, us_ascii} so the load
%% must fail with `{unsupported_charset, _}` and leave ETS untouched.
ensure_loaded_unsupported_charset(Config) ->
    Path = fixture(Config, "shift_jis.po"),
    ?assertEqual(
        {error, {unsupported_charset, <<"SHIFT_JIS">>}},
        erli18n_server:ensure_loaded(default, <<"ja">>, Path)
    ),
    ?assertEqual(undefined, erli18n_server:lookup_header(default, <<"ja">>)).

%% PSD-009: plural_count_mismatch propagated from the parser. ETS stays
%% clean — no partial state.
ensure_loaded_plural_mismatch(Config) ->
    Path = fixture(Config, "mismatch.po"),
    ?assertMatch(
        {error, {plural_count_mismatch, <<"Tree">>, 3, [0, 1, 3]}},
        erli18n_server:ensure_loaded(default, <<"xx">>, Path)
    ),
    ?assertEqual(undefined, erli18n_server:lookup_header(default, <<"xx">>)).

%% A .po without a Plural-Forms header: load succeeds, header_state
%% records plural = fallback. lookup_plural_form/5 then uses the
%% C/Germanic default (N=1 -> form 0; else -> form 1).
ensure_loaded_no_plural_header_uses_fallback(Config) ->
    Path = fixture(Config, "no_plural_header.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    {ok, HeaderState} = erli18n_server:lookup_header(default, <<"en">>),
    ?assertEqual(fallback, maps:get(plural, HeaderState)),
    %% N=1 -> singular form 0.
    ?assertEqual(
        {ok, <<"arbre">>},
        erli18n_server:lookup_plural_form(
            default, <<"en">>, undefined, <<"tree">>, 1
        )
    ),
    %% N=2,5 -> plural form 1.
    ?assertEqual(
        {ok, <<"arbres">>},
        erli18n_server:lookup_plural_form(
            default, <<"en">>, undefined, <<"tree">>, 2
        )
    ),
    ?assertEqual(
        {ok, <<"arbres">>},
        erli18n_server:lookup_plural_form(
            default, <<"en">>, undefined, <<"tree">>, 5
        )
    ).

%% PSD-001: fuzzy entries dropped by default.
ensure_loaded_fuzzy_dropped_by_default(Config) ->
    Path = fixture(Config, "fuzzy_entry.po"),
    {ok, NumLoaded} = erli18n_server:ensure_loaded(default, <<"fr">>, Path),
    ?assertEqual(1, NumLoaded),
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(
            default,
            <<"fr">>,
            undefined,
            <<"uncertain">>
        )
    ),
    ?assertEqual(
        {ok, <<"vivant">>},
        erli18n_server:lookup_singular(
            default,
            <<"fr">>,
            undefined,
            <<"alive">>
        )
    ).

%% PSD-001: include_fuzzy => true preserves fuzzy entries; the header
%% records the choice.
ensure_loaded_fuzzy_included_with_opt(Config) ->
    Path = fixture(Config, "fuzzy_entry.po"),
    {ok, 2} = erli18n_server:ensure_loaded(
        default,
        <<"fr">>,
        Path,
        #{include_fuzzy => true}
    ),
    ?assertEqual(
        {ok, <<"incerto">>},
        erli18n_server:lookup_singular(
            default,
            <<"fr">>,
            undefined,
            <<"uncertain">>
        )
    ),
    {ok, HeaderState} = erli18n_server:lookup_header(default, <<"fr">>),
    ?assertEqual(true, maps:get(fuzzy_included, HeaderState)).

%% PSD-004: header rule is source-of-truth, but CLDR divergence is logged
%% (and persisted in header_state.divergence). Uses divergent_fr.po with
%% French header `n != 1` while CLDR canonical for `fr` is `n > 1`.
ensure_loaded_emits_cldr_divergence_warning(Config) ->
    Path = fixture(Config, "divergent_fr.po"),
    {Result, Logs} = with_log_capture(
        fun() ->
            erli18n_server:ensure_loaded(
                default,
                <<"fr">>,
                Path
            )
        end
    ),
    ?assertMatch({ok, 1}, Result),
    %% header_state captures the divergence payload for downstream
    %% telemetry consumption (Parte 7).
    {ok, HeaderState} = erli18n_server:lookup_header(default, <<"fr">>),
    ?assertMatch(
        {plural_divergence, _, _},
        maps:get(divergence, HeaderState)
    ),
    %% A ?LOG_WARNING was emitted with the divergence event tag.
    DivergenceLogs =
        [
            E
         || E <- Logs,
            case E of
                #{msg := {report, #{event := plural_divergence}}} -> true;
                _ -> false
            end
        ],
    ?assert(
        length(DivergenceLogs) >= 1,
        "expected at least one plural_divergence ?LOG_WARNING"
    ).

%% AMB-001: reload overwrites the existing catalog with the new .po
%% contents. The old catalog is gone.
reload_replaces_catalog(Config) ->
    % "Hello" -> "Bonjour"
    PathA = fixture(Config, "minimal_en.po"),
    % "tree"  -> "arbre"/"arbres"
    PathB = fixture(Config, "plural_fr.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"fr">>, PathA),
    ?assertMatch(
        {ok, <<"Bonjour">>},
        erli18n_server:lookup_singular(
            default,
            <<"fr">>,
            undefined,
            <<"Hello">>
        )
    ),
    {ok, NumLoaded} = erli18n_server:reload(default, <<"fr">>, PathB),
    ?assertEqual(1, NumLoaded),
    %% Old singular gone.
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(
            default,
            <<"fr">>,
            undefined,
            <<"Hello">>
        )
    ),
    %% New plural present.
    ?assertEqual(
        {ok, <<"arbres">>},
        erli18n_server:lookup_plural(
            default,
            <<"fr">>,
            undefined,
            <<"tree">>,
            1
        )
    ),
    %% Header now reflects the new file path.
    {ok, HeaderState} = erli18n_server:lookup_header(default, <<"fr">>),
    ?assertEqual(PathB, maps:get(po_path, HeaderState)).

%% reload bypasses the idempotency check: even when the same file is
%% reloaded, the timestamp must advance (re-execution).
reload_idempotency_bypassed(Config) ->
    Path = fixture(Config, "minimal_en.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"fr">>, Path),
    {ok, H1} = erli18n_server:lookup_header(default, <<"fr">>),
    timer:sleep(5),
    {ok, 1} = erli18n_server:reload(default, <<"fr">>, Path),
    {ok, H2} = erli18n_server:lookup_header(default, <<"fr">>),
    ?assert(
        maps:get(loaded_at, H2) >= maps:get(loaded_at, H1),
        "reload must update loaded_at"
    ),
    %% Distinct calls — even same path — must yield distinct timestamps
    %% when wall-clock differs.
    ?assertNotEqual(maps:get(loaded_at, H1), maps:get(loaded_at, H2)).

unload_removes_header_too(Config) ->
    Path = fixture(Config, "minimal_en.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"fr">>, Path),
    ?assertMatch({ok, _}, erli18n_server:lookup_header(default, <<"fr">>)),
    ok = erli18n_server:unload(default, <<"fr">>),
    ?assertEqual(
        undefined,
        erli18n_server:lookup_header(default, <<"fr">>)
    ),
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(
            default,
            <<"fr">>,
            undefined,
            <<"Hello">>
        )
    ).

%% A catalog with 3 singular + 1 plural (2 forms in ETS) reports 4
%% which_keys entries — the plural is deduplicated.
which_keys_returns_unique_msgids(_Config) ->
    Entries = [
        {singular, undefined, <<"a">>, <<"A">>},
        {singular, undefined, <<"b">>, <<"B">>},
        {singular, undefined, <<"c">>, <<"C">>},
        {plural, undefined, <<"tree">>, [{0, <<"arbre">>}, {1, <<"arbres">>}]}
    ],
    ok = erli18n_server:insert_catalog(default, <<"fr">>, Entries),
    Keys = erli18n_server:which_keys(default, <<"fr">>),
    ?assertEqual(4, length(Keys)),
    %% Each type appears as expected.
    Singulars = [K || {singular, _, _} = K <- Keys],
    Plurals = [K || {plural, _, _} = K <- Keys],
    ?assertEqual(3, length(Singulars)),
    ?assertEqual(1, length(Plurals)),
    ?assertEqual([{plural, undefined, <<"tree">>}], Plurals).

%% Path follows the GNU gettext convention:
%%   <PrivDir>/locale/<Locale>/LC_MESSAGES/<Domain>.po
default_po_path_convention(_Config) ->
    Path = erli18n_server:default_po_path(erli18n, default, <<"pt_BR">>),
    PathBin = iolist_to_binary(Path),
    ?assert(
        binary:match(
            PathBin,
            <<"/priv/locale/pt_BR/LC_MESSAGES/default.po">>
        ) =/=
            nomatch,
        "path must contain /priv/locale/pt_BR/LC_MESSAGES/default.po"
    ).

%% Fallback rule: N=0,2,5 all map to form 1; N=1 maps to form 0.
%% Mirrors the C/Germanic default cited in GNU manual "Translating
%% plural forms" §"Plural forms".
lookup_plural_form_with_fallback_locale(Config) ->
    Path = fixture(Config, "no_plural_header.po"),
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"en">>, Path),
    ?assertEqual(
        {ok, <<"arbres">>},
        erli18n_server:lookup_plural_form(
            default, <<"en">>, undefined, <<"tree">>, 0
        )
    ),
    ?assertEqual(
        {ok, <<"arbre">>},
        erli18n_server:lookup_plural_form(
            default, <<"en">>, undefined, <<"tree">>, 1
        )
    ),
    ?assertEqual(
        {ok, <<"arbres">>},
        erli18n_server:lookup_plural_form(
            default, <<"en">>, undefined, <<"tree">>, 2
        )
    ),
    ?assertEqual(
        {ok, <<"arbres">>},
        erli18n_server:lookup_plural_form(
            default, <<"en">>, undefined, <<"tree">>, 5
        )
    ).

%% Atomicity: if the load fails (here via unsupported_charset), ETS state
%% present before the call is preserved. No partial writes leaked.
atomicidade_load_fails(Config) ->
    GoodPath = fixture(Config, "minimal_en.po"),
    BadPath = fixture(Config, "shift_jis.po"),
    %% Pre-load: 1 catalog (default, fr).
    {ok, 1} = erli18n_server:ensure_loaded(default, <<"fr">>, GoodPath),
    BeforeMem = erli18n_server:memory_info(),
    %% Attempt a bad load on a different (D, L) so we can confirm the
    %% partial-failure does not leak into ETS at all.
    ?assertEqual(
        {error, {unsupported_charset, <<"SHIFT_JIS">>}},
        erli18n_server:ensure_loaded(default, <<"ja">>, BadPath)
    ),
    AfterMem = erli18n_server:memory_info(),
    %% Pre-existing catalog still intact.
    ?assertEqual(
        {ok, <<"Bonjour">>},
        erli18n_server:lookup_singular(
            default,
            <<"fr">>,
            undefined,
            <<"Hello">>
        )
    ),
    %% No new rows from the failed load.
    ?assertEqual(
        maps:get(num_keys, BeforeMem),
        maps:get(num_keys, AfterMem)
    ),
    ?assertEqual(
        undefined,
        erli18n_server:lookup_header(default, <<"ja">>)
    ).

%% Header has a syntactically-valid Plural-Forms field that the .po
%% parser preserves verbatim, but `erli18n_plural:compile/1` rejects.
%% The load must fail with `{plural_compile_error, _}` and ETS must
%% remain untouched. Exercises the compile-failure branch of
%% `install_parsed` (the `{error, {plural_compile_error, _}}` return)
%% and the `{error, _} = E` re-raise inside `maybe_compile_plural`.
ensure_loaded_plural_compile_error(Config) ->
    Path = fixture(Config, "bad_plural_expr.po"),
    Result = erli18n_server:ensure_loaded(default, <<"xx">>, Path),
    ?assertMatch({error, {plural_compile_error, _}}, Result),
    ?assertEqual(undefined, erli18n_server:lookup_header(default, <<"xx">>)).

%% A .po that has only the header (no msgid/msgstr entries) must load
%% successfully with zero entries. The header_state is still installed
%% so subsequent lookups know the catalog exists. Exercises the
%% `insert_entries(_, _, []) -> true` clause.
ensure_loaded_header_only_no_entries(Config) ->
    Path = fixture(Config, "header_only.po"),
    %% Private locale so the header row this test installs does not
    %% leak into later cases (init_per_testcase unloads only catalogs
    %% reported by loaded_catalogs/0, which excludes header-only rows).
    ?assertEqual(
        {ok, 0},
        erli18n_server:ensure_loaded(default, <<"empty_cat">>, Path)
    ),
    {ok, HeaderState} =
        erli18n_server:lookup_header(default, <<"empty_cat">>),
    ?assertEqual(0, maps:get(num_entries, HeaderState)),
    %% Header rows are excluded from the user-visible catalog count by
    %% design — the O(1) catalog index only tracks (D, L) with >=1 entry.
    Catalogs = erli18n_server:loaded_catalogs(),
    ?assertEqual(
        false,
        lists:keymember(
            {default, <<"empty_cat">>},
            1,
            [{{D, L}, N} || {D, L, N} <- Catalogs]
        )
    ),
    %% Clean up the orphan header row so subsequent tests start clean.
    ok = erli18n_server:unload(default, <<"empty_cat">>).

%% A plural entry with NO msgstr forms (i.e. empty form list) is still
%% accepted by the parser when no Plural-Forms header pins nplurals.
%% `entry_to_objects/3` returns [] for such entries, and the bulk
%% insert path takes the empty-Objects branch. Exercises the
%% `[] -> true` arm of the `case Objects of` inside insert_entries/3.
ensure_loaded_plural_empty_forms_list(Config) ->
    Path = fixture(Config, "empty_plural_forms.po"),
    %% The load succeeds with 1 entry counted (header records the entry
    %% count, even though it yielded zero ETS objects).
    ?assertEqual(
        {ok, 1},
        erli18n_server:ensure_loaded(default, <<"empty_pl">>, Path)
    ),
    {ok, HeaderState} = erli18n_server:lookup_header(default, <<"empty_pl">>),
    ?assertEqual(1, maps:get(num_entries, HeaderState)),
    %% No plural form rows were inserted (empty list).
    ?assertEqual(
        undefined,
        erli18n_server:lookup_plural(
            default,
            <<"empty_pl">>,
            undefined,
            <<"x">>,
            0
        )
    ),
    %% Clean up the orphan header row so subsequent tests start clean.
    ok = erli18n_server:unload(default, <<"empty_pl">>).

%% `file:filename()` admits both list and binary forms; the load path
%% normalises via `to_binary_path/1` for telemetry metadata. This case
%% exercises the `is_binary` clause by passing the fixture path as a
%% binary literal. Uses a private locale so init_per_testcase already
%% cleaned up any prior load.
ensure_loaded_accepts_binary_path(Config) ->
    PathList = fixture(Config, "minimal_en.po"),
    PathBin = iolist_to_binary(PathList),
    ?assert(is_binary(PathBin)),
    %% The public spec for `ensure_loaded/3` is `file:filename()`
    %% (i.e. `string()`), but at runtime the loader normalises via
    %% `to_binary_path/1` and accepts a binary too. This test exists
    %% specifically to pin that binary-path behaviour. We cast at the
    %% boundary so eqwalizer sees the documented spec while the runtime
    %% test exercises the real binary branch.
    PathArg = eqwalizer:dynamic_cast(PathBin),
    ?assertEqual(
        {ok, 1},
        erli18n_server:ensure_loaded(
            default,
            <<"en_binpath">>,
            PathArg
        )
    ),
    ?assertEqual(
        {ok, <<"Bonjour">>},
        erli18n_server:lookup_singular(
            default,
            <<"en_binpath">>,
            undefined,
            <<"Hello">>
        )
    ).

%% When `emit_lookup_telemetry` is enabled, loading a catalog that has
%% fuzzy entries triggers a re-parse with `include_fuzzy => true` so
%% the count of dropped entries can be surfaced. Exercises the
%% telemetry-enabled branch of `maybe_emit_fuzzy_skip/5` and the
%% `Diff > 0 -> emit` clause inside it. We restore the env on exit so
%% the rest of the suite (and downstream suites) see the default.
ensure_loaded_fuzzy_skip_with_lookup_telemetry(Config) ->
    OldEnv = application:get_env(erli18n, emit_lookup_telemetry),
    application:set_env(erli18n, emit_lookup_telemetry, true),
    try
        Path = fixture(Config, "fuzzy_entry.po"),
        %% Default load drops the 1 fuzzy entry; the count is computed
        %% by re-parsing with include_fuzzy => true.
        ?assertEqual(
            {ok, 1},
            erli18n_server:ensure_loaded(default, <<"fr">>, Path)
        ),
        %% Non-fuzzy entry is reachable.
        ?assertEqual(
            {ok, <<"vivant">>},
            erli18n_server:lookup_singular(
                default,
                <<"fr">>,
                undefined,
                <<"alive">>
            )
        )
    after
        restore_env(emit_lookup_telemetry, OldEnv)
    end.

%% Same opt-in flag, but the loaded fixture has zero fuzzy entries —
%% Diff = 0, so the telemetry emit is skipped. Exercises the `false`
%% arm of `case Diff > 0`.
ensure_loaded_no_fuzzy_with_lookup_telemetry(Config) ->
    OldEnv = application:get_env(erli18n, emit_lookup_telemetry),
    application:set_env(erli18n, emit_lookup_telemetry, true),
    try
        Path = fixture(Config, "minimal_en.po"),
        ?assertEqual(
            {ok, 1},
            erli18n_server:ensure_loaded(default, <<"en">>, Path)
        ),
        ?assertEqual(
            {ok, <<"Bonjour">>},
            erli18n_server:lookup_singular(
                default,
                <<"en">>,
                undefined,
                <<"Hello">>
            )
        )
    after
        restore_env(emit_lookup_telemetry, OldEnv)
    end.

%% Restore an application env var to its prior value (or unset it if it
%% was unset before). Helper used by the two telemetry-enabled cases.
restore_env(Key, undefined) ->
    application:unset_env(erli18n, Key);
restore_env(Key, {ok, Value}) ->
    application:set_env(erli18n, Key, Value).

%% When the catalog header is missing entirely, lookup_plural_form/5
%% returns `undefined` (no fallback rule is even tried). Exercises the
%% `undefined -> undefined` clause of the case on lookup_header inside
%% lookup_plural_form/5.
lookup_plural_form_unloaded_catalog(_Config) ->
    ?assertEqual(
        undefined,
        erli18n_server:lookup_header(default, <<"never_loaded">>)
    ),
    ?assertEqual(
        undefined,
        erli18n_server:lookup_plural_form(
            default,
            <<"never_loaded">>,
            undefined,
            <<"tree">>,
            1
        )
    ).

%% which_keys/2 must filter out rows that belong to other catalogs.
%% Loading two catalogs (different Domain or Locale) and querying for
%% only one of them must yield only that catalog's keys, exercising
%% the catch-all `collect_key(_, _, _Obj, Acc) -> Acc` clause that
%% drops rows for the non-matching catalog.
which_keys_filters_other_catalogs(_Config) ->
    %% Catalog A: (default, fr) — 1 singular.
    ok = erli18n_server:insert_singular(
        default,
        <<"fr">>,
        undefined,
        <<"Hello">>,
        <<"Bonjour">>
    ),
    %% Catalog B (different locale): (default, es) — 1 singular + 1 plural.
    ok = erli18n_server:insert_singular(
        default,
        <<"es">>,
        undefined,
        <<"Hello">>,
        <<"Hola">>
    ),
    ok = erli18n_server:insert_plural(
        default,
        <<"es">>,
        undefined,
        <<"tree">>,
        [{0, <<"arbol">>}, {1, <<"arboles">>}]
    ),
    %% which_keys for (default, fr) returns only the fr key — the es
    %% rows fall into the catch-all and are dropped.
    KeysFr = erli18n_server:which_keys(default, <<"fr">>),
    ?assertEqual([{singular, undefined, <<"Hello">>}], KeysFr),
    %% Sanity: querying the other catalog returns its rows.
    KeysEs = lists:sort(erli18n_server:which_keys(default, <<"es">>)),
    ?assertEqual(
        [
            {plural, undefined, <<"tree">>},
            {singular, undefined, <<"Hello">>}
        ],
        KeysEs
    ).
