-module(keywords_SUITE).

-moduledoc """
Tests for `rebar3_erli18n_keywords` — the name-AND-arity keyword spec.

Asserts that every recognized `{Name, Arity}` resolves to the correct
literal-slot indices (verified against the `erli18n` facade clause heads),
that the d/dc families shift the slots right by one, that the p/np families
carry a context slot, that the plural families carry a plural slot, and that
the Phase 1 `f`-family mirrors its non-`f` sibling's leading slots.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    bare_singular/1,
    domained_singular/1,
    contextual_singular/1,
    bare_plural/1,
    contextual_plural/1,
    f_family_mirrors_sibling/1,
    unknown_call_is_error/1,
    spec_covers_full_facade/1,
    spec_is_a_shared_constant/1
]).

all() ->
    [
        bare_singular,
        domained_singular,
        contextual_singular,
        bare_plural,
        contextual_plural,
        f_family_mirrors_sibling,
        unknown_call_is_error,
        spec_covers_full_facade,
        spec_is_a_shared_constant
    ].

bare_singular(_Config) ->
    ?assertEqual(
        {ok, #{domain => from_macro, msgid => 1, kind => singular}},
        rebar3_erli18n_keywords:lookup(gettext, 1)
    ),
    ?assertEqual(
        {ok, #{domain => 1, msgid => 2, kind => singular}},
        rebar3_erli18n_keywords:lookup(gettext, 2)
    ),
    %% gettext/3 carries a trailing Locale; msgid slot is still 2.
    ?assertEqual(
        {ok, #{domain => 1, msgid => 2, kind => singular}},
        rebar3_erli18n_keywords:lookup(gettext, 3)
    ).

domained_singular(_Config) ->
    %% Domain is the FIRST arg; msgid shifts to slot 2.
    ?assertEqual(
        {ok, #{domain => 1, msgid => 2, kind => singular}},
        rebar3_erli18n_keywords:lookup(dgettext, 2)
    ),
    ?assertEqual(
        {ok, #{domain => 1, msgid => 2, kind => singular}},
        rebar3_erli18n_keywords:lookup(dcgettext, 3)
    ).

contextual_singular(_Config) ->
    %% Bare p: context=1, msgid=2.
    ?assertEqual(
        {ok, #{domain => from_macro, context => 1, msgid => 2, kind => singular}},
        rebar3_erli18n_keywords:lookup(pgettext, 2)
    ),
    %% Domained p: domain=1, context=2, msgid=3.
    ?assertEqual(
        {ok, #{domain => 1, context => 2, msgid => 3, kind => singular}},
        rebar3_erli18n_keywords:lookup(pgettext, 3)
    ),
    ?assertEqual(
        {ok, #{domain => 1, context => 2, msgid => 3, kind => singular}},
        rebar3_erli18n_keywords:lookup(dcpgettext, 4)
    ).

bare_plural(_Config) ->
    %% Bare n: msgid=1, plural=2.
    ?assertEqual(
        {ok, #{domain => from_macro, msgid => 1, plural => 2, kind => plural}},
        rebar3_erli18n_keywords:lookup(ngettext, 3)
    ),
    %% Domained n: domain=1, msgid=2, plural=3.
    ?assertEqual(
        {ok, #{domain => 1, msgid => 2, plural => 3, kind => plural}},
        rebar3_erli18n_keywords:lookup(dngettext, 4)
    ).

contextual_plural(_Config) ->
    %% Bare np: context=1, msgid=2, plural=3.
    ?assertEqual(
        {ok, #{domain => from_macro, context => 1, msgid => 2, plural => 3, kind => plural}},
        rebar3_erli18n_keywords:lookup(npgettext, 4)
    ),
    %% Domained np: domain=1, context=2, msgid=3, plural=4.
    ?assertEqual(
        {ok, #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural}},
        rebar3_erli18n_keywords:lookup(dcnpgettext, 6)
    ).

f_family_mirrors_sibling(_Config) ->
    %% gettextf/2 leading slots == gettext/1 leading slots (ignoring the
    %% trailing Bindings map).
    {ok, NonF} = rebar3_erli18n_keywords:lookup(gettext, 1),
    {ok, F} = rebar3_erli18n_keywords:lookup(gettextf, 2),
    ?assertEqual(maps:get(msgid, NonF), maps:get(msgid, F)),
    ?assertEqual(maps:get(domain, NonF), maps:get(domain, F)),
    %% npgettextf/5 mirrors npgettext/4 leading slots.
    {ok, NpNonF} = rebar3_erli18n_keywords:lookup(npgettext, 4),
    {ok, NpF} = rebar3_erli18n_keywords:lookup(npgettextf, 5),
    ?assertEqual(maps:get(context, NpNonF), maps:get(context, NpF)),
    ?assertEqual(maps:get(msgid, NpNonF), maps:get(msgid, NpF)),
    ?assertEqual(maps:get(plural, NpNonF), maps:get(plural, NpF)).

unknown_call_is_error(_Config) ->
    ?assertEqual(error, rebar3_erli18n_keywords:lookup(gettext, 9)),
    ?assertEqual(error, rebar3_erli18n_keywords:lookup(not_a_gettext, 2)),
    %% spec/0 returns a map keyed by {Name, Arity}.
    Spec = rebar3_erli18n_keywords:spec(),
    ?assert(is_map(Spec)),
    ?assert(maps:is_key({gettext, 1}, Spec)).

%% Every facade clause head with a literal msgid slot must be in the spec.
%% This guards against a future facade arity silently dropping out of the
%% extractor's recognition set.
spec_covers_full_facade(_Config) ->
    Spec = rebar3_erli18n_keywords:spec(),
    Expected = [
        {gettext, 1},
        {gettext, 2},
        {gettext, 3},
        {dgettext, 2},
        {dgettext, 3},
        {dcgettext, 3},
        {ngettext, 3},
        {ngettext, 4},
        {ngettext, 5},
        {dngettext, 4},
        {dngettext, 5},
        {dcngettext, 5},
        {pgettext, 2},
        {pgettext, 3},
        {pgettext, 4},
        {dpgettext, 3},
        {dpgettext, 4},
        {dcpgettext, 4},
        {npgettext, 4},
        {npgettext, 5},
        {npgettext, 6},
        {dnpgettext, 5},
        {dnpgettext, 6},
        {dcnpgettext, 6},
        {gettextf, 2},
        {gettextf, 3},
        {gettextf, 4},
        {dgettextf, 3},
        {dgettextf, 4},
        {dcgettextf, 4},
        {ngettextf, 4},
        {ngettextf, 5},
        {ngettextf, 6},
        {dngettextf, 5},
        {dngettextf, 6},
        {dcngettextf, 6},
        {pgettextf, 3},
        {pgettextf, 4},
        {pgettextf, 5},
        {dpgettextf, 4},
        {dpgettextf, 5},
        {dcpgettextf, 5},
        {npgettextf, 5},
        {npgettextf, 6},
        {npgettextf, 7},
        {dnpgettextf, 6},
        {dnpgettextf, 7},
        {dcnpgettextf, 7}
    ],
    lists:foreach(
        fun(Key) -> ?assert(maps:is_key(Key, Spec)) end,
        Expected
    ),
    %% No extra rows beyond the expected set.
    ?assertEqual(lists:sort(Expected), lists:sort(maps:keys(Spec))).

%% The spec table is a compile-time literal, so the compiler builds it once
%% and every call returns the same shared constant — not a per-call merge that
%% rebuilds a fresh map each time. Repeated calls must therefore be the SAME
%% term by identity (erts_debug:same/2), which fails against a `maps:merge`
%% implementation that allocates a new map on every call.
spec_is_a_shared_constant(_Config) ->
    A = rebar3_erli18n_keywords:spec(),
    B = rebar3_erli18n_keywords:spec(),
    ?assert(erts_debug:same(A, B)),
    %% Still observably the full, correct table.
    ?assertEqual(A, B),
    ?assert(maps:is_key({gettext, 1}, A)).
