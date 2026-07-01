%%% =====================================================================
%%% Behavior-pinning suite for `erli18n_po` (the PO/POT parser and
%%% serializer).
%%%
%%% Many of the parser's error and escape clauses are easy to assert only
%%% with a WILDCARD reason (`{syntax_error, _, _}`), which lets a tag-swap
%%% or dropped clause pass unnoticed. Each testcase here pins ONE such
%%% clause to its EXACT observable payload through the PUBLIC
%%% `erli18n_po:parse/1`, `dump/1` and `escape_string/1` interface, so a
%%% clause or tag change becomes observable.
%%%
%%% Every assertion holds against the current code. The error oracles use
%%% the EXACT tag/payload (e.g. `{escape_incomplete_utf8, _}`, NOT
%%% `{escape_invalid_utf8, _}`; `content_after_close_quote`, NOT just
%%% `_`), so a clause or tag change in `erli18n_po` is caught here rather
%%% than silently accepted.
%%%
%%% The `escape_string/1` non-UTF-8 TOTALITY property (a lone 0xFF byte)
%%% lives in the companion suite; this suite owns the `\r` escape
%%% partition and every pinned error tag.
%%% =====================================================================
-module(erli18n_po_adequacy_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    escape_string_cr_partition/1,
    escape_string_all_five_escapes_oracle/1,
    unknown_escape_payload_pinned/1,
    content_after_close_quote_pinned/1,
    unterminated_string_pinned/1,
    dangling_backslash_pinned/1,
    escape_incomplete_utf8_pinned/1,
    charset_conversion_utf8_body_pinned/1,
    parse_msgstr_index_malformed_pinned/1,
    absent_msgstr_coerces_empty/1,
    dump_parse_totality_property/1
]).

%% PropEr `?FORALL`/`?LET` generators are statically typed as `term()` by
%% eqwalizer, so each function that binds a generated value to a documented
%% shape (`binary()` here) carries a static `-eqwalizer({nowarn_function, _})`
%% annotation — the same zero-runtime-dep pattern used by the sibling
%% `erli18n_po_props`/`erli18n_po_fuzz` modules.
-eqwalizer({nowarn_function, prop_dump_parse_totality/0}).
-eqwalizer({nowarn_function, adversarial_binary/0}).

all() ->
    [
        escape_string_cr_partition,
        escape_string_all_five_escapes_oracle,
        unknown_escape_payload_pinned,
        content_after_close_quote_pinned,
        unterminated_string_pinned,
        dangling_backslash_pinned,
        escape_incomplete_utf8_pinned,
        charset_conversion_utf8_body_pinned,
        parse_msgstr_index_malformed_pinned,
        absent_msgstr_coerces_empty,
        dump_parse_totality_property
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

%% =========================
%% Helpers
%% =========================

%% A valid header WITH a real `raw` body, so the roundtrip law
%% `parse(dump(C)) =:= {ok, C}` holds for the entries (see `dump/1`
%% moduledoc). Used by the CR roundtrip oracle.
header_map() ->
    #{
        plural_forms => ~"nplurals=2; plural=(n != 1);",
        content_type => ~"text/plain; charset=UTF-8",
        charset => utf8,
        raw => <<
            "Content-Type: text/plain; charset=UTF-8\n"
            "Plural-Forms: nplurals=2; plural=(n != 1);\n"
        >>
    }.

%% The minimal valid header block used to prefix entry-level fixtures, so
%% the charset prepass succeeds and the entry-level error is what surfaces.
minimal_header() ->
    <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
    >>.

%% A fixed valid `.po` that parses to {ok, _} WITH an entry, so the
%% totality property actually feeds a real catalog into `dump/1`.
base_po() ->
    <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
        "msgid \"hello\"\n"
        "msgstr \"world\"\n"
    >>.

%% =========================
%% escape_string/1 dump-direction oracles
%% =========================

%% The carriage-return (`\r`, 0x0D) partition of `escape_string/1`
%% is the ONLY clause that turns a raw CR into the two-byte `\r` sequence
%% (`erli18n_po:escape_string/2` clause for `<<$\r, _>>`). Pin it two ways:
%%
%%   (1) the direct unit oracle `escape_string(~"a\rb") =:= ~"a\\rb"` — if
%%       the CR clause is deleted, the catch-all passes the raw 0x0D
%%       through and this equality fails; and
%%   (2) the round trip `parse(dump(C))` of a catalog whose translation
%%       carries a raw CR must re-emerge byte-identical. With the CR clause
%%       present, `dump/1` escapes the CR to `\r`, which `parse/1` decodes
%%       back to 0x0D. Delete the clause and `dump/1` emits a raw CR, which
%%       `split_lines/1` folds to LF on reparse — corrupting (or splitting)
%%       the value, so the entries diverge.
escape_string_cr_partition(_Config) ->
    ?assertEqual(~"a\\rb", erli18n_po:escape_string(~"a\rb")),
    Catalog = #{
        header => header_map(),
        entries => [{singular, undefined, ~"k", ~"a\rb"}]
    },
    Dumped = erli18n_po:dump(Catalog),
    {ok, C2} = erli18n_po:parse(Dumped),
    ?assertEqual(
        [{singular, undefined, ~"k", ~"a\rb"}],
        maps:get(entries, C2)
    ).

%% A direct oracle on the dump-direction
%% escaper for ALL FIVE escapes plus a passthrough byte. The string mixes
%% `"`, `\n`, `\t`, `\\` and `\r`; the result must be the byte-exact
%% escaped form. Each of the five `escape_string/2` clauses is corruptible
%% independently — a dropped or tag-swapped clause changes exactly one
%% two-byte segment of the output, which this byte-for-byte equality
%% catches.
escape_string_all_five_escapes_oracle(_Config) ->
    Input = <<"a\"b\nc\td\\e\rf">>,
    Expected = <<"a\\\"b\\nc\\td\\\\e\\rf">>,
    ?assertEqual(Expected, erli18n_po:escape_string(Input)).

%% =========================
%% Pinned syntax-error reasons (parse/1)
%% =========================

%% An unknown escape selector (`\q`) must surface the
%% EXACT offending byte in the payload — `{unknown_escape, $q}` — not a
%% wildcarded reason. The `decode_escape(<<C, _>>)` catch-all carries `C`;
%% pinning `$q` (= 113) holds the payload to the actual offending byte
%% rather than a dropped or constant value.
unknown_escape_payload_pinned(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"k\"\n"
        "msgstr \"a\\qb\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, {unknown_escape, $q}}},
        erli18n_po:parse(Bin)
    ).

%% A non-whitespace byte after the closing quote
%% (`msgid "a"b`) takes the FALSE branch of `is_only_trailing_ws/1` and
%% must yield the typed `content_after_close_quote` reason. Pinning the
%% exact tag distinguishes it from any other syntax reason.
content_after_close_quote_pinned(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"a\"b\n"
        "msgstr \"y\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, content_after_close_quote}},
        erli18n_po:parse(Bin)
    ).

%% A quoted value that never closes
%% (`msgid "abc` with no closing quote) empties `decode_chars/2` to its
%% `<<>>` clause, which must be `unterminated_string` — distinct from
%% `dangling_backslash` and `content_after_close_quote`.
unterminated_string_pinned(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"abc\n"
        "msgstr \"y\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, unterminated_string}},
        erli18n_po:parse(Bin)
    ).

%% A value ending in a lone backslash
%% (`msgid "x\`) reaches `decode_escape(<<>>)`, which must be
%% `dangling_backslash` — distinct from `unterminated_string`. Note the
%% backslash is consumed BEFORE the empty-string clause, so the two reasons
%% must not collapse.
dangling_backslash_pinned(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"x\\\n"
        "msgstr \"y\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, dangling_backslash}},
        erli18n_po:parse(Bin)
    ).

%% A lone UTF-8 LEAD-byte escape (`\xC3`, the
%% start of a 2-byte sequence with no continuation) in a UTF-8 catalog must
%% surface `{escape_incomplete_utf8, _}` — the `{incomplete, _, _}` arm of
%% `transcode_escape_bytes/2`, OBSERVABLY DISTINCT from the
%% `{escape_invalid_utf8, _}` arm reported for `\xFF`.
%% Asserting the exact tag distinguishes the two arms.
escape_incomplete_utf8_pinned(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"k\"\n"
        "msgstr \"x\\xC3\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, {escape_incomplete_utf8, _}}},
        erli18n_po:parse(Bin)
    ).

%% A UTF-8-declared body whose final byte is a
%% bare lead byte (0xC3) fails the whole-body UTF-8 gate in
%% `normalize_input/2`, which must surface `{charset_conversion, ~"UTF-8",
%% _}`. The label is pinned (`~"UTF-8"`) so a label swap fails; the trailing
%% byte is in the literal body, so the gate (not a per-escape decode) is the
%% rejecter.
charset_conversion_utf8_body_pinned(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\n"
        "msgid \"x",
        16#C3
    >>,
    ?assertMatch(
        {error, {charset_conversion, ~"UTF-8", _}},
        erli18n_po:parse(Bin)
    ).

%% A malformed `msgstr[N]` index — a non-digit
%% inside the brackets (`msgstr[0x9]`) — hits the bare-`error` catch-all of
%% `parse_msgstr_index/2`, which `classify_line/2` maps to the typed
%% `expected_msgstr_string` reason. Pin that exact reason: the malformed
%% index must be REJECTED (never silently accepted as index 0), and the
%% reason distinguishes it from the `index_too_long` arm.
parse_msgstr_index_malformed_pinned(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"a\"\n"
        "msgid_plural \"b\"\n"
        "msgstr[0x9] \"z\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, expected_msgstr_string}},
        erli18n_po:parse(Bin)
    ).

%% A `msgid` block with NO `msgstr` line at all
%% (`undefined`, not an explicit `""`) must coerce to `<<>>` via the
%% `undefined -> <<>>` arm of `emit_entry/2`, yielding
%% `{singular, undefined, <<"x">>, <<>>}`. This is a DIFFERENT code path
%% from the explicit-empty case; if the arm kept `undefined`, the entry's
%% 4th element would be `undefined` and this exact-equality assertion
%% fails.
absent_msgstr_coerces_empty(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"x\"\n"
        "\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, ~"x", <<>>}],
        maps:get(entries, Catalog)
    ).

%% =========================
%% dump∘parse totality
%% =========================

%% `dump/1` is documented total over every catalog `parse/1` can actually
%% emit. This property feeds adversarial bytes through `parse/1` and, on
%% every `{ok, C}`, asserts `is_binary(dump(C))` — `dump/1` must never
%% raise on a catalog the parser produced.
dump_parse_totality_property(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_dump_parse_totality(),
            [{numtests, 200}, {to_file, user}]
        )
    ).

prop_dump_parse_totality() ->
    ?FORALL(
        BGen,
        adversarial_binary(),
        begin
            B = BGen,
            case erli18n_po:parse(B) of
                {ok, C} ->
                    is_binary(erli18n_po:dump(C));
                {error, _} ->
                    %% Parser refusal is fine — the totality claim only
                    %% constrains the `{ok, _}` case.
                    true
            end
        end
    ).

%% A mix of raw random bytes, the fixed valid catalog (guarantees `dump/1`
%% is exercised on a real parsed catalog), and a valid catalog with a random
%% byte suffix (so quasi-valid inputs that still parse `{ok, _}` reach
%% `dump/1`).
adversarial_binary() ->
    oneof([
        binary(),
        exactly(base_po()),
        ?LET(Suffix, binary(), <<(base_po())/binary, Suffix/binary>>)
    ]).
