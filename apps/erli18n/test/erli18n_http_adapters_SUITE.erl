%%% =====================================================================
%%% Common Test suite for the optional web adapters `erli18n_cowboy` and
%%% `erli18n_elli`, plus the `erli18n:loaded_locales/0` available-set helper.
%%%
%%% The adapters are exercised against the REAL framework request objects
%%% (cowboy/elli are test-profile deps): a minimal `cowboy_req` map and a
%%% real Elli `#req{}` record are built and passed straight to `execute/2` /
%%% `preprocess/2`, so no live socket/port is needed and the cases are
%%% deterministic. Coverage spans header negotiation, cookie/query/path
%%% overrides and their precedence, the unsupported -> default path, the
%%% `Env` handoff (Cowboy), the `logger` metadata opt-out, and an
%%% end-to-end check that a gettext lookup after the middleware returns the
%%% negotiated translation.
%%% =====================================================================
-module(erli18n_http_adapters_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("elli/include/elli.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).

-export([
    loaded_locales_authoritative/1,
    loaded_locales_equals_catalog_projection/1
]).

-export([
    cowboy_header_negotiation/1,
    cowboy_query_override/1,
    cowboy_cookie_override/1,
    cowboy_query_over_cookie/1,
    cowboy_custom_option_names/1,
    cowboy_unsupported_default/1,
    cowboy_path_binding/1,
    cowboy_path_binding_non_atom/1,
    cowboy_path_binding_non_binary_value/1,
    cowboy_path_unconfigured/1,
    cowboy_query_valueless/1,
    cowboy_query_malformed_escape/1,
    cowboy_logger_metadata_set/1,
    cowboy_logger_metadata_off/1,
    cowboy_query_unsupported_default/1,
    cowboy_cookie_unsupported_default/1,
    cowboy_path_unsupported_default/1,
    cowboy_explicit_available_and_default/1
]).

-export([
    elli_header_negotiation/1,
    elli_query_override/1,
    elli_cookie_override/1,
    elli_unsupported_default/1,
    elli_args_non_map/1,
    elli_path_source_is_noop/1,
    elli_logger_metadata_off/1,
    elli_logger_metadata_set/1,
    elli_query_over_cookie/1,
    elli_custom_option_names/1,
    elli_query_unsupported_default/1,
    elli_cookie_unsupported_default/1,
    elli_query_valueless/1,
    elli_query_malformed_escape/1
]).

-export([
    malformed_default_falls_back/1,
    malformed_available_non_list_falls_back/1,
    malformed_available_all_bad_elements_falls_back/1,
    available_mixed_elements_filtered/1,
    malformed_sources_non_list_falls_back/1,
    sources_stray_element_dropped/1,
    malformed_query_param_falls_back/1,
    malformed_cookie_name_falls_back/1
]).

-define(DOMAIN, my_domain).

%% `elli_req/2` builds a partial Elli `#req{}` (only the fields these tests read);
%% eqwalizer flags the unset record fields, so the documented nowarn idiom applies
%% to this one test helper.
-eqwalizer({nowarn_function, elli_req/2}).

all() ->
    [
        loaded_locales_authoritative,
        loaded_locales_equals_catalog_projection,
        {group, cowboy},
        {group, elli},
        {group, validation}
    ].

groups() ->
    [
        {cowboy, [], [
            cowboy_header_negotiation,
            cowboy_query_override,
            cowboy_cookie_override,
            cowboy_query_over_cookie,
            cowboy_custom_option_names,
            cowboy_unsupported_default,
            cowboy_path_binding,
            cowboy_path_binding_non_atom,
            cowboy_path_binding_non_binary_value,
            cowboy_path_unconfigured,
            cowboy_query_valueless,
            cowboy_query_malformed_escape,
            cowboy_logger_metadata_set,
            cowboy_logger_metadata_off,
            cowboy_query_unsupported_default,
            cowboy_cookie_unsupported_default,
            cowboy_path_unsupported_default,
            cowboy_explicit_available_and_default
        ]},
        {elli, [], [
            elli_header_negotiation,
            elli_query_override,
            elli_cookie_override,
            elli_unsupported_default,
            elli_args_non_map,
            elli_path_source_is_noop,
            elli_logger_metadata_off,
            elli_logger_metadata_set,
            elli_query_over_cookie,
            elli_custom_option_names,
            elli_query_unsupported_default,
            elli_cookie_unsupported_default,
            elli_query_valueless,
            elli_query_malformed_escape
        ]},
        {validation, [], [
            malformed_default_falls_back,
            malformed_available_non_list_falls_back,
            malformed_available_all_bad_elements_falls_back,
            available_mixed_elements_filtered,
            malformed_sources_non_list_falls_back,
            sources_stray_element_dropped,
            malformed_query_param_falls_back,
            malformed_cookie_name_falls_back
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erli18n),
    %% Three loaded locales for one domain; `en` is the default and is left
    %% deliberately unloaded so the unsupported -> default path is observable.
    ok = erli18n:set_default_locale(~"en"),
    ok = erli18n_server:insert_singular(?DOMAIN, ~"pt_BR", undefined, ~"Hello", ~"Olá"),
    ok = erli18n_server:insert_singular(?DOMAIN, ~"fr", undefined, ~"Hello", ~"Bonjour"),
    ok = erli18n_server:insert_singular(?DOMAIN, ~"de", undefined, ~"Hello", ~"Hallo"),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(erli18n),
    ok.

%% =========================
%% loaded_locales/0
%% =========================

loaded_locales_authoritative(_Config) ->
    %% Distinct, sorted locales across the loaded catalogs — the available set.
    ?assertEqual([~"de", ~"fr", ~"pt_BR"], erli18n:loaded_locales()),
    ok.

loaded_locales_equals_catalog_projection(_Config) ->
    %% loaded_locales/0 is the sorted, distinct locale projection of
    %% loaded_catalogs/0 — the loaded-locale index mirrors the catalog set.
    Projection = lists:usort([L || {_D, L, _N} <- erli18n:loaded_catalogs()]),
    ?assertEqual(Projection, erli18n:loaded_locales()),
    ?assertEqual([~"de", ~"fr", ~"pt_BR"], erli18n:loaded_locales()),
    %% Re-inserting into an existing locale (reload-style) must not duplicate it.
    ok = erli18n_server:insert_singular(?DOMAIN, ~"fr", undefined, ~"Bye", ~"Au revoir"),
    ?assertEqual([~"de", ~"fr", ~"pt_BR"], erli18n:loaded_locales()),
    ok.

%% =========================
%% Cowboy adapter
%% =========================

cowboy_header_negotiation(_Config) ->
    %% No `erli18n` key in Env exercises the default-options branch.
    Req = cowboy_req(#{~"accept-language" => ~"pt-BR,fr;q=0.9"}, ~"", #{}),
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{}),
    ?assertEqual(~"pt_BR", erli18n:which_locale()),
    ?assertEqual(~"pt_BR", maps:get(erli18n_locale, Env)),
    %% End-to-end: the documented pipeline really sets the locale for lookups.
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello")),
    ok.

cowboy_query_override(_Config) ->
    Req = cowboy_req(#{~"accept-language" => ~"de"}, ~"locale=fr", #{}),
    {ok, _Req, _Env} = erli18n_cowboy:execute(Req, #{erli18n => #{}}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ?assertEqual(~"Bonjour", erli18n:gettext(?DOMAIN, ~"Hello")),
    ok.

cowboy_cookie_override(_Config) ->
    Req = cowboy_req(
        #{~"accept-language" => ~"de", ~"cookie" => ~"sid=x; locale=fr"}, ~"", #{}
    ),
    {ok, _Req, _Env} = erli18n_cowboy:execute(Req, #{}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

cowboy_query_over_cookie(_Config) ->
    Req = cowboy_req(#{~"cookie" => ~"locale=de"}, ~"locale=fr", #{}),
    {ok, _Req, _Env} = erli18n_cowboy:execute(Req, #{}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

cowboy_custom_option_names(_Config) ->
    %% Custom `query_param` wins (query > cookie): the `lang=de` query is read via
    %% the custom name.
    Req = cowboy_req(#{~"cookie" => ~"loc=de"}, ~"lang=de", #{}),
    Opts = #{query_param => ~"lang", cookie_name => ~"loc"},
    {ok, _Req, _Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"de", erli18n:which_locale()),
    %% Isolate the COOKIE source so the custom `cookie_name` (`loc`) is actually
    %% read: with the query source removed, `fr` comes from the custom-named cookie.
    ReqCookie = cowboy_req(#{~"cookie" => ~"loc=fr"}, ~"lang=de", #{}),
    {ok, _R2, Env2} = erli18n_cowboy:execute(
        ReqCookie, #{erli18n => Opts#{sources => [cookie, header]}}
    ),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env2)),
    ok.

cowboy_unsupported_default(_Config) ->
    Req = cowboy_req(#{~"accept-language" => ~"ja, ko"}, ~"", #{}),
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{}),
    ?assertEqual(~"en", erli18n:which_locale()),
    ?assertEqual(~"en", maps:get(erli18n_locale, Env)),
    ok.

cowboy_path_binding(_Config) ->
    Req = cowboy_req(#{~"accept-language" => ~"de"}, ~"", #{locale => ~"fr"}),
    Opts = #{sources => [path, header], path_binding => locale},
    {ok, _Req, _Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

cowboy_path_unconfigured(_Config) ->
    %% `path` listed but no `path_binding`: that source yields nothing and the
    %% header is used instead.
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    Opts = #{sources => [path, header]},
    {ok, _Req, _Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

cowboy_query_valueless(_Config) ->
    %% `?locale` with no value is not a usable override; the header is used.
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"locale", #{}),
    {ok, _Req, _Env} = erli18n_cowboy:execute(Req, #{}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

cowboy_query_malformed_escape(_Config) ->
    %% A malformed percent-escape in the raw query (`?locale=%ZZ`) would make
    %% cowboy's own `parse_qs/1` decoder raise; the adapter instead feeds the RAW
    %% query (`cowboy_req:qs/1`, total) to the core parser
    %% `erli18n_http:query_value/2`, whose fail-soft percent-decoding maps it to
    %% undefined. The source is skipped, the header is used, the request does NOT
    %% crash. Several shapes that crash `cow_qs:parse_qs/1` are exercised.
    lists:foreach(
        fun(Qs) ->
            Req = cowboy_req(#{~"accept-language" => ~"fr"}, Qs, #{}),
            {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{}),
            ?assertEqual(~"fr", erli18n:which_locale()),
            ?assertEqual(~"fr", maps:get(erli18n_locale, Env))
        end,
        [~"locale=%ZZ", ~"%", ~"locale=%E0%", ~"locale=%"]
    ),
    ok.

cowboy_path_binding_non_atom(_Config) ->
    %% A misconfigured non-atom `path_binding` (operator error) must be fail-soft:
    %% the `path` source is skipped rather than crashing with a case_clause, so
    %% negotiation falls through to the header.
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{locale => ~"de"}),
    Opts = #{sources => [path, header], path_binding => <<"locale">>},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env)),
    ok.

cowboy_path_binding_non_binary_value(_Config) ->
    %% The router can bind a NON-BINARY value (e.g. an integer from an
    %% `:id/integer` constraint). `cowboy_req:binding/3` returns it as-is; the
    %% core `is_binary` guard rejects it, so the `path` source is skipped
    %% fail-soft and negotiation falls through to the header — never a crash and
    %% never a non-binary reaching the negotiator. Exercises the adapter->core
    %% wiring end-to-end (the core-only non-binary case lives in the adequacy
    %% suite; here the value travels the real cowboy seam).
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{locale => 42}),
    Opts = #{sources => [path, header], path_binding => locale},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env)),
    ok.

cowboy_logger_metadata_set(_Config) ->
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    {ok, _Req, _Env} = erli18n_cowboy:execute(Req, #{}),
    ?assertEqual(#{locale => ~"fr"}, only_locale(logger:get_process_metadata())),
    ok.

cowboy_logger_metadata_off(_Config) ->
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    {ok, _Req, _Env} = erli18n_cowboy:execute(Req, #{erli18n => #{set_logger_metadata => false}}),
    ?assertEqual(undefined, logger:get_process_metadata()),
    ok.

cowboy_query_unsupported_default(_Config) ->
    %% An unsupported locale supplied via the QUERY source maps onto the
    %% negotiation miss path -> default `en`. Restricting `sources` to `[query]`
    %% isolates the query source so the header `de` cannot rescue it.
    Req = cowboy_req(#{~"accept-language" => ~"de"}, ~"locale=ja", #{}),
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => #{sources => [query]}}),
    ?assertEqual(~"en", erli18n:which_locale()),
    ?assertEqual(~"en", maps:get(erli18n_locale, Env)),
    ok.

cowboy_cookie_unsupported_default(_Config) ->
    %% Same miss path via the COOKIE source in isolation.
    Req = cowboy_req(#{~"accept-language" => ~"de", ~"cookie" => ~"locale=ja"}, ~"", #{}),
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => #{sources => [cookie]}}),
    ?assertEqual(~"en", erli18n:which_locale()),
    ?assertEqual(~"en", maps:get(erli18n_locale, Env)),
    ok.

cowboy_path_unsupported_default(_Config) ->
    %% Same miss path via the PATH binding source in isolation.
    Req = cowboy_req(#{~"accept-language" => ~"de"}, ~"", #{locale => ~"ja"}),
    Opts = #{sources => [path], path_binding => locale},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"en", erli18n:which_locale()),
    ?assertEqual(~"en", maps:get(erli18n_locale, Env)),
    ok.

cowboy_explicit_available_and_default(_Config) ->
    %% Both `available` and `default` are supplied explicitly, exercising the
    %% lazy-resolution explicit-match arms (no fall-through to
    %% erli18n:loaded_locales/0 / erli18n:default_locale/0). The chosen
    %% `available`/`default` deliberately diverge from the loaded catalogs and
    %% the process default `en`, so the result can only come from the explicit
    %% options: `de` (loaded) is excluded from `available`, forcing the
    %% explicit `default` `it`, which is honoured even though it is not loaded.
    Req = cowboy_req(#{~"accept-language" => ~"de"}, ~"", #{}),
    Opts = #{available => [~"fr"], default => ~"it"},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"it", erli18n:which_locale()),
    ?assertEqual(~"it", maps:get(erli18n_locale, Env)),
    %% A candidate inside the explicit `available` set is selected over the
    %% explicit default, proving `available` is the one in force.
    Req2 = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    {ok, _Req2, Env2} = erli18n_cowboy:execute(Req2, #{erli18n => Opts}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env2)),
    ok.

%% =========================
%% Option-value validation (run/2 boundary) — fail-soft-and-observable
%% =========================

malformed_default_falls_back(_Config) ->
    %% A non-binary `default` is dropped, so the documented default
    %% (erli18n:default_locale/0 = `en`) applies on a total miss. The request is
    %% NOT crashed by the malformed value.
    Req = cowboy_req(#{~"accept-language" => ~"ja"}, ~"", #{}),
    Opts = #{sources => [header], default => 123},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"en", erli18n:which_locale()),
    ?assertEqual(~"en", maps:get(erli18n_locale, Env)),
    ok.

malformed_available_non_list_falls_back(_Config) ->
    %% A non-list `available` is dropped, so the loaded set (erli18n:loaded_locales/0
    %% = [de, fr, pt_BR]) applies: a `de` header still negotiates to `de`.
    Req = cowboy_req(#{~"accept-language" => ~"de"}, ~"", #{}),
    Opts = #{sources => [header], available => not_a_list},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"de", erli18n:which_locale()),
    ?assertEqual(~"de", maps:get(erli18n_locale, Env)),
    ok.

malformed_available_all_bad_elements_falls_back(_Config) ->
    %% An `available` list whose elements are all non-binary filters to empty and
    %% is dropped, so the loaded set applies (`de` header -> `de`).
    Req = cowboy_req(#{~"accept-language" => ~"de"}, ~"", #{}),
    Opts = #{sources => [header], available => [1, 2, 3]},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"de", erli18n:which_locale()),
    ?assertEqual(~"de", maps:get(erli18n_locale, Env)),
    ok.

available_mixed_elements_filtered(_Config) ->
    %% An `available` list with some non-binary elements keeps only the binary
    %% ones: here only `fr` survives, so a `de` header (filtered out) misses and
    %% falls to the default `en`, while an `fr` header is honoured.
    ReqMiss = cowboy_req(#{~"accept-language" => ~"de"}, ~"", #{}),
    Opts = #{sources => [header], available => [~"fr", bad, 7]},
    {ok, _R1, Env1} = erli18n_cowboy:execute(ReqMiss, #{erli18n => Opts}),
    ?assertEqual(~"en", maps:get(erli18n_locale, Env1)),
    ReqHit = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    {ok, _R2, Env2} = erli18n_cowboy:execute(ReqHit, #{erli18n => Opts}),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env2)),
    ok.

malformed_sources_non_list_falls_back(_Config) ->
    %% A non-list `sources` is treated as absent: the default precedence
    %% `[query, cookie, header]` applies, so the header is used.
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    Opts = #{sources => not_a_list},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env)),
    ok.

sources_stray_element_dropped(_Config) ->
    %% A `sources` list with a stray non-source element drops that element rather
    %% than reaching the adapter's candidate_value/3 with an unhandled source; the
    %% valid `header` source still resolves.
    Req = cowboy_req(#{~"accept-language" => ~"fr"}, ~"", #{}),
    Opts = #{sources => [bogus, header]},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env)),
    ok.

malformed_query_param_falls_back(_Config) ->
    %% A non-binary `query_param` falls back to the `<<"locale">>` default, so a
    %% `?locale=fr` query is still read.
    Req = cowboy_req(#{~"accept-language" => ~"de"}, ~"locale=fr", #{}),
    Opts = #{sources => [query, header], query_param => 42},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env)),
    ok.

malformed_cookie_name_falls_back(_Config) ->
    %% A non-binary `cookie_name` falls back to the `<<"locale">>` default, so the
    %% `locale=fr` cookie is still read.
    Req = cowboy_req(#{~"accept-language" => ~"de", ~"cookie" => ~"locale=fr"}, ~"", #{}),
    Opts = #{sources => [cookie, header], cookie_name => 42},
    {ok, _Req, Env} = erli18n_cowboy:execute(Req, #{erli18n => Opts}),
    ?assertEqual(~"fr", maps:get(erli18n_locale, Env)),
    ok.

%% =========================
%% Elli adapter
%% =========================

elli_header_negotiation(_Config) ->
    Req = elli_req([{~"Accept-Language", ~"pt-BR"}], []),
    ?assertEqual(Req, erli18n_elli:preprocess(Req, #{})),
    ?assertEqual(~"pt_BR", erli18n:which_locale()),
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello")),
    ok.

elli_query_override(_Config) ->
    Req = elli_req([{~"Accept-Language", ~"de"}], [{~"locale", ~"fr"}]),
    _ = erli18n_elli:preprocess(Req, #{}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

elli_cookie_override(_Config) ->
    Req = elli_req([{~"Accept-Language", ~"de"}, {~"Cookie", ~"locale=fr"}], []),
    _ = erli18n_elli:preprocess(Req, #{}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

elli_unsupported_default(_Config) ->
    Req = elli_req([{~"Accept-Language", ~"ja"}], []),
    _ = erli18n_elli:preprocess(Req, #{}),
    ?assertEqual(~"en", erli18n:which_locale()),
    ok.

elli_args_non_map(_Config) ->
    %% A non-map `Args` falls back to default options.
    Req = elli_req([{~"Accept-Language", ~"fr"}], []),
    _ = erli18n_elli:preprocess(Req, []),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

elli_path_source_is_noop(_Config) ->
    %% Elli has no path source; listing it is a harmless no-op and the header
    %% is used instead.
    Req = elli_req([{~"Accept-Language", ~"fr"}], []),
    _ = erli18n_elli:preprocess(Req, #{sources => [path, header]}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

elli_logger_metadata_off(_Config) ->
    Req = elli_req([{~"Accept-Language", ~"fr"}], []),
    _ = erli18n_elli:preprocess(Req, #{set_logger_metadata => false}),
    ?assertEqual(undefined, logger:get_process_metadata()),
    ok.

elli_logger_metadata_set(_Config) ->
    %% Mirror of cowboy_logger_metadata_set/1: default opts set the locale
    %% metadata for the request process.
    Req = elli_req([{~"Accept-Language", ~"fr"}], []),
    _ = erli18n_elli:preprocess(Req, #{}),
    ?assertEqual(#{locale => ~"fr"}, only_locale(logger:get_process_metadata())),
    ok.

elli_query_over_cookie(_Config) ->
    %% Both present, query wins (default precedence query > cookie).
    Req = elli_req([{~"Cookie", ~"locale=de"}], [{~"locale", ~"fr"}]),
    _ = erli18n_elli:preprocess(Req, #{}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

elli_custom_option_names(_Config) ->
    %% Mirror of cowboy_custom_option_names/1: custom query_param/cookie_name.
    Req = elli_req([{~"Cookie", ~"loc=de"}], [{~"lang", ~"de"}]),
    Opts = #{query_param => ~"lang", cookie_name => ~"loc"},
    _ = erli18n_elli:preprocess(Req, Opts),
    ?assertEqual(~"de", erli18n:which_locale()),
    %% Isolate the COOKIE source so the custom `cookie_name` (`loc`) is read.
    ReqCookie = elli_req([{~"Cookie", ~"loc=fr"}], [{~"lang", ~"de"}]),
    _ = erli18n_elli:preprocess(ReqCookie, Opts#{sources => [cookie, header]}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

elli_query_unsupported_default(_Config) ->
    %% Unsupported via the QUERY source in isolation -> default `en`.
    Req = elli_req([{~"Accept-Language", ~"de"}], [{~"locale", ~"ja"}]),
    _ = erli18n_elli:preprocess(Req, #{sources => [query]}),
    ?assertEqual(~"en", erli18n:which_locale()),
    ok.

elli_cookie_unsupported_default(_Config) ->
    %% Unsupported via the COOKIE source in isolation -> default `en`.
    Req = elli_req([{~"Accept-Language", ~"de"}, {~"Cookie", ~"locale=ja"}], []),
    _ = erli18n_elli:preprocess(Req, #{sources => [cookie]}),
    ?assertEqual(~"en", erli18n:which_locale()),
    ok.

elli_query_valueless(_Config) ->
    %% Mirror of cowboy_query_valueless/1: a value-less `?locale` arg surfaces as
    %% the atom `true` from elli's decoder; the seam normalizes it to undefined,
    %% so the query source is skipped and the header is used.
    Req = elli_req([{~"Accept-Language", ~"fr"}], [{~"locale", true}]),
    _ = erli18n_elli:preprocess(Req, #{}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

elli_query_malformed_escape(_Config) ->
    %% A malformed percent-escape (`?locale=%ZZ`) in the raw query: the adapter
    %% feeds the raw query (`elli_request:query_str/1`, total) to the core parser
    %% `erli18n_http:query_value/2`, whose fail-soft percent-decoding maps the
    %% malformed escape to undefined, so the source is skipped, negotiation falls
    %% through to the header, and the request does NOT crash.
    Req = elli_req([{~"Accept-Language", ~"fr"}], [{~"locale", ~"%ZZ"}]),
    _ = erli18n_elli:preprocess(Req, #{}),
    ?assertEqual(~"fr", erli18n:which_locale()),
    ok.

%% =========================
%% Helpers
%% =========================

%% Minimal cowboy_req map: cowboy_req:header/3, cowboy_req:qs/1, and
%% cowboy_req:binding/3 read exactly the `headers` / `qs` / `bindings` keys. The
%% `qs` value is the RAW query binary (cowboy stores it pre-parsed, never
%% decoding), fed straight to the total core parser `erli18n_http:query_value/2`.
cowboy_req(Headers, Qs, Bindings) ->
    #{headers => Headers, qs => Qs, bindings => Bindings}.

%% Build a partial Elli `#req{}`. The adapter now reads the RAW query via
%% `elli_request:query_str/1`, which splits `raw_path` on `?`, so the test query
%% tokens (`Args`) are rendered into `raw_path` verbatim (NOT re-encoded — a token
%% like `~"%ZZ"` is meant to be a raw, malformed escape exercising the fail-soft
%% core parser). A `true` value renders a value-less key (`?locale`, no `=`).
%% `args` is left populated too so the record stays faithful to a real request.
elli_req(Headers, Args) ->
    #req{headers = Headers, args = Args, raw_path = raw_path_of(Args)}.

raw_path_of([]) ->
    ~"/";
raw_path_of(Args) ->
    Pairs = [render_arg(Arg) || Arg <- Args],
    Qs = lists:join(~"&", Pairs),
    iolist_to_binary([~"/?", Qs]).

render_arg({Key, true}) -> Key;
render_arg({Key, Value}) when is_binary(Value) -> <<Key/binary, "=", Value/binary>>.

%% Keep only the `locale` key so the assertion is independent of any unrelated
%% metadata, while still proving the adapter set it.
only_locale(undefined) -> undefined;
only_locale(Meta) when is_map(Meta) -> maps:with([locale], Meta).
