-ifndef(ERLI18N_HRL).
-define(ERLI18N_HRL, true).

-define(GETTEXT_DOMAIN, default).

-define(ETS_TABLE, erli18n_catalog).

%% Finding #7 (memory-info-tab2list-per-load-quadratic) + Finding #13
%% (server-unload-select-delete-full-scan): authoritative O(1) side index
%% of loaded catalogs, keyed per (Domain, Locale), carrying that catalog's
%% set of data keys.
%%
%% The data table (`?ETS_TABLE') used to be scanned in full
%% (`ets:tab2list/1') on every load to count distinct (Domain, Locale)
%% catalogs for `memory_info/0' — O(total_rows) per load, so N loads were
%% O(N^2). Instead the server now maintains this `set' table with exactly
%% one row per catalog that has >=1 entry, updated incrementally on insert
%% and unload. `num_catalogs' is then `ets:info(?CATALOG_INDEX_TABLE,
%% size)' — O(1).
%%
%% Finding #13: each index row is `{{Domain, Locale}, KeySet}', where
%% `KeySet' is a `sets:set/1' of the catalog's full data keys (the
%% `?SINGULAR_KEY'/`?PLURAL_KEY' tuples; the header key is NOT a data key
%% and is tracked separately). This lets `unload/2' (and the reload path)
%% delete a single catalog by iterating ITS keys and calling `ets:delete/2'
%% per key — O(catalog size) — instead of `ets:select_delete/2' with a
%% partial-key match spec, which on a `set' table cannot probe by a (D, L)
%% key prefix and so scans EVERY row of ALL catalogs (O(total rows)).
%%
%% Owned by `erli18n_server' (not the table owner): unlike the data table,
%% the index is cheap, derivable server-private state. When the worker
%% crashes the index dies with it, and the worker rebuilds it on `init/1'
%% from the surviving data table (a one-time O(rows) pass, never on the
%% per-load hot path). Membership rule, drift-free by construction:
%% "index row present <=> the catalog has >=1 data entry; its KeySet is
%% exactly that catalog's set of data keys".
-define(CATALOG_INDEX_TABLE, erli18n_catalog_index).

-define(SINGULAR_KEY(Domain, Locale, Context, Msgid),
        {singular, Domain, Locale, Context, Msgid}).
-define(PLURAL_KEY(Domain, Locale, Context, Msgid, Index),
        {plural, Domain, Locale, Context, Msgid, Index}).
-define(HEADER_KEY(Domain, Locale),
        {header, Domain, Locale}).

%% ETS heir handoff constants (finding #10:
%% ets-owned-by-server-no-heir-crash-loses-all-catalogs).
%%
%% The catalog table is created and held by a dedicated long-lived owner
%% process (`?TABLE_OWNER`) which keeps itself as the table `heir`. The
%% mutating worker (`erli18n_server`) receives the table via
%% `ets:give_away/3` and operates it. When the worker crashes, ETS sends
%% the table back to the owner via `{'ETS-TRANSFER', ...}` with all rows
%% intact, so catalog state outlives the process that mutates (and may
%% crash) it.
%%
%% `?ETS_HEIR_DATA` tags the transfer that fires when the table-holding
%% worker dies (heir reclaim). `?ETS_HANDOFF_DATA` tags the deliberate
%% owner->worker `give_away/3` handoff. Distinct markers let each receiver
%% match the exact transfer it expects.
-define(ETS_HEIR_DATA, erli18n_catalog_heir).
-define(ETS_HANDOFF_DATA, erli18n_catalog_handoff).

%% Registered name of the dedicated table-owner process.
-define(TABLE_OWNER, erli18n_table_owner).

-endif.
