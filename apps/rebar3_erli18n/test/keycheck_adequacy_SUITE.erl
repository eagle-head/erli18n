-module(keycheck_adequacy_SUITE).

-moduledoc """
Boundary behavior for `rebar3_erli18n_keycheck` that the functional
`keycheck_SUITE` cases leave implicit:

- `warn` returns the SAME `{violations, _}` shape as `strict` (the warn/strict
  fail-vs-log split is the provider's job, modeled here at the return-value
  level);
- a call site whose domain is ABSENT from the universe map is never flagged
  (domain scoping keeps unknown domains silent);
- an empty universe with empty call sites is `ok` (no spurious violations).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    warn_policy_returns_violations/1,
    strict_policy_returns_violations/1,
    domain_absent_from_universe_never_flagged/1,
    empty_universe_and_call_sites_is_ok/1,
    contextual_violations_sort_by_context/1
]).

all() ->
    [
        warn_policy_returns_violations,
        strict_policy_returns_violations,
        domain_absent_from_universe_never_flagged,
        empty_universe_and_call_sites_is_ok,
        contextual_violations_sort_by_context
    ].

entry(Domain, Ctx, Msgid, Refs) ->
    #{
        domain => Domain,
        kind => singular,
        context => Ctx,
        msgid => Msgid,
        plural => undefined,
        references => Refs
    }.

universe(KeyList) ->
    sets:from_list(KeyList).

%% `warn` performs the comparison and returns `{violations, _}` exactly like
%% `strict`; the difference (log vs fail) is mapped by the provider.
warn_policy_returns_violations(_Config) ->
    Universe = #{default => universe([])},
    CallSites = #{default => [entry(default, undefined, <<"X">>, [{"a.erl", 1}])]},
    ?assertMatch(
        {violations, [{default, undefined, <<"X">>, [{"a.erl", 1}]}]},
        rebar3_erli18n_keycheck:check(Universe, CallSites, warn)
    ).

%% `strict` returns the same `{violations, _}`; the provider maps strict to a
%% build failure. Asserted here purely at the return-value level (the path
%% mapping itself is verified at the provider level).
strict_policy_returns_violations(_Config) ->
    Universe = #{default => universe([])},
    CallSites = #{default => [entry(default, undefined, <<"X">>, [{"a.erl", 1}])]},
    ?assertMatch(
        {violations, [{default, undefined, <<"X">>, [{"a.erl", 1}]}]},
        rebar3_erli18n_keycheck:check(Universe, CallSites, strict)
    ).

%% Domain scoping: a call site for a domain with NO entry in the universe map
%% is simply skipped — never reported, even under `strict`.
domain_absent_from_universe_never_flagged(_Config) ->
    Universe = #{default => universe([{undefined, <<"Known">>}])},
    CallSites = #{uncompiled => [entry(uncompiled, undefined, <<"Anything">>, [{"a.erl", 1}])]},
    ?assertEqual(ok, rebar3_erli18n_keycheck:check(Universe, CallSites, strict)).

%% Degenerate input: no compiled catalogs and no call sites -> ok.
empty_universe_and_call_sites_is_ok(_Config) ->
    ?assertEqual(ok, rebar3_erli18n_keycheck:check(#{}, #{}, strict)),
    ?assertEqual(ok, rebar3_erli18n_keycheck:check(#{}, #{}, warn)),
    ?assertEqual(ok, rebar3_erli18n_keycheck:check(#{}, #{}, off)).

%% Two CONTEXTUAL (non-undefined msgctxt) violations for the same domain, sites
%% and msgid tie-break on the context: the diagnostics sort deterministically by
%% context (`norm_ctx/1`'s non-undefined branch), so `<<"menu">>` sorts before
%% `<<"toolbar">>`. Pins the contextual (pgettext) key path the existing
%% context-less cases never exercise.
contextual_violations_sort_by_context(_Config) ->
    Universe = #{default => universe([])},
    CallSites = #{
        default => [
            entry(default, <<"toolbar">>, <<"Save">>, [{"a.erl", 1}]),
            entry(default, <<"menu">>, <<"Save">>, [{"a.erl", 1}])
        ]
    },
    ?assertMatch(
        {violations, [
            {default, <<"menu">>, <<"Save">>, [{"a.erl", 1}]},
            {default, <<"toolbar">>, <<"Save">>, [{"a.erl", 1}]}
        ]},
        rebar3_erli18n_keycheck:check(Universe, CallSites, strict)
    ).
