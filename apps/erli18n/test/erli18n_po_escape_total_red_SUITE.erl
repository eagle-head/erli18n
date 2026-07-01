%%% =====================================================================
%%% erli18n_po_escape_total_red_SUITE
%%%
%%% Pins the TOTALITY contract of the exported, cross-package serializer
%%% `erli18n_po:escape_string/1`. Its public `-spec` is
%%% `binary() -> binary()` and its docstring promises "every other byte
%%% passed through unchanged" — i.e. the function is total over all
%%% binaries. This suite asserts that behavior.
%%%
%%% The totality testcases (`escape_string_total_examples/1` and
%%% `escape_string_total_property/1`) exercise the non-UTF-8 partition:
%%% `escape_string/1` walks the binary with a `<<C/utf8, Rest/binary>>`
%%% clause, so a byte-wise catch-all is what keeps it total over input
%%% that is not valid UTF-8 (e.g. a lone <<255>>, <<254>>, a lone lead
%%% byte <<195>>, a truncated multibyte <<226,130>>, or a trailing stray
%%% byte <<"ok",255>>). For each such input the documented
%%% `binary() -> binary()` contract requires a binary result.
%%%
%%% `escape_string_valid_passthrough/1` pins the complementary direction:
%%% valid bytes pass through unchanged, so any totality change must
%%% preserve that path rather than regress it.
%%% =====================================================================
-module(erli18n_po_escape_total_red_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    escape_string_total_examples/1,
    escape_string_total_property/1,
    escape_string_valid_passthrough/1
]).

%% The PropEr `?FORALL` generator `binary()` is statically typed as
%% `proper_gen:instance()` by eqwalizer; the property binds the generated
%% value and feeds it to a documented `binary() -> binary()` API, so carry
%% the same static `-eqwalizer({nowarn_function, _})` annotation the
%% existing `erli18n_po_props` generators use.
-eqwalizer({nowarn_function, prop_escape_string_total/0}).

all() ->
    [
        escape_string_total_examples,
        escape_string_total_property,
        escape_string_valid_passthrough
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

%% =========================
%% totality: concrete counter-examples
%% =========================

%% Each of these binaries contains a byte that is not a valid UTF-8
%% encoding, so the `<<C/utf8, Rest/binary>>` walk in `escape_string/1`
%% only stays total over them via a byte-wise catch-all. Per the
%% documented `binary() -> binary()` totality contract every call must
%% return a binary.
%%
%% This is not a vacuous "no-crash" oracle: `is_binary/1` holds for any
%% passthrough or transcoded byte-wise handling, but not for a
%% `function_clause` failure on a non-UTF-8 byte — the exact behavior at
%% stake. The non-UTF-8 partition is what distinguishes it from the
%% valid-byte path.
escape_string_total_examples(_Config) ->
    NonUtf8Inputs = [
        %% Lone 0xFF — never a valid UTF-8 byte.
        <<255>>,
        %% Lone 0xFE — never a valid UTF-8 byte.
        <<254>>,
        %% Lone 2-byte lead 0xC3 with no continuation byte.
        <<195>>,
        %% Truncated 3-byte sequence (lead + one continuation, missing
        %% the final continuation byte).
        <<226, 130>>,
        %% Valid ASCII prefix followed by a stray non-UTF-8 byte — proves
        %% the crash is reached mid-walk, not only on a leading bad byte.
        <<"ok", 255>>
    ],
    lists:foreach(
        fun(Input) ->
            ?assert(is_binary(erli18n_po:escape_string(Input)))
        end,
        NonUtf8Inputs
    ).

%% =========================
%% totality: property
%% =========================

%% The totality law as a property: for ANY binary, the total serializer
%% must return a binary. PropEr explores the non-UTF-8 partition
%% (shrinking toward a minimal binary such as <<255>>), where a
%% `<<C/utf8, ...>>`-only walk would raise `function_clause`; the
%% byte-wise catch-all is what keeps the property holding across all
%% generated binaries.
escape_string_total_property(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_escape_string_total(),
            [{numtests, 200}, {to_file, user}]
        )
    ).

prop_escape_string_total() ->
    ?FORALL(
        B,
        binary(),
        is_binary(erli18n_po:escape_string(B))
    ).

%% =========================
%% valid-byte passthrough
%% =========================

%% Valid UTF-8 bytes with no special escape character pass through
%% byte-identically. This pins the complementary direction: any totality
%% change must not break valid-byte passthrough. (The five escape
%% substitutions \\ \" \n \t \r are owned by the separate po suite; here
%% we only pin plain passthrough.)
escape_string_valid_passthrough(_Config) ->
    ?assertEqual(~"abc", erli18n_po:escape_string(~"abc")),
    %% A multibyte UTF-8 codepoint (é = <<195,169>>) is valid UTF-8 and
    %% survives unchanged via the `<<C/utf8, _>>` clause.
    ?assertEqual(<<16#C3, 16#A9>>, erli18n_po:escape_string(<<16#C3, 16#A9>>)).
