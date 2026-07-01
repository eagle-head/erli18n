-module(erli18n_interp_SUITE).

%% Common Test suite for the pure `%{name}` interpolation substituter
%% `erli18n_interp` (named interpolation). The substituter is
%% TOTAL and fail-soft: malformed `msgstr` bytes or missing bindings must
%% degrade gracefully, never crash a lookup (same bar as `erli18n_po`).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).

-export([
    substitutes_a_named_binding/1,
    substitutes_multiple_bindings/1,
    reorders_bindings_by_name/1,
    repeats_a_binding/1,
    missing_binding_lenient_leaves_literal/1,
    missing_binding_strict_raises/1,
    strict_resolves_when_present/1,
    double_percent_escapes_to_literal/1,
    double_percent_brace_emits_literal_placeholder/1,
    triple_percent_then_placeholder_bound/1,
    triple_percent_then_placeholder_missing/1,
    adjacent_placeholders_resolve/1,
    value_with_placeholder_syntax_is_not_reinterpolated/1,
    malformed_unclosed_brace_is_literal/1,
    malformed_empty_name_is_literal/1,
    malformed_leading_digit_is_literal/1,
    lone_trailing_percent_is_literal/1,
    coerces_integer_value/1,
    coerces_atom_value/1,
    coerces_float_value/1,
    coerces_iolist_value/1,
    coerces_unknown_term_safely/1,
    empty_bindings_leaves_all_literals/1,
    empty_msgstr_yields_empty/1,
    underscore_and_digits_in_name/1,
    cap_clamps_oversized_value/1,
    cap_truncates_oversized_output/1,
    cap_emits_literal_beyond_expansion_limit/1,
    cap_oversized_name_is_literal/1,
    cap_output_bounded_on_unbound_placeholders/1,
    cap_output_bounded_on_double_percent/1,
    cap_output_bounded_on_literal_text/1,
    cap_value_exactly_at_limit_not_clamped/1,
    cap_expansions_exactly_at_limit_all_substituted/1,
    name_at_max_atom_length_resolves/1,
    output_capped_across_token_kinds/1,
    coerce_non_text_value_fallbacks/1
]).

all() ->
    [
        substitutes_a_named_binding,
        substitutes_multiple_bindings,
        reorders_bindings_by_name,
        repeats_a_binding,
        missing_binding_lenient_leaves_literal,
        missing_binding_strict_raises,
        strict_resolves_when_present,
        double_percent_escapes_to_literal,
        double_percent_brace_emits_literal_placeholder,
        triple_percent_then_placeholder_bound,
        triple_percent_then_placeholder_missing,
        adjacent_placeholders_resolve,
        value_with_placeholder_syntax_is_not_reinterpolated,
        malformed_unclosed_brace_is_literal,
        malformed_empty_name_is_literal,
        malformed_leading_digit_is_literal,
        lone_trailing_percent_is_literal,
        coerces_integer_value,
        coerces_atom_value,
        coerces_float_value,
        coerces_iolist_value,
        coerces_unknown_term_safely,
        empty_bindings_leaves_all_literals,
        empty_msgstr_yields_empty,
        underscore_and_digits_in_name,
        cap_clamps_oversized_value,
        cap_truncates_oversized_output,
        cap_emits_literal_beyond_expansion_limit,
        cap_oversized_name_is_literal,
        cap_output_bounded_on_unbound_placeholders,
        cap_output_bounded_on_double_percent,
        cap_output_bounded_on_literal_text,
        cap_value_exactly_at_limit_not_clamped,
        cap_expansions_exactly_at_limit_all_substituted,
        name_at_max_atom_length_resolves,
        output_capped_across_token_kinds,
        coerce_non_text_value_fallbacks
    ].

%% A single `%{name}` placeholder is replaced by its bound value.
substitutes_a_named_binding(_Config) ->
    ?assertEqual(
        ~"Hello, World!",
        erli18n_interp:format(~"Hello, %{name}!", #{name => ~"World"})
    ).

%% Several distinct placeholders each resolve independently.
substitutes_multiple_bindings(_Config) ->
    ?assertEqual(
        ~"a=1, b=2",
        erli18n_interp:format(
            ~"a=%{a}, b=%{b}",
            #{a => ~"1", b => ~"2"}
        )
    ).

%% Placeholders resolve BY NAME, so the translator may reorder them
%% without touching the call site.
reorders_bindings_by_name(_Config) ->
    B = #{first => ~"Ada", last => ~"Lovelace"},
    ?assertEqual(
        ~"Ada Lovelace",
        erli18n_interp:format(~"%{first} %{last}", B)
    ),
    ?assertEqual(
        ~"Lovelace, Ada",
        erli18n_interp:format(~"%{last}, %{first}", B)
    ).

%% The same name may appear more than once.
repeats_a_binding(_Config) ->
    ?assertEqual(
        ~"x x x",
        erli18n_interp:format(~"%{w} %{w} %{w}", #{w => ~"x"})
    ).

%% Lenient (the format/2 default): an unbound name is left literal.
missing_binding_lenient_leaves_literal(_Config) ->
    ?assertEqual(
        ~"Hello, %{name}!",
        erli18n_interp:format(~"Hello, %{name}!", #{})
    ),
    %% Mixed: present resolves, absent stays literal.
    ?assertEqual(
        ~"1 and %{b}",
        erli18n_interp:format(~"%{a} and %{b}", #{a => ~"1"})
    ).

%% Strict: an unbound name raises the typed error.
missing_binding_strict_raises(_Config) ->
    ?assertError(
        {erli18n_interp, {missing_binding, name}},
        erli18n_interp:format(
            ~"Hello, %{name}!", #{}, #{on_missing => strict}
        )
    ).

%% Strict still resolves a present binding without raising.
strict_resolves_when_present(_Config) ->
    ?assertEqual(
        ~"Hello, Sam!",
        erli18n_interp:format(
            ~"Hello, %{who}!",
            #{who => ~"Sam"},
            #{on_missing => strict}
        )
    ).

%% `%%` collapses to a single literal `%`.
double_percent_escapes_to_literal(_Config) ->
    ?assertEqual(
        ~"100% sure",
        erli18n_interp:format(~"100%% sure", #{})
    ).

%% `%%{name}` -> `%` then a literal `{name}` (the placeholder is NOT
%% substituted because `%%` consumed the `%`).
double_percent_brace_emits_literal_placeholder(_Config) ->
    ?assertEqual(
        ~"%{name}",
        erli18n_interp:format(~"%%{name}", #{name => ~"X"})
    ).

%% `%%%{name}` = `%%` (-> literal `%`) followed by `%{name}`. With the
%% binding present the third `%` starts a real placeholder, so the result
%% is `%` + value. This exercises the left-to-right, two-byte `%%`
%% consumption rule against an immediately following placeholder.
triple_percent_then_placeholder_bound(_Config) ->
    ?assertEqual(
        ~"%X",
        erli18n_interp:format(~"%%%{name}", #{name => ~"X"})
    ).

%% `%%%{name}` with NO binding: `%%` -> `%`, then `%{name}` is an unbound
%% placeholder left literal (lenient). The literal output therefore keeps
%% the leading `%` AND the un-substituted `%{name}`, i.e. `%%{name}`.
triple_percent_then_placeholder_missing(_Config) ->
    ?assertEqual(
        ~"%%{name}",
        erli18n_interp:format(~"%%%{name}", #{})
    ).

%% Two placeholders with no separator each resolve independently in the
%% single left-to-right pass.
adjacent_placeholders_resolve(_Config) ->
    ?assertEqual(
        ~"AB",
        erli18n_interp:format(~"%{a}%{b}", #{a => ~"A", b => ~"B"})
    ).

%% One-pass semantics: a value that itself contains `%{...}` syntax is
%% spliced verbatim and NOT re-scanned for further substitution.
value_with_placeholder_syntax_is_not_reinterpolated(_Config) ->
    ?assertEqual(
        ~"x=%{c}",
        erli18n_interp:format(~"x=%{v}", #{v => ~"%{c}"})
    ).

%% A `%{` that never closes is emitted literally, never crashes.
malformed_unclosed_brace_is_literal(_Config) ->
    ?assertEqual(
        ~"%{name",
        erli18n_interp:format(~"%{name", #{name => ~"X"})
    ),
    ?assertEqual(
        ~"a %{ b",
        erli18n_interp:format(~"a %{ b", #{})
    ).

%% `%{}` (empty name) is malformed -> literal.
malformed_empty_name_is_literal(_Config) ->
    ?assertEqual(
        ~"%{}",
        erli18n_interp:format(~"%{}", #{})
    ).

%% A name may not START with a digit -> malformed -> literal.
malformed_leading_digit_is_literal(_Config) ->
    ?assertEqual(
        ~"%{1bad}",
        erli18n_interp:format(~"%{1bad}", #{})
    ).

%% A lone `%` at end of input is literal.
lone_trailing_percent_is_literal(_Config) ->
    ?assertEqual(
        ~"done 100%",
        erli18n_interp:format(~"done 100%", #{})
    ).

%% Integer values coerce to decimal text.
coerces_integer_value(_Config) ->
    ?assertEqual(
        ~"count=42",
        erli18n_interp:format(~"count=%{count}", #{count => 42})
    ),
    ?assertEqual(
        ~"n=-7",
        erli18n_interp:format(~"n=%{n}", #{n => -7})
    ).

%% Atom values coerce via their UTF-8 name.
coerces_atom_value(_Config) ->
    ?assertEqual(
        ~"state=ready",
        erli18n_interp:format(~"state=%{state}", #{state => ready})
    ).

%% Float values coerce to a textual form (no crash).
coerces_float_value(_Config) ->
    Out = erli18n_interp:format(~"pi=%{pi}", #{pi => 3.5}),
    ?assertEqual(~"pi=3.5", Out).

%% Iolists / strings coerce to UTF-8 text.
coerces_iolist_value(_Config) ->
    ?assertEqual(
        ~"v=abc",
        erli18n_interp:format(~"v=%{v}", #{v => [$a, ~"b", "c"]})
    ).

%% An unknown term (tuple) renders via a bounded safe fallback, no crash.
coerces_unknown_term_safely(_Config) ->
    Out = erli18n_interp:format(~"x=%{x}", #{x => {a, b}}),
    %% Content assertion: the unknown term is actually rendered (`~tp`),
    %% not merely replaced by some non-empty placeholder.
    ?assertMatch(<<"x=", _/binary>>, Out),
    ?assert(binary:match(Out, ~"{a,b}") =/= nomatch).

%% Empty bindings: every placeholder stays literal (lenient default).
empty_bindings_leaves_all_literals(_Config) ->
    ?assertEqual(
        ~"%{a} %{b}",
        erli18n_interp:format(~"%{a} %{b}", #{})
    ).

%% Empty input -> empty output.
empty_msgstr_yields_empty(_Config) ->
    ?assertEqual(<<>>, erli18n_interp:format(<<>>, #{x => ~"y"})).

%% Underscores and inner digits are valid name characters.
underscore_and_digits_in_name(_Config) ->
    ?assertEqual(
        ~"v",
        erli18n_interp:format(~"%{_user_2}", #{'_user_2' => ~"v"})
    ).

%% =========================
%% Anti-DoS caps (fail-soft clamping, never raising)
%% =========================

%% A single binding value larger than the per-value cap (8192 bytes) is
%% clamped before splicing. The result keeps the `v=` prefix plus exactly
%% the first 8192 bytes of the value.
cap_clamps_oversized_value(_Config) ->
    Big = binary:copy(<<$z>>, 9000),
    Out = erli18n_interp:format(~"v=%{v}", #{v => Big}),
    %% "v=" (2 bytes) + clamped value (8192 bytes).
    ?assertEqual(2 + 8192, byte_size(Out)),
    ?assertMatch(<<"v=", _/binary>>, Out),
    %% The original 9000-byte value did NOT pass through whole.
    ?assert(byte_size(Out) < byte_size(<<"v=", Big/binary>>)).

%% Accumulated output is truncated once it would exceed the output cap
%% (65536 bytes): the pass stops and drops the remaining input rather than
%% growing without bound. 100 placeholders each rendering 1000 bytes would
%% be ~100000 bytes uncapped; the capped output is far smaller.
cap_truncates_oversized_output(_Config) ->
    BigVal = binary:copy(<<$q>>, 1000),
    Many = binary:copy(~"%{v}", 100),
    Out = erli18n_interp:format(Many, #{v => BigVal}),
    %% Bounded near the cap, well below the uncapped ~100000 bytes.
    ?assert(byte_size(Out) < 100000),
    ?assert(byte_size(Out) =< 65536 + byte_size(BigVal)),
    %% Not all 100 expansions survived (truncation dropped the tail).
    ?assert(length(binary:matches(Out, BigVal)) < 100).

%% Beyond the expansion cap (1024) further `%{name}` references are emitted
%% LITERALLY instead of substituted. With 1100 references and a binding
%% present, exactly 1024 are substituted and the remaining 76 stay literal.
cap_emits_literal_beyond_expansion_limit(_Config) ->
    Ph = binary:copy(~"%{v}", 1100),
    Out = erli18n_interp:format(Ph, #{v => ~"-"}),
    ?assertEqual(1024, length(binary:matches(Out, ~"-"))),
    ?assertEqual(1100 - 1024, length(binary:matches(Out, ~"%{v}"))).

%% A placeholder name run exceeding the name cap (256 bytes) before its
%% closing `}` is treated as malformed and emitted literally — never
%% probed against the atom table. The whole input round-trips unchanged.
cap_oversized_name_is_literal(_Config) ->
    LongName = binary:copy(<<$a>>, 257),
    Msg = <<"%{", LongName/binary, "}">>,
    ?assertEqual(Msg, erli18n_interp:format(Msg, #{})).

%% Many UNBOUND placeholders on the lenient path must
%% keep the accumulated output within the cap. Each `%{<256-byte-name>}` is
%% emitted literally; ~2000 of them would be ~518000 bytes uncapped.
cap_output_bounded_on_unbound_placeholders(_Config) ->
    Name = binary:copy(<<$a>>, 256),
    Ph = <<"%{", Name/binary, "}">>,
    In = binary:copy(Ph, 2000),
    Out = erli18n_interp:format(In, #{}),
    ?assert(byte_size(Out) =< 65536).

%% Regression: a long run of `%%` escapes (each -> one literal `%`) is
%% bounded by the output cap rather than growing with the input.
cap_output_bounded_on_double_percent(_Config) ->
    In = binary:copy(~"%%", 100000),
    Out = erli18n_interp:format(In, #{}),
    ?assert(byte_size(Out) =< 65536).

%% Regression: a huge run of plain literal text (no placeholders) is
%% truncated at the output cap, not returned whole.
cap_output_bounded_on_literal_text(_Config) ->
    In = binary:copy(<<$a>>, 70000),
    Out = erli18n_interp:format(In, #{}),
    ?assertEqual(65536, byte_size(Out)).

%% Boundary: a value of EXACTLY the per-value cap (8192 bytes) passes
%% through unclamped; one byte more (8193) is clamped to 8192.
cap_value_exactly_at_limit_not_clamped(_Config) ->
    AtLimit = binary:copy(<<$z>>, 8192),
    OverLimit = binary:copy(<<$z>>, 8193),
    ?assertEqual(AtLimit, erli18n_interp:format(~"%{x}", #{x => AtLimit})),
    ?assertEqual(
        8192, byte_size(erli18n_interp:format(~"%{x}", #{x => OverLimit}))
    ).

%% Boundary: EXACTLY the expansion cap (1024) references all substitute;
%% none is emitted literally.
cap_expansions_exactly_at_limit_all_substituted(_Config) ->
    In = binary:copy(~"%{v}", 1024),
    Out = erli18n_interp:format(In, #{v => ~"-"}),
    ?assertEqual(1024, length(binary:matches(Out, ~"-"))),
    ?assertEqual([], binary:matches(Out, ~"%{v}")).

%% Boundary: a name at the maximum atom length (255 bytes) — within the
%% 256-byte name cap — resolves normally. A 256+ byte name cannot exist as
%% an atom, so 255 is the largest resolvable name; the 257-byte malformed
%% case is covered by cap_oversized_name_is_literal.
name_at_max_atom_length_resolves(_Config) ->
    Name = binary:copy(<<$a>>, 255),
    Atom = binary_to_atom(Name, utf8),
    ?assertEqual(
        ~"OK",
        erli18n_interp:format(<<"%{", Name/binary, "}">>, #{Atom => ~"OK"})
    ).

%% The anti-DoS output cap (65536 bytes) bounds the result regardless of input:
%% once the cap is reached, every kind of trailing token (literal `%`, `%%`,
%% `%X`, a malformed / value / missing / expansion-capped placeholder) is
%% dropped or truncated so the output never exceeds the cap. A literal prefix
%% (not subject to the per-value clamp) fills the buffer to the boundary.
output_capped_across_token_kinds(_Config) ->
    Lit = fun(N) -> binary:copy(<<$x>>, N) end,
    Size = fun(Msgstr, B) -> byte_size(erli18n_interp:format(Msgstr, B)) end,
    %% At exactly the cap, each trailing token is dropped.
    ?assertEqual(65536, Size(<<(Lit(65536))/binary, "%%">>, #{})),
    ?assertEqual(65536, Size(<<(Lit(65536))/binary, "%">>, #{})),
    ?assertEqual(65536, Size(<<(Lit(65536))/binary, "%z">>, #{})),
    ?assertEqual(65536, Size(<<(Lit(65536))/binary, "%{">>, #{})),
    ?assertEqual(65536, Size(<<(Lit(65536))/binary, "%{g}">>, #{g => ~"ZZ"})),
    ?assertEqual(65536, Size(<<(Lit(65536))/binary, "%{miss}">>, #{})),
    %% One byte below the cap, a 2-byte token is truncated to fit exactly.
    ?assertEqual(65536, Size(<<(Lit(65535))/binary, "%{">>, #{})),
    ?assertEqual(65536, Size(<<(Lit(65535))/binary, "%{g}">>, #{g => ~"ZZ"})),
    %% At the cap, a following plain-text run is also dropped (the buffer is
    %% filled to the boundary by eight clamped placeholders first).
    PlainAfterCap = iolist_to_binary([binary:copy(~"%{a}", 8), ~"tail"]),
    ?assertEqual(65536, Size(PlainAfterCap, #{a => binary:copy(<<$y>>, 8192)})),
    %% Past the expansion cap (1024), placeholders emit literally; at the output
    %% cap that literal emission is dropped too.
    Many = iolist_to_binary(lists:duplicate(1025, ~"%{a}")),
    ?assertEqual(65536, Size(Many, #{a => binary:copy(<<$a>>, 64)})),
    %% One byte short of the cap past the expansion cap, the literal placeholder
    %% emission is truncated to fit exactly.
    ExpTrunc = iolist_to_binary([binary:copy(~"%{a}", 1024), binary:copy(<<$z>>, 1023), ~"%{a}"]),
    ?assertEqual(65536, Size(ExpTrunc, #{a => binary:copy(<<$w>>, 63)})),
    ok.

%% Binding values outside the binary/integer/float/atom/valid-iolist surface
%% coerce totally via a bounded fallback rather than crashing.
coerce_non_text_value_fallbacks(_Config) ->
    %% A list with an invalid codepoint -> bounded safe-inspect fallback.
    ?assertEqual(~"[-1]", erli18n_interp:format(~"%{x}", #{x => [-1]})),
    %% An invalid-UTF-8 binary -> re-encoded treating the bytes as latin1
    %% (total for any binary): <<255,254>> -> UTF-8 <<195,191,195,190>>.
    ?assertEqual(
        <<195, 191, 195, 190>>,
        erli18n_interp:format(~"%{x}", #{x => <<255, 254>>})
    ).
