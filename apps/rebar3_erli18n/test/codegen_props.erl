%%% =====================================================================
%%% Property-based tests for `rebar3_erli18n_codegen` — the pure
%%% compiled-catalog source emitter.
%%%
%%% `render/2` must be a faithful, total term-to-source lift: for ANY
%%% well-formed `render_spec()` (a `compiled_spec()`-shaped 4-tuple whose
%%% domain is a BINARY), the rendered source must compile and `Mod:catalog()`
%%% must return the equivalent `compiled_spec()` — the input with its binary
%%% domain interned to the matching atom. These properties exercise that
%%% contract over randomly generated catalogs (varied contexts, unicode,
%%% plural arities and ASTs, headers) far beyond the hand-written
%%% `codegen_SUITE` examples.
%%%
%%% Properties:
%%%   * P-ROUNDTRIP — render -> compile -> load -> `catalog/0` returns the
%%%     input `render_spec()` with element 1 atomized, for an arbitrary
%%%     generated binary-domain `render_spec()`.
%%%   * P-MODULE-NAME-STABLE — `module_name/2` is deterministic and injective
%%%     over distinct `{Domain, Locale}` pairs (returning a BINARY name), and
%%%     in particular keeps `pt_BR` and `pt-BR` distinguishable.
%%%   * P-MANGLE-INJECTIVE — the byte mangler underlying `module_name/2` is
%%%     injective: distinct `{Domain, Locale}` pairs never collide onto one
%%%     carrier name. Each non-alphanumeric byte becomes a unique `_<hex>`
%%%     escape and the two mangled segments are joined by the `__` separator a
%%%     mangled segment never contains, so the name determines the pair. This
%%%     exercises the guarantee over diverse pairs, beyond the single `pt_BR`
%%%     vs `pt-BR` case.
%%%
%%% References:
%%%   * Hughes, "QuickCheck", ICFP 2000.
%%%   * PropEr docs — https://hexdocs.pm/proper/
%%% =====================================================================
-module(codegen_props).

-include_lib("proper/include/proper.hrl").

-export([
    prop_render_roundtrips/0,
    prop_module_name_stable_and_injective/0,
    prop_module_name_injective/0
]).

%% Generators
-export([
    compiled_spec/0,
    domain_bin/0,
    locale_bin/0,
    entries/0,
    singular_entry/0,
    plural_entry/0,
    context/0,
    text_bin/0,
    baked_header/0,
    plural_field/0,
    plural_ast/0
]).

%% PropEr `?FORALL`/`?LET` generators are statically typed as `term()` by
%% eqwalizer, so every function that binds a generated value to a documented
%% shape (a `compiled_spec()`, an `entry()`, a plural `ast()`, …) carries a
%% static `-eqwalizer({nowarn_function, F/A}).` annotation — the same
%% zero-runtime-dep pattern used across the runtime modules and
%% `erli18n_interp_props`.
-eqwalizer({nowarn_function, prop_module_name_stable_and_injective/0}).
-eqwalizer({nowarn_function, prop_module_name_injective/0}).
-eqwalizer({nowarn_function, locale_bin/0}).
-eqwalizer({nowarn_function, text_bin/0}).
%% `roundtrips/1` is the property body, not a generator: it compiles and loads
%% rendered source via `compile:forms`/`code:load_binary` (and scans it with
%% `unicode:characters_to_list`), whose results eqwalizer infers as wide union
%% types no static narrowing removes — the same dynamic-module-load boundary the
%% runtime modules annotate.
-eqwalizer({nowarn_function, roundtrips/1}).

%% =========================
%% Properties
%% =========================

%% P-ROUNDTRIP — render -> compile -> load -> catalog() equals the input.
prop_render_roundtrips() ->
    ?FORALL(
        Spec,
        compiled_spec(),
        roundtrips(Spec)
    ).

roundtrips({DomainBin, Locale, Entries, Header} = Spec) ->
    %% `render/2` returns the module name as a BINARY; the carrier's module
    %% ATOM is interned by the compiler and recovered from `compile:forms`'
    %% 3rd element. `catalog/0` returns the spec with its binary domain interned
    %% to the matching atom, so compare against the atomized spec.
    {ModBin, Src} = rebar3_erli18n_codegen:render(Spec, #{}),
    Bin = unicode:characters_to_binary(Src),
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Bin)),
    Forms = split_forms(Tokens),
    Opts = [binary, return_errors, warnings_as_errors, warn_unused_vars],
    case compile:forms(Forms, Opts) of
        {ok, Mod, Beam} ->
            _ = code:purge(Mod),
            {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Beam),
            Got = Mod:catalog(),
            _ = code:purge(Mod),
            _ = code:delete(Mod),
            Expected = {binary_to_atom(DomainBin, utf8), Locale, Entries, Header},
            ModBin =:= atom_to_binary(Mod, utf8) andalso Got =:= Expected;
        _Other ->
            false
    end.

%% P-MODULE-NAME-STABLE — deterministic, BINARY-valued, and `pt_BR` vs `pt-BR`
%% distinct.
prop_module_name_stable_and_injective() ->
    ?FORALL(
        {Domain, Locale},
        {domain_bin(), locale_bin()},
        begin
            A = rebar3_erli18n_codegen:module_name(Domain, Locale),
            B = rebar3_erli18n_codegen:module_name(Domain, Locale),
            UnderscoreName = rebar3_erli18n_codegen:module_name(Domain, ~"pt_BR"),
            DashName = rebar3_erli18n_codegen:module_name(Domain, ~"pt-BR"),
            is_binary(A) andalso A =:= B andalso UnderscoreName =/= DashName
        end
    ).

%% P-MANGLE-INJECTIVE — distinct `{Domain, Locale}` pairs yield distinct module
%% names. `module_name/2` mangles each segment (every alphanumeric byte maps to
%% itself, every other byte to a unique `_<lower-hex>` escape) and joins them
%% with the `__` separator a mangled segment never contains, so the mapping is
%% collision-free — proving the injectivity `module_name/2` documents.
prop_module_name_injective() ->
    ?FORALL(
        {D1, L1, D2, L2},
        {domain_bin(), locale_bin(), domain_bin(), locale_bin()},
        case {D1, L1} =/= {D2, L2} of
            true ->
                rebar3_erli18n_codegen:module_name(D1, L1) =/=
                    rebar3_erli18n_codegen:module_name(D2, L2);
            false ->
                true
        end
    ).

%% =========================
%% Generators
%% =========================

%% A binary-domain `render_spec()` — the shape `render/2` consumes. The
%% domain is a BINARY (never an atom), so the emitter interns no atom from it;
%% the carrier's domain atom is interned by the compiler from the rendered
%% source.
compiled_spec() ->
    ?LET(
        {Domain, Locale, Entries, Header},
        {domain_bin(), locale_bin(), entries(), baked_header()},
        {Domain, Locale, Entries, Header}
    ).

domain_bin() ->
    oneof([~"default", ~"errors", ~"my-app", ~"messages"]).

%% A locale binary biased toward the metacharacters the name mangler must
%% escape (`_`, `-`, `.`, `@`) plus ordinary script bytes.
locale_bin() ->
    ?LET(
        Parts,
        non_empty(list(oneof([~"en", ~"pt", ~"BR", ~"_", ~"-", ~".", ~"@", ~"x"]))),
        iolist_to_binary(Parts)
    ).

entries() ->
    list(oneof([singular_entry(), plural_entry()])).

singular_entry() ->
    ?LET(
        {Ctx, Msgid, Tr},
        {context(), text_bin(), text_bin()},
        {singular, Ctx, Msgid, Tr}
    ).

plural_entry() ->
    ?LET(
        {Ctx, Msgid, Plural, Forms},
        {context(), text_bin(), text_bin(), non_empty(list({non_neg_integer(), text_bin()}))},
        {plural, Ctx, Msgid, Plural, Forms}
    ).

context() ->
    oneof([undefined, text_bin()]).

%% Text bytes biased toward unicode so the abstract-literal round-trip is
%% exercised on multi-byte content, never only ASCII.
text_bin() ->
    ?LET(
        S,
        list(oneof([$a, $z, $%, ${, $}, 16#00E9, 16#0440, 16#1F600])),
        unicode:characters_to_binary(S)
    ).

baked_header() ->
    ?LET(
        {Plural, Divergence, Fuzzy, NumEntries},
        {
            plural_field(),
            oneof([none, {plural_divergence, text_bin(), text_bin()}]),
            boolean(),
            non_neg_integer()
        },
        #{
            plural => Plural,
            plural_raw => ~"nplurals=2; plural=(n != 1);",
            po_path => "priv/locale/x/LC_MESSAGES/default.po",
            divergence => Divergence,
            fuzzy_included => Fuzzy,
            num_entries => NumEntries
        }
    ).

plural_field() ->
    oneof([
        fallback,
        ?LET(
            {N, Ast},
            {range(1, 6), plural_ast()},
            #{nplurals => N, expr => Ast, raw => ~"nplurals=2; plural=(n != 1);"}
        )
    ]).

%% A bounded plural AST: integers, `n`, binops, the negation unop, and
%% ternaries — exactly `erli18n_plural:ast()`.
plural_ast() ->
    ?SIZED(Size, plural_ast(Size)).

plural_ast(0) ->
    oneof([n, range(0, 5)]);
plural_ast(Size) ->
    Smaller = Size div 2,
    oneof([
        n,
        range(0, 5),
        ?LET(
            {Op, L, R},
            {plural_op(), plural_ast(Smaller), plural_ast(Smaller)},
            {binop, Op, L, R}
        ),
        ?LET(A, plural_ast(Smaller), {unop, '!', A}),
        ?LET(
            {C, T, E},
            {plural_ast(Smaller), plural_ast(Smaller), plural_ast(Smaller)},
            {ternary, C, T, E}
        )
    ]).

plural_op() ->
    oneof(['+', '-', '*', '/', '%', '==', '!=', '<', '>', '<=', '>=', '&&', '||']).

%% =========================
%% Helpers
%% =========================

split_forms(Tokens) ->
    split_forms(Tokens, [], []).

split_forms([], _Acc, Forms) ->
    lists:reverse(Forms);
split_forms([{dot, _} = Dot | Rest], Acc, Forms) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([Dot | Acc])),
    split_forms(Rest, [], [Form | Forms]);
split_forms([Tok | Rest], Acc, Forms) ->
    split_forms(Rest, [Tok | Acc], Forms).
