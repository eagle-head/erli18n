-module(rebar3_erli18n_keycheck).

-moduledoc """
Pure key-existence checker for compile-time catalogs.

Compares the literal `msgid`s of a project's facade call sites (as
deduplicated by `rebar3_erli18n_common:extract_project/1`) against the
per-domain key universe of the *compiled* catalogs, and reports every call
site whose `{Context, Msgid}` has no matching compiled key. Each missing key
is reported exactly ONCE: the universe is the locale-invariant UNION of every
compiled locale's keys for a domain, and the call sites are already
deduplicated to one logical message each, so a `msgid` used in three locales
(or from three source files) yields a single diagnostic carrying all of its
call sites.

The module is PURE: no file or process I/O, no codegen, and no
`persistent_term` access. The reference universe is built by the caller
(the compile provider) by keying each parsed `.po`/`.pot` entry through
`rebar3_erli18n_common:entry_key/1`; `check/3` only consults the resulting
sets. Domain scoping (restricting the check to domains that
actually have a compiled catalog) is also the CALLER's responsibility: a call
site whose domain is ABSENT from the universe map is never flagged, so the
checker stays silent about domains the project did not opt into compiling.

## Policy

`check/3` is policy-driven: `off` short-circuits to `ok` without inspecting
anything; `warn` and `strict` both perform the comparison and return the same
`{violations, [diag()]}` when keys are missing (or `ok` when none are). The
distinction between *warn* (log and continue) and *strict* (fail the build) is
mapped by the provider that calls this function, not here — keeping the
checker a deterministic pure predicate.

## Determinism

The returned diagnostics are sorted by `{Domain, File, Line}` (then context
and msgid as tie-breakers), and each diagnostic's call sites are themselves
sorted and de-duplicated, so the output is byte-stable across runs and
machines. `format_diag/1` renders a diagnostic to a byte-pinnable message that
carries the exact `rebar3 erli18n extract` then `rebar3 erli18n compile`
remediation commands.
""".

-export([check/3, format_diag/1]).

-export_type([diag/0, policy/0]).

-doc """
One missing-key diagnostic: a logical message that a facade call site
references but the compiled catalog does not define.

`Domain` is the gettext domain; `Ctx` the message context (`undefined` for the
bare, context-less form); `Msgid` the literal message id; and `Sites` the
sorted, de-duplicated `{SourceFile, Line}` call sites that reference it.
""".
-type diag() :: {
    Domain :: atom(),
    Ctx :: undefined | binary(),
    Msgid :: binary(),
    Sites :: [{file:filename(), pos_integer()}]
}.

-doc """
The check policy.

`off` disables the check entirely (always `ok`); `warn` and `strict` both run
the comparison and return any `{violations, _}` identically — the caller maps
`warn` to a logged warning and `strict` to a build failure.
""".
-type policy() :: off | warn | strict.

%% A per-domain compiled key universe: the union, across every compiled locale
%% of a domain, of each entry's `{Context, Msgid}` identity key.
-type universe() :: #{atom() => sets:set({undefined | binary(), binary()})}.

%% Facade call sites grouped by domain, as produced by `extract_project/1`.
-type call_sites() :: #{atom() => [rebar3_erli18n_common:dedup_entry()]}.

-doc """
Compare call sites against the compiled key universe under `Policy`.

When `Policy` is `off`, returns `ok` without inspecting either map. Otherwise,
for every domain that is present in BOTH `Universe` and `CallSites`, each call
site whose `{Context, Msgid}` key is not an element of that domain's universe
set becomes a diagnostic. Domains in `CallSites` but ABSENT from `Universe` are
skipped (the caller's domain scoping). Returns `ok` when nothing is missing, or
`{violations, Diags}` with the diagnostics sorted by `{Domain, File, Line}`.
""".
-spec check(universe(), call_sites(), policy()) -> ok | {violations, [diag()]}.
check(_Universe, _CallSites, off) ->
    ok;
check(Universe, CallSites, Policy) when Policy =:= warn; Policy =:= strict ->
    case lists:sort(fun diag_order/2, collect(Universe, CallSites)) of
        [] -> ok;
        Diags -> {violations, Diags}
    end.

-doc """
Render a `diag()` to a byte-pinnable, remediation-carrying message.

The output is deterministic for a given diagnostic and names the exact
`rebar3 erli18n extract` then `rebar3 erli18n compile` commands that
regenerate the compiled catalog so the missing key is defined.
""".
-spec format_diag(diag()) -> binary().
format_diag({Domain, Ctx, Msgid, Sites}) ->
    iolist_to_binary([
        <<"erli18n: msgid ">>,
        quote(Msgid),
        context_suffix(Ctx),
        <<" in domain '">>,
        atom_to_binary(Domain, utf8),
        <<"' is missing from the compiled catalog.\n">>,
        <<"  call sites: ">>,
        join_sites(Sites),
        <<"\n">>,
        <<"  remediation: run 'rebar3 erli18n extract' then ">>,
        <<"'rebar3 erli18n compile' to regenerate the compiled catalog.">>
    ]).

%% =========================
%% Collection
%% =========================

%% Gather every missing-key diagnostic across the domains that appear in BOTH
%% maps. A domain present in `CallSites` but absent from `Universe` is silently
%% skipped — that is the caller's domain scoping.
-spec collect(universe(), call_sites()) -> [diag()].
collect(Universe, CallSites) ->
    maps:fold(
        fun(Domain, Entries, Acc) ->
            case Universe of
                #{Domain := KeySet} -> domain_diags(Domain, Entries, KeySet) ++ Acc;
                #{} -> Acc
            end
        end,
        [],
        CallSites
    ).

%% Every call site in `Entries` whose `{Context, Msgid}` is not in `KeySet`
%% becomes a diagnostic carrying its sorted, de-duplicated call sites.
-spec domain_diags(atom(), [rebar3_erli18n_common:dedup_entry()], sets:set(KeyT)) ->
    [diag()]
when
    KeyT :: {undefined | binary(), binary()}.
domain_diags(Domain, Entries, KeySet) ->
    lists:filtermap(
        fun(#{context := Ctx, msgid := Msgid, references := Refs}) ->
            case sets:is_element({Ctx, Msgid}, KeySet) of
                true -> false;
                false -> {true, {Domain, Ctx, Msgid, lists:usort(Refs)}}
            end
        end,
        Entries
    ).

%% Total order on diagnostics: by domain, then first call site (file then
%% line, since `Sites` is sorted), then context and msgid as tie-breakers.
-spec diag_order(diag(), diag()) -> boolean().
diag_order({D1, C1, M1, S1}, {D2, C2, M2, S2}) ->
    {D1, S1, norm_ctx(C1), M1} =< {D2, S2, norm_ctx(C2), M2}.

-spec norm_ctx(undefined | binary()) -> binary().
norm_ctx(undefined) -> <<>>;
norm_ctx(Ctx) -> Ctx.

%% =========================
%% Rendering helpers
%% =========================

-spec quote(binary()) -> binary().
quote(Bin) ->
    <<"\"", Bin/binary, "\"">>.

-spec context_suffix(undefined | binary()) -> binary().
context_suffix(undefined) ->
    <<>>;
context_suffix(Ctx) ->
    <<" (context \"", Ctx/binary, "\")">>.

-spec join_sites([{file:filename(), pos_integer()}]) -> binary().
join_sites(Sites) ->
    narrow_bin(lists:join(<<", ">>, [format_site(S) || S <- Sites])).

-spec format_site({file:filename(), pos_integer()}) -> binary().
format_site({File, Line}) ->
    narrow_bin([narrow_bin(File), <<":">>, integer_to_binary(Line)]).

%% Narrow `unicode:characters_to_binary/1` to a binary. Source paths and the
%% rendered fragments are valid char data, so the conversion always yields a
%% binary; the assertion narrows the union result and an impossible non-binary
%% crashes explicitly rather than propagating.
-spec narrow_bin(unicode:chardata()) -> binary().
narrow_bin(Chars) ->
    Bin = unicode:characters_to_binary(Chars),
    true = is_binary(Bin),
    Bin.
