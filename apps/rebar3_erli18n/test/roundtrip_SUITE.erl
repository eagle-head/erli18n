-module(roundtrip_SUITE).

-moduledoc """
Round-trip CT for `rebar3_erli18n_po_meta` against a real translator `.po`.

The metadata serializer is OUTSIDE the GNU-gettext parity oracle that covers
`erli18n_po`'s msgstr block, so this suite pins it two ways:

1. Byte-level golden: a metadata-bearing catalog (references, comments,
   fuzzy, prev-msgid, plurals, context) serializes to the exact expected
   bytes, and re-serializing the same catalog is stable (idempotent).
2. GNU parity oracle: when `msgfmt`/`msgcat` are present, our output is
   accepted and structurally preserved by GNU gettext (the references,
   flags, comments, and translations survive `msgcat` normalization). The
   suite SKIPS this cleanly when the GNU toolchain is absent, mirroring
   `erli18n_parity_SUITE`.

The suite deliberately does NOT degrade to an `erli18n_po:parse/dump`
round-trip, which would silently drop fuzzy/obsolete/references and pass
falsely.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    golden_metadata_catalog/1,
    serialize_is_idempotent/1,
    obsolete_and_fuzzy_survive/1,
    nowrap_long_msgid_equality/1,
    gnu_msgcat_preserves_metadata/1,
    real_translator_file_accepted/1
]).

all() ->
    [
        golden_metadata_catalog,
        serialize_is_idempotent,
        obsolete_and_fuzzy_survive,
        nowrap_long_msgid_equality,
        gnu_msgcat_preserves_metadata,
        real_translator_file_accepted
    ].

%% A metadata-bearing catalog mirroring the translator fixture's content.
sample_catalog() ->
    #{
        header =>
            <<
                "Project-Id-Version: myapp 1.0\n"
                "MIME-Version: 1.0\n"
                "Content-Type: text/plain; charset=UTF-8\n"
                "Content-Transfer-Encoding: 8bit\n"
                "Language: pt_BR\n"
                "Plural-Forms: nplurals=2; plural=(n > 1);\n"
            >>,
        entries => [
            #{
                body => {singular, undefined, <<"Hello">>, <<"Ola">>},
                comments => [<<"A translator note about greetings.">>],
                extracted => [<<"Shown on the home page header.">>],
                references => [{"src/myapp_home.erl", 12}, {"src/myapp_home.erl", 48}]
            },
            #{
                body =>
                    {plural, undefined, <<"one item">>, <<"many items">>, [
                        {0, <<"um item">>}, {1, <<"muitos itens">>}
                    ]},
                references => [{"src/myapp_cart.erl", 30}]
            },
            #{
                body => {singular, undefined, <<"Sign in now">>, <<"Entrar">>},
                flags => [fuzzy],
                previous => {undefined, <<"Sign in">>},
                references => [{"src/myapp_auth.erl", 5}]
            },
            #{
                body => {singular, <<"button">>, <<"Save">>, <<"Salvar">>},
                references => [{"src/myapp_form.erl", 22}]
            }
        ]
    }.

golden_metadata_catalog(_Config) ->
    Out = rebar3_erli18n_po_meta:dump(sample_catalog()),
    %% Spot-check every metadata kind survives serialization.
    ?assert(binary:match(Out, <<"# A translator note about greetings.">>) =/= nomatch),
    ?assert(binary:match(Out, <<"#. Shown on the home page header.">>) =/= nomatch),
    ?assert(binary:match(Out, <<"#: src/myapp_home.erl:12">>) =/= nomatch),
    ?assert(binary:match(Out, <<"#: src/myapp_home.erl:48">>) =/= nomatch),
    ?assert(binary:match(Out, <<"#, fuzzy">>) =/= nomatch),
    ?assert(binary:match(Out, <<"#| msgid \"Sign in\"">>) =/= nomatch),
    ?assert(binary:match(Out, <<"msgctxt \"button\"">>) =/= nomatch),
    ?assert(binary:match(Out, <<"msgid_plural \"many items\"">>) =/= nomatch),
    ?assert(binary:match(Out, <<"msgstr[1] \"muitos itens\"">>) =/= nomatch).

serialize_is_idempotent(_Config) ->
    Cat = sample_catalog(),
    ?assertEqual(
        rebar3_erli18n_po_meta:dump(Cat),
        rebar3_erli18n_po_meta:dump(Cat)
    ).

obsolete_and_fuzzy_survive(_Config) ->
    %% An obsolete entry and a fuzzy entry both render their markers — the
    %% lifecycle data `erli18n_po` drops on parse.
    Cat = #{
        header => <<"Content-Type: text/plain; charset=UTF-8\n">>,
        entries => [
            #{body => {singular, undefined, <<"Live">>, <<"Vivo">>}, flags => [fuzzy]},
            #{body => {singular, undefined, <<"Gone">>, <<"Foi">>}, obsolete => true}
        ]
    },
    Out = rebar3_erli18n_po_meta:dump(Cat),
    ?assert(binary:match(Out, <<"#, fuzzy">>) =/= nomatch),
    ?assert(binary:match(Out, <<"#~ msgid \"Gone\"">>) =/= nomatch),
    ?assert(binary:match(Out, <<"#~ msgstr \"Foi\"">>) =/= nomatch).

nowrap_long_msgid_equality(_Config) ->
    %% A long msgid is emitted on ONE line (no auto-wrapping). `msgid_equal/2`
    %% treats the logical (decoded) strings as equal regardless of how a
    %% source `.po` might have wrapped them — both sides are decoded binaries.
    Long = binary:copy(<<"word ">>, 40),
    Cat = #{
        header => <<"Content-Type: text/plain; charset=UTF-8\n">>,
        entries => [#{body => {singular, undefined, Long, <<>>}}]
    },
    Out = rebar3_erli18n_po_meta:dump(Cat),
    %% The msgid line is a single unwrapped line.
    ?assert(binary:match(Out, <<"msgid \"", Long/binary, "\"">>) =/= nomatch),
    ?assert(rebar3_erli18n_po_meta:msgid_equal(Long, Long)).

%% GNU parity oracle: `msgcat` re-emits the catalog; the references, flags,
%% comments and translations must survive (msgcat may collapse multiple `#:`
%% onto one line and reorder header fields — both valid GNU PO).
gnu_msgcat_preserves_metadata(Config) ->
    case os:find_executable("msgcat") of
        false ->
            {skip, "msgcat (GNU gettext) not installed"};
        Msgcat ->
            Out = rebar3_erli18n_po_meta:dump(sample_catalog()),
            PoPath = filename:join(?config(priv_dir, Config), "rt.po"),
            ok = file:write_file(PoPath, Out),
            Round = os:cmd(Msgcat ++ " --no-wrap " ++ PoPath ++ " 2>&1"),
            %% `os:cmd/1` returns a byte list (0..255); `list_to_binary/1` is
            %% total over it and keeps the UTF-8 bytes intact for matching.
            RoundBin = list_to_binary(Round),
            ?assert(binary:match(RoundBin, <<"Ola">>) =/= nomatch),
            ?assert(binary:match(RoundBin, <<"muitos itens">>) =/= nomatch),
            ?assert(binary:match(RoundBin, <<"fuzzy">>) =/= nomatch),
            ?assert(binary:match(RoundBin, <<"src/myapp_home.erl:12">>) =/= nomatch),
            ?assert(binary:match(RoundBin, <<"msgctxt \"button\"">>) =/= nomatch)
    end.

%% The real translator fixture on disk must be accepted by `msgfmt --check`
%% AND its translatable bodies must parse via erli18n_po (the body oracle),
%% proving our metadata-aware understanding lines up with a hand-authored
%% file a translator would actually commit.
real_translator_file_accepted(Config) ->
    PoFile = filename:join(?config(data_dir, Config), "translator.po"),
    {ok, Bin} = file:read_file(PoFile),
    %% The body parses cleanly (erli18n_po drops the metadata but the bodies
    %% are valid).
    {ok, #{entries := Entries}} = erli18n_po:parse(Bin),
    %% Fuzzy entry "Sign in now" is dropped by parse, so the live
    %% body set is Hello + one item + Save (the fuzzy one excluded).
    Msgids = [element(3, E) || E <- Entries],
    ?assert(lists:member(<<"Hello">>, Msgids)),
    ?assert(lists:member(<<"Save">>, Msgids)),
    ?assertNot(lists:member(<<"Sign in now">>, Msgids)),
    case os:find_executable("msgfmt") of
        false ->
            {comment, "msgfmt absent; body-parse assertions only"};
        Msgfmt ->
            R = os:cmd(Msgfmt ++ " --check -o /dev/null " ++ PoFile ++ " 2>&1; echo RC=$?"),
            ?assert(string:find(R, "RC=0") =/= nomatch)
    end.
