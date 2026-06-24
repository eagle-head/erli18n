%%% =====================================================================
%%% Property-based tests for `erli18n_interp` — the pure `%{name}`
%%% interpolation substituter (Phase 1 named interpolation).
%%%
%%% `erli18n_interp:format/2` runs on the `gettextf`/`ngettextf` hot path
%%% and carries the same totality bar as `erli18n_plural:evaluate/2`: for
%%% ANY `msgstr` bytes and ANY bindings map it must NEVER raise and ALWAYS
%%% return a binary. These properties exercise that contract adversarially.
%%%
%%% Properties:
%%%   * P-TOTAL — over arbitrary `msgstr` bytes (including invalid UTF-8,
%%%     stray `%`, unbalanced `%{`) and arbitrary bindings maps (atom keys,
%%%     wild values), `format/2` returns a binary and never crashes.
%%%   * P-ESCAPE — `%%` round-trips to a single literal `%`: a string built
%%%     only from `%%` pairs and `%`-free text decodes to exactly the text
%%%     with each `%%` halved, with empty bindings.
%%%   * P-MALFORMED — feeding a `%{` followed by an arbitrary (possibly
%%%     never-closing, possibly illegal-char) tail still yields a binary
%%%     and never raises (lenient AND strict; strict may only raise the
%%%     typed `missing_binding` error, never anything else).
%%%
%%% References:
%%%   * Hughes, "QuickCheck", ICFP 2000.
%%%   * PropEr docs — https://hexdocs.pm/proper/
%%% =====================================================================
-module(erli18n_interp_props).

-include_lib("proper/include/proper.hrl").

-export([
    prop_format_is_total/0,
    prop_double_percent_roundtrip/0,
    prop_malformed_reference_is_total/0
]).

%% Generators
-export([msgstr_bytes/0, bindings_map/0, binding_value/0, name_atom/0]).

%% PropEr `?FORALL`/`?LET` generators are statically typed as `term()` by
%% eqwalizer, so every function that binds a generated value to a documented
%% shape (a `binary()` msgstr, a `#{atom() => term()}` bindings map, a token
%% byte, …) carries a static `-eqwalizer({nowarn_function, F/A}).` annotation —
%% the same zero-runtime-dep pattern used in the runtime modules
%% `erli18n_server`/`erli18n_pt_store`. This replaces the former runtime
%% `eqwalizer` cast-helper calls (and the `eqwalizer_support` dep).
-eqwalizer({nowarn_function, prop_format_is_total/0}).
-eqwalizer({nowarn_function, prop_double_percent_roundtrip/0}).
-eqwalizer({nowarn_function, prop_malformed_reference_is_total/0}).
-eqwalizer({nowarn_function, msgstr_bytes/0}).
-eqwalizer({nowarn_function, msgstr_token/0}).
-eqwalizer({nowarn_function, bindings_map/0}).

%% =========================
%% Properties
%% =========================

%% P-TOTAL — `format/2` is total over arbitrary input.
%%
%% The generator deliberately biases toward the metacharacters that drive
%% the substitution state machine (`%`, `{`, `}`) plus arbitrary bytes
%% (which may form invalid UTF-8), and pairs them with a bindings map whose
%% values span every coercion branch. The only assertion is that the
%% result is a binary obtained without an exception.
prop_format_is_total() ->
    ?FORALL(
        {MsgstrGen, BindingsGen},
        {msgstr_bytes(), bindings_map()},
        begin
            %% PropEr generators are statically typed as `term()` by
            %% eqwalizer; this property carries a static
            %% `-eqwalizer({nowarn_function, ...})` (top of module) so the
            %% generator values are used at their documented contracts
            %% (`msgstr_bytes/0` yields a binary, `bindings_map/0` yields a
            %% `#{atom() => term()}`).
            Msgstr = MsgstrGen,
            Bindings = BindingsGen,
            try erli18n_interp:format(Msgstr, Bindings) of
                Out when is_binary(Out) ->
                    true;
                Other ->
                    ct:pal(
                        "P-TOTAL non-binary result: ~p~nMsgstr=~p Bindings=~p~n",
                        [Other, Msgstr, Bindings]
                    ),
                    false
            catch
                Class:Reason:Stack ->
                    ct:pal(
                        "P-TOTAL format/2 must be total but crashed: ~p:~p~n~p~n"
                        "Msgstr=~p Bindings=~p~n",
                        [Class, Reason, Stack, Msgstr, Bindings]
                    ),
                    false
            end
        end
    ).

%% P-ESCAPE — `%%` halves to a single `%`.
%%
%% We build the input from a `%`-free text fragment with `%%` pairs
%% interspersed, so the ONLY metacharacter activity is the `%%` escape.
%% The output must equal the text with each `%%` rendered as one `%`. With
%% empty bindings and no valid `%{name}`, nothing else can change.
prop_double_percent_roundtrip() ->
    ?FORALL(
        SegmentsGen,
        list(escape_segment()),
        begin
            Segments = SegmentsGen,
            Input = iolist_to_binary([seg_input(S) || S <- Segments]),
            Expected = iolist_to_binary([seg_expected(S) || S <- Segments]),
            try erli18n_interp:format(Input, #{}) of
                Expected ->
                    true;
                Other ->
                    ct:pal(
                        "P-ESCAPE mismatch:~nInput=~p~nExpected=~p~nGot=~p~n",
                        [Input, Expected, Other]
                    ),
                    false
            catch
                Class:Reason:Stack ->
                    ct:pal(
                        "P-ESCAPE crashed: ~p:~p~n~p~nInput=~p~n",
                        [Class, Reason, Stack, Input]
                    ),
                    false
            end
        end
    ).

%% P-MALFORMED — a `%{` followed by an arbitrary tail stays total under
%% BOTH policies. The tail may never close, may contain illegal name
%% characters, or may close on a valid-but-unbound name. The lenient path
%% must always return a binary; the strict path must either return a binary
%% or raise EXACTLY the typed `{erli18n_interp, {missing_binding, _}}`
%% error — never any other class of exception.
prop_malformed_reference_is_total() ->
    ?FORALL(
        {TailGen, BindingsGen},
        {msgstr_bytes(), bindings_map()},
        begin
            Tail = TailGen,
            Bindings = BindingsGen,
            Input = <<"%{", Tail/binary>>,
            LenientOk =
                try erli18n_interp:format(Input, Bindings) of
                    Out when is_binary(Out) -> true;
                    _ -> false
                catch
                    _:_ -> false
                end,
            StrictOk =
                try erli18n_interp:format(Input, Bindings, #{on_missing => strict}) of
                    Out2 when is_binary(Out2) -> true;
                    _ -> false
                catch
                    error:{erli18n_interp, {missing_binding, _}} ->
                        %% Only the typed opt-in error is permitted here.
                        true;
                    Class:Reason:Stack ->
                        ct:pal(
                            "P-MALFORMED strict raised wrong error: ~p:~p~n~p~n"
                            "Input=~p~n",
                            [Class, Reason, Stack, Input]
                        ),
                        false
                end,
            LenientOk andalso StrictOk
        end
    ).

%% =========================
%% Generators
%% =========================

%% Arbitrary `msgstr` bytes, biased toward the substitution
%% metacharacters so the state machine is heavily exercised. Includes
%% arbitrary bytes (which may form invalid UTF-8) to prove the coercion /
%% scan path never assumes well-formed input.
msgstr_bytes() ->
    ?LET(
        Tokens,
        list(msgstr_token()),
        iolist_to_binary(Tokens)
    ).

%% Each token is already a binary chunk: single metacharacters, raw bytes
%% (which may build invalid UTF-8 sequences), and well-formed multibyte
%% UTF-8 codepoints. Mixing raw bytes with valid codepoints exercises the
%% total UTF-8 handling of the scan/coercion path.
msgstr_token() ->
    frequency([
        {6, <<$%>>},
        {4, <<${>>},
        {3, <<$}>>},
        {3, ?LET(C, oneof([$a, $b, $_, $0, $9, $z, $A, $Z]), <<C>>)},
        {2, ?LET(Byte, range(0, 255), <<Byte>>)},
        {1, ?LET(Cp, range(16#80, 16#10FFFF), utf8_codepoint(Cp))}
    ]).

%% Encode a code point as UTF-8, skipping the surrogate range (which is
%% not encodable). Surrogates fall back to a single raw byte so the
%% generator stays total.
utf8_codepoint(Cp) when Cp >= 16#D800, Cp =< 16#DFFF ->
    <<16#3F>>;
utf8_codepoint(Cp) ->
    <<Cp/utf8>>.

%% Bindings map with atom keys (drawn from a fixed pool of EXISTING atoms,
%% so `binary_to_existing_atom/2` can find them) and values spanning every
%% coercion branch.
bindings_map() ->
    ?LET(
        Pairs,
        list({name_atom(), binding_value()}),
        maps:from_list(Pairs)
    ).

%% A pool of already-interned atoms usable as placeholder names. These are
%% literals here, so they exist at runtime.
name_atom() ->
    oneof([name, a, b, c, count, who, x, y, '_user_2', state]).

%% Values across the coercion surface: binaries (incl. invalid UTF-8),
%% integers, floats, atoms, iolists, and arbitrary terms.
binding_value() ->
    oneof([
        binary(),
        invalid_utf8_binary(),
        integer(),
        float(),
        oneof([ready, done, '']),
        list(range(0, 16#10FFFF)),
        {a, b},
        #{k => v},
        make_ref()
    ]).

%% Deterministically-invalid UTF-8 byte sequences (raw 0xFF/0xFE, truncated
%% multibyte leads, lone continuation bytes) so the `ensure_utf8/1` latin1
%% re-encode fallback is exercised on purpose, not only when a random
%% `binary()` happens to be ill-formed.
invalid_utf8_binary() ->
    oneof([
        <<16#FF, 16#FE, 16#FD>>,
        <<16#C3>>,
        <<16#E2, 16#82>>,
        <<16#80, 16#80>>,
        <<$a, 16#FF, $b>>
    ]).

%% A segment of the escape round-trip input: either a chunk of `%`-free
%% text, or a `%%` escape pair.
escape_segment() ->
    oneof([{text, percent_free_text()}, percent_pair]).

%% Text containing no `%` byte (so it cannot trigger any escape or
%% placeholder). Restricted to printable ASCII minus `%` for clarity.
percent_free_text() ->
    list(oneof([$a, $b, $c, $1, $2, ${, $}, $\s, $!, $\n])).

%% =========================
%% Escape-segment helpers
%% =========================
%% (Plain functions, not generators — operate on already-generated data.)

seg_input({text, Chars}) -> list_to_binary(Chars);
seg_input(percent_pair) -> ~"%%".

seg_expected({text, Chars}) -> list_to_binary(Chars);
seg_expected(percent_pair) -> ~"%".
