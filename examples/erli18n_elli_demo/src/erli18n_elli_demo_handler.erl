-module(erli18n_elli_demo_handler).

-moduledoc """
Elli handler that renders three demo strings in the locale the `erli18n_elli`
middleware already negotiated and set on this request process. No locale argument
is threaded — every `erli18n` lookup reads the per-process locale.

The locale is visible here because Elli runs the middleware and the handler in
**one** request process. It would NOT be visible in a process this handler spawns
(a pooled worker, a `gen_server`, a `Task`-style job): that process starts at
`erli18n:which_locale() = undefined`. Capture `erli18n:which_locale()` and
re-`setlocale/1` it across any such boundary.
""".

-behaviour(elli_handler).

-export([handle/2, handle_event/3]).

handle(_Req, _Args) ->
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
    {200, [{<<"Content-Type">>, <<"text/plain; charset=utf-8">>}], Body}.

%% Elli emits lifecycle/error events through this callback; the demo ignores them.
handle_event(_Event, _Args, _Config) ->
    ok.

%% `which_locale/0` is `undefined` only if the middleware never ran; here it
%% always set one, but render defensively rather than crashing the response.
locale_label(undefined) -> <<"(none)">>;
locale_label(Locale) -> Locale.
