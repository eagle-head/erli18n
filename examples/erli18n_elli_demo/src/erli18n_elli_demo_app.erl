-module(erli18n_elli_demo_app).

-moduledoc """
Loads the demo catalogs, then starts the supervisor that owns the Elli listener.

The listener is configured with `elli_middleware` and `erli18n_elli` as a
preprocess-only middleware ahead of the real handler (see
`erli18n_elli_demo_sup`). `erli18n_elli` negotiates the request locale (default
precedence query → cookie → `Accept-Language`) and calls `erli18n:setlocale/1` on
the request process before the handler runs, so `erli18n_elli_demo_handler`
translates with no locale argument. The `pt_BR` and `es` catalogs are loaded; `en`
is the (deliberately unloaded) default, so an unmatched request falls back to the
raw English msgids.
""".

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = load_catalogs(),
    %% `en` is intentionally NOT loaded: it is the default locale, so an
    %% unmatched negotiation resolves to the raw (English) msgid.
    erli18n:set_default_locale(<<"en">>),
    erli18n_elli_demo_sup:start_link().

stop(_State) ->
    ok.

%% Load the bundled `pt_BR` + `es` catalogs into the `default` gettext domain.
%% A failed load crashes the boot on purpose — a broken example should fail
%% loudly rather than silently serve raw msgids.
load_catalogs() ->
    Dir = filename:join(code:priv_dir(erli18n_elli_demo), "gettext"),
    Po = fun(Locale) ->
        filename:join([Dir, Locale, "LC_MESSAGES", "default.po"])
    end,
    {ok, _} = erli18n_server:ensure_loaded(default, <<"pt_BR">>, Po("pt_BR")),
    {ok, _} = erli18n_server:ensure_loaded(default, <<"es">>, Po("es")),
    ok.
