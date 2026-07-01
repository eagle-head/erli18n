-module(erli18n_register_compiled_SUITE).

%% Functional Common Test suite for the serialized compiled-catalog
%% registration API `erli18n_server:register_compiled_many/1`. The function
%% installs an ALREADY-parsed + ALREADY-compiled catalog
%% through the EXISTING single-mutation critical section (it reuses the same
%% `{commit_many, _}` server message and `do_commit_many/1` install path the
%% bulk `.po` loader uses), so the catalog becomes readable through the
%% lock-free `lookup_*` hot path with NO boot-time parse/compile.

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
    register_single_installs_and_reads/1,
    register_returns_ensure_result_ok_n/1,
    register_plural_form_is_evaluated/1,
    register_header_surfaces_baked_values/1,
    register_idempotent_second_call_is_already/1,
    register_does_not_overwrite_existing/1,
    register_batch_installs_all/1,
    register_empty_list_is_empty/1,
    register_mixed_already_and_new/1,
    register_duplicate_in_one_batch_second_is_already/1
]).

all() ->
    [
        register_single_installs_and_reads,
        register_returns_ensure_result_ok_n,
        register_plural_form_is_evaluated,
        register_header_surfaces_baked_values,
        register_idempotent_second_call_is_already,
        register_does_not_overwrite_existing,
        register_batch_installs_all,
        register_empty_list_is_empty,
        register_mixed_already_and_new,
        register_duplicate_in_one_batch_second_is_already
    ].

init_per_suite(Config) ->
    {ok, _Apps} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    ok.

init_per_testcase(_TC, Config) ->
    %% Mirror erli18n_server_SUITE: start each case from a clean catalog set.
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

register_single_installs_and_reads(_Config) ->
    Entries = [
        {singular, undefined, ~"Hello", ~"Bonjour"},
        {singular, ~"menu", ~"File", ~"Fichier"}
    ],
    Spec = {default, ~"fr", Entries, fallback_baked("fr.po", 2)},
    [{default, ~"fr", {ok, 2}}] = erli18n_server:register_compiled_many([Spec]),
    ?assertEqual(
        {ok, ~"Bonjour"},
        erli18n_server:lookup_singular(default, ~"fr", undefined, ~"Hello")
    ),
    ?assertEqual(
        {ok, ~"Fichier"},
        erli18n_server:lookup_singular(default, ~"fr", ~"menu", ~"File")
    ),
    %% A miss is still a miss (the registered catalog has no such key).
    ?assertEqual(
        undefined,
        erli18n_server:lookup_singular(default, ~"fr", undefined, ~"Missing")
    ).

register_returns_ensure_result_ok_n(_Config) ->
    Entries = [{singular, undefined, ~"a", ~"A"}],
    Spec = {default, ~"de", Entries, fallback_baked("de.po", 1)},
    ?assertEqual(
        [{default, ~"de", {ok, 1}}],
        erli18n_server:register_compiled_many([Spec])
    ).

register_plural_form_is_evaluated(_Config) ->
    %% A real compiled rule (n > 1) baked into the header: the lock-free
    %% plural read evaluates it WITHOUT any boot-time compile.
    Compiled = compile(~"nplurals=2; plural=(n > 1);"),
    Entries = [
        {plural, undefined, ~"file", ~"files", [{0, ~"fichier"}, {1, ~"fichiers"}]}
    ],
    Baked = compiled_baked(Compiled, ~"(n > 1)", "fr.po", 1),
    Spec = {default, ~"fr", Entries, Baked},
    [{default, ~"fr", {ok, 1}}] = erli18n_server:register_compiled_many([Spec]),
    ?assertEqual(
        {ok, ~"fichier"},
        erli18n_server:lookup_plural_form(default, ~"fr", undefined, ~"file", 1)
    ),
    ?assertEqual(
        {ok, ~"fichiers"},
        erli18n_server:lookup_plural_form(default, ~"fr", undefined, ~"file", 2)
    ),
    ?assertEqual(
        {ok, ~"fichiers"},
        erli18n_server:lookup_plural_form(default, ~"fr", undefined, ~"file", 42)
    ).

register_header_surfaces_baked_values(_Config) ->
    Divergence = {plural_divergence, ~"(n != 1)", ~"(n > 1)"},
    Compiled = compile(~"nplurals=2; plural=(n != 1);"),
    Baked = #{
        plural => Compiled,
        plural_raw => ~"(n != 1)",
        po_path => "pt_BR.po",
        divergence => Divergence,
        fuzzy_included => true,
        num_entries => 1
    },
    Entries = [{singular, undefined, ~"Hi", ~"Oi"}],
    Spec = {default, ~"pt_BR", Entries, Baked},
    [{default, ~"pt_BR", {ok, 1}}] =
        erli18n_server:register_compiled_many([Spec]),
    {ok, Header} = erli18n_server:lookup_header(default, ~"pt_BR"),
    %% The baked fields are surfaced verbatim through lookup_header/2.
    ?assertEqual("pt_BR.po", maps:get(po_path, Header)),
    ?assertEqual(Divergence, maps:get(divergence, Header)),
    ?assertEqual(true, maps:get(fuzzy_included, Header)),
    ?assertEqual(1, maps:get(num_entries, Header)),
    ?assertEqual(Compiled, maps:get(plural, Header)),
    ?assertEqual(~"(n != 1)", maps:get(plural_raw, Header)),
    %% loaded_at is STAMPED at registration (it is NOT a baked field).
    ?assert(is_integer(maps:get(loaded_at, Header))).

register_idempotent_second_call_is_already(_Config) ->
    Entries = [{singular, undefined, ~"a", ~"A"}],
    Spec = {default, ~"es", Entries, fallback_baked("es.po", 1)},
    [{default, ~"es", {ok, 1}}] = erli18n_server:register_compiled_many([Spec]),
    %% Second registration of the same catalog is the idempotent fast-path.
    ?assertEqual(
        [{default, ~"es", {ok, already}}],
        erli18n_server:register_compiled_many([Spec])
    ).

register_does_not_overwrite_existing(_Config) ->
    First = [{singular, undefined, ~"k", ~"first"}],
    ok = ok_install(default, ~"it", First, "it.po", 1),
    %% A second register with DIFFERENT entries for the same catalog must be
    %% an idempotent no-op (ensure semantics): the first catalog is preserved.
    Second = [{singular, undefined, ~"k", ~"second"}],
    Spec2 = {default, ~"it", Second, fallback_baked("it.po", 1)},
    ?assertEqual(
        [{default, ~"it", {ok, already}}],
        erli18n_server:register_compiled_many([Spec2])
    ),
    ?assertEqual(
        {ok, ~"first"},
        erli18n_server:lookup_singular(default, ~"it", undefined, ~"k")
    ).

register_batch_installs_all(_Config) ->
    Specs = [
        {default, ~"fr", [{singular, undefined, ~"x", ~"fr-x"}], fallback_baked("fr.po", 1)},
        {default, ~"de", [{singular, undefined, ~"x", ~"de-x"}], fallback_baked("de.po", 1)},
        {default, ~"es", [{singular, undefined, ~"x", ~"es-x"}], fallback_baked("es.po", 1)}
    ],
    Results = erli18n_server:register_compiled_many(Specs),
    ?assertEqual(3, length(Results)),
    ?assert(lists:member({default, ~"fr", {ok, 1}}, Results)),
    ?assert(lists:member({default, ~"de", {ok, 1}}, Results)),
    ?assert(lists:member({default, ~"es", {ok, 1}}, Results)),
    ?assertEqual(
        {ok, ~"fr-x"},
        erli18n_server:lookup_singular(default, ~"fr", undefined, ~"x")
    ),
    ?assertEqual(
        {ok, ~"de-x"},
        erli18n_server:lookup_singular(default, ~"de", undefined, ~"x")
    ),
    ?assertEqual(
        {ok, ~"es-x"},
        erli18n_server:lookup_singular(default, ~"es", undefined, ~"x")
    ).

register_empty_list_is_empty(_Config) ->
    ?assertEqual([], erli18n_server:register_compiled_many([])).

register_mixed_already_and_new(_Config) ->
    %% Pre-register one catalog, then a batch containing that one plus a new
    %% one: the existing reports `already`, the new one reports `{ok, N}`.
    ok = ok_install(default, ~"fr", [{singular, undefined, ~"x", ~"fr-x"}], "fr.po", 1),
    Specs = [
        {default, ~"fr", [{singular, undefined, ~"x", ~"OTHER"}], fallback_baked("fr.po", 1)},
        {default, ~"de", [{singular, undefined, ~"x", ~"de-x"}], fallback_baked("de.po", 1)}
    ],
    Results = erli18n_server:register_compiled_many(Specs),
    ?assert(lists:member({default, ~"fr", {ok, already}}, Results)),
    ?assert(lists:member({default, ~"de", {ok, 1}}, Results)),
    %% The pre-existing catalog was NOT overwritten by the batch.
    ?assertEqual(
        {ok, ~"fr-x"},
        erli18n_server:lookup_singular(default, ~"fr", undefined, ~"x")
    ).

register_duplicate_in_one_batch_second_is_already(_Config) ->
    %% Two specs for the SAME (Domain, Locale) in ONE batch: the batch is
    %% processed in order, so the first install succeeds and every later
    %% duplicate takes the idempotent fast-path with `{ok, already}`. The
    %% installed value is the FIRST one; the duplicates never overwrite it.
    First =
        {default, ~"dup", [{singular, undefined, ~"k", ~"first"}], fallback_baked("dup.po", 1)},
    Second =
        {default, ~"dup", [{singular, undefined, ~"k", ~"SECOND"}], fallback_baked("dup.po", 1)},
    Third =
        {default, ~"dup", [{singular, undefined, ~"k", ~"THIRD"}], fallback_baked("dup.po", 1)},
    Results = erli18n_server:register_compiled_many([First, Second, Third]),
    ?assertEqual(
        [
            {default, ~"dup", {ok, 1}},
            {default, ~"dup", {ok, already}},
            {default, ~"dup", {ok, already}}
        ],
        Results
    ),
    %% The read path serves the FIRST value; the duplicates were discarded.
    ?assertEqual(
        {ok, ~"first"},
        erli18n_server:lookup_singular(default, ~"dup", undefined, ~"k")
    ).

%% =========================
%% Helpers
%% =========================

ok_install(D, L, Entries, PoPath, NumEntries) ->
    Spec = {D, L, Entries, fallback_baked(PoPath, NumEntries)},
    [{D, L, {ok, NumEntries}}] = erli18n_server:register_compiled_many([Spec]),
    ok.

fallback_baked(PoPath, NumEntries) ->
    #{
        plural => fallback,
        plural_raw => erli18n_plural:fallback_rule(),
        po_path => PoPath,
        divergence => none,
        fuzzy_included => false,
        num_entries => NumEntries
    }.

compiled_baked(Compiled, PluralRaw, PoPath, NumEntries) ->
    #{
        plural => Compiled,
        plural_raw => PluralRaw,
        po_path => PoPath,
        divergence => none,
        fuzzy_included => false,
        num_entries => NumEntries
    }.

compile(Raw) ->
    {ok, Compiled} = erli18n_plural:compile(Raw),
    Compiled.
