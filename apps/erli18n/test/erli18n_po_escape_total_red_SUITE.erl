%%% =====================================================================
%%% erli18n_po_escape_total_red_SUITE
%%%
%%% PURPOSE: pin the TOTALITY contract of the exported, cross-package
%%% serializer `erli18n_po:escape_string/1`. Its public `-spec` is
%%% `binary() -> binary()` and its docstring promises "every other byte
%%% passed through unchanged" — i.e. the function is documented TOTAL over
%%% all binaries. This suite asserts that promised behavior.
%%%
%%% GENERATED FROM: the po-parser test-adequacy audit, finding F2
%%% ("TOTALITY property missing for escape_string/1 — a non-UTF-8 byte
%%% crashes the documented-total binary()->binary() cross-package API").
%%%
%%% RED/GREEN EXPECTATION: this is a RED suite. The two totality
%%% testcases (`escape_string_total_examples/1` and
%%% `escape_string_total_property/1`) MUST FAIL against the current code.
%%% The bug, proven live: the catch-all clause at erli18n_po.erl:1770 is
%%% `escape_string(<<C/utf8, Rest/binary>>, Acc)`, so any binary holding a
%%% byte that is not valid UTF-8 (e.g. a lone <<255>>, <<254>>, a lone
%%% lead byte <<195>>, a truncated multibyte <<226,130>>, or a trailing
%%% stray byte <<"ok",255>>) matches NO clause and raises
%%% `error:function_clause` instead of returning a binary. The correct
%%% fix (a byte-wise catch-all) is NOT implemented here; this suite only
%%% pins the target behavior so the fix can turn it green.
%%%
%%% The single GREEN anchor (`escape_string_valid_passthrough/1`, clearly
%%% marked) confirms valid bytes already pass through unchanged TODAY, so
%%% the eventual fix must preserve that path rather than regress it.
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
%% F2 — totality: concrete counter-examples
%% =========================

%% F2 (RED). Each of these binaries contains a byte that is not a valid
%% UTF-8 encoding, so the catch-all `<<C/utf8, Rest/binary>>` clause at
%% erli18n_po.erl:1770 matches none of them and `escape_string/1` raises
%% `error:function_clause` TODAY. Per the documented `binary() -> binary()`
%% totality contract every call MUST instead return a binary. These
%% assertions therefore FAIL now and will pass once a byte-wise catch-all
%% is added.
%%
%% This is NOT a vacuous "no-crash" oracle: `is_binary/1` would still hold
%% for any passthrough or transcoded byte-wise fix, but it FAILS for the
%% surviving `function_clause` mutant — the exact behavior the finding
%% names. The non-UTF-8 partition is what distinguishes it from the
%% already-tested valid-byte path.
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
%% F2 — totality: property
%% =========================

%% F2 (RED). The totality law as a property: for ANY binary, the
%% documented-total serializer must return a binary. This is currently
%% falsifiable — PropEr will shrink to a minimal non-UTF-8 binary (e.g.
%% <<255>>) on which `escape_string/1` raises `function_clause`, so
%% `proper:quickcheck/2` returns a counter-example and the `?assert`
%% fails. Once the byte-wise catch-all lands, the property holds for all
%% 200 generated binaries.
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
%% GREEN anchor (passes TODAY)
%% =========================

%% GREEN. Valid UTF-8 bytes with no special escape character pass through
%% byte-identically under the current code. This anchor is deliberately
%% green: it guards the regression direction — the totality fix must NOT
%% break the existing valid-byte passthrough that the audit already
%% trusts. (The five escape substitutions \\ \" \n \t \r are owned by the
%% separate green po suite; here we only pin plain passthrough.)
escape_string_valid_passthrough(_Config) ->
    ?assertEqual(~"abc", erli18n_po:escape_string(~"abc")),
    %% A multibyte UTF-8 codepoint (é = <<195,169>>) is valid UTF-8 and
    %% survives unchanged via the `<<C/utf8, _>>` clause.
    ?assertEqual(<<16#C3, 16#A9>>, erli18n_po:escape_string(<<16#C3, 16#A9>>)).
