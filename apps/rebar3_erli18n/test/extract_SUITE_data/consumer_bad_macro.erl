%% Extraction fixture whose `?GETTEXT_DOMAIN` is overridden to a NON-atom
%% (a string). The extractor's macro reader must fall back to the safe
%% `default` rather than mis-resolve it, and bare-family calls land under
%% `default`.
-module(consumer_bad_macro).

-define(GETTEXT_DOMAIN, "not_an_atom").
-include_lib("erli18n/include/erli18n.hrl").

-export([greet/0]).

greet() ->
    erli18n:gettext(<<"Hello from bad macro">>).
