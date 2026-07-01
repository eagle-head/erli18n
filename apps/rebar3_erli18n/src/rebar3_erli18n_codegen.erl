-module(rebar3_erli18n_codegen).

-moduledoc """
Pure term-to-source emitter for compile-time erli18n catalogs.

`render/2` lifts a `render_spec()` — a `compiled_spec()`-shaped 4-tuple whose
domain is a BINARY (not an atom): an already-parsed entry list plus an
already-compiled plural rule (or the `fallback` atom) and a `baked_header()` —
into the Erlang SOURCE of a tiny generated module whose single `catalog/0`
clause returns the equivalent `compiled_spec()` term as a literal (the domain
atom is interned by the COMPILER from the rendered source, never by an
atom-creating BIF on filesystem/CLI input). A build-time provider then compiles
the source to BEAM, so the consumer's boot registers the catalog through
`erli18n_server:register_compiled_many/1` with NO runtime `.po` parse and NO
plural compile: every entry is pre-parsed and the plural AST is pre-built,
baked straight into the module's literal pool.

## How the source is built

The catalog term is lifted to an abstract literal with `erl_parse:abstract/2`
and wrapped in hand-built module/export/marker/spec forms plus the `catalog/0`
function form; each form is rendered with `erl_pp:form/1` under a `@generated`
banner. This uses ONLY `erl_parse` + `erl_pp` from stdlib — no `merl`, no
`erl_syntax`, no parse transform, and no `compile:forms`-to-BEAM step here
(compilation is a separate provider concern). The emitter is a pure function:
the same `render_spec()` and `render_opts()` always produce byte-identical
source.

The carrier's two dynamic atoms — its module name and its domain — are NOT
minted by an atom-creating BIF on the binary domain. Instead the forms are
rendered with two FIXED plugin-literal sentinel atoms (`?MODULE_SENTINEL` and
`?DOMAIN_SENTINEL`) standing in those slots, and a post-render `binary:replace`
swaps each rendered sentinel TOKEN for developer-controlled source text: the
raw binary module name, and `quote_atom_source/1` of the binary domain. The
compiler — not the emitter — then interns the carrier's atoms from that bounded
source. The `$` bytes force `erl_pp` to single-quote each sentinel into a token
that collides with no other rendered carrier token, so the replacement is
unambiguous and does not re-flow the `erl_pp` layout.

## The `-spec` and eqwalizer

The generated `catalog/0` ALWAYS carries the precise
`-spec catalog() -> erli18n_server:compiled_spec().`. By default (`render_opts`
`eqwalizer_nowarn => true`, also the value when the key is absent) it ALSO
carries a function-scoped `-eqwalizer({nowarn_function, catalog/0}).`: a
generated catalog can embed a deeply nested plural `t:erli18n_plural:ast/0`
literal that eqwalizer cannot always narrow to the spec, so the nowarn keeps a
generated module type-clean without weakening the precise spec. Passing
`eqwalizer_nowarn => false` omits the nowarn; it is used by the committed proof
fixture, whose `compiled_spec()` is simple enough to type-check against the
spec WITHOUT the escape hatch (so the spec itself is proven, not merely
asserted).

## Marker attribute

Every generated module carries
`-erli18n_compiled_catalog([{domain, _}, {locale, _}, {generator_vsn, _}]).`
so a loader can discover compiled catalogs by attribute and detect schema
drift via `generator_vsn/0`.
""".

-export([render/2, module_name/2, generator_vsn/0]).
-export([quote_atom_source/1, module_sentinel/0, domain_sentinel/0]).

%% `erl_parse:abstract_form()` and `abstract_expr()` are OPAQUE types: only
%% `erl_parse` may construct values of them. A source emitter, however, must
%% build these forms BY HAND (erl_parse exposes no public constructors), then
%% hand them to `erl_pp:form/1` — so dialyzer sees both the constructed
%% literals and the `erl_pp` call as opacity violations even though they are
%% well-formed abstract terms. We keep the precise opaque types in the specs
%% (they document the contract exactly) and scope a `no_opaque` suppression to
%% the form-building functions, the same structural mechanism the
%% `rebar3_erli18n_host` seam uses for its own unavoidable host-API edges.
-dialyzer(
    {no_opaque, [
        render/2,
        forms/5,
        eqwalizer_forms/1,
        marker_form/2,
        spec_form/0,
        catalog_function/1,
        abstract_term/1
    ]}
).

%% Codegen schema version. Bump when the SHAPE of the generated module
%% changes (the marker attribute, the `catalog/0` contract, or the literal
%% layout) so a loader can refuse a module emitted by an incompatible
%% generator. It is independent of the package `vsn` on purpose: the package
%% can release without changing the generated-module contract, and vice versa.
-define(GENERATOR_VSN, <<"1">>).

%% Fixed source annotation for every emitted form. The generated source has no
%% meaningful line geometry of its own (it is machine-built, not authored), so
%% a single constant keeps `render/2` deterministic and byte-stable.
-define(ANNO, erl_anno:new(0)).

%% Replace sentinels for the sentinel-replace carrier-naming technique. The
%% carrier is rendered through the unchanged `erl_pp` pipeline with these two
%% FIXED atoms standing in for the per-catalog module name and domain; a
%% post-render `binary:replace` then swaps the rendered sentinel TOKENS for the
%% developer-controlled source text, so the compiler — not an atom-creating BIF
%% on filesystem/CLI input — interns the carrier's two dynamic atoms. The `$`
%% bytes force `erl_pp` to single-quote each sentinel into a token
%% (`'$erli18n_cc_module$'` / `'$erli18n_cc_domain$'`) that collides with no
%% other rendered carrier token, making the replacement unambiguous.
-define(MODULE_SENTINEL, '$erli18n_cc_module$').
-define(DOMAIN_SENTINEL, '$erli18n_cc_domain$').

-doc """
Options controlling `render/2`.

- `eqwalizer_nowarn` — whether to emit the function-scoped
  `-eqwalizer({nowarn_function, catalog/0}).` on the generated `catalog/0`.
  Defaults to `true` (also the value when the key is ABSENT). `false` omits
  the nowarn and is used by the proof fixture. The precise
  `-spec catalog() -> erli18n_server:compiled_spec().` is emitted either way.
""".
-type render_opts() :: #{eqwalizer_nowarn => boolean()}.

-doc """
Input to `render/2`: a `compiled_spec()`-shaped 4-tuple whose domain is a
BINARY rather than an atom.

Threading the domain as a binary end-to-end keeps `render/2` from interning an
atom out of filesystem/CLI input. The carrier's domain atom is interned by the
COMPILER instead, from the `quote_atom_source/1` text spliced over the rendered
`?DOMAIN_SENTINEL` token. The `Locale`, entry list and `baked_header()` are
identical to those of `erli18n_server:compiled_spec()`.
""".
-type render_spec() ::
    {
        binary(),
        erli18n_server:locale(),
        [erli18n_po:entry()],
        erli18n_server:baked_header()
    }.

-export_type([render_opts/0, render_spec/0]).

-doc """
Render a `render_spec()` to the source of its generated catalog module.

Returns `{Module, Source}` where `Module` is the deterministic module name as
a BINARY (see `module_name/2`) and `Source` is the complete `.erl` text as
`unicode:chardata()`: a `@generated` banner, then the module/export/marker
forms, the precise `catalog/0` spec (with the optional eqwalizer nowarn per
`Opts`), and the `catalog/0` function whose body is the equivalent
`compiled_spec()` lifted to an abstract literal. The result round-trips:
compiling the source and calling `Module:catalog()` yields the `compiled_spec()`
the `render_spec()` denotes (its binary domain interned to the matching atom).

The carrier is rendered through the unchanged `forms/5` + `erl_pp:form/1`
pipeline with the two FIXED sentinel atoms in the module-name and domain slots;
a post-render `binary:replace` then splices the real binary module name and
`quote_atom_source/1` of the domain over the rendered sentinel tokens, so the
carrier's dynamic atoms are interned by the compiler, not by any atom-creating
BIF here.

The function is pure and deterministic — identical `Spec`/`Opts` always
produce byte-identical `Source`.
""".
-spec render(render_spec(), render_opts()) ->
    {binary(), unicode:chardata()}.
render({DomainBin, Locale, Entries, Header}, Opts) ->
    Mod = module_name(DomainBin, Locale),
    SentinelSpec = setelement(
        1, {DomainBin, Locale, Entries, Header}, ?DOMAIN_SENTINEL
    ),
    Forms = forms(?MODULE_SENTINEL, ?DOMAIN_SENTINEL, Locale, SentinelSpec, Opts),
    Rendered = iolist_to_binary([erl_pp:form(F) || F <- Forms]),
    WithModule = binary:replace(
        Rendered, <<"'$erli18n_cc_module$'">>, Mod, [global]
    ),
    Source = binary:replace(
        WithModule,
        <<"'$erli18n_cc_domain$'">>,
        iolist_to_binary(quote_atom_source(DomainBin)),
        [global]
    ),
    {Mod, [banner(Mod), Source]}.

-doc """
Deterministic module name for the catalog of `{Domain, Locale}`.

Mangles `Domain` and `Locale` — both binaries — into the unique BINARY
`erli18n_cc_<MangledDomain>__<MangledLocale>`. Each non-`[A-Za-z0-9]` byte is
replaced by `_` followed by its two lowercase hex digits, so the mapping is
INJECTIVE — distinct `{Domain, Locale}` pairs never collide. In particular a
`pt_BR` locale (`pt_5fBR`) and a `pt-BR` locale (`pt_2dBR`) yield distinct
module names. The `__` double-underscore between the two mangled segments is
an unambiguous separator: a mangled segment never contains `__` (its only `_`
bytes are escape markers, each followed by two hex digits).

The name is returned as a BINARY — no atom is interned here. The carrier's
module atom is interned by the compiler when the rendered source (with this
binary spliced over the `?MODULE_SENTINEL` token) is compiled.
""".
-spec module_name(binary(), erli18n_server:locale()) -> binary().
module_name(Domain, Locale) when is_binary(Domain), is_binary(Locale) ->
    MangledDomain = mangle(Domain),
    MangledLocale = mangle(Locale),
    <<"erli18n_cc_", MangledDomain/binary, "__", MangledLocale/binary>>.

-doc """
The generator schema version stamped into the marker attribute.

A loader compares it against the version it expects so a module emitted by an
incompatible generator (different marker layout, `catalog/0` contract or
literal shape) can be refused rather than mis-read.
""".
-spec generator_vsn() -> binary().
generator_vsn() ->
    ?GENERATOR_VSN.

-doc """
The fixed module-name replace sentinel, `'$erli18n_cc_module$'`.

Rendered into the carrier's `-module` slot (and any other module-name slot) so
a post-render `binary:replace` of its `erl_pp` token can splice in the real
carrier module name. Exposed so the replace site and its tests share one
source of truth for the sentinel atom.
""".
-spec module_sentinel() -> '$erli18n_cc_module$'.
module_sentinel() ->
    ?MODULE_SENTINEL.

-doc """
The fixed domain replace sentinel, `'$erli18n_cc_domain$'`.

Rendered into the carrier's domain slots (the marker attribute and the
`catalog/0` literal) so a post-render `binary:replace` of its `erl_pp` token
can splice in `quote_atom_source/1` of the real domain. Exposed so the replace
site and its tests share one source of truth for the sentinel atom.
""".
-spec domain_sentinel() -> '$erli18n_cc_domain$'.
domain_sentinel() ->
    ?DOMAIN_SENTINEL.

-doc """
Render `Bin` as Erlang single-quoted atom SOURCE text.

Returns the iolist source of a quoted atom whose interned value equals
`binary_to_atom(Bin, utf8)`: a leading `'`, each codepoint escaped via
`escape_cp/1`, and a trailing `'`. The atom is ALWAYS single-quoted (so
reserved words like `if`/`end` and metacharacter names like `my-app` scan back
correctly) and the output is ALWAYS pure 7-bit ASCII — every codepoint
`>= 128`, every control byte, `DEL`, the quote and the backslash are escaped,
so the source is safe to embed in any latin1-or-utf8 `.erl` file.

`Bin` MUST be valid UTF-8; a non-UTF-8 binary is a loud
`error({invalid_domain_encoding, Bin})` (this function interns NO atom and so
cannot launder undecodable bytes into one). It performs byte/codepoint/integer
operations only — it constructs no atom itself; the carrier's atom is interned
by the COMPILER from this developer-controlled source text.
""".
-spec quote_atom_source(binary()) -> iolist().
quote_atom_source(Bin) when is_binary(Bin) ->
    case unicode:characters_to_list(Bin, utf8) of
        Cps when is_list(Cps) ->
            [$', [escape_cp(Cp) || Cp <- Cps], $'];
        _NotAList ->
            error({invalid_domain_encoding, Bin})
    end.

%% Escape a single codepoint for inclusion inside a single-quoted atom token.
%% Printable ASCII (excluding the quote and backslash) passes through verbatim;
%% the quote and backslash are backslash-escaped; everything else (control
%% bytes, `DEL`, and every codepoint `>= 128`) becomes a uniform lowercase
%% `\x{...}` brace escape, keeping the output pure 7-bit ASCII.
-spec escape_cp(char()) -> char() | iolist().
escape_cp($') ->
    [$\\, $'];
escape_cp($\\) ->
    [$\\, $\\];
escape_cp(C) when C >= 16#20, C =< 16#7E ->
    C;
escape_cp(C) ->
    Hex = string:lowercase(integer_to_list(C, 16)),
    [$\\, $x, ${, Hex, $}].

%% =========================
%% Form construction
%% =========================

%% The ordered list of abstract forms making up the generated module:
%% `-module`, `-export`, the marker attribute, the optional eqwalizer nowarn,
%% the precise `-spec`, and finally the `catalog/0` function whose single
%% clause body is the `compiled_spec()` lifted to an abstract literal.
-spec forms(
    module(),
    erli18n_server:domain(),
    erli18n_server:locale(),
    erli18n_server:compiled_spec(),
    render_opts()
) -> [erl_parse:abstract_form()].
forms(Mod, Domain, Locale, Spec, Opts) ->
    Head = [
        {attribute, ?ANNO, module, Mod},
        {attribute, ?ANNO, export, [{catalog, 0}]},
        marker_form(Domain, Locale)
    ],
    Eqwalizer = eqwalizer_forms(Opts),
    Tail = [
        spec_form(),
        catalog_function(Spec)
    ],
    Head ++ Eqwalizer ++ Tail.

%% `-erli18n_compiled_catalog([{domain, D}, {locale, L}, {generator_vsn, V}]).`
-spec marker_form(erli18n_server:domain(), erli18n_server:locale()) ->
    erl_parse:abstract_form().
marker_form(Domain, Locale) ->
    {attribute, ?ANNO, erli18n_compiled_catalog, [
        {domain, Domain},
        {locale, Locale},
        {generator_vsn, ?GENERATOR_VSN}
    ]}.

%% The optional `-eqwalizer({nowarn_function, catalog/0}).` form. Emitted when
%% `eqwalizer_nowarn` is absent or `true`; omitted on `false`. The parser
%% normalises `catalog/0` to the `{catalog, 0}` tuple, exactly what eqwalizer
%% reads from a hand-written `catalog/0` source form, so the two are
%% indistinguishable post-parse.
-spec eqwalizer_forms(render_opts()) -> [erl_parse:abstract_form()].
eqwalizer_forms(Opts) ->
    case maps:get(eqwalizer_nowarn, Opts, true) of
        false ->
            [];
        true ->
            [{attribute, ?ANNO, eqwalizer, {nowarn_function, {catalog, 0}}}]
    end.

%% `-spec catalog() -> erli18n_server:compiled_spec().`
-spec spec_form() -> erl_parse:abstract_form().
spec_form() ->
    FunType =
        {type, ?ANNO, 'fun', [
            {type, ?ANNO, product, []},
            {remote_type, ?ANNO, [
                {atom, ?ANNO, erli18n_server},
                {atom, ?ANNO, compiled_spec},
                []
            ]}
        ]},
    {attribute, ?ANNO, spec, {{catalog, 0}, [FunType]}}.

%% `catalog() -> <Spec as abstract literal>.`
-spec catalog_function(erli18n_server:compiled_spec()) -> erl_parse:abstract_form().
catalog_function(Spec) ->
    Body = abstract_term(Spec),
    {function, ?ANNO, catalog, 0, [
        {clause, ?ANNO, [], [], [Body]}
    ]}.

%% Lift an arbitrary `compiled_spec()` sub-term to an abstract literal with a
%% CANONICAL, deterministic layout. `erl_parse:abstract/2` renders a map in the
%% term's internal iteration order, which is NOT stable across how the map was
%% constructed (a compiler-built literal and a runtime-assembled map with the
%% same keys can iterate differently), so a build-time render and a
%% verification-time render of the "same" spec could differ byte-for-byte. We
%% therefore handle maps ourselves, emitting fields in sorted-key order, and
%% recurse through tuples and lists so a nested header/plural map is canonical
%% too; leaves (atoms, integers, binaries, `[]`) defer to `erl_parse:abstract/2`.
%% Sorting by key is loss-free here because every map in a `compiled_spec()` has
%% unique atom keys.
-spec abstract_term(term()) -> erl_parse:abstract_expr().
abstract_term(Map) when is_map(Map) ->
    Fields = [
        {map_field_assoc, ?ANNO, abstract_term(K), abstract_term(V)}
     || {K, V} <- lists:sort(maps:to_list(Map))
    ],
    {map, ?ANNO, Fields};
abstract_term(Tuple) when is_tuple(Tuple) ->
    {tuple, ?ANNO, [abstract_term(E) || E <- tuple_to_list(Tuple)]};
abstract_term([H | T]) ->
    {cons, ?ANNO, abstract_term(H), abstract_term(T)};
abstract_term([]) ->
    {nil, ?ANNO};
abstract_term(Leaf) ->
    erl_parse:abstract(Leaf, [{line, 0}]).

%% =========================
%% Banner
%% =========================

%% The `@generated` DO-NOT-EDIT comment block prepended to every module. It is
%% plain comment text (erl_pp never emits comments) so it is rendered here, not
%% as an abstract form.
-spec banner(binary()) -> unicode:chardata().
banner(ModBin) ->
    [
        ~"%% @generated by rebar3_erli18n_codegen — DO NOT EDIT.\n",
        ~"%%\n",
        <<"%% Compile-time erli18n catalog for module ", ModBin/binary, ".\n">>,
        ~"%% An already-parsed entry list plus an already-compiled plural rule,\n",
        ~"%% baked into BEAM so boot performs no .po parse and no plural compile.\n",
        ~"%% Regenerate from the source .po; manual edits will be overwritten.\n",
        ~"\n"
    ].

%% =========================
%% Name mangling
%% =========================

%% Replace every non-`[A-Za-z0-9]` byte of `Bin` with `_` followed by its two
%% lowercase hex digits, leaving alphanumeric bytes untouched. The result is a
%% valid atom-name segment and the transform is injective (the `_xx` escape is
%% unambiguous: an escape marker `_` is always followed by two hex digits,
%% which an alphanumeric byte never is).
-spec mangle(binary()) -> binary().
mangle(Bin) ->
    iolist_to_binary([mangle_byte(B) || <<B>> <= Bin]).

-spec mangle_byte(byte()) -> byte() | binary().
mangle_byte(B) when
    (B >= $0 andalso B =< $9);
    (B >= $A andalso B =< $Z);
    (B >= $a andalso B =< $z)
->
    B;
mangle_byte(B) ->
    Hex = integer_to_binary(B, 16),
    Padded =
        case Hex of
            <<_>> -> <<"0", Hex/binary>>;
            _ -> Hex
        end,
    <<"_", (string:lowercase(Padded))/binary>>.
