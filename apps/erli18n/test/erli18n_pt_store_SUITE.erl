-module(erli18n_pt_store_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    singular_hit/1,
    singular_miss/1,
    singular_byte_identical/1,
    plural_compiled/1,
    plural_fallback/1,
    plural_header_absent/1,
    plural_miss/1,
    header_lookup/1,
    reload_replaces/1,
    unload_idempotent/1,
    build_put_equals_load/1,
    merge_entries_creates_and_extends/1,
    merge_entries_empty_is_noop/1,
    merge_entries_bad_index_crashes/1,
    get_map_returns_whole_map/1,
    introspection_counts_and_keys/1,
    all_lists_loaded_catalogs/1,
    erase_all_clears_namespace/1,
    guards_reject_bad_args/1
]).

-define(D, erli18n_pt_test).
-define(L, <<"fr">>).

%% `guards_reject_bad_args/1` deliberately passes WRONG-typed arguments (a
%% binary where a domain atom is required, an atom where a locale binary is
%% required) to assert the store's guards reject them with `function_clause`.
%% eqwalizer cannot see that this is intentional, so re-announce the boundary
%% with a static annotation — the same zero-runtime-dep pattern used in the
%% runtime modules `erli18n_server`/`erli18n_pt_store`, replacing the former
%% runtime `eqwalizer` cast-helper call (and the `eqwalizer_support` dep).
-eqwalizer({nowarn_function, guards_reject_bad_args/1}).

all() ->
    [
        singular_hit,
        singular_miss,
        singular_byte_identical,
        plural_compiled,
        plural_fallback,
        plural_header_absent,
        plural_miss,
        header_lookup,
        reload_replaces,
        unload_idempotent,
        build_put_equals_load,
        merge_entries_creates_and_extends,
        merge_entries_empty_is_noop,
        merge_entries_bad_index_crashes,
        get_map_returns_whole_map,
        introspection_counts_and_keys,
        all_lists_loaded_catalogs,
        erase_all_clears_namespace,
        guards_reject_bad_args
    ].

init_per_testcase(_Case, Config) ->
    _ = erli18n_pt_store:erase_all(),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = erli18n_pt_store:erase_all(),
    ok.

singular_hit(_Config) ->
    Entries = [{singular, undefined, <<"Hello">>, <<"Bonjour">>}],
    ok = erli18n_pt_store:load(?D, ?L, Entries, fallback_header()),
    ?assertEqual(
        {ok, <<"Bonjour">>},
        erli18n_pt_store:get_singular(?D, ?L, undefined, <<"Hello">>)
    ).

singular_miss(_Config) ->
    Entries = [{singular, undefined, <<"Hello">>, <<"Bonjour">>}],
    ok = erli18n_pt_store:load(?D, ?L, Entries, fallback_header()),
    ?assertEqual(undefined, erli18n_pt_store:get_singular(?D, ?L, undefined, <<"Nope">>)),
    %% wrong context is a normalized miss
    ?assertEqual(undefined, erli18n_pt_store:get_singular(?D, ?L, <<"menu">>, <<"Hello">>)),
    %% absent catalog is a miss, not a crash
    ?assertEqual(undefined, erli18n_pt_store:get_singular(absent_dom, ?L, undefined, <<"Hello">>)).

singular_byte_identical(_Config) ->
    V = <<"Caf\303\251 \342\200\224 \342\202\254 99"/utf8>>,
    Entries = [{singular, <<"ctx">>, <<"Price">>, V}],
    ok = erli18n_pt_store:load(?D, ?L, Entries, fallback_header()),
    {ok, Got} = erli18n_pt_store:get_singular(?D, ?L, <<"ctx">>, <<"Price">>),
    ?assertEqual(V, Got),
    ?assertEqual(byte_size(V), byte_size(Got)).

plural_compiled(_Config) ->
    H = compiled_header(),
    Compiled = maps:get(plural, H),
    Entries = [
        {plural, undefined, <<"file">>, <<"files">>, [{0, <<"fichier">>}, {1, <<"fichiers">>}]}
    ],
    ok = erli18n_pt_store:load(?D, ?L, Entries, H),
    %% hand-compute the index via the same total function the store uses
    ?assertEqual(0, erli18n_plural:evaluate(Compiled, 1)),
    ?assertEqual(1, erli18n_plural:evaluate(Compiled, 2)),
    ?assertEqual(
        {ok, <<"fichier">>}, erli18n_pt_store:get_plural_form(?D, ?L, undefined, <<"file">>, 1)
    ),
    ?assertEqual(
        {ok, <<"fichiers">>}, erli18n_pt_store:get_plural_form(?D, ?L, undefined, <<"file">>, 2)
    ).

plural_fallback(_Config) ->
    %% no compiled rule: C/Germanic fallback (N == 1 -> 0; else 1)
    Entries = [
        {plural, undefined, <<"item">>, <<"items">>, [{0, <<"Element">>}, {1, <<"Elemente">>}]}
    ],
    ok = erli18n_pt_store:load(?D, ?L, Entries, fallback_header()),
    ?assertEqual(
        {ok, <<"Element">>}, erli18n_pt_store:get_plural_form(?D, ?L, undefined, <<"item">>, 1)
    ),
    ?assertEqual(
        {ok, <<"Elemente">>}, erli18n_pt_store:get_plural_form(?D, ?L, undefined, <<"item">>, 5)
    ).

plural_header_absent(_Config) ->
    %% A catalog map with NO '$header' key (the shape the low-level insert path
    %% produces). The header carries the Plural-Forms rule, so with no header
    %% there is no form to select: get_plural_form/5 returns `undefined`
    %% DIRECTLY for every N, WITHOUT reading any row. It does NOT fall through to
    %% the C/Germanic fallback (doing so would surface an inserted plural form
    %% behind an unsupported public read). This mirrors
    %% erli18n_server:lookup_plural_form/5's `undefined -> undefined` arm.
    Map = #{
        {plural, undefined, <<"file">>, 0} => <<"fichier">>,
        {plural, undefined, <<"file">>, 1} => <<"fichiers">>
    },
    ok = erli18n_pt_store:put_map(?D, ?L, Map),
    [
        ?assertEqual(
            undefined, erli18n_pt_store:get_plural_form(?D, ?L, undefined, <<"file">>, N)
        )
     || N <- [0, 1, 2, 7, 100]
    ],
    %% The rows are present at the storage layer (the catalog IS populated): a
    %% header-bearing path would read them; only the form-aware read declines.
    #{} = Stored = erli18n_pt_store:get_map(?D, ?L),
    ?assertEqual(<<"fichier">>, maps:get({plural, undefined, <<"file">>, 0}, Stored)),
    ?assertEqual(<<"fichiers">>, maps:get({plural, undefined, <<"file">>, 1}, Stored)),
    %% A header-absent map also yields `undefined` for a header lookup.
    ?assertEqual(undefined, erli18n_pt_store:lookup_header(?D, ?L)).

plural_miss(_Config) ->
    Entries = [{plural, undefined, <<"only0">>, <<"only0s">>, [{0, <<"z">>}]}],
    ok = erli18n_pt_store:load(?D, ?L, Entries, fallback_header()),
    %% wrong msgid -> miss
    ?assertEqual(undefined, erli18n_pt_store:get_plural_form(?D, ?L, undefined, <<"ghost">>, 1)),
    %% N /= 1 selects index 1, which was not stored -> miss
    ?assertEqual(undefined, erli18n_pt_store:get_plural_form(?D, ?L, undefined, <<"only0">>, 5)).

header_lookup(_Config) ->
    H = fallback_header(),
    ok = erli18n_pt_store:load(?D, ?L, [], H),
    ?assertEqual({ok, H}, erli18n_pt_store:lookup_header(?D, ?L)),
    ?assertEqual(undefined, erli18n_pt_store:lookup_header(absent_dom, ?L)).

reload_replaces(_Config) ->
    ok = erli18n_pt_store:load(
        ?D, ?L, [{singular, undefined, <<"Hi">>, <<"Old">>}], fallback_header()
    ),
    ?assertEqual({ok, <<"Old">>}, erli18n_pt_store:get_singular(?D, ?L, undefined, <<"Hi">>)),
    ok = erli18n_pt_store:reload(
        ?D, ?L, [{singular, undefined, <<"Hi">>, <<"New">>}], fallback_header()
    ),
    ?assertEqual({ok, <<"New">>}, erli18n_pt_store:get_singular(?D, ?L, undefined, <<"Hi">>)),
    %% keys not in the new corpus are gone (whole-term replacement)
    ok = erli18n_pt_store:reload(?D, ?L, [], fallback_header()),
    ?assertEqual(undefined, erli18n_pt_store:get_singular(?D, ?L, undefined, <<"Hi">>)).

unload_idempotent(_Config) ->
    ok = erli18n_pt_store:load(
        ?D, ?L, [{singular, undefined, <<"Hi">>, <<"Bonjour">>}], fallback_header()
    ),
    ok = erli18n_pt_store:unload(?D, ?L),
    ?assertEqual(undefined, erli18n_pt_store:get_singular(?D, ?L, undefined, <<"Hi">>)),
    %% erase of an absent key is idempotent
    ?assertEqual(ok, erli18n_pt_store:unload(?D, ?L)).

build_put_equals_load(_Config) ->
    Entries = [
        {singular, undefined, <<"Hi">>, <<"Salut">>},
        {plural, undefined, <<"file">>, <<"files">>, [{0, <<"fichier">>}, {1, <<"fichiers">>}]}
    ],
    H = fallback_header(),
    ok = erli18n_pt_store:load(?D, ?L, Entries, H),
    Ref = persistent_term:get({erli18n_catalog, ?D, ?L}),
    Map = erli18n_pt_store:build_map(Entries, H),
    ?assert(is_map(Map)),
    ok = erli18n_pt_store:unload(?D, ?L),
    ok = erli18n_pt_store:put_map(?D, ?L, Map),
    ?assertEqual(Ref, persistent_term:get({erli18n_catalog, ?D, ?L})).

merge_entries_creates_and_extends(_Config) ->
    %% Merge into an ABSENT catalog: creates it (no header, since the insert
    %% path carries none).
    ok = erli18n_pt_store:merge_entries(?D, ?L, [
        {singular, undefined, <<"Hi">>, <<"Salut">>}
    ]),
    ?assertEqual({ok, <<"Salut">>}, erli18n_pt_store:get_singular(?D, ?L, undefined, <<"Hi">>)),
    ?assertEqual(undefined, erli18n_pt_store:lookup_header(?D, ?L)),
    %% Merge again: EXTENDS the existing map, keeps prior entries.
    ok = erli18n_pt_store:merge_entries(?D, ?L, [
        {plural, undefined, <<"file">>, <<"files">>, [{0, <<"fichier">>}, {1, <<"fichiers">>}]}
    ]),
    ?assertEqual({ok, <<"Salut">>}, erli18n_pt_store:get_singular(?D, ?L, undefined, <<"Hi">>)),
    %% The merged catalog carries no header (the insert path writes none), so
    %% the form-aware get_plural_form/5 misses. The plural row IS stored, though:
    %% read it directly at the storage layer to prove the merge extended the map.
    ?assertEqual(undefined, erli18n_pt_store:get_plural_form(?D, ?L, undefined, <<"file">>, 1)),
    #{} = Stored = erli18n_pt_store:get_map(?D, ?L),
    ?assertEqual(<<"fichier">>, maps:get({plural, undefined, <<"file">>, 0}, Stored)),
    ?assertEqual(<<"fichiers">>, maps:get({plural, undefined, <<"file">>, 1}, Stored)).

merge_entries_empty_is_noop(_Config) ->
    %% An empty merge against an ABSENT catalog creates nothing (no put).
    ok = erli18n_pt_store:merge_entries(?D, ?L, []),
    ?assertEqual(undefined, erli18n_pt_store:get_map(?D, ?L)),
    %% An empty merge against a PRESENT catalog leaves the term byte-identical
    %% (the `Map =:= Base` no-op arm: no put, so no second global GC).
    ok = erli18n_pt_store:load(
        ?D, ?L, [{singular, undefined, <<"Hi">>, <<"Salut">>}], fallback_header()
    ),
    Before = persistent_term:get({erli18n_catalog, ?D, ?L}),
    ok = erli18n_pt_store:merge_entries(?D, ?L, []),
    ?assertEqual(Before, persistent_term:get({erli18n_catalog, ?D, ?L})).

merge_entries_bad_index_crashes(_Config) ->
    %% The historical loud insert contract: a negative plural form index is a
    %% `function_clause` crash, not a silently stored bad key.
    ?assertError(
        function_clause,
        erli18n_pt_store:merge_entries(?D, ?L, [
            {plural, undefined, <<"file">>, <<"files">>, [{-1, <<"bad">>}]}
        ])
    ).

get_map_returns_whole_map(_Config) ->
    H = fallback_header(),
    ok = erli18n_pt_store:load(?D, ?L, [{singular, undefined, <<"Hi">>, <<"Salut">>}], H),
    %% Match the map pattern so the `catalog_map() | undefined` result is
    %% narrowed to `catalog_map()` (a freshly-loaded catalog is never absent);
    %% this is a real assertion (the read must return a map), not an eqwalizer
    %% dodge.
    #{} = Map = erli18n_pt_store:get_map(?D, ?L),
    ?assertEqual(<<"Salut">>, maps:get({singular, undefined, <<"Hi">>}, Map)),
    ?assertEqual(H, maps:get('$header', Map)),
    %% Absent catalog => undefined.
    ?assertEqual(undefined, erli18n_pt_store:get_map(absent_dom, ?L)).

introspection_counts_and_keys(_Config) ->
    %% A catalog with 1 singular + 1 plural (2 forms) + a header.
    Entries = [
        {singular, undefined, <<"Hi">>, <<"Salut">>},
        {plural, undefined, <<"file">>, <<"files">>, [{0, <<"fichier">>}, {1, <<"fichiers">>}]}
    ],
    ok = erli18n_pt_store:load(?D, ?L, Entries, fallback_header()),
    %% Narrow `catalog_map() | undefined` to `catalog_map()` by matching the map
    %% pattern (the freshly-loaded catalog is present); a real assertion the read
    %% returned a map, not an eqwalizer dodge.
    #{} = Map = erli18n_pt_store:get_map(?D, ?L),
    %% key_count counts every stored key INCLUDING the header: 3 data + 1.
    ?assertEqual(4, erli18n_pt_store:key_count(Map)),
    %% data_count drops the header.
    ?assertEqual(3, erli18n_pt_store:data_count(Map)),
    %% data_keys returns exactly the non-header keys (sorted for comparison).
    ?assertEqual(
        lists:sort([
            {singular, undefined, <<"Hi">>},
            {plural, undefined, <<"file">>, 0},
            {plural, undefined, <<"file">>, 1}
        ]),
        lists:sort(erli18n_pt_store:data_keys(Map))
    ),
    %% storage_bytes is a positive byte size for a non-empty map.
    ?assert(erli18n_pt_store:storage_bytes(Map) > 0),
    %% A header-only map has zero data keys but a non-zero key_count.
    HeaderOnly = erli18n_pt_store:build_map([], fallback_header()),
    ?assertEqual(1, erli18n_pt_store:key_count(HeaderOnly)),
    ?assertEqual(0, erli18n_pt_store:data_count(HeaderOnly)),
    ?assertEqual([], erli18n_pt_store:data_keys(HeaderOnly)),
    %% A truly empty map: data_count uses the header-absent arm (map_size, no -1).
    ?assertEqual(0, erli18n_pt_store:data_count(#{})).

all_lists_loaded_catalogs(_Config) ->
    %% erase_all in setup guarantees a clean namespace, so `all/0` reflects
    %% exactly what this case loads.
    ?assertEqual([], erli18n_pt_store:all()),
    ok = erli18n_pt_store:load(
        ?D, ?L, [{singular, undefined, <<"Hi">>, <<"Salut">>}], fallback_header()
    ),
    ok = erli18n_pt_store:load(
        ?D, <<"es">>, [{singular, undefined, <<"Hi">>, <<"Hola">>}], fallback_header()
    ),
    Loaded = lists:sort([{Dom, Loc} || {Dom, Loc, _Map} <- erli18n_pt_store:all()]),
    ?assertEqual([{?D, <<"es">>}, {?D, ?L}], Loaded),
    %% Each tuple's third element is the catalog map.
    [{_, _, M} | _] = erli18n_pt_store:all(),
    ?assert(is_map(M)),
    %% clean up the extra locale (init/end only knows ?D/?L; erase_all covers it
    %% but be explicit about the namespace having two members here).
    ok = erli18n_pt_store:unload(?D, <<"es">>).

erase_all_clears_namespace(_Config) ->
    ok = erli18n_pt_store:load(
        ?D, ?L, [{singular, undefined, <<"Hi">>, <<"Salut">>}], fallback_header()
    ),
    ok = erli18n_pt_store:load(
        ?D, <<"es">>, [{singular, undefined, <<"Hi">>, <<"Hola">>}], fallback_header()
    ),
    %% erase_all removes every {erli18n_catalog,_,_} term and reports the count.
    ?assertEqual(2, erli18n_pt_store:erase_all()),
    ?assertEqual([], erli18n_pt_store:all()),
    ?assertEqual(undefined, erli18n_pt_store:get_map(?D, ?L)),
    ?assertEqual(undefined, erli18n_pt_store:get_map(?D, <<"es">>)),
    %% Idempotent: a second sweep removes nothing.
    ?assertEqual(0, erli18n_pt_store:erase_all()).

guards_reject_bad_args(_Config) ->
    %% The read/write primitives keep loud guards: a contract violation is a
    %% `function_clause` crash, never a silent wrong answer.
    BadDomain = <<"not_an_atom">>,
    BadLocale = fr,
    ?assertError(
        function_clause, erli18n_pt_store:get_singular(BadDomain, ?L, undefined, <<"x">>)
    ),
    ?assertError(
        function_clause, erli18n_pt_store:get_singular(?D, BadLocale, undefined, <<"x">>)
    ),
    ?assertError(
        function_clause, erli18n_pt_store:get_plural_form(?D, BadLocale, undefined, <<"x">>, 1)
    ),
    ?assertError(function_clause, erli18n_pt_store:lookup_header(BadDomain, ?L)),
    ?assertError(function_clause, erli18n_pt_store:get_map(BadDomain, ?L)),
    ?assertError(function_clause, erli18n_pt_store:unload(BadDomain, ?L)),
    ?assertError(function_clause, erli18n_pt_store:merge_entries(BadDomain, ?L, [])).

%% --- helpers ---

fallback_header() ->
    #{plural => fallback, source => test}.

compiled_header() ->
    {ok, Compiled} = erli18n_plural:compile(<<"nplurals=2; plural=(n > 1);">>),
    #{plural => Compiled, source => test}.
