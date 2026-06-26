-module(erli18n_cowboy_demo_app).

-moduledoc """
Boots a Cowboy listener with the `erli18n_cowboy` middleware in front of a single
handler, after loading the demo catalogs.

The middleware negotiates the request locale (default precedence
query → cookie → `Accept-Language`) and calls `erli18n:setlocale/1` on the
request process **before** the handler runs, so `erli18n_cowboy_demo_handler`
translates with no locale argument. The `pt_BR` and `es` catalogs are loaded; `en`
is the (deliberately unloaded) default, so a request that matches nothing falls
back to the raw English msgids.
""".

-behaviour(application).

-export([start/2, stop/1]).

-define(LISTENER, erli18n_cowboy_demo_http).
-define(PORT, 8080).

start(_StartType, _StartArgs) ->
    ok = load_catalogs(),
    %% `en` is intentionally NOT loaded: it is the default locale, so an
    %% unmatched negotiation resolves to the raw (English) msgid.
    erli18n:set_default_locale(<<"en">>),
    Dispatch = cowboy_router:compile([
        {'_', [{"/", erli18n_cowboy_demo_handler, []}]}
    ]),
    {ok, _} = cowboy:start_clear(
        ?LISTENER,
        [{port, ?PORT}],
        #{
            env => #{
                dispatch => Dispatch,
                %% Middleware options live under the `erli18n` key. Every key is
                %% optional; this is just the explicit form of the default order.
                erli18n => #{sources => [query, cookie, header]}
            },
            %% `erli18n_cowboy` runs BEFORE the handler. The default sources need
            %% no router binding, so it can run ahead of `cowboy_router` (a
            %% `path_binding` source would instead require it AFTER the router).
            middlewares => [erli18n_cowboy, cowboy_router, cowboy_handler]
        }
    ),
    erli18n_cowboy_demo_sup:start_link().

stop(_State) ->
    ok = cowboy:stop_listener(?LISTENER).

%% Load the bundled `pt_BR` + `es` catalogs into the `default` gettext domain.
%% A failed load crashes the boot on purpose — a broken example should fail
%% loudly rather than silently serve raw msgids.
load_catalogs() ->
    Dir = filename:join(code:priv_dir(erli18n_cowboy_demo), "gettext"),
    Po = fun(Locale) ->
        filename:join([Dir, Locale, "LC_MESSAGES", "default.po"])
    end,
    {ok, _} = erli18n_server:ensure_loaded(default, <<"pt_BR">>, Po("pt_BR")),
    {ok, _} = erli18n_server:ensure_loaded(default, <<"es">>, Po("es")),
    ok.
