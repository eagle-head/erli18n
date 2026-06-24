-module(erli18n_demo_greeting).

-moduledoc """
Greeting and notification copy for the demo app, all in the DEFAULT gettext
domain.

Every call below uses a compile-time-LITERAL msgid, so `rebar3 erli18n
extract` discovers each one and writes it into `default.pot`. This module is
production code a real downstream app would ship: the strings are the
user-facing copy, and the runtime calls translate them through whatever
catalog `erli18n` has loaded for the negotiated locale.
""".

-export([
    welcome/0,
    farewell/0,
    unread_summary/1,
    greet/1
]).

%% Plain singular — `gettext/1`. Keyed under the module's `?GETTEXT_DOMAIN`
%% (here the implicit `default`, since this module does not override it).
-spec welcome() -> binary().
welcome() ->
    erli18n:gettext(<<"Welcome to the demo application">>).

-spec farewell() -> binary().
farewell() ->
    erli18n:gettext(<<"Goodbye, see you next time">>).

%% Plural — `ngettext/3`. Both the singular and plural msgids are literals, so
%% the entry carries `msgid` + `msgid_plural` into the catalog.
-spec unread_summary(non_neg_integer()) -> binary().
unread_summary(Count) ->
    erli18n:ngettext(
        <<"You have one unread message">>,
        <<"You have %{count} unread messages">>,
        Count
    ).

%% Interpolating f-family — `gettextf/2`. The trailing bindings map is ignored
%% for extraction; only the literal msgid is pulled into the catalog.
-spec greet(binary()) -> binary().
greet(Name) ->
    erli18n:gettextf(<<"Hello, %{name}!">>, #{name => Name}).
