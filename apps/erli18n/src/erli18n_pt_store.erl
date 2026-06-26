-module(erli18n_pt_store).

-moduledoc """
`persistent_term` storage layer for erli18n translation catalogs.

Each loaded `{Domain, Locale}` catalog is stored as ONE persistent term:
key `{erli18n_catalog, Domain, Locale}`, value a single map holding

- `{singular, Context, Msgid} => Translation`
- `{plural, Context, Msgid, Index} => Translation`
- `'$header' => header_state()`

Reads are copy-free (`persistent_term:get/2` does not copy the term onto the
caller's heap) and lock-free from the caller process. The read semantics mirror
the previous ETS reads byte-for-byte: a missing catalog or a missing key both
yield `undefined`, and the plural read evaluates the compiled rule (or the
C/Germanic fallback) exactly as before.

## Read-path rule (load-bearing)

Call `persistent_term:get/2` FRESH on every lookup and let the returned map be
transient. NEVER cache the catalog map in a long-lived process's state or
process dictionary: a process holding the old term is forced into a major
(fullsweep) garbage collection when the catalog is reloaded, and would serve a
stale catalog. (erlang.org/doc/apps/erts/persistent_term.html, Best Practices.)

## Reload cost

`put_map/3` (install/reload) and `unload/2` (`persistent_term:erase/1`) of the
catalog map defer a node-wide literal-area cleanup: every process still
referencing the old map runs a major GC, and all processes are made runnable to
scan their heaps. It is paid once per (re)load — acceptable for erli18n's
load-once-at-boot workload, but it is a real cost that ETS did not have.

The loaded-catalog index term (`?INDEX_KEY`) is written on the same node-wide
basis only when its `ordsets` set actually changes: the first load of a
`{Domain, Locale}` pair and the unload of the last reference to it each pay one
index `persistent_term:put` (and its literal-area cleanup), but a reload of an
already-indexed catalog skips the index write entirely (compare-before-put), so
a steady-state reload pays the cost of the catalog-map term only.

### Why the default-available index is NOT cached here

The per-request locale-negotiation default-available path rebuilds a canonical
`available_index` from `loaded_locales/0` on each request. Caching that prebuilt
index as a SECOND `persistent_term` keyed off `?INDEX_KEY` was considered and
DELIBERATELY REJECTED. The per-request work it removes is marginal (one
copy-free `index_get/0` plus a `usort`/`canonicalize` over the tiny index) and
is ALREADY fully avoidable by an application passing an explicit `available`
option (the per-request thunk then returns it directly, with no rebuild). A
cached term, by contrast, would add a recurring cost: a second
`persistent_term:put` that must fire in lock-step with `?INDEX_KEY` on EVERY
index change (first load of a pair, last unload, and the header-only-reload
`index_del` path), each scheduling the node-wide literal-area GC that the
compare-before-put discipline exists to minimize. It would also widen the
lock-step invariant surface (across `put_map/3`, `unload/2`, `index_update/2`,
`erase_all/0`) and need `?INDEX_KEY`-style namespace exclusion. A marginal,
easily-avoided per-request saving traded for recurring reload-time node-wide GC
plus added invariant/bug surface is premature optimization, so the index is
recomputed per request rather than cached.
""".

-export([
    build_map/2,
    put_map/3,
    load/4,
    reload/4,
    merge_entries/3,
    get_singular/4,
    get_plural_form/5,
    lookup_header/2,
    get_map/2,
    unload/2
]).

%% Storage-namespace introspection / lifecycle (observability + app stop).
-export([
    all/0,
    loaded_locales/0,
    data_keys/1,
    key_count/1,
    data_count/1,
    storage_bytes/1,
    erase_all/0
]).

%% `persistent_term:get/0' is specced with `term()' keys, so eqwalizer cannot
%% see that our namespace filter `{erli18n_catalog, D, L}' guarantees an
%% `{atom(), binary()}' shape. The comprehension narrows the key by pattern, so
%% the `{domain(), locale(), catalog_map()}' result is sound by construction;
%% re-announce it with a static boundary annotation (no runtime cast — the
%% `eqwalizer:dynamic_cast/1' helper ships only in the test-only
%% `eqwalizer_support' dep, which Hex cannot package).
-eqwalizer({nowarn_function, all/0}).

-define(KEY(Domain, Locale), {erli18n_catalog, Domain, Locale}).
%% The loaded-catalog index lives under its OWN fixed (zero-argument) key, a
%% 1-tuple so it can never be confused with a 3-tuple catalog key
%% `{erli18n_catalog, Domain, Locale}` by any namespace comprehension (the
%% `all/0`/`erase_all/0` filters match the 3-tuple, so the index term is
%% excluded from them by construction).
-define(INDEX_KEY, {erli18n_catalog_index}).
-define(HEADER, '$header').

-type domain() :: atom().
-type locale() :: binary().
-type context() :: undefined | binary().
-type msgid() :: binary().
-type translation() :: binary().
%% The authoritative header-state shape lives in `erli18n_server' (the only
%% producer of header states — built in full by its load/reload staging and
%% handed to `build_map/2'). Alias it here so a stored/looked-up header is
%% byte-identical to what `erli18n_server:lookup_header/2' promises: the
%% compiled plural rule (or the `fallback' atom when the .po has no
%% Plural-Forms header) plus its metadata keys.
-type header_state() :: erli18n_server:header_state().
%% A data (non-header) key inside a catalog map. `Domain`/`Locale` are
%% factored up into the persistent_term key, so the in-map keys carry only
%% the context/msgid (and, for plurals, the form index).
-type data_key() ::
    {singular, context(), msgid()}
    | {plural, context(), msgid(), non_neg_integer()}.
%% Every key a catalog map may hold: its data keys plus the header marker.
-type stored_key() :: data_key() | '$header'.
-type catalog_map() :: #{stored_key() => translation() | header_state()}.

-export_type([catalog_map/0, data_key/0]).

-doc """
Build the per-catalog value map from parsed `.po` entries and a header state,
WITHOUT touching `persistent_term` (pure). Used to construct the map off the
measured/serialized write path before a single `put_map/3`.
""".
-spec build_map([erli18n_po:entry()], header_state()) -> catalog_map().
build_map(Entries, HeaderState) when is_list(Entries), is_map(HeaderState) ->
    lists:foldl(fun put_entry/2, #{?HEADER => HeaderState}, Entries).

-doc "Install a pre-built catalog map as the single persistent term for `{Domain, Locale}`.".
-spec put_map(domain(), locale(), catalog_map()) -> ok.
put_map(Domain, Locale, Map) when is_atom(Domain), is_binary(Locale), is_map(Map) ->
    persistent_term:put(?KEY(Domain, Locale), Map),
    %% Keep the loaded-catalog index in lock-step with the catalog term, mirroring
    %% the `loaded_catalogs/0` semantics: a catalog counts as "loaded" only once it
    %% holds >=1 data (non-header) entry. `put_map/3` is the single add chokepoint
    %% (load/4, reload/4, merge_entries/3-that-creates, and the server's staged
    %% install all route through here), so updating the index here — add when the
    %% installed map carries data, drop it otherwise — keeps the index equal to the
    %% `data_count > 0` set.
    %%
    %% The `data_count =:= 0` -> `index_del` branch is reached by a header-only
    %% LOAD/RELOAD, NOT by a merge: `build_map/2` seeds `#{?HEADER => HeaderState}`,
    %% so a load/reload with an empty `Entries` list installs a header-only map
    %% (`data_count = 0`) and must drop any prior index entry for the pair. A merge
    %% can NEVER reach this branch: `merge_entries/3` folds add-only `put_entry/2`
    %% over an existing base, so the resulting map can only GROW-or-equal the base;
    %% an equal merge short-circuits to `ok` WITHOUT calling `put_map/3`, and a
    %% growing merge keeps every prior data key, so `data_count` stays > 0.
    case data_count(Map) > 0 of
        true -> index_add(Domain, Locale);
        false -> index_del(Domain, Locale)
    end,
    ok.

-doc "Build the catalog map and install it in one step (the install/load commit).".
-spec load(domain(), locale(), [erli18n_po:entry()], header_state()) -> ok.
load(Domain, Locale, Entries, HeaderState) ->
    put_map(Domain, Locale, build_map(Entries, HeaderState)).

-doc """
Reload a catalog: whole-term replacement. Identical to `load/4` because
`persistent_term:put/2` overwrites the term at the key, so there are no stale
entries to prune (a concurrent reader sees either the entire old or the entire
new catalog, never a half-applied one).
""".
-spec reload(domain(), locale(), [erli18n_po:entry()], header_state()) -> ok.
reload(Domain, Locale, Entries, HeaderState) ->
    load(Domain, Locale, Entries, HeaderState).

-doc "Singular lookup. Mirrors `erli18n_server:lookup_singular/4` (miss => `undefined`).".
-spec get_singular(domain(), locale(), context(), msgid()) -> {ok, translation()} | undefined.
get_singular(Domain, Locale, Context, Msgid) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid)
->
    case lookup_map(Domain, Locale) of
        undefined ->
            undefined;
        Map ->
            case maps:get({singular, Context, Msgid}, Map, undefined) of
                undefined -> undefined;
                Translation -> {ok, Translation}
            end
    end.

-doc """
Plural-aware lookup. Mirrors `erli18n_server:lookup_plural_form/5`: read the
header, select the form index via the compiled rule (or the C/Germanic
fallback), then read the per-index plural key. Miss => `undefined`.
""".
-spec get_plural_form(domain(), locale(), context(), msgid(), integer()) ->
    {ok, translation()} | undefined.
get_plural_form(Domain, Locale, Context, Msgid, N) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_integer(N)
->
    case lookup_map(Domain, Locale) of
        undefined ->
            undefined;
        Map ->
            %% Header absent (catalog not loaded, or populated only by the
            %% low-level insert_* API, which writes data rows but no header)
            %% -> `undefined` directly, WITHOUT reading any entry. This mirrors
            %% `erli18n_server:lookup_plural_form/5`'s historical contract: the
            %% header is what carries the Plural-Forms rule, so with no header
            %% there is no form to select and the lookup is a miss.
            case maps:get(?HEADER, Map, undefined) of
                #{plural := fallback} ->
                    plural_entry(Map, Context, Msgid, fallback_form_index(N));
                #{plural := Compiled} ->
                    plural_entry(Map, Context, Msgid, erli18n_plural:evaluate(Compiled, N));
                undefined ->
                    undefined
            end
    end.

%% Read the per-index plural entry from an already-resolved catalog map.
%% Reached only after a present header has selected the form index; a missing
%% index key is a `undefined` miss.
plural_entry(Map, Context, Msgid, Index) ->
    case maps:get({plural, Context, Msgid, Index}, Map, undefined) of
        undefined -> undefined;
        Translation -> {ok, Translation}
    end.

-doc "Header lookup. Mirrors `erli18n_server:lookup_header/2` (miss => `undefined`).".
-spec lookup_header(domain(), locale()) -> {ok, header_state()} | undefined.
lookup_header(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    case lookup_map(Domain, Locale) of
        undefined ->
            undefined;
        Map ->
            case maps:get(?HEADER, Map, undefined) of
                undefined -> undefined;
                HeaderState -> {ok, HeaderState}
            end
    end.

-doc "Unload a catalog: erase the persistent term. Idempotent (`ok` whether present or not).".
-spec unload(domain(), locale()) -> ok.
unload(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    _ = persistent_term:erase(?KEY(Domain, Locale)),
    %% Drop the pair from the loaded-catalog index in the same body, keeping it
    %% consistent with the erased term. Idempotent: erasing a never-loaded catalog
    %% deletes an absent pair (a total no-op).
    index_del(Domain, Locale),
    ok.

-doc """
Merge entries into the existing catalog map, creating it if absent and
preserving the header if present. Used by the low-level insert API
(`erli18n_server:insert_singular/5` etc.): an empty merge is a no-op (no
catalog is created, no `put`). A negative or non-integer plural form index is a
loud `function_clause` crash, matching the historical insert contract.
""".
-spec merge_entries(domain(), locale(), [erli18n_po:entry()]) -> ok.
merge_entries(Domain, Locale, Entries) when
    is_atom(Domain), is_binary(Locale), is_list(Entries)
->
    Base =
        case lookup_map(Domain, Locale) of
            undefined -> #{};
            Existing -> Existing
        end,
    Map = lists:foldl(fun put_entry/2, Base, Entries),
    case Map =:= Base of
        true -> ok;
        false -> put_map(Domain, Locale, Map)
    end.

-doc "Return the whole catalog map for `{Domain, Locale}`, or `undefined` if not loaded.".
-spec get_map(domain(), locale()) -> catalog_map() | undefined.
get_map(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    lookup_map(Domain, Locale).

-doc """
List every loaded catalog as `{Domain, Locale, Map}`. Filters the node's
persistent terms by the `erli18n_catalog` namespace, so it is O(total
persistent terms on the node) — an observability call, never the hot path.
""".
-spec all() -> [{domain(), locale(), catalog_map()}].
all() ->
    [{D, L, V} || {{erli18n_catalog, D, L}, V} <- persistent_term:get()].

-doc """
The loaded-locale set: the sorted, distinct locales across all loaded catalogs.
ONE keyed `persistent_term` read (copy-free) plus a project/`usort` over the
tiny index — O(1) on the node table, NOT the node-wide scan that `all/0` does.
This is the hot-path accessor behind `erli18n:loaded_locales/0`.
""".
-spec loaded_locales() -> [locale()].
loaded_locales() ->
    lists:usort([Locale || {_Domain, Locale} <- index_get()]).

-doc "The data (non-header) keys of a catalog map.".
-spec data_keys(catalog_map()) -> [data_key()].
data_keys(Map) when is_map(Map) ->
    lists:foldl(fun keep_data_key/2, [], maps:keys(Map)).

-doc "Total number of stored keys in a catalog map (data keys plus the header).".
-spec key_count(catalog_map()) -> non_neg_integer().
key_count(Map) when is_map(Map) ->
    map_size(Map).

-doc "Number of data (non-header) keys in a catalog map.".
-spec data_count(catalog_map()) -> non_neg_integer().
data_count(Map) when is_map(Map) ->
    case maps:is_key(?HEADER, Map) of
        true -> map_size(Map) - 1;
        false -> map_size(Map)
    end.

-doc "Approximate storage size of a catalog map in bytes (term word size * word).".
-spec storage_bytes(catalog_map()) -> non_neg_integer().
storage_bytes(Map) when is_map(Map) ->
    erts_debug:size(Map) * erlang:system_info(wordsize).

-doc """
Erase every `{erli18n_catalog, _, _}` persistent term on the node and return
how many were removed. Called on application stop, since persistent terms are
node-global and are NOT cleared when the application stops.
""".
-spec erase_all() -> non_neg_integer().
erase_all() ->
    Keys = [K || {{erli18n_catalog, _D, _L} = K, _V} <- persistent_term:get()],
    lists:foreach(fun(K) -> _ = persistent_term:erase(K) end, Keys),
    %% Erase the loaded-catalog index too, OUTSIDE the catalog `Keys` count: it is
    %% not a catalog, so the returned total (how many catalogs were removed) stays
    %% catalog-only. This clears the index on application stop and the test resets.
    _ = persistent_term:erase(?INDEX_KEY),
    length(Keys).

%% --- internal ---

lookup_map(Domain, Locale) ->
    persistent_term:get(?KEY(Domain, Locale), undefined).

%% The loaded-catalog index: an `ordsets` of `{Domain, Locale}` pairs stored
%% under the single `?INDEX_KEY` term. It mirrors the set of catalogs with
%% `data_count > 0` (the `loaded_catalogs/0` key set), so removing one catalog
%% never drops a locale still held by another domain. `ordsets:add_element/2`
%% is idempotent (reload adds no duplicate) and `ordsets:del_element/2` is total
%% (idempotent unload of an absent pair is a no-op).
%% `index_get/0` is a copy-free keyed read; `index_add/2`/`index_del/2` write
%% the index back ONLY when the ordset actually changes (see `index_update/2`),
%% so a reload of an already-indexed catalog or an unload of an absent pair
%% skips the `persistent_term:put` and its node-wide literal-area GC.
-spec index_get() -> ordsets:ordset({domain(), locale()}).
index_get() ->
    persistent_term:get(?INDEX_KEY, []).

-spec index_add(domain(), locale()) -> ok.
index_add(Domain, Locale) ->
    index_update(fun ordsets:add_element/2, {Domain, Locale}).

-spec index_del(domain(), locale()) -> ok.
index_del(Domain, Locale) ->
    index_update(fun ordsets:del_element/2, {Domain, Locale}).

%% Compare-before-put on the loaded-catalog index. `persistent_term:put/2`
%% schedules a node-wide literal-area GC (every process is made runnable to
%% scan its heap), so it must run ONLY when the index actually changes. A
%% reload of an already-indexed catalog (`add` of a present pair) and an unload
%% of an absent pair (`del` of a missing pair) both leave the ordset identical
%% to what is already stored: in that case skip the `put` and its GC entirely.
%% The lock-step invariant is preserved exactly — when the op is a no-op the
%% stored term already equals `Op(Pair, Current)`, so omitting the write keeps
%% the term equal to the `data_count > 0` catalog set by construction.
-spec index_update(
    fun((Pair, ordsets:ordset(Pair)) -> ordsets:ordset(Pair)),
    Pair
) -> ok when Pair :: {domain(), locale()}.
index_update(Op, Pair) ->
    Current = index_get(),
    case Op(Pair, Current) of
        Current ->
            ok;
        Updated ->
            persistent_term:put(?INDEX_KEY, Updated),
            ok
    end.

-spec put_entry(erli18n_po:entry(), catalog_map()) -> catalog_map().
put_entry({singular, Ctx, Msgid, Translation}, Map) ->
    Map#{{singular, Ctx, Msgid} => Translation};
put_entry({plural, Ctx, Msgid, _MsgidPlural, Forms}, Map) ->
    %% The form-index guard keeps the historical loud contract: a negative or
    %% non-integer index is a `function_clause` crash, not a silently stored
    %% bad key. The parser only ever emits valid (>= 0) indices, so the load
    %% path never trips it; only a hand-crafted insert can.
    lists:foldl(
        fun({Idx, Translation}, Acc) when is_integer(Idx), Idx >= 0 ->
            Acc#{{plural, Ctx, Msgid, Idx} => Translation}
        end,
        Map,
        Forms
    ).

%% Accumulate the data (non-header) keys of a catalog map. Clause-based so the
%% key shape is narrowed exactly: the header marker is dropped, singular and
%% plural keys are kept verbatim. Folds over the catalog's KEYS (not its
%% key/value pairs): the value plays no part in collecting the data keys.
-spec keep_data_key(stored_key(), [data_key()]) -> [data_key()].
keep_data_key(?HEADER, Acc) ->
    Acc;
keep_data_key({singular, _Ctx, _Msgid} = Key, Acc) ->
    [Key | Acc];
keep_data_key({plural, _Ctx, _Msgid, _Idx} = Key, Acc) ->
    [Key | Acc].

%% C/Germanic fallback when the .po has no Plural-Forms header: N == 1 -> 0 else 1.
fallback_form_index(1) -> 0;
fallback_form_index(_N) -> 1.
