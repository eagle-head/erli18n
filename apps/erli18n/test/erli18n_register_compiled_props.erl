%%% =====================================================================
%%% Property-based tests for `erli18n_server:register_compiled_many/1`.
%%%
%%% Claims:
%%%   * P-roundtrip: registering a compiled spec installs a catalog whose
%%%     DATA entries are byte-identical to a reference
%%%     `erli18n_pt_store:build_map/2` over the same entries (the only
%%%     header field that can differ is the stamped `loaded_at`, so the
%%%     comparison drops the `'$header'` marker).
%%%   * P-idempotent: registering the SAME spec twice equals registering it
%%%     once — the second call is `{ok, already}` and leaves the installed
%%%     term untouched.
%%%   * P-order: registering a batch of distinct `{Domain, Locale}` specs is
%%%     order-independent — the installed catalogs are identical whatever the
%%%     order of the input list.
%%%
%%% References:
%%%   * Hughes, "QuickCheck", ICFP 2000.
%%%   * PropEr docs — https://hexdocs.pm/proper/
%%% =====================================================================
-module(erli18n_register_compiled_props).

-include_lib("proper/include/proper.hrl").

-export([
    prop_register_roundtrip_equals_reference/0,
    prop_register_twice_equals_once/0,
    prop_register_batch_order_independent/0
]).

%% PropEr `?FORALL`/`?LET` generators are statically typed as `term()` by
%% eqwalizer, so every function that binds a generated value to a documented
%% shape carries a static `-eqwalizer({nowarn_function, F/A}).` — the same
%% zero-runtime-dep pattern used in the runtime modules
%% `erli18n_server`/`erli18n_pt_store`.
-eqwalizer({nowarn_function, prop_register_roundtrip_equals_reference/0}).
-eqwalizer({nowarn_function, prop_register_twice_equals_once/0}).
-eqwalizer({nowarn_function, prop_register_batch_order_independent/0}).
-eqwalizer({nowarn_function, non_empty_binary/0}).

-define(DOMAIN, prop_register_dom).
-define(LOCALE, <<"px">>).

%% =========================
%% Properties
%% =========================

%% P-roundtrip: the installed catalog's data entries equal a reference
%% `build_map/2` over the same entries (header dropped: `loaded_at` is
%% stamped, so the `'$header'` value legitimately differs).
prop_register_roundtrip_equals_reference() ->
    ?FORALL(
        EntriesGen,
        entries_gen(),
        begin
            Entries = EntriesGen,
            Baked = baked(length(Entries)),
            Spec = {?DOMAIN, ?LOCALE, Entries, Baked},
            [{?DOMAIN, ?LOCALE, _}] =
                erli18n_server:register_compiled_many([Spec]),
            Installed = installed_map(?DOMAIN, ?LOCALE),
            Reference = erli18n_pt_store:build_map(Entries, full_header(Baked)),
            teardown(?DOMAIN, ?LOCALE),
            data_only(Installed) =:= data_only(Reference)
        end
    ).

%% P-idempotent: register-twice == register-once. The second call returns
%% `{ok, already}` and the installed term is unchanged.
prop_register_twice_equals_once() ->
    ?FORALL(
        EntriesGen,
        entries_gen(),
        begin
            Entries = EntriesGen,
            Spec = {?DOMAIN, ?LOCALE, Entries, baked(length(Entries))},
            [{?DOMAIN, ?LOCALE, _}] =
                erli18n_server:register_compiled_many([Spec]),
            Once = installed_map(?DOMAIN, ?LOCALE),
            R2 = erli18n_server:register_compiled_many([Spec]),
            Twice = installed_map(?DOMAIN, ?LOCALE),
            teardown(?DOMAIN, ?LOCALE),
            (R2 =:= [{?DOMAIN, ?LOCALE, {ok, already}}]) andalso
                (Once =:= Twice)
        end
    ).

%% P-order: a batch of distinct {Domain, Locale} specs installs the same
%% catalogs no matter the order of the input list.
prop_register_batch_order_independent() ->
    ?FORALL(
        SpecsGen,
        distinct_locale_specs(),
        begin
            Specs = SpecsGen,
            %% Forward order.
            _ = erli18n_server:register_compiled_many(Specs),
            Forward = [{L, data_only(installed_map(D, L))} || {D, L, _, _} <- Specs],
            [teardown(D, L) || {D, L, _, _} <- Specs],
            %% Reversed order.
            _ = erli18n_server:register_compiled_many(lists:reverse(Specs)),
            Reversed = [{L, data_only(installed_map(D, L))} || {D, L, _, _} <- Specs],
            [teardown(D, L) || {D, L, _, _} <- Specs],
            lists:sort(Forward) =:= lists:sort(Reversed)
        end
    ).

%% =========================
%% Generators
%% =========================

%% A list of singular entries (possibly with duplicate msgids — the catalog
%% map collapses them exactly as `build_map/2` does, so the round-trip holds).
entries_gen() ->
    ?LET(
        Pairs,
        list({non_empty_binary(), non_empty_binary()}),
        singular_entries(Pairs)
    ).

singular_entries(Pairs) ->
    [{singular, undefined, Msgid, Translation} || {Msgid, Translation} <- Pairs].

non_empty_binary() ->
    ?LET(L, non_empty(list(range($a, $z))), list_to_binary(L)).

%% A batch of 1..5 specs over DISTINCT locales (l1..lN), each with its own
%% small entry list, so the order-independence claim is about cross-catalog
%% commit order, not within-catalog overwrite.
distinct_locale_specs() ->
    ?LET(N, range(1, 5), build_locale_specs(N)).

build_locale_specs(N) ->
    [
        begin
            Locale = list_to_binary("l" ++ integer_to_list(I)),
            Entries = [
                {singular, undefined, list_to_binary("k" ++ integer_to_list(I)),
                    list_to_binary("v" ++ integer_to_list(I))}
            ],
            {?DOMAIN, Locale, Entries, baked(1)}
        end
     || I <- lists:seq(1, N)
    ].

%% =========================
%% Helpers
%% =========================

baked(NumEntries) ->
    #{
        plural => fallback,
        plural_raw => erli18n_plural:fallback_rule(),
        po_path => "prop.po",
        divergence => none,
        fuzzy_included => false,
        num_entries => NumEntries
    }.

%% The full header_state() a reference build_map/2 needs: the baked fields
%% plus a stamped loaded_at. The data-only comparison drops '$header', so the
%% exact loaded_at value is irrelevant here.
full_header(Baked) ->
    Baked#{loaded_at => 0}.

installed_map(Domain, Locale) ->
    persistent_term:get({erli18n_catalog, Domain, Locale}).

data_only(Map) ->
    maps:remove('$header', Map).

teardown(Domain, Locale) ->
    ok = erli18n_server:unload(Domain, Locale).
