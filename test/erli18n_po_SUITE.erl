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
    dump_roundtrip_with_context/1,
    comments_skipped/1,
    flags_other_than_fuzzy_ignored/1,
    parse_file_ok/1,
    parse_file_missing/1,
    hex_and_octal_escapes/1,
    degenerate_plural_nplurals_1/1,
    duplicate_header_dropped/1,
    %% Coverage-targeted tests
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
    tab_indented_line_in_main_parser/1
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
        dump_roundtrip_with_context,
        comments_skipped,
        flags_other_than_fuzzy_ignored,
        parse_file_ok,
        parse_file_missing,
        hex_and_octal_escapes,
        degenerate_plural_nplurals_1,
        duplicate_header_dropped,
        %% Coverage-targeted tests
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
        tab_indented_line_in_main_parser
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

%% PSD-002: header with valid UTF-8 charset parses OK.
header_minimal_utf8(_Config) ->
    {ok, Catalog} = erli18n_po:parse(minimal_header()),
    Header = maps:get(header, Catalog),
    ?assertEqual(utf8, maps:get(charset, Header)),
    ?assertEqual(
        <<"nplurals=2; plural=(n != 1);">>,
        maps:get(plural_forms, Header)
    ),
    ?assertEqual([], maps:get(entries, Catalog)).

%% PSD-002: unsupported charset returns structured error, no entries
%% emitted.
header_unsupported_charset(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=SHIFT_JIS\\n\"\n"
    >>,
    ?assertEqual(
        {error, {unsupported_charset, <<"SHIFT_JIS">>}},
        erli18n_po:parse(Bin)
    ).

%% Finding #5 (po-header-malformed-content-type-badmatch-crash): a
%% `Content-Type` header with a SINGLE SPACE before the colon must
%% surface a structured `{error, {unsupported_charset, _}}` for an
%% unsupported charset — never a `badmatch` crash. Before the fix the
%% two charset detection paths diverged: the prepass `find_charset_line`
%% required the literal `content-type:` substring (no space), so it
%% missed this line and fell through to the default utf8, while
%% `build_header`'s field parser trimmed the key to `content-type`,
%% classified the charset, hit `{error,_}` on the non-exhaustive
%% `{ok,Charset} =` match, and crashed the loader gen_server.
header_unsupported_charset_space_before_colon(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type : text/plain; charset=Shift_JIS\\n\"\n"
    >>,
    ?assertEqual(
        {error, {unsupported_charset, <<"Shift_JIS">>}},
        erli18n_po:parse(Bin)
    ).

%% Companion to the above: a SUPPORTED charset with a space before the
%% colon must parse OK and detect the declared charset (latin1 here),
%% proving the prepass and `build_header` now AGREE on the same
%% whitespace-tolerant field parse instead of diverging. Before the fix
%% the prepass missed the spaced `Content-Type ` line and defaulted to
%% utf8, so the charset was silently wrong.
header_supported_charset_space_before_colon(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type : text/plain; charset=ISO-8859-1\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(latin1, maps:get(charset, maps:get(header, Catalog))).

%% A TAB before the colon is another adversarial spacing the literal
%% prepass matcher missed. Same contract: structured error, no crash.
header_unsupported_charset_tab_before_colon(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type\t: text/plain; charset=Shift_JIS\\n\"\n"
    >>,
    ?assertEqual(
        {error, {unsupported_charset, <<"Shift_JIS">>}},
        erli18n_po:parse(Bin)
    ).

%% PSD-002: ISO-8859-1 body bytes are converted to UTF-8 internally.
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

%% PSD-002: header without Content-Type defaults to utf8.
header_missing_content_type(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    Header = maps:get(header, Catalog),
    ?assertEqual(utf8, maps:get(charset, Header)).

%% PSD-005: UTF-8 BOM is silently stripped.
bom_utf8_stripped(_Config) ->
    Bin =
        <<16#EF, 16#BB, 16#BF, (minimal_header())/binary,
            "msgid \"Hello\"\n"
            "msgstr \"Bonjour\"\n">>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, undefined, <<"Hello">>, <<"Bonjour">>}] =
        maps:get(entries, Catalog).

%% =========================
%% Entry tests
%% =========================

single_entry_singular(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"Hello\"\n"
        "msgstr \"Bonjour\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, <<"Hello">>, <<"Bonjour">>}],
        maps:get(entries, Catalog)
    ).

%% PSD-006: msgctxt is stored as a separate field, never glued.
single_entry_with_context(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgctxt \"menu\"\n"
        "msgid \"File\"\n"
        "msgstr \"Fichier\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, <<"menu">>, <<"File">>, <<"Fichier">>}],
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
        [{plural, undefined, <<"tree">>, [{0, <<"arbre">>}, {1, <<"arbres">>}]}],
        maps:get(entries, Catalog)
    ).

%% PSD-009: header declares nplurals=3, entry has [0, 1, 3] — error,
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
        {error, {plural_count_mismatch, <<"Tree">>, 3, [0, 1, 3]}},
        erli18n_po:parse(Bin)
    ).

%% PSD-009: extra plural index also rejected atomically.
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
        {error, {plural_count_mismatch, <<"Tree">>, 2, [0, 1, 2]}},
        erli18n_po:parse(Bin)
    ).

%% PSD-001: fuzzy entries dropped by default.
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
        [{singular, undefined, <<"a">>, <<"b">>}],
        maps:get(entries, Catalog)
    ).

%% PSD-001: include_fuzzy => true preserves fuzzy entries.
fuzzy_included_with_opt(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "#, fuzzy\n"
        "msgid \"x\"\n"
        "msgstr \"y\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin, #{include_fuzzy => true}),
    ?assertEqual(
        [{singular, undefined, <<"x">>, <<"y">>}],
        maps:get(entries, Catalog)
    ).

%% PSD-007: obsolete entries are skipped silently.
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
        [{singular, undefined, <<"alive">>, <<"vivant">>}],
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
    ?assertEqual(<<"a\nb\tc\"d\\e">>, Msgid),
    ?assertEqual(<<"x\nx\tx\"x\\x">>, Translation).

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
    ?assertEqual(<<"first second">>, Msgid),
    ?assertEqual(<<"trad end">>, Translation).

%% PSD-003: parser preserves empty msgstr verbatim; fallback is the
%% lookup's job.
empty_msgstr_preserved(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"Hello\"\n"
        "msgstr \"\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, <<"Hello">>, <<>>}],
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
        [{plural, undefined, <<"tree">>, [{0, <<>>}, {1, <<>>}]}],
        maps:get(entries, Catalog)
    ).

%% =========================
%% Roundtrip tests
%% =========================

dump_roundtrip_singular(_Config) ->
    Bin = <<
        (minimal_header())/binary,
        "msgid \"Hello\"\n"
        "msgstr \"Bonjour\"\n"
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
    {ok, C2} = erli18n_po:parse(Dumped),
    ?assertEqual(maps:get(entries, C1), maps:get(entries, C2)).

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
        "msgstr \"Bonjour\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(
        [{singular, undefined, <<"Hello">>, <<"Bonjour">>}],
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
        [{singular, undefined, <<"x %s">>, <<"y %s">>}],
        maps:get(entries, Catalog)
    ).

parse_file_ok(Config) ->
    PrivDir = ?config(priv_dir, Config),
    Path = filename:join(PrivDir, "ok.po"),
    Bin = <<
        (minimal_header())/binary,
        "msgid \"Hello\"\n"
        "msgstr \"Bonjour\"\n"
    >>,
    ok = file:write_file(Path, Bin),
    {ok, Catalog} = erli18n_po:parse_file(Path),
    ?assertEqual(
        [{singular, undefined, <<"Hello">>, <<"Bonjour">>}],
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
    ?assertEqual(<<"AA">>, Msgid).

%% PSD-008: nplurals=1 (Japanese-style); single msgstr[0] is enough.
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
        [{plural, undefined, <<"Fish">>, [{0, <<"sakana">>}]}],
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
        "msgstr \"Bonjour\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    Header = maps:get(header, Catalog),
    %% The first header (UTF-8) wins for the conversion pass; the second
    %% header entry is dropped from entries.
    ?assertEqual(utf8, maps:get(charset, Header)),
    ?assertEqual(
        [{singular, undefined, <<"Hello">>, <<"Bonjour">>}],
        maps:get(entries, Catalog)
    ).

%% =========================
%% Coverage-targeted helpers
%% =========================

po_with_charset(Charset) ->
    %% Build a header with a custom charset string (raw bytes, no escape
    %% sequences). Used to exercise charset alias mapping branches.
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
            <<"msgid \"">>,
            Msgid,
            <<"\"\n", "msgstr \"">>,
            Msgstr,
            <<"\"\n">>
        ]
    ).

%% =========================
%% Coverage-targeted tests
%% =========================

%% Cover L279: charset alias "utf8" (no hyphen) normalizes to utf8.
charset_alias_utf8_no_hyphen(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(<<"utf8">>)),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% Cover L281: charset alias "iso8859-1" (no dash between iso and 8859)
%% normalizes to latin1.
charset_alias_iso8859_1_no_dashes(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(<<"iso8859-1">>)),
    ?assertEqual(latin1, maps:get(charset, maps:get(header, Catalog))).

%% Cover L282: charset alias "latin-1" normalizes to latin1.
charset_alias_latin_hyphen_1(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(<<"latin-1">>)),
    ?assertEqual(latin1, maps:get(charset, maps:get(header, Catalog))).

%% Cover L284: charset alias "us-ascii" normalizes to us_ascii.
charset_alias_us_ascii(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(<<"us-ascii">>)),
    ?assertEqual(us_ascii, maps:get(charset, maps:get(header, Catalog))).

%% Cover L285: charset alias "ascii" (short form) normalizes to us_ascii.
charset_alias_ascii_short(_Config) ->
    {ok, Catalog} = erli18n_po:parse(po_with_charset(<<"ascii">>)),
    ?assertEqual(us_ascii, maps:get(charset, maps:get(header, Catalog))).

%% Cover L269: extract_charset_token hits separator branch when the
%% charset value is followed by a semicolon parameter list (e.g.
%% "charset=utf-8; boundary=foo"). After ";" the token finalizes.
charset_with_trailing_semicolon(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=utf-8; boundary=x\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% Cover L273: finalize_token(<<>>) -> undefined fires when charset has
%% an empty value (e.g. "charset=" immediately followed by separator).
%% The prepass returns {ok, utf8} via the undefined branch.
charset_empty_value_defaults_utf8(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=; foo=bar\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% Cover L300, L301, L313, L317: us-ascii body with only ASCII bytes
%% validates ok and passes through.
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
        [{singular, undefined, <<"hello">>, <<"world">>}],
        maps:get(entries, Catalog)
    ).

%% Cover L302, L315: us-ascii body with a byte > 127 is rejected with
%% the charset_conversion error.
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
        {error, {charset_conversion, <<"US-ASCII">>, _}},
        erli18n_po:parse(Bin)
    ).

%% Cover L199: collect_header_msgstr hits the comment branch when a
%% comment line appears between the header msgid "" and msgstr "".
header_msgstr_comment_continuation(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "# inserted translator comment between msgid and msgstr\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% Cover the blank branch in collect_header_msgstr (line 196-197 is
%% covered; this asserts the path works end-to-end with a blank line
%% between msgid and msgstr).
header_msgstr_blank_continuation(_Config) ->
    Bin = <<
        "msgid \"\"\n"
        "\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
    >>,
    {ok, Catalog} = erli18n_po:parse(Bin),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog))).

%% Cover L431: msgctxt spread across multiple continuation lines.
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
        [{singular, <<"line1 line2">>, <<"x">>, <<"y">>}],
        maps:get(entries, Catalog)
    ).

%% Cover L435: msgid_plural spread across multiple continuation lines.
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
    [{plural, undefined, <<"tree">>, Plurals}] =
        maps:get(entries, Catalog),
    ?assertEqual([{0, <<"a">>}, {1, <<"b">>}], Plurals).

%% Cover L440-441: msgstr[N] spread across continuation lines. The
%% append branch for {msgstr, Idx} pops the head and reconcatenates.
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
    [{plural, undefined, <<"tree">>, Plurals}] =
        maps:get(entries, Catalog),
    ?assertEqual([{0, <<"first continued">>}, {1, <<"b">>}], Plurals).

%% Cover L683: msgctxt keyword with no following quoted string returns
%% a syntax error in the main parser pass.
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

%% Cover L710: strip_keyword_space handles tab whitespace after keyword
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
        [{singular, <<"ctx">>, <<"x">>, <<"y">>}],
        maps:get(entries, Catalog)
    ).

%% Cover L704: a quoted-string continuation line appearing before any
%% keyword has set last_field is a syntax error.
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

%% Cover L752 (decode_quoted_string {error, expected_quote}): the parser
%% reaches handle_string_field with content that does not start with ".
%% This happens when classify_msgstr returns {ok, Content} but the
%% Content was actually empty after stripping (only possible via the
%% main parser path: send "msgstr [0] ..." with malformed index).
%%
%% The cleanest user-visible trigger: a continuation line whose body
%% (after stripping leading ws) is just a bare quote followed by
%% non-quote content — the decode_chars path treats it as content_after
%% which we already test. Instead, exercise expected_quote via a
%% malformed continuation by feeding append_to_last a non-quote.
%%
%% Simpler: classify_line catches "msgid X" (no quotes) and returns
%% other-shape via strip_keyword_space => error => syntax_error. To hit
%% expected_quote inside decode_quoted_string we must reach
%% decode_quoted_string with input not starting with $". The only
%% caller paths to decode_quoted_string are:
%%   - handle_string_field via classify_line
%%   - collect_header_msgstr (prepass)
%%   - consume_continuations (prepass)
%%   - decode_chars continuation in classify_line
%%
%% strip_keyword_space already filters non-quote inputs to "error"
%% before decode_quoted_string is called for main keyword fields, so
%% the path is via continuation. A continuation line passes the raw
%% bytes (starting with $") to decode_quoted_string, which always
%% matches the $" head. So expected_quote is unreachable via main pass.
%%
%% However consume_continuations (prepass, L221) calls
%% decode_quoted_string on Trimmed where Trimmed starts with $".  So
%% also unreachable via prepass continuation. The only remaining caller
%% is collect_header_msgstr at L201, which receives "Content" from
%% strip_keyword_space — which guarantees it starts with $". So
%% expected_quote really is defensive code.
%%
%% Mark as unreachable. This test documents the analysis by exercising
%% the closest reachable path: a malformed header msgstr with no quote.
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

%% Cover L758, L811, L814: a quoted string with trailing whitespace
%% after the closing quote. is_only_trailing_ws walks the whitespace
%% and returns true via the empty-binary base case.
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
        [{singular, undefined, <<"hello">>, <<"world">>}],
        maps:get(entries, Catalog)
    ).

%% Cover L778: \b backspace escape decodes to byte 8.
escape_backspace(_Config) ->
    Bin = po_with_entry(<<"k">>, <<"a\\bb">>),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a", 8, "b">>, T).

%% Cover L779: \f formfeed escape decodes to byte 12.
escape_formfeed(_Config) ->
    Bin = po_with_entry(<<"k">>, <<"a\\fb">>),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a", 12, "b">>, T).

%% Cover L780: \v vertical tab escape decodes to byte 11.
escape_vertical_tab(_Config) ->
    Bin = po_with_entry(<<"k">>, <<"a\\vb">>),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a", 11, "b">>, T).

%% Cover L781: \a alert (BEL) escape decodes to byte 7.
escape_alert_bell(_Config) ->
    Bin = po_with_entry(<<"k">>, <<"a\\ab">>),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a", 7, "b">>, T).

%% Cover L782: \/ forward slash escape decodes to '/'.
escape_forward_slash(_Config) ->
    Bin = po_with_entry(<<"k">>, <<"a\\/b">>),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a/b">>, T).

%% Cover L783: \? question mark escape decodes to '?'.
escape_question_mark(_Config) ->
    Bin = po_with_entry(<<"k">>, <<"a\\?b">>),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a?b">>, T).

%% Cover L784: \' single quote escape decodes to '.
escape_single_quote(_Config) ->
    Bin = po_with_entry(<<"k">>, <<"a\\'b">>),
    {ok, Catalog} = erli18n_po:parse(Bin),
    [{singular, _, _, T}] = maps:get(entries, Catalog),
    ?assertEqual(<<"a'b">>, T).

%% Cover L802: \x followed by a non-hex digit produces invalid_hex_escape.
invalid_hex_escape_non_hex_digit(_Config) ->
    Bin = po_with_entry(<<"k">>, <<"a\\xZZb">>),
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
        <<"nplurals=2; plural=(n != 1);">>,
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
        [{singular, undefined, <<"x">>, <<"y">>}],
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
        [{singular, undefined, <<"only">>, <<"trans">>}],
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
        entries => [{singular, undefined, <<"k">>, <<"v">>}]
    },
    Dumped = erli18n_po:dump(Catalog),
    %% Re-parse the dumped output to confirm a minimal valid header was
    %% emitted.
    {ok, Catalog2} = erli18n_po:parse(Dumped),
    ?assertEqual(utf8, maps:get(charset, maps:get(header, Catalog2))),
    ?assertEqual(
        [{singular, undefined, <<"k">>, <<"v">>}],
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
        [{singular, undefined, <<"x">>, <<"y">>}],
        maps:get(entries, Catalog)
    ).
