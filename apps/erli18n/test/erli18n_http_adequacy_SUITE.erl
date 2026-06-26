%%% =====================================================================
%%% Common Test suite for the optional web adapters (`erli18n_cowboy`,
%%% `erli18n_elli`) and their framework-agnostic core (`erli18n_http`,
%%% `erli18n_http_apply`) — GENERATED FROM THE TEST-ADEQUACY AUDIT to pin
%%% the http-adapters findings that the existing suites leave unasserted.
%%%
%%% It closes these audit gaps (one testcase per finding cluster):
%%%   * the OBSERVABLE half of "fail-soft-AND-observable": a malformed
%%%     per-request `default`/`available` option emits EXACTLY ONE
%%%     `logger:warning/2` referencing the offending key (captured here via
%%%     an installed primary logger filter that forwards matching events to
%%%     an ETS table) — and the well-formed / kept-list paths warn ZERO times;
%%%   * cowboy `execute/2` returns `Req` UNCHANGED and preserves pre-existing
%%%     `Env` keys across the `erli18n_locale` merge;
%%%   * cowboy `execute/2` with a NON-MAP `erli18n` Env value degrades to
%%%     default options and negotiates from the request (no crash);
%%%   * `cookie_value/2` first-occurrence-wins on a duplicate-named cookie and
%%%     the empty-value (`locale=`) boundary returning `<<>>`;
%%%   * `query_value/2` empty-value (`locale=`) boundary returning `<<>>`,
%%%     including the empty-first short-circuit;
%%%   * a non-boolean `set_logger_metadata` value is treated as "on";
%%%   * two PropEr properties: `cookie_value/2` first-occurrence value-correctness
%%%     and the `negotiate_locale_lazy/4` at-most-once / stop-at-first-hit laws.
%%%
%%% EXPECTATION: GREEN. Every case asserts the CURRENT, intended behavior of
%%% the production code; the suite is expected to pass as-is and each oracle is
%%% strengthened to FAIL under the specific mutation the finding names
%%% (last-wins cookie, dropped/duplicated logger:warning, dropped Req/Env keys,
%%% removed is_map guard, collapsed set_logger_metadata guard, empty-value ->
%%% undefined, re-extract / double-force in the lazy engine).
%%% =====================================================================
-module(erli18n_http_adequacy_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    query_value_empty_value_boundary/1,
    cookie_value_empty_value_boundary/1,
    cookie_value_duplicate_first_wins/1,
    cowboy_req_and_env_preserved/1,
    cowboy_non_map_erli18n_negotiates_defaults/1,
    malformed_default_emits_one_warning/1,
    malformed_available_emits_one_warning/1,
    non_boolean_set_logger_metadata_treated_on/1,
    cookie_first_occurrence_property/1,
    lazy_negotiate_invariants_property/1
]).

%% Exported so it can be installed as a primary logger filter
%% (`fun ?MODULE:capture_filter/2`).
-export([capture_filter/2]).

%% PropEr properties and generators (exported, mirroring the `*_props` modules).
-export([
    prop_cookie_value_first_occurrence/0,
    prop_negotiate_lazy_invariants/0,
    cookie_val_gen/0,
    safe_cookie_char/0,
    noise_segs/0,
    noise_seg/0,
    value_map_gen/0,
    lazy_value/0,
    lazy_sources_gen/0,
    available_gen/0,
    locale_gen/0
]).

-define(DOMAIN, my_domain).
-define(CAPTURE, erli18n_http_adequacy_warnings).
-define(FILTER_ID, erli18n_http_adequacy_capture).
-define(NUMTESTS, 200).

%% PropEr `?FORALL`/`?LET` bodies are statically typed as `term()` by eqwalizer,
%% so each property and each generator that binds a generated value to a
%% documented shape carries a static nowarn annotation — the same pattern used
%% in `erli18n_http_props`.
-eqwalizer({nowarn_function, prop_cookie_value_first_occurrence/0}).
-eqwalizer({nowarn_function, prop_negotiate_lazy_invariants/0}).
-eqwalizer({nowarn_function, cookie_val_gen/0}).
-eqwalizer({nowarn_function, noise_segs/0}).

all() ->
    [
        query_value_empty_value_boundary,
        cookie_value_empty_value_boundary,
        cookie_value_duplicate_first_wins,
        cowboy_req_and_env_preserved,
        cowboy_non_map_erli18n_negotiates_defaults,
        malformed_default_emits_one_warning,
        malformed_available_emits_one_warning,
        non_boolean_set_logger_metadata_treated_on,
        cookie_first_occurrence_property,
        lazy_negotiate_invariants_property
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erli18n),
    %% `en` is the default and is deliberately left unloaded so the
    %% unsupported -> default path is observable; `de`/`fr`/`pt_BR` are loaded.
    ok = erli18n:set_default_locale(~"en"),
    ok = erli18n_server:insert_singular(?DOMAIN, ~"pt_BR", undefined, ~"Hello", ~"Olá"),
    ok = erli18n_server:insert_singular(?DOMAIN, ~"fr", undefined, ~"Hello", ~"Bonjour"),
    ok = erli18n_server:insert_singular(?DOMAIN, ~"de", undefined, ~"Hello", ~"Hallo"),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(erli18n),
    ok.

%% A fresh capture table plus a primary logger filter are installed per testcase.
%% The filter forwards exactly the erli18n malformed-option warnings to the table
%% (and swallows them so they do not pollute the CT log); every other log event is
%% passed through untouched (`ignore`). CT runs init/testcase/end in one process,
%% so the table created here is owned and reachable for the whole testcase.
init_per_testcase(_TC, Config) ->
    _ =
        try
            ets:delete(?CAPTURE)
        catch
            error:badarg -> true
        end,
    ?CAPTURE = ets:new(?CAPTURE, [named_table, public, set]),
    _ = logger:remove_primary_filter(?FILTER_ID),
    ok = logger:add_primary_filter(?FILTER_ID, {fun ?MODULE:capture_filter/2, []}),
    Config.

end_per_testcase(_TC, _Config) ->
    _ = logger:remove_primary_filter(?FILTER_ID),
    _ =
        try
            ets:delete(?CAPTURE)
        catch
            error:badarg -> true
        end,
    ok.

%% =========================
%% Pure core: query/cookie empty-value and duplicate boundaries
%% =========================

query_value_empty_value_boundary(_Config) ->
    %% A present key with an EMPTY value (`locale=`, a `=` then nothing) decodes to
    %% `<<>>`, NOT `undefined`. This pins the empty-value partition the existing
    %% query tests never feed; a mutation mapping an empty decoded value to
    %% `undefined` would survive every other query test (negotiate skips `<<>>`),
    %% but fails here.
    ?assertEqual(~"", erli18n_http:query_value(~"locale=", ~"locale")),
    %% Duplicate key with an empty FIRST value short-circuits on that first empty
    %% value rather than continuing to `locale=fr` (distinct from the
    %% malformed-first-continue case): the result is the empty `<<>>`, not `fr`.
    ?assertEqual(~"", erli18n_http:query_value(~"locale=&locale=fr", ~"locale")),
    ok.

cookie_value_empty_value_boundary(_Config) ->
    %% A cookie with an EMPTY unquoted value (`locale=`) returns `<<>>` (the
    %% empty-value partition, distinct from the quoted-empty `locale=""` case the
    %% existing tests cover).
    ?assertEqual(~"", erli18n_http:cookie_value(~"locale=", ~"locale")),
    ok.

cookie_value_duplicate_first_wins(_Config) ->
    %% Duplicate/conflicting cookies (parameter pollution): the FIRST occurrence
    %% wins. A last-wins mutation of `lookup_cookie/2` would return `de` and
    %% greens every existing single-cookie test, but fails both shapes here.
    ?assertEqual(~"fr", erli18n_http:cookie_value(~"locale=fr; locale=de", ~"locale")),
    ?assertEqual(
        ~"fr", erli18n_http:cookie_value(~"locale=fr; sid=x; locale=de", ~"locale")
    ),
    ok.

%% =========================
%% Cowboy adapter: Env/Req passthrough and non-map env value
%% =========================

cowboy_req_and_env_preserved(_Config) ->
    %% `execute/2` returns the input `Req` UNCHANGED and merges only
    %% `erli18n_locale` onto the `Env`, preserving every pre-existing key
    %% (a downstream middleware key `my_other_key` and the documented `dispatch`).
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    Env0 = #{erli18n => #{}, my_other_key => sentinel, dispatch => some_dispatch},
    {ok, ReqOut, EnvOut} = erli18n_cowboy:execute(Req, Env0),
    %% Req identity: a mutation that rebuilds/replaces Req is caught.
    ?assertEqual(Req, ReqOut),
    %% Pre-existing keys survive the merge.
    ?assertEqual(sentinel, maps:get(my_other_key, EnvOut)),
    ?assertEqual(some_dispatch, maps:get(dispatch, EnvOut)),
    ?assertEqual(~"fr", maps:get(erli18n_locale, EnvOut)),
    %% Whole-Env oracle: input Env plus EXACTLY {erli18n_locale => fr}. A mutation
    %% replacing the merge with `#{erli18n_locale => L}` (dropping other keys) fails.
    ?assertEqual(Env0#{erli18n_locale => ~"fr"}, EnvOut),
    ok.

cowboy_non_map_erli18n_negotiates_defaults(_Config) ->
    %% A present-but-NON-MAP `erli18n` Env value fails the `is_map(O)` guard and
    %% degrades to default options (`_ -> #{}`), so negotiation runs from the
    %% request header. Dropping `when is_map(O)` would route `not_a_map` into
    %% `run/2` (head guard `is_map(Opts0)`) and function_clause-crash, failing this.
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    {ok, ReqOut, Env} = erli18n_cowboy:execute(Req, #{erli18n => not_a_map}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env)),
    ?assertEqual(Req, ReqOut),
    ok.

%% =========================
%% Observable half of fail-soft-AND-observable: logger:warning capture
%% =========================

malformed_default_emits_one_warning(_Config) ->
    %% A well-formed binary `default` warns ZERO times (kills an always-warn mutant)
    %% and is honoured on a total miss.
    Req = cowboy_req(#{~"accept-language" => ~"ja"}, ~"", #{}),
    clear_captured(),
    {ok, _R0, Env0} = erli18n_cowboy:execute(
        Req, #{erli18n => #{sources => [header], default => ~"it"}}
    ),
    ?assertEqual(~"it", maps:get(erli18n_locale, Env0)),
    ?assertEqual(0, warning_count()),
    %% A non-binary `default` (123) is dropped and emits EXACTLY ONE warning that
    %% references the `default` key and carries the offending value. Firing it
    %% zero/twice (count =/= 1) or warning about the wrong key/value fails here.
    clear_captured(),
    {ok, _R1, Env1} = erli18n_cowboy:execute(
        Req, #{erli18n => #{sources => [header], default => 123}}
    ),
    ?assertEqual(~"en", maps:get(erli18n_locale, Env1)),
    ?assertEqual(1, warning_count()),
    [{Format, Args}] = captured_events(),
    ?assert(is_erli18n_warning(Format)),
    ?assert(string:find(Format, "default") =/= nomatch),
    ?assertEqual([123], Args),
    ok.

malformed_available_emits_one_warning(_Config) ->
    ReqDe = cowboy_req(#{~"accept-language" => ~"de"}, ~"", #{}),
    %% A NON-LIST `available` is dropped (loaded set applies, `de` -> `de`) and
    %% emits EXACTLY ONE warning referencing `available` with the offending value.
    clear_captured(),
    {ok, _R1, Env1} = erli18n_cowboy:execute(
        ReqDe, #{erli18n => #{sources => [header], available => not_a_list}}
    ),
    ?assertEqual(~"de", maps:get(erli18n_locale, Env1)),
    ?assertEqual(1, warning_count()),
    [{F1, A1}] = captured_events(),
    ?assert(string:find(F1, "available") =/= nomatch),
    ?assertEqual([not_a_list], A1),
    %% A list that filters down to EMPTY (`[1,2,3]`) is dropped and emits one warning.
    clear_captured(),
    {ok, _R2, Env2} = erli18n_cowboy:execute(
        ReqDe, #{erli18n => #{sources => [header], available => [1, 2, 3]}}
    ),
    ?assertEqual(~"de", maps:get(erli18n_locale, Env2)),
    ?assertEqual(1, warning_count()),
    [{_F2, A2}] = captured_events(),
    ?assertEqual([[1, 2, 3]], A2),
    %% A MIXED list keeps the binary element (`[~"fr"]`) — the kept-list branch must
    %% NOT warn. `de` is filtered out of `[fr]`, so the header misses and falls to
    %% the default `en`. A mutation moving `warn_available/1` into the kept branch
    %% would warn here (count 1) and fail this zero-warning assertion.
    clear_captured(),
    {ok, _R3, Env3} = erli18n_cowboy:execute(
        ReqDe, #{erli18n => #{sources => [header], available => [~"fr", bad, 7]}}
    ),
    ?assertEqual(~"en", maps:get(erli18n_locale, Env3)),
    ?assertEqual(0, warning_count()),
    ok.

non_boolean_set_logger_metadata_treated_on(_Config) ->
    %% `set_logger_metadata` is a typed-boolean option; only the LITERAL `false`
    %% disables it. A non-boolean value (0) and an explicit `true` both fall to the
    %% catch-all and SET `#{locale => L}`. A mutation widening the disabling clause
    %% to `#{set_logger_metadata := _} -> ok` would leave metadata unset and fail.
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    {ok, _R0, _E0} = erli18n_cowboy:execute(
        Req, #{erli18n => #{set_logger_metadata => 0}}
    ),
    ?assertEqual(#{locale => ~"fr"}, only_locale(logger:get_process_metadata())),
    {ok, _R1, _E1} = erli18n_cowboy:execute(
        Req, #{erli18n => #{set_logger_metadata => true}}
    ),
    ?assertEqual(#{locale => ~"fr"}, only_locale(logger:get_process_metadata())),
    ok.

%% =========================
%% Property wrappers
%% =========================

cookie_first_occurrence_property(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_cookie_value_first_occurrence(),
            [{numtests, ?NUMTESTS}, {to_file, user}]
        )
    ).

lazy_negotiate_invariants_property(_Config) ->
    ?assert(
        proper:quickcheck(
            prop_negotiate_lazy_invariants(),
            [{numtests, ?NUMTESTS}, {to_file, user}]
        )
    ).

%% =========================
%% Properties
%% =========================

%% F15: value-correctness + first-occurrence + identity-unquote for cookie_value/2.
%% A header is built that contains a known `locale=V1` pair AND a later DUPLICATE
%% `locale=V2` pair (V2 is guaranteed distinct), surrounded by non-`locale` noise.
%% `cookie_value/2` must return V1 verbatim (first occurrence wins; the value has
%% no surrounding quotes so unquote is identity). A last-match mutation of
%% `lookup_cookie/2` returns V2 =/= V1; an over/under-strip of `unquote/1` mangles
%% V1 — both fail this property.
prop_cookie_value_first_occurrence() ->
    ?FORALL(
        {V1, Pre, Mid, Post},
        {cookie_val_gen(), noise_segs(), noise_segs(), noise_segs()},
        begin
            V2 = <<"d_", V1/binary>>,
            Pair1 = <<"locale=", V1/binary>>,
            Pair2 = <<"locale=", V2/binary>>,
            Segs = Pre ++ [Pair1] ++ Mid ++ [Pair2] ++ Post,
            Header = iolist_to_binary(lists:join(~"; ", Segs)),
            Got = erli18n_http:cookie_value(Header, ~"locale"),
            case Got =:= V1 of
                true -> true;
                false -> ct_fail("cookie first-occurrence", [Header, Got, V1])
            end
        end
    ).

%% F16: at-most-once / stop-at-first-hit laws for negotiate_locale_lazy/4 over
%% arbitrary source orderings (with duplicates/empties), an adversarial per-source
%% value map, and counter-backed Available/Default thunks. A recording Extract
%% logs each call (in order) to the test mailbox. Asserts: never raises; result is
%% a member of [Default|Available]; the recorded calls are exactly a PREFIX of
%% Sources (no re-order, no extract-after-stop); on a hit the last extracted source
%% is the winner; on a total miss every source was walked; the Available thunk is
%% forced AT MOST ONCE; the Default thunk is forced once iff (and only iff) a total
%% miss. A re-extract, a per-candidate index rebuild, or a missing short-circuit
%% all violate one of these.
prop_negotiate_lazy_invariants() ->
    ?FORALL(
        {Sources, ValueMap, Avail, Def},
        {lazy_sources_gen(), value_map_gen(), available_gen(), locale_gen()},
        begin
            _ = drain_calls(),
            Self = self(),
            ACtr = counters:new(1, []),
            DCtr = counters:new(1, []),
            Extract = fun(S) ->
                Self ! {called, S},
                maps:get(S, ValueMap, undefined)
            end,
            AvThunk = fun() ->
                counters:add(ACtr, 1, 1),
                Avail
            end,
            DefThunk = fun() ->
                counters:add(DCtr, 1, 1),
                Def
            end,
            try erli18n_http:negotiate_locale_lazy(Sources, Extract, AvThunk, DefThunk) of
                {Locale, Won} ->
                    Calls = drain_calls(),
                    check_lazy(
                        Locale,
                        Won,
                        Sources,
                        Calls,
                        Avail,
                        Def,
                        counters:get(ACtr, 1),
                        counters:get(DCtr, 1)
                    );
                Other ->
                    ct_fail("lazy bad shape", [Other, Sources])
            catch
                Class:Reason:Stack ->
                    ct_fail("lazy crashed", [Class, Reason, Stack, Sources])
            end
        end
    ).

%% =========================
%% Generators
%% =========================

%% A cookie value built from a "safe" alphabet (no whitespace, `;`, `=`, or `"`),
%% so the value round-trips through `parse_cookie_pair/1` + `unquote/1` unchanged.
cookie_val_gen() ->
    ?LET(Cs, list(safe_cookie_char()), iolist_to_binary(Cs)).

safe_cookie_char() ->
    oneof([$a, $b, $c, $d, $e, $f, $0, $1, $2, $-, $_, $x, $y, $z]).

%% A bounded list (<= 8) of non-`locale` noise cookie segments, keeping the total
%% pair/byte count well under the parser's anti-DoS caps.
noise_segs() ->
    ?LET(N, range(0, 8), proper_types:vector(N, noise_seg())).

noise_seg() ->
    oneof([~"sid=abc", ~"x=1", ~"theme=dark", ~"foo=bar", ~"a=b", ~"k=v"]).

%% A per-source value map feeding adversarial values (absent, empty, real and
%% q-valued locales, and non-binary garbage) to the recording Extract.
value_map_gen() ->
    ?LET(
        {Q, C, H, P},
        {lazy_value(), lazy_value(), lazy_value(), lazy_value()},
        #{query => Q, cookie => C, header => H, path => P}
    ).

lazy_value() ->
    oneof([
        undefined,
        ~"",
        ~"fr",
        ~"de",
        ~"pt-BR",
        ~"pt_BR",
        ~"ja",
        ~"fr;q=0.9",
        42,
        an_atom
    ]).

%% An arbitrary source ordering, including duplicates and the empty list.
lazy_sources_gen() ->
    list(oneof([query, cookie, header, path])).

available_gen() ->
    list(locale_gen()).

locale_gen() ->
    oneof([~"en", ~"fr", ~"de", ~"pt", ~"pt_BR", ~"ja"]).

%% =========================
%% Helpers
%% =========================

%% Minimal cowboy_req map: cowboy_req:header/3, cowboy_req:qs/1, and
%% cowboy_req:binding/3 read exactly the `headers` / `qs` / `bindings` keys.
cowboy_req(Headers, Qs, Bindings) ->
    #{headers => Headers, qs => Qs, bindings => Bindings}.

%% Keep only the `locale` key so the metadata assertion is independent of any
%% unrelated process metadata, while still proving the adapter set it.
only_locale(undefined) -> undefined;
only_locale(Meta) when is_map(Meta) -> maps:with([locale], Meta).

%% --- logger capture ---

%% Primary logger filter: forward exactly the erli18n malformed-option warnings to
%% the capture table and `stop` them (so they do not reach the handlers / CT log);
%% every other event is passed through unchanged (`ignore`).
capture_filter(#{level := warning, msg := {Format, Args}}, _Extra) when is_list(Format) ->
    case is_erli18n_warning(Format) of
        true ->
            ets:insert(?CAPTURE, {erlang:unique_integer([monotonic]), Format, Args}),
            stop;
        false ->
            ignore
    end;
capture_filter(_Event, _Extra) ->
    ignore.

is_erli18n_warning(Format) when is_list(Format) ->
    string:find(Format, "erli18n: ignoring malformed") =/= nomatch;
is_erli18n_warning(_Other) ->
    false.

clear_captured() ->
    true = ets:delete_all_objects(?CAPTURE),
    ok.

warning_count() ->
    ets:info(?CAPTURE, size).

captured_events() ->
    [{F, A} || {_K, F, A} <- ets:tab2list(?CAPTURE)].

%% --- lazy-property bookkeeping ---

%% Drain the recorded {called, Source} messages in extraction order; [] once empty.
drain_calls() ->
    receive
        {called, S} -> [S | drain_calls()]
    after 0 -> []
    end.

%% The full invariant battery for prop_negotiate_lazy_invariants/0.
check_lazy(Locale, Won, Sources, Calls, Avail, Def, AvCount, DefCount) ->
    MemberOk = is_binary(Locale) andalso lists:member(Locale, [Def | Avail]),
    PrefixOk = Calls =:= lists:sublist(Sources, length(Calls)),
    StopOk =
        case Won of
            default -> Calls =:= Sources;
            _ -> Calls =/= [] andalso lists:last(Calls) =:= Won
        end,
    AvOk = AvCount =< 1,
    DefOk = DefCount =< 1 andalso ((Won =:= default) =:= (DefCount =:= 1)),
    case MemberOk andalso PrefixOk andalso StopOk andalso AvOk andalso DefOk of
        true ->
            true;
        false ->
            ct_fail(
                "lazy invariant",
                [Locale, Won, Sources, Calls, Avail, Def, AvCount, DefCount]
            )
    end.

ct_fail(Label, Args) ->
    ct:pal("~s: ~p~n", [Label, Args]),
    false.
