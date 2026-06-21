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
    insert_plural_empty_form_list_is_noop/1
]).

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
        insert_plural_empty_form_list_is_noop
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
