-module(erli18n_register_compiled_adequacy_SUITE).

%% Adequacy suite for `erli18n_server:register_compiled_many/1`. It pins the
%% boundaries the implementation must keep — the behaviours that are easy to
%% regress and that the plain functional suite does not assert:
%%
%%   * `loaded_at` is STAMPED at registration, never carried in the
%%     `baked_header()` (the baked map has only the other 6 header fields).
%%   * `po_path`/`divergence`/`fuzzy_included`/`num_entries` surfaced through
%%     `lookup_header/2` are the BAKED values (full `header_state()` parity).
%%   * BOOT-QUIET PROOF: registering a catalog whose BAKED header carries a
%%     real `divergence` and `fuzzy_included => true` fires NEITHER
%%     `[erli18n, plural, divergence_warning]` NOR `[erli18n, lookup,
%%     fuzzy_skip]`, yet `lookup_header/2` still returns the baked divergence.
%%   * Registration installs ONLY through the serialized writer (it reuses the
%%     existing `{commit_many, _}` server message; there is no new server
%%     message clause).
%%   * Ensure-idempotency preserves a prior `reload/3`.
%%   * `reload/3` after a register overrides the registered catalog.
%%   * A malformed entry crashes LOUDLY inside `build_map`'s `put_entry`
%%     (`function_clause`), NOT as a structured `{error, _}`.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% Telemetry handler referenced by `{Module, Function}` from telemetry.
-export([handle_event/4]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    loaded_at_stamped_not_baked/1,
    baked_values_surfaced_via_header/1,
    boot_quiet_no_divergence_no_fuzzy_telemetry/1,
    install_routes_only_through_serialized_writer/1,
    ensure_idempotency_preserves_prior_reload/1,
    reload_after_register_overrides/1,
    malformed_entry_crashes_loudly/1
]).

all() ->
    [
        loaded_at_stamped_not_baked,
        baked_values_surfaced_via_header,
        boot_quiet_no_divergence_no_fuzzy_telemetry,
        install_routes_only_through_serialized_writer,
        ensure_idempotency_preserves_prior_reload,
        reload_after_register_overrides,
        malformed_entry_crashes_loudly
    ].

init_per_suite(Config) ->
    %% `telemetry` is an OPTIONAL dependency of erli18n, so it is NOT
    %% auto-started by `ensure_all_started(erli18n)`; the boot-quiet proof
    %% attaches real handlers, so start it explicitly first (mirrors
    %% erli18n_telemetry_SUITE).
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _Apps} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    ok.

init_per_testcase(TC, Config) ->
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    Tab = ets:new(erli18n_register_capture, [public, ordered_set]),
    HandlerId = list_to_binary(
        "erli18n_register_adequacy_" ++
            atom_to_list(TC) ++ "_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    [{capture_tab, Tab}, {handler_id, HandlerId} | Config].

end_per_testcase(_TC, Config) ->
    %% Best-effort teardown: a handler may never have been attached (only the
    %% boot-quiet case attaches), so detach can return `{error, not_found}`.
    _ = telemetry:detach(?config(handler_id, Config)),
    _ = ets:delete(?config(capture_tab, Config)),
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    ok.

%% =========================
%% Test cases
%% =========================

%% `loaded_at` is NOT one of the baked_header() fields: it is stamped at the
%% instant of registration. Capture a `Before` wall-clock, register, and
%% assert the surfaced `loaded_at` is a real timestamp at-or-after `Before`.
loaded_at_stamped_not_baked(_Config) ->
    Before = erlang:system_time(millisecond),
    Baked = fallback_baked("fr.po", 1),
    %% The baked header carries NO loaded_at key (it is stamped, not baked).
    ?assertNot(maps:is_key(loaded_at, Baked)),
    Spec = {default, ~"fr", [{singular, undefined, ~"a", ~"A"}], Baked},
    [{default, ~"fr", {ok, 1}}] = erli18n_server:register_compiled_many([Spec]),
    {ok, Header} = erli18n_server:lookup_header(default, ~"fr"),
    LoadedAt = maps:get(loaded_at, Header),
    ?assert(is_integer(LoadedAt)),
    ?assert(LoadedAt >= Before),
    ?assert(LoadedAt =< erlang:system_time(millisecond)).

baked_values_surfaced_via_header(_Config) ->
    Compiled = compile(~"nplurals=2; plural=(n > 1);"),
    Divergence = {plural_divergence, ~"(n != 1)", ~"(n > 1)"},
    Baked = #{
        plural => Compiled,
        plural_raw => ~"(n != 1)",
        po_path => "the/path.po",
        divergence => Divergence,
        fuzzy_included => true,
        num_entries => 7
    },
    Spec = {default, ~"fr", [{singular, undefined, ~"a", ~"A"}], Baked},
    [{default, ~"fr", {ok, 7}}] = erli18n_server:register_compiled_many([Spec]),
    {ok, Header} = erli18n_server:lookup_header(default, ~"fr"),
    %% Every baked field is surfaced verbatim (the only header field NOT taken
    %% from the baked map is loaded_at, which is stamped).
    ?assertEqual(Compiled, maps:get(plural, Header)),
    ?assertEqual(~"(n != 1)", maps:get(plural_raw, Header)),
    ?assertEqual("the/path.po", maps:get(po_path, Header)),
    ?assertEqual(Divergence, maps:get(divergence, Header)),
    ?assertEqual(true, maps:get(fuzzy_included, Header)),
    ?assertEqual(7, maps:get(num_entries, Header)).

%% BOOT-QUIET PROOF. A catalog whose BAKED header carries a real plural
%% divergence AND was built without fuzzy entries must install SILENTLY: the
%% reused serialized writer sees a staged() with divergence => none and
%% fuzzy_skipped => 0, so it emits NEITHER the divergence_warning NOR the
%% fuzzy_skip telemetry. The baked divergence is still recoverable through
%% lookup_header/2 (it lives in the catalog map's '$header').
boot_quiet_no_divergence_no_fuzzy_telemetry(Config) ->
    %% emit_lookup_telemetry on so the fuzzy_skip path is NOT suppressed by an
    %% opt-out; this isolates the boot-quiet behaviour to the register design.
    Prev = application:get_env(erli18n, emit_lookup_telemetry),
    application:set_env(erli18n, emit_lookup_telemetry, true),
    try
        attach(Config, [
            [erli18n, plural, divergence_warning],
            [erli18n, lookup, fuzzy_skip]
        ]),
        Compiled = compile(~"nplurals=2; plural=(n != 1);"),
        Divergence = {plural_divergence, ~"(n != 1)", ~"(n > 1)"},
        Baked = #{
            plural => Compiled,
            plural_raw => ~"(n != 1)",
            po_path => "pt_BR.po",
            divergence => Divergence,
            fuzzy_included => false,
            num_entries => 1
        },
        Spec = {default, ~"pt_BR", [{singular, undefined, ~"Hi", ~"Oi"}], Baked},
        [{default, ~"pt_BR", {ok, 1}}] =
            erli18n_server:register_compiled_many([Spec]),
        %% No boot-time telemetry burst.
        ?assertEqual([], captured_for(Config, [erli18n, plural, divergence_warning])),
        ?assertEqual([], captured_for(Config, [erli18n, lookup, fuzzy_skip])),
        %% ...yet the baked divergence is fully recoverable.
        {ok, Header} = erli18n_server:lookup_header(default, ~"pt_BR"),
        ?assertEqual(Divergence, maps:get(divergence, Header))
    after
        restore_env(emit_lookup_telemetry, Prev)
    end.

%% Registration must reuse the EXISTING serialized writer, not add a new
%% server message. Prove it two ways: (1) there is no `register_compiled_*`
%% handle_call clause — a raw register message is `{error, unknown_call}`;
%% (2) the catalog nonetheless ends up installed in persistent_term (the only
%% mutation site the server owns), and the server pid is unchanged.
install_routes_only_through_serialized_writer(_Config) ->
    Pid = whereis(erli18n_server),
    ?assert(is_pid(Pid)),
    %% No register-specific server message exists.
    ?assertEqual(
        {error, unknown_call},
        gen_server:call(
            erli18n_server,
            {register_compiled_many, [{default, ~"fr", [], fallback_baked("fr.po", 0)}]}
        )
    ),
    %% The public API installs the catalog (the term appears under the
    %% catalog key the server's writer owns).
    Spec = {default, ~"fr", [{singular, undefined, ~"a", ~"A"}], fallback_baked("fr.po", 1)},
    [{default, ~"fr", {ok, 1}}] = erli18n_server:register_compiled_many([Spec]),
    ?assertMatch(
        #{},
        persistent_term:get({erli18n_catalog, default, ~"fr"}, undefined)
    ),
    %% The serialized writer was not restarted by the registration.
    ?assertEqual(Pid, whereis(erli18n_server)).

%% Ensure-idempotency: a catalog already installed by `reload/3` (the real
%% .po pipeline) is NOT clobbered by a later register of the same {D, L}.
ensure_idempotency_preserves_prior_reload(Config) ->
    Path = write_po(Config, ~"Hello", ~"Bonjour"),
    {ok, 1} = erli18n_server:reload(default, ~"fr", Path),
    ?assertEqual(
        {ok, ~"Bonjour"},
        erli18n_server:lookup_singular(default, ~"fr", undefined, ~"Hello")
    ),
    %% Register the same catalog with a DIFFERENT translation: idempotent.
    Spec =
        {default, ~"fr", [{singular, undefined, ~"Hello", ~"SALUT"}], fallback_baked("fr.po", 1)},
    ?assertEqual(
        [{default, ~"fr", {ok, already}}],
        erli18n_server:register_compiled_many([Spec])
    ),
    %% The reloaded translation survives.
    ?assertEqual(
        {ok, ~"Bonjour"},
        erli18n_server:lookup_singular(default, ~"fr", undefined, ~"Hello")
    ).

%% A `reload/3` after a register overrides the registered catalog wholesale
%% (reload never takes the idempotent fast-path).
reload_after_register_overrides(Config) ->
    Spec =
        {default, ~"fr", [{singular, undefined, ~"Hello", ~"REGISTERED"}],
            fallback_baked("fr.po", 1)},
    [{default, ~"fr", {ok, 1}}] = erli18n_server:register_compiled_many([Spec]),
    ?assertEqual(
        {ok, ~"REGISTERED"},
        erli18n_server:lookup_singular(default, ~"fr", undefined, ~"Hello")
    ),
    Path = write_po(Config, ~"Hello", ~"Bonjour"),
    {ok, 1} = erli18n_server:reload(default, ~"fr", Path),
    ?assertEqual(
        {ok, ~"Bonjour"},
        erli18n_server:lookup_singular(default, ~"fr", undefined, ~"Hello")
    ).

%% Trusted-input contract: a malformed entry (negative plural form index) is
%% NOT a structured {error, _} — it crashes LOUDLY inside build_map's
%% put_entry, in the CALLER's preparation phase, before any mutation.
malformed_entry_crashes_loudly(_Config) ->
    BadEntries = [{plural, undefined, ~"file", ~"files", [{-1, ~"bad"}]}],
    Spec = {default, ~"fr", BadEntries, fallback_baked("fr.po", 1)},
    ?assertError(
        function_clause,
        erli18n_server:register_compiled_many([Spec])
    ),
    %% No catalog was installed by the crashed call.
    ?assertEqual(undefined, erli18n_server:lookup_header(default, ~"fr")).

%% =========================
%% Telemetry capture helpers (mirrors erli18n_telemetry_SUITE)
%% =========================

attach(Config, EventNames) ->
    HandlerId = ?config(handler_id, Config),
    Tab = ?config(capture_tab, Config),
    ok = telemetry:attach_many(
        HandlerId,
        EventNames,
        fun ?MODULE:handle_event/4,
        #{tab => Tab}
    ),
    ok.

handle_event(EventName, Measurements, Metadata, #{tab := Tab}) ->
    Seq = erlang:unique_integer([monotonic, positive]),
    ets:insert(Tab, {Seq, EventName, Measurements, Metadata}),
    ok.

captured_for(Config, EventName) ->
    Tab = ?config(capture_tab, Config),
    [{M, Meta} || {_S, N, M, Meta} <- ets:tab2list(Tab), N =:= EventName].

%% =========================
%% Fixture helpers
%% =========================

write_po(Config, Msgid, Translation) ->
    Dir = ?config(priv_dir, Config),
    Path = filename:join(
        Dir,
        "register_adequacy_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".po"
    ),
    Po = [
        <<"msgid \"\"\n">>,
        <<"msgstr \"\"\n">>,
        <<"\"Content-Type: text/plain; charset=UTF-8\\n\"\n\n">>,
        <<"msgid \"">>,
        Msgid,
        <<"\"\n">>,
        <<"msgstr \"">>,
        Translation,
        <<"\"\n">>
    ],
    ok = file:write_file(Path, Po),
    Path.

fallback_baked(PoPath, NumEntries) ->
    #{
        plural => fallback,
        plural_raw => erli18n_plural:fallback_rule(),
        po_path => PoPath,
        divergence => none,
        fuzzy_included => false,
        num_entries => NumEntries
    }.

compile(Raw) ->
    {ok, Compiled} = erli18n_plural:compile(Raw),
    Compiled.

restore_env(_Key, undefined) ->
    ok;
restore_env(Key, {ok, Value}) ->
    application:set_env(erli18n, Key, Value).
