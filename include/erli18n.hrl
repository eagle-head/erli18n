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

-endif.
