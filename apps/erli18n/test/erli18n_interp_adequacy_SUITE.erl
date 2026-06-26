-module(erli18n_interp_adequacy_SUITE).

%%% =====================================================================
%%% PURPOSE
%%% Adequacy suite for the pure `%{name}` interpolation substituter
%%% `erli18n_interp:format/2,3`. It pins observable, currently-CORRECT
%%% behaviour that the existing `erli18n_interp_SUITE` / `_props` leave
%%% unasserted, killing the surviving mutants each finding names:
%%%
%%%   * the strict-miss error carries the RAW BINARY name for a
%%%     never-interned placeholder (and the ATOM form for an interned one);
%%%   * the integer coercion arm is the ONLY `coerce/1` clause WITHOUT a
%%%     per-value clamp, so a bignum splices un-clamped (bounded only by the
%%%     global 65536 output cap) — this suite pins that current behaviour;
%%%   * a bogus `on_missing` value silently degrades strict -> lenient;
%%%   * a placeholder name of EXACTLY 256 bytes degrades safely on both
%%%     policies (read_name accepts it, the atom probe misses);
%%%   * a valid multibyte-UTF-8 binding value splices byte-identically
%%%     (no latin1 double-encoding);
%%%   * the per-value clamp DOES apply to the iolist / unknown-term arms;
%%%   * float values render via `float_to_binary/2` `[short]` across the
%%%     sign / zero-sign / scientific partitions.
%%%
%%% This suite was GENERATED from the test-adequacy audit (findings file
%%% group "interp", subset = everything EXCEPT the invalid-UTF-8 byte-offset
%%% truncation findings F1/F2/F3/F4/F6/F9/F22, which live in the dedicated
%%% RED suite `erli18n_interp_utf8_red_SUITE`). It covers F5, F7, F8, F10,
%%% F11, F12, F13, F14, F15, F16, F17, F18, F19, F20, F21, F23, F24, F25,
%%% F26, F27, F28, F29, F30.
%%%
%%% RED/GREEN EXPECTATION: this is a GREEN suite. Every case asserts the
%%% CURRENT (correct) behaviour and PASSES against the code as it stands,
%%% while each oracle is strong enough to FAIL under the mutation the finding
%%% names (tag/term swap, dropped clamp, added clamp, fallthrough flip,
%%% latin1 re-encode, `[short]` -> default float form).
%%% =====================================================================

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

%% PropEr `?FORALL`/`?LET`/`range`/`oneof` values are statically typed as
%% `term()` by eqwalizer; each property (and the `?LET`-binding generator
%% `ident_name/0`) binds generated values and uses them at their documented
%% shapes, so they carry a static `-eqwalizer({nowarn_function, ...})`
%% exactly like the existing `erli18n_interp_props` module.
-eqwalizer({nowarn_function, prop_strict_miss_name_shape/0}).
-eqwalizer({nowarn_function, prop_valid_utf8_value_passthrough/0}).
-eqwalizer({nowarn_function, prop_integer_value_not_per_value_clamped/0}).
-eqwalizer({nowarn_function, ident_name/0}).
-eqwalizer({nowarn_function, bogus_on_missing_degrades_to_lenient/1}).

-export([all/0]).

-export([
    strict_miss_never_interned_carries_raw_binary_name/1,
    integer_value_arm_bypasses_per_value_clamp/1,
    bogus_on_missing_degrades_to_lenient/1,
    name_exactly_256_bytes_degrades_safely/1,
    valid_multibyte_utf8_value_splices_byte_identically/1,
    per_value_clamp_applies_to_iolist_and_unknown_arms/1,
    float_partitions_render_short_form/1,
    prop_strict_miss_name_shape_holds/1,
    prop_valid_utf8_value_passthrough_holds/1,
    prop_integer_value_not_per_value_clamped_holds/1
]).

all() ->
    [
        strict_miss_never_interned_carries_raw_binary_name,
        integer_value_arm_bypasses_per_value_clamp,
        bogus_on_missing_degrades_to_lenient,
        name_exactly_256_bytes_degrades_safely,
        valid_multibyte_utf8_value_splices_byte_identically,
        per_value_clamp_applies_to_iolist_and_unknown_arms,
        float_partitions_render_short_form,
        prop_strict_miss_name_shape_holds,
        prop_valid_utf8_value_passthrough_holds,
        prop_integer_value_not_per_value_clamped_holds
    ].

%% =====================================================================
%% F5 + F11 + F13 + F17 + F20 — strict-miss error term shape.
%% `missing_name_term/1` (erli18n_interp.erl:406-411) returns the existing
%% ATOM when the name is already interned, otherwise the RAW BINARY (never
%% interns a new atom). The existing suite asserts ONLY the interned-atom
%% form (`{missing_binding, name}`); a mutant that always returned a fixed
%% atom — or wrapped the never-interned name in `binary_to_atom/2` — would
%% survive. Asserting the BINARY form for a never-interned name (and the
%% ATOM form for an interned one) pins both arms.
%% =====================================================================
strict_miss_never_interned_carries_raw_binary_name(_Config) ->
    %% Never-interned name: the strict error must carry the RAW BINARY.
    %% (The name appears ONLY as a binary literal here, never as an atom,
    %% so `binary_to_existing_atom/2` raises badarg for it.)
    ?assertError(
        {erli18n_interp, {missing_binding, <<"zzz_never_interned_xyzzy">>}},
        erli18n_interp:format(
            ~"%{zzz_never_interned_xyzzy}", #{}, #{on_missing => strict}
        )
    ),
    %% Contrast: an interned-but-unbound atom name carries the ATOM form.
    %% Writing the atom literal in the pattern interns it, so at runtime the
    %% probe finds it and `missing_name_term/1` returns the atom.
    ?assertError(
        {erli18n_interp, {missing_binding, interned_unbound_marker}},
        erli18n_interp:format(
            ~"%{interned_unbound_marker}", #{}, #{on_missing => strict}
        )
    ).

%% =====================================================================
%% F7 + F12 + F15 + F19 + F26 — the integer coercion arm
%% (erli18n_interp.erl:471-472 `coerce(V) when is_integer(V) ->
%% integer_to_binary(V)`) is the ONLY `coerce/1` clause NOT wrapped in
%% `clamp_value/1`. A bignum whose decimal text exceeds ?MAX_VALUE_BYTES
%% (8192) but is under the global ?MAX_OUTPUT_BYTES (65536) is therefore
%% spliced WHOLE. This pins that current (un-clamped) behaviour: a mutant
%% adding `clamp_value/1` to the integer arm would truncate to 8192 and
%% break the exact-equality oracle.
%% =====================================================================
integer_value_arm_bypasses_per_value_clamp(_Config) ->
    N = 1 bsl 40000,
    Full = integer_to_binary(N),
    %% ~12041 decimal digits: over the 8192 per-value cap, under the 65536
    %% output cap (so the global backstop does NOT truncate it either).
    ?assert(byte_size(Full) > 8192),
    ?assert(byte_size(Full) < 65536),
    Out = erli18n_interp:format(~"%{n}", #{n => N}),
    %% Spliced whole, byte-for-byte: the integer arm does not clamp.
    ?assertEqual(Full, Out),
    ?assertEqual(byte_size(Full), byte_size(Out)).

%% =====================================================================
%% F8 + F16 — a bogus `on_missing` value silently degrades to lenient.
%% `on_missing/1` (erli18n_interp.erl:222-223) matches only the literal
%% `strict`; any other value falls through to `lenient`, which leaves the
%% unbound `%{x}` literal instead of raising. A mutant flipping the
%% fallthrough to `strict` (or treating any value as strict) would raise,
%% breaking the equality oracle.
%% =====================================================================
bogus_on_missing_degrades_to_lenient(_Config) ->
    %% A wrong-but-plausible policy atom degrades to lenient (no raise).
    ?assertEqual(
        ~"need %{x}",
        erli18n_interp:format(~"need %{x}", #{}, #{on_missing => raise})
    ),
    %% A wrong-typed policy value degrades identically.
    ?assertEqual(
        ~"need %{x}",
        erli18n_interp:format(~"need %{x}", #{}, #{on_missing => true})
    ).

%% =====================================================================
%% F10 — a placeholder name of EXACTLY 256 bytes. `read_name/3` rejects
%% only `Len > ?MAX_NAME_BYTES` (256), so a 256-byte name is ACCEPTED;
%% but no atom can exceed 255 bytes, so `binary_to_existing_atom/2` misses
%% (badarg, caught). Lenient must round-trip the placeholder literally;
%% strict must raise with the raw 256-byte BINARY name. This pins the
%% read_name/atom off-by-one degrades safely on BOTH policies. The existing
%% suite only tests 255 (resolves) and 257 (rejected before the probe),
%% never the 256-byte boundary that reaches the probe.
%% =====================================================================
name_exactly_256_bytes_degrades_safely(_Config) ->
    Name = binary:copy(<<$a>>, 256),
    Msg = <<"%{", Name/binary, "}">>,
    %% Lenient: the 256-byte placeholder is emitted literally (round-trips),
    %% proving the atom-probe miss never crashes (totality holds).
    ?assertEqual(Msg, erli18n_interp:format(Msg, #{})),
    %% Strict: the same miss raises with the RAW 256-byte BINARY name
    %% (pinned by the bound `Name`, captured by the assert macro's fun).
    ?assertError(
        {erli18n_interp, {missing_binding, Name}},
        erli18n_interp:format(Msg, #{}, #{on_missing => strict})
    ).

%% =====================================================================
%% F14 + F18 + F21 — a valid multibyte-UTF-8 binding value splices through
%% BYTE-IDENTICALLY. `ensure_utf8/1` (erli18n_interp.erl:487-490) keeps
%% already-valid UTF-8 verbatim via `unicode:characters_to_binary(Bin, utf8,
%% utf8)`. A mutant flipping the source encoding to `latin1` would
%% double-encode every non-ASCII codepoint (e.g. <<195,169>> -> 4 bytes)
%% while still returning a binary; the existing suite uses only ASCII binary
%% values, so it would survive. The byte-exact `café` oracle kills it.
%% =====================================================================
valid_multibyte_utf8_value_splices_byte_identically(_Config) ->
    %% <<"café"/utf8>> = <<99,97,102,195,169>> (the 'é' is 2 UTF-8 bytes).
    ?assertEqual(
        <<"café"/utf8>>,
        erli18n_interp:format(~"%{v}", #{v => <<"café"/utf8>>})
    ),
    ?assertEqual(
        <<"hi café"/utf8>>,
        erli18n_interp:format(~"hi %{v}", #{v => <<"café"/utf8>>})
    ).

%% =====================================================================
%% F27 + F29 + F30 — the per-value clamp `clamp_value/1` is shared by the
%% iolist arm (erli18n_interp.erl:477-478) and the unknown-term arm
%% (erli18n_interp.erl:479-481), not just the binary arm asserted by the
%% existing suite. An oversized iolist and an oversized `~tp`-rendered term
%% must each clamp to exactly ?MAX_VALUE_BYTES (8192). A mutant dropping
%% `clamp_value/1` from either arm would leave the full (9000+/larger)
%% rendering and break the byte-size oracle.
%% =====================================================================
per_value_clamp_applies_to_iolist_and_unknown_arms(_Config) ->
    %% iolist arm: 9000-element iolist -> 9000 bytes -> clamped to 8192.
    Iolist = lists:duplicate(9000, $z),
    OutList = erli18n_interp:format(~"%{v}", #{v => Iolist}),
    ?assertEqual(8192, byte_size(OutList)),
    %% Content oracle: the clamp keeps the leading bytes (not some other
    %% truncation), killing a mutant that swaps `safe_iolist/1`.
    ?assertEqual(binary:copy(<<$z>>, 8192), OutList),
    %% unknown-term arm: a 4000-element tuple renders (`~tp`) to well over
    %% 8192 bytes -> clamped to 8192.
    Tuple = list_to_tuple(lists:seq(1, 4000)),
    OutTerm = erli18n_interp:format(~"%{v}", #{v => Tuple}),
    ?assertEqual(8192, byte_size(OutTerm)),
    %% The render begins with the actual inspected term (`{1,2,3,...`),
    %% proving the safe-inspect fallback ran before the clamp.
    ?assertMatch(<<"{1,2,3", _/binary>>, OutTerm).

%% =====================================================================
%% F28 — float coercion across partitions. `safe_float/1`
%% (erli18n_interp.erl:511-513) uses `float_to_binary(F, [short])`; the
%% existing suite asserts only `3.5`. Pinning the sign (-0.0), zero-sign
%% (0.0) and scientific (1.0e300 / 1.5e-10) partitions kills a mutant that
%% drops `[short]` (the default form renders `1.5e-10` as a long decimal).
%% =====================================================================
float_partitions_render_short_form(_Config) ->
    ?assertEqual(
        ~"pi=-0.0", erli18n_interp:format(~"pi=%{pi}", #{pi => -0.0})
    ),
    ?assertEqual(
        ~"pi=0.0", erli18n_interp:format(~"pi=%{pi}", #{pi => 0.0})
    ),
    ?assertEqual(
        ~"pi=1.0e300", erli18n_interp:format(~"pi=%{pi}", #{pi => 1.0e300})
    ),
    ?assertEqual(
        ~"pi=1.5e-10", erli18n_interp:format(~"pi=%{pi}", #{pi => 1.5e-10})
    ).

%% =====================================================================
%% F24 — property over the strict-miss Name shape. For an arbitrary
%% unbound, syntactically-valid placeholder name, the strict error's Name is
%% the existing ATOM if interned, otherwise the raw BINARY — exactly the
%% two arms of `missing_name_term/1`. The expected shape is computed
%% independently via `binary_to_existing_atom/2`, so a mutant that ALWAYS
%% returns a binary fails on an interned name, and one that ALWAYS interns
%% (atom) fails on a never-interned name.
%% =====================================================================
prop_strict_miss_name_shape_holds(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_strict_miss_name_shape(),
            [{numtests, 200}, {to_file, user}]
        )
    ).

prop_strict_miss_name_shape() ->
    ?FORALL(
        NameBin,
        ident_name(),
        begin
            %% Names longer than the 256-byte cap are rejected by read_name
            %% (emitted literally, no raise), so they fall outside this
            %% property's domain — skip them.
            case byte_size(NameBin) =< 256 of
                false ->
                    true;
                true ->
                    Input = <<"%{", NameBin/binary, "}">>,
                    Expected =
                        try binary_to_existing_atom(NameBin, utf8) of
                            A -> A
                        catch
                            error:badarg -> NameBin
                        end,
                    try
                        erli18n_interp:format(
                            Input, #{}, #{on_missing => strict}
                        )
                    of
                        %% An unbound name under strict MUST raise.
                        _ -> false
                    catch
                        error:{erli18n_interp, {missing_binding, Got}} ->
                            Got =:= Expected
                    end
            end
        end
    ).

%% =====================================================================
%% F23 — property: a valid-UTF-8 binding value under the per-value cap, in
%% a `%`-free single-placeholder template, passes through BYTE-IDENTICALLY.
%% `format(~"%{v}", #{v => V}) =:= V`. A latin1 re-encode mutant on
%% `ensure_utf8/1` would double-encode any non-ASCII codepoint, so the
%% identity fails for every multibyte value the generator emits.
%% =====================================================================
prop_valid_utf8_value_passthrough_holds(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_valid_utf8_value_passthrough(),
            [{numtests, 200}, {to_file, user}]
        )
    ).

prop_valid_utf8_value_passthrough() ->
    ?FORALL(
        Cps,
        list(valid_codepoint()),
        begin
            case unicode:characters_to_binary(Cps, unicode, utf8) of
                V when is_binary(V), byte_size(V) =< 8192 ->
                    %% Bound name `v` is interned via the map key; the value
                    %% is spliced once and never re-scanned, so output =:= V.
                    erli18n_interp:format(~"%{v}", #{v => V}) =:= V;
                _ ->
                    %% Over the per-value cap (clamped) — outside this
                    %% identity property's domain.
                    true
            end
        end
    ).

%% =====================================================================
%% F25 — property: the integer arm omits the per-value clamp, so a bignum
%% is spliced WHOLE and bounded only by the global 65536 output cap. For a
%% randomised power-of-two magnitude the output equals the full decimal
%% text when it fits, else exactly the first 65536 bytes. A mutant adding
%% `clamp_value/1` to the integer arm clamps to 8192 and fails whenever the
%% decimal text is in (8192, 65536].
%% =====================================================================
prop_integer_value_not_per_value_clamped_holds(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_integer_value_not_per_value_clamped(),
            [{numtests, 200}, {to_file, user}]
        )
    ).

prop_integer_value_not_per_value_clamped() ->
    ?FORALL(
        Shift,
        range(0, 300000),
        begin
            N = 1 bsl Shift,
            Full = integer_to_binary(N),
            Out = erli18n_interp:format(~"%{n}", #{n => N}),
            Cap = 65536,
            case byte_size(Full) =< Cap of
                true ->
                    %% Fits: spliced whole, no per-value clamp at 8192.
                    Out =:= Full;
                false ->
                    %% Over the output cap: truncated to exactly 65536 bytes
                    %% (all ASCII digits, so the cut is on a byte boundary).
                    byte_size(Out) =:= Cap andalso
                        Out =:= binary:part(Full, 0, Cap)
            end
        end
    ).

%% =========================
%% Generators
%% =========================

%% A syntactically valid placeholder name binary: first char a letter or
%% `_`, the rest letters / digits / `_`. Biased to sometimes draw from a
%% pool of atoms that are interned here (so the strict-miss ATOM arm is
%% exercised); the random branch yields almost-certainly never-interned
%% names (the BINARY arm). The atoms below appear as literals so they exist
%% at runtime, yet are UNBOUND (empty bindings) so strict raises.
ident_name() ->
    frequency([
        {3,
            ?LET(
                {First, Rest},
                {ident_first_char(), list(ident_rest_char())},
                list_to_binary([First | Rest])
            )},
        {1,
            ?LET(
                A,
                oneof([name, who, count, state, interned_unbound_marker]),
                atom_to_binary(A, utf8)
            )}
    ]).

ident_first_char() ->
    oneof([$a, $b, $c, $x, $y, $z, $A, $Q, $Z, $_]).

ident_rest_char() ->
    oneof([$a, $b, $c, $x, $y, $z, $0, $9, $_]).

%% A valid Unicode codepoint (excluding the surrogate range, which is not
%% UTF-8 encodable). Spans ASCII and multibyte so the byte-identity
%% passthrough property exercises the non-ASCII coercion path.
valid_codepoint() ->
    oneof([range(0, 16#D7FF), range(16#E000, 16#10FFFF)]).
