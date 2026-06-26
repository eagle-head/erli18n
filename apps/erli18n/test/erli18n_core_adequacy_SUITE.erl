%%% =====================================================================
%%% Core-runtime test-adequacy suite (erli18n facade + server + pt_store +
%%% app/sup lifecycle).
%%%
%%% GENERATED FROM THE TEST-ADEQUACY AUDIT (group: core-runtime). Each case pins
%%% one confirmed finding (or a tight cluster) that the existing suites reach but
%%% never assert, and is written to KILL the surviving mutant the finding names
%%% (erase-all-on-stop, the facade empty-translation guard, the server-boundary
%%% crash contract, the env-bound type/range validation, the f-family count
%%% auto-bind/override merge order, and the supervisor SupFlags/child spec).
%%%
%%% RED/GREEN EXPECTATION: GREEN. Every assertion below describes the CURRENT,
%%% intended behaviour of the production code, so the whole suite is expected to
%%% pass as-is. It would only go RED under the specific mutation each case
%%% targets (or a genuine regression).
%%%
%%% Setup mirrors erli18n_server_SUITE: the app is started in init_per_suite and
%%% every catalog is unloaded around each case. Several cases stop/restart the
%%% whole application; init_per_testcase/end_per_testcase therefore re-ensure the
%%% app is started and the store is empty so the lifecycle cases cannot leak
%%% state into their neighbours.
%%% =====================================================================
-module(erli18n_core_adequacy_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% `malformed_insert_crashes_server_catalog_survives/1` deliberately feeds
%% out-of-contract values to the write API (a negative plural form index and an
%% unknown entry tag) to drive the server-boundary crash. eqwalizer would
%% correctly reject those ill-typed literals statically, so re-announce the
%% boundary with a static annotation — the same zero-runtime-dep pattern the
%% runtime modules and erli18n_server_SUITE use.
-eqwalizer({nowarn_function, malformed_insert_crashes_server_catalog_survives/1}).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    stop_start_erases_loaded_catalogs/1,
    stop_start_lookup_returns_undefined/1,
    empty_translation_degrades_to_source/1,
    malformed_insert_crashes_server_catalog_survives/1,
    invalid_max_po_entries_is_explicit_error/1,
    negative_bound_rejected_zero_accepted/1,
    ngettextf_count_autobind_and_override/1,
    supervisor_init_supflags_and_childspec/1
]).

all() ->
    [
        stop_start_erases_loaded_catalogs,
        stop_start_lookup_returns_undefined,
        empty_translation_degrades_to_source,
        malformed_insert_crashes_server_catalog_survives,
        invalid_max_po_entries_is_explicit_error,
        negative_bound_rejected_zero_accepted,
        ngettextf_count_autobind_and_override,
        supervisor_init_supflags_and_childspec
    ].

init_per_suite(Config) ->
    {ok, _Apps} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(erli18n),
    ok.

init_per_testcase(_TC, Config) ->
    {ok, _Apps} = application:ensure_all_started(erli18n),
    unload_all(),
    Config.

end_per_testcase(_TC, _Config) ->
    %% A lifecycle case may have left the app stopped (or stopped then aborted on
    %% an assertion); re-ensure it is up and the store is clean so the next case
    %% starts from the same blank slate erli18n_server_SUITE relies on.
    {ok, _Apps} = application:ensure_all_started(erli18n),
    unload_all(),
    ok.

%% =========================
%% Test cases
%% =========================

%% F1 / F6: stop/start must not leak stale persistent_term catalogs. After an
%% application:stop the previously loaded (default, pt_BR) catalog is gone from
%% loaded_catalogs/0, and a re-run of ensure_loaded is a FRESH install ({ok, N}),
%% NOT the idempotent {ok, already} that a surviving header would produce.
%% Removing erli18n_pt_store:erase_all/0 from erli18n_app:stop/1 makes both
%% assertions fail (the catalog and its header survive the restart).
stop_start_erases_loaded_catalogs(_Config) ->
    Path = write_minimal_po(),
    try
        %% A real .po install carries a header, so ensure_loaded reports {ok, 1}
        %% and a second call would be {ok, already} — the idempotency signal this
        %% case proves is wiped on stop.
        ?assertEqual(
            {ok, 1},
            erli18n_server:ensure_loaded(default, ~"pt_BR", Path)
        ),
        ?assert(lists:keymember(~"pt_BR", 2, erli18n_server:loaded_catalogs())),
        ok = application:stop(erli18n),
        {ok, _Apps} = application:ensure_all_started(erli18n),
        %% The loaded-catalog index is empty after the restart ...
        ?assertEqual([], erli18n_server:loaded_catalogs()),
        ?assertNot(lists:keymember(~"pt_BR", 2, erli18n_server:loaded_catalogs())),
        %% ... and re-loading is a genuine fresh install, not {ok, already}.
        ?assertEqual(
            {ok, 1},
            erli18n_server:ensure_loaded(default, ~"pt_BR", Path)
        )
    after
        _ = erli18n_server:unload(default, ~"pt_BR"),
        _ = file:delete(Path)
    end.

%% F7 / F8: the erase-all-on-stop guarantee, observed through the read path. A
%% key that hit before the stop returns undefined after the restart, and the
%% loaded-catalog list is empty. Deleting erase_all/0 from stop/1 leaves the
%% node-global persistent_term catalog installed and the lookup would still hit.
stop_start_lookup_returns_undefined(_Config) ->
    ok = erli18n_server:insert_singular(
        default, ~"pt_BR", undefined, ~"Hello", ~"Olá"
    ),
    ?assertEqual(
        {ok, ~"Olá"},
        erli18n_server:lookup_singular(default, ~"pt_BR", undefined, ~"Hello")
    ),
    ok = application:stop(erli18n),
    {ok, _Apps} = application:ensure_all_started(erli18n),
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(default, ~"pt_BR", undefined, ~"Hello")
    ),
    ?assertEqual([], erli18n_server:loaded_catalogs()).

%% F4: an empty stored translation must never surface past the facade. The store
%% genuinely holds the empty binary (the read path returns {ok, <<>>}), but
%% erli18n:gettext/3's `T =/= <<>>` guard degrades it to the source Msgid.
%% Dropping that guard makes gettext/3 return <<>> and the assertion fails. The
%% plural arm shows the same: with no Plural-Forms header the empty forms are
%% never read and ngettext degrades to Msgid (N==1) / MsgidPlural (N/=1).
empty_translation_degrades_to_source(_Config) ->
    ok = erli18n_server:insert_singular(
        default, ~"pt", undefined, ~"k", ~""
    ),
    %% The empty binary really is in the store (the read path returns it).
    ?assertEqual(
        {ok, ~""},
        erli18n_server:lookup_singular(default, ~"pt", undefined, ~"k")
    ),
    %% But the public facade returns the source Msgid, never the empty binary.
    ?assertEqual(~"k", erli18n:gettext(default, ~"k", ~"pt")),
    ok = erli18n_server:insert_plural(
        default, ~"pt", undefined, ~"file", [{0, ~""}, {1, ~""}]
    ),
    ?assertEqual(~"file", erli18n:ngettext(default, ~"file", ~"files", 1, ~"pt")),
    ?assertEqual(~"files", erli18n:ngettext(default, ~"file", ~"files", 2, ~"pt")).

%% F5: a malformed entry passes the write API's top-level shape guard but crashes
%% the shared writer in erli18n_pt_store:put_entry — a loud crash-by-contract, not
%% a silently stored bad row. Drive it through erli18n_server (not pt_store
%% directly): the caller gets the propagated server exit, the supervisor restarts
%% the worker with a new pid, and every previously loaded catalog stays intact
%% (persistent_term is node-global and outlives the crash). Flipping the
%% `Idx >= 0` guard or adding a catch-all put_entry clause would let the bad row
%% store with no crash, so the ?assertExit would fail.
malformed_insert_crashes_server_catalog_survives(_Config) ->
    ok = erli18n_server:insert_singular(
        default, ~"pt_BR", undefined, ~"Hello", ~"Olá"
    ),
    Pid0 = server_pid(),
    %% Negative form index: passes is_list(Entries) but crashes put_entry.
    ?assertExit(
        {{function_clause, _}, _},
        erli18n_server:insert_plural(
            default, ~"fr", undefined, ~"file", [{-1, ~"x"}]
        )
    ),
    Pid1 = wait_for_new_worker(Pid0, 100),
    ?assertNotEqual(Pid0, Pid1),
    %% The pre-existing catalog survived the writer crash untouched.
    ?assertEqual(
        {ok, ~"Olá"},
        erli18n_server:lookup_singular(default, ~"pt_BR", undefined, ~"Hello")
    ),
    %% Unknown entry tag: no matching put_entry clause -> server crashes again.
    ?assertExit(
        {{function_clause, _}, _},
        erli18n_server:insert_catalog(
            default, ~"fr", [{bogus, undefined, ~"k", ~"v"}]
        )
    ),
    Pid2 = wait_for_new_worker(Pid1, 100),
    ?assertNotEqual(Pid1, Pid2),
    ?assertEqual(
        {ok, ~"Olá"},
        erli18n_server:lookup_singular(default, ~"pt_BR", undefined, ~"Hello")
    ),
    %% The restarted worker is a functional writer again.
    ok = erli18n_server:insert_singular(
        default, ~"pt_BR", undefined, ~"Bye", ~"Adeus"
    ),
    ?assertEqual(
        {ok, ~"Adeus"},
        erli18n_server:lookup_singular(default, ~"pt_BR", undefined, ~"Bye")
    ).

%% F2 / F11: a wrong-typed max_po_entries env value is a loud deployment error.
%% With max_po_entries = not_a_number and Opts = #{} (default path taken),
%% ensure_loaded crashes with error({invalid_erli18n_bound, not_a_number}) BEFORE
%% any mutation — no catalog is installed (lookup_header stays undefined). This is
%% the same loud-config contract erli18n_server_coverage_SUITE proves for the
%% bytes cap, here for the entries cap (narrow_bound's wrong-type clause).
invalid_max_po_entries_is_explicit_error(_Config) ->
    Path = write_minimal_po(),
    try
        with_env(max_po_entries, not_a_number, fun() ->
            ?assertError(
                {invalid_erli18n_bound, not_a_number},
                erli18n_server:ensure_loaded(default, ~"pt", Path, #{})
            ),
            ?assertEqual(
                undefined,
                erli18n_server:lookup_header(default, ~"pt")
            )
        end)
    after
        _ = file:delete(Path)
    end.

%% F10: the N >= 0 boundary of narrow_bound. A negative configured bound is out of
%% range and crashes with error({invalid_erli18n_bound, -1}); the off-by-one
%% neighbour 0 is ACCEPTED as a bound (no crash) — the load proceeds and is
%% rejected by the entry cap instead ({error, {too_many_entries, 1, 0}}). Pinning
%% both sides kills a mutated guard (N > 0 would crash on 0; N >= -1 would accept
%% -1).
negative_bound_rejected_zero_accepted(_Config) ->
    Path = write_minimal_po(),
    try
        with_env(max_po_entries, -1, fun() ->
            ?assertError(
                {invalid_erli18n_bound, -1},
                erli18n_server:ensure_loaded(default, ~"neg", Path, #{})
            )
        end),
        with_env(max_po_entries, 0, fun() ->
            ?assertEqual(
                {error, {too_many_entries, 1, 0}},
                erli18n_server:ensure_loaded(default, ~"zero", Path, #{})
            )
        end)
    after
        _ = erli18n_server:unload(default, ~"zero"),
        _ = file:delete(Path)
    end.

%% F3: the f-family Bindings parameter, count auto-bind and caller-override
%% partitions. No catalog is loaded for this locale, so the facade falls back to
%% the Msgid/MsgidPlural (each carrying a %{count} placeholder) and interpolation
%% still runs over it. Empty bindings substitute N (auto-bind path: bind_count
%% merges #{count => N}); a caller-supplied count overrides N in the TEXT while N
%% still drives plural-FORM selection (singular vs plural). Dropping the auto-bind
%% leaves "%{count}" literal; swapping the maps:merge order makes the override
%% case substitute N instead of 99 — either mutation fails an assertion.
ngettextf_count_autobind_and_override(_Config) ->
    Loc = ~"zz_autobind",
    %% Auto-bind: count => N is substituted from the empty map.
    ?assertEqual(
        ~"1 file",
        erli18n:ngettextf(default, ~"%{count} file", ~"%{count} files", 1, Loc, #{})
    ),
    ?assertEqual(
        ~"3 files",
        erli18n:ngettextf(default, ~"%{count} file", ~"%{count} files", 3, Loc, #{})
    ),
    %% Override wins in the text; N (not the override) still selects the form.
    ?assertEqual(
        ~"99 file",
        erli18n:ngettextf(
            default, ~"%{count} file", ~"%{count} files", 1, Loc, #{count => 99}
        )
    ),
    ?assertEqual(
        ~"99 files",
        erli18n:ngettextf(
            default, ~"%{count} file", ~"%{count} files", 3, Loc, #{count => 99}
        )
    ).

%% F9 / F12 / F13: the supervisor contract is value-asserted directly from the
%% pure, side-effect-free erli18n_sup:init([]). Pins strategy=one_for_one,
%% intensity=5, period=10 and the single child spec (id, start, restart=permanent,
%% shutdown=5000, type=worker, modules). Mutating intensity, period, restart
%% flavour, or the shutdown value changes restart semantics with zero failing
%% assertion today — each assertion below catches exactly one such mutant.
supervisor_init_supflags_and_childspec(_Config) ->
    {ok, {SupFlags, ChildSpecs}} = erli18n_sup:init([]),
    ?assertEqual(one_for_one, maps:get(strategy, SupFlags)),
    ?assertEqual(5, maps:get(intensity, SupFlags)),
    ?assertEqual(10, maps:get(period, SupFlags)),
    ?assertMatch([_], ChildSpecs),
    [Child] = ChildSpecs,
    ?assertEqual(erli18n_server, maps:get(id, Child)),
    ?assertEqual({erli18n_server, start_link, []}, maps:get(start, Child)),
    ?assertEqual(permanent, maps:get(restart, Child)),
    ?assertEqual(5000, maps:get(shutdown, Child)),
    ?assertEqual(worker, maps:get(type, Child)),
    ?assertEqual([erli18n_server], maps:get(modules, Child)).

%% =========================
%% Helpers
%% =========================

%% Unload every currently loaded catalog (mirrors erli18n_server_SUITE's
%% per-testcase reset).
unload_all() ->
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    ok.

%% Narrow the registered server name to a concrete pid (the only legal value for
%% a running gen_server); a missing process is a setup failure for these cases.
server_pid() ->
    case whereis(erli18n_server) of
        P when is_pid(P) -> P;
        Other -> error({erli18n_server_not_running, Other})
    end.

%% Run `Fun` with `Key` temporarily set in the erli18n app env, restoring the
%% prior value (or unsetting it if it had none) afterwards even on a crash.
with_env(Key, Val, Fun) ->
    Orig = application:get_env(erli18n, Key),
    ok = application:set_env(erli18n, Key, Val),
    try
        Fun()
    after
        case Orig of
            undefined -> application:unset_env(erli18n, Key);
            {ok, Prev} -> application:set_env(erli18n, Key, Prev)
        end
    end.

%% Write a minimal valid .po (one singular "Hello" -> "Olá") to a unique temp
%% path and return it. Mirrors erli18n_server_SUITE's fixture writer.
write_minimal_po() ->
    Path =
        "/tmp/erli18n_core_adq_" ++
            integer_to_list(erlang:unique_integer([positive])) ++ ".po",
    Po =
        <<
            "msgid \"\"\n"
            "msgstr \"\"\n"
            "\"Content-Type: text/plain; charset=UTF-8\\n\"\n\n"
            "msgid \"Hello\"\n"
            "msgstr \"Olá\"\n"/utf8
        >>,
    ok = file:write_file(Path, Po),
    Path.

%% Poll until the registered worker is a live pid different from the one that was
%% killed. Bounded retries keep the case from hanging if the supervisor never
%% brings the worker back.
wait_for_new_worker(_OldPid, 0) ->
    error(worker_not_restarted);
wait_for_new_worker(OldPid, Retries) ->
    case whereis(erli18n_server) of
        P when is_pid(P), P =/= OldPid ->
            P;
        _ ->
            timer:sleep(20),
            wait_for_new_worker(OldPid, Retries - 1)
    end.
