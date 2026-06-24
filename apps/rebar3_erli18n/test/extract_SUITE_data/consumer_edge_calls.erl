%% Extraction fixture covering edge call shapes:
%%   * an `erli18n:` call that is NOT a gettext-family function (must be
%%     ignored by the keyword spec, walked-through without extraction);
%%   * a recognized call NESTED inside another expression (the walk descends).
-module(consumer_edge_calls).

-include_lib("erli18n/include/erli18n.hrl").

-export([non_gettext_call/0, nested_call/0]).

%% `erli18n:which_locale/0` is a real facade function but NOT in the keyword
%% spec — the extractor must walk past it, extracting nothing.
non_gettext_call() ->
    L = erli18n:which_locale(),
    {L, erli18n:gettext(<<"After a non-gettext call">>)}.

%% A recognized call nested inside a list/tuple literal — the recursive walk
%% must reach it.
nested_call() ->
    [erli18n:gettext(<<"Nested in a list">>)].
