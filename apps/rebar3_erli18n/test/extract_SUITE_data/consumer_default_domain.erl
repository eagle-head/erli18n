%% Extraction fixture using the DEFAULT `?GETTEXT_DOMAIN` (no override), so
%% the macro expands to `default` and bare-family calls land under `default`.
%% Exercises the literal-extraction, dynamic-skip, and non-literal-domain-skip
%% paths through the public include.
-module(consumer_default_domain).

-include_lib("erli18n/include/erli18n.hrl").

-export([
    plain/0,
    domained/1,
    contextual/0,
    plurals/1,
    interpolating/1,
    dynamic_skipped/1,
    nonliteral_domain_skipped/1,
    macro_domain/0,
    duplicate_msgid/0
]).

%% gettext/1,2,3 — bare singular (domain = default via the macro).
plain() ->
    A = erli18n:gettext(<<"Hello">>),
    B = erli18n:gettext(mydomain, <<"Goodbye">>),
    C = erli18n:gettext(mydomain, <<"See you">>, <<"pt_BR">>),
    {A, B, C}.

%% d/dc singular — Domain is the FIRST argument (literal atom).
domained(Locale) ->
    A = erli18n:dgettext(accounts, <<"Sign in">>),
    B = erli18n:dgettext(accounts, <<"Sign out">>, Locale),
    C = erli18n:dcgettext(accounts, <<"Reset password">>, Locale),
    {A, B, C}.

%% p/dp/dcp — contextual singular.
contextual() ->
    A = erli18n:pgettext(<<"menu">>, <<"File">>),
    B = erli18n:pgettext(mydomain, <<"menu">>, <<"Edit">>),
    C = erli18n:dpgettext(mydomain, <<"button">>, <<"Save">>),
    {A, B, C}.

%% n/dn and np — plural msgid + msgid_plural.
plurals(N) ->
    A = erli18n:ngettext(<<"one apple">>, <<"many apples">>, N),
    B = erli18n:dngettext(fruit, <<"one pear">>, <<"many pears">>, N),
    C = erli18n:npgettext(<<"cart">>, <<"one item">>, <<"many items">>, N),
    {A, B, C}.

%% f-family — trailing Bindings map, ignored for msgid extraction.
interpolating(N) ->
    A = erli18n:gettextf(<<"Hi %{name}">>, #{name => <<"Sam">>}),
    B = erli18n:ngettextf(<<"%{count} file">>, <<"%{count} files">>, N, #{}),
    C = erli18n:dpgettextf(msgs, <<"alert">>, <<"%{n} left">>, #{n => N}),
    {A, B, C}.

%% Dynamic msgid — must be SKIPPED.
dynamic_skipped(Var) ->
    erli18n:gettext(Var).

%% Non-literal d/dc Domain — must be SKIPPED.
nonliteral_domain_skipped(Domain) ->
    erli18n:dgettext(Domain, <<"Only literal domains extract">>).

%% `?GETTEXT_DOMAIN` resolves (default) via epp.
macro_domain() ->
    erli18n:dgettext(?GETTEXT_DOMAIN, <<"Domain from macro">>).

%% Same msgid referenced from two call sites — must dedup to ONE entry with
%% TWO `#:` references.
duplicate_msgid() ->
    A = erli18n:gettext(<<"Repeated">>),
    B = erli18n:gettext(<<"Repeated">>),
    {A, B}.
