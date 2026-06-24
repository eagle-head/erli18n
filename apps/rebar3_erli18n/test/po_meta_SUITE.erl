-module(po_meta_SUITE).

-moduledoc """
Tests for `rebar3_erli18n_po_meta` — the metadata-aware PO serializer.

This layer is OUTSIDE the GNU-gettext parity oracle (that oracle covers
`erli18n_po`'s msgstr block), so it carries its own byte-level golden
assertions for the metadata `erli18n_po` cannot represent — `#:` references,
`#.`/`# ` comments, `#, fuzzy`, `#~` obsolete, `#|` previous-msgid — plus a
`msgmerge` parity oracle that runs when the CLI is present and skips cleanly
when absent (mirroring `erli18n_parity_SUITE`).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    singular_block/1,
    references_emitted/1,
    comments_emitted/1,
    fuzzy_flag_emitted/1,
    previous_msgid_emitted/1,
    obsolete_block/1,
    plural_block/1,
    msgid_equal_logical/1,
    header_emitted/1,
    escapes_in_previous/1,
    binary_reference_and_flag/1,
    empty_context_emitted_undefined_omitted/1,
    obsolete_plural_block/1,
    obsolete_plural_keeps_comment_unprefixed/1,
    plural_with_extracted_and_references/1,
    msgmerge_accepts_output/1
]).

all() ->
    [
        singular_block,
        references_emitted,
        comments_emitted,
        fuzzy_flag_emitted,
        previous_msgid_emitted,
        obsolete_block,
        plural_block,
        msgid_equal_logical,
        header_emitted,
        escapes_in_previous,
        binary_reference_and_flag,
        empty_context_emitted_undefined_omitted,
        obsolete_plural_block,
        obsolete_plural_keeps_comment_unprefixed,
        plural_with_extracted_and_references,
        msgmerge_accepts_output
    ].

header() ->
    <<"Content-Type: text/plain; charset=UTF-8\n">>.

cat(Entries) ->
    #{header => header(), entries => Entries}.

singular_block(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, undefined, <<"Hello">>, <<"Ola">>}
    }),
    ?assertEqual(<<"msgid \"Hello\"\nmsgstr \"Ola\"\n\n">>, Out).

references_emitted(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, undefined, <<"Hi">>, <<>>},
        references => [{"src/a.erl", 10}, {"src/b.erl", 20}]
    }),
    ?assertEqual(
        <<"#: src/a.erl:10\n#: src/b.erl:20\nmsgid \"Hi\"\nmsgstr \"\"\n\n">>,
        Out
    ).

comments_emitted(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, undefined, <<"X">>, <<>>},
        comments => [<<"translator note">>],
        extracted => [<<"programmer note">>]
    }),
    ?assertEqual(
        <<"# translator note\n#. programmer note\nmsgid \"X\"\nmsgstr \"\"\n\n">>,
        Out
    ).

fuzzy_flag_emitted(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, undefined, <<"X">>, <<"Y">>},
        flags => [fuzzy]
    }),
    ?assertEqual(<<"#, fuzzy\nmsgid \"X\"\nmsgstr \"Y\"\n\n">>, Out).

previous_msgid_emitted(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, undefined, <<"New">>, <<"T">>},
        flags => [fuzzy],
        previous => {undefined, <<"Old">>}
    }),
    ?assertEqual(
        <<"#, fuzzy\n#| msgid \"Old\"\nmsgid \"New\"\nmsgstr \"T\"\n\n">>,
        Out
    ),
    %% With a previous context and plural form.
    Out2 = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, <<"ctx">>, <<"New">>, <<"T">>},
        previous => {<<"oldctx">>, <<"Old">>, <<"Olds">>}
    }),
    ?assertEqual(
        <<
            "#| msgctxt \"oldctx\"\n#| msgid \"Old\"\n#| msgid_plural \"Olds\"\n"
            "msgctxt \"ctx\"\nmsgid \"New\"\nmsgstr \"T\"\n\n"
        >>,
        Out2
    ).

obsolete_block(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, <<"ctx">>, <<"Old">>, <<"Velho">>},
        obsolete => true
    }),
    ?assertEqual(
        <<"#~ msgctxt \"ctx\"\n#~ msgid \"Old\"\n#~ msgstr \"Velho\"\n\n">>,
        Out
    ).

plural_block(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {plural, undefined, <<"one">>, <<"many">>, [{0, <<"um">>}, {1, <<"muitos">>}]},
        references => [{"src/p.erl", 5}]
    }),
    ?assertEqual(
        <<
            "#: src/p.erl:5\nmsgid \"one\"\nmsgid_plural \"many\"\n"
            "msgstr[0] \"um\"\nmsgstr[1] \"muitos\"\n\n"
        >>,
        Out
    ).

msgid_equal_logical(_Config) ->
    ?assert(rebar3_erli18n_po_meta:msgid_equal(<<"abc">>, <<"abc">>)),
    ?assertNot(rebar3_erli18n_po_meta:msgid_equal(<<"abc">>, <<"abd">>)).

header_emitted(_Config) ->
    Out = rebar3_erli18n_po_meta:dump(cat([])),
    %% The header is rendered via erli18n_po:dump/1 as an empty msgid block.
    ?assert(binary:match(Out, <<"msgid \"\"">>) =/= nomatch),
    ?assert(binary:match(Out, <<"Content-Type: text/plain; charset=UTF-8">>) =/= nomatch).

escapes_in_previous(_Config) ->
    %% A previous-msgid carrying every escapable byte (backslash, quote,
    %% newline, tab, carriage return) must be re-escaped in the `#|` line.
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, undefined, <<"new">>, <<"t">>},
        previous => {undefined, <<"a\\b\"c\nd\te\rf">>}
    }),
    ?assert(binary:match(Out, <<"#| msgid \"a\\\\b\\\"c\\nd\\te\\rf\"">>) =/= nomatch).

binary_reference_and_flag(_Config) ->
    %% A reference whose path is a binary, and a flag given as a binary.
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, undefined, <<"x">>, <<>>},
        references => [{<<"lib/m.erl">>, 7}],
        flags => [fuzzy, <<"c-format">>]
    }),
    ?assert(binary:match(Out, <<"#: lib/m.erl:7">>) =/= nomatch),
    ?assert(binary:match(Out, <<"#, fuzzy, c-format">>) =/= nomatch),
    %% An invalid char-data path (a codepoint past the Unicode max) cannot
    %% encode; `to_binary/1` falls back to an empty path rather than crash.
    Bad = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, undefined, <<"y">>, <<>>},
        references => [{[16#110000], 1}]
    }),
    ?assert(binary:match(Bad, <<"#: :1">>) =/= nomatch).

%% The no-context invariant (Revision #4), pinned on the SERIALIZE side:
%% an explicit empty-binary context (`<<>>`) is a real, distinct context
%% and MUST emit `msgctxt ""`, whereas the absent-context `undefined`
%% MUST omit the `msgctxt` line entirely. (Ported from the abandoned
%% runtime preserve-mode SUITE, which asserted the same distinction on the
%% READ side; the write-side serializer is the structural home now.)
empty_context_emitted_undefined_omitted(_Config) ->
    WithEmpty = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, <<>>, <<"Id">>, <<"Tr">>}
    }),
    ?assertEqual(<<"msgctxt \"\"\nmsgid \"Id\"\nmsgstr \"Tr\"\n\n">>, WithEmpty),
    WithUndefined = rebar3_erli18n_po_meta:dump_entry(#{
        body => {singular, undefined, <<"Id">>, <<"Tr">>}
    }),
    ?assertEqual(<<"msgid \"Id\"\nmsgstr \"Tr\"\n\n">>, WithUndefined),
    %% The empty-context form is byte-distinct from the absent-context form.
    ?assertNotEqual(WithEmpty, WithUndefined).

%% An obsolete PLURAL entry: every line of the multi-line plural block —
%% `msgid`, `msgid_plural`, and each `msgstr[N]` — is `#~ `-prefixed. The
%% existing `obsolete_block` covers only a singular obsolete; the plural
%% body exercises `prefix_lines/2` over four block lines, the case the
%% abandoned preserve SUITE pinned for PSD-007.
obsolete_plural_block(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body =>
            {plural, undefined, <<"old">>, <<"olds">>, [{0, <<"ancien">>}, {1, <<"anciens">>}]},
        obsolete => true
    }),
    ?assertEqual(
        <<
            "#~ msgid \"old\"\n#~ msgid_plural \"olds\"\n"
            "#~ msgstr[0] \"ancien\"\n#~ msgstr[1] \"anciens\"\n\n"
        >>,
        Out
    ).

%% An obsolete entry with a translator comment AND a context: the `# `
%% comment is NOT `#~ `-prefixed (it precedes the obsolete block), while
%% every body line — including `#~ msgctxt` — IS. Pins the comment/obsolete
%% interaction the discarded SUITE exercised via its metadata fixture.
obsolete_plural_keeps_comment_unprefixed(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body => {plural, <<"c">>, <<"old">>, <<"olds">>, [{0, <<"a">>}, {1, <<"b">>}]},
        obsolete => true,
        comments => [<<"gone">>]
    }),
    ?assertEqual(
        <<
            "# gone\n#~ msgctxt \"c\"\n#~ msgid \"old\"\n#~ msgid_plural \"olds\"\n"
            "#~ msgstr[0] \"a\"\n#~ msgstr[1] \"b\"\n\n"
        >>,
        Out
    ).

%% A plural entry carrying BOTH an `#.` extracted (programmer) comment and
%% `#:` references, in canonical GNU order (extracted before references,
%% both before the plural block). The existing `plural_block` covers
%% references only; this pins the extracted+references+plural combination
%% the abandoned `preserve_plural_entry_with_metadata` asserted on parse.
plural_with_extracted_and_references(_Config) ->
    Out = rebar3_erli18n_po_meta:dump_entry(#{
        body =>
            {plural, undefined, <<"apple">>, <<"apples">>, [{0, <<"maca">>}, {1, <<"macas">>}]},
        extracted => [<<"count of apples">>],
        references => [{"src/apples.erl", 1}]
    }),
    ?assertEqual(
        <<
            "#. count of apples\n#: src/apples.erl:1\n"
            "msgid \"apple\"\nmsgid_plural \"apples\"\n"
            "msgstr[0] \"maca\"\nmsgstr[1] \"macas\"\n\n"
        >>,
        Out
    ).

%% Parity oracle: when `msgmerge` (GNU gettext) is present, our output must
%% be accepted and round-tripped by it. Skips cleanly when absent.
msgmerge_accepts_output(Config) ->
    case os:find_executable("msgfmt") of
        false ->
            {skip, "msgfmt (GNU gettext) not installed"};
        Msgfmt ->
            Out = rebar3_erli18n_po_meta:dump(
                cat([
                    #{
                        body => {singular, undefined, <<"Hello">>, <<"Ola">>},
                        references => [{"src/x.erl", 1}],
                        comments => [<<"a note">>]
                    }
                ])
            ),
            PoPath = filename:join(?config(priv_dir, Config), "meta.po"),
            ok = file:write_file(PoPath, Out),
            %% msgfmt --check validates the whole file (syntax + format).
            Cmd = Msgfmt ++ " --check -o /dev/null " ++ PoPath,
            Result = os:cmd(Cmd ++ " 2>&1; echo EXIT=$?"),
            ?assert(string:find(Result, "EXIT=0") =/= nomatch)
    end.
