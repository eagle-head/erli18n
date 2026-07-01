-module(erli18n_po_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    header_minimal_utf8/1,
    header_unsupported_charset/1,
    header_unsupported_charset_space_before_colon/1,
    header_supported_charset_space_before_colon/1,
    header_unsupported_charset_tab_before_colon/1,
    header_latin1/1,
    header_missing_content_type/1,
    bom_utf8_stripped/1,
    single_entry_singular/1,
    single_entry_with_context/1,
    plural_entry/1,
    plural_count_mismatch_missing/1,
    plural_count_mismatch_extra/1,
    fuzzy_dropped_by_default/1,
    fuzzy_included_with_opt/1,
    obsolete_skipped/1,
    escape_sequences/1,
    multiline_string/1,
    empty_msgstr_preserved/1,
    empty_msgstr_plural_preserved/1,
    dump_roundtrip_singular/1,
    dump_roundtrip_plural/1,
    dump_plural_msgid_plural_undefined_fallback/1,
    dump_roundtrip_with_context/1,
    comments_skipped/1,
    flags_other_than_fuzzy_ignored/1,
    parse_file_ok/1,
    parse_file_missing/1,
    hex_and_octal_escapes/1,
    hex_escape_high_byte_utf8_rejected/1,
    hex_escape_latin1_transcodes/1,
    hex_escape_utf8_multibyte_ok/1,
    octal_escape_high_byte/1,
    ascii_escape_high_byte_rejected/1,
    degenerate_plural_nplurals_1/1,
    duplicate_header_dropped/1,
    %% Parser branch tests
    charset_alias_utf8_no_hyphen/1,
    charset_alias_iso8859_1_no_dashes/1,
    charset_alias_latin_hyphen_1/1,
    charset_alias_us_ascii/1,
    charset_alias_ascii_short/1,
    charset_with_trailing_semicolon/1,
    charset_empty_value_defaults_utf8/1,
    us_ascii_pure_ascii_body/1,
    us_ascii_non_ascii_byte_rejected/1,
    header_msgstr_comment_continuation/1,
    header_msgstr_blank_continuation/1,
    msgctxt_multiline_continuation/1,
    msgid_plural_multiline_continuation/1,
    msgstr_index_multiline_continuation/1,
    msgctxt_keyword_without_string/1,
    msgctxt_keyword_with_tab/1,
    unexpected_continuation_at_top/1,
    continuation_invalid_quote_decode/1,
    trailing_whitespace_after_close_quote/1,
    escape_backspace/1,
    escape_formfeed/1,
    escape_vertical_tab/1,
    escape_alert_bell/1,
    escape_forward_slash/1,
    escape_question_mark/1,
    escape_single_quote/1,
    invalid_hex_escape_non_hex_digit/1,
    msgctxt_before_header_prepass/1,
    msgstr_n_before_header_prepass/1,
    msgid_plural_before_header_prepass/1,
    header_line_without_colon_skipped/1,
    plural_forms_nplurals_without_equals/1,
    dump_synthetic_catalog_empty_raw/1,
    dump_catalog_missing_raw_key/1,
    msgctxt_bare_keyword_before_header_prepass/1,
    msgid_plural_bare_keyword_before_header_prepass/1,
    tab_indented_line_in_main_parser/1,
    line_endings_lf_crlf_lone_cr_parse_identically/1,
    parse_rejects_malformed_escapes_and_index/1,
    plural_nplurals_header_dos_bounded/1,
    many_continuation_lines_join_correctly_and_bounded/1
]).

all() ->
    [
        header_minimal_utf8,
        header_unsupported_charset,
        header_unsupported_charset_space_before_colon,
        header_supported_charset_space_before_colon,
        header_unsupported_charset_tab_before_colon,
        header_latin1,
        header_missing_content_type,
        bom_utf8_stripped,
        single_entry_singular,
        single_entry_with_context,
        plural_entry,
        plural_count_mismatch_missing,
        plural_count_mismatch_extra,
        fuzzy_dropped_by_default,
        fuzzy_included_with_opt,
        obsolete_skipped,
        escape_sequences,
        multiline_string,
        empty_msgstr_preserved,
        empty_msgstr_plural_preserved,
        dump_roundtrip_singular,
        dump_roundtrip_plural,
        dump_plural_msgid_plural_undefined_fallback,
        dump_roundtrip_with_context,
        comments_skipped,
        flags_other_than_fuzzy_ignored,
        parse_file_ok,
        parse_file_missing,
        hex_and_octal_escapes,
        hex_escape_high_byte_utf8_rejected,
        hex_escape_latin1_transcodes,
        hex_escape_utf8_multibyte_ok,
        octal_escape_high_byte,
        ascii_escape_high_byte_rejected,
        degenerate_plural_nplurals_1,
        duplicate_header_dropped,
        %% Parser branch tests
        charset_alias_utf8_no_hyphen,
        charset_alias_iso8859_1_no_dashes,
        charset_alias_latin_hyphen_1,
        charset_alias_us_ascii,
        charset_alias_ascii_short,
        charset_with_trailing_semicolon,
        charset_empty_value_defaults_utf8,
        us_ascii_pure_ascii_body,
        us_ascii_non_ascii_byte_rejected,
        header_msgstr_comment_continuation,
        header_msgstr_blank_continuation,
        msgctxt_multiline_continuation,
        msgid_plural_multiline_continuation,
        msgstr_index_multiline_continuation,
        msgctxt_keyword_without_string,
        msgctxt_keyword_with_tab,
        unexpected_continuation_at_top,
        continuation_invalid_quote_decode,
        trailing_whitespace_after_close_quote,
        escape_backspace,
        escape_formfeed,
        escape_vertical_tab,
        escape_alert_bell,
        escape_forward_slash,
        escape_question_mark,
        escape_single_quote,
        invalid_hex_escape_non_hex_digit,
        msgctxt_before_header_prepass,
        msgstr_n_before_header_prepass,
        msgid_plural_before_header_prepass,
        header_line_without_colon_skipped,
        plural_forms_nplurals_without_equals,
        dump_synthetic_catalog_empty_raw,
        dump_catalog_missing_raw_key,
        msgctxt_bare_keyword_before_header_prepass,
        msgid_plural_bare_keyword_before_header_prepass,
        tab_indented_line_in_main_parser,
        line_endings_lf_crlf_lone_cr_parse_identically,
        parse_rejects_malformed_escapes_and_index,
        plural_nplurals_header_dos_bounded,
        many_continuation_lines_join_correctly_and_bounded
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

%% =========================
%% Helpers
%% =========================

minimal_header() ->
    <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
    >>.

%% =========================
%% Header tests
%% =========================

%% Header with valid UTF-8 charset parses OK.
header_minimal_utf8(_Config) ->
    {ok, Catalog} = erli18n_po:parse(minimal_header()),
    Header = maps:get(header, Catalog),
    ?assertEqual(utf8, maps:get(charset, Header)),
    ?assertEqual(
        ~"nplurals=2; plural=(n != 1);",
        maps:get(plural_forms, Header)
    ),
    ?assertEqual([], maps:get(entries, Catalog)).

%% Unsupported charset returns structured error, no entries
%% emitted.
header_unsupported_charset(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=SHIFT_JIS\\n\"\n"
    >>,
    ?assertEqual(
        {error, {unsupported_charset, ~"SHIFT_JIS"}},
        erli18n_po:parse(Bin)
    ).

%% A `Content-Type` header with a SINGLE SPACE before the colon must
%% surface a structured `{error, {unsupported_charset, _}}` for an
%% unsupported charset — never a `badmatch` crash. This pins the two
%% charset detection paths to AGREE on a whitespace-tolerant field parse:
%% if the prepass `find_charset_line` required the literal `content-type:`
%% substring (no space) it would miss this line and fall through to the
%% default utf8, while `build_header`'s field parser trims the key to
%% `content-type`, classifies the charset, and would then hit `{error,_}`
%% on the non-exhaustive `{ok,Charset} =` match — a crash in the loader
%% gen_server.
header_unsupported_charset_space_before_colon(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type : text/plain; charset=Shift_JIS\\n\"\n"
    >>,
    ?assertEqual(
        {error, {unsupported_charset, ~"Shift_JIS"}},
        erli18n_po:parse(Bin)
    ).

%% Companion to the above: a SUPPORTED charset with a space before the
%% colon must parse OK and detect the declared charset (latin1 here),
%% pinning the prepass and `build_header` to the same whitespace-tolerant
%% field parse. If the prepass missed the spaced `Content-Type ` line it
%% would default to utf8 and the charset would be silently wrong.
header_supported_charset_space_before_colon(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type : text/plain; charset=ISO-8859-1\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(latin1, maps:get(charset, maps:get(header, Catalog))).

%% A TAB before the colon is another adversarial spacing a literal
%% prepass matcher would miss. Same contract: structured error, no crash.
header_unsupported_charset_tab_before_colon(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type\t: text/plain; charset=Shift_JIS\\n\"\n"
    >>,
    ?assertEqual(
        {error, {unsupported_charset, ~"Shift_JIS"}},
        erli18n_po:parse(Bin)
    ).

%% ISO-8859-1 body bytes are converted to UTF-8 internally.
header_latin1(_Config) ->
    %% "é" in latin1 is the single byte 16#E9. Embed it raw in a binary
    %% header and entry.
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=ISO-8859-1\\n\"\n"
        "\n"
        "msgid \"Caf",
        16#E9,
        "\"\n"
        "msgstr \"Caf",
        16#E9,
        "\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, undefined, Msgid, Translation}] =
        maps:get(entries, Catalog),
    %% "é" in UTF-8 is two bytes: 0xC3, 0xA9.
    ?assertEqual(<<"Caf", 16#C3, 16#A9>>, Msgid),
    ?assertEqual(<<"Caf", 16#C3, 16#A9>>, Translation),
    ?assertEqual(latin1, maps:get(charset, maps:get(header, Catalog))).

%% Header without Content-Type defaults to utf8.
header_missing_content_type(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    Header = maps:get(header, Catalog),
    ?assertEqual(utf8, maps:get(charset, Header)).

%% UTF-8 BOM is silently stripped.
bom_utf8_stripped(_Config) ->
    Bin =
        <<16#EF, 16#BB, 16#BF, (minimal_header())/binary,
            "msgid \"Hello\"\n"
            "msgstr \"Oi\"\n">>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, undefined, ~"Hello", ~"Oi"}] =
        maps:get(entries, Catalog).

%% =========================
%% Entry tests
%% =========================

single_entry_singular(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"Hello\"\n"
        "msgstr \"Oi\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, ~"Hello", ~"Oi"}],
        maps:get(entries, Catalog)
    ).

%% msgctxt is stored as a separate field, never glued.
single_entry_with_context(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgctxt \"menu\"\n"
        "msgid \"File\"\n"
        "msgstr \"Fichier\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, ~"menu", ~"File", ~"Fichier"}],
        maps:get(entries, Catalog)
    ).

plural_entry(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"tree\"\n"
        "msgid_plural \"trees\"\n"
        "msgstr[0] \"arbre\"\n"
        "msgstr[1] \"arbres\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [
            {plural, undefined, ~"tree", ~"trees", [
                {0, ~"arbre"}, {1, ~"arbres"}
            ]}
        ],
        maps:get(entries, Catalog)
    ).

%% Header declares nplurals=3, entry has [0, 1, 3] — error,
%% no entries emitted.
plural_count_mismatch_missing(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=3; plural=0;\\n\"\n"
        "\n"
        "msgid \"Tree\"\n"
        "msgid_plural \"Trees\"\n"
        "msgstr[0] \"a\"\n"
        "msgstr[1] \"b\"\n"
        "msgstr[3] \"d\"\n"
    >>,
    ?assertEqual(
        {error, {plural_count_mismatch, ~"Tree", 3, [0, 1, 3]}},
        erli18n_po:parse(Bin)
    ).

%% Extra plural index also rejected atomically.
plural_count_mismatch_extra(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
        "msgid \"Tree\"\n"
        "msgid_plural \"Trees\"\n"
        "msgstr[0] \"a\"\n"
        "msgstr[1] \"b\"\n"
        "msgstr[2] \"c\"\n"
    >>,
    ?assertEqual(
        {error, {plural_count_mismatch, ~"Tree", 2, [0, 1, 2]}},
        erli18n_po:parse(Bin)
    ).

%% Fuzzy entries dropped by default.
fuzzy_dropped_by_default(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "#, fuzzy\n"
        "msgid \"x\"\n"
        "msgstr \"y\"\n"
        "\n"
        "msgid \"a\"\n"
        "msgstr \"b\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, ~"a", ~"b"}],
        maps:get(entries, Catalog)
    ).

%% include_fuzzy => true preserves fuzzy entries.
fuzzy_included_with_opt(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "#, fuzzy\n"
        "msgid \"x\"\n"
        "msgstr \"y\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin, #{include_fuzzy => true}),
    ?assertEqual(
        [{singular, undefined, ~"x", ~"y"}],
        maps:get(entries, Catalog)
    ).

%% Obsolete entries are skipped silently.
obsolete_skipped(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"alive\"\n"
        "msgstr \"vivant\"\n"
        "\n"
        "#~ msgid \"old\"\n"
        "#~ msgstr \"ancien\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, ~"alive", ~"vivant"}],
        maps:get(entries, Catalog)
    ).

escape_sequences(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"a\\nb\\tc\\\"d\\\\e\"\n"
        "msgstr \"x\\nx\\tx\\\"x\\\\x\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, undefined, Msgid, Translation}] =
        maps:get(entries, Catalog),
    ?assertEqual(~"a\nb\tc\"d\\e", Msgid),
    ?assertEqual(~"x\nx\tx\"x\\x", Translation).

multiline_string(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"\"\n"
        "\"first \"\n"
        "\"second\"\n"
        "msgstr \"\"\n"
        "\"trad \"\n"
        "\"end\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, undefined, Msgid, Translation}] =
        maps:get(entries, Catalog),
    ?assertEqual(~"first second", Msgid),
    ?assertEqual(~"trad end", Translation).

%% Parser preserves empty msgstr verbatim; fallback is the
%% lookup's job.
empty_msgstr_preserved(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"Hello\"\n"
        "msgstr \"\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, ~"Hello", <<>>}],
        maps:get(entries, Catalog)
    ).

empty_msgstr_plural_preserved(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"tree\"\n"
        "msgid_plural \"trees\"\n"
        "msgstr[0] \"\"\n"
        "msgstr[1] \"\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{plural, undefined, ~"tree", ~"trees", [{0, <<>>}, {1, <<>>}]}],
        maps:get(entries, Catalog)
    ).

%% =========================
%% Roundtrip tests
%% =========================

dump_roundtrip_singular(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"Hello\"\n"
        "msgstr \"Oi\"\n"
    >>,
    {ok, C1} = erli18n_po:parse(Bin),
    Dumped = erli18n_po:dump(C1),
    {ok, C2} = erli18n_po:parse(Dumped),
    %% Header field charset must match. Entries must be identical.
    ?assertEqual(maps:get(entries, C1), maps:get(entries, C2)),
    ?assertEqual(
        maps:get(charset, maps:get(header, C1)),
        maps:get(charset, maps:get(header, C2))
    ).

dump_roundtrip_plural(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"tree\"\n"
        "msgid_plural \"trees\"\n"
        "msgstr[0] \"arbre\"\n"
        "msgstr[1] \"arbres\"\n"
    >>,
    {ok, C1} = erli18n_po:parse(Bin),
    Dumped = erli18n_po:dump(C1),
    %% The dumped `.po` must carry the REAL `msgid_plural` form
    %% (`trees`), not the singular `msgid` (`tree`).
    ?assertNotEqual(
        nomatch, binary:match(Dumped, ~"msgid_plural \"trees\"")
    ),
    {ok, C2} = erli18n_po:parse(Dumped),
    ?assertEqual(maps:get(entries, C1), maps:get(entries, C2)),
    %% And the retained `msgid_plural` survives the full cycle.
    [{plural, undefined, ~"tree", ~"trees", _}] =
        maps:get(entries, C2).

%% When a parsed plural entry carries `undefined` as its
%% `msgid_plural` (a degenerate catalog with `msgstr[N]` lines but no
%% explicit `msgid_plural` source line — built here in-memory), `dump/1`
%% falls back to the singular `Msgid` for that slot rather than crashing.
dump_plural_msgid_plural_undefined_fallback(_Config) ->
    Catalog = #{
        header => #{
            plural_forms => ~"nplurals=2; plural=(n != 1);",
            charset => utf8,
            raw => <<
                "Content-Type: text/plain; charset=UTF-8\n"
                "Plural-Forms: nplurals=2; plural=(n != 1);\n"
            >>
        },
        entries => [
            {plural, undefined, ~"tree", undefined, [
                {0, ~"arbre"}, {1, ~"arbres"}
            ]}
        ]
    },
    Dumped = erli18n_po:dump(Catalog),
    %% Fallback: singular `msgid` reused as the `msgid_plural` source.
    ?assertNotEqual(
        nomatch, binary:match(Dumped, ~"msgid_plural \"tree\"")
    ),
    {ok, C2} = erli18n_po:parse(Dumped),
    [{plural, undefined, ~"tree", ~"tree", _}] =
        maps:get(entries, C2).

dump_roundtrip_with_context(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgctxt \"menu\"\n"
        "msgid \"File\"\n"
        "msgstr \"Fichier\"\n"
    >>,
    {ok, C1} = erli18n_po:parse(Bin),
    Dumped = erli18n_po:dump(C1),
    {ok, C2} = erli18n_po:parse(Dumped),
    ?assertEqual(maps:get(entries, C1), maps:get(entries, C2)).

%% =========================
%% Misc parser behavior
%% =========================

comments_skipped(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "# translator note\n"
        "#. extracted comment\n"
        "#: src/foo.erl:42\n"
        "#| msgid \"previous\"\n"
        "msgid \"Hello\"\n"
        "msgstr \"Oi\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, ~"Hello", ~"Oi"}],
        maps:get(entries, Catalog)
    ).

flags_other_than_fuzzy_ignored(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "#, c-format\n"
        "msgid \"x %s\"\n"
        "msgstr \"y %s\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, ~"x %s", ~"y %s"}],
        maps:get(entries, Catalog)
    ).

parse_file_ok(Config) ->
    PrivDir = ?config(priv_dir, Config),
    Path = filename:join(PrivDir, "ok.po"),
    Bin = <<
        (minimal_header())/binary,
        "msgid \"Hello\"\n"
        "msgstr \"Oi\"\n"
    >>,
    ok = file:write_file(Path, Bin),
    {ok, Catalog} = erli18n_po:parse_file(Path),
    ?assertEqual(
        [{singular, undefined, ~"Hello", ~"Oi"}],
        maps:get(entries, Catalog)
    ).

parse_file_missing(_Config) ->
    Path =
        "/tmp/erli18n_po_does_not_exist_" ++
            integer_to_list(erlang:unique_integer([positive])) ++ ".po",
    ?assertMatch(
        {error, {file_error, enoent}},
        erli18n_po:parse_file(Path)
    ).

hex_and_octal_escapes(_Config) ->
    %% \x41 = 'A', \101 = 'A'. Use them inside ASCII-safe content.
    Bin = <<
        (minimal_header())/binary,
        "msgid \"\\x41\\101\"\n"
        "msgstr \"AA\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, undefined, Msgid, _}] = maps:get(entries, Catalog),
    ?assertEqual(~"AA", Msgid).

%% In a UTF-8 catalog the escape byte is interpreted in the declared
%% charset's code space and transcoded, so a lone high-byte hex escape
%% (`\xFF`) is not valid UTF-8: parse surfaces a STRUCTURED
%% `{escape_invalid_utf8, _}` syntax error instead of storing an
%% invalid-UTF-8 translation (`<<255>>` spliced raw past the UTF-8 gate),
%% which would then crash downstream unicode-aware ops with badarg. This
%% is parity with msgfmt's "invalid multibyte sequence" rejection.
hex_escape_high_byte_utf8_rejected(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"k\"\n"
        "msgstr \"x\\xFFy\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, {escape_invalid_utf8, _}}},
        erli18n_po:parse(Bin)
    ).

%% In an ISO-8859-1 catalog the escape byte is a Latin-1 codepoint and
%% MUST transcode to UTF-8 like any natural byte. `\xFF` means U+00FF,
%% whose UTF-8 encoding is <<195,191>> — NOT the raw byte <<255>>. A
%% natural latin1 byte 0xE9 (é) in the same field must coexist as
%% <<195,169>>. This is the gettext two-phase model: escape bytes live in
%% the declared charset's code space.
hex_escape_latin1_transcodes(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=ISO-8859-1\\n\"\n"
        "\n"
        "msgid \"k\"\n"
        "msgstr \"",
        16#E9,
        "\\xFFz\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, undefined, ~"k", Translation}] =
        maps:get(entries, Catalog),
    %% é = <<195,169>> (natural byte transcoded) | \xFF = U+00FF =
    %% <<195,191>> (escape transcoded) | z = <<122>>.
    ?assertEqual(<<16#C3, 16#A9, 16#C3, 16#BF, $z>>, Translation),
    %% The output is valid UTF-8 (the invariant enforced here).
    ?assert(is_binary(unicode:characters_to_binary(Translation, utf8, utf8))).

%% A UTF-8 catalog may legitimately spell a multibyte
%% codepoint as CONSECUTIVE high-byte escapes (`\xC3\xBF` = U+00FF). These
%% must be grouped into one raw run and validated as UTF-8 together,
%% yielding <<195,191>> — preserving gettext parity for valid escapes
%% while rejecting only invalid ones.
hex_escape_utf8_multibyte_ok(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"k\"\n"
        "msgstr \"x\\xC3\\xBFy\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, undefined, ~"k", Translation}] =
        maps:get(entries, Catalog),
    ?assertEqual(<<$x, 16#C3, 16#BF, $y>>, Translation),
    ?assert(is_binary(unicode:characters_to_binary(Translation, utf8, utf8))).

%% Octal `\377` is the byte 0xFF and must behave exactly like
%% `\xFF` in every charset — rejected (lone) in UTF-8, transcoded in
%% latin1.
octal_escape_high_byte(_Config) ->
    Utf8Bin = <<
        (minimal_header())/binary,
        "msgid \"k\"\n"
        "msgstr \"x\\377y\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, {escape_invalid_utf8, _}}},
        erli18n_po:parse(Utf8Bin)
    ),
    Latin1Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=ISO-8859-1\\n\"\n"
        "\n"
        "msgid \"k\"\n"
        "msgstr \"\\377z\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Latin1Bin),
    [{singular, undefined, ~"k", Translation}] =
        maps:get(entries, Catalog),
    ?assertEqual(<<16#C3, 16#BF, $z>>, Translation).

%% In a US-ASCII catalog a high byte is OUTSIDE the charset
%% entirely. The escape characters (`\`,`x`,`F`,`F`) are all ASCII so the
%% body passes the US-ASCII gate, but the decoded byte 0xFF >= 0x80 is not
%% representable — surface a structured `{invalid_escape_charset, ...}`
%% error rather than emit a non-ASCII byte in an ASCII catalog.
ascii_escape_high_byte_rejected(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=US-ASCII\\n\"\n"
        "\n"
        "msgid \"k\"\n"
        "msgstr \"x\\xFFy\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, {invalid_escape_charset, us_ascii, 16#FF}}},
        erli18n_po:parse(Bin)
    ).

%% nplurals=1 (Japanese-style); single msgstr[0] is enough.
degenerate_plural_nplurals_1(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=1; plural=0;\\n\"\n"
        "\n"
        "msgid \"Fish\"\n"
        "msgid_plural \"Fishes\"\n"
        "msgstr[0] \"sakana\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{plural, undefined, ~"Fish", ~"Fishes", [{0, ~"sakana"}]}],
        maps:get(entries, Catalog)
    ).

duplicate_header_dropped(_Config) ->
    %% Two header entries (msgid ""). The first wins; the second is
    %% silently dropped.
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=ISO-8859-1\\n\"\n"
        "\n"
        "msgid \"Hello\"\n"
        "msgstr \"Oi\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    Header = maps:get(header, Catalog),
    %% The first header (UTF-8) wins for the conversion pass; the second
    %% header entry is dropped from entries.
    ?assertEqual(utf8, maps:get(charset, Header)),
    ?assertEqual(
        [{singular, undefined, ~"Hello", ~"Oi"}],
        maps:get(entries, Catalog)
    ).

%% =========================
%% Parser branch helpers
%% =========================

po_with_charset(Charset) ->
    %% Build a header with a custom charset string (raw bytes, no escape
    %% sequences). Exercises charset alias mapping.
    iolist_to_binary(
        [
            <<
                "msgid \"\"\n"
                "msgstr \"\"\n"
                "\"Content-Type: text/plain; charset="
            >>,
            Charset,
            <<
                "\\n\"\n"
                "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
            >>
        ]
    ).

po_with_entry(Msgid, Msgstr) ->
    iolist_to_binary(
        [
            minimal_header(),
            ~"msgid \"",
            Msgid,
            <<"\"\n", "msgstr \"">>,
            Msgstr,
            ~"\"\n"
        ]
    ).

%% =========================
%% Parser branch tests
%% =========================

%% Charset alias "utf8" (no hyphen) normalizes to utf8.
charset_alias_utf8_no_hyphen(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(~"utf8")),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% Charset alias "iso8859-1" (no dash between iso and 8859)
%% normalizes to latin1.
charset_alias_iso8859_1_no_dashes(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(~"iso8859-1")),
    ?assertEqual(latin1, maps:get(charset, maps:get(header, Catalog))).

%% Charset alias "latin-1" normalizes to latin1.
charset_alias_latin_hyphen_1(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(~"latin-1")),
    ?assertEqual(latin1, maps:get(charset, maps:get(header, Catalog))).

%% Charset alias "us-ascii" normalizes to us_ascii.
charset_alias_us_ascii(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(~"us-ascii")),
    ?assertEqual(us_ascii, maps:get(charset, maps:get(header, Catalog))).

%% Charset alias "ascii" (short form) normalizes to us_ascii.
charset_alias_ascii_short(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(~"ascii")),
    ?assertEqual(us_ascii, maps:get(charset, maps:get(header, Catalog))).

%% extract_charset_token hits the separator branch when the charset
%% value is followed by a semicolon parameter list (e.g.
%% "charset=utf-8; boundary=foo"). After ";" the token finalizes.
charset_with_trailing_semicolon(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=utf-8; boundary=x\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% finalize_token(<<>>) -> undefined fires when charset has an empty
%% value (e.g. "charset=" immediately followed by separator). The
%% prepass returns {ok, utf8} via the undefined branch.
charset_empty_value_defaults_utf8(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=; foo=bar\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% A us-ascii body with only ASCII bytes validates ok and passes
%% through.
us_ascii_pure_ascii_body(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=US-ASCII\\n\"\n"
        "\n"
        "msgid \"hello\"\n"
        "msgstr \"world\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(us_ascii, maps:get(charset, maps:get(header, Catalog))),
    ?assertEqual(
        [{singular, undefined, ~"hello", ~"world"}],
        maps:get(entries, Catalog)
    ).

%% A us-ascii body with a byte > 127 is rejected with the
%% charset_conversion error.
us_ascii_non_ascii_byte_rejected(_Config) ->
    %% 16#C3 = 195 (> 127), illegal in US-ASCII.
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=US-ASCII\\n\"\n"
        "\n"
        "msgid \"x",
        16#C3,
        "\"\n"
        "msgstr \"y\"\n"
    >>,
    ?assertMatch(
        {error, {charset_conversion, ~"US-ASCII", _}},
        erli18n_po:parse(Bin)
    ).

%% collect_header_msgstr hits the comment branch when a comment line
%% appears between the header msgid "" and msgstr "".
header_msgstr_comment_continuation(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "# inserted translator comment between msgid and msgstr\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% The blank branch in collect_header_msgstr: a blank line between the
%% header msgid and msgstr is skipped and the header still parses.
header_msgstr_blank_continuation(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% msgctxt spread across multiple continuation lines.
msgctxt_multiline_continuation(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgctxt \"\"\n"
        "\"line1 \"\n"
        "\"line2\"\n"
        "msgid \"x\"\n"
        "msgstr \"y\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, ~"line1 line2", ~"x", ~"y"}],
        maps:get(entries, Catalog)
    ).

%% msgid_plural spread across multiple continuation lines.
msgid_plural_multiline_continuation(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"tree\"\n"
        "msgid_plural \"\"\n"
        "\"long \"\n"
        "\"trees\"\n"
        "msgstr[0] \"a\"\n"
        "msgstr[1] \"b\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{plural, undefined, ~"tree", MsgidPlural, Plurals}] =
        maps:get(entries, Catalog),
    ?assertEqual(~"long trees", MsgidPlural),
    ?assertEqual([{0, ~"a"}, {1, ~"b"}], Plurals).

%% msgstr[N] spread across continuation lines. The append branch for
%% {msgstr, Idx} pops the head and reconcatenates.
msgstr_index_multiline_continuation(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"tree\"\n"
        "msgid_plural \"trees\"\n"
        "msgstr[0] \"first \"\n"
        "\"continued\"\n"
        "msgstr[1] \"b\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{plural, undefined, ~"tree", ~"trees", Plurals}] =
        maps:get(entries, Catalog),
    ?assertEqual([{0, ~"first continued"}, {1, ~"b"}], Plurals).

%% A msgctxt keyword with no following quoted string returns a syntax
%% error in the main parser pass.
msgctxt_keyword_without_string(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgctxt\n"
        "msgid \"x\"\n"
        "msgstr \"y\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, expected_msgctxt_string}},
        erli18n_po:parse(Bin)
    ).

%% strip_keyword_space handles tab whitespace after the keyword
%% (msgctxt followed by a tab then the quoted string).
msgctxt_keyword_with_tab(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgctxt\t\"ctx\"\n"
        "msgid \"x\"\n"
        "msgstr \"y\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, ~"ctx", ~"x", ~"y"}],
        maps:get(entries, Catalog)
    ).

%% A quoted-string continuation line appearing before any keyword has
%% set last_field is a syntax error.
unexpected_continuation_at_top(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "\"orphan continuation\"\n"
        "msgid \"x\"\n"
        "msgstr \"y\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, unexpected_continuation}},
        erli18n_po:parse(Bin)
    ).

%% decode_quoted_string returns {error, expected_quote} only when its
%% input does not start with $", but every caller guarantees a leading
%% $", so that branch is defensive. The callers of decode_quoted_string
%% are:
%%   - handle_string_field via classify_line: strip_keyword_space filters
%%     non-quote inputs to "error" before decode_quoted_string runs.
%%   - consume_continuations (prepass): passes Trimmed, which starts
%%     with $".
%%   - collect_header_msgstr (prepass): receives Content from
%%     strip_keyword_space, which guarantees a leading $".
%%   - the decode_chars continuation in classify_line: passes raw bytes
%%     that start with $".
%% The closest reachable failure is a malformed continuation whose decode
%% fails on an invalid escape, exercising decode_quoted_string's error
%% return path from a main-pass continuation line.
continuation_invalid_quote_decode(_Config) ->
    %% A malformed continuation that fails decode (invalid escape) —
    %% exercises the error return path of decode_quoted_string from a
    %% main-pass continuation line.
    Bin = <<
        (minimal_header())/binary,
        "msgid \"x\"\n"
        "msgstr \"first\"\n"
        "\"second\\q\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, _}},
        erli18n_po:parse(Bin)
    ).

%% A quoted string with trailing whitespace after the closing quote.
%% is_only_trailing_ws walks the whitespace and returns true via the
%% empty-binary base case.
trailing_whitespace_after_close_quote(_Config) ->
    %% Note: leading whitespace on continuation lines is trimmed by
    %% trim_leading_ws, but trailing whitespace on the keyword line is
    %% preserved. Use spaces and tabs after the closing quote.
    Bin = <<
        (minimal_header())/binary,
        "msgid \"hello\"  \t \n"
        "msgstr \"world\"\t  \n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, ~"hello", ~"world"}],
        maps:get(entries, Catalog)
    ).

%% \b backspace escape decodes to byte 8.
escape_backspace(_Config) ->
    Bin = po_with_entry(~"k", ~"a\\bb"),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a", 8, "b">>, T).

%% \f formfeed escape decodes to byte 12.
escape_formfeed(_Config) ->
    Bin = po_with_entry(~"k", ~"a\\fb"),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a", 12, "b">>, T).

%% \v vertical tab escape decodes to byte 11.
escape_vertical_tab(_Config) ->
    Bin = po_with_entry(~"k", ~"a\\vb"),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a", 11, "b">>, T).

%% \a alert (BEL) escape decodes to byte 7.
escape_alert_bell(_Config) ->
    Bin = po_with_entry(~"k", ~"a\\ab"),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a", 7, "b">>, T).

%% Cover L782: \/ forward slash escape decodes to '/'.
escape_forward_slash(_Config) ->
    Bin = po_with_entry(~"k", ~"a\\/b"),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(~"a/b", T).

%% Cover L783: \? question mark escape decodes to '?'.
escape_question_mark(_Config) ->
    Bin = po_with_entry(~"k", ~"a\\?b"),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(~"a?b", T).

%% Cover L784: \' single quote escape decodes to '.
escape_single_quote(_Config) ->
    Bin = po_with_entry(~"k", ~"a\\'b"),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(~"a'b", T).

%% Cover L802: \x followed by a non-hex digit produces invalid_hex_escape.
invalid_hex_escape_non_hex_digit(_Config) ->
    Bin = po_with_entry(~"k", ~"a\\xZZb"),
    ?assertMatch(
        {error, {syntax_error, _, invalid_hex_escape}},
        erli18n_po:parse(Bin)
    ).

%% Cover L624-626 (raw-pass msgctxt classifier): a msgctxt line appears
%% before the header. The prepass walks past it via the catchall and
%% still finds the header.
msgctxt_before_header_prepass(_Config) ->
    Bin = <<
        "msgctxt \"stray\"\n"
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% Cover L641 (raw-pass msgstr[N] classifier returning msgstr_n shape):
%% an indexed msgstr line appears before the header. The prepass walks
%% past it.
msgstr_n_before_header_prepass(_Config) ->
    Bin = <<
        "msgstr[0] \"stray\"\n"
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% Cover L629-631 (raw-pass msgid_plural classifier): a msgid_plural
%% line appears before the header.
msgid_plural_before_header_prepass(_Config) ->
    Bin = <<
        "msgid_plural \"stray\"\n"
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% Cover L564: parse_header_line catchall returns [] for a header line
%% lacking a ":" separator. Embed such a line in the header msgstr.
header_line_without_colon_skipped(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\"NoColonHereJustGarbage\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    Header = maps:get(header, Catalog),
    %% The malformed line is preserved in raw but contributes no field.
    ?assertEqual(utf8, maps:get(charset, Header)),
    %% Plural-Forms still parsed correctly.
    ?assertEqual(
        ~"nplurals=2; plural=(n != 1);",
        maps:get(plural_forms, Header)
    ).

%% Cover L601: Plural-Forms contains the word "nplurals" but no "="
%% after it, so extract_nplurals_value returns undefined.
plural_forms_nplurals_without_equals(_Config) ->
    %% Note: the prepass charset extraction must still succeed.
    %% A Plural-Forms value of "nplurals " (with no =) exercises L601.
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals \\n\"\n"
        "\n"
        "msgid \"x\"\n"
        "msgstr \"y\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    %% nplurals undefined -> validate_plural_indices accepts any set,
    %% so singular entry still emits.
    ?assertEqual(
        [{singular, undefined, ~"x", ~"y"}],
        maps:get(entries, Catalog)
    ).

%% Cover L823-824: dump_header is called with a header whose raw is the
%% empty binary (synthesized when input had no header). Build such a
%% catalog by parsing a PO file with no header entry, then dumping it.
dump_synthetic_catalog_empty_raw(_Config) ->
    %% No header entry at all — parser synthesizes empty header where
    %% raw = <<>>.
    Bin = <<
        "msgid \"only\"\n"
        "msgstr \"trans\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    Header = maps:get(header, Catalog),
    ?assertEqual(<<>>, maps:get(raw, Header)),
    Dumped = erli18n_po:dump(Catalog),
    %% Re-parsing the dump produces a header with a populated raw.
    {ok, Catalog2} = erli18n_po:parse(Dumped),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog2))),
    %% The original singular entry roundtrips.
    ?assertEqual(
        [{singular, undefined, ~"only", ~"trans"}],
        maps:get(entries, Catalog2)
    ).

%% Cover L829: dump_header default branch fires when the header map
%% lacks the raw key entirely. Construct a catalog directly and call
%% dump/1 — exercises the tolerant fallback.
dump_catalog_missing_raw_key(_Config) ->
    Catalog = #{
        header => #{
            plural_forms => <<>>,
            content_type => <<>>,
            charset => utf8
        },
        entries => [{singular, undefined, ~"k", ~"v"}]
    },
    Dumped = erli18n_po:dump(Catalog),
    %% Re-parse the dumped output to confirm a minimal valid header was
    %% emitted.
    {ok, Catalog2} = erli18n_po:parse(Dumped),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog2))),
    ?assertEqual(
        [{singular, undefined, ~"k", ~"v"}],
        maps:get(entries, Catalog2)
    ).

%% Cover L626: classify_raw_line for "msgctxt" without any quoted
%% string returns 'other'. Triggers via a bare keyword line BEFORE the
%% header, so the prepass classifier hits the error branch.
msgctxt_bare_keyword_before_header_prepass(_Config) ->
    Bin = <<
        "msgctxt\n"
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
    >>,
    %% The main parser rejects the bare "msgctxt" line with a syntax
    %% error — but only AFTER the prepass has succeeded (which is what
    %% we need to exercise L626).
    ?assertMatch(
        {error, {syntax_error, _, expected_msgctxt_string}},
        erli18n_po:parse(Bin)
    ).

%% Cover L631: classify_raw_line for "msgid_plural" without a quoted
%% string returns 'other'. Same shape as above, for msgid_plural.
msgid_plural_bare_keyword_before_header_prepass(_Config) ->
    Bin = <<
        "msgid_plural\n"
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
    >>,
    ?assertMatch(
        {error, {syntax_error, _, expected_msgid_plural_string}},
        erli18n_po:parse(Bin)
    ).

%% Cover L738: trim_leading_ws strips tab indentation. PO files
%% sometimes have tab-indented keyword lines.
tab_indented_line_in_main_parser(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "\tmsgid \"x\"\n"
        "\tmsgstr \"y\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, ~"x", ~"y"}],
        maps:get(entries, Catalog)
    ).

%% `split_lines/1` normalizes lone CR (0x0D, classic Mac) to LF, the same
%% way it folds CRLF -> LF, so the three newline conventions parse a
%% byte-identical catalog to the EXACT same result. A `split_lines/1` that
%% only replaced <<"\r\n">> then split on <<"\n">> would treat a lone-CR
%% file as one giant line, so the parser would see content after the first
%% closing quote, returning a spurious
%% {error, {syntax_error, 1, content_after_close_quote}}. GNU `msgfmt -c`
%% accepts the same lone-CR file (exit 0), so failing to normalize it
%% would be a real parity gap.
line_endings_lf_crlf_lone_cr_parse_identically(_Config) ->
    %% A logical 2-entry catalog whose lines are joined by a parameterized
    %% terminator. The byte content of each line is identical across the
    %% three variants; only the line terminator differs.
    Lines = [
        ~"msgid \"\"",
        ~"msgstr \"\"",
        ~"\"Content-Type: text/plain; charset=UTF-8\\n\"",
        ~"\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"",
        ~"",
        ~"msgid \"Hello\"",
        ~"msgstr \"Oi\"",
        ~"",
        ~"msgid \"Bye\"",
        ~"msgstr \"Tchau\""
    ],
    Join = fun(Sep) ->
        iolist_to_binary(lists:join(Sep, Lines))
    end,
    LfBin = Join(~"\n"),
    CrlfBin = Join(~"\r\n"),
    LoneCrBin = Join(~"\r"),

    Expected = [
        {singular, undefined, ~"Hello", ~"Oi"},
        {singular, undefined, ~"Bye", ~"Tchau"}
    ],

    {ok, LfCatalog} = erli18n_po:parse(LfBin),
    ?assertEqual(Expected, maps:get(entries, LfCatalog)),

    {ok, CrlfCatalog} = erli18n_po:parse(CrlfBin),
    ?assertEqual(Expected, maps:get(entries, CrlfCatalog)),

    %% The lone-CR case — the one a CRLF-only normalization would miss.
    {ok, LoneCrCatalog} = erli18n_po:parse(LoneCrBin),
    ?assertEqual(Expected, maps:get(entries, LoneCrCatalog)),

    %% All three byte-distinct inputs must yield the SAME parsed entries
    %% AND the same detected charset/plural-forms header.
    ?assertEqual(
        maps:get(entries, LfCatalog),
        maps:get(entries, LoneCrCatalog)
    ),
    ?assertEqual(
        maps:get(entries, CrlfCatalog),
        maps:get(entries, LoneCrCatalog)
    ),
    ?assertEqual(
        utf8,
        maps:get(charset, maps:get(header, LoneCrCatalog))
    ),
    ?assertEqual(
        ~"nplurals=2; plural=(n != 1);",
        maps:get(plural_forms, maps:get(header, LoneCrCatalog))
    ).

%% Malformed escapes / indices in a .po surface a structured syntax error
%% (input -> output). The escape-heavy literals use the same `\"` / `\\`
%% conventions as the other parser cases in this suite.
parse_rejects_malformed_escapes_and_index(_Config) ->
    %% Octal escape > 255.
    ?assertEqual(
        {error, {syntax_error, 1, {octal_escape_out_of_range, 256}}},
        erli18n_po:parse(~"msgid \"\\400\"\nmsgstr \"x\"\n")
    ),
    %% A trailing invalid-UTF-8 escape (\377 = byte 255) flushed at EOF.
    ?assertEqual(
        {error, {syntax_error, 1, {escape_invalid_utf8, <<255>>}}},
        erli18n_po:parse(~"msgid \"\\377\"\nmsgstr \"y\"\n")
    ),
    %% An over-long msgstr index: the prepass classifies the line as `other`
    %% and the main parser rejects it.
    ?assertEqual(
        {error, {syntax_error, 1, {index_too_long, 7}}},
        erli18n_po:parse(
            ~"msgstr[88888888] \"x\"\nmsgid \"\"\nmsgstr \"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        )
    ),
    ok.

%% The header's `nplurals=` value is attacker-controlled and
%% `collect_digits/2` caps only the DIGIT COUNT (max 7 digits => up to
%% 9_999_999), so a 158-byte `.po` can legitimately declare
%% `nplurals=9999999`. The plural index validation must NEVER size a list
%% by that header value: `lists:seq(0, Nplurals - 1)` would materialize a
%% ~10M-element list (~80MB, ~340ms vs ~0.1ms for a real catalog). The
%% present index set is validated WITHOUT building the header-sized
%% sequence, so this returns the EXACT same structured
%% `{plural_count_mismatch, Msgid, Nplurals, Indices}` error a genuine
%% count mismatch always produces, and it completes in bounded time.
%%
%% Black-box, through `parse/1`: input -> structured error, with a
%% deterministic wall-clock ceiling an unbounded ~10M-allocation could
%% not meet. A generous 200ms bound (validation runs in single-digit ms)
%% keeps the test stable on slow CI while still failing hard against the
%% unbounded allocation it replaces.
plural_nplurals_header_dos_bounded(_Config) ->
    Attack = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=9999999; plural=0;\\n\"\n"
        "\n"
        "msgid \"Tree\"\n"
        "msgid_plural \"Trees\"\n"
        "msgstr[0] \"a\"\n"
    >>,
    %% Tiny input; a multi-MB allocation here would be a clear DoS.
    ?assert(byte_size(Attack) < 200),
    T0 = erlang:monotonic_time(microsecond),
    Result = erli18n_po:parse(Attack),
    ElapsedUs = erlang:monotonic_time(microsecond) - T0,
    %% The exact structured plural-count error is preserved verbatim: only
    %% index 0 is present, but the header declares 9_999_999 forms.
    ?assertEqual(
        {error, {plural_count_mismatch, ~"Tree", 9999999, [0]}},
        Result
    ),
    %% Bounded: never materializes the header-sized sequence.
    ?assert(ElapsedUs < 200000).

%% A field built from MANY continuation lines must (a) join to the
%% byte-correct concatenation and (b) build in O(total) time. The parser
%% accumulates each continuation segment as an O(1) prepend onto a
%% reversed list and joins once at finalization, rather than a per-line
%% `<<Prev/binary, Bin/binary>>` that would re-copy the growing
%% accumulator out of the record.
%%
%% Black-box, through `parse/1`: a msgid AND a msgstr each spread over
%% thousands of continuation lines must reassemble to the exact expected
%% binary (correctness of the new reversed-list-then-join path, including
%% segment ORDER — a reversed join would corrupt it), and the parse must
%% finish within a generous bound.
many_continuation_lines_join_correctly_and_bounded(_Config) ->
    N = 4000,
    Seq = lists:seq(1, N),
    %% Each continuation line carries one distinct ASCII chunk; ORDER is
    %% load-bearing, so a wrong (reversed) join would fail the equality.
    MsgidConts = iolist_to_binary([
        <<"\"m", (integer_to_binary(I))/binary, ".\"\n">>
     || I <- Seq
    ]),
    MsgstrConts = iolist_to_binary([
        <<"\"s", (integer_to_binary(I))/binary, ".\"\n">>
     || I <- Seq
    ]),
    Bin = <<
        (minimal_header())/binary,
        "msgid \"\"\n",
        MsgidConts/binary,
        "msgstr \"\"\n",
        MsgstrConts/binary
    >>,
    ExpectedMsgid = iolist_to_binary([<<"m", (integer_to_binary(I))/binary, ".">> || I <- Seq]),
    ExpectedMsgstr = iolist_to_binary([<<"s", (integer_to_binary(I))/binary, ".">> || I <- Seq]),
    T0 = erlang:monotonic_time(microsecond),
    {ok, Catalog} = erli18n_po:parse(Bin),
    ElapsedUs = erlang:monotonic_time(microsecond) - T0,
    ?assertEqual(
        [{singular, undefined, ExpectedMsgid, ExpectedMsgstr}],
        maps:get(entries, Catalog)
    ),
    %% Bounded build over thousands of continuation lines.
    ?assert(ElapsedUs < 2000000).
