-module(common_SUITE).

-moduledoc """
Unit tests for the pure helpers of `rebar3_erli18n_common`: deduplication of
extracted call sites into catalog entries (merging and ordering references),
`.pot` construction for singular and plural entries, and the shared
`format_error/1` rendering.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    dedup_merges_references/1,
    dedup_orders_by_context_and_msgid/1,
    dedup_dedups_identical_references/1,
    entries_to_pot_singular/1,
    entries_to_pot_plural/1,
    format_error_variants/1,
    runtime_lib_path_resolves/1,
    format_lib_path_clauses/1,
    maybe_log_runtime_lib_path_unset/1,
    maybe_log_runtime_lib_path_set/1
]).

all() ->
    [
        dedup_merges_references,
        dedup_orders_by_context_and_msgid,
        dedup_dedups_identical_references,
        entries_to_pot_singular,
        entries_to_pot_plural,
        format_error_variants,
        runtime_lib_path_resolves,
        format_lib_path_clauses,
        maybe_log_runtime_lib_path_unset,
        maybe_log_runtime_lib_path_set
    ].

extracted(Domain, Kind, Ctx, Msgid, Plural, Ref) ->
    #{
        domain => Domain,
        kind => Kind,
        context => Ctx,
        msgid => Msgid,
        plural => Plural,
        reference => Ref
    }.

dedup_merges_references(_Config) ->
    %% Same {Context, Msgid} from two sites -> one entry, both references.
    Raw = [
        extracted(default, singular, undefined, <<"Hi">>, undefined, {"a.erl", 1}),
        extracted(default, singular, undefined, <<"Hi">>, undefined, {"b.erl", 2})
    ],
    [Entry] = rebar3_erli18n_common:dedup_entries(Raw),
    ?assertEqual([{"a.erl", 1}, {"b.erl", 2}], maps:get(references, Entry)).

dedup_orders_by_context_and_msgid(_Config) ->
    %% Deterministic ordering by {Context, Msgid}. A contextual entry and a
    %% bare entry sort by their normalized context then msgid.
    Raw = [
        extracted(default, singular, <<"z">>, <<"B">>, undefined, {"x.erl", 9}),
        extracted(default, singular, undefined, <<"A">>, undefined, {"x.erl", 1})
    ],
    Entries = rebar3_erli18n_common:dedup_entries(Raw),
    Keys = [{maps:get(context, E), maps:get(msgid, E)} || E <- Entries],
    %% undefined context (normalized to <<>>) sorts before "z".
    ?assertEqual([{undefined, <<"A">>}, {<<"z">>, <<"B">>}], Keys).

dedup_dedups_identical_references(_Config) ->
    %% The SAME reference appearing twice collapses to one.
    Raw = [
        extracted(default, singular, undefined, <<"Hi">>, undefined, {"a.erl", 1}),
        extracted(default, singular, undefined, <<"Hi">>, undefined, {"a.erl", 1})
    ],
    [Entry] = rebar3_erli18n_common:dedup_entries(Raw),
    ?assertEqual([{"a.erl", 1}], maps:get(references, Entry)).

entries_to_pot_singular(_Config) ->
    [Dedup] = rebar3_erli18n_common:dedup_entries([
        extracted(default, singular, <<"ctx">>, <<"Hi">>, undefined, {"a.erl", 1})
    ]),
    Catalog = rebar3_erli18n_common:entries_to_pot([Dedup]),
    Bytes = rebar3_erli18n_po_meta:dump(Catalog),
    ?assert(binary:match(Bytes, <<"msgctxt \"ctx\"">>) =/= nomatch),
    ?assert(binary:match(Bytes, <<"msgid \"Hi\"">>) =/= nomatch),
    ?assert(binary:match(Bytes, <<"msgstr \"\"">>) =/= nomatch),
    ?assert(binary:match(Bytes, <<"#: a.erl:1">>) =/= nomatch).

entries_to_pot_plural(_Config) ->
    [Dedup] = rebar3_erli18n_common:dedup_entries([
        extracted(default, plural, undefined, <<"one">>, <<"many">>, {"p.erl", 3})
    ]),
    Catalog = rebar3_erli18n_common:entries_to_pot([Dedup]),
    Bytes = rebar3_erli18n_po_meta:dump(Catalog),
    ?assert(binary:match(Bytes, <<"msgid \"one\"">>) =/= nomatch),
    ?assert(binary:match(Bytes, <<"msgid_plural \"many\"">>) =/= nomatch),
    ?assert(binary:match(Bytes, <<"msgstr[0] \"\"">>) =/= nomatch),
    ?assert(binary:match(Bytes, <<"msgstr[1] \"\"">>) =/= nomatch).

format_error_variants(_Config) ->
    P1 = rebar3_erli18n_common:format_error({parse_failed, "f.erl", oops}),
    ?assert(string:find(P1, "f.erl") =/= nomatch),
    P2 = rebar3_erli18n_common:format_error({drift, <<"two stale">>}),
    ?assert(string:find(P2, "drift") =/= nomatch),
    P3 = rebar3_erli18n_common:format_error({po_parse_failed, "g.po", boom}),
    ?assert(string:find(P3, "g.po") =/= nomatch),
    P4 = rebar3_erli18n_common:format_error(other_reason),
    ?assert(string:find(P4, "other_reason") =/= nomatch).

%% The cross-package load-path diagnostic. `runtime_lib_path/0` is the
%% structural proof that the `erli18n_po` runtime module is reachable across
%% the published `{deps, [erli18n]}` boundary: in this in-node suite it is
%% loaded from the umbrella build (a concrete `.beam` path, or `cover_compiled`
%% under `--cover`); in a downstream consumer it resolves under that consumer's
%% `_build/<profile>/checkouts/erli18n/ebin`. Either way it must NOT be
%% `non_existing` — that would mean the plugin cannot reach the lib it depends
%% on. We also assert the module is genuinely callable (the cross-package edge
%% is live, not merely on the path).
runtime_lib_path_resolves(_Config) ->
    Which = rebar3_erli18n_common:runtime_lib_path(),
    ?assertNotEqual(non_existing, Which),
    ?assert(is_list(Which) orelse lists:member(Which, [cover_compiled, preloaded])),
    %% The published API the providers actually call is reachable: a trivial
    %% round-trip through erli18n_po proves the cross-package call resolves
    %% (no `undef erli18n_po:dump/1`).
    Dumped = erli18n_po:dump(#{header => #{raw => <<>>}, entries => []}),
    ?assert(is_binary(Dumped)),
    ?assertEqual(<<"\\\"q\\\"">>, erli18n_po:escape_string(<<"\"q\"">>)).

%% `format_lib_path/1` renders both `code:which/1` result shapes: a concrete
%% `.beam` path (verbatim) and the special atoms (spelled out).
format_lib_path_clauses(_Config) ->
    ?assertEqual(
        "/x/checkouts/erli18n/ebin/erli18n_po.beam",
        rebar3_erli18n_common:format_lib_path("/x/checkouts/erli18n/ebin/erli18n_po.beam")
    ),
    ?assertEqual("non_existing", rebar3_erli18n_common:format_lib_path(non_existing)),
    ?assertEqual("cover_compiled", rebar3_erli18n_common:format_lib_path(cover_compiled)),
    ?assertEqual("preloaded", rebar3_erli18n_common:format_lib_path(preloaded)).

%% With the diagnostic env var UNSET, the logger is never touched and the
%% function is a silent no-op returning `ok`.
maybe_log_runtime_lib_path_unset(_Config) ->
    true = os:unsetenv("ERLI18N_DIAG_LOADPATH"),
    ?assertEqual(ok, rebar3_erli18n_common:maybe_log_runtime_lib_path()).

%% With the env var SET, the function logs the resolved path through the rebar3
%% host logger (available in the CT node) and returns `ok`. Exercises the
%% logging branch end to end.
maybe_log_runtime_lib_path_set(_Config) ->
    true = os:putenv("ERLI18N_DIAG_LOADPATH", "1"),
    try
        ?assertEqual(ok, rebar3_erli18n_common:maybe_log_runtime_lib_path())
    after
        true = os:unsetenv("ERLI18N_DIAG_LOADPATH")
    end.
