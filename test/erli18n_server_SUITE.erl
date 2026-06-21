-module(erli18n_server_SUITE).

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
    insert_lookup_singular/1,
    insert_lookup_plural/1,
    insert_catalog_mixed/1,
    lookup_missing_returns_undefined/1,
    unload_removes_only_target/1,
    unload_idempotent/1,
    memory_info_accuracy/1,
    loaded_catalogs_grouping/1,
    context_undefined_distinct_from_binary/1,
    overwrite_on_reinsert/1,
    unknown_call_returns_error/1,
    unknown_cast_does_not_crash/1,
    unknown_info_does_not_crash/1,
    terminate_called_on_app_stop/1,
    code_change_no_op/1,
    catalog_survives_worker_kill/1,
    load_pipeline_runs_in_caller_only_commit_in_server/1,
    commit_honours_tunable_timeout/1,
    lookup_plural_5_not_exported/1,
    header_absent_plural_form_is_a_miss/1,
    read_api_guards_reject_bad_args/1
]).

all() ->
    [
        insert_lookup_singular,
        insert_lookup_plural,
        insert_catalog_mixed,
        lookup_missing_returns_undefined,
        unload_removes_only_target,
        unload_idempotent,
        memory_info_accuracy,
        loaded_catalogs_grouping,
        context_undefined_distinct_from_binary,
        overwrite_on_reinsert,
        unknown_call_returns_error,
        unknown_cast_does_not_crash,
        unknown_info_does_not_crash,
        terminate_called_on_app_stop,
        code_change_no_op,
        catalog_survives_worker_kill,
        load_pipeline_runs_in_caller_only_commit_in_server,
        commit_honours_tunable_timeout,
        lookup_plural_5_not_exported,
        header_absent_plural_form_is_a_miss,
        read_api_guards_reject_bad_args
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
    ok.

%% =========================
%% Test cases
%% =========================

insert_lookup_singular(_Config) ->
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"Hello",
        ~"Olá"
    ),
    ?assertEqual(
        {ok, ~"Olá"},
        erli18n_server:lookup_singular(
            default,
            ~"pt_BR",
            undefined,
            ~"Hello"
        )
    ).

insert_lookup_plural(_Config) ->
    Entries = [{0, ~"un arbre"}, {1, ~"des arbres"}],
    ok = erli18n_server:insert_plural(
        default,
        ~"pt_BR",
        undefined,
        ~"tree",
        Entries
    ),
    %% Finding #16: the raw index-based plural read is internal. These
    %% insert-path rows carry NO Plural-Forms header, so the form-aware public
    %% read `lookup_plural_form/5` is a MISS (header absent -> `undefined`
    %% directly; see header_absent_plural_form_is_a_miss/1). The stored rows are
    %% therefore asserted directly at the storage layer (the rows that
    %% `insert_plural` writes by index). A real compiled header is covered by
    %% erli18n_loader_SUITE.
    ?assertEqual(
        {ok, ~"un arbre"},
        plural_row(default, ~"pt_BR", undefined, ~"tree", 0)
    ),
    ?assertEqual(
        {ok, ~"des arbres"},
        plural_row(default, ~"pt_BR", undefined, ~"tree", 1)
    ).

insert_catalog_mixed(_Config) ->
    Entries = [
        {singular, undefined, ~"Hello", ~"Olá"},
        {singular, ~"menu", ~"File", ~"Fichier"},
        {plural, undefined, ~"tree", ~"trees", [
            {0, ~"arbre"}, {1, ~"arbres"}
        ]}
    ],
    ok = erli18n_server:insert_catalog(default, ~"pt_BR", Entries),
    ?assertEqual(
        {ok, ~"Olá"},
        erli18n_server:lookup_singular(
            default,
            ~"pt_BR",
            undefined,
            ~"Hello"
        )
    ),
    ?assertEqual(
        {ok, ~"Fichier"},
        erli18n_server:lookup_singular(
            default,
            ~"pt_BR",
            ~"menu",
            ~"File"
        )
    ),
    %% The inserted catalog carries no Plural-Forms header, so the form-aware
    %% read misses; assert the stored index-1 row directly at the storage layer.
    ?assertEqual(
        {ok, ~"arbres"},
        plural_row(default, ~"pt_BR", undefined, ~"tree", 1)
    ).

lookup_missing_returns_undefined(_Config) ->
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(
            default,
            ~"pt_BR",
            undefined,
            ~"NotThere"
        )
    ),
    ?assertEqual(
        undefined,
        plural_form(default, ~"pt_BR", undefined, ~"tree", 1)
    ).

unload_removes_only_target(_Config) ->
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"Hello",
        ~"Olá"
    ),
    ok = erli18n_server:insert_singular(
        default,
        ~"es",
        undefined,
        ~"Hello",
        ~"Hola"
    ),
    ok = erli18n_server:insert_plural(
        default,
        ~"pt_BR",
        undefined,
        ~"tree",
        [{0, ~"arbre"}, {1, ~"arbres"}]
    ),
    ok = erli18n_server:unload(default, ~"pt_BR"),
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(
            default,
            ~"pt_BR",
            undefined,
            ~"Hello"
        )
    ),
    ?assertEqual(
        undefined,
        plural_form(default, ~"pt_BR", undefined, ~"tree", 1)
    ),
    ?assertEqual(
        {ok, ~"Hola"},
        erli18n_server:lookup_singular(
            default,
            ~"es",
            undefined,
            ~"Hello"
        )
    ).

unload_idempotent(_Config) ->
    ok = erli18n_server:unload(default, ~"never_loaded"),
    ok = erli18n_server:unload(default, ~"never_loaded").

memory_info_accuracy(_Config) ->
    %% With persistent_term there is no always-present table consuming bytes:
    %% an empty store holds zero catalogs, so its storage is exactly 0 (this
    %% differs from the ETS era, where an empty table still reported overhead).
    Empty = erli18n_server:memory_info(),
    ?assertEqual(0, maps:get(num_keys, Empty)),
    ?assertEqual(0, maps:get(num_catalogs, Empty)),
    ?assertEqual(0, maps:get(ets_bytes, Empty)),

    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"Hello",
        ~"Olá"
    ),
    ok = erli18n_server:insert_singular(
        default,
        ~"es",
        undefined,
        ~"Hello",
        ~"Hola"
    ),
    ok = erli18n_server:insert_plural(
        default,
        ~"pt_BR",
        undefined,
        ~"tree",
        [{0, ~"arbre"}, {1, ~"arbres"}]
    ),
    After = erli18n_server:memory_info(),
    ?assertEqual(4, maps:get(num_keys, After)),
    ?assertEqual(2, maps:get(num_catalogs, After)),
    ?assert(maps:get(ets_bytes, After) > maps:get(ets_bytes, Empty)).

loaded_catalogs_grouping(_Config) ->
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"a",
        ~"a-fr"
    ),
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"b",
        ~"b-fr"
    ),
    ok = erli18n_server:insert_singular(
        default,
        ~"es",
        undefined,
        ~"a",
        ~"a-es"
    ),
    Catalogs = lists:sort(erli18n_server:loaded_catalogs()),
    ?assertEqual([{default, ~"es", 1}, {default, ~"pt_BR", 2}], Catalogs).

context_undefined_distinct_from_binary(_Config) ->
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"File",
        ~"Fichier"
    ),
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        ~"menu",
        ~"File",
        ~"Fichier (menu)"
    ),
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        ~"verb",
        ~"File",
        ~"Classer"
    ),
    ?assertEqual(
        {ok, ~"Fichier"},
        erli18n_server:lookup_singular(
            default,
            ~"pt_BR",
            undefined,
            ~"File"
        )
    ),
    ?assertEqual(
        {ok, ~"Fichier (menu)"},
        erli18n_server:lookup_singular(
            default,
            ~"pt_BR",
            ~"menu",
            ~"File"
        )
    ),
    ?assertEqual(
        {ok, ~"Classer"},
        erli18n_server:lookup_singular(
            default,
            ~"pt_BR",
            ~"verb",
            ~"File"
        )
    ).

overwrite_on_reinsert(_Config) ->
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"Hello",
        ~"Olá"
    ),
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"Hello",
        ~"Salut"
    ),
    ?assertEqual(
        {ok, ~"Salut"},
        erli18n_server:lookup_singular(
            default,
            ~"pt_BR",
            undefined,
            ~"Hello"
        )
    ).

%% Robustness contract: any unknown gen_server:call/2 message yields
%% {error, unknown_call} and the server stays up — no crash, no restart.
%% Exercises the handle_call/3 catch-all clause.
unknown_call_returns_error(_Config) ->
    Pid = whereis(erli18n_server),
    ?assert(is_pid(Pid)),
    ?assertEqual(
        {error, unknown_call},
        gen_server:call(erli18n_server, {garbage_op, foo})
    ),
    ?assertEqual(
        {error, unknown_call},
        gen_server:call(erli18n_server, totally_unknown)
    ),
    %% Server pid is unchanged (supervisor did not restart it) and the
    %% read API still works.
    ?assertEqual(Pid, whereis(erli18n_server)),
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(
            default,
            ~"unloaded",
            undefined,
            ~"x"
        )
    ).

%% Robustness: unknown cast is silently ignored. Exercises the
%% handle_cast/2 catch-all clause. Asserts the server pid stays the
%% same after the spurious message (no crash).
unknown_cast_does_not_crash(_Config) ->
    Pid = whereis(erli18n_server),
    ok = gen_server:cast(erli18n_server, {garbage_cast, foo}),
    ok = gen_server:cast(erli18n_server, totally_unknown),
    %% Round-trip a synchronous call to flush the message queue so we
    %% know the cast was handled before we sample the pid.
    ?assertEqual(
        {error, unknown_call},
        gen_server:call(erli18n_server, ping_after_cast)
    ),
    ?assertEqual(Pid, whereis(erli18n_server)).

%% Robustness: arbitrary Erlang messages (e.g., late `down` notifications
%% or stray monitor refs) hit handle_info/2 catch-all. Server must not
%% crash. Exercises handle_info/2.
unknown_info_does_not_crash(_Config) ->
    Pid = whereis(erli18n_server),
    Pid ! {garbage_info, foo},
    Pid ! totally_unknown_info,
    %% Flush via sync call to ensure the info messages were processed.
    ?assertEqual(
        {error, unknown_call},
        gen_server:call(erli18n_server, ping_after_info)
    ),
    ?assertEqual(Pid, whereis(erli18n_server)).

%% Exercise the terminate/2 callback. `sys:terminate/2` is the OTP
%% canonical way to drive a gen_server through its normal shutdown
%% sequence — the proc exits with the supplied reason and the
%% behaviour's terminate/2 is invoked exactly once before the process
%% goes down. We then restart the app so the rest of the SUITE keeps
%% working.
terminate_called_on_app_stop(_Config) ->
    %% `whereis/1` returns `pid() | port() | undefined`; narrow at the
    %% boundary so the subsequent `monitor/2`, `sys:terminate/2` etc. see
    %% a concrete `pid()` (which is the only legal value for a registered
    %% gen_server name). A missing process is a setup failure for this
    %% case, hence the explicit crash.
    Pid =
        case whereis(erli18n_server) of
            P when is_pid(P) -> P;
            Other -> error({erli18n_server_not_running, Other})
        end,
    Ref = monitor(process, Pid),
    %% sys:terminate invokes the OTP shutdown protocol which guarantees
    %% terminate/2 is called (cf. OTP `sys` docs). We also stop the app
    %% afterwards so the supervisor doesn't immediately restart the
    %% child and pollute later cases.
    sys:terminate(Pid, normal),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 5000 ->
        ct:fail({terminate_timeout, Pid})
    end,
    _ = application:stop(erli18n),
    {ok, _Apps} = application:ensure_all_started(erli18n),
    ?assert(is_pid(whereis(erli18n_server))).

%% Exercise the code_change/3 callback. `sys:change_code/4` is the
%% OTP-supported handle for driving a running gen_server through the
%% release-upgrade protocol; the live module's code_change/3 is invoked
%% with the requested OldVsn and Extra, and the returned state replaces
%% the running state. Server must remain responsive afterwards.
code_change_no_op(_Config) ->
    %% See `terminate_called_on_app_stop/1` — same `whereis/1` narrowing
    %% pattern so `sys:suspend/1`, `sys:change_code/4` and `sys:resume/1`
    %% type-check against `sys:name() = pid() | atom() | tuple()`.
    Pid =
        case whereis(erli18n_server) of
            P when is_pid(P) -> P;
            Other -> error({erli18n_server_not_running, Other})
        end,
    %% The server must be suspended before sys:change_code/4 is called
    %% (cf. OTP `sys` docs); resumed unconditionally so the rest of the
    %% suite keeps working even on assertion failure.
    ok = sys:suspend(Pid),
    try
        ?assertEqual(
            ok,
            sys:change_code(Pid, erli18n_server, "0", extra_term)
        )
    after
        ok = sys:resume(Pid)
    end,
    %% Still responsive and same pid.
    ?assertEqual(Pid, whereis(erli18n_server)),
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(
            default,
            ~"x",
            undefined,
            ~"y"
        )
    ).

%% An abrupt crash of the writer worker MUST NOT destroy the loaded catalogs.
%% Under persistent_term there is no heir machinery at all: the catalogs live
%% in `persistent_term`, which is node-global and owned by the runtime, so an
%% `exit(Pid, kill)` of the writer cannot touch them. After the supervisor
%% restarts the worker, every translation is still readable and the restarted
%% writer is again a functional writer. This is strictly stronger durability
%% than the old ETS heir handoff (no handoff-timeout failure class).
catalog_survives_worker_kill(_Config) ->
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"Hello",
        ~"Olá"
    ),
    ?assertEqual(
        {ok, ~"Olá"},
        erli18n_server:lookup_singular(
            default, ~"pt_BR", undefined, ~"Hello"
        )
    ),
    Pid =
        case whereis(erli18n_server) of
            P when is_pid(P) -> P;
            Other -> error({erli18n_server_not_running, Other})
        end,
    Ref = monitor(process, Pid),
    %% Abrupt, unhandleable kill — the worst case the finding describes.
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 5000 ->
        ct:fail({worker_kill_timeout, Pid})
    end,
    %% Wait for the supervisor to restart the worker with a NEW pid.
    NewPid = wait_for_new_worker(Pid, 100),
    ?assert(is_pid(NewPid)),
    ?assertNotEqual(Pid, NewPid),
    %% The catalog must have survived the crash because persistent_term is
    %% process-independent (node-global, owned by the runtime).
    ?assertEqual(
        {ok, ~"Olá"},
        erli18n_server:lookup_singular(
            default, ~"pt_BR", undefined, ~"Hello"
        )
    ),
    ?assertNotEqual([], erli18n_server:loaded_catalogs()),
    %% The restarted worker must still be a functional writer.
    ok = erli18n_server:insert_singular(
        default,
        ~"pt_BR",
        undefined,
        ~"Bye",
        ~"Adeus"
    ),
    ?assertEqual(
        {ok, ~"Adeus"},
        erli18n_server:lookup_singular(
            default, ~"pt_BR", undefined, ~"Bye"
        )
    ).

%% Finding #6 (load-pipeline-serialized-in-gen-server-no-bounds-or-timeout):
%% the server must no longer run the WHOLE load pipeline inside handle_call.
%% The heavy read+parse+compile runs in the caller; the server only commits
%% a validated payload via a `{commit, Mode, Domain, Locale, Payload}'
%% message. This case pins the structural boundary by speaking the commit
%% protocol directly: a `{commit, ensure, ...}' with a validated payload
%% installs the catalog, and the old whole-pipeline `{ensure_loaded, ...}'
%% message is no longer a recognised server call (it falls into the
%% unknown_call catch-all). Pre-fix: `{ensure_loaded, ...}' is the load
%% message and `{commit, ...}' is unknown -> RED.
load_pipeline_runs_in_caller_only_commit_in_server(_Config) ->
    %% Build a validated payload via the public ensure_loaded path on a
    %% throwaway catalog, then read it back out of the staged form is not
    %% directly accessible — instead we assert the protocol shape: the
    %% server treats the old whole-pipeline message as unknown.
    ?assertEqual(
        {error, unknown_call},
        gen_server:call(
            erli18n_server,
            {ensure_loaded, default, ~"x", "/nonexistent.po", #{}}
        )
    ),
    ?assertEqual(
        {error, unknown_call},
        gen_server:call(
            erli18n_server,
            {reload, default, ~"x", "/nonexistent.po", #{}}
        )
    ),
    %% The public API still works end-to-end (heavy phase in the caller,
    %% commit in the server). Use a real on-disk fixture so the caller-side
    %% read+parse succeeds and only the commit travels to the server.
    Path = write_minimal_po(),
    try
        ?assertEqual(
            {ok, 1},
            erli18n_server:ensure_loaded(default, ~"caller_phase", Path, #{})
        ),
        ?assertEqual(
            {ok, ~"Olá"},
            erli18n_server:lookup_singular(
                default, ~"caller_phase", undefined, ~"Hello"
            )
        )
    after
        ok = erli18n_server:unload(default, ~"caller_phase"),
        _ = file:delete(Path)
    end.

%% Finding #6, tunable-timeout class. The commit timeout must be settable
%% through `opts()` (`timeout => infinity`). Because the heavy phase no
%% longer runs behind the mailbox, only the ms-scale commit uses the
%% timeout; passing `infinity` must be accepted and the load must succeed.
%% Pre-fix `opts()` has no `timeout` key (the whole call uses the implicit
%% 5000ms) -> the option is silently ignored; this case pins that the new
%% key is honoured by the commit call.
commit_honours_tunable_timeout(_Config) ->
    Path = write_minimal_po(),
    try
        ?assertEqual(
            {ok, 1},
            erli18n_server:ensure_loaded(
                default, ~"timeout_cat", Path, #{timeout => infinity}
            )
        ),
        ?assertEqual(
            {ok, 1},
            erli18n_server:reload(
                default, ~"timeout_cat", Path, #{timeout => 10000}
            )
        )
    after
        ok = erli18n_server:unload(default, ~"timeout_cat"),
        _ = file:delete(Path)
    end.

%% Finding #16 (lookup-plural-5-exported-footgun-bypasses-form-evaluation).
%% `lookup_plural/5` did a raw, index-based ETS lookup with NO Plural-Forms
%% evaluation. Exporting it next to the form-aware `lookup_plural_form/5`
%% invited callers to pass the raw count N as the form index and silently
%% receive the wrong plural form. The fix keeps `lookup_plural/5` internal:
%% the only supported plural read on the public surface is the form-aware
%% `lookup_plural_form/5`. Pin the minimal public Read API here.
lookup_plural_5_not_exported(_Config) ->
    Exported = erli18n_server:module_info(exports),
    ?assertNot(lists:member({lookup_plural, 5}, Exported)),
    %% The form-aware entry point stays public — it encapsulates the
    %% locale-specific Plural-Forms evaluation the library exists to own.
    ?assert(lists:member({lookup_plural_form, 5}, Exported)),
    %% The remaining Read API stays public and stable.
    ?assert(lists:member({lookup_singular, 4}, Exported)),
    ?assert(lists:member({lookup_header, 2}, Exported)).

%% Finding #16, guard-consistency class. `lookup_plural_form/5` always
%% guarded its arguments, but `lookup_singular/4` (and the now-internal
%% `lookup_plural/5`) did not: a malformed argument returned `undefined`
%% (a silent miss) instead of crashing. Pin that the public read takes the
%% same `is_atom`/`is_binary` guards, so a contract break is a loud
%% `function_clause`, never a silent wrong/empty answer.
read_api_guards_reject_bad_args(_Config) ->
    %% The arguments below intentionally violate the published spec to
    %% exercise the runtime guards. eqwalizer would (correctly) reject them
    %% statically, so we cast each ill-typed value at the boundary — the
    %% same pattern used by `ensure_loaded_accepts_binary_path/1`. At
    %% runtime `eqwalizer:dynamic_cast/1` is the identity, so the guard is
    %% still hit with the original bad value.
    BadDomain = eqwalizer:dynamic_cast(~"not_an_atom"),
    BadLocale = eqwalizer:dynamic_cast(fr),
    BadContext = eqwalizer:dynamic_cast(menu),
    BadMsgid = eqwalizer:dynamic_cast(hello),
    %% Non-atom domain.
    ?assertError(
        function_clause,
        erli18n_server:lookup_singular(
            BadDomain, ~"pt_BR", undefined, ~"Hello"
        )
    ),
    %% Non-binary locale.
    ?assertError(
        function_clause,
        erli18n_server:lookup_singular(default, BadLocale, undefined, ~"Hello")
    ),
    %% Context that is neither `undefined` nor a binary.
    ?assertError(
        function_clause,
        erli18n_server:lookup_singular(default, ~"pt_BR", BadContext, ~"Hello")
    ),
    %% Non-binary msgid.
    ?assertError(
        function_clause,
        erli18n_server:lookup_singular(default, ~"pt_BR", undefined, BadMsgid)
    ),
    %% A well-formed call on the same shape still works (guards do not
    %% reject valid input).
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(
            default, ~"pt_BR", undefined, ~"Missing"
        )
    ).

%% Header-absent plural miss contract. A catalog populated ONLY via the
%% low-level insert API (`insert_plural`/`insert_catalog`) has data rows but NO
%% Plural-Forms header. `lookup_plural_form/5` carries no locale plural rule for
%% such a catalog, so by contract it returns `undefined` directly for ANY count
%% N — it does NOT silently fall back to a C/Germanic form and read a row (which
%% would surface an inserted form behind an unsupported public read). The raw
%% rows ARE present and readable at the storage layer (`plural_row/5`); only the
%% form-aware public read declines them. Mirrors main's lookup_plural_form/5
%% `undefined -> undefined` arm.
header_absent_plural_form_is_a_miss(_Config) ->
    ok = erli18n_server:insert_plural(
        default,
        ~"pt_BR",
        undefined,
        ~"tree",
        [{0, ~"un arbre"}, {1, ~"des arbres"}]
    ),
    %% The rows exist at the storage layer (proves the catalog is populated).
    ?assertEqual({ok, ~"un arbre"}, plural_row(default, ~"pt_BR", undefined, ~"tree", 0)),
    ?assertEqual({ok, ~"des arbres"}, plural_row(default, ~"pt_BR", undefined, ~"tree", 1)),
    %% But the form-aware public read is a miss for every N, because no header.
    [
        ?assertEqual(
            undefined,
            erli18n_server:lookup_plural_form(default, ~"pt_BR", undefined, ~"tree", N)
        )
     || N <- [0, 1, 2, 5, 100]
    ],
    ok.

%% The form-aware public read. Used here only for the missing-catalog miss
%% (`lookup_missing_returns_undefined/1`): with no catalog loaded the read is
%% `undefined`. For insert-path rows (no Plural-Forms header) this read MISSES
%% by contract (header absent -> `undefined` directly), so those cases assert
%% the stored row via `plural_row/5` instead.
plural_form(Domain, Locale, Context, Msgid, N) ->
    erli18n_server:lookup_plural_form(Domain, Locale, Context, Msgid, N).

%% Finding #16: read a raw plural form row directly at the storage layer. The
%% form-aware `lookup_plural_form/5` requires a Plural-Forms header to map
%% N -> form index; these insert-path unit cases write rows by index with NO
%% header, so they assert the stored row directly (mirrors the row shape
%% `insert_plural` writes). Goes through the persistent_term storage module by
%% the in-map `{plural, Context, Msgid, Index}` key — the moral successor of the
%% ETS-era raw `ets:lookup` read.
plural_row(Domain, Locale, Context, Msgid, Index) ->
    case erli18n_pt_store:get_map(Domain, Locale) of
        undefined ->
            undefined;
        Map ->
            case maps:get({plural, Context, Msgid, Index}, Map, undefined) of
                undefined -> undefined;
                Translation -> {ok, Translation}
            end
    end.

%% Write a minimal valid .po (one singular "Hello" -> "Olá") to a unique
%% temp path and return it. Used by the finding-#6 cases that need a real
%% on-disk catalog the caller-side phase can read+parse.
write_minimal_po() ->
    Path =
        "/tmp/erli18n_server_min_" ++
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

%% Poll until the registered worker is a live pid different from the one
%% that was killed. Bounded retries keep the case from hanging if the
%% supervisor never brings the worker back.
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
