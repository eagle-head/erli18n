-module(erli18n_demo_errors).

-moduledoc """
Error-message copy for the demo app, partitioned into the `errors` gettext
domain via the public `?GETTEXT_DOMAIN` macro.

Defining `?GETTEXT_DOMAIN` to a LITERAL atom before including `erli18n.hrl`
moves every bare-family call in this module into `errors.pot` instead of
`default.pot`. The extractor reads the macro from the expanded abstract form
(it must be a literal atom), so this whole module's strings land under the
`errors` domain — the multi-domain story a real app uses to separate, e.g.,
validation errors from general UI copy.
""".

-define(GETTEXT_DOMAIN, errors).
-include_lib("erli18n/include/erli18n.hrl").

-export([
    not_found/0,
    forbidden/0,
    field_required/1,
    too_many_attempts/1
]).

%% Bare `gettext/1`, but keyed under `errors` because of the macro override.
-spec not_found() -> binary().
not_found() ->
    erli18n:gettext(<<"The requested resource was not found">>).

-spec forbidden() -> binary().
forbidden() ->
    erli18n:gettext(<<"You do not have permission to perform this action">>).

%% Contextual singular with `f`-family interpolation — `pgettextf/3`. The
%% literal context `<<"validation">>` disambiguates this msgid from any
%% same-text msgid in another context, and the `%{field}` placeholder is
%% substituted from `Bindings`.
-spec field_required(binary()) -> binary().
field_required(Field) ->
    erli18n:pgettextf(
        <<"validation">>,
        <<"The %{field} field is required">>,
        #{field => Field}
    ).

%% Contextual plural — `npgettext/4`, all leading slots literal.
-spec too_many_attempts(non_neg_integer()) -> binary().
too_many_attempts(Remaining) ->
    erli18n:npgettext(
        <<"security">>,
        <<"One attempt remaining">>,
        <<"%{count} attempts remaining">>,
        Remaining
    ).
