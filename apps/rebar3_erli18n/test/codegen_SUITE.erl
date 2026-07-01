-module(codegen_SUITE).

-moduledoc """
Tests for `rebar3_erli18n_codegen` — the pure compiled-catalog source emitter.

The central obligation is a ROUND-TRIP: for a `compiled_spec()`, the rendered
source must compile (under the project's `warnings_as_errors` `erl_opts`) and
`Mod:catalog()` must return a term EQUAL to the input spec, across every
catalog shape — `undefined` and binary contexts, unicode binaries, multi-form
plurals, a `{binop, '>', n, 1}` rule, a nested ternary rule, the `fallback`
header, a `{plural_divergence, _, _}` divergence, `fuzzy_included` true/false,
and an empty entry list. The suite also pins the emitted scaffolding (banner,
marker attribute, precise `-spec`, and the conditional eqwalizer nowarn) and
proves the committed proof fixture cannot drift from a fresh `render/2`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    roundtrip_singular_undefined_ctx/1,
    roundtrip_singular_binary_ctx/1,
    roundtrip_unicode_binaries/1,
    roundtrip_multi_form_plural/1,
    roundtrip_binop_rule/1,
    roundtrip_ternary_rule/1,
    roundtrip_fallback_header/1,
    roundtrip_divergence/1,
    roundtrip_fuzzy_included/1,
    roundtrip_empty_entries/1,
    banner_present/1,
    marker_present/1,
    precise_spec_present/1,
    default_emits_eqwalizer_nowarn/1,
    eqwalizer_false_omits_nowarn/1,
    eqwalizer_absent_defaults_to_nowarn/1,
    module_name_distinguishes_separators/1,
    mangle_at_long_name_boundary/1,
    generator_vsn_is_binary/1,
    proof_fixture_does_not_drift/1,
    quote_atom_source_default/1,
    quote_atom_source_reserved_words/1,
    quote_atom_source_metachars/1,
    quote_atom_source_embedded_escapes/1,
    quote_atom_source_unicode/1,
    quote_atom_source_empty/1,
    quote_atom_source_control_del/1,
    quote_atom_source_non_utf8_raises/1,
    quote_atom_source_pure_ascii/1,
    quote_atom_source_identity/1,
    quoting_roundtrips_edge_domains/1,
    sentinels_render_isolated/1,
    prop_render_roundtrips/1,
    prop_module_name_stable_and_injective/1,
    prop_module_name_injective/1
]).

%% Number of QuickCheck runs per property — the repo's release-blocking floor.
-define(NUMTESTS, 200).

%% `compile_source/1` is the dynamic-module load helper: `compile:forms`/
%% `code:load_binary` and `unicode:characters_to_list` return wide union types
%% eqwalizer cannot statically narrow, so quarantine it with a static
%% annotation — the same zero-runtime-dep pattern used in the runtime modules
%% `erli18n_server`/`erli18n_pt_store`. (A wild attribute must precede the first
%% function definition, so it lives here rather than beside the helper.)
-eqwalizer({nowarn_function, compile_source/1}).

all() ->
    [
        roundtrip_singular_undefined_ctx,
        roundtrip_singular_binary_ctx,
        roundtrip_unicode_binaries,
        roundtrip_multi_form_plural,
        roundtrip_binop_rule,
        roundtrip_ternary_rule,
        roundtrip_fallback_header,
        roundtrip_divergence,
        roundtrip_fuzzy_included,
        roundtrip_empty_entries,
        banner_present,
        marker_present,
        precise_spec_present,
        default_emits_eqwalizer_nowarn,
        eqwalizer_false_omits_nowarn,
        eqwalizer_absent_defaults_to_nowarn,
        module_name_distinguishes_separators,
        mangle_at_long_name_boundary,
        generator_vsn_is_binary,
        proof_fixture_does_not_drift,
        quote_atom_source_default,
        quote_atom_source_reserved_words,
        quote_atom_source_metachars,
        quote_atom_source_embedded_escapes,
        quote_atom_source_unicode,
        quote_atom_source_empty,
        quote_atom_source_control_del,
        quote_atom_source_non_utf8_raises,
        quote_atom_source_pure_ascii,
        quote_atom_source_identity,
        quoting_roundtrips_edge_domains,
        sentinels_render_isolated,
        prop_render_roundtrips,
        prop_module_name_stable_and_injective,
        prop_module_name_injective
    ].

%% =========================
%% PropEr property runners (drive `codegen_props`)
%% =========================

%% The `codegen_props` module holds the PropEr properties and generators
%% (kept separate so the generators carry their own `-eqwalizer` nowarn
%% annotations); these two cases drive them through `proper:quickcheck/2`,
%% mirroring `erli18n_property_SUITE`.
prop_render_roundtrips(_Config) ->
    run_property(codegen_props:prop_render_roundtrips()).

prop_module_name_stable_and_injective(_Config) ->
    run_property(codegen_props:prop_module_name_stable_and_injective()).

prop_module_name_injective(_Config) ->
    run_property(codegen_props:prop_module_name_injective()).

%% Bridge PropEr's boolean API to CT's exception-based pass/fail, surfacing a
%% minimized counter-example to the CT log via `{to_file, user}`.
run_property(Property) ->
    Result = proper:quickcheck(
        Property,
        [{numtests, ?NUMTESTS}, {to_file, user}]
    ),
    ?assert(Result =:= true).

%% =========================
%% Round-trip cases
%% =========================

%% A `undefined`-context singular entry round-trips through render -> compile
%% -> load -> catalog().
roundtrip_singular_undefined_ctx(_Config) ->
    Spec = spec([{singular, undefined, ~"Hello", ~"Olá"}], fallback_header()),
    assert_roundtrip(Spec).

%% A binary `msgctxt` (key partitioning) round-trips intact.
roundtrip_singular_binary_ctx(_Config) ->
    Spec = spec(
        [{singular, ~"menu", ~"File", ~"Arquivo"}],
        fallback_header()
    ),
    assert_roundtrip(Spec).

%% Non-ASCII msgid AND msgstr bytes survive the abstract-literal round-trip
%% byte-for-byte (the emitter must not lossily re-encode them).
roundtrip_unicode_binaries(_Config) ->
    Spec = spec(
        [
            {singular, ~"ключ", ~"Привет", ~"Здравствуйте"},
            {singular, undefined, ~"café", ~"café au lait"}
        ],
        fallback_header()
    ),
    assert_roundtrip(Spec).

%% A 3-form plural entry round-trips, including the per-form index tuples.
roundtrip_multi_form_plural(_Config) ->
    Spec = spec(
        [
            {plural, undefined, ~"tree", ~"trees", [
                {0, ~"drzewo"}, {1, ~"drzewa"}, {2, ~"drzew"}
            ]}
        ],
        compiled_header(3, {ternary, {binop, '==', n, 1}, 0, 2})
    ),
    assert_roundtrip(Spec).

%% A `{binop, '>', n, 1}` plural AST is baked as a literal and round-trips.
roundtrip_binop_rule(_Config) ->
    Spec = spec(
        [{plural, undefined, ~"tree", ~"trees", [{0, ~"árvore"}, {1, ~"árvores"}]}],
        compiled_header(2, {binop, '>', n, 1})
    ),
    assert_roundtrip(Spec).

%% A nested ternary plural AST round-trips structurally.
roundtrip_ternary_rule(_Config) ->
    Ast = {ternary, {binop, '==', n, 1}, 0, {ternary, {binop, '==', n, 2}, 1, 2}},
    Spec = spec(
        [{plural, ~"ctx", ~"item", ~"items", [{0, ~"x"}, {1, ~"y"}, {2, ~"z"}]}],
        compiled_header(3, Ast)
    ),
    assert_roundtrip(Spec).

%% The `fallback` plural header (no Plural-Forms in the source .po) round-trips.
roundtrip_fallback_header(_Config) ->
    Spec = spec([{singular, undefined, ~"a", ~"A"}], fallback_header()),
    ?assertEqual(fallback, maps:get(plural, element(4, Spec))),
    assert_roundtrip(Spec).

%% A `{plural_divergence, _, _}` divergence value round-trips inside the header.
roundtrip_divergence(_Config) ->
    Header0 = compiled_header(2, {binop, '!=', n, 1}),
    Header = Header0#{divergence => {plural_divergence, ~"n != 1", ~"n > 1"}},
    Spec = spec([{singular, undefined, ~"a", ~"A"}], Header),
    assert_roundtrip(Spec).

%% `fuzzy_included => true` round-trips (the boolean is baked verbatim).
roundtrip_fuzzy_included(_Config) ->
    Header = (fallback_header())#{fuzzy_included => true},
    Spec = spec([{singular, undefined, ~"a", ~"A"}], Header),
    ?assertEqual(true, maps:get(fuzzy_included, element(4, Spec))),
    assert_roundtrip(Spec).

%% An empty entry list (header-only catalog) round-trips.
roundtrip_empty_entries(_Config) ->
    Header = (fallback_header())#{num_entries => 0},
    Spec = spec([], Header),
    assert_roundtrip(Spec).

%% =========================
%% Scaffolding assertions
%% =========================

banner_present(_Config) ->
    Src = render_bin(spec([{singular, undefined, ~"a", ~"A"}], fallback_header()), #{}),
    ?assert(contains(Src, ~"@generated")),
    ?assert(contains(Src, ~"DO NOT EDIT")).

marker_present(_Config) ->
    Spec = spec([{singular, undefined, ~"a", ~"A"}], fallback_header()),
    Src = render_bin(Spec, #{}),
    ?assert(contains(Src, ~"-erli18n_compiled_catalog(")),
    ?assert(contains(Src, ~"generator_vsn")),
    %% After the post-render sentinel-replace the marker carries the QUOTED
    %% domain atom (from `quote_atom_source/1`), and the `catalog/0` body opens
    %% with that same quoted domain.
    ?assert(contains(Src, ~"{domain, 'default'}")),
    ?assert(contains(Src, ~"{'default',")).

precise_spec_present(_Config) ->
    Spec = spec([{singular, undefined, ~"a", ~"A"}], fallback_header()),
    Src = render_bin(Spec, #{}),
    ?assert(
        contains(Src, ~"-spec catalog() -> erli18n_server:compiled_spec().")
    ).

default_emits_eqwalizer_nowarn(_Config) ->
    Spec = spec([{singular, undefined, ~"a", ~"A"}], fallback_header()),
    Src = render_bin(Spec, #{eqwalizer_nowarn => true}),
    ?assert(contains(Src, ~"-eqwalizer({nowarn_function, {catalog, 0}})")),
    %% The precise spec is retained ALONGSIDE the nowarn, never replaced by it.
    ?assert(
        contains(Src, ~"-spec catalog() -> erli18n_server:compiled_spec().")
    ).

eqwalizer_false_omits_nowarn(_Config) ->
    Spec = spec([{singular, undefined, ~"a", ~"A"}], fallback_header()),
    Src = render_bin(Spec, #{eqwalizer_nowarn => false}),
    ?assertNot(contains(Src, ~"nowarn_function")),
    %% The precise spec is still emitted even with the nowarn suppressed.
    ?assert(
        contains(Src, ~"-spec catalog() -> erli18n_server:compiled_spec().")
    ).

eqwalizer_absent_defaults_to_nowarn(_Config) ->
    Spec = spec([{singular, undefined, ~"a", ~"A"}], fallback_header()),
    %% An empty opts map (key absent) must behave exactly like `=> true`.
    Src = render_bin(Spec, #{}),
    ?assert(contains(Src, ~"-eqwalizer({nowarn_function, {catalog, 0}})")).

module_name_distinguishes_separators(_Config) ->
    %% `module_name/2` now takes a BINARY domain and returns a BINARY name (no
    %% atom is interned here).
    PtBr = rebar3_erli18n_codegen:module_name(~"default", ~"pt_BR"),
    PtDashBr = rebar3_erli18n_codegen:module_name(~"default", ~"pt-BR"),
    ?assert(is_binary(PtBr)),
    ?assert(is_binary(PtDashBr)),
    ?assertNotEqual(PtBr, PtDashBr),
    %% Stable, deterministic mangling.
    ?assertEqual(PtBr, rebar3_erli18n_codegen:module_name(~"default", ~"pt_BR")),
    %% Domain is sanitised too: a non-alphanumeric byte is hex-escaped.
    Hyphenated = rebar3_erli18n_codegen:module_name(~"my-app", ~"en"),
    ?assertEqual(~"erli18n_cc_my_2dapp__en", Hyphenated).

%% A long domain and an all-escaped locale still mangle to a valid, compilable
%% module name, and the carrier round-trips. Each non-alphanumeric byte expands
%% to a three-char `_<hex>` escape, so the cases are sized so the interned
%% module atom stays under Erlang's 255-byte atom limit — the render -> compile
%% -> load -> `catalog/0` path is the real oracle that the long name is valid.
mangle_at_long_name_boundary(_Config) ->
    Entries = [{singular, undefined, ~"a", ~"A"}],
    Header = fallback_header(),
    Cases = [
        %% Long ASCII domain (bytes preserved) + all-`_` locale (each byte a
        %% `_5f` escape): module atom is ~248 bytes, just under the 255 limit.
        {binary:copy(~"x", 100), binary:copy(~"_", 45)},
        %% Long all-escaped domain (every `-` byte becomes `_2d`) + short locale.
        {binary:copy(~"-", 70), ~"en"},
        %% Long multibyte-unicode locale: each UTF-8 byte of `é` is escaped.
        {~"default", binary:copy(~"é", 30)}
    ],
    lists:foreach(
        fun({Domain, Locale}) ->
            Spec = {Domain, Locale, Entries, Header},
            {ModBin, Src} = rebar3_erli18n_codegen:render(Spec, #{}),
            ?assert(is_binary(ModBin)),
            {Mod, Beam} = compile_source(Src),
            ?assertEqual(ModBin, atom_to_binary(Mod, utf8)),
            _ = code:purge(Mod),
            {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Beam),
            try
                %% `catalog/0` recovers the spec with its binary domain interned
                %% to the matching atom (by the compiler, from the emitted source).
                Expected = {binary_to_atom(Domain, utf8), Locale, Entries, Header},
                ?assertEqual(Expected, Mod:catalog())
            after
                _ = code:purge(Mod),
                _ = code:delete(Mod)
            end
        end,
        Cases
    ).

generator_vsn_is_binary(_Config) ->
    ?assert(is_binary(rebar3_erli18n_codegen:generator_vsn())).

%% =========================
%% Atom-source quoting (quote_atom_source/1, escape_cp/1, sentinels)
%% =========================

%% The canonical case: a plain alphanumeric domain is ALWAYS single-quoted and
%% otherwise byte-identical — `default` renders to the nine chars `'default'`.
quote_atom_source_default(_Config) ->
    ?assertEqual(~"'default'", qbin(~"default")).

%% Erlang reserved words MUST be single-quoted to scan back to an atom (an
%% unquoted `if`/`end` is a keyword, not an atom). Quoting is unconditional, so
%% each one round-trips to the exact reserved-word atom.
quote_atom_source_reserved_words(_Config) ->
    ?assertEqual(~"'if'", qbin(~"if")),
    ?assertEqual(~"'receive'", qbin(~"receive")),
    ?assertEqual(~"'catch'", qbin(~"catch")),
    ?assertEqual(~"'end'", qbin(~"end")).

%% Atom metacharacters (`-`, space, `.`) are printable ASCII that are NOT the
%% quote or backslash, so they stay literal inside the surrounding quotes.
quote_atom_source_metachars(_Config) ->
    ?assertEqual(~"'my-app'", qbin(~"my-app")),
    ?assertEqual(~"'a b'", qbin(~"a b")),
    ?assertEqual(~"'a.b'", qbin(~"a.b")).

%% An embedded single quote and an embedded backslash are each backslash-escaped
%% so the rendered token scans back to an atom containing that literal byte.
quote_atom_source_embedded_escapes(_Config) ->
    ?assertEqual(<<$', $a, $\\, $', $b, $'>>, qbin(~"a'b")),
    ?assertEqual(<<$', $a, $\\, $\\, $b, $'>>, qbin(~"a\\b")).

%% Non-ASCII codepoints are emitted as uniform lowercase `\x{...}` brace escapes
%% (one per codepoint), never as raw UTF-8 bytes.
quote_atom_source_unicode(_Config) ->
    ?assertEqual(~"'caf\\x{e9}'", qbin(~"café")),
    ?assertEqual(~"'\\x{43a}\\x{43b}\\x{44e}\\x{447}'", qbin(~"ключ")).

%% The empty binary renders to the empty-atom token `''` (two quotes, nothing
%% between), which scans back to the empty atom.
quote_atom_source_empty(_Config) ->
    ?assertEqual(~"''", qbin(~"")),
    ?assertEqual('', scan_atom(qbin(~""))).

%% Control bytes and DEL are non-printable, so they are escaped via `\x{...}`
%% (lowercase hex, no zero padding): NUL -> `\x{0}`, TAB -> `\x{9}`,
%% DEL -> `\x{7f}`.
quote_atom_source_control_del(_Config) ->
    ?assertEqual(~"'\\x{0}\\x{9}\\x{7f}'", qbin(<<0, 9, 127>>)),
    ?assertEqual(~"'\\x{a}'", qbin(<<"\n">>)).

%% A non-UTF-8 binary is a LOUD failure — `quote_atom_source/1` never silently
%% mangles undecodable input.
quote_atom_source_non_utf8_raises(_Config) ->
    ?assertError(
        {invalid_domain_encoding, _},
        rebar3_erli18n_codegen:quote_atom_source(<<16#FF, 16#FF>>)
    ).

%% Every rendered token is pure 7-bit ASCII (no byte >= 128), even for inputs
%% that contain wide codepoints — the whole point of the `\x{...}` escaping.
quote_atom_source_pure_ascii(_Config) ->
    [
        ?assert(is_pure_ascii(qbin(B)))
     || B <- identity_corpus()
    ].

%% IDENTITY: for every corpus input, feeding the rendered token through
%% `erl_scan:string` scans to the EXACT atom that `binary_to_atom(B, utf8)`
%% would produce — the quoting is lossless and unambiguous.
quote_atom_source_identity(_Config) ->
    [
        ?assertEqual(binary_to_atom(B, utf8), scan_atom(qbin(B)))
     || B <- identity_corpus()
    ].

%% EDGE-DOMAIN ROUND-TRIP: for a corpus of awkward domains — reserved words,
%% metacharacters, an embedded quote/backslash, unicode, and the empty domain —
%% render -> compile -> load -> `catalog/0` recovers a catalog whose domain atom
%% has the EXACT bytes of the input binary (its atom interned by the COMPILER
%% from `quote_atom_source/1`), with locale/entries/header intact. This is the
%% end-to-end proof that the binary-threaded domain survives the sentinel-replace
%% carrier naming and the compiler interning, for domains a naive
%% `binary_to_atom` would have mishandled or a bare token would have mis-scanned.
quoting_roundtrips_edge_domains(_Config) ->
    Locale = ~"en",
    Entries = [{singular, undefined, ~"Hello", ~"Olá"}],
    Header = fallback_header(),
    lists:foreach(
        fun(Domain) ->
            {ModBin, Src} = rebar3_erli18n_codegen:render(
                {Domain, Locale, Entries, Header}, #{}
            ),
            {Mod, Beam} = compile_source(Src),
            ?assertEqual(ModBin, atom_to_binary(Mod, utf8)),
            _ = code:purge(Mod),
            {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Beam),
            try
                {Dom, Loc, Ents, Hdr} = Mod:catalog(),
                ?assertEqual(Domain, atom_to_binary(Dom, utf8)),
                ?assertEqual(Locale, Loc),
                ?assertEqual(Entries, Ents),
                ?assertEqual(Header, Hdr)
            after
                _ = code:purge(Mod),
                _ = code:delete(Mod)
            end
        end,
        edge_domains()
    ).

%% Awkward domains the binary-threaded quoting must round-trip: reserved words,
%% metacharacters, an embedded quote and backslash, Latin-1 and Cyrillic, and the
%% empty domain.
edge_domains() ->
    [
        ~"receive",
        ~"if",
        ~"catch",
        ~"end",
        ~"my-app",
        ~"a b",
        ~"a.b",
        ~"a'b",
        ~"a\\b",
        ~"café",
        ~"ключ",
        ~""
    ].

%% The two replace sentinels each render (via `erl_pp`) to a single-quoted
%% token, and neither token occurs as a substring of a normally-rendered
%% carrier — the property that makes the post-render `binary:replace` collision
%% free.
sentinels_render_isolated(_Config) ->
    ModTok = pp_atom(rebar3_erli18n_codegen:module_sentinel()),
    DomTok = pp_atom(rebar3_erli18n_codegen:domain_sentinel()),
    ?assertEqual(~"'$erli18n_cc_module$'", ModTok),
    ?assertEqual(~"'$erli18n_cc_domain$'", DomTok),
    Carrier = render_bin(
        spec([{singular, undefined, ~"Hello", ~"Olá"}], fallback_header()),
        #{}
    ),
    ?assertEqual(nomatch, binary:match(Carrier, ModTok)),
    ?assertEqual(nomatch, binary:match(Carrier, DomTok)).

%% A representative corpus exercising the round-trip identity and pure-ASCII
%% obligations: plain, reserved word, metachars, embedded quote/backslash,
%% Latin-1 and Cyrillic codepoints, the empty atom, control bytes and DEL.
identity_corpus() ->
    [
        ~"default",
        ~"if",
        ~"my-app",
        ~"a b",
        ~"a.b",
        ~"a'b",
        ~"a\\b",
        ~"café",
        ~"ключ",
        ~"",
        <<0, 9, 127>>,
        <<"\n\r\t">>
    ].

%% Render a single atom to its `erl_pp` token text as a binary.
pp_atom(Atom) ->
    unicode:characters_to_binary(erl_pp:expr({atom, erl_anno:new(0), Atom})).

%% Materialise `quote_atom_source/1`'s iolist to a binary for assertion.
qbin(Bin) ->
    unicode:characters_to_binary(rebar3_erli18n_codegen:quote_atom_source(Bin)).

%% Tokenise a rendered atom-source token back to its atom.
scan_atom(QBin) ->
    {ok, [{atom, _, Atom}, {dot, _}], _} =
        erl_scan:string(binary_to_list(QBin) ++ "."),
    Atom.

%% True when every byte of `Bin` is in the 7-bit ASCII range.
is_pure_ascii(Bin) ->
    lists:all(fun(B) -> B < 128 end, binary_to_list(Bin)).

%% =========================
%% Proof fixture drift guard
%% =========================

%% The committed proof fixture `erli18n_cc_default__en.erl` lives in
%% `apps/rebar3_erli18n/src/` so the gate's eqwalize step type-checks it
%% WITHOUT the function-scoped nowarn (it is rendered with
%% `eqwalizer_nowarn => false`). This case proves it cannot silently drift: a
%% fresh `render/2` of its source `compiled_spec()` must be byte-identical to
%% the committed file. If the emitter output changes, this fails until the
%% fixture is regenerated.
proof_fixture_does_not_drift(_Config) ->
    {Mod, Src} = rebar3_erli18n_codegen:render(
        to_render_spec(proof_spec()), #{eqwalizer_nowarn => false}
    ),
    %% `render/2` now returns the module name as a BINARY.
    ?assertEqual(~"erli18n_cc_default__en", Mod),
    Fresh = unicode:characters_to_binary(Src),
    %% The committed fixture is already loaded into the project, so its atom
    %% exists — resolve it WITHOUT interning a fresh atom.
    ModAtom = binary_to_existing_atom(Mod, utf8),
    SrcPath = fixture_source_path(ModAtom),
    {ok, Committed} = file:read_file(SrcPath),
    ?assertEqual(
        Committed,
        Fresh,
        "committed proof fixture drifted from render/2 — regenerate it"
    ),
    %% And the committed module agrees with the spec it was rendered from.
    ?assertEqual(proof_spec(), ModAtom:catalog()).

%% The proof fixture's source `compiled_spec()` — kept simple (fallback plural,
%% no divergence, ASCII) so it type-checks against the precise `-spec` without
%% the eqwalizer escape hatch.
proof_spec() ->
    {default, ~"en",
        [
            {singular, undefined, ~"Hello", ~"Hello"},
            {singular, ~"menu", ~"File", ~"File"}
        ],
        #{
            plural => fallback,
            plural_raw => ~"nplurals=2; plural=(n != 1);",
            po_path => ~"priv/locale/en/LC_MESSAGES/default.po",
            divergence => none,
            fuzzy_included => false,
            num_entries => 2
        }}.

%% Resolve the committed `.erl` path from the compiled module's own metadata,
%% so the test does not hard-code a repo-relative path.
fixture_source_path(Mod) ->
    CompileInfo = Mod:module_info(compile),
    case proplists:get_value(source, CompileInfo) of
        Path when is_list(Path) -> Path;
        _ -> ct:fail({no_source_in_module_info, Mod})
    end.

%% =========================
%% Helpers
%% =========================

%% Build a `compiled_spec()` for domain `default`, locale `pt_BR`.
spec(Entries, Header) ->
    {default, ~"pt_BR", Entries, Header}.

%% A `baked_header()` with `fallback` plural (no Plural-Forms header).
fallback_header() ->
    #{
        plural => fallback,
        plural_raw => ~"nplurals=2; plural=(n != 1);",
        po_path => "priv/locale/pt_BR/LC_MESSAGES/default.po",
        divergence => none,
        fuzzy_included => false,
        num_entries => 1
    }.

%% A `baked_header()` with an already-compiled plural rule.
compiled_header(NPlurals, Ast) ->
    #{
        plural => #{
            nplurals => NPlurals,
            expr => Ast,
            raw => ~"nplurals=2; plural=(n != 1);"
        },
        plural_raw => ~"nplurals=2; plural=(n != 1);",
        po_path => "priv/locale/pt_BR/LC_MESSAGES/default.po",
        divergence => none,
        fuzzy_included => false,
        num_entries => 1
    }.

%% Convert an atom-domain `compiled_spec()` (the term `catalog/0` must return)
%% into the binary-domain `render_spec()` that `render/2` now consumes. The
%% local `spec/2`, `proof_spec/0` and friends keep building the atom-domain
%% form so the assertions read against the real `catalog/0` output.
to_render_spec({Domain, Locale, Entries, Header}) ->
    {atom_to_binary(Domain, utf8), Locale, Entries, Header}.

render_bin(Spec, Opts) ->
    {_Mod, Src} = rebar3_erli18n_codegen:render(to_render_spec(Spec), Opts),
    unicode:characters_to_binary(Src).

contains(Bin, Needle) ->
    binary:match(Bin, Needle) =/= nomatch.

%% Render, compile (under the project erl_opts, so this also asserts the
%% generated source is warnings_as_errors-clean), load, and assert the loaded
%% `catalog/0` returns a term equal to the input spec.
assert_roundtrip(Spec) ->
    {ModBin, Src} = rebar3_erli18n_codegen:render(to_render_spec(Spec), #{}),
    %% The carrier's module ATOM is interned by the compiler; recover it from
    %% `compile:forms`' 3rd element and assert it matches the binary `render/2`
    %% returned (no atom is interned by the emitter or this test).
    {Mod, Beam} = compile_source(Src),
    ?assertEqual(ModBin, atom_to_binary(Mod, utf8)),
    _ = code:purge(Mod),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Beam),
    try
        ?assertEqual(Spec, Mod:catalog())
    after
        _ = code:purge(Mod),
        _ = code:delete(Mod)
    end.

%% Compile rendered source with the SAME strict options the project gate uses
%% (`warnings_as_errors` plus the warn flags), so a warning in the generated
%% source fails the case rather than passing silently. Returns the compiler's
%% interned module atom alongside the BEAM.
compile_source(Src) ->
    Bin = unicode:characters_to_binary(Src),
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Bin)),
    Forms = split_forms(Tokens),
    Opts = [
        binary,
        debug_info,
        return_errors,
        warnings_as_errors,
        warn_unused_vars,
        warn_shadow_vars,
        warn_obsolete_guard
    ],
    case compile:forms(Forms, Opts) of
        {ok, Mod, Beam} ->
            {Mod, Beam};
        Other ->
            ct:fail({compile_failed, Other})
    end.

%% Split a flat token list into per-form abstract forms on `dot` tokens.
split_forms(Tokens) ->
    split_forms(Tokens, [], []).

split_forms([], _Acc, Forms) ->
    lists:reverse(Forms);
split_forms([{dot, _} = Dot | Rest], Acc, Forms) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([Dot | Acc])),
    split_forms(Rest, [], [Form | Forms]);
split_forms([Tok | Rest], Acc, Forms) ->
    split_forms(Rest, [Tok | Acc], Forms).
