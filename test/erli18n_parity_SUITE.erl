%%% =====================================================================
%%% Parity harness: erli18n (subject) vs gettexter + GNU msgfmt (oracle).
%%%
%%% Spec source-of-truth:
%%%   * `parity_specs.md` §1-§4 — overall harness shape, oracle pin.
%%%   * `parity_specs.md` §4 "Oracle canônico — pinning de versão msgfmt"
%%%     — `msgfmt >= 0.21` is mandatory; we validate at suite init.
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
%%%   * If `gettexter` is not on the code path → same skip path.
%%%
%%% Scope (v0.1):
%%%   * 5 core scenarios covering singular, plural fr, plural ru,
%%%     contextual, empty-msgstr-fallback.
%%%   * The remaining 4 `.feature` files in `parity_tests/` are
%%%     documented as backlog in `parity_specs.md` §5 ("conjunto de
%%%     fixtures (8 mínimos)"); they are not blocking v0.1.
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
    parity_plural_fr/1,
    parity_plural_ru/1,
    parity_contextual_lookup/1,
    parity_empty_msgstr_fallback/1
]).

%% Domain used across all scenarios. Must match the .po fixture's
%% filename convention (`<DOMAIN>.po`) so `gettexter:bindtextdomain/2`
%% and msgfmt can find it under
%%   `<base>/<locale>/LC_MESSAGES/<domain>.po|.mo`.
-define(DOMAIN, parity_default).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        parity_singular_lookup,
        parity_singular_miss_fallback,
        parity_plural_fr,
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
            case code:ensure_loaded(gettexter) of
                {module, gettexter} ->
                    {ok, _} = application:ensure_all_started(erli18n),
                    {ok, _} = application:ensure_all_started(gettexter),
                    Base = make_locale_root(),
                    [
                        {msgfmt_version, MsgfmtVersion},
                        {locale_base, Base}
                        | Config
                    ];
                _ ->
                    {skip,
                        "gettexter not on the code path — parity oracle "
                        "unavailable"}
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
                    "newer toolchain (see parity_specs.md §4)."};
        {error, {parse_failed, Out}} ->
            {skip, "could not parse msgfmt --version output: " ++ Out}
    end.

end_per_suite(_Config) ->
    _ = application:stop(gettexter),
    _ = application:stop(erli18n),
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, Config) ->
    %% Best-effort cleanup so iterations don't leak ETS state in either
    %% oracle or subject.
    Base = ?config(locale_base, Config),
    Locales = [<<"fr">>, <<"ru">>, <<"xx">>, <<"en">>],
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
            %% gettexter has no per-locale unload — the catalog stays
            %% across tests but `bindtextdomain` is rebound for each
            %% test so the path resolution is fresh.
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
        "msgstr \"Bonjour\"\n"
    >>,
    install_fixture(Base, <<"fr">>, Po),
    load_both(Base, <<"fr">>),
    OracleOut = gettexter:gettext(<<"Hello">>, <<"fr">>),
    SubjectOut = erli18n:gettext(?DOMAIN, <<"Hello">>, <<"fr">>),
    ?assertEqual(<<"Bonjour">>, OracleOut),
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
        "msgstr \"Bonjour\"\n"
    >>,
    install_fixture(Base, <<"fr">>, Po),
    load_both(Base, <<"fr">>),
    OracleOut = gettexter:gettext(<<"NoTranslation">>, <<"fr">>),
    SubjectOut = erli18n:gettext(?DOMAIN, <<"NoTranslation">>, <<"fr">>),
    %% Per R1 (BR-MIGRAR-001): miss returns msgid unchanged.
    ?assertEqual(<<"NoTranslation">>, OracleOut),
    ?assertEqual(OracleOut, SubjectOut),
    ok.

%% PARITY-02 (Scenario Outline: English-style French plural).
%% gettexter pluralization uses gettexter's compiled .mo plural rule;
%% erli18n evaluates the same C-expression from the .po header.
parity_plural_fr(Config) ->
    Base = ?config(locale_base, Config),
    Po = <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n > 1);\\n\"\n"
        "\n"
        "msgid \"Fish\"\n"
        "msgid_plural \"Fishes\"\n"
        "msgstr[0] \"Poisson\"\n"
        "msgstr[1] \"Poissons\"\n"
    >>,
    install_fixture(Base, <<"fr">>, Po),
    load_both(Base, <<"fr">>),
    %% French (n > 1): 0 -> singular(0); 1 -> singular(0); 2+ -> plural(1).
    lists:foreach(
        fun(N) -> check_plural(<<"Fish">>, <<"Fishes">>, N, <<"fr">>) end,
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
    install_fixture(Base, <<"ru">>, Po),
    load_both(Base, <<"ru">>),
    lists:foreach(
        fun(N) -> check_plural(<<"Stone">>, <<"Stones">>, N, <<"ru">>) end,
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
        "msgstr \"Sauver\"\n"
        "\n"
        "msgctxt \"menu\"\n"
        "msgid \"Save\"\n"
        "msgstr \"Enregistrer\"\n"
    >>,
    install_fixture(Base, <<"fr">>, Po),
    load_both(Base, <<"fr">>),
    O1 = gettexter:pgettext(<<"button">>, <<"Save">>, <<"fr">>),
    S1 = erli18n:pgettext(?DOMAIN, <<"button">>, <<"Save">>, <<"fr">>),
    O2 = gettexter:pgettext(<<"menu">>, <<"Save">>, <<"fr">>),
    S2 = erli18n:pgettext(?DOMAIN, <<"menu">>, <<"Save">>, <<"fr">>),
    ?assertEqual(<<"Sauver">>, O1),
    ?assertEqual(O1, S1),
    ?assertEqual(<<"Enregistrer">>, O2),
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
        "msgstr \"Bonjour\"\n"
        "\n"
        "msgid \"Empty\"\n"
        "msgstr \"\"\n"
    >>,
    install_fixture(Base, <<"fr">>, Po),
    load_both(Base, <<"fr">>),
    OracleEmpty = gettexter:gettext(<<"Empty">>, <<"fr">>),
    SubjectEmpty = erli18n:gettext(?DOMAIN, <<"Empty">>, <<"fr">>),
    ?assertEqual(<<"Empty">>, OracleEmpty),
    ?assertEqual(OracleEmpty, SubjectEmpty),
    ok.

%% =========================
%% Plural-comparison helper
%% =========================

check_plural(Singular, Plural, N, Locale) ->
    Oracle = gettexter:ngettext(Singular, Plural, N, Locale),
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

%% Load the same locale into both libraries. `gettexter` discovers the
%% `.mo` via its `bindtextdomain` + `ensure_loaded` convention; erli18n
%% loads the `.po` directly (its native format) — both ultimately
%% surface identical translations from the same source.
load_both(Base, Locale) ->
    ok = gettexter:bindtextdomain(?DOMAIN, Base),
    {ok, _} = gettexter:ensure_loaded(?DOMAIN, lc_messages, Locale),
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
