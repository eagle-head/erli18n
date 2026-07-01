%%% =====================================================================
%%% Parity harness: erli18n (subject) vs the GNU gettext CLI (oracle).
%%%
%%% The oracle is PRE-COMPUTED, out of band, by
%%% `bin/extract-gettext-table.sh` (run inside the `gettext-extract`
%%% Docker service against the LATEST GNU gettext). That step compiles
%%% every scenario's `.po`, runs the real CLI, and records the expected
%%% byte-for-byte output of each scenario into an oracle artifact. The
%%% suite then loads erli18n against the SAME `.po` source and asserts
%%% byte-equality against the recorded oracle. Decoupling extraction from
%%% comparison means the suite needs no gettext toolchain, no system
%%% locales, and no network — only the two committed/extracted data
%%% files:
%%%
%%%   * `apps/erli18n/test/parity_matrix.eterm` — the COMMITTED scenario
%%%     list, shared verbatim by the extractor and this suite. Each entry
%%%     is a single lookup (one `op`, one expected output) so the oracle
%%%     maps 1:1 by `id`.
%%%   * `$ERLI18N_PARITY_ORACLE` — the extracted oracle artifact
%%%     (`parity_oracle.eterm`), produced by the gettext-extract step and
%%%     pointed at by the environment variable the gate sets.
%%%
%%% Skip / fail policy (the only behavioral subtlety):
%%%   * If `ERLI18N_PARITY_ORACLE` is UNSET, the suite SKIPS cleanly. This
%%%     is the "not the gate context" path: a developer running
%%%     `rebar3 ct`, or the gate's own `ct --cover` pass, never sets the
%%%     env, so the suite must not turn those green runs red. The gettext
%%%     outputs those runs would need simply do not exist yet.
%%%   * If `ERLI18N_PARITY_ORACLE` IS set, this is the GATE CONTEXT and
%%%     there is NO skip. A missing/unreadable/malformed oracle, a missing
%%%     scenario matrix, an empty matrix, a scenario absent from the
%%%     oracle, or ANY byte divergence is a HARD FAIL with an actionable
%%%     message naming the scenario, the expected (oracle) vs got
%%%     (erli18n) bytes, and the recorded gettext version. The gate's
%%%     dedicated "parity" step sets the env (mirroring `require_elp`), so
%%%     that path is exercised on every `--full` run.
%%%
%%% Scenario format (`parity_matrix.eterm`, `file:consult/1`-readable —
%%% either one wrapping list term `[ #{...}, #{...} ].` or a sequence of
%%% map terms `#{...}.\n#{...}.`):
%%%
%%%   #{
%%%       id           => binary(),   %% unique; also the oracle key
%%%       op           => gettext | ngettext | pgettext | npgettext,
%%%       locale       => binary(),   %% e.g. <<"pt_BR">>
%%%       domain       => binary(),   %% informational; the subject keys by ?DOMAIN
%%%       plural_forms => binary(),   %% the `.po` Plural-Forms header value
%%%       context      => binary() | undefined,  %% set for pgettext / npgettext
%%%       msgid        => binary(),
%%%       msgid_plural => binary() | undefined,  %% set for ngettext / npgettext
%%%       n            => integer() | undefined, %% set for ngettext / npgettext
%%%       present      => boolean(),  %% false = header-only catalog (a miss)
%%%       translations => [binary()], %% msgstr / msgstr[0..N-1]
%%%       description  => binary()
%%%   }
%%%
%%% Both this suite (build_po/1) and bin/extract-gettext-table.sh assemble an
%%% identical `.po` from these fields, so neither stores a ready-made catalog.
%%%
%%% Oracle format (`$ERLI18N_PARITY_ORACLE`, `file:consult/1`-readable). The
%%% canonical artifact bin/extract-gettext-table.sh emits is a flat sequence
%%% of terms — one `{Id, Expected}` per scenario, preceded by a single
%%% `{gettext_version, V}` term:
%%%
%%%   {gettext_version, <<"0.23.1">>}.
%%%   {<<"singular_de_hit">>, <<72,97,108,108,111>>}.
%%%   ...
%%%
%%% The reader also tolerates a single wrapping map
%%% `#{gettext_version => _, results => #{Id => Expected}}`, a bare
%%% `#{Id => Expected}` map, or a `[{Id, Expected}, ...]` proplist; when no
%%% version term is present it is reported as "unknown".
%%% =====================================================================
-module(erli18n_parity_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    suite/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([parity_against_oracle/1]).

%% Domain used as the subject's catalog key across all scenarios. The
%% oracle is domain-agnostic (the GNU CLI derives the expected output from
%% the `.po` itself), so any fixed atom works; we keep the historical one.
-define(DOMAIN, parity_default).

%% Environment variables.
%%   * ERLI18N_PARITY_ORACLE — REQUIRED in the gate context; path to the
%%     extracted oracle artifact. Its presence is the gate-context signal.
%%   * ERLI18N_PARITY_MATRIX — OPTIONAL override for the scenario matrix
%%     path; defaults to `parity_matrix.eterm` next to this suite.
-define(ORACLE_ENV, "ERLI18N_PARITY_ORACLE").
-define(MATRIX_ENV, "ERLI18N_PARITY_MATRIX").
-define(MATRIX_FILE, "parity_matrix.eterm").

suite() ->
    [{timetrap, {seconds, 300}}].

all() ->
    [parity_against_oracle].

%% =========================
%% Suite-level setup / skip policy
%% =========================

init_per_suite(Config) ->
    case os:getenv(?ORACLE_ENV) of
        false ->
            {skip,
                ?ORACLE_ENV
                " is not set - parity runs only in the gate context, "
                "which sets this variable to the extracted gettext oracle "
                "(.gate/artifacts/parity_oracle.eterm). Outside the gate "
                "the suite skips so `rebar3 ct` stays green; run the full "
                "gate (bin/quality-gate.sh --full, or `make parity`) to "
                "produce the oracle and exercise this suite."};
        OraclePath ->
            {ok, _} = application:ensure_all_started(erli18n),
            [{oracle_path, OraclePath} | Config]
    end.

end_per_suite(_Config) ->
    %% Only meaningful when init_per_suite started the app (gate context);
    %% a no-op stop on a not-started app raises, so swallow it.
    try
        application:stop(erli18n)
    catch
        _:_ -> ok
    end,
    ok.

%% =========================
%% The data-driven parity test
%% =========================
%%
%% A single testcase intentionally aggregates ALL scenarios: the matrix is
%% runtime data (read from disk), so it cannot be expanded into one
%% exported testcase per scenario. Aggregation is also better for a gate —
%% one run surfaces EVERY divergence at once rather than stopping at the
%% first. Any structural problem (missing oracle/matrix, empty matrix) or
%% any per-scenario divergence is a hard `ct:fail/1`.
parity_against_oracle(Config) ->
    OraclePath = ?config(oracle_path, Config),
    {Version, Oracle} = load_oracle_or_fail(OraclePath),
    Scenarios = load_matrix_or_fail(Config),
    Base = make_base(),
    try
        Results = [evaluate(Base, Oracle, S) || S <- Scenarios],
        case [R || {_Id, Status} = R <- Results, Status =/= ok] of
            [] ->
                ct:log(
                    "erli18n parity: ~p scenario(s) matched the GNU gettext "
                    "oracle byte-for-byte (gettext ~ts).",
                    [length(Results), version_str(Version)]
                ),
                ok;
            Bad ->
                Report = format_report(Version, Bad),
                ct:pal("~ts", [Report]),
                ct:fail(
                    lists:flatten(
                        io_lib:format(
                            "erli18n parity FAILED: ~p of ~p scenario(s) "
                            "diverged from the GNU gettext oracle "
                            "(gettext ~ts). Details:~n~ts",
                            [
                                length(Bad),
                                length(Results),
                                version_str(Version),
                                Report
                            ]
                        )
                    )
                )
        end
    after
        file:del_dir_r(Base)
    end.

%% =========================
%% Per-scenario evaluation
%% =========================

%% Returns `{Id, ok}` on a byte-for-byte match, or a tagged failure tuple
%% otherwise. Per-scenario exceptions (malformed entry, load failure) are
%% caught and reported per scenario so one bad row does not mask the rest.
evaluate(Base, Oracle, Scenario) when is_map(Scenario) ->
    case maps:get(id, Scenario, undefined) of
        undefined ->
            {~"<scenario missing id>", {error, error, missing_field_id, []}};
        Id ->
            try
                Got = run_scenario(Base, Scenario),
                case Oracle of
                    #{Id := Got} ->
                        {Id, ok};
                    #{Id := Expected} ->
                        {Id, {mismatch, Expected, Got}};
                    _ ->
                        {Id, {no_oracle_entry, Got}}
                end
            catch
                Class:Reason:Stack ->
                    {Id, {error, Class, Reason, Stack}}
            end
    end;
evaluate(_Base, _Oracle, Scenario) ->
    {~"<non-map scenario>", {error, error, {not_a_map, Scenario}, []}}.

%% Install the scenario's `.po` into a fresh, hermetic directory, load it
%% into erli18n (the subject), run the requested lookup, then unload. We
%% unload before AND after because `ensure_loaded/3` is idempotent: a
%% second scenario reusing the same {Domain, Locale} would otherwise read
%% the FIRST scenario's catalog instead of reloading the new `.po`.
run_scenario(Base, Scenario) ->
    Locale = req(Scenario, locale),
    Po = build_po(Scenario),
    Domain = ?DOMAIN,
    try
        erli18n:unload(Domain, Locale)
    catch
        _:_ -> ok
    end,
    PoPath = install_po(Base, Locale, Po),
    case erli18n:ensure_loaded(Domain, Locale, PoPath) of
        {ok, _} -> ok;
        {error, Reason} -> error({erli18n_load_failed, Reason, PoPath})
    end,
    try
        dispatch(Domain, Locale, Scenario)
    after
        try
            erli18n:unload(Domain, Locale)
        catch
            _:_ -> ok
        end
    end.

%% Map each scenario `op` to the matching erli18n facade function. Argument
%% order mirrors the C gettext macro family exactly (see `erli18n.erl`).
dispatch(Domain, Locale, #{op := gettext} = S) ->
    erli18n:gettext(Domain, req(S, msgid), Locale);
dispatch(Domain, Locale, #{op := ngettext} = S) ->
    erli18n:ngettext(
        Domain, req(S, msgid), req(S, msgid_plural), req(S, n), Locale
    );
dispatch(Domain, Locale, #{op := pgettext} = S) ->
    erli18n:pgettext(Domain, req(S, context), req(S, msgid), Locale);
dispatch(Domain, Locale, #{op := npgettext} = S) ->
    erli18n:npgettext(
        Domain,
        req(S, context),
        req(S, msgid),
        req(S, msgid_plural),
        req(S, n),
        Locale
    );
dispatch(_Domain, _Locale, S) ->
    error({unknown_or_missing_op, maps:get(op, S, undefined)}).

%% Required-field accessor with a scenario-tagged error so a malformed
%% matrix row points straight at the offending `id` and key.
req(Scenario, Key) ->
    case Scenario of
        #{Key := Value} ->
            Value;
        _ ->
            error({missing_field, Key, {scenario, maps:get(id, Scenario, undefined)}})
    end.

%% Build the scenario `.po` from the matrix fields, encoding the SAME catalog
%% that bin/extract-gettext-table.sh feeds to msgfmt/gettext, so erli18n (the
%% subject) and the GNU CLI (the oracle) load identical entries. The matrix
%% carries fields (msgid / msgid_plural / translations / plural_forms /
%% context / present), not a ready-made `.po`, so both sides assemble it the
%% same way. `present => false` emits a header-only catalog (a deliberate miss).
build_po(S) ->
    Locale = req(S, locale),
    PluralForms = req(S, plural_forms),
    Header = [
        <<"msgid \"\"\n">>,
        <<"msgstr \"\"\n">>,
        <<"\"Content-Type: text/plain; charset=UTF-8\\n\"\n">>,
        <<"\"Language: ">>,
        Locale,
        <<"\\n\"\n">>,
        <<"\"Plural-Forms: ">>,
        PluralForms,
        <<"\\n\"\n">>
    ],
    Entry =
        case req(S, present) of
            false ->
                [];
            true ->
                CtxLine =
                    case maps:get(context, S, undefined) of
                        undefined -> [];
                        Ctx -> [<<"msgctxt \"">>, Ctx, <<"\"\n">>]
                    end,
                Msgid = req(S, msgid),
                Translations = maps:get(translations, S, []),
                Body =
                    case maps:get(msgid_plural, S, undefined) of
                        undefined ->
                            First =
                                case Translations of
                                    [T | _] -> T;
                                    [] -> <<>>
                                end,
                            [
                                <<"msgid \"">>,
                                Msgid,
                                <<"\"\n">>,
                                <<"msgstr \"">>,
                                First,
                                <<"\"\n">>
                            ];
                        Plural ->
                            Indexed = lists:zip(
                                lists:seq(0, length(Translations) - 1),
                                Translations
                            ),
                            Forms = [
                                [
                                    <<"msgstr[">>,
                                    integer_to_binary(I),
                                    <<"] \"">>,
                                    T,
                                    <<"\"\n">>
                                ]
                             || {I, T} <- Indexed
                            ],
                            [
                                <<"msgid \"">>,
                                Msgid,
                                <<"\"\n">>,
                                <<"msgid_plural \"">>,
                                Plural,
                                <<"\"\n">>,
                                Forms
                            ]
                    end,
                [<<"\n">>, CtxLine, Body]
        end,
    iolist_to_binary([Header, Entry]).

%% =========================
%% Fixture installation (subject only — no msgfmt / .mo needed)
%% =========================
%%
%% Layout convention preserved from the prior suite:
%%   <Base>/<unique>/<Locale>/LC_MESSAGES/<Domain>.po
%% Each call gets a unique leaf so scenarios sharing a locale never collide
%% on disk; the in-BEAM catalog is reset by the unload in `run_scenario/2`.
install_po(Base, Locale, Po) when is_binary(Po) ->
    U = erlang:unique_integer([positive, monotonic]),
    PoPath = filename:join([
        Base,
        integer_to_list(U),
        binary_to_list(Locale),
        "LC_MESSAGES",
        atom_to_list(?DOMAIN) ++ ".po"
    ]),
    ok = filelib:ensure_dir(PoPath),
    ok = file:write_file(PoPath, Po),
    PoPath.

make_base() ->
    U = erlang:unique_integer([positive, monotonic]),
    Dir = filename:join(scratch_root(), "erli18n_parity_" ++ integer_to_list(U)),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

scratch_root() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        T -> T
    end.

%% =========================
%% Oracle loading (hard fail in the gate context)
%% =========================

load_oracle_or_fail(Path) ->
    case filelib:is_regular(Path) of
        false ->
            ct:fail(
                lists:flatten(
                    io_lib:format(
                        "erli18n parity: oracle artifact not found at ~ts "
                        "("
                        ?ORACLE_ENV
                        "). The gettext-extract step "
                        "(bin/extract-gettext-table.sh) must run first to "
                        "produce parity_oracle.eterm. This is a HARD FAILURE "
                        "in the gate context - there is no skip.",
                        [Path]
                    )
                )
            );
        true ->
            case file:consult(Path) of
                {ok, Terms} ->
                    normalize_oracle(Terms, Path);
                {error, Reason} ->
                    ct:fail(
                        lists:flatten(
                            io_lib:format(
                                "erli18n parity: could not parse oracle "
                                "artifact ~ts: ~p",
                                [Path, Reason]
                            )
                        )
                    )
            end
    end.

%% Accept the canonical wrapped map, a bare results map, or a proplist.
normalize_oracle([Map], _Path) when is_map(Map) ->
    case maps:is_key(results, Map) of
        true ->
            {maps:get(gettext_version, Map, undefined), to_results(maps:get(results, Map))};
        false ->
            {undefined, to_results(Map)}
    end;
normalize_oracle([List], _Path) when is_list(List) ->
    Version = proplists:get_value(gettext_version, List, undefined),
    Pairs = [{K, V} || {K, V} <- List, K =/= gettext_version],
    {Version, to_results(Pairs)};
normalize_oracle(Terms, Path) when is_list(Terms), Terms =/= [] ->
    %% Flat `file:consult/1` result: one {Id, Bytes} term per scenario, plus
    %% an optional leading {gettext_version, V} term — the canonical artifact
    %% shape emitted by bin/extract-gettext-table.sh.
    case
        lists:all(
            fun
                ({_, _}) -> true;
                (_) -> false
            end,
            Terms
        )
    of
        true ->
            Version = proplists:get_value(gettext_version, Terms, undefined),
            Pairs = [{K, V} || {K, V} <- Terms, K =/= gettext_version],
            {Version, to_results(Pairs)};
        false ->
            normalize_oracle_unexpected(Terms, Path)
    end;
normalize_oracle(Terms, Path) ->
    normalize_oracle_unexpected(Terms, Path).

normalize_oracle_unexpected(Terms, Path) ->
    ct:fail(
        lists:flatten(
            io_lib:format(
                "erli18n parity: unexpected oracle shape in ~ts. Expected a "
                "list of `{Id, Expected}` terms (the canonical artifact), a "
                "single map `#{gettext_version => _, results => #{Id => "
                "Expected}}`, or a `[{Id, Expected}]` proplist. Got: ~p",
                [Path, Terms]
            )
        )
    ).

to_results(Map) when is_map(Map) -> Map;
to_results(List) when is_list(List) -> maps:from_list(List).

%% =========================
%% Scenario matrix loading (hard fail in the gate context)
%% =========================

load_matrix_or_fail(Config) ->
    Path = matrix_path(Config),
    case filelib:is_regular(Path) of
        false ->
            ct:fail(
                lists:flatten(
                    io_lib:format(
                        "erli18n parity: scenario matrix not found at ~ts. "
                        "It must be COMMITTED at apps/erli18n/test/"
                        ?MATRIX_FILE
                        " (shared verbatim with bin/extract-gettext-table.sh), "
                        "or "
                        ?MATRIX_ENV
                        " must point at it. HARD FAILURE.",
                        [Path]
                    )
                )
            );
        true ->
            case file:consult(Path) of
                {ok, Terms} ->
                    case normalize_scenarios(Terms) of
                        [] ->
                            ct:fail(
                                lists:flatten(
                                    io_lib:format(
                                        "erli18n parity: scenario matrix ~ts "
                                        "is empty - no scenarios to check. "
                                        "HARD FAILURE.",
                                        [Path]
                                    )
                                )
                            );
                        Scenarios ->
                            Scenarios
                    end;
                {error, Reason} ->
                    ct:fail(
                        lists:flatten(
                            io_lib:format(
                                "erli18n parity: could not parse scenario "
                                "matrix ~ts: ~p",
                                [Path, Reason]
                            )
                        )
                    )
            end
    end.

%% `file:consult/1` returns either a one-element list wrapping the whole
%% scenario list (`[ #{...}, ... ].`) or a flat list of map terms (one
%% `#{...}.` per scenario). Disambiguate by the wrapper being a list.
normalize_scenarios([Inner]) when is_list(Inner) -> Inner;
normalize_scenarios(Terms) when is_list(Terms) -> Terms.

matrix_path(Config) ->
    case os:getenv(?MATRIX_ENV) of
        false -> filename:join(test_dir(Config), ?MATRIX_FILE);
        "" -> filename:join(test_dir(Config), ?MATRIX_FILE);
        Override -> Override
    end.

%% Resolve the directory holding this suite (and the committed matrix).
%% `data_dir` is `.../erli18n_parity_SUITE_data/`; its parent is the test
%% dir rebar3 copies the matrix into. We normalise away any trailing
%% separator before taking the parent. Falls back to the loaded beam's
%% directory, then the cwd.
test_dir(Config) ->
    case ?config(data_dir, Config) of
        DataDir when is_list(DataDir), DataDir =/= "" ->
            filename:dirname(filename:join(filename:split(DataDir)));
        _ ->
            case code:which(?MODULE) of
                Beam when is_list(Beam), Beam =/= "" -> filename:dirname(Beam);
                _ -> "."
            end
    end.

%% =========================
%% Failure reporting
%% =========================

format_report(Version, Bad) ->
    Header = io_lib:format(
        "Recorded gettext version: ~ts~n"
        "Each entry below is a scenario whose erli18n (subject) output did "
        "NOT match the GNU gettext oracle byte-for-byte.~n",
        [version_str(Version)]
    ),
    iolist_to_binary([Header | [format_bad(B) || B <- Bad]]).

format_bad({Id, {mismatch, Expected, Got}}) ->
    io_lib:format(
        "  - [~ts] MISMATCH~n"
        "      expected (oracle):  ~tp~n"
        "      got (erli18n):      ~tp~n",
        [id_str(Id), Expected, Got]
    );
format_bad({Id, {no_oracle_entry, Got}}) ->
    io_lib:format(
        "  - [~ts] NO ORACLE ENTRY - this scenario id is absent from the "
        "oracle; re-run bin/extract-gettext-table.sh so it covers every "
        "matrix scenario.~n"
        "      got (erli18n):      ~tp~n",
        [id_str(Id), Got]
    );
format_bad({Id, {error, Class, Reason, _Stack}}) ->
    io_lib:format(
        "  - [~ts] ERROR while running scenario: ~p:~p~n",
        [id_str(Id), Class, Reason]
    ).

id_str(Id) when is_binary(Id) -> Id;
id_str(Id) -> io_lib:format("~p", [Id]).

version_str(undefined) -> "unknown";
version_str(V) when is_binary(V) -> V;
version_str(V) -> io_lib:format("~p", [V]).
