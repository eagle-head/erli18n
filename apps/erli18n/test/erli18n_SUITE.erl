-module(erli18n_SUITE).

%% Common Test suite for the public facade `erli18n.erl` (Part 6).
%% Each test carries the design citation (BR-MIGRAR-NNN / PSD-NNN)
%% in its docstring so that a failure points straight at the spec
%% it violates.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Singular family
-export([
    gettext_1_uses_defaults/1,
    gettext_2_explicit_domain/1,
    gettext_3_explicit_locale/1,
    gettext_fallback_to_msgid_when_missing/1,
    gettext_fallback_when_translation_empty/1,
    dgettext_alias/1,
    dcgettext_alias/1
]).

%% Plural family
-export([
    ngettext_uses_compiled_plural_for_locale/1,
    ngettext_fallback_when_no_translation/1,
    ngettext_fallback_when_form_empty/1,
    ngettext_bignum_huge_n/1,
    ngettext_with_explicit_locale/1,
    dngettext_alias/1,
    dcngettext_alias/1,
    ngettext_japanese_degenerate_plural/1
]).

%% Contextual family
-export([
    pgettext_singular_with_context/1,
    pgettext_fallback_to_msgid_when_context_missing/1,
    pgettext_distinct_from_undefined_context/1,
    npgettext_plural_with_context/1,
    dpgettext_alias/1,
    dnpgettext_alias/1,
    dcpgettext_alias/1,
    dcnpgettext_alias/1,
    pgettext_2_uses_defaults/1,
    npgettext_4_uses_defaults/1,
    npgettext_5_uses_defaults_for_locale/1,
    dnpgettext_5_alias/1,
    emit_lookup_miss_when_telemetry_enabled/1
]).

%% Locale / domain state
-export([
    setlocale_then_which_locale/1,
    which_locale_undefined_by_default/1,
    default_locale_used_when_setlocale_unset/1,
    default_locale_getter_setter/1,
    textdomain_getter_setter/1,
    process_dict_isolation/1,
    which_locale_invalid_process_value/1,
    default_locale_invalid_env/1,
    textdomain_invalid_env/1
]).

%% Passthrough load API
-export([
    ensure_loaded_via_facade/1,
    reload_via_facade/1,
    unload_via_facade/1,
    memory_info_passthrough/1,
    loaded_catalogs_passthrough/1,
    which_keys_passthrough/1,
    default_po_path_helper/1
]).

all() ->
    %% singular
    [
        gettext_1_uses_defaults,
        gettext_2_explicit_domain,
        gettext_3_explicit_locale,
        gettext_fallback_to_msgid_when_missing,
        gettext_fallback_when_translation_empty,
        dgettext_alias,
        dcgettext_alias,
        %% plural
        ngettext_uses_compiled_plural_for_locale,
        ngettext_fallback_when_no_translation,
        ngettext_fallback_when_form_empty,
        ngettext_bignum_huge_n,
        ngettext_with_explicit_locale,
        dngettext_alias,
        dcngettext_alias,
        ngettext_japanese_degenerate_plural,
        %% context
        pgettext_singular_with_context,
        pgettext_fallback_to_msgid_when_context_missing,
        pgettext_distinct_from_undefined_context,
        npgettext_plural_with_context,
        dpgettext_alias,
        dnpgettext_alias,
        dcpgettext_alias,
        dcnpgettext_alias,
        pgettext_2_uses_defaults,
        npgettext_4_uses_defaults,
        npgettext_5_uses_defaults_for_locale,
        dnpgettext_5_alias,
        emit_lookup_miss_when_telemetry_enabled,
        %% locale / domain state
        setlocale_then_which_locale,
        which_locale_undefined_by_default,
        default_locale_used_when_setlocale_unset,
        default_locale_getter_setter,
        textdomain_getter_setter,
        process_dict_isolation,
        which_locale_invalid_process_value,
        default_locale_invalid_env,
        textdomain_invalid_env,
        %% passthrough
        ensure_loaded_via_facade,
        reload_via_facade,
        unload_via_facade,
        memory_info_passthrough,
        loaded_catalogs_passthrough,
        which_keys_passthrough,
        default_po_path_helper
    ].

%% =========================
%% Fixtures
%% =========================

init_per_suite(Config) ->
    {ok, _Apps} = application:ensure_all_started(erli18n),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(erli18n),
    ok.

%% Clear persistent_term catalogs, process-dict locale, and application env
%% between tests so each case starts from a known baseline. The application env
%% reset is critical: `set_default_locale`/`textdomain` writes persist
%% across tests otherwise (RISK: leakage between cases).
init_per_testcase(_TC, Config) ->
    [
        ok = erli18n_server:unload(D, L)
     || {D, L, _N} <- erli18n_server:loaded_catalogs()
    ],
    erlang:erase('$erli18n_locale'),
    ok = application:unset_env(erli18n, default_locale),
    ok = application:unset_env(erli18n, default_domain),
    ok = application:unset_env(erli18n, emit_lookup_telemetry),
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

fixture(Config, Name) ->
    Dir = ?config(data_dir, Config),
    Path = filename:join(Dir, Name),
    case filelib:is_file(Path) of
        true -> Path;
        false -> ct:fail({fixture_missing, Path})
    end.

%% =========================
%% Singular — gettext family
%% =========================

%% R6 (locale + domain resolution): setlocale puts <<"pt_BR">> in the PD;
%% gettext/1 picks the default domain and uses the resolved locale.
gettext_1_uses_defaults(Config) ->
    Path = fixture(Config, "pt_br_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(~"Olá", erli18n:gettext(~"Hello")).

%% gettext/2 takes the domain explicitly; locale still comes from PD.
gettext_2_explicit_domain(Config) ->
    Path = fixture(Config, "pt_br_my_domain.po"),
    {ok, _} = erli18n:ensure_loaded(my_domain, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(~"Oi", erli18n:gettext(my_domain, ~"Hello")).

%% gettext/3 must ignore the per-process locale and use the one passed
%% explicitly — useful for one-off server-side rendering in a different
%% locale than the caller's session.
gettext_3_explicit_locale(Config) ->
    PtBrPath = fixture(Config, "pt_br_default.po"),
    EsPath = fixture(Config, "es_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", PtBrPath),
    {ok, _} = erli18n:ensure_loaded(default, ~"es", EsPath),
    ok = erli18n:setlocale(~"pt_BR"),
    %% 3-arity overrides the PD and uses <<"es">>.
    ?assertEqual(
        ~"Hola",
        erli18n:gettext(default, ~"Hello", ~"es")
    ),
    %% The PD locale is untouched.
    ?assertEqual(~"pt_BR", erli18n:which_locale()).

%% R1 (BR-MIGRAR-001): a miss returns the original msgid.
gettext_fallback_to_msgid_when_missing(Config) ->
    Path = fixture(Config, "pt_br_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        ~"NotInCatalog",
        erli18n:gettext(default, ~"NotInCatalog", ~"pt_BR")
    ).

%% PSD-003: msgstr "" is treated as untranslated. The parser drops the
%% row, the lookup misses, and the facade falls back to the msgid. The
%% facade's empty-binary guard is defence-in-depth (an empty translation
%% should never reach the UI even if a row leaked through).
gettext_fallback_when_translation_empty(Config) ->
    Path = fixture(Config, "pt_br_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        ~"Untranslated",
        erli18n:gettext(default, ~"Untranslated", ~"pt_BR")
    ).

%% dgettext/2 and gettext/2 must be exact aliases (GNU naming parity).
dgettext_alias(Config) ->
    Path = fixture(Config, "pt_br_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        erli18n:gettext(default, ~"Hello"),
        erli18n:dgettext(default, ~"Hello")
    ),
    ?assertEqual(
        erli18n:gettext(default, ~"Hello", ~"pt_BR"),
        erli18n:dgettext(default, ~"Hello", ~"pt_BR")
    ).

dcgettext_alias(Config) ->
    Path = fixture(Config, "pt_br_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        erli18n:gettext(default, ~"Hello", ~"pt_BR"),
        erli18n:dcgettext(default, ~"Hello", ~"pt_BR")
    ).

%% =========================
%% Plural — ngettext family
%% =========================

%% pt_BR rule: (n > 1) — N=0,1 -> form 0 (singular); N>=2 -> form 1.
ngettext_uses_compiled_plural_for_locale(Config) ->
    Path = fixture(Config, "plural_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"árvore",
        erli18n:ngettext(~"tree", ~"trees", 0)
    ),
    ?assertEqual(
        ~"árvore",
        erli18n:ngettext(~"tree", ~"trees", 1)
    ),
    ?assertEqual(
        ~"árvores",
        erli18n:ngettext(~"tree", ~"trees", 2)
    ),
    ?assertEqual(
        ~"árvores",
        erli18n:ngettext(~"tree", ~"trees", 100)
    ).

%% BR-MIGRAR-002: with no catalog loaded, ngettext returns msgid when
%% N == 1 and msgid_plural otherwise (English/C grammar fallback).
ngettext_fallback_when_no_translation(_Config) ->
    %% No catalog for <<"xx">>.
    ok = erli18n:setlocale(~"xx"),
    ?assertEqual(
        ~"tree",
        erli18n:ngettext(~"tree", ~"trees", 1)
    ),
    ?assertEqual(
        ~"trees",
        erli18n:ngettext(~"tree", ~"trees", 2)
    ),
    ?assertEqual(
        ~"trees",
        erli18n:ngettext(~"tree", ~"trees", 0)
    ).

%% PSD-003: msgstr[1] "" — form 1 is dropped by the parser. N=1 returns
%% the singular translation; N=2 misses form 1 and falls back to
%% msgid_plural.
ngettext_fallback_when_form_empty(Config) ->
    Path = fixture(Config, "plural_pt_br_partial.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    %% Form 0 present → translated.
    ?assertEqual(
        ~"folha",
        erli18n:ngettext(~"leaf", ~"leaves", 1)
    ),
    %% Form 1 dropped → fallback to msgid_plural.
    ?assertEqual(
        ~"leaves",
        erli18n:ngettext(~"leaf", ~"leaves", 2)
    ),
    ?assertEqual(
        ~"leaves",
        erli18n:ngettext(~"leaf", ~"leaves", 5)
    ).

%% N can be a bignum (e.g. 2^31, 2^63, more). The plural evaluator is
%% bignum-clean; the facade must pass through untouched.
ngettext_bignum_huge_n(Config) ->
    Path = fixture(Config, "plural_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    %% 2^31, breaks int32
    BigN = 2147483648,
    ?assertEqual(
        ~"árvores",
        erli18n:ngettext(~"tree", ~"trees", BigN)
    ),
    %% 2^64, well into bignum land
    HugeN = 1 bsl 64,
    ?assertEqual(
        ~"árvores",
        erli18n:ngettext(~"tree", ~"trees", HugeN)
    ),
    %% Negative N: pt_BR rule (n > 1) evaluates false, so form 0
    %% (singular). The point is the evaluator does NOT crash.
    ?assertEqual(
        ~"árvore",
        erli18n:ngettext(~"tree", ~"trees", -1)
    ).

%% 5-arity ngettext: explicit locale overrides the PD locale.
ngettext_with_explicit_locale(Config) ->
    PtBrPath = fixture(Config, "plural_pt_br.po"),
    EsPath = fixture(Config, "es_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", PtBrPath),
    {ok, _} = erli18n:ensure_loaded(default, ~"es", EsPath),
    ok = erli18n:setlocale(~"es"),
    %% Explicit pt_BR overrides es PD.
    ?assertEqual(
        ~"árvore",
        erli18n:ngettext(
            default,
            ~"tree",
            ~"trees",
            1,
            ~"pt_BR"
        )
    ),
    ?assertEqual(
        ~"árvores",
        erli18n:ngettext(
            default,
            ~"tree",
            ~"trees",
            5,
            ~"pt_BR"
        )
    ).

dngettext_alias(Config) ->
    Path = fixture(Config, "plural_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        erli18n:ngettext(
            default,
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        ),
        erli18n:dngettext(
            default,
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        )
    ),
    %% dngettext/4 uses resolved locale.
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        erli18n:ngettext(default, ~"tree", ~"trees", 2),
        erli18n:dngettext(default, ~"tree", ~"trees", 2)
    ).

dcngettext_alias(Config) ->
    Path = fixture(Config, "plural_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        erli18n:ngettext(
            default,
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        ),
        erli18n:dcngettext(
            default,
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        )
    ).

%% Japanese: nplurals=1, plural=0 — every N maps to form 0. Single
%% translation string. The facade must NOT crash and must NOT fall back
%% to msgid_plural for any N (form 0 is present).
ngettext_japanese_degenerate_plural(Config) ->
    Path = fixture(Config, "plural_ja.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"ja", Path),
    ok = erli18n:setlocale(~"ja"),
    [
        ?assertEqual(
            ~"ki",
            erli18n:ngettext(~"tree", ~"trees", N)
        )
     || N <- [0, 1, 2, 5, 100, 1000]
    ].

%% =========================
%% Contextual — pgettext / npgettext family
%% =========================

%% A msgid in a context returns its context-specific translation.
pgettext_singular_with_context(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        ~"Menu Arquivo",
        erli18n:pgettext(
            default,
            ~"menu",
            ~"File",
            ~"pt_BR"
        )
    ).

%% A miss in a context does NOT fall back to the no-context entry — it
%% falls back to the source msgid (R3).
pgettext_fallback_to_msgid_when_context_missing(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    %% No entry for context "toolbar"; must NOT leak the no-context
    %% translation "Arquivo". Must fall back to msgid "File".
    ?assertEqual(
        ~"File",
        erli18n:pgettext(
            default,
            ~"toolbar",
            ~"File",
            ~"pt_BR"
        )
    ).

%% Confirm the same msgid with and without context yields different
%% translations.
pgettext_distinct_from_undefined_context(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        ~"Arquivo",
        erli18n:pgettext(
            default,
            undefined,
            ~"File",
            ~"pt_BR"
        )
    ),
    ?assertEqual(
        ~"Menu Arquivo",
        erli18n:pgettext(
            default,
            ~"menu",
            ~"File",
            ~"pt_BR"
        )
    ).

%% Plural-in-context resolves through the per-locale rule.
npgettext_plural_with_context(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    %% (n > 1): N=1 -> form 0; N=2 -> form 1.
    ?assertEqual(
        ~"Menu árvore",
        erli18n:npgettext(
            default,
            ~"menu",
            ~"tree",
            ~"trees",
            1,
            ~"pt_BR"
        )
    ),
    ?assertEqual(
        ~"Menu árvores",
        erli18n:npgettext(
            default,
            ~"menu",
            ~"tree",
            ~"trees",
            5,
            ~"pt_BR"
        )
    ),
    %% Unknown context falls back to msgid/msgid_plural per R4.
    ?assertEqual(
        ~"tree",
        erli18n:npgettext(
            default,
            ~"unknown",
            ~"tree",
            ~"trees",
            1,
            ~"pt_BR"
        )
    ),
    ?assertEqual(
        ~"trees",
        erli18n:npgettext(
            default,
            ~"unknown",
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        )
    ).

dpgettext_alias(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        erli18n:pgettext(default, ~"menu", ~"File"),
        erli18n:dpgettext(default, ~"menu", ~"File")
    ),
    ?assertEqual(
        erli18n:pgettext(
            default,
            ~"menu",
            ~"File",
            ~"pt_BR"
        ),
        erli18n:dpgettext(
            default,
            ~"menu",
            ~"File",
            ~"pt_BR"
        )
    ).

dnpgettext_alias(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        erli18n:npgettext(
            default,
            ~"menu",
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        ),
        erli18n:dnpgettext(
            default,
            ~"menu",
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        )
    ).

dcpgettext_alias(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        erli18n:pgettext(
            default,
            ~"menu",
            ~"File",
            ~"pt_BR"
        ),
        erli18n:dcpgettext(
            default,
            ~"menu",
            ~"File",
            ~"pt_BR"
        )
    ).

dcnpgettext_alias(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        erli18n:npgettext(
            default,
            ~"menu",
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        ),
        erli18n:dcnpgettext(
            default,
            ~"menu",
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        )
    ).

%% pgettext/2 arity shortcut: with no Domain and no Locale args, the
%% facade must resolve domain from `textdomain/0` (defaults to `default`)
%% and locale from `which_locale/0` (the PD entry set by setlocale/1).
%% Behavioural assertion: the returned translation matches the one the
%% caller would get from the explicit 4-arity call.
pgettext_2_uses_defaults(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"Menu Arquivo",
        erli18n:pgettext(~"menu", ~"File")
    ),
    %% Parity with the explicit 4-arity call.
    ?assertEqual(
        erli18n:pgettext(default, ~"menu", ~"File", ~"pt_BR"),
        erli18n:pgettext(~"menu", ~"File")
    ).

%% npgettext/4 arity shortcut: domain from `textdomain/0`, locale from
%% `which_locale/0`. Exercises the contextual+plural path with N>1, which
%% selects plural form 1 under the pt_BR rule (n > 1).
npgettext_4_uses_defaults(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    %% N=1 -> form 0 (singular).
    ?assertEqual(
        ~"Menu árvore",
        erli18n:npgettext(
            ~"menu",
            ~"tree",
            ~"trees",
            1
        )
    ),
    %% N=2 -> form 1 (plural).
    ?assertEqual(
        ~"Menu árvores",
        erli18n:npgettext(
            ~"menu",
            ~"tree",
            ~"trees",
            2
        )
    ),
    %% Parity with the explicit 6-arity call.
    ?assertEqual(
        erli18n:npgettext(
            default,
            ~"menu",
            ~"tree",
            ~"trees",
            2,
            ~"pt_BR"
        ),
        erli18n:npgettext(
            ~"menu",
            ~"tree",
            ~"trees",
            2
        )
    ).

%% npgettext/5 (Domain + Context + Msgid + Plural + N, no Locale): the
%% Locale must come from `which_locale/0`. We load the same fixture under
%% `my_domain` so the lookup hits and the assertion can compare against a
%% known translation, while setlocale picks the right catalog.
npgettext_5_uses_defaults_for_locale(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(my_domain, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"Menu árvore",
        erli18n:npgettext(
            my_domain,
            ~"menu",
            ~"tree",
            ~"trees",
            1
        )
    ),
    ?assertEqual(
        ~"Menu árvores",
        erli18n:npgettext(
            my_domain,
            ~"menu",
            ~"tree",
            ~"trees",
            5
        )
    ),
    %% Parity with the explicit 6-arity call: same Domain, Context,
    %% Msgid, Plural, N — the 5-arity must pick up <<"pt_BR">> from PD.
    ?assertEqual(
        erli18n:npgettext(
            my_domain,
            ~"menu",
            ~"tree",
            ~"trees",
            5,
            ~"pt_BR"
        ),
        erli18n:npgettext(
            my_domain,
            ~"menu",
            ~"tree",
            ~"trees",
            5
        )
    ).

%% dnpgettext/5 — GNU C-macro alias for npgettext/5 (no explicit Locale,
%% Locale comes from the PD via setlocale). Must return the exact same
%% translation as the underlying npgettext/5 call.
dnpgettext_5_alias(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(my_domain, ~"pt_BR", Path),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        erli18n:npgettext(
            my_domain,
            ~"menu",
            ~"tree",
            ~"trees",
            1
        ),
        erli18n:dnpgettext(
            my_domain,
            ~"menu",
            ~"tree",
            ~"trees",
            1
        )
    ),
    ?assertEqual(
        erli18n:npgettext(
            my_domain,
            ~"menu",
            ~"tree",
            ~"trees",
            5
        ),
        erli18n:dnpgettext(
            my_domain,
            ~"menu",
            ~"tree",
            ~"trees",
            5
        )
    ).

%% With `emit_lookup_telemetry = true` set via the public application
%% env, a lookup miss must drive the enabled branch of
%% `emit_lookup_miss/5` (the one that actually calls
%% `erli18n_telemetry:emit/3`). Behavioural assertion: the lookup still
%% returns the msgid fallback — the user-visible contract does not change
%% when telemetry is enabled. The presence of the flag is the only
%% observable difference at the API surface; the emit itself is
%% verified by attaching a `:telemetry` handler that records the event.
emit_lookup_miss_when_telemetry_enabled(_Config) ->
    %% `telemetry` is listed as `optional_applications` so we must start
    %% it explicitly here. Idempotent — already-started is also ok.
    {ok, _} = application:ensure_all_started(telemetry),
    ok = application:set_env(erli18n, emit_lookup_telemetry, true),
    Self = self(),
    HandlerId = {?MODULE, emit_lookup_miss_when_telemetry_enabled},
    ok = telemetry:attach(
        HandlerId,
        [erli18n, lookup, miss],
        fun(Event, Measurements, Metadata, _Cfg) ->
            Self ! {telemetry_event, Event, Measurements, Metadata}
        end,
        undefined
    ),
    try
        %% Force a miss across the four call sites that go through
        %% emit_lookup_miss/5 (gettext, ngettext, pgettext, npgettext).
        ?assertEqual(
            ~"Missing",
            erli18n:gettext(default, ~"Missing", ~"xx")
        ),
        ?assertEqual(
            ~"Missings",
            erli18n:ngettext(
                default,
                ~"Missing",
                ~"Missings",
                2,
                ~"xx"
            )
        ),
        ?assertEqual(
            ~"Missing",
            erli18n:pgettext(
                default,
                ~"ctx",
                ~"Missing",
                ~"xx"
            )
        ),
        ?assertEqual(
            ~"Missings",
            erli18n:npgettext(
                default,
                ~"ctx",
                ~"Missing",
                ~"Missings",
                2,
                ~"xx"
            )
        ),
        %% Drain the events: we must see at least one per call site.
        Events = collect_telemetry_events([]),
        Functions = lists:sort([
            maps:get(function, Md)
         || {telemetry_event, [erli18n, lookup, miss], _, Md} <-
                Events
        ]),
        ?assertEqual([gettext, ngettext, npgettext, pgettext], Functions)
    after
        ok = telemetry:detach(HandlerId)
    end.

%% Drain telemetry events sent to the test process. Uses a short timeout
%% to bound the wait — telemetry handlers are synchronous so all events
%% are already in the mailbox by the time the lookup returns.
collect_telemetry_events(Acc) ->
    receive
        {telemetry_event, _, _, _} = E ->
            collect_telemetry_events([E | Acc])
    after 100 ->
        lists:reverse(Acc)
    end.

%% =========================
%% Locale / domain state
%% =========================

setlocale_then_which_locale(_Config) ->
    ?assertEqual(undefined, erli18n:which_locale()),
    ok = erli18n:setlocale(~"de"),
    ?assertEqual(~"de", erli18n:which_locale()),
    %% Idempotent overwrite.
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(~"pt_BR", erli18n:which_locale()).

%% Per BR-MIGRAR-003: process dictionary is per-process. A freshly
%% spawned process starts with which_locale = undefined.
which_locale_undefined_by_default(_Config) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        Parent ! {self(), erli18n:which_locale()}
    end),
    receive
        {Pid, Result} ->
            ?assertEqual(undefined, Result)
    after 1000 ->
        ct:fail(timeout_waiting_for_spawned_process)
    end.

%% R5: when setlocale is never called, the resolved locale is whatever
%% default_locale/0 returns. Verified indirectly: load the catalog for
%% the default <<"en">> and confirm lookup works without setlocale.
default_locale_used_when_setlocale_unset(Config) ->
    %% Default is <<"en">> per the facade constant.

    %% any po file, we use the catalog
    EnPath = fixture(Config, "es_default.po"),
    %% Load under the locale that default_locale/0 returns.
    DefaultLocale = erli18n:default_locale(),
    ?assertEqual(~"en", DefaultLocale),
    %% Switch default to es so a no-setlocale gettext resolves there.
    ok = erli18n:set_default_locale(~"es"),
    {ok, _} = erli18n:ensure_loaded(default, ~"es", EnPath),
    ?assertEqual(undefined, erli18n:which_locale()),
    %% gettext/1 with no PD locale must use the application default.
    ?assertEqual(~"Hola", erli18n:gettext(~"Hello")).

default_locale_getter_setter(_Config) ->
    ?assertEqual(~"en", erli18n:default_locale()),
    ok = erli18n:set_default_locale(~"pt_BR"),
    ?assertEqual(~"pt_BR", erli18n:default_locale()).

textdomain_getter_setter(_Config) ->
    %% The application's default domain is `default`.
    ?assertEqual(default, erli18n:textdomain()),
    ok = erli18n:textdomain(my_app),
    ?assertEqual(my_app, erli18n:textdomain()).

%% Critical BEAM property: process dictionary is per-process. Setting
%% locale in the parent must NOT bleed into a spawned child.
process_dict_isolation(_Config) ->
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(~"pt_BR", erli18n:which_locale()),
    Parent = self(),
    Pid = spawn_link(fun() ->
        Parent ! {self(), erli18n:which_locale()}
    end),
    receive
        {Pid, ChildLocale} ->
            ?assertEqual(undefined, ChildLocale)
    after 1000 ->
        ct:fail(timeout)
    end,
    %% Parent dict still intact.
    ?assertEqual(~"pt_BR", erli18n:which_locale()).

%% Config-validation contracts: a corrupt per-process locale or a malformed
%% env value surfaces a structured error (input -> output), never a silent
%% wrong type. init_per_testcase resets the process key and env afterward.
which_locale_invalid_process_value(_Config) ->
    erlang:put('$erli18n_locale', not_a_binary),
    ?assertError(
        {invalid_process_locale, {'$erli18n_locale', not_a_binary, expected, binary}},
        erli18n:which_locale()
    ).

default_locale_invalid_env(_Config) ->
    application:set_env(erli18n, default_locale, some_atom),
    ?assertError(
        {invalid_config, {erli18n, default_locale, some_atom, expected, binary}},
        erli18n:default_locale()
    ).

textdomain_invalid_env(_Config) ->
    application:set_env(erli18n, default_domain, ~"x"),
    ?assertError(
        {invalid_config, {erli18n, default_domain, ~"x", expected, atom}},
        erli18n:textdomain()
    ).

%% =========================
%% Passthrough load API
%% =========================

ensure_loaded_via_facade(Config) ->
    Path = fixture(Config, "pt_br_default.po"),
    Result = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertMatch({ok, N} when is_integer(N), Result),
    %% Idempotent second call.
    ?assertEqual(
        {ok, already},
        erli18n:ensure_loaded(default, ~"pt_BR", Path)
    ),
    %% With opts (include_fuzzy is irrelevant for this fixture; we
    %% only test that the 4-arity passes through).
    ?assertEqual(
        {ok, already},
        erli18n:ensure_loaded(default, ~"pt_BR", Path, #{})
    ).

reload_via_facade(Config) ->
    PtBrPath = fixture(Config, "pt_br_default.po"),
    EsPath = fixture(Config, "es_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", PtBrPath),
    %% Reload under the same (D, L) with a different file; the catalog
    %% is replaced (AMB-001).
    {ok, _} = erli18n:reload(default, ~"pt_BR", EsPath),
    %% "Hello" -> "Hola" now (es content under pt_BR key).
    ?assertEqual(
        ~"Hola",
        erli18n:gettext(default, ~"Hello", ~"pt_BR")
    ),
    %% reload/4 also passes through.
    {ok, _} = erli18n:reload(default, ~"pt_BR", PtBrPath, #{}),
    ?assertEqual(
        ~"Olá",
        erli18n:gettext(default, ~"Hello", ~"pt_BR")
    ).

unload_via_facade(Config) ->
    Path = fixture(Config, "pt_br_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    ?assertEqual(
        ~"Olá",
        erli18n:gettext(default, ~"Hello", ~"pt_BR")
    ),
    ok = erli18n:unload(default, ~"pt_BR"),
    %% After unload, lookup misses → fallback to msgid.
    ?assertEqual(
        ~"Hello",
        erli18n:gettext(default, ~"Hello", ~"pt_BR")
    ).

memory_info_passthrough(Config) ->
    Path = fixture(Config, "pt_br_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    Info = erli18n:memory_info(),
    ?assertMatch(
        #{
            ets_bytes := _,
            num_catalogs := _,
            num_keys := _
        },
        Info
    ),
    ?assert(maps:get(ets_bytes, Info) > 0),
    %% Hello + Goodbye at least
    ?assert(maps:get(num_keys, Info) >= 2),
    ?assertEqual(1, maps:get(num_catalogs, Info)).

loaded_catalogs_passthrough(Config) ->
    PtBrPath = fixture(Config, "pt_br_default.po"),
    EsPath = fixture(Config, "es_default.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", PtBrPath),
    {ok, _} = erli18n:ensure_loaded(default, ~"es", EsPath),
    Cats = erli18n:loaded_catalogs(),
    ?assertEqual(2, length(Cats)),
    %% Project each tuple to {Domain, Locale} for set comparison so the
    %% test does not depend on row counts.
    Pairs = lists:sort([{D, L} || {D, L, _N} <- Cats]),
    ?assertEqual([{default, ~"es"}, {default, ~"pt_BR"}], Pairs).

which_keys_passthrough(Config) ->
    Path = fixture(Config, "context_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    Keys = erli18n:which_keys(default, ~"pt_BR"),
    %% Two singular "File" entries (context undefined + "menu") +
    %% one plural "tree" in "menu". Plural is deduped.
    ?assert(length(Keys) >= 3),
    ?assert(lists:member({singular, undefined, ~"File"}, Keys)),
    ?assert(lists:member({singular, ~"menu", ~"File"}, Keys)),
    ?assert(lists:member({plural, ~"menu", ~"tree"}, Keys)).

default_po_path_helper(_Config) ->
    Path = erli18n:default_po_path(erli18n, default, ~"pt_BR"),
    PathBin = iolist_to_binary(Path),
    ?assert(
        binary:match(
            PathBin,
            ~"/priv/locale/pt_BR/LC_MESSAGES/default.po"
        ) =/=
            nomatch
    ).
