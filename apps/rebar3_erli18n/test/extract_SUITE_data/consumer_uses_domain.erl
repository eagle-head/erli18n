%% Extraction fixture: a consumer module that calls the erli18n facade
%% family in every shape the keyword spec must recognize.
%%
%% It is compiled/scanned by the extractor through `epp` so that
%% `?GETTEXT_DOMAIN` (from include/erli18n.hrl) is expanded to a literal
%% atom BEFORE the abstract form is walked. The suite asserts:
%%   * literal msgid/msgid_plural/msgctxt are extracted with the right Domain
%%   * `?GETTEXT_DOMAIN` resolves to the literal atom `default`
%%   * an overridden literal domain (here: `errors`) is picked up
%%   * dynamic (non-literal) msgids are skipped, never errored
%%   * a non-literal d/dc Domain is skipped, never mis-domained
-module(consumer_uses_domain).

-define(GETTEXT_DOMAIN, errors).
-include_lib("erli18n/include/erli18n.hrl").

-export([
    plain/0,
    domained/1,
    contextual/0,
    plurals/1,
    interpolating/1,
    dynamic_skipped/1,
    nonliteral_domain_skipped/1,
    macro_domain/0
]).

%% gettext/1,2,3 — plain singular.
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

%% p/dp/dcp — contextual singular (Context follows Domain).
contextual() ->
    A = erli18n:pgettext(<<"menu">>, <<"File">>),
    B = erli18n:pgettext(mydomain, <<"menu">>, <<"Edit">>),
    C = erli18n:dpgettext(mydomain, <<"button">>, <<"Save">>),
    {A, B, C}.

%% n/dn/dcn and np families — plural msgid + msgid_plural.
plurals(N) ->
    A = erli18n:ngettext(<<"one apple">>, <<"many apples">>, N),
    B = erli18n:dngettext(fruit, <<"one pear">>, <<"many pears">>, N),
    C = erli18n:npgettext(<<"cart">>, <<"one item">>, <<"many items">>, N),
    {A, B, C}.

%% f-family — trailing Bindings map, ignored for msgid extraction.
interpolating(N) ->
    A = erli18n:gettextf(<<"Hi %{name}">>, #{name => <<"Sam">>}),
    B = erli18n:ngettextf(
        <<"%{count} file">>, <<"%{count} files">>, N, #{}
    ),
    C = erli18n:dpgettextf(
        msgs, <<"alert">>, <<"%{n} left">>, #{n => N}
    ),
    {A, B, C}.

%% Dynamic msgid — must be SKIPPED (not extracted, not errored).
dynamic_skipped(Var) ->
    erli18n:gettext(Var).

%% Non-literal d/dc Domain — must be SKIPPED (never mis-domained).
nonliteral_domain_skipped(Domain) ->
    erli18n:dgettext(Domain, <<"Only literal domains extract">>).

%% `?GETTEXT_DOMAIN` resolves to a literal atom via epp (here overridden to
%% `errors`); the extractor must read it as `errors`, not as a runtime call.
macro_domain() ->
    erli18n:dgettext(?GETTEXT_DOMAIN, <<"Domain from macro">>).
