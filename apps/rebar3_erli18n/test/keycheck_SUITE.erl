-module(keycheck_SUITE).

-moduledoc """
Unit tests for the pure key-existence checker `rebar3_erli18n_keycheck`.

Pins the core contract: an absent literal key is a violation; a present one is
`ok`; a key supplied via the locale union (including one sourced only from the
`.pot`) passes; the `off` policy short-circuits; diagnostics are sorted by
`{Domain, File, Line}`; the diagnostic text is byte-stable and carries the
exact remediation commands; and a key referenced across several locales is
reported exactly once.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    absent_key_is_violation/1,
    present_key_is_ok/1,
    pot_only_key_passes_via_union/1,
    off_policy_returns_ok/1,
    deterministic_sort_by_domain_file_line/1,
    byte_pinned_diagnostic_text/1,
    shared_across_three_locales_reported_once/1
]).

all() ->
    [
        absent_key_is_violation,
        present_key_is_ok,
        pot_only_key_passes_via_union,
        off_policy_returns_ok,
        deterministic_sort_by_domain_file_line,
        byte_pinned_diagnostic_text,
        shared_across_three_locales_reported_once
    ].

%% A deduplicated singular call site, matching `rebar3_erli18n_common:dedup_entry()`.
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

%% A literal call site whose key is NOT in the compiled universe -> a violation
%% carrying that call site.
absent_key_is_violation(_Config) ->
    Universe = #{default => universe([{undefined, <<"Known">>}])},
    CallSites = #{default => [entry(default, undefined, <<"Unknown">>, [{"a.erl", 1}])]},
    ?assertEqual(
        {violations, [{default, undefined, <<"Unknown">>, [{"a.erl", 1}]}]},
        rebar3_erli18n_keycheck:check(Universe, CallSites, strict)
    ).

%% A literal call site whose key IS in the compiled universe -> ok.
present_key_is_ok(_Config) ->
    Universe = #{default => universe([{undefined, <<"Known">>}])},
    CallSites = #{default => [entry(default, undefined, <<"Known">>, [{"a.erl", 1}])]},
    ?assertEqual(ok, rebar3_erli18n_keycheck:check(Universe, CallSites, strict)).

%% The universe is the union of every locale's keys (and may include keys
%% sourced only from the `.pot` template). A call site satisfied by that union
%% passes even though it is not in any single locale's `.po` by itself.
pot_only_key_passes_via_union(_Config) ->
    %% `{undefined, <<"FromPot">>}` models a key present only in the `.pot`;
    %% the union also carries a per-locale key. Both are in the set.
    Universe = #{default => universe([{undefined, <<"FromLocale">>}, {undefined, <<"FromPot">>}])},
    CallSites = #{default => [entry(default, undefined, <<"FromPot">>, [{"a.erl", 1}])]},
    ?assertEqual(ok, rebar3_erli18n_keycheck:check(Universe, CallSites, strict)).

%% `off` short-circuits: even an absent key is not reported.
off_policy_returns_ok(_Config) ->
    Universe = #{default => universe([])},
    CallSites = #{default => [entry(default, undefined, <<"Unknown">>, [{"a.erl", 1}])]},
    ?assertEqual(ok, rebar3_erli18n_keycheck:check(Universe, CallSites, off)).

%% Diagnostics are sorted by `{Domain, File, Line}` regardless of input order
%% or map iteration order.
deterministic_sort_by_domain_file_line(_Config) ->
    Universe = #{default => universe([]), errors => universe([])},
    CallSites = #{
        default => [
            entry(default, undefined, <<"M2">>, [{"z.erl", 5}]),
            entry(default, undefined, <<"M1">>, [{"a.erl", 1}])
        ],
        errors => [entry(errors, undefined, <<"E">>, [{"a.erl", 9}])]
    },
    ?assertEqual(
        {violations, [
            {default, undefined, <<"M1">>, [{"a.erl", 1}]},
            {default, undefined, <<"M2">>, [{"z.erl", 5}]},
            {errors, undefined, <<"E">>, [{"a.erl", 9}]}
        ]},
        rebar3_erli18n_keycheck:check(Universe, CallSites, strict)
    ).

%% The rendered diagnostic is byte-for-byte stable and carries the exact
%% extract-then-compile remediation, for both the context-less and the
%% contextual shapes.
byte_pinned_diagnostic_text(_Config) ->
    Bare = rebar3_erli18n_keycheck:format_diag(
        {default, undefined, <<"Hi">>, [{"a.erl", 1}, {"b.erl", 2}]}
    ),
    ?assertEqual(
        <<
            "erli18n: msgid \"Hi\" in domain 'default' is missing from the compiled catalog.\n"
            "  call sites: a.erl:1, b.erl:2\n"
            "  remediation: run 'rebar3 erli18n extract' then 'rebar3 erli18n compile' "
            "to regenerate the compiled catalog."
        >>,
        Bare
    ),
    Ctxual = rebar3_erli18n_keycheck:format_diag(
        {default, <<"menu">>, <<"File">>, [{"m.erl", 3}]}
    ),
    ?assertEqual(
        <<
            "erli18n: msgid \"File\" (context \"menu\") in domain 'default' is missing "
            "from the compiled catalog.\n"
            "  call sites: m.erl:3\n"
            "  remediation: run 'rebar3 erli18n extract' then 'rebar3 erli18n compile' "
            "to regenerate the compiled catalog."
        >>,
        Ctxual
    ).

%% The universe is locale-invariant: a key absent from a union built out of
%% three locales' worth of OTHER keys yields exactly ONE diagnostic for the
%% single deduplicated call site, not one per locale.
shared_across_three_locales_reported_once(_Config) ->
    %% Union across pt/es/fr carrying unrelated keys; the call-site key is in
    %% none of them.
    Union = universe([
        {undefined, <<"pt_key">>},
        {undefined, <<"es_key">>},
        {undefined, <<"fr_key">>}
    ]),
    Universe = #{default => Union},
    CallSites = #{default => [entry(default, undefined, <<"Missing">>, [{"a.erl", 1}])]},
    {violations, Diags} = rebar3_erli18n_keycheck:check(Universe, CallSites, strict),
    ?assertEqual(1, length(Diags)),
    ?assertMatch([{default, undefined, <<"Missing">>, [{"a.erl", 1}]}], Diags).
