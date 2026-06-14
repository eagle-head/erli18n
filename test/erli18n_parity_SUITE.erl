%%% =====================================================================
%%% Parity harness: erli18n (subject) vs the GNU gettext CLI (oracle).
%%%
%%% The oracle is the real GNU `gettext` / `ngettext` command-line tools
%%% (shelled out via `os:cmd/1`), driven against the same compiled `.mo`
%%% catalog that `msgfmt` produces from each scenario's inline `.po`.
%%% `msgfmt` remains the `.po -> .mo` compiler; the runtime lookups are
%%% delegated to `gettext`/`ngettext` rather than an in-BEAM library.
%%%
%%% Rules:
%%%   * Canonical oracle — msgfmt version pinning: `msgfmt >= 0.21` is
%%%     mandatory; we validate at suite init.
%%%   * `parity_tests/01-singular-lookup.feature` (PARITY-01)
%%%   * `parity_tests/02-plural-lookup.feature` (PARITY-02)
%%%   * `parity_tests/03-contextual-lookup.feature` (PARITY-03)
%%%   * `parity_tests/09-edge-cases.feature` (PARITY-09)
%%%
%%% Skip policy (release-blocking but environment-tolerant):
%%%   * If `msgfmt` is missing OR < 0.21 → suite is skipped with a clear
%%%     message; the build still succeeds. This keeps the suite green on
%%%     dev boxes without the GNU gettext toolchain installed (notably
%%%     Alpine without `apk add gettext`, macOS without `brew install
%%%     gettext`). CI is expected to install the toolchain and exercise
%%%     the full suite.
%%%   * If the `gettext`/`ngettext` runtime binaries are missing → same
%%%     skip path.
%%%   * If the required system locales (`pt_BR.UTF-8`, `ru_RU.UTF-8`)
%%%     are not generated, GNU gettext returns the source msgid
%%%     unchanged, so a round-trip probe at suite init detects this and
%%%     skips with an actionable message instead of producing false
%%%     parity results.
%%%
%%% Scope (v0.1):
%%%   * 5 core scenarios covering singular, plural pt_BR, plural ru,
%%%     contextual, empty-msgstr-fallback.
%%%   * The remaining 4 `.feature` files in `parity_tests/` are
%%%     documented as backlog (fixture set, 8 minimum); they are not
%%%     blocking v0.1.
%%% =====================================================================
-module(erli18n_parity_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    suite/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    parity_singular_lookup/1,
    parity_singular_miss_fallback/1,
    parity_plural_pt_br/1,
    parity_plural_ru/1,
    parity_contextual_lookup/1,
    parity_empty_msgstr_fallback/1
]).

%% Domain used across all scenarios. Must match the .po fixture's
%% filename convention (`<DOMAIN>.po`) so the GNU gettext CLI (via
%% `TEXTDOMAINDIR` + `-d <DOMAIN>`) and msgfmt can find it under
%%   `<base>/<locale>/LC_MESSAGES/<domain>.po|.mo`.
-define(DOMAIN, parity_default).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        parity_singular_lookup,
        parity_singular_miss_fallback,
        parity_plural_pt_br,
        parity_plural_ru,
        parity_contextual_lookup,
        parity_empty_msgstr_fallback
    ].

%% =========================
%% Suite-level setup / skip policy
%% =========================

init_per_suite(Config) ->
    case check_msgfmt() of
        {ok, MsgfmtVersion} ->
            case check_gettext_cli() of
                ok ->
                    case check_locales([<<"pt_BR">>, <<"ru_RU">>]) of
                        ok ->
                            {ok, _} = application:ensure_all_started(erli18n),
                            Base = make_locale_root(),
                            [
                                {msgfmt_version, MsgfmtVersion},
                                {locale_base, Base}
                                | Config
                            ];
                        {error, {locale_missing, Loc}} ->
                            {skip,
                                "system locale " ++ binary_to_list(Loc) ++
                                    ".UTF-8 not generated — GNU gettext "
                                    "returns the source string, so parity "
                                    "cannot be checked. Generate it "
                                    "(Debian/Ubuntu: add the line to "
                                    "/etc/locale.gen and run `sudo "
                                    "locale-gen`, or `sudo localedef -i " ++
                                    binary_to_list(Loc) ++ " -f UTF-8 " ++
                                    binary_to_list(Loc) ++
                                    ".UTF-8`). "
                                    "Required: pt_BR.UTF-8 and ru_RU.UTF-8."}
                    end;
                {error, missing} ->
                    {skip,
                        "GNU gettext/ngettext runtime binaries not installed "
                        "— parity oracle unavailable. Install GNU gettext "
                        "(`apt install gettext`, `brew install gettext`, "
                        "`apk add gettext`)."}
            end;
        {error, missing} ->
            {skip,
                "msgfmt binary not installed — parity oracle "
                "unavailable. Install GNU gettext >= 0.21 "
                "(`apt install gettext`, `brew install gettext`, "
                "`apk add gettext`)."};
        {error, {too_old, V}} ->
            {skip,
                "msgfmt " ++ V ++
                    " < 0.21 — parity oracle requires "
                    "GNU gettext >= 0.21."};
        {error, {parse_failed, Out}} ->
            {skip, "could not parse msgfmt --version output: " ++ Out}
    end.

end_per_suite(_Config) ->
    _ = application:stop(erli18n),
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, Config) ->
    %% Best-effort cleanup so iterations don't leak ETS state in either
    %% oracle or subject.
    Base = ?config(locale_base, Config),
    Locales = [<<"pt_BR">>, <<"ru_RU">>, <<"xx">>, <<"en">>],
    lists:foreach(
        fun(L) ->
            %% Best-effort: server may be down between tests, or the
            %% catalog may never have been loaded. Both are normal in
            %% cleanup — swallow any class of exception.
            try
                erli18n:unload(?DOMAIN, L)
            catch
                _:_ -> ok
            end,
            %% The GNU gettext CLI oracle has no in-BEAM state to unload —
            %% it reads the `.mo` from disk per call, and `Base` is
            %% removed below, so nothing else to clean up here.
            ok
        end,
        Locales
    ),
    file:del_dir_r(Base),
    ok.

%% =========================
%% Scenarios
%% =========================

%% PARITY-01 scenario: implicit-locale gettext returns identical
%% translation.
parity_singular_lookup(Config) ->
    Base = ?config(locale_base, Config),
    Po = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
        "msgid \"Hello\"\n"
        "msgstr \"Olá\"\n"/utf8
    >>,
    install_fixture(Base, <<"pt_BR">>, Po),
    load_both(Base, <<"pt_BR">>),
    OracleOut = oracle_gettext(Base, ?DOMAIN, <<"Hello">>, <<"pt_BR">>),
    SubjectOut = erli18n:gettext(?DOMAIN, <<"Hello">>, <<"pt_BR">>),
    ?assertEqual(<<"Olá"/utf8>>, OracleOut),
    ?assertEqual(OracleOut, SubjectOut),
    ok.

%% PARITY-01 / R1-fallback scenario: lookup miss returns original input.
parity_singular_miss_fallback(Config) ->
    Base = ?config(locale_base, Config),
    Po = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
        "msgid \"Hello\"\n"
        "msgstr \"Olá\"\n"/utf8
    >>,
    install_fixture(Base, <<"pt_BR">>, Po),
    load_both(Base, <<"pt_BR">>),
    OracleOut =
        oracle_gettext(Base, ?DOMAIN, <<"NoTranslation">>, <<"pt_BR">>),
    SubjectOut = erli18n:gettext(?DOMAIN, <<"NoTranslation">>, <<"pt_BR">>),
    %% Per R1 (BR-MIGRAR-001): miss returns msgid unchanged.
    ?assertEqual(<<"NoTranslation">>, OracleOut),
    ?assertEqual(OracleOut, SubjectOut),
    ok.

%% PARITY-02 (Scenario Outline: English-style Brazilian Portuguese
%% plural). The GNU `ngettext` CLI selects the form from the compiled
%% `.mo` plural rule; erli18n evaluates the same C-expression from the
%% `.po` header. pt_BR uses `plural=(n > 1)`, identical to the prior
%% French fixture, so the [0,1,2,5,100] expectations are unchanged.
parity_plural_pt_br(Config) ->
    Base = ?config(locale_base, Config),
    Po = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n > 1);\\n\"\n"
        "\n"
        "msgid \"Fish\"\n"
        "msgid_plural \"Fishes\"\n"
        "msgstr[0] \"Peixe\"\n"
        "msgstr[1] \"Peixes\"\n"
    >>,
    install_fixture(Base, <<"pt_BR">>, Po),
    load_both(Base, <<"pt_BR">>),
    %% pt_BR (n > 1): 0 -> singular(0); 1 -> singular(0); 2+ -> plural(1).
    lists:foreach(
        fun(N) ->
            check_plural(Base, <<"Fish">>, <<"Fishes">>, N, <<"pt_BR">>)
        end,
        [0, 1, 2, 5, 100]
    ),
    ok.

%% PARITY-02 (Scenario Outline: Russian 3-form rule).
parity_plural_ru(Config) ->
    Base = ?config(locale_base, Config),
    Po = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : "
        "n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2;\\n\"\n"
        "\n"
        "msgid \"Stone\"\n"
        "msgid_plural \"Stones\"\n"
        "msgstr[0] \"Kamen\"\n"
        "msgstr[1] \"Kamnia\"\n"
        "msgstr[2] \"Kamney\"\n"
    >>,
    install_fixture(Base, <<"ru_RU">>, Po),
    load_both(Base, <<"ru_RU">>),
    lists:foreach(
        fun(N) ->
            check_plural(Base, <<"Stone">>, <<"Stones">>, N, <<"ru_RU">>)
        end,
        [1, 2, 5, 11, 21, 100]
    ),
    ok.

%% PARITY-03: pgettext lookup with explicit context. The msgctxt
%% boundary is the EOT byte in `.mo`; erli18n keeps `{Ctx, Msgid}`
%% separated per PSD-006. Both libraries must surface the
%% context-specific translation.
parity_contextual_lookup(Config) ->
    Base = ?config(locale_base, Config),
    Po = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
        "msgctxt \"button\"\n"
        "msgid \"Save\"\n"
        "msgstr \"Salvar\"\n"
        "\n"
        "msgctxt \"menu\"\n"
        "msgid \"Save\"\n"
        "msgstr \"Gravar\"\n"
    >>,
    install_fixture(Base, <<"pt_BR">>, Po),
    load_both(Base, <<"pt_BR">>),
    O1 = oracle_pgettext(Base, ?DOMAIN, <<"button">>, <<"Save">>, <<"pt_BR">>),
    S1 = erli18n:pgettext(?DOMAIN, <<"button">>, <<"Save">>, <<"pt_BR">>),
    O2 = oracle_pgettext(Base, ?DOMAIN, <<"menu">>, <<"Save">>, <<"pt_BR">>),
    S2 = erli18n:pgettext(?DOMAIN, <<"menu">>, <<"Save">>, <<"pt_BR">>),
    ?assertEqual(<<"Salvar">>, O1),
    ?assertEqual(O1, S1),
    ?assertEqual(<<"Gravar">>, O2),
    ?assertEqual(O2, S2),
    ok.

%% PARITY-01 / PSD-003: empty `msgstr ""` falls back to msgid in both
%% libraries (R1).
parity_empty_msgstr_fallback(Config) ->
    Base = ?config(locale_base, Config),
    Po = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
        "msgid \"Hello\"\n"
        "msgstr \"Olá\"\n"
        "\n"
        "msgid \"Empty\"\n"
        "msgstr \"\"\n"/utf8
    >>,
    install_fixture(Base, <<"pt_BR">>, Po),
    load_both(Base, <<"pt_BR">>),
    OracleEmpty = oracle_gettext(Base, ?DOMAIN, <<"Empty">>, <<"pt_BR">>),
    SubjectEmpty = erli18n:gettext(?DOMAIN, <<"Empty">>, <<"pt_BR">>),
    ?assertEqual(<<"Empty">>, OracleEmpty),
    ?assertEqual(OracleEmpty, SubjectEmpty),
    ok.

%% =========================
%% Plural-comparison helper
%% =========================

check_plural(Base, Singular, Plural, N, Locale) ->
    Oracle = oracle_ngettext(Base, ?DOMAIN, Singular, Plural, N, Locale),
    Subject = erli18n:ngettext(?DOMAIN, Singular, Plural, N, Locale),
    case Oracle =:= Subject of
        true ->
            true;
        false ->
            ct:pal(
                "PARITY MISMATCH n=~p locale=~s~n  oracle=~p~n  "
                "subject=~p~n",
                [N, Locale, Oracle, Subject]
            ),
            ?assert(false)
    end.

%% =========================
%% GNU gettext CLI oracle
%% =========================
%%
%% The oracle shells out to the real GNU `gettext`/`ngettext` binaries.
%% Each helper builds an env prefix that points the CLI at the compiled
%% `.mo` (`TEXTDOMAINDIR=<Base>` + `-d <DOMAIN>`) and forces the locale
%% (`LANGUAGE`/`LC_ALL=<Locale>.UTF-8`), then captures stdout and strips
%% exactly one trailing newline.

%% Shell out to GNU `gettext` for a singular lookup.
oracle_gettext(Base, Domain, Msgid, Locale) ->
    Cmd = io_lib:format(
        "~s gettext -d ~s ~s",
        [oracle_env(Base, Locale), atom_to_list(Domain), oracle_quote(Msgid)]
    ),
    run_oracle(Cmd).

%% Shell out to GNU `ngettext` for a plural lookup. `N` is a
%% non-negative integer rendered as bare digits (the CLI's COUNT arg).
oracle_ngettext(Base, Domain, Singular, Plural, N, Locale) ->
    Cmd = io_lib:format(
        "~s ngettext -d ~s ~s ~s ~w",
        [
            oracle_env(Base, Locale),
            atom_to_list(Domain),
            oracle_quote(Singular),
            oracle_quote(Plural),
            N
        ]
    ),
    run_oracle(Cmd).

%% Shell out to GNU `gettext` for a contextual (msgctxt) lookup. The
%% `.mo` contextual key is `Context <EOT> Msgid` where `<EOT>` is byte
%% `0x04`; GNU gettext has no context flag, so we pass that exact byte
%% sequence as the single msgid argument.
oracle_pgettext(Base, Domain, Context, Msgid, Locale) ->
    Key = iolist_to_binary([Context, <<4>>, Msgid]),
    Cmd = io_lib:format(
        "~s gettext -d ~s ~s",
        [oracle_env(Base, Locale), atom_to_list(Domain), oracle_quote(Key)]
    ),
    run_oracle(Cmd).

%% Build the "TEXTDOMAINDIR=.. LANGUAGE=.. LC_ALL=..UTF-8" env prefix.
oracle_env(Base, Locale) ->
    L = binary_to_list(Locale),
    io_lib:format(
        "TEXTDOMAINDIR=~ts LANGUAGE=~s LC_ALL=~s.UTF-8",
        [Base, L, L]
    ).

%% Run the oracle command and capture stdout as RAW BYTES, dropping
%% exactly one trailing "\n". We read via a port in `binary` mode rather
%% than `os:cmd/1` on purpose: `os:cmd/1` decodes its output using the
%% emulator's unicode mode, so a UTF-8 translation like "Olá" comes back
%% as the codepoint list `[$O, $l, 225]` and `list_to_binary/1` would then
%% re-truncate it to Latin-1 (`<<$O, $l, 225>>`), failing the byte-for-byte
%% comparison against the subject. The port hands us the exact UTF-8 bytes
%% the `gettext` CLI emitted. We go through `/bin/sh -c` so the
%% `VAR=val cmd` env prefix built by `oracle_env/2` is honoured.
run_oracle(CmdIoList) ->
    Cmd = lists:flatten(CmdIoList),
    Port = open_port(
        {spawn_executable, "/bin/sh"},
        [binary, stream, eof, hide, {args, ["-c", Cmd]}]
    ),
    strip_trailing_nl(drain_port(Port, <<>>)).

drain_port(Port, Acc) ->
    receive
        {Port, {data, Bytes}} ->
            drain_port(Port, <<Acc/binary, Bytes/binary>>);
        {Port, eof} ->
            %% The port may already be closed by the time we see eof; port_close/1
            %% raises error:badarg in that case, which we ignore. Any other error
            %% propagates rather than being silently swallowed.
            try
                port_close(Port)
            catch
                error:badarg -> ok
            end,
            Acc
    end.

strip_trailing_nl(<<>>) ->
    <<>>;
strip_trailing_nl(Bin) ->
    Sz = byte_size(Bin),
    case binary:at(Bin, Sz - 1) of
        $\n -> binary:part(Bin, 0, Sz - 1);
        _ -> Bin
    end.

%% POSIX single-quote a binary/iolist for safe inclusion in an os:cmd
%% shell string. Single quotes preserve every byte literally (incl. the
%% 0x04 EOT used for msgctxt keys); only the single-quote char needs the
%% classic '\'' break-out.
oracle_quote(Bin) when is_binary(Bin) ->
    oracle_quote(binary_to_list(Bin));
oracle_quote(Str) when is_list(Str) ->
    Escaped = lists:flatmap(
        fun
            ($') -> "'\\''";
            (C) -> [C]
        end,
        Str
    ),
    "'" ++ Escaped ++ "'".

%% =========================
%% Install fixture: write .po to disk, run msgfmt to produce .mo
%% =========================

%% Layout convention shared by both libraries:
%%   <Base>/<Locale>/LC_MESSAGES/<Domain>.po
%%   <Base>/<Locale>/LC_MESSAGES/<Domain>.mo
install_fixture(Base, Locale, PoBin) ->
    Dir = filename:join([Base, binary_to_list(Locale), "LC_MESSAGES"]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    PoPath = po_path(Base, Locale),
    MoPath = mo_path(Base, Locale),
    ok = file:write_file(PoPath, PoBin),
    %% `msgfmt --check` validates the catalog. Output goes to MoPath.
    Cmd = io_lib:format("msgfmt --check -o ~ts ~ts", [MoPath, PoPath]),
    case os:cmd(lists:flatten(Cmd) ++ " 2>&1") of
        "" -> ok;
        Other -> ct:pal("msgfmt stderr/stdout: ~ts~n", [Other])
    end,
    case filelib:is_regular(MoPath) of
        true -> ok;
        false -> error({msgfmt_failed, PoPath, MoPath})
    end.

%% Load the locale into the subject (erli18n). The GNU gettext CLI oracle
%% needs no in-BEAM bind — it reads the compiled `.mo` from disk directly
%% (via `TEXTDOMAINDIR`/`-d <DOMAIN>`), which `install_fixture` already
%% wrote. Both ultimately surface translations from the same `.po`
%% source.
load_both(Base, Locale) ->
    PoPath = po_path(Base, Locale),
    case erli18n:ensure_loaded(?DOMAIN, Locale, PoPath) of
        {ok, _} -> ok;
        {error, Reason} -> error({erli18n_load_failed, Reason, PoPath})
    end.

po_path(Base, Locale) ->
    filename:join([
        Base,
        binary_to_list(Locale),
        "LC_MESSAGES",
        atom_to_list(?DOMAIN) ++ ".po"
    ]).

mo_path(Base, Locale) ->
    filename:join([
        Base,
        binary_to_list(Locale),
        "LC_MESSAGES",
        atom_to_list(?DOMAIN) ++ ".mo"
    ]).

make_locale_root() ->
    U = erlang:unique_integer([positive, monotonic]),
    Dir = filename:join(
        "/tmp",
        "erli18n_parity_" ++ integer_to_list(U)
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

%% =========================
%% Runtime CLI + locale availability checks
%% =========================

%% Both runtime binaries must exist; they ship together in
%% gettext-runtime.
check_gettext_cli() ->
    case {os:find_executable("gettext"), os:find_executable("ngettext")} of
        {false, _} -> {error, missing};
        {_, false} -> {error, missing};
        {_, _} -> ok
    end.

%% A locale is "usable" iff GNU gettext, pointed at a tiny throwaway
%% catalog under that locale, returns the TRANSLATION rather than the
%% source string. This is the only reliable cross-distro probe: parsing
%% `locale -a` is brittle (names vary: pt_BR vs pt_BR.utf8). We compile a
%% one-entry .mo with msgfmt and check the round-trip. We probe with the
%% exact locale strings the tests use so the probe and the real lookups
%% share fate.
check_locales([]) ->
    ok;
check_locales([Loc | Rest]) ->
    Probe = make_locale_root(),
    try
        Dir = filename:join([Probe, binary_to_list(Loc), "LC_MESSAGES"]),
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        Po = <<
            "msgid \"\"\n"
            "msgstr \"\"\n"
            "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
            "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
            "\nmsgid \"__probe__\"\nmsgstr \"__ok__\"\n"
        >>,
        PoP = filename:join(Dir, "probe.po"),
        MoP = filename:join(Dir, "probe.mo"),
        ok = file:write_file(PoP, Po),
        _ = os:cmd(
            lists:flatten(
                io_lib:format("msgfmt -o ~ts ~ts 2>&1", [MoP, PoP])
            )
        ),
        Got = oracle_gettext(Probe, probe, <<"__probe__">>, Loc),
        case Got of
            <<"__ok__">> -> check_locales(Rest);
            _ -> {error, {locale_missing, Loc}}
        end
    after
        file:del_dir_r(Probe)
    end.

%% =========================
%% msgfmt version check
%% =========================

check_msgfmt() ->
    case os:find_executable("msgfmt") of
        false ->
            {error, missing};
        _ ->
            Out = os:cmd("msgfmt --version 2>&1"),
            case parse_msgfmt_version(Out) of
                {ok, V} ->
                    case version_ge(V, "0.21") of
                        true -> {ok, V};
                        false -> {error, {too_old, V}}
                    end;
                error ->
                    {error, {parse_failed, Out}}
            end
    end.

%% GNU msgfmt prints its version on the first line, e.g.
%% "msgfmt (GNU gettext-tools) 0.21\n...". We pluck the last token of
%% that first line.
parse_msgfmt_version(Output) ->
    case string:split(Output, "\n") of
        [FirstLine | _] ->
            Tokens = string:lexemes(FirstLine, " \t"),
            case lists:last(Tokens) of
                "" -> error;
                V -> {ok, V}
            end;
        _ ->
            error
    end.

%% Lexicographic numeric component comparison: "0.21" >= "0.21" → true;
%% "0.19.5" >= "0.21" → false.
version_ge(A, B) ->
    Ai = parse_version(A),
    Bi = parse_version(B),
    Ai >= Bi.

parse_version(V) ->
    Parts = string:split(V, ".", all),
    [list_to_integer(numeric_prefix(P)) || P <- Parts].

%% Some msgfmt builds tack non-digit suffixes onto the patch level
%% ("0.21.1-dev"); take the leading digits only.
numeric_prefix(Str) ->
    case lists:takewhile(fun(C) -> C >= $0 andalso C =< $9 end, Str) of
        "" -> "0";
        Pfx -> Pfx
    end.
