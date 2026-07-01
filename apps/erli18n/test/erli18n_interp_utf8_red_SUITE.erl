-module(erli18n_interp_utf8_red_SUITE).

%%% =====================================================================
%%% PURPOSE
%%% Pin the documented "coerced output is ALWAYS valid UTF-8" invariant of
%%% `erli18n_interp:format/2,3` at its two BYTE-OFFSET truncation sites,
%%% neither of which may cut a multibyte UTF-8 codepoint in half:
%%%
%%%   * the per-value clamp `clamp_value/1`
%%%     (erli18n_interp.erl:530-531) at ?MAX_VALUE_BYTES = 8192, and
%%%   * the global output cap in `append_and_check/2`
%%%     (erli18n_interp.erl:443-446) at ?MAX_OUTPUT_BYTES = 65536.
%%%
%%% Both caps are powers of two; a 3-byte codepoint (e.g. U+20AC "€")
%%% divides neither evenly, so a raw `binary:part/3` cut would land inside
%%% a codepoint and emit a dangling lead/continuation byte (invalid UTF-8)
%%% that downstream cowboy/elli would serialise as a corrupt response body.
%%% Truncation must instead back off to a codepoint boundary.
%%%
%%% Every truncation testcase asserts that the output is well-formed UTF-8
%%% and byte-bounded by its cap. The `ascii_truncation_control_stays_valid`
%%% case pins the complementary bound: pure-ASCII truncation is already
%%% valid and stays exact, so the codepoint-boundary backoff must not
%%% over-truncate an all-ASCII run.
%%% =====================================================================

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

%% PropEr `?FORALL`/`range`/`oneof` values are statically typed as `term()`
%% by eqwalizer; the property binds generated values (a codepoint integer,
%% a repeat count) and uses them at their documented shapes, so it carries a
%% static `-eqwalizer({nowarn_function, ...})` exactly like the existing
%% `erli18n_interp_props` module.
-eqwalizer({nowarn_function, prop_truncation_preserves_utf8/0}).

-export([all/0]).

-export([
    value_clamp_multibyte_stays_valid_utf8/1,
    output_cap_multibyte_stays_valid_utf8/1,
    truncation_preserves_utf8_property/1,
    ascii_truncation_control_stays_valid/1,
    output_cap_all_continuation_bytes_total/1
]).

all() ->
    [
        value_clamp_multibyte_stays_valid_utf8,
        output_cap_multibyte_stays_valid_utf8,
        truncation_preserves_utf8_property,
        ascii_truncation_control_stays_valid,
        output_cap_all_continuation_bytes_total
    ].

%% =====================================================================
%% Per-value clamp (clamp_value/1, :530-531) must not split a 3-byte
%% codepoint. ?MAX_VALUE_BYTES = 8192 = 2730*3 + 2, so cutting a run of
%% U+20AC at byte 8192 would land two bytes into the 2731st codepoint,
%% dropping its third byte and leaving a dangling <<226,130>> (invalid
%% UTF-8). The clamped value must still be well-formed UTF-8 (and <= 8192
%% bytes).
%% =====================================================================
value_clamp_multibyte_stays_valid_utf8(_Config) ->
    %% U+20AC "€" encodes to exactly 3 UTF-8 bytes.
    Euro = <<"€"/utf8>>,
    %% 3000 copies = 9000 bytes -> clamped at byte 8192 (mid-codepoint).
    Out3000 = erli18n_interp:format(~"%{v}", #{v => binary:copy(Euro, 3000)}),
    assert_valid_utf8_within(Out3000, 8192),
    %% 5000 copies = 15000 bytes -> same per-value clamp boundary.
    Out5000 = erli18n_interp:format(~"%{v}", #{v => binary:copy(Euro, 5000)}),
    assert_valid_utf8_within(Out5000, 8192).

%% =====================================================================
%% Output cap (append_and_check/2, :443-446) must not split a 3-byte
%% codepoint. A 90000-byte literal run of U+20AC (the template IS the text,
%% no bindings) is truncated to ?MAX_OUTPUT_BYTES = 65536 = 21845*3 + 1, so
%% byte 65536 would be a lone lead byte of the 21846th codepoint (invalid
%% UTF-8). The truncated output must still be well-formed UTF-8 (and
%% <= 65536).
%% =====================================================================
output_cap_multibyte_stays_valid_utf8(_Config) ->
    Euro = <<"€"/utf8>>,
    Big = binary:copy(Euro, 30000),
    Out = erli18n_interp:format(Big, #{}),
    assert_valid_utf8_within(Out, 65536).

%% =====================================================================
%% Property: for a binary built from a repeated 3-byte codepoint of random
%% (cap-exceeding) length, BOTH truncation paths (the per-value clamp via
%% "%{v}", and the output cap via a literal run) must return well-formed
%% UTF-8 bounded by their respective caps. A byte-offset cut of a 3-byte
%% run at 8192/65536 always lands mid-codepoint, so truncation must back
%% off to a codepoint boundary.
%% =====================================================================
truncation_preserves_utf8_property(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_truncation_preserves_utf8(),
            [{numtests, 200}, {to_file, user}]
        )
    ).

prop_truncation_preserves_utf8() ->
    ?FORALL(
        {Cp, Count},
        {multibyte_3byte_codepoint(), range(2731, 30000)},
        begin
            %% A run of 3-byte codepoints; Count >= 2731 guarantees the
            %% value path (Count*3 > 8192) always truncates. The output path
            %% additionally truncates once Count*3 > 65536.
            V = binary:copy(<<Cp/utf8>>, Count),
            ValueOut = erli18n_interp:format(~"%{v}", #{v => V}),
            OutputOut = erli18n_interp:format(V, #{}),
            ValueOk = valid_and_bounded(ValueOut, 8192),
            OutputOk = valid_and_bounded(OutputOut, 65536),
            case ValueOk andalso OutputOk of
                true ->
                    true;
                false ->
                    ct:pal(
                        "UTF-8 truncation produced invalid output:~n"
                        "cp=~p count=~p~n"
                        "value_out_size=~p value_ok=~p~n"
                        "output_out_size=~p output_ok=~p~n",
                        [
                            Cp,
                            Count,
                            byte_size(ValueOut),
                            ValueOk,
                            byte_size(OutputOut),
                            OutputOk
                        ]
                    ),
                    false
            end
        end
    ).

%% =====================================================================
%% Pure-ASCII truncation is ALWAYS valid UTF-8 (every byte is its own
%% codepoint) and the cap byte sizes are exact. This pins that the
%% codepoint-boundary backoff must NOT over-truncate ASCII (the value
%% clamp must still land on 8192 and the output cap on 65536 for an
%% all-ASCII run).
%% =====================================================================
ascii_truncation_control_stays_valid(_Config) ->
    AsciiVal = binary:copy(<<$z>>, 9000),
    OutVal = erli18n_interp:format(~"%{v}", #{v => AsciiVal}),
    ?assertEqual(8192, byte_size(OutVal)),
    ?assert(is_binary(unicode:characters_to_binary(OutVal, utf8, utf8))),
    AsciiLit = binary:copy(<<$a>>, 70000),
    OutLit = erli18n_interp:format(AsciiLit, #{}),
    ?assertEqual(65536, byte_size(OutLit)),
    ?assert(is_binary(unicode:characters_to_binary(OutLit, utf8, utf8))).

%% =====================================================================
%% Totality edge — a literal made ENTIRELY of UTF-8 continuation bytes
%% (0x80), longer than the output cap. The codepoint-boundary back-off walks
%% every byte from the cut down to position 0 without ever finding a lead
%% byte (exercising the `codepoint_start/2` base clause), so the over-cap
%% chunk backs off to empty. The result must still be well-formed UTF-8
%% (empty is trivially valid) and within the cap — totality over malformed
%% bytes, never a crash and never a dangling partial sequence.
%% =====================================================================
output_cap_all_continuation_bytes_total(_Config) ->
    AllContinuation = binary:copy(<<16#80>>, 70000),
    Out = erli18n_interp:format(AllContinuation, #{}),
    ?assert(byte_size(Out) =< 65536),
    ?assert(is_binary(unicode:characters_to_binary(Out, utf8, utf8))).

%% =========================
%% Helpers
%% =========================

%% Assert (via the test framework) that `Out` is non-empty, byte-bounded by
%% `Cap`, and well-formed UTF-8. `unicode:characters_to_binary/3` returns a
%% binary only for valid input; an `{error,_,_}` / `{incomplete,_,_}` result
%% (a split codepoint) fails the `is_binary` oracle.
assert_valid_utf8_within(Out, Cap) ->
    ?assert(byte_size(Out) > 0),
    ?assert(byte_size(Out) =< Cap),
    ?assert(is_binary(unicode:characters_to_binary(Out, utf8, utf8))).

%% Boolean form of the same oracle, for use inside the property.
valid_and_bounded(Bin, Cap) ->
    byte_size(Bin) =< Cap andalso
        is_binary(unicode:characters_to_binary(Bin, utf8, utf8)).

%% Codepoints in U+0800..U+FFFF (excluding surrogates) encode to exactly 3
%% UTF-8 bytes. Because both caps (8192, 65536) are powers of two and 3
%% divides neither, a byte-offset cut of a run of these ALWAYS lands
%% mid-codepoint — the precise condition a raw byte-offset cut would
%% render as invalid UTF-8, which the truncator must back off to avoid.
multibyte_3byte_codepoint() ->
    oneof([16#20AC, 16#4E2D, 16#0939, 16#0E01, 16#16A0]).
