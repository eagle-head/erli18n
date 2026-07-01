%%% =====================================================================
%%% Common Test suite for the locale-fallback FACADE integration.
%%%
%%% A `pt` catalog is loaded; the suite asserts that a `pt_BR` (and its
%%% hyphenated / mis-cased / legacy-alias forms) request:
%%%   * returns the raw msgid when `locale_fallback = off` (default; the
%%%     exact 0.2.0 behavior), and
%%%   * falls back to the loaded `pt` catalog when `base_language` (or a
%%%     matching `{explicit, Map}`) is enabled,
%%% across all four lookup families (gettext / ngettext / pgettext /
%%% npgettext) and the interpolating `f`-family, with the
%%% `[erli18n, locale, fallback]` telemetry event firing only when enabled.
%%% =====================================================================
-module(erli18n_fallback_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    off_is_unchanged/1,
    exact_hit_unaffected_when_enabled/1,
    base_language_singular/1,
    base_language_canonicalization/1,
    base_language_plural/1,
    base_language_contextual/1,
    base_language_contextual_plural/1,
    base_language_f_family/1,
    base_language_ngettextf/1,
    base_language_pgettextf/1,
    base_language_npgettextf/1,
    unknown_locale_still_misses/1,
    explicit_map_override/1,
    explicit_map_fallthrough/1,
    set_locale_fallback_off_roundtrip/1,
    facade_negotiate_and_parse/1,
    facade_canonicalize_locale/1,
    facade_negotiate_falls_to_default/1,
    base_language_plural_whole_chain_miss/1,
    invalid_default_locale_is_failsoft/1,
    invalid_locale_fallback_behaves_as_off/1,
    telemetry_event_on_fallback_hit/1,
    telemetry_chain_depth_consistent/1,
    telemetry_silent_when_disabled/1
]).

-define(DOMAIN, fb).

all() ->
    [
        off_is_unchanged,
        exact_hit_unaffected_when_enabled,
        base_language_singular,
        base_language_canonicalization,
        base_language_plural,
        base_language_contextual,
        base_language_contextual_plural,
        base_language_f_family,
        base_language_ngettextf,
        base_language_pgettextf,
        base_language_npgettextf,
        unknown_locale_still_misses,
        explicit_map_override,
        explicit_map_fallthrough,
        set_locale_fallback_off_roundtrip,
        facade_negotiate_and_parse,
        facade_canonicalize_locale,
        facade_negotiate_falls_to_default,
        base_language_plural_whole_chain_miss,
        invalid_default_locale_is_failsoft,
        invalid_locale_fallback_behaves_as_off,
        telemetry_event_on_fallback_hit,
        telemetry_chain_depth_consistent,
        telemetry_silent_when_disabled
    ].

init_per_suite(Config) ->
    %% `telemetry` is optional_applications (not auto-started); boot it
    %% explicitly so the fallback-event cases can attach a handler. The lib
    %% stays crash-safe when telemetry is absent (covered by the telemetry
    %% suite); here we exercise the attach/emit path.
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _Apps} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    _ = application:stop(telemetry),
    ok.

init_per_testcase(_TC, Config) ->
    %% Clean slate: unload catalogs, reset locale + the fallback env, then
    %% load the `pt` base catalog under locale "pt".
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    erlang:erase('$erli18n_locale'),
    ok = application:set_env(erli18n, default_locale, ~"und"),
    ok = application:set_env(erli18n, locale_fallback, off),
    ok = application:set_env(erli18n, emit_lookup_telemetry, false),
    Path = fixture(Config, "fallback_pt.po"),
    {ok, _} = erli18n:ensure_loaded(?DOMAIN, ~"pt", Path),
    Config.

end_per_testcase(_TC, _Config) ->
    ok = application:unset_env(erli18n, default_locale),
    ok = application:set_env(erli18n, locale_fallback, off),
    ok = application:unset_env(erli18n, emit_lookup_telemetry),
    detach_all(),
    ok.

%% =========================
%% Cases
%% =========================

off_is_unchanged(_Config) ->
    %% Default off: a pt_BR request misses through to the msgid / msgid_plural,
    %% identical to 0.2.0.
    ?assertEqual(~"Hello", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR")),
    ?assertEqual(~"trees", erli18n:ngettext(?DOMAIN, ~"tree", ~"trees", 2, ~"pt_BR")),
    ?assertEqual(~"Open", erli18n:pgettext(?DOMAIN, ~"menu", ~"Open", ~"pt_BR")),
    ?assertEqual(
        ~"messages",
        erli18n:npgettext(?DOMAIN, ~"inbox", ~"message", ~"messages", 2, ~"pt_BR")
    ),
    ok.

exact_hit_unaffected_when_enabled(_Config) ->
    %% Enabling the chain must not change an exact hit.
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt")),
    ?assertEqual(
        ~"árvores", erli18n:ngettext(?DOMAIN, ~"tree", ~"trees", 2, ~"pt")
    ),
    ok.

base_language_singular(_Config) ->
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR")),
    ok.

base_language_canonicalization(_Config) ->
    ok = erli18n:set_locale_fallback(base_language),
    %% Hyphenated, mis-cased, and legacy forms all canonicalize and fall back.
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt-BR")),
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"PT_br")),
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR.UTF-8")),
    ok.

base_language_plural(_Config) ->
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(
        ~"árvore", erli18n:ngettext(?DOMAIN, ~"tree", ~"trees", 1, ~"pt_BR")
    ),
    ?assertEqual(
        ~"árvores", erli18n:ngettext(?DOMAIN, ~"tree", ~"trees", 5, ~"pt_BR")
    ),
    ok.

base_language_contextual(_Config) ->
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(~"Abrir", erli18n:pgettext(?DOMAIN, ~"menu", ~"Open", ~"pt_BR")),
    ok.

base_language_contextual_plural(_Config) ->
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(
        ~"mensagem",
        erli18n:npgettext(?DOMAIN, ~"inbox", ~"message", ~"messages", 1, ~"pt_BR")
    ),
    ?assertEqual(
        ~"mensagens",
        erli18n:npgettext(?DOMAIN, ~"inbox", ~"message", ~"messages", 4, ~"pt_BR")
    ),
    ok.

base_language_f_family(_Config) ->
    %% The interpolating family delegates to the non-f sibling, so it inherits
    %% the fallback; the msgstr here has no placeholder, output is the plain
    %% translation (exercises the delegation path).
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(~"Olá", erli18n:gettextf(?DOMAIN, ~"Hello", ~"pt_BR", #{})),
    ok.

unknown_locale_still_misses(_Config) ->
    %% A locale whose whole chain is unloaded (default "und" not loaded) still
    %% returns the msgid even with fallback enabled.
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(~"Hello", erli18n:gettext(?DOMAIN, ~"Hello", ~"xx_YY")),
    ok.

explicit_map_override(_Config) ->
    %% An explicit override points de_AT at pt.
    ok = erli18n:set_locale_fallback({explicit, #{~"de_AT" => [~"pt"]}}),
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"de_AT")),
    %% A hyphenated request key still matches the canonical map key.
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"de-AT")),
    ok.

explicit_map_fallthrough(_Config) ->
    %% An unlisted locale falls through to base_language behavior.
    ok = erli18n:set_locale_fallback({explicit, #{~"de_AT" => [~"pt"]}}),
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR")),
    ok.

%% The interpolating plural/contextual f-variants thread context and N through
%% the chain — exercise each (the msgstrs carry no placeholder, so the output
%% is the plain fallback translation, proving the delegation path).
base_language_ngettextf(_Config) ->
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(~"árvore", erli18n:ngettextf(?DOMAIN, ~"tree", ~"trees", 1, ~"pt_BR", #{})),
    ?assertEqual(~"árvores", erli18n:ngettextf(?DOMAIN, ~"tree", ~"trees", 5, ~"pt_BR", #{})),
    ok.

base_language_pgettextf(_Config) ->
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(~"Abrir", erli18n:pgettextf(?DOMAIN, ~"menu", ~"Open", ~"pt_BR", #{})),
    ok.

base_language_npgettextf(_Config) ->
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(
        ~"mensagem",
        erli18n:npgettextf(?DOMAIN, ~"inbox", ~"message", ~"messages", 1, ~"pt_BR", #{})
    ),
    ?assertEqual(
        ~"mensagens",
        erli18n:npgettextf(?DOMAIN, ~"inbox", ~"message", ~"messages", 4, ~"pt_BR", #{})
    ),
    ok.

set_locale_fallback_off_roundtrip(_Config) ->
    %% Enabling resolves the fallback; switching back to off reverts EXACTLY to
    %% the 0.2.0 raw-msgid behavior.
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR")),
    ok = erli18n:set_locale_fallback(off),
    ?assertEqual(~"Hello", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR")),
    ok.

facade_negotiate_and_parse(_Config) ->
    %% Facade passthroughs: negotiate/2 + parse_accept_language/1.
    ?assertEqual({ok, ~"pt"}, erli18n:negotiate([~"pt-BR"], [~"pt", ~"en"])),
    Prefs = erli18n:parse_accept_language(~"fr-CH, pt;q=0.9, en;q=0.5"),
    ?assertEqual([{~"fr-ch", 1000}, {~"pt", 900}, {~"en", 500}], Prefs),
    ?assertEqual({ok, ~"pt"}, erli18n:negotiate(Prefs, [~"pt", ~"en"])),
    ok.

facade_canonicalize_locale(_Config) ->
    ?assertEqual(~"pt_BR", erli18n:canonicalize_locale(~"PT-br.UTF-8")),
    ?assertEqual(~"he", erli18n:canonicalize_locale(~"iw")),
    ok.

facade_negotiate_falls_to_default(_Config) ->
    %% The facade negotiate/2 ALWAYS returns {ok,_}, defaulting to
    %% default_locale() on no match — the OPPOSITE of the module's negotiate/2,
    %% which returns `error`. A regression collapsing them would pass the gate
    %% but break callers, so assert both contracts here.
    ok = application:set_env(erli18n, default_locale, ~"en"),
    ?assertEqual({ok, ~"en"}, erli18n:negotiate([~"zh_Hant"], [~"pt", ~"de"])),
    ?assertEqual(error, erli18n_negotiate:negotiate([~"zh_Hant"], [~"pt", ~"de"])),
    ok.

base_language_plural_whole_chain_miss(_Config) ->
    %% A plural lookup whose ENTIRE fallback chain is unloaded falls through to
    %% the C-convention plural msgid (drives the resolve_plural recursion, the
    %% empty-chain base case, and the whole-chain miss).
    ok = erli18n:set_locale_fallback(base_language),
    ?assertEqual(~"tree", erli18n:ngettext(?DOMAIN, ~"tree", ~"trees", 1, ~"xx_YY")),
    ?assertEqual(~"trees", erli18n:ngettext(?DOMAIN, ~"tree", ~"trees", 5, ~"xx_YY")),
    ok.

invalid_default_locale_is_failsoft(_Config) ->
    %% Enabling fallback with a MISCONFIGURED default_locale must never turn a
    %% lookup miss into a crash: the chain is built without a floor and still
    %% resolves the base language.
    ok = erli18n:set_locale_fallback(base_language),
    ok = application:set_env(erli18n, default_locale, not_a_binary),
    ?assertEqual(~"Olá", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR")),
    ok.

invalid_locale_fallback_behaves_as_off(_Config) ->
    %% A garbage locale_fallback value degrades to `off` (returns the raw
    %% msgid), never crashing the lookup.
    ok = application:set_env(erli18n, locale_fallback, some_garbage_value),
    ?assertEqual(~"Hello", erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR")),
    ok.

telemetry_chain_depth_consistent(_Config) ->
    %% pt_BR (canonical) and pt-BR (hyphenated) resolve the identical chain to
    %% `pt`; both must report the SAME chain_depth (measured against the full
    %% canonical chain, not the redundant-head-dropped one).
    ok = erli18n:set_locale_fallback(base_language),
    ok = application:set_env(erli18n, emit_lookup_telemetry, true),
    D1 = capture_chain_depth(~"pt_BR"),
    D2 = capture_chain_depth(~"pt-BR"),
    ?assertEqual(1, D1),
    ?assertEqual(D1, D2),
    ok.

telemetry_event_on_fallback_hit(_Config) ->
    ok = erli18n:set_locale_fallback(base_language),
    ok = application:set_env(erli18n, emit_lookup_telemetry, true),
    Self = self(),
    Ref = make_ref(),
    Handler = {?MODULE, Ref},
    ok = telemetry:attach(
        Handler,
        [erli18n, locale, fallback],
        fun(Event, Measurements, Metadata, _) ->
            Self ! {Ref, Event, Measurements, Metadata}
        end,
        undefined
    ),
    ~"Olá" = erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR"),
    receive
        {Ref, [erli18n, locale, fallback], Measurements, Metadata} ->
            ?assertEqual(1, maps:get(count, Measurements)),
            %% Full canonical chain pt_BR -> [pt_BR, pt, und]; pt resolves at
            %% chain index 1 (depth is measured against the full chain, so the
            %% redundant-head skip does not shift it).
            ?assertEqual(1, maps:get(chain_depth, Measurements)),
            ?assertEqual(~"pt_BR", maps:get(requested_locale, Metadata)),
            ?assertEqual(~"pt", maps:get(resolved_locale, Metadata)),
            ?assertEqual(gettext, maps:get(function, Metadata))
    after 1000 ->
        ct:fail(no_locale_fallback_event)
    end,
    ok.

telemetry_silent_when_disabled(_Config) ->
    %% Flag off: no event even though the fallback resolves the translation.
    ok = erli18n:set_locale_fallback(base_language),
    ok = application:set_env(erli18n, emit_lookup_telemetry, false),
    Self = self(),
    Ref = make_ref(),
    Handler = {?MODULE, Ref},
    ok = telemetry:attach(
        Handler,
        [erli18n, locale, fallback],
        fun(Event, Measurements, Metadata, _) ->
            Self ! {Ref, Event, Measurements, Metadata}
        end,
        undefined
    ),
    ~"Olá" = erli18n:gettext(?DOMAIN, ~"Hello", ~"pt_BR"),
    receive
        {Ref, _, _, _} -> ct:fail(unexpected_locale_fallback_event)
    after 200 ->
        ok
    end.

%% =========================
%% Helpers
%% =========================

fixture(Config, Name) ->
    Dir = ?config(data_dir, Config),
    Path = filename:join(Dir, Name),
    case filelib:is_file(Path) of
        true -> Path;
        false -> ct:fail({fixture_missing, Path})
    end.

%% Detach any telemetry handlers this suite attached (best effort).
detach_all() ->
    _ = [
        telemetry:detach(Id)
     || #{id := Id} <- telemetry:list_handlers([erli18n, locale, fallback])
    ],
    ok.

%% Attach a one-shot handler, trigger a fallback hit for `Locale`, and return
%% the reported chain_depth. Assumes base_language + telemetry are enabled.
capture_chain_depth(Locale) ->
    Self = self(),
    Ref = make_ref(),
    ok = telemetry:attach(
        {?MODULE, Ref},
        [erli18n, locale, fallback],
        fun(_E, Measurements, _Meta, _) -> Self ! {Ref, maps:get(chain_depth, Measurements)} end,
        undefined
    ),
    ~"Olá" = erli18n:gettext(?DOMAIN, ~"Hello", Locale),
    Depth =
        receive
            {Ref, D} -> D
        after 1000 -> ct:fail({no_event_for, Locale})
        end,
    ok = telemetry:detach({?MODULE, Ref}),
    Depth.
