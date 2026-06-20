%%% =====================================================================
%%% Property-based tests for `erli18n` facade lookup — determinism
%%% invariant (property P4).
%%%
%%% Claim (P4): for any fixed `(Domain, Locale, Context, Msgid)`, repeated
%%% calls to `gettext/pgettext/ngettext` return the same value. Lookup is
%%% a pure function of (catalog state, query) — no race conditions, no
%%% wall-clock dependency, no random.
%%%
%%% This property guards against subtle concurrency bugs where the ETS
%%% read in `erli18n_server:lookup_singular/4` could observe a partial
%%% write from a concurrent `ensure_loaded`. We do not exercise
%%% concurrent inserts in this v0.1 property — that would belong in a
%%% `proper_statem` test (the "Concurrent variant") and is documented
%%% as backlog. What we DO cover:
%%% the simpler, foundational invariant — sequential calls are
%%% reproducible.
%%%
%%% Setup: insert a deterministic catalog once, then random-query it
%%% multiple times. Cleanup via `unload/2` between properties so the
%%% test domain does not leak across iterations.
%%%
%%% References:
%%%   * Hughes, "QuickCheck", ICFP 2000.
%%%   * Papadakis et al., PADL 2011 —
%%%     https://proper-testing.github.io/papers/proper_acm.pdf
%%%   * PropEr docs — https://hexdocs.pm/proper/
%%% =====================================================================
-module(erli18n_lookup_props).

-include_lib("proper/include/proper.hrl").

-export([
    prop_singular_lookup_deterministic/0,
    prop_plural_lookup_deterministic/0,
    prop_contextual_lookup_deterministic/0,
    prop_miss_fallback_deterministic/0
]).

-define(TEST_DOMAIN, prop_lookup_dom).
-define(TEST_LOCALE, <<"px">>).

%% =========================
%% Properties
%% =========================

%% Singular: insert a catalog, then call `gettext/3` three times. All
%% three calls must return identical bytes.
prop_singular_lookup_deterministic() ->
    ?FORALL(
        {MsgidGen, TranslationGen},
        {non_empty_msgid(), non_empty_translation()},
        begin
            %% PropEr generators are statically typed as `term()` by
            %% eqwalizer; cast at the property boundary to the documented
            %% generator contracts (`binary()` for both).
            Msgid = eqwalizer:dynamic_cast(MsgidGen),
            Translation = eqwalizer:dynamic_cast(TranslationGen),
            setup_singular_catalog(undefined, Msgid, Translation),
            R1 = erli18n:gettext(?TEST_DOMAIN, Msgid, ?TEST_LOCALE),
            R2 = erli18n:gettext(?TEST_DOMAIN, Msgid, ?TEST_LOCALE),
            R3 = erli18n:gettext(?TEST_DOMAIN, Msgid, ?TEST_LOCALE),
            teardown(),
            (R1 =:= R2) andalso (R2 =:= R3) andalso (R1 =:= Translation)
        end
    ).

%% Plural: insert a catalog with English-style nplurals=2 and check that
%% the form-index selection is deterministic across calls for a fixed N.
prop_plural_lookup_deterministic() ->
    ?FORALL(
        {MsgidGen, SingularTGen, PluralTGen, NGen},
        {non_empty_msgid(), non_empty_translation(), non_empty_translation(), n_for_plural()},
        begin
            %% Generator boundary — see `prop_singular_lookup_deterministic/0`.
            Msgid = eqwalizer:dynamic_cast(MsgidGen),
            SingularT = eqwalizer:dynamic_cast(SingularTGen),
            PluralT = eqwalizer:dynamic_cast(PluralTGen),
            N = eqwalizer:dynamic_cast(NGen),
            setup_plural_catalog(Msgid, SingularT, PluralT),
            R1 = erli18n:ngettext(
                ?TEST_DOMAIN,
                Msgid,
                Msgid,
                N,
                ?TEST_LOCALE
            ),
            R2 = erli18n:ngettext(
                ?TEST_DOMAIN,
                Msgid,
                Msgid,
                N,
                ?TEST_LOCALE
            ),
            R3 = erli18n:ngettext(
                ?TEST_DOMAIN,
                Msgid,
                Msgid,
                N,
                ?TEST_LOCALE
            ),
            teardown(),
            Expected =
                case N of
                    1 -> SingularT;
                    _ -> PluralT
                end,
            (R1 =:= R2) andalso (R2 =:= R3) andalso (R1 =:= Expected)
        end
    ).

%% Contextual: insert with a non-undefined context, then look up with
%% the same context. Repeats must return identical bytes.
prop_contextual_lookup_deterministic() ->
    ?FORALL(
        {CtxGen, MsgidGen, TranslationGen},
        {non_empty_context(), non_empty_msgid(), non_empty_translation()},
        begin
            %% Generator boundary — see `prop_singular_lookup_deterministic/0`.
            Ctx = eqwalizer:dynamic_cast(CtxGen),
            Msgid = eqwalizer:dynamic_cast(MsgidGen),
            Translation = eqwalizer:dynamic_cast(TranslationGen),
            setup_singular_catalog(Ctx, Msgid, Translation),
            R1 = erli18n:pgettext(?TEST_DOMAIN, Ctx, Msgid, ?TEST_LOCALE),
            R2 = erli18n:pgettext(?TEST_DOMAIN, Ctx, Msgid, ?TEST_LOCALE),
            R3 = erli18n:pgettext(?TEST_DOMAIN, Ctx, Msgid, ?TEST_LOCALE),
            teardown(),
            (R1 =:= R2) andalso (R2 =:= R3) andalso (R1 =:= Translation)
        end
    ).

%% Miss fallback: when no catalog is loaded, every call must return the
%% msgid unchanged. Tests rule R1 (BR-MIGRAR-001, PSD-003).
prop_miss_fallback_deterministic() ->
    ?FORALL(
        MsgidGen,
        non_empty_msgid(),
        begin
            %% Generator boundary — see `prop_singular_lookup_deterministic/0`.
            Msgid = eqwalizer:dynamic_cast(MsgidGen),
            %% guarantee no catalog
            teardown(),
            R1 = erli18n:gettext(?TEST_DOMAIN, Msgid, ?TEST_LOCALE),
            R2 = erli18n:gettext(?TEST_DOMAIN, Msgid, ?TEST_LOCALE),
            (R1 =:= R2) andalso (R1 =:= Msgid)
        end
    ).

%% =========================
%% Generators
%% =========================

%% Non-empty UTF-8 msgid, 1..30 codepoints. `proper_unicode:utf8/2`
%% can yield `<<>>` even for N>=1 (N is a max, not a min — see PropEr
%% docs), so we wrap with `?SUCHTHAT` to enforce non-emptiness at the
%% byte level. Empty msgid is reserved for the catalog header per GNU
%% gettext §11.2 ("The Format of PO Files") and our parser treats
%% `msgid ""` as the header marker — leaking it into a lookup would
%% trigger the fallback path and break the deterministic-translation
%% claim of this property.
non_empty_msgid() ->
    ?SUCHTHAT(
        BGen,
        ?LET(
            NGen,
            choose(1, 30),
            proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
        ),
        %% Generator boundary — narrow `BGen` (a `proper_gen:instance()`)
        %% to the documented `binary()` shape so `byte_size/1` type-checks.
        byte_size(eqwalizer:dynamic_cast(BGen)) > 0
    ).

%% Non-empty translation, mirrors msgid shape so the lookup post-cond
%% (`R1 =:= Translation`) can be checked verbatim. Empty translation
%% would activate the R1 fallback (PSD-003) and obscure the property.
non_empty_translation() ->
    ?SUCHTHAT(
        BGen,
        ?LET(
            NGen,
            choose(1, 50),
            proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
        ),
        %% Generator boundary — see `non_empty_msgid/0`.
        byte_size(eqwalizer:dynamic_cast(BGen)) > 0
    ).

%% Non-empty context for `pgettext` testing. Empty context binary `<<>>`
%% is distinct from `undefined` per PSD-006, but we keep the generator
%% simple by forcing a non-empty value — the empty case is well covered
%% by `prop_singular_lookup_deterministic/0` (which passes `undefined`).
non_empty_context() ->
    ?SUCHTHAT(
        BGen,
        ?LET(
            NGen,
            choose(1, 20),
            proper_unicode:utf8(eqwalizer:dynamic_cast(NGen), 2)
        ),
        %% Generator boundary — see `non_empty_msgid/0`.
        byte_size(eqwalizer:dynamic_cast(BGen)) > 0
    ).

%% Plural N: small positives (the common case), but including 0 because
%% French-style `(n > 1)` puts 0 in the singular slot — the deterministic
%% claim must hold regardless of which form is selected.
n_for_plural() ->
    oneof([0, 1, 2, 3, 5, 10, 100]).

%% =========================
%% Setup / teardown
%% =========================
%%
%% The ETS catalog is `protected` and owned by `erli18n_server` — only
%% that process can write. So we set up catalogs by synthesizing a
%% minimal `.po` text, dumping it to a temp file, and invoking the
%% normal `ensure_loaded/3` pipeline. This is also closer to the
%% real-world load path, making the determinism property exercise the
%% same code paths a production caller would.

setup_singular_catalog(Ctx, Msgid, Translation) ->
    ok = ensure_app_started(),
    teardown(),
    Po = synthesize_po([{singular, Ctx, Msgid, Translation}]),
    load_temp_po(Po),
    ok.

setup_plural_catalog(Msgid, SingularT, PluralT) ->
    ok = ensure_app_started(),
    teardown(),
    Po = synthesize_po([
        {plural, undefined, Msgid, <<Msgid/binary, "s">>, [
            {0, SingularT}, {1, PluralT}
        ]}
    ]),
    load_temp_po(Po),
    ok.

%% Serialize a single-entry catalog to PO text via `erli18n_po:dump/1`
%% (the same dumper exercised by P1/P2). Header is fixed at English
%% nplurals=2.
synthesize_po(Entries) ->
    Catalog =
        #{
            header => #{
                plural_forms =>
                    ~"nplurals=2; plural=(n != 1);",
                content_type => ~"text/plain; charset=UTF-8",
                charset => utf8,
                raw =>
                    <<
                        "Content-Type: text/plain; charset=UTF-8\n"
                        "Plural-Forms: nplurals=2; plural=(n != 1);\n"
                    >>
            },
            entries => Entries
        },
    erli18n_po:dump(Catalog).

load_temp_po(PoBin) ->
    Path = temp_po_path(),
    ok = file:write_file(Path, PoBin),
    case erli18n:ensure_loaded(?TEST_DOMAIN, ?TEST_LOCALE, Path) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            file:delete(Path),
            error({load_failed, Reason})
    end,
    %% Delete the temp file eagerly — the parsed catalog already lives
    %% in ETS and the path is only needed for the load step.
    file:delete(Path),
    ok.

temp_po_path() ->
    Dir = filename:join("/tmp", "erli18n_lookup_props"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Unique = erlang:unique_integer([positive, monotonic]),
    filename:join(Dir, "lookup_prop_" ++ integer_to_list(Unique) ++ ".po").

teardown() ->
    case whereis(erli18n_server) of
        undefined -> ok;
        _Pid -> erli18n:unload(?TEST_DOMAIN, ?TEST_LOCALE)
    end.

%% Idempotent app boot — covers the case where the property is
%% invoked from a process that has not yet started the application.
ensure_app_started() ->
    case application:ensure_all_started(erli18n) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, _} = Err -> error(Err)
    end.
