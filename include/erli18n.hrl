-ifndef(ERLI18N_HRL).
-define(ERLI18N_HRL, true).

-define(GETTEXT_DOMAIN, default).

-define(ETS_TABLE, erli18n_catalog).

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
