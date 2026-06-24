-module(rebar3_erli18n_prv_merge).

-moduledoc """
`rebar3 erli18n merge` — msgmerge-style sync of a `.po` against the fresh
`.pot`.

For each `{Domain, Locale}` it parses the existing `.po` (via
`erli18n_po:parse`) for the translations and serializes the merged result
through `rebar3_erli18n_po_meta`, applying the lifecycle the plain
parse/dump round-trip cannot:

- a `.pot` msgid present in the old `.po` keeps its translation and gains
  the fresh `#:` references;
- a `.pot` msgid ABSENT from the old `.po` is added as an untranslated
  entry, fuzzy-matched (`rebar3_erli18n_jaro`) against the removed msgids so
  a renamed string carries its old translation as `#, fuzzy` with a `#|`
  previous-msgid hint;
- an old msgid no longer in the `.pot` (and not consumed as a fuzzy source)
  is demoted to a `#~` obsolete entry rather than deleted;
- msgid equality is wrapping-insensitive (`--no-wrap` / line-wrapped msgids
  compare equal), because both sides are decoded binaries.
""".

%% This module implements the rebar3 `provider` contract (`init/1`, `do/1`,
%% `format_error/1`); it is registered via `providers:create([{module, ?MODULE}, ...])`
%% in `init/1`. The `-behaviour(provider)` attribute is intentionally omitted:
%% the `provider` behaviour ships inside the rebar3 escript (stripped of
%% debug_info and not on Hex), so neither dialyzer nor eqwalizer can load its
%% callback info standalone — the attribute would only yield false
%% "behaviour/callback not available" diagnostics for a contract the exports
%% already satisfy.

-export([init/1, do/1, format_error/1]).

%% `previous_of/1` is exported for white-box testing only (build-tool
%% internal, not a published Hex API). See its `-doc` for the full rationale.
-export([previous_of/1]).

-define(PROVIDER, merge).
-define(NAMESPACE, erli18n).
-define(DEPS, [{default, compile}]).

-doc "Register the `merge` provider under the `erli18n` namespace.".
-spec init(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()}.
init(State) ->
    Provider = rebar3_erli18n_host:create_provider([
        {name, ?PROVIDER},
        {namespace, ?NAMESPACE},
        {module, ?MODULE},
        {bare, true},
        {deps, ?DEPS},
        {example, "rebar3 erli18n merge --locale pt_BR"},
        {opts, rebar3_erli18n_common:common_opts()},
        {short_desc, "Sync .po catalogs against the freshly extracted .pot (msgmerge-style)."},
        {desc,
            "Re-extract the .pot, then for each target .po keep existing translations for "
            "still-present msgids, add new msgids (fuzzy-matched against removed ones), demote "
            "removed msgids to #~ obsolete, and preserve #: references. Reuses erli18n_po:parse "
            "for the body and rebar3_erli18n_po_meta for the metadata."}
    ]),
    {ok, rebar3_erli18n_host:add_provider(State, Provider)}.

-doc "Run the merge for the selected `{Domain, Locale}` catalogs.".
-spec do(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()} | {error, string()}.
do(State) ->
    case rebar3_erli18n_common:extract_project(State) of
        {ok, ByDomain} ->
            case targets(State) of
                {ok, Locale} ->
                    Result = merge_all(State, ByDomain, Locale),
                    handle(State, Result);
                {error, Reason} ->
                    {error, format_error(Reason)}
            end;
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

-doc "Render a provider error to a human string.".
-spec format_error(term()) -> string().
format_error(Reason) ->
    rebar3_erli18n_common:format_error(Reason).

%% =========================
%% Target selection
%% =========================

-spec targets(rebar3_erli18n_host:state()) -> {ok, string()} | {error, term()}.
targets(State) ->
    Args = rebar3_erli18n_host:parsed_args(State),
    case proplists:get_value(locale, Args) of
        undefined -> {error, locale_required};
        Locale -> {ok, Locale}
    end.

-spec handle(rebar3_erli18n_host:state(), ok | {error, term()}) ->
    {ok, rebar3_erli18n_host:state()} | {error, string()}.
handle(State, ok) -> {ok, State};
handle(_State, {error, Reason}) -> {error, format_error(Reason)}.

%% =========================
%% Merge
%% =========================

-spec merge_all(rebar3_erli18n_host:state(), #{atom() => [Entry]}, string()) ->
    ok | {error, term()}
when
    Entry :: rebar3_erli18n_common:dedup_entry().
merge_all(State, ByDomain, Locale) ->
    maps:fold(
        fun
            (Domain, Entries, ok) -> merge_one(State, Domain, Entries, Locale);
            (_Domain, _Entries, {error, _} = Err) -> Err
        end,
        ok,
        ByDomain
    ).

-spec merge_one(rebar3_erli18n_host:state(), atom(), [Entry], string()) ->
    ok | {error, term()}
when
    Entry :: rebar3_erli18n_common:dedup_entry().
merge_one(State, Domain, PotEntries, Locale) ->
    Path = rebar3_erli18n_common:po_path(State, Domain, Locale),
    case read_old(Path) of
        {ok, OldHeader, OldEntries} ->
            Merged = merge_entries(PotEntries, OldEntries),
            Catalog = #{header => OldHeader, entries => Merged},
            ok = filelib:ensure_dir(Path),
            ok = file:write_file(Path, rebar3_erli18n_po_meta:dump(Catalog)),
            rebar3_erli18n_host:info("erli18n: merged ~ts", [Path]),
            ok;
        {error, Reason} ->
            {error, {po_parse_failed, Path, Reason}}
    end.

%% Read an existing `.po`. A missing file means a brand-new locale: treat it
%% as an empty catalog with a UTF-8 header so the merge produces the initial
%% translated template.
-spec read_old(file:filename()) ->
    {ok, binary(), [erli18n_po:entry()]} | {error, term()}.
read_old(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case erli18n_po:parse(Bin) of
                %% `erli18n_po:parse/1` always populates the header `raw`
                %% field (a synthetic header is supplied when the `.po` has
                %% none), so we match it directly — no missing-key fallback.
                {ok, #{header := #{raw := Raw}, entries := Entries}} ->
                    {ok, Raw, Entries};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, enoent} ->
            {ok, default_header(), []};
        {error, Reason} ->
            {error, Reason}
    end.

-spec default_header() -> binary().
default_header() ->
    ~"Content-Type: text/plain; charset=UTF-8\n".

%% Core merge, in three passes:
%%   1. Exact carry-over: a fresh `.pot` msgid present in the old catalog
%%      keeps its translation and refreshes its `#:` references.
%%   2. Fuzzy carry-over: a fresh msgid ABSENT from the old catalog is
%%      paired (jaro >= 0.8) with a removed old msgid; the new entry takes
%%      the old translation, is flagged `#, fuzzy`, and records the old
%%      msgid as a `#|` previous-msgid hint. The matched old key is consumed.
%%   3. Obsolete: any old entry whose key was neither carried over nor
%%      consumed as a fuzzy source is demoted to a `#~` obsolete entry.
-spec merge_entries([Entry], [erli18n_po:entry()]) ->
    [rebar3_erli18n_po_meta:meta_entry()]
when
    Entry :: rebar3_erli18n_common:dedup_entry().
merge_entries(PotEntries, OldEntries) ->
    OldIndex = index_old(OldEntries),
    %% Split fresh entries into exact-matched and new (no exact old entry).
    {Exact, New} = lists:partition(
        fun(#{context := Ctx, msgid := Msgid}) -> maps:is_key({Ctx, Msgid}, OldIndex) end,
        PotEntries
    ),
    ExactKeys = #{{Ctx, Msgid} => true || #{context := Ctx, msgid := Msgid} <- Exact},
    %% Removed = old keys not exactly carried over; candidates for fuzzy.
    Removed = [E || E <- OldEntries, not maps:is_key(old_key(E), ExactKeys)],
    {NewMeta, FuzzyUsed} = fuzzy_merge(New, Removed),
    ExactMeta = [exact_meta(PotE, OldIndex) || PotE <- Exact],
    Consumed = maps:merge(ExactKeys, FuzzyUsed),
    Obsolete = obsolete_entries(OldEntries, Consumed),
    ExactMeta ++ NewMeta ++ Obsolete.

%% Index old entries by {Context, Msgid} for O(1) carry-over lookup.
-spec index_old([erli18n_po:entry()]) -> #{{undefined | binary(), binary()} => erli18n_po:entry()}.
index_old(Entries) ->
    lists:foldl(
        fun(E, Acc) -> Acc#{old_key(E) => E} end,
        #{},
        Entries
    ).

-spec old_key(erli18n_po:entry()) -> {undefined | binary(), binary()}.
old_key({singular, Ctx, Msgid, _}) -> {Ctx, Msgid};
old_key({plural, Ctx, Msgid, _, _}) -> {Ctx, Msgid}.

%% Build the meta-entry for an exact-matched fresh entry: old translation,
%% fresh references, no fuzzy flag.
-spec exact_meta(Entry, OldIndex) -> rebar3_erli18n_po_meta:meta_entry() when
    Entry :: rebar3_erli18n_common:dedup_entry(),
    OldIndex :: #{{undefined | binary(), binary()} => erli18n_po:entry()}.
exact_meta(#{context := Ctx, msgid := Msgid, references := Refs} = PotE, OldIndex) ->
    OldEntry = maps:get({Ctx, Msgid}, OldIndex),
    #{body => body_with_translation(PotE, OldEntry), references => Refs}.

%% Pair each new fresh msgid with the best removed old msgid (jaro >= 0.8).
%% A successful pairing consumes the old key (so it is not also obsoleted)
%% and yields a `#, fuzzy` entry carrying the old translation plus a `#|`
%% previous-msgid hint. New msgids with no fuzzy source stay untranslated.
-spec fuzzy_merge([Entry], [erli18n_po:entry()]) ->
    {[rebar3_erli18n_po_meta:meta_entry()], #{{undefined | binary(), binary()} => true}}
when
    Entry :: rebar3_erli18n_common:dedup_entry().
fuzzy_merge(New, Removed) ->
    {MetaRev, Used, _Left} = lists:foldl(
        fun(NewE, {AccMeta, AccUsed, Candidates}) ->
            {MetaE, Consumed, Rest} = fuzzy_one(NewE, Candidates),
            {[MetaE | AccMeta], add_used(Consumed, AccUsed), Rest}
        end,
        {[], #{}, Removed},
        New
    ),
    {lists:reverse(MetaRev), Used}.

%% Fuzzy-match one new entry against the remaining removed candidates.
-spec fuzzy_one(Entry, [erli18n_po:entry()]) ->
    {rebar3_erli18n_po_meta:meta_entry(), none | {undefined | binary(), binary()}, [
        erli18n_po:entry()
    ]}
when
    Entry :: rebar3_erli18n_common:dedup_entry().
fuzzy_one(#{msgid := Msgid, references := Refs} = NewE, Candidates) ->
    CandMsgids = [old_msgid(C) || C <- Candidates],
    case rebar3_erli18n_jaro:best_match(Msgid, CandMsgids) of
        nomatch ->
            {#{body => empty_body(NewE), references => Refs}, none, Candidates};
        {ok, MatchMsgid, _Score} ->
            {Match, Rest} = take_by_msgid(MatchMsgid, Candidates),
            Meta = fuzzy_meta(NewE, Match, Refs),
            {Meta, old_key(Match), Rest}
    end.

-spec old_msgid(erli18n_po:entry()) -> binary().
old_msgid({singular, _, Msgid, _}) -> Msgid;
old_msgid({plural, _, Msgid, _, _}) -> Msgid.

%% Remove the first candidate whose msgid matches, returning it and the rest.
-spec take_by_msgid(binary(), [erli18n_po:entry()]) ->
    {erli18n_po:entry(), [erli18n_po:entry()]}.
take_by_msgid(Msgid, Candidates) ->
    take_by_msgid(Msgid, Candidates, []).

-spec take_by_msgid(binary(), [erli18n_po:entry()], [erli18n_po:entry()]) ->
    {erli18n_po:entry(), [erli18n_po:entry()]}.
take_by_msgid(Msgid, [C | Rest], Acc) ->
    case old_msgid(C) =:= Msgid of
        true -> {C, lists:reverse(Acc, Rest)};
        false -> take_by_msgid(Msgid, Rest, [C | Acc])
    end.

%% Build the `#, fuzzy` meta-entry: fresh shape, old translation, prev-msgid.
-spec fuzzy_meta(Entry, erli18n_po:entry(), [{file:filename(), pos_integer()}]) ->
    rebar3_erli18n_po_meta:meta_entry()
when
    Entry :: rebar3_erli18n_common:dedup_entry().
fuzzy_meta(NewE, Match, Refs) ->
    Body = transplant_translation(NewE, Match),
    #{
        body => Body,
        references => Refs,
        flags => [fuzzy],
        previous => previous_of(Match)
    }.

%% Carry the old translation onto the new shape regardless of singular/plural
%% mismatch: a singular->singular keeps the string; any cross-shape pairing
%% keeps the new shape but reuses what translation bytes exist.
-spec transplant_translation(Entry, erli18n_po:entry()) -> rebar3_erli18n_po_meta:body() when
    Entry :: rebar3_erli18n_common:dedup_entry().
transplant_translation(#{kind := singular, context := Ctx, msgid := Msgid}, {singular, _, _, Tr}) ->
    {singular, Ctx, Msgid, Tr};
transplant_translation(
    #{kind := plural, context := Ctx, msgid := Msgid, plural := Plural},
    {plural, _, _, _, Forms}
) ->
    {plural, Ctx, Msgid, Plural, Forms};
transplant_translation(NewE, _Mismatched) ->
    empty_body(NewE).

-doc """
Build the `#|` previous-msgid hint for a fuzzy match: the old
context+msgid, plus the old msgid_plural when the matched entry carried one.

This is a build-tool internal, exported only so the CT suite can white-box
every clause; it is not part of any published (Hex) API surface.

`erli18n_po:entry()` types a plural's `msgid_plural` as `undefined |
binary()`, so the clause head below must cover `undefined` for the match to
be total over the imported type (dialyzer/eqwalizer exhaustiveness). In
practice `erli18n_po:parse/1` never yields a plural with an undefined
msgid_plural — a degenerate `msgstr[N]`-without-`msgid_plural` block is
parsed as a SINGULAR entry — so the `undefined` clause is type-mandated, not
behaviourally reachable through the merge's parse-driven inputs.
""".
-spec previous_of(erli18n_po:entry()) ->
    {undefined | binary(), binary()} | {undefined | binary(), binary(), binary()}.
previous_of({singular, Ctx, Msgid, _}) -> {Ctx, Msgid};
previous_of({plural, Ctx, Msgid, undefined, _}) -> {Ctx, Msgid};
previous_of({plural, Ctx, Msgid, MsgidPlural, _}) -> {Ctx, Msgid, MsgidPlural}.

-spec add_used(none | {undefined | binary(), binary()}, Used) -> Used when
    Used :: #{{undefined | binary(), binary()} => true}.
add_used(none, Used) -> Used;
add_used(Key, Used) -> Used#{Key => true}.

%% Build a translated body by transplanting the old translation onto the
%% fresh `.pot` shape (which carries the authoritative msgid/plural).
-spec body_with_translation(Entry, erli18n_po:entry()) -> rebar3_erli18n_po_meta:body() when
    Entry :: rebar3_erli18n_common:dedup_entry().
body_with_translation(#{kind := singular, context := Ctx, msgid := Msgid}, {singular, _, _, Tr}) ->
    {singular, Ctx, Msgid, Tr};
body_with_translation(
    #{kind := plural, context := Ctx, msgid := Msgid, plural := Plural},
    {plural, _, _, _, Forms}
) ->
    {plural, Ctx, Msgid, Plural, Forms};
body_with_translation(PotE, _Mismatched) ->
    %% Shape changed singular<->plural between old and new: drop the stale
    %% translation, keep the fresh shape untranslated.
    empty_body(PotE).

-spec empty_body(Entry) -> rebar3_erli18n_po_meta:body() when
    Entry :: rebar3_erli18n_common:dedup_entry().
empty_body(#{kind := singular, context := Ctx, msgid := Msgid}) ->
    {singular, Ctx, Msgid, <<>>};
empty_body(#{kind := plural, context := Ctx, msgid := Msgid, plural := Plural}) ->
    {plural, Ctx, Msgid, Plural, [{0, <<>>}, {1, <<>>}]}.

%% Demote every old entry whose key was not carried over into a `#~`
%% obsolete meta-entry, preserving its translation bytes.
-spec obsolete_entries([erli18n_po:entry()], Used) -> [rebar3_erli18n_po_meta:meta_entry()] when
    Used :: #{{undefined | binary(), binary()} => true}.
obsolete_entries(OldEntries, Used) ->
    [
        #{body => E, obsolete => true}
     || E <- OldEntries, not maps:is_key(old_key(E), Used)
    ].
