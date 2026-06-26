-module(erli18n_cowboy_demo_handler).

-moduledoc """
Cowboy handler that renders three demo strings in the locale the `erli18n_cowboy`
middleware already negotiated and set on this request process. No locale argument
is threaded — every `erli18n` lookup reads the per-process locale.

The locale set by the middleware is visible here because Cowboy runs the
middleware chain and the handler in **one** request process. It would NOT be
visible in a process this handler spawns (a pooled worker, a `gen_server`, a
`Task`-style job, a stream handler that offloads): that process starts at
`erli18n:which_locale() = undefined`. Capture `erli18n:which_locale()` and
re-`setlocale/1` it across any such boundary.
""".

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Locale = erli18n:which_locale(),
    Body = [
        <<"locale: ">>,
        locale_label(Locale),
        <<"\n">>,
        erli18n:gettext(<<"Welcome to erli18n">>),
        <<"\n">>,
        erli18n:gettextf(<<"Hello, %{name}!">>, #{name => <<"world">>}),
        <<"\n">>,
        erli18n:ngettextf(
            <<"You have one unread message">>,
            <<"You have %{count} unread messages">>,
            3,
            #{}
        ),
        <<"\n">>
    ],
    Req = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
        Body,
        Req0
    ),
    {ok, Req, State}.

%% `which_locale/0` is `undefined` only if the middleware never ran; here it
%% always set one, but render defensively rather than crashing the response.
locale_label(undefined) -> <<"(none)">>;
locale_label(Locale) -> Locale.
