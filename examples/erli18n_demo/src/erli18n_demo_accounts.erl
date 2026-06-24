-module(erli18n_demo_accounts).

-moduledoc """
Account-flow copy for the demo app, using the explicit-domain `d`/`dc`
families so the strings land in the `accounts` domain WITHOUT a module-wide
`?GETTEXT_DOMAIN` override.

The `d`/`dc` families carry the gettext `Domain` as the FIRST argument; it
must be a literal atom for extraction (a dynamic domain is skipped, never
mis-keyed). This module also documents the dynamic-msgid caveat: a msgid that
is a runtime value is deliberately NOT extracted, yet still translates
correctly at runtime.
""".

-export([
    sign_in/0,
    sign_out/1,
    password_reset/1,
    seats_left/1,
    %% Demonstrates the dynamic-key caveat (NOT extracted).
    dynamic_label/1
]).

%% `dgettext/2` — explicit literal-atom domain `accounts` in arg 1.
-spec sign_in() -> binary().
sign_in() ->
    erli18n:dgettext(accounts, <<"Sign in to your account">>).

%% `dgettextf/3` — explicit domain + f-family interpolation.
-spec sign_out(binary()) -> binary().
sign_out(Name) ->
    erli18n:dgettextf(accounts, <<"Goodbye, %{name} — you are signed out">>, #{name => Name}).

%% `dcgettext/3` — the dc variant (explicit domain, locale category arg).
-spec password_reset(binary()) -> binary().
password_reset(Locale) ->
    erli18n:dcgettext(accounts, <<"We sent a password reset link to your email">>, Locale).

%% `dngettext/4` — explicit-domain plural.
-spec seats_left(non_neg_integer()) -> binary().
seats_left(N) ->
    erli18n:dngettext(
        accounts,
        <<"One seat left on your plan">>,
        <<"%{count} seats left on your plan">>,
        N
    ).

%% The dynamic-msgid caveat in action: the msgid here is a RUNTIME value, not a
%% compile-time literal, so `rebar3 erli18n extract` does NOT pull it into the
%% `.pot` (and `check` therefore never false-fails on it). The translation
%% still works at runtime AS LONG AS the resolved key already exists in the
%% catalog — the app must ensure that by other means (e.g. extracting the
%% literal forms elsewhere, or a `gettext_noop`-style anchor).
-spec dynamic_label(binary()) -> binary().
dynamic_label(Key) ->
    erli18n:gettext(Key).
