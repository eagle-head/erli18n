%% coding: utf-8
-module(rebar3_erli18n_adequacy_SUITE).

-moduledoc """
Test-adequacy backfill for the rebar3_erli18n plugin providers.

Generated from the plugin test-adequacy audit (findings F1..F33). Each case
pins ONE confirmed finding (or a tight cluster of duplicate findings) that the
existing `providers_SUITE`/`extract_SUITE`/`po_meta_SUITE`/`jaro_SUITE` left
unasserted, and is crafted to KILL the specific surviving mutant the finding
names — primarily:

- `lists:all` -> `lists:any` at `prv_report.erl:216` (a partially-translated
  plural must count as UNtranslated);
- the `fuzzy_one` nomatch branch at `prv_merge.erl:245` (a brand-new msgid
  carries NO `#, fuzzy` and NO `#|`);
- the exact-carryover reference refresh at `prv_merge.erl:211-213`;
- the integer binary-segment Unicode-scalar bounds at
  `extract_forms.erl:355-362`;
- the multibyte `chars_to_binary` normalization at `extract_forms.erl:369`;
- the `is_dir(LC_MESSAGES)` locale filter at `prv_report.erl:168-174`;
- the jaro empty/identical/unicode contract at `jaro.erl:80-86`.

RED/GREEN expectation: GREEN for every case EXCEPT the two write-failure
fault-injection cases (`extract_write_failure_returns_error`,
`merge_write_failure_returns_error`). Those assert the documented structural
`{error, _}` contract; the production code currently hard-matches `ok =
file:write_file(...)`, so on a non-root host they CRASH (badmatch) instead of
returning `{error, _}` and the assertion FAILS RED — surfacing the bug. On a
root host the directory-permission injection cannot block the write, so they
`{skip, ...}` cleanly. This mirrors the `providers_SUITE` rebar3-state harness
and the `po_meta_SUITE` msgfmt skip-guard idiom.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2]).
-export([
    report_partial_plural_counts_untranslated/1,
    merge_new_msgid_no_fuzzy_no_previous/1,
    merge_exact_refreshes_references/1,
    jaro_empty_identical_and_unicode/1,
    extract_integer_segment_unicode_bounds/1,
    extract_multibyte_literal_msgid/1,
    report_excludes_stray_non_locale_dir/1,
    extract_check_round_trip/1,
    po_meta_dump_roundtrip_msgfmt/1,
    extract_write_failure_returns_error/1,
    merge_write_failure_returns_error/1,
    extract_pot_dir_unwritable_returns_error/1,
    merge_ensure_dir_failure_returns_error/1
]).

all() ->
    [
        report_partial_plural_counts_untranslated,
        merge_new_msgid_no_fuzzy_no_previous,
        merge_exact_refreshes_references,
        jaro_empty_identical_and_unicode,
        extract_integer_segment_unicode_bounds,
        extract_multibyte_literal_msgid,
        report_excludes_stray_non_locale_dir,
        extract_check_round_trip,
        po_meta_dump_roundtrip_msgfmt,
        extract_write_failure_returns_error,
        merge_write_failure_returns_error,
        extract_pot_dir_unwritable_returns_error,
        merge_ensure_dir_failure_returns_error
    ].

init_per_testcase(TC, Config) ->
    Proj = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    SrcDir = filename:join([Proj, "src"]),
    ok = filelib:ensure_path(SrcDir),
    [{proj, Proj}, {src_dir, SrcDir} | Config].

%% =========================
%% Harness (mirrors providers_SUITE)
%% =========================

%% Build a rebar_state whose single project app lives at the test project
%% dir, with the given parsed args (a proplist).
state(Config, Args) ->
    Proj = ?config(proj, Config),
    {ok, App} = rebar_app_info:new(myapp, "0.1.0", Proj),
    St0 = rebar_state:new(),
    St1 = rebar_state:project_apps(St0, [App]),
    rebar_state:command_parsed_args(St1, {Args, []}).

write_consumer(Config, Body) ->
    File = filename:join(?config(src_dir, Config), "myapp_strings.erl"),
    ok = file:write_file(File, Body),
    File.

greet_module(Msgids) ->
    Funs = [
        ["f", integer_to_list(N), "() -> erli18n:gettext(<<\"", M, "\">>).\n"]
     || {N, M} <- lists:zip(lists:seq(1, length(Msgids)), Msgids)
    ],
    Exports = string:join(
        ["f" ++ integer_to_list(N) ++ "/0" || N <- lists:seq(1, length(Msgids))],
        ", "
    ),
    iolist_to_binary([
        "-module(myapp_strings).\n",
        "-export([",
        Exports,
        "]).\n",
        Funs
    ]).

pot_path(Config, Domain) ->
    filename:join([?config(proj, Config), "priv", "gettext", Domain ++ ".pot"]).

po_path(Config, Locale, Domain) ->
    filename:join([
        ?config(proj, Config), "priv", "gettext", Locale, "LC_MESSAGES", Domain ++ ".po"
    ]).

%% Run `Fun` with this process's group leader swapped for a capturing I/O
%% server, returning everything the providers wrote to the console as one
%% UTF-8 binary (the REAL report text `rebar3 erli18n report` prints).
capture_console(Fun) ->
    OldGL = group_leader(),
    Server = spawn_link(fun() -> console_io_loop([]) end),
    group_leader(Server, self()),
    try
        Fun()
    after
        group_leader(OldGL, self())
    end,
    Server ! {get, self()},
    receive
        {console_data, Data} -> Data
    after 5000 ->
        ct:fail(console_capture_timeout)
    end.

console_io_loop(Buf) ->
    receive
        {io_request, From, ReplyAs, {put_chars, _Enc, Chars}} ->
            From ! {io_reply, ReplyAs, ok},
            console_io_loop([Chars | Buf]);
        {io_request, From, ReplyAs, {put_chars, _Enc, M, F, A}} ->
            From ! {io_reply, ReplyAs, ok},
            console_io_loop([apply(M, F, A) | Buf]);
        {io_request, From, ReplyAs, _Other} ->
            From ! {io_reply, ReplyAs, {error, enotsup}},
            console_io_loop(Buf);
        {get, From} ->
            From ! {console_data, iolist_to_binary(lists:reverse(Buf))}
    end.

%% Parse a runtime-written source module through the extractor (epp), exactly
%% like extract_SUITE's `scan/2` but for a module written into priv_dir at run
%% time (so rebar3 never tries to compile it). No include dirs are needed: the
%% module carries no `-include`, and bare gettext resolves to the `default`
%% domain.
scan_source(Config, Name, Src) ->
    File = filename:join(?config(priv_dir, Config), Name),
    ok = file:write_file(File, Src),
    rebar3_erli18n_extract_forms:scan_file(File, []).

%% Does binary `Bin` decode to a string containing the Unicode code point `Cp`?
%% (Ported from extract_SUITE: asserts a boundary scalar round-trips into the
%% extracted msgid bytes.)
has_codepoint(Bin, Cp) ->
    case unicode:characters_to_list(Bin) of
        Chars when is_list(Chars) -> lists:member(Cp, Chars);
        _ -> false
    end.

msgids(Entries) ->
    [maps:get(msgid, E) || E <- Entries].

%% =========================
%% Tests
%% =========================

%% F1/F2/F5/F8/F10/F16: a PARTIALLY-translated plural (`msgstr[0]` non-empty,
%% `msgstr[1]` empty) MUST count as UNtranslated. This kills the
%% `lists:all -> lists:any` mutant at prv_report.erl:216: `lists:all` over
%% [{0,<<"um gato">>},{1,<<>>}] is false (correct -> 0/1), whereas `lists:any`
%% would be true (wrong -> 1/1). The existing report_counts_translated_plural
%% fills BOTH forms and only ever asserts 1/1, so it cannot see this.
report_partial_plural_counts_untranslated(Config) ->
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([p/1]).\n",
            "p(N) -> erli18n:ngettext(<<\"one cat\">>, <<\"many cats\">>, N).\n"
        ])
    ),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    %% Fill ONLY the singular plural-form; leave msgstr[1] empty.
    T = binary:replace(
        Bytes,
        <<"msgstr[0] \"\"\nmsgstr[1] \"\"">>,
        <<"msgstr[0] \"um gato\"\nmsgstr[1] \"\"">>
    ),
    %% Sanity: the half-filled replacement actually took.
    ?assertNotEqual(Bytes, T),
    ok = file:write_file(Po, T),
    Text = capture_console(fun() ->
        {ok, _} = rebar3_erli18n_prv_report:do(state(Config, []))
    end),
    ?assertEqual(
        <<
            "erli18n translation report\n"
            "==========================\n"
            "\n"
            "domain: default\n"
            "  pt_BR    0/1 translated  (1 missing)\n"
            "\n"
            "\n"
        >>,
        Text
    ).

%% F3/F9/F11: the fuzzy_one nomatch branch (prv_merge.erl:245). A brand-new
%% msgid merged into a fresh/empty locale (Removed=[], best_match -> nomatch)
%% must be emitted as a plain untranslated entry with NEITHER a `#, fuzzy` flag
%% NOR a `#|` previous-msgid line. A mutant that injected `flags => [fuzzy]` or
%% `previous => ...` on the nomatch branch would survive every existing merge
%% test (none assert the ABSENCE of those lines on a first merge).
merge_new_msgid_no_fuzzy_no_previous(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    %% The brand-new entry IS present...
    ?assertNotEqual(nomatch, binary:match(Bytes, <<"msgid \"Hello\"">>)),
    %% ...but carries no fuzzy flag and no previous-msgid hint.
    ?assertEqual(nomatch, binary:match(Bytes, <<"#, fuzzy">>)),
    ?assertEqual(nomatch, binary:match(Bytes, <<"#|">>)).

%% F12/F22/F30: exact-carryover refreshes the `#:` references (prv_merge.erl
%% :211-213 takes Refs from the FRESH PotE). Translate a msgid, MOVE its call
%% site to a later line, re-extract and re-merge: the carried-over entry keeps
%% its translation AND its `#:` reference reflects the NEW line. A mutant
%% emitting `references => []` drops the `:8` line; one reusing the stale refs
%% keeps `:3`. Either way this case fails; the existing merge tests never
%% relocate a call site, so they cannot see it.
merge_exact_refreshes_references(Config) ->
    %% Call site on line 3.
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([f/0]).\n",
            "f() -> erli18n:gettext(<<\"Hello\">>).\n"
        ])
    ),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    Po = po_path(Config, "pt_BR", "default"),
    {ok, Bytes} = file:read_file(Po),
    %% The first merge referenced line 3.
    ?assertNotEqual(nomatch, binary:match(Bytes, <<"myapp_strings.erl:3">>)),
    %% Translate it.
    Translated = binary:replace(
        Bytes, <<"msgid \"Hello\"\nmsgstr \"\"">>, <<"msgid \"Hello\"\nmsgstr \"Ola\"">>
    ),
    ok = file:write_file(Po, Translated),
    %% Move the SAME call site down to line 8 (five padding lines).
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([f/0]).\n",
            "%% pad\n%% pad\n%% pad\n%% pad\n%% pad\n",
            "f() -> erli18n:gettext(<<\"Hello\">>).\n"
        ])
    ),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    {ok, After} = file:read_file(Po),
    %% Translation preserved AND the reference refreshed to the new line.
    ?assertNotEqual(nomatch, binary:match(After, <<"msgstr \"Ola\"">>)),
    ?assertNotEqual(nomatch, binary:match(After, <<"myapp_strings.erl:8">>)),
    ?assertEqual(nomatch, binary:match(After, <<"myapp_strings.erl:3">>)).

%% F13/F17/F23/F24/F25/F27/F29: the jaro empty/identical/unicode contract
%% (jaro.erl:80-86). similarity(<<>>,<<>>) is the documented 1.0; an empty
%% needle yields a defined nomatch (no crash); a multibyte UTF-8 candidate is
%% scored by CODE POINT (the exact "café" scores 1.0, "cafe" strictly less)
%% and the deterministic pick is order-independent. The entire jaro_SUITE uses
%% only ASCII non-empty inputs, so none of these boundaries are exercised.
jaro_empty_identical_and_unicode(_Config) ->
    %% Two empty strings are fully similar (documented contract).
    ?assertEqual(1.0, rebar3_erli18n_jaro:similarity(<<>>, <<>>)),
    %% Empty needle vs non-empty: defined 0.0, below threshold -> nomatch.
    ?assertEqual(0.0, rebar3_erli18n_jaro:similarity(<<>>, <<"x">>)),
    ?assertEqual(nomatch, rebar3_erli18n_jaro:best_match(<<>>, [<<"x">>])),
    %% A multibyte exact match scores exactly 1.0 (no codepoint-vs-byte miscount).
    ?assertEqual(
        1.0, rebar3_erli18n_jaro:similarity(<<"café"/utf8>>, <<"café"/utf8>>)
    ),
    %% "cafe" (ASCII) is strictly LESS similar to "café" than the exact match,
    %% so the deterministic pick is the multibyte exact candidate at 1.0...
    ?assert(rebar3_erli18n_jaro:similarity(<<"café"/utf8>>, <<"cafe">>) < 1.0),
    ?assertEqual(
        {ok, <<"café"/utf8>>, 1.0},
        rebar3_erli18n_jaro:best_match(<<"café"/utf8>>, [<<"cafe">>, <<"café"/utf8>>])
    ),
    %% ...regardless of candidate order (determinism).
    ?assertEqual(
        {ok, <<"café"/utf8>>, 1.0},
        rebar3_erli18n_jaro:best_match(<<"café"/utf8>>, [<<"café"/utf8>>, <<"cafe">>])
    ).

%% F4/F7/F14/F19: the integer binary-segment Unicode-scalar guard
%% (extract_forms.erl:355-362). The four valid-range boundaries 0, 16#10FFFF,
%% 16#D7FF, 16#E000 must ACCEPT (their scalar round-trips into the extracted
%% msgid bytes); the surrogate 16#DFFF and the over-range 16#110000 must SKIP.
%% Because an accepted out-of-range/surrogate value would raise `badarg` on
%% `<<Int/utf8>>` and ABORT the whole scan, "scan returns {ok,...} and the
%% sibling literal still extracts" kills the bound-flip mutants (`=< 16#10FFFE`,
%% `< 16#D7FF`, `> 16#E000`, `> 16#DFFE`, `=< 16#110000`, `> 0`). The mixed
%% string+integer segment (`<<"A", 16#E9/utf8, "z">>`) also pins the fold over
%% heterogeneous segments. extract_SUITE tests only `<<65,66,67>>` (mid-range)
%% and `<<16#D800>>` (one surrogate).
extract_integer_segment_unicode_bounds(Config) ->
    Src = <<
        "-module(segmsg).\n"
        "-export([a/0, b/0, c/0, d/0, e/0, g/0, h/0, s/0]).\n"
        "a() -> erli18n:gettext(<<0>>).\n"
        "b() -> erli18n:gettext(<<16#10FFFF/utf8>>).\n"
        "c() -> erli18n:gettext(<<16#D7FF>>).\n"
        "d() -> erli18n:gettext(<<16#E000>>).\n"
        "e() -> erli18n:gettext(<<16#DFFF>>).\n"
        "g() -> erli18n:gettext(<<16#110000>>).\n"
        "h() -> erli18n:gettext(<<\"A\", 16#E9/utf8, \"z\">>).\n"
        "s() -> erli18n:gettext(<<\"sibling\">>).\n"
    >>,
    %% The scan must COMPLETE (no badarg abort on the skipped segments).
    {ok, default, Entries} = scan_source(Config, "segmsg.erl", Src),
    Ms = msgids(Entries),
    %% Accept partition: each boundary scalar round-trips into a msgid.
    ?assert(lists:any(fun(M) -> has_codepoint(M, 0) end, Ms)),
    ?assert(lists:any(fun(M) -> has_codepoint(M, 16#10FFFF) end, Ms)),
    ?assert(lists:any(fun(M) -> has_codepoint(M, 16#D7FF) end, Ms)),
    ?assert(lists:any(fun(M) -> has_codepoint(M, 16#E000) end, Ms)),
    %% Skip partition: surrogate and over-range produce NO entry.
    ?assertNot(lists:any(fun(M) -> has_codepoint(M, 16#DFFF) end, Ms)),
    ?assertNot(lists:any(fun(M) -> has_codepoint(M, 16#110000) end, Ms)),
    %% Mixed string+integer segment folds to the concatenated UTF-8 bytes.
    ?assert(lists:member(<<65, 16#E9/utf8, 122>>, Ms)),
    %% The sibling literal still extracts -> the scan ran past every skip.
    ?assert(lists:member(<<"sibling">>, Ms)).

%% F6/F15/F26: multibyte literal-string msgid normalization
%% (extract_forms.erl:329-330 / :369). A non-ASCII binary literal
%% (`<<"café"/utf8>>`) AND a non-ASCII charlist (`"café"`) must both normalize
%% to the exact source UTF-8 bytes (<<99,97,102,195,169>>), with no mojibake
%% (a latin1-vs-utf8 corruption would double-encode the é). Every asserted
%% msgid in extract_SUITE is ASCII, so the multibyte branch of chars_to_binary
%% is never observably exercised. The fixture carries a `coding: utf-8`
%% directive so epp decodes the é to one code point.
extract_multibyte_literal_msgid(Config) ->
    Src = <<
        "%% coding: utf-8\n"
        "-module(mbmsg).\n"
        "-export([a/0, b/0]).\n"
        "a() -> erli18n:gettext(<<\"café\"/utf8>>).\n"
        "b() -> erli18n:gettext(\"café\").\n"/utf8
    >>,
    {ok, default, Entries} = scan_source(Config, "mbmsg.erl", Src),
    Ms = msgids(Entries),
    Expected = <<"café"/utf8>>,
    %% Both the binary-literal and the charlist forms normalize identically.
    ?assertEqual(<<99, 97, 102, 195, 169>>, Expected),
    ?assertEqual(2, length(Ms)),
    ?assert(lists:all(fun(M) -> M =:= Expected end, Ms)).

%% F28/F31/F32: the `is_dir(LC_MESSAGES)` locale filter (prv_report.erl
%% :168-174). A stray sibling directory under the catalog root that lacks an
%% LC_MESSAGES subdir must NOT appear as a locale row. Because the filter sorts
%% locales and "NOTALOCALE" < "pt_BR", a dropped filter would surface a phantom
%% "(no catalog)" row BEFORE pt_BR, so the byte-exact block assertion fails.
%% Every existing all-locales report test only ever has the pt_BR dir present.
report_excludes_stray_non_locale_dir(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
    %% A stray directory directly under the catalog root, with NO LC_MESSAGES.
    Stray = filename:join([?config(proj, Config), "priv", "gettext", "NOTALOCALE"]),
    ok = filelib:ensure_path(Stray),
    Text = capture_console(fun() ->
        {ok, _} = rebar3_erli18n_prv_report:do(state(Config, []))
    end),
    %% Only pt_BR is reported; the stray dir is filtered out entirely.
    ?assertEqual(nomatch, binary:match(Text, <<"NOTALOCALE">>)),
    ?assertEqual(
        <<
            "erli18n translation report\n"
            "==========================\n"
            "\n"
            "domain: default\n"
            "  pt_BR    0/1 translated  (1 missing)\n"
            "\n"
            "\n"
        >>,
        Text
    ).

%% F33: the extract -> check pipeline round-trip invariant. Extraction writes
%% each `.pot` via `po_meta:dump(entries_to_pot(...))`; check recomputes the
%% identical bytes and compares. Over a project mixing every call-site shape
%% (bare/domained/contextual/plural/f-family across two domains), a fresh
%% extract followed immediately by check must return `{ok, _}` (no drift) in
%% BOTH full and `--names-only` modes — the documented no-false-drift contract.
extract_check_round_trip(Config) ->
    write_consumer(
        Config,
        iolist_to_binary([
            "-module(myapp_strings).\n",
            "-export([a/0, b/0, c/0, d/1, e/0]).\n",
            "a() -> erli18n:gettext(<<\"Bare\">>).\n",
            "b() -> erli18n:dgettext(accounts, <<\"Domained\">>).\n",
            "c() -> erli18n:pgettext(<<\"menu\">>, <<\"Contextual\">>).\n",
            "d(N) -> erli18n:ngettext(<<\"one\">>, <<\"many\">>, N).\n",
            "e() -> erli18n:gettextf(<<\"Hi %{name}\">>, #{name => <<\"x\">>}).\n"
        ])
    ),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    %% Both .pot domains are committed by the same extraction the check reads.
    ?assert(filelib:is_file(pot_path(Config, "default"))),
    ?assert(filelib:is_file(pot_path(Config, "accounts"))),
    %% Fresh extract -> check passes in BOTH modes (no false drift).
    {ok, _} = rebar3_erli18n_prv_check:do(state(Config, [])),
    {ok, _} = rebar3_erli18n_prv_check:do(state(Config, [{names_only, true}])).

%% F18: the po_meta dump differential oracle. `dump/1` over a catalog mixing
%% singular+plural bodies, unicode msgids/translations, `#:` references, `#.`
%% extracted comments and a `#|` previous-msgid must produce GNU-valid PO bytes
%% that `msgfmt --check` accepts. Skips cleanly when msgfmt is absent (mirrors
%% po_meta_SUITE/erli18n_parity_SUITE). Broadens the existing
%% msgmerge_accepts_output (singular ASCII only) across the metadata domain.
po_meta_dump_roundtrip_msgfmt(Config) ->
    case os:find_executable("msgfmt") of
        false ->
            {skip, "msgfmt (GNU gettext) not installed"};
        Msgfmt ->
            %% A COMPLETE gettext header: `msgfmt --check` runs `--check-header`,
            %% and a catalog that carries a plural entry must declare
            %% `Plural-Forms: nplurals=...; plural=...;` or msgfmt rejects it with
            %% two fatal errors. `po_meta:dump` serializes the header verbatim (it
            %% does not synthesize Plural-Forms — that is operator/merge metadata),
            %% so the fixture must supply a valid one for the round-trip to be a
            %% meaningful "dump output is msgfmt-valid" assertion.
            Cat = #{
                header =>
                    <<
                        "Project-Id-Version: erli18n-test\n"
                        "MIME-Version: 1.0\n"
                        "Content-Type: text/plain; charset=UTF-8\n"
                        "Content-Transfer-Encoding: 8bit\n"
                        "Plural-Forms: nplurals=2; plural=(n != 1);\n"
                    >>,
                entries => [
                    #{
                        body => {singular, undefined, <<"café"/utf8>>, <<"café-pt"/utf8>>},
                        references => [{"src/x.erl", 1}],
                        extracted => [<<"a unicode note"/utf8>>]
                    },
                    #{
                        body =>
                            {plural, undefined, <<"one cat">>, <<"many cats">>, [
                                {0, <<"um gato">>}, {1, <<"muitos gatos">>}
                            ]},
                        references => [{"src/p.erl", 2}]
                    },
                    #{
                        body => {singular, <<"ctx">>, <<"New">>, <<"Novo">>},
                        flags => [fuzzy],
                        previous => {undefined, <<"Old">>}
                    }
                ]
            },
            Out = rebar3_erli18n_po_meta:dump(Cat),
            PoPath = filename:join(?config(priv_dir, Config), "adequacy_meta.po"),
            ok = file:write_file(PoPath, Out),
            Cmd = Msgfmt ++ " --check -o /dev/null " ++ PoPath,
            Result = os:cmd(Cmd ++ " 2>&1; echo EXIT=$?"),
            ?assert(string:find(Result, "EXIT=0") =/= nomatch)
    end.

%% F20 (M26 write-failure, expected RED): when the destination `.pot` cannot be
%% written, extract `do/1` is spec'd to return `{error, string()}`. Here the
%% target `priv/gettext/default.pot` already exists as a DIRECTORY, so
%% `file:write_file(..., Bytes)` returns `{error, eisdir}`. The production code
%% (`ok = file:write_file(Path, Bytes)`, prv_extract.erl:85) hard-matches `ok`,
%% so it badmatch-CRASHES instead of returning the structured error -> this
%% assertion FAILS RED, surfacing the bug. The orchestrator should confirm the
%% red status.
extract_write_failure_returns_error(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    %% Pre-create the target .pot path as a directory (write -> eisdir).
    PotAsDir = pot_path(Config, "default"),
    ok = filelib:ensure_path(PotAsDir),
    ?assertMatch({error, _}, rebar3_erli18n_prv_extract:do(state(Config, []))).

%% F21 (write-failure, expected RED on a non-root host): when the target `.po`
%% cannot be written, merge `do/1` is spec'd to return `{error, string()}`. The
%% locale is brand-new so read_old hits enoent and returns an empty catalog (so
%% the WRITE path is reached, not the read path the existing
%% merge_po_path_unreadable covers). The LC_MESSAGES dir is made read-only so
%% `file:write_file(Path, ...)` returns `{error, eacces}`. The production code
%% (`ok = file:write_file(...)`, prv_merge.erl:130) hard-matches `ok` and
%% badmatch-CRASHES -> the assertion FAILS RED. On a root host the permission
%% cannot block the write, so the case skips cleanly.
merge_write_failure_returns_error(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    {ok, _} = rebar3_erli18n_prv_extract:do(state(Config, [])),
    Po = po_path(Config, "pt_BR", "default"),
    Dir = filename:dirname(Po),
    %% Create the LC_MESSAGES dir (Po itself stays absent -> read_old=enoent).
    ok = filelib:ensure_dir(Po),
    ok = file:change_mode(Dir, 8#0500),
    Probe = filename:join(Dir, "probe"),
    case file:write_file(Probe, <<>>) of
        {error, _} ->
            %% Non-root: writes into Dir are genuinely blocked. Restore the
            %% mode via `after` so a badmatch CRASH (the current bug) cannot
            %% leave the dir unwritable for priv_dir teardown.
            try
                Result = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
                ?assertMatch({error, _}, Result)
            after
                file:change_mode(Dir, 8#0700)
            end;
        ok ->
            ok = file:delete(Probe),
            ok = file:change_mode(Dir, 8#0700),
            {skip, "running as root: directory permissions do not block writes"}
    end.

%% Coverage for the `filelib:ensure_path/1` FAILURE arm of extract's `write_pots/2`:
%% point `--pot-dir` at a path nested UNDER a regular file, so the pot dir cannot
%% be created. extract `do/1` must surface `{error, _}` (the structured
%% write_failed error), not crash — distinct from the eisdir write-failure above,
%% which exercises the per-file `file:write_file` arm.
extract_pot_dir_unwritable_returns_error(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    Priv = ?config(priv_dir, Config),
    Blocker = filename:join(Priv, "extract_blocker_file"),
    ok = file:write_file(Blocker, <<>>),
    BlockedPotDir = filename:join(Blocker, "gettext"),
    ?assertMatch(
        {error, _},
        rebar3_erli18n_prv_extract:do(state(Config, [{pot_dir, BlockedPotDir}]))
    ).

%% Coverage for the `filelib:ensure_dir/1` FAILURE arm of merge's `write_po/2`
%% (distinct from the `file:write_file` eacces arm above). The LOCALE dir is made
%% read-only so `ensure_dir` cannot CREATE the `LC_MESSAGES` subdir — yet the `.po`
%% itself is genuinely absent, so `read_old` returns `enoent` (a brand-new locale,
%% NOT a read error) and the WRITE path is reached. merge `do/1` must return
%% `{error, _}` rather than badmatch-crash. Skips cleanly on a root host (where
%% directory permissions do not block `mkdir`), and restores the mode via `after`
%% so a crash cannot leave the tree unwritable for priv_dir teardown.
merge_ensure_dir_failure_returns_error(Config) ->
    write_consumer(Config, greet_module([<<"Hello">>])),
    Po = po_path(Config, "pt_BR", "default"),
    LcMessages = filename:dirname(Po),
    LocaleDir = filename:dirname(LcMessages),
    ok = filelib:ensure_path(LocaleDir),
    ok = file:change_mode(LocaleDir, 8#0500),
    ProbeDir = filename:join(LocaleDir, "probe_dir"),
    case file:make_dir(ProbeDir) of
        {error, _} ->
            %% Non-root: creating a subdir under the read-only locale dir is
            %% genuinely blocked, so `ensure_dir` will fail.
            try
                Result = rebar3_erli18n_prv_merge:do(state(Config, [{locale, "pt_BR"}])),
                ?assertMatch({error, _}, Result)
            after
                file:change_mode(LocaleDir, 8#0700)
            end;
        ok ->
            ok = file:del_dir(ProbeDir),
            ok = file:change_mode(LocaleDir, 8#0700),
            {skip, "running as root: directory permissions do not block mkdir"}
    end.
