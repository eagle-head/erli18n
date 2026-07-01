%%% =====================================================================
%%% Common Test suite filling the remaining behavioural corners of
%%% `erli18n_server`: the `infinity` / invalid anti-DoS bounds, the
%%% header-only (empty) catalog path, idempotent (re)loads, and
%%% crash-recovery durability via `persistent_term` (node-global storage that
%%% survives a writer crash with no heir). Each case drives a public entry
%%% point and asserts the observable result/state — input -> output.
%%% =====================================================================
-module(erli18n_server_coverage_SUITE).

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
    default_po_path_unknown_app/1,
    infinity_bounds_and_header_only_catalog/1,
    invalid_bound_is_explicit_error/1,
    ensure_loaded_is_idempotent/1,
    ensure_loaded_many_idempotent_within_batch/1,
    ensure_loaded_idempotent_under_concurrency/1,
    reload_header_only_catalog/1,
    crash_recovery_preserves_catalog/1,
    insert_plural_empty_form_list_is_noop/1,
    concurrent_read_during_reload/1,
    raising_telemetry_handler_does_not_break_load/1,
    duplicate_msgid_in_one_po_last_wins/1
]).

%% Telemetry handler callback: telemetry refers to it by `{Module, Function}`.
-export([throwing_load_handler/4]).

all() ->
    [
        default_po_path_unknown_app,
        infinity_bounds_and_header_only_catalog,
        invalid_bound_is_explicit_error,
        ensure_loaded_is_idempotent,
        ensure_loaded_many_idempotent_within_batch,
        ensure_loaded_idempotent_under_concurrency,
        reload_header_only_catalog,
        crash_recovery_preserves_catalog,
        insert_plural_empty_form_list_is_noop,
        concurrent_read_during_reload,
        raising_telemetry_handler_does_not_break_load,
        duplicate_msgid_in_one_po_last_wins
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    ok.

init_per_testcase(_TC, Config) ->
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    ok = application:unset_env(erli18n, max_po_bytes),
    ok = application:unset_env(erli18n, max_po_entries),
    Config.

end_per_testcase(_TC, _Config) ->
    application:unset_env(erli18n, max_po_bytes),
    application:unset_env(erli18n, max_po_entries),
    ok.

%% =========================
%% Cases
%% =========================

default_po_path_unknown_app(_Config) ->
    %% An unknown OTP app surfaces a structured error (not a corrupt path).
    ?assertError(
        {priv_dir_not_found, no_such_app_xyz},
        erli18n_server:default_po_path(no_such_app_xyz, default, ~"pt")
    ).

infinity_bounds_and_header_only_catalog(Config) ->
    %% `infinity` disables the size/entry caps; a header-only `.po` loads with
    %% zero entries and indexes nothing, and which_keys/2 returns the empty set.
    ok = application:set_env(erli18n, max_po_bytes, infinity),
    ok = application:set_env(erli18n, max_po_entries, infinity),
    Path = fixture(Config, "header_only.po"),
    ?assertEqual({ok, 0}, erli18n_server:ensure_loaded(d_inf, ~"pt", Path)),
    ?assertEqual([], erli18n_server:which_keys(d_inf, ~"pt")).

invalid_bound_is_explicit_error(Config) ->
    %% A malformed bound env value is a deployment error and crashes with a
    %% descriptive payload rather than silently degrading.
    ok = application:set_env(erli18n, max_po_bytes, not_a_number),
    Path = fixture(Config, "header_only.po"),
    ?assertError(
        {invalid_erli18n_bound, not_a_number},
        erli18n_server:ensure_loaded(d_bad, ~"pt", Path)
    ).

ensure_loaded_is_idempotent(Config) ->
    %% A second ensure_loaded of an already-installed (Domain, Locale) is a
    %% no-op reported as {ok, already}.
    Path = fixture(Config, "singular_plural.po"),
    ?assertMatch({ok, N} when is_integer(N), erli18n_server:ensure_loaded(d_idem, ~"pt", Path)),
    ?assertEqual({ok, already}, erli18n_server:ensure_loaded(d_idem, ~"pt", Path)).

ensure_loaded_many_idempotent_within_batch(Config) ->
    %% Two specs for the SAME (Domain, Locale) in one batch: the first installs,
    %% the second is detected as already-present at commit time.
    Path = fixture(Config, "singular_plural.po"),
    Results = erli18n_server:ensure_loaded_many([
        {d_many, ~"pt", Path, #{}},
        {d_many, ~"pt", Path, #{}}
    ]),
    ?assertMatch([{d_many, ~"pt", {ok, _}}, {d_many, ~"pt", {ok, already}}], Results).

ensure_loaded_idempotent_under_concurrency(Config) ->
    %% Several loaders race on the SAME fresh (Domain, Locale). Released
    %% together, they all pass the lock-free EARLY idempotency check (none sees
    %% it loaded yet) and proceed to commit; the gen_server serializes the
    %% commits, so the first installs and the rest are caught by the re-check
    %% INSIDE the serialized commit. Exactly one install, the rest `already` —
    %% regardless of scheduling.
    Path = fixture(Config, "singular_plural.po"),
    Parent = self(),
    Barrier = make_ref(),
    Pids = [
        spawn(fun() ->
            receive
                Barrier -> ok
            end,
            Parent ! {self(), erli18n_server:ensure_loaded(d_race, ~"pt", Path)}
        end)
     || _ <- lists:seq(1, 8)
    ],
    _ = [P ! Barrier || P <- Pids],
    Results = [
        receive
            {P, R} -> R
        after 5000 -> ct:fail(timeout)
        end
     || P <- Pids
    ],
    Installs = [R || {ok, M} = R <- Results, is_integer(M)],
    Already = [R || R <- Results, R =:= {ok, already}],
    ?assertEqual(1, length(Installs)),
    ?assertEqual(7, length(Already)).

reload_header_only_catalog(Config) ->
    %% Reloading a header-only catalog re-installs it with no data rows (the
    %% empty-objects branch of the atomic swap).
    Path = fixture(Config, "header_only.po"),
    {ok, 0} = erli18n_server:ensure_loaded(d_reload, ~"pt", Path),
    ?assertEqual({ok, 0}, erli18n_server:reload(d_reload, ~"pt", Path)).

crash_recovery_preserves_catalog(Config) ->
    %% A catalog with singular AND plural entries survives a server crash
    %% because it lives in `persistent_term` (node-global, owned by the
    %% runtime — process-independent). On restart the server re-derives its
    %% observability view straight from persistent_term, so which_keys/2
    %% reports the same set afterwards. There is no index to rebuild from
    %% surviving rows; the catalog was never lost.
    Path = fixture(Config, "singular_plural.po"),
    {ok, _} = erli18n_server:ensure_loaded(d_crash, ~"pt", Path),
    Before = lists:sort(erli18n_server:which_keys(d_crash, ~"pt")),
    ?assert(length(Before) >= 2),
    OldPid = whereis(erli18n_server),
    true = is_pid(OldPid),
    exit(OldPid, kill),
    ok = wait_restarted(OldPid, 100),
    After = lists:sort(erli18n_server:which_keys(d_crash, ~"pt")),
    ?assertEqual(Before, After).

insert_plural_empty_form_list_is_noop(_Config) ->
    %% A plural insert carrying ZERO message forms writes no entries, so the
    %% empty-merge no-op fires: no persistent term is created, no catalog is
    %% registered (`ok`, nothing loaded, no keys). This drives the
    %% empty-entries arm of `erli18n_pt_store:merge_entries/3`.
    ?assertEqual(
        ok, erli18n_server:insert_plural(d_empty, ~"fr", undefined, ~"file", [])
    ),
    ?assertEqual([], erli18n_server:which_keys(d_empty, ~"fr")),
    ?assertNot(lists:keymember(d_empty, 1, erli18n_server:loaded_catalogs())).

%% =========================
%% Helpers
%% =========================

fixture(Config, Name) ->
    Dir = ?config(data_dir, Config),
    filename:join(Dir, Name).

%% Wait until the supervisor has restarted the registered server under a NEW
%% pid (and it answers a call).
wait_restarted(_OldPid, 0) ->
    ct:fail(server_not_restarted);
wait_restarted(OldPid, N) ->
    case whereis(erli18n_server) of
        New when is_pid(New), New =/= OldPid ->
            _ = erli18n_server:loaded_catalogs(),
            ok;
        _ ->
            timer:sleep(20),
            wait_restarted(OldPid, N - 1)
    end.

%% =========================
%% Adequacy: concurrency, dependency-failure isolation, duplicate resolution
%% =========================

%% Readers looking up a key in a tight loop while another process reloads the
%% SAME (Domain, Locale) between two catalogs that both define the key with a
%% DIFFERENT translation. Because a reload swaps the catalog atomically in
%% `persistent_term`, every concurrent read must observe EITHER the old OR the
%% new translation — never `undefined` (a torn / half-applied swap) and never a
%% crash. Pins the read-during-reload atomicity the idempotency test does not.
concurrent_read_during_reload(Config) ->
    PoA = write_temp_po(Config, "rr_a.po", entry_po(~"Hello", ~"OlaA")),
    PoB = write_temp_po(Config, "rr_b.po", entry_po(~"Hello", ~"OlaB")),
    {ok, _} = erli18n_server:ensure_loaded(d_rr, ~"pt", PoA),
    Parent = self(),
    Barrier = make_ref(),
    Readers = [
        spawn(fun() ->
            receive
                Barrier -> ok
            end,
            Reads = [
                erli18n_server:lookup_singular(d_rr, ~"pt", undefined, ~"Hello")
             || _ <- lists:seq(1, 200)
            ],
            Parent ! {self(), Reads}
        end)
     || _ <- lists:seq(1, 5)
    ],
    Reloader = spawn(fun() ->
        receive
            Barrier -> ok
        end,
        lists:foreach(
            fun(_) ->
                _ = erli18n_server:reload(d_rr, ~"pt", PoB),
                _ = erli18n_server:reload(d_rr, ~"pt", PoA)
            end,
            lists:seq(1, 50)
        )
    end),
    _ = [P ! Barrier || P <- [Reloader | Readers]],
    Batches = [
        receive
            {P, R} -> R
        after 10000 -> ct:fail(reader_timeout)
        end
     || P <- Readers
    ],
    Allowed = [{ok, ~"OlaA"}, {ok, ~"OlaB"}],
    lists:foreach(
        fun(Batch) ->
            lists:foreach(fun(Read) -> ?assert(lists:member(Read, Allowed)) end, Batch)
        end,
        Batches
    ).

%% A telemetry HANDLER that raises is isolated by the telemetry library (which
%% detaches the failing handler and logs), so an erli18n catalog load still
%% succeeds and the catalog is queryable. `erli18n_telemetry` deliberately does
%% NOT wrap `telemetry:execute` in its own try/catch — it relies on this
%% library contract — so this pins that a misbehaving telemetry consumer can
%% never break an erli18n operation.
raising_telemetry_handler_does_not_break_load(Config) ->
    _ = application:ensure_all_started(telemetry),
    Tid = ets:new(erli18n_th_probe, [public]),
    HandlerId = {?MODULE, make_ref()},
    ok = telemetry:attach(
        HandlerId,
        [erli18n, catalog, load, stop],
        fun ?MODULE:throwing_load_handler/4,
        Tid
    ),
    try
        Path = fixture(Config, "singular_plural.po"),
        Result = erli18n_server:ensure_loaded(d_th, ~"pt", Path),
        ?assertMatch({ok, N} when is_integer(N), Result),
        %% The handler DID fire (so the isolation is real, not vacuous)...
        ?assertEqual([{fired, true}], ets:lookup(Tid, fired)),
        %% ...and the load succeeded despite the handler crash.
        ?assertEqual(
            {ok, ~"Ola"}, erli18n_server:lookup_singular(d_th, ~"pt", undefined, ~"Hello")
        )
    after
        telemetry:detach(HandlerId),
        ets:delete(Tid)
    end.

throwing_load_handler(_Event, _Measurements, _Metadata, Tid) ->
    ets:insert(Tid, {fired, true}),
    error(intentional_handler_crash).

%% A single `.po` that declares the same `msgid` twice resolves deterministically
%% to LAST-WINS (parse keeps both entries in source order; the catalog map is
%% built left-to-right so the later translation overwrites the earlier). Pins the
%% resolution so a future first-wins / silent-drop regression is caught. NOTE:
%% GNU msgfmt would REJECT a duplicate msgid; erli18n is deliberately lenient
%% here, and this test documents that intentional divergence.
duplicate_msgid_in_one_po_last_wins(Config) ->
    Body = <<
        (po_header())/binary,
        "msgid \"Dup\"\nmsgstr \"First\"\n\n"
        "msgid \"Dup\"\nmsgstr \"Second\"\n"
    >>,
    Path = write_temp_po(Config, "dup.po", Body),
    {ok, _} = erli18n_server:ensure_loaded(d_dup, ~"pt", Path),
    ?assertEqual(
        {ok, ~"Second"}, erli18n_server:lookup_singular(d_dup, ~"pt", undefined, ~"Dup")
    ).

%% A minimal UTF-8 `.po` header (mirrors the committed fixtures).
po_header() ->
    <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
    >>.

%% A header plus one singular entry, as `.po` bytes.
entry_po(Msgid, Msgstr) ->
    <<
        (po_header())/binary,
        "msgid \"",
        Msgid/binary,
        "\"\nmsgstr \"",
        Msgstr/binary,
        "\"\n"
    >>.

write_temp_po(Config, Name, Body) ->
    Path = filename:join(?config(priv_dir, Config), Name),
    ok = file:write_file(Path, Body),
    Path.
