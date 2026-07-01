-module(erli18n_fmt_SUITE).

%% Common Test suite for the `f`-suffix interpolating family on the
%% `erli18n` facade (named %{name} interpolation): `gettextf`,
%% `ngettextf`, `pgettextf`, `npgettextf` and their `d`/`dc` aliases.
%%
%% Each `f` member must RESOLVE exactly like its non-`f` sibling (same
%% domain/locale/context/plural-form selection and same miss/fallback)
%% and THEN run `erli18n_interp:format/2` over the resolved string with
%% the trailing `Bindings` map. The plural members auto-bind `count => N`
%% with a caller-supplied `count` overriding it.
%%
%% This suite is intentionally separate from `erli18n_SUITE`: it does not
%% modify that suite. Fixtures live in `erli18n_fmt_SUITE_data`.

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
    gettextf_2_uses_defaults/1,
    gettextf_3_explicit_domain/1,
    gettextf_4_explicit_locale/1,
    gettextf_reorders_by_name/1,
    gettextf_miss_falls_back_then_interpolates/1,
    dgettextf_alias/1,
    dcgettextf_alias/1
]).

%% Plural family
-export([
    ngettextf_4_uses_defaults/1,
    ngettextf_5_explicit_domain/1,
    ngettextf_6_explicit_locale/1,
    ngettextf_auto_binds_count/1,
    ngettextf_caller_count_overrides/1,
    ngettextf_plural_form_with_count_override/1,
    ngettextf_miss_falls_back_then_interpolates/1,
    dngettextf_alias/1,
    dcngettextf_alias/1
]).

%% Contextual singular family
-export([
    pgettextf_3_uses_defaults/1,
    pgettextf_4_explicit_domain/1,
    pgettextf_5_explicit_locale/1,
    pgettextf_undefined_context_like_gettext/1,
    dpgettextf_alias/1,
    dcpgettextf_alias/1
]).

%% Contextual plural family
-export([
    npgettextf_5_uses_defaults/1,
    npgettextf_6_explicit_domain/1,
    npgettextf_7_explicit_locale/1,
    npgettextf_auto_binds_count/1,
    npgettextf_caller_count_overrides/1,
    npgettextf_plural_form_with_count_override/1,
    npgettextf_undefined_context_like_ngettext/1,
    dnpgettextf_alias/1,
    dcnpgettextf_alias/1
]).

all() ->
    [
        %% singular
        gettextf_2_uses_defaults,
        gettextf_3_explicit_domain,
        gettextf_4_explicit_locale,
        gettextf_reorders_by_name,
        gettextf_miss_falls_back_then_interpolates,
        dgettextf_alias,
        dcgettextf_alias,
        %% plural
        ngettextf_4_uses_defaults,
        ngettextf_5_explicit_domain,
        ngettextf_6_explicit_locale,
        ngettextf_auto_binds_count,
        ngettextf_caller_count_overrides,
        ngettextf_plural_form_with_count_override,
        ngettextf_miss_falls_back_then_interpolates,
        dngettextf_alias,
        dcngettextf_alias,
        %% contextual singular
        pgettextf_3_uses_defaults,
        pgettextf_4_explicit_domain,
        pgettextf_5_explicit_locale,
        pgettextf_undefined_context_like_gettext,
        dpgettextf_alias,
        dcpgettextf_alias,
        %% contextual plural
        npgettextf_5_uses_defaults,
        npgettextf_6_explicit_domain,
        npgettextf_7_explicit_locale,
        npgettextf_auto_binds_count,
        npgettextf_caller_count_overrides,
        npgettextf_plural_form_with_count_override,
        npgettextf_undefined_context_like_ngettext,
        dnpgettextf_alias,
        dcnpgettextf_alias
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

%% Reset all shared state between cases (mirrors erli18n_SUITE).
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

load_fmt(Config) ->
    Path = fixture(Config, "fmt_pt_br.po"),
    {ok, _} = erli18n:ensure_loaded(default, ~"pt_BR", Path),
    {ok, _} = erli18n:ensure_loaded(my_domain, ~"pt_BR", Path),
    ok.

%% =========================
%% Singular — gettextf family
%% =========================

%% gettextf/2 resolves via gettext/1 (default domain + resolved locale)
%% then interpolates the trailing bindings.
gettextf_2_uses_defaults(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    %% Same resolution as the non-f sibling, then interpolation.
    Resolved = erli18n:gettext(~"Hello, %{name}!"),
    ?assertEqual(~"Olá, %{name}!", Resolved),
    ?assertEqual(
        ~"Olá, Ada!",
        erli18n:gettextf(~"Hello, %{name}!", #{name => ~"Ada"})
    ).

%% gettextf/3 takes the domain explicitly; locale from the PD.
gettextf_3_explicit_domain(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"Olá, Ada!",
        erli18n:gettextf(my_domain, ~"Hello, %{name}!", #{name => ~"Ada"})
    ).

%% gettextf/4 takes domain AND locale explicitly, ignoring the PD.
gettextf_4_explicit_locale(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"en"),
    ?assertEqual(
        ~"Olá, Ada!",
        erli18n:gettextf(
            default, ~"Hello, %{name}!", ~"pt_BR", #{name => ~"Ada"}
        )
    ),
    %% PD locale untouched.
    ?assertEqual(~"en", erli18n:which_locale()).

%% Resolution then interpolation must honour the translator's reorder of
%% the placeholders (resolution by name, not position).
gettextf_reorders_by_name(Config) ->
    ok = load_fmt(Config),
    %% Source order is %{user} then %{item}; the pt_BR translation
    %% reverses them. The binding still resolves by name.
    ?assertEqual(
        ~"livro enviado por Ada",
        erli18n:gettextf(
            default,
            ~"%{user} sent %{item}",
            ~"pt_BR",
            #{user => ~"Ada", item => ~"livro"}
        )
    ).

%% On a miss the resolution falls back to the msgid (which itself carries
%% placeholders), then interpolation runs over that fallback.
gettextf_miss_falls_back_then_interpolates(Config) ->
    ok = load_fmt(Config),
    %% "Bye %{name}" is not in the catalog: gettext returns the msgid,
    %% then interpolation fills %{name}.
    ?assertEqual(
        ~"Bye Ada",
        erli18n:gettextf(
            default, ~"Bye %{name}", ~"pt_BR", #{name => ~"Ada"}
        )
    ).

%% dgettextf/3,4 are exact aliases of gettextf/3,4 (GNU naming parity).
dgettextf_alias(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    B = #{name => ~"Ada"},
    ?assertEqual(
        erli18n:gettextf(default, ~"Hello, %{name}!", B),
        erli18n:dgettextf(default, ~"Hello, %{name}!", B)
    ),
    ?assertEqual(
        erli18n:gettextf(default, ~"Hello, %{name}!", ~"pt_BR", B),
        erli18n:dgettextf(default, ~"Hello, %{name}!", ~"pt_BR", B)
    ).

dcgettextf_alias(Config) ->
    ok = load_fmt(Config),
    B = #{name => ~"Ada"},
    ?assertEqual(
        erli18n:gettextf(default, ~"Hello, %{name}!", ~"pt_BR", B),
        erli18n:dcgettextf(default, ~"Hello, %{name}!", ~"pt_BR", B)
    ).

%% =========================
%% Plural — ngettextf family
%% =========================

%% ngettextf/4 resolves via ngettext/3 (default domain + resolved locale)
%% then interpolates, auto-binding count => N.
ngettextf_4_uses_defaults(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"1 árvore",
        erli18n:ngettextf(~"%{count} tree", ~"%{count} trees", 1, #{})
    ),
    ?assertEqual(
        ~"3 árvores",
        erli18n:ngettextf(~"%{count} tree", ~"%{count} trees", 3, #{})
    ).

%% ngettextf/5 takes the domain explicitly.
ngettextf_5_explicit_domain(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"2 árvores",
        erli18n:ngettextf(
            my_domain, ~"%{count} tree", ~"%{count} trees", 2, #{}
        )
    ).

%% ngettextf/6 takes domain AND locale explicitly.
ngettextf_6_explicit_locale(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"en"),
    ?assertEqual(
        ~"5 árvores",
        erli18n:ngettextf(
            default, ~"%{count} tree", ~"%{count} trees", 5, ~"pt_BR", #{}
        )
    ).

%% count => N is auto-bound even when the caller passes an empty map.
ngettextf_auto_binds_count(Config) ->
    ok = load_fmt(Config),
    ?assertEqual(
        ~"7 árvores",
        erli18n:ngettextf(
            default, ~"%{count} tree", ~"%{count} trees", 7, ~"pt_BR", #{}
        )
    ).

%% A caller-supplied count WINS over the auto-bound N.
ngettextf_caller_count_overrides(Config) ->
    ok = load_fmt(Config),
    %% N=3 selects the plural form, but the rendered count is the
    %% caller's override (99).
    ?assertEqual(
        ~"99 árvores",
        erli18n:ngettextf(
            default,
            ~"%{count} tree",
            ~"%{count} trees",
            3,
            ~"pt_BR",
            #{count => 99}
        )
    ).

%% Form selection (driven by N) and rendered count (driven by the caller
%% override) are INDEPENDENT. N=2 selects the plural msgstr ("árvores"),
%% while the override count=1 is the number actually rendered — proving the
%% override does not feed back into plural-form selection.
ngettextf_plural_form_with_count_override(Config) ->
    ok = load_fmt(Config),
    ?assertEqual(
        ~"1 árvores",
        erli18n:ngettextf(
            default,
            ~"%{count} tree",
            ~"%{count} trees",
            2,
            ~"pt_BR",
            #{count => 1}
        )
    ).

%% On a miss, ngettext falls back (msgid if N==1 else msgid_plural), and
%% interpolation runs over that fallback with the auto-bound count.
ngettextf_miss_falls_back_then_interpolates(Config) ->
    ok = load_fmt(Config),
    %% Not in the catalog: N==1 -> msgid; N==2 -> msgid_plural.
    ?assertEqual(
        ~"1 cat",
        erli18n:ngettextf(
            default, ~"%{count} cat", ~"%{count} cats", 1, ~"pt_BR", #{}
        )
    ),
    ?assertEqual(
        ~"4 cats",
        erli18n:ngettextf(
            default, ~"%{count} cat", ~"%{count} cats", 4, ~"pt_BR", #{}
        )
    ).

dngettextf_alias(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        erli18n:ngettextf(
            my_domain, ~"%{count} tree", ~"%{count} trees", 2, #{}
        ),
        erli18n:dngettextf(
            my_domain, ~"%{count} tree", ~"%{count} trees", 2, #{}
        )
    ),
    ?assertEqual(
        erli18n:ngettextf(
            my_domain, ~"%{count} tree", ~"%{count} trees", 2, ~"pt_BR", #{}
        ),
        erli18n:dngettextf(
            my_domain, ~"%{count} tree", ~"%{count} trees", 2, ~"pt_BR", #{}
        )
    ).

dcngettextf_alias(Config) ->
    ok = load_fmt(Config),
    ?assertEqual(
        erli18n:ngettextf(
            my_domain, ~"%{count} tree", ~"%{count} trees", 2, ~"pt_BR", #{}
        ),
        erli18n:dcngettextf(
            my_domain, ~"%{count} tree", ~"%{count} trees", 2, ~"pt_BR", #{}
        )
    ).

%% =========================
%% Contextual singular — pgettextf family
%% =========================

%% pgettextf/3 resolves via pgettext/2 (default domain + resolved locale)
%% then interpolates.
pgettextf_3_uses_defaults(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"Oi Ada",
        erli18n:pgettextf(~"greeting", ~"Hi %{name}", #{name => ~"Ada"})
    ).

%% pgettextf/4 takes the domain explicitly.
pgettextf_4_explicit_domain(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"Oi Ada",
        erli18n:pgettextf(
            my_domain, ~"greeting", ~"Hi %{name}", #{name => ~"Ada"}
        )
    ).

%% pgettextf/5 takes domain AND locale explicitly.
pgettextf_5_explicit_locale(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"en"),
    ?assertEqual(
        ~"Oi Ada",
        erli18n:pgettextf(
            default, ~"greeting", ~"Hi %{name}", ~"pt_BR", #{name => ~"Ada"}
        )
    ),
    ?assertEqual(~"en", erli18n:which_locale()).

%% An `undefined` context makes the contextual lookup behave exactly like
%% the non-contextual one: pgettextf/5 with `undefined` resolves the bare
%% msgid (no `msgctxt`) just as gettext would, then interpolates.
pgettextf_undefined_context_like_gettext(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"en"),
    B = #{name => ~"Ada"},
    %% The msgid "Hello, %{name}!" exists with NO context in the fixture.
    Expected = erli18n:gettextf(default, ~"Hello, %{name}!", ~"pt_BR", B),
    ?assertEqual(~"Olá, Ada!", Expected),
    ?assertEqual(
        Expected,
        erli18n:pgettextf(
            default, undefined, ~"Hello, %{name}!", ~"pt_BR", B
        )
    ).

dpgettextf_alias(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    B = #{name => ~"Ada"},
    ?assertEqual(
        erli18n:pgettextf(default, ~"greeting", ~"Hi %{name}", B),
        erli18n:dpgettextf(default, ~"greeting", ~"Hi %{name}", B)
    ),
    ?assertEqual(
        erli18n:pgettextf(default, ~"greeting", ~"Hi %{name}", ~"pt_BR", B),
        erli18n:dpgettextf(default, ~"greeting", ~"Hi %{name}", ~"pt_BR", B)
    ).

dcpgettextf_alias(Config) ->
    ok = load_fmt(Config),
    B = #{name => ~"Ada"},
    ?assertEqual(
        erli18n:pgettextf(default, ~"greeting", ~"Hi %{name}", ~"pt_BR", B),
        erli18n:dcpgettextf(default, ~"greeting", ~"Hi %{name}", ~"pt_BR", B)
    ).

%% =========================
%% Contextual plural — npgettextf family
%% =========================

%% npgettextf/5 resolves via npgettext/4 (default domain + resolved
%% locale) then interpolates, auto-binding count => N.
npgettextf_5_uses_defaults(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"1 mensagem",
        erli18n:npgettextf(
            ~"inbox", ~"%{count} message", ~"%{count} messages", 1, #{}
        )
    ),
    ?assertEqual(
        ~"3 mensagens",
        erli18n:npgettextf(
            ~"inbox", ~"%{count} message", ~"%{count} messages", 3, #{}
        )
    ).

%% npgettextf/6 takes the domain explicitly.
npgettextf_6_explicit_domain(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        ~"2 mensagens",
        erli18n:npgettextf(
            my_domain, ~"inbox", ~"%{count} message", ~"%{count} messages", 2, #{}
        )
    ).

%% npgettextf/7 takes domain AND locale explicitly.
npgettextf_7_explicit_locale(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"en"),
    ?assertEqual(
        ~"5 mensagens",
        erli18n:npgettextf(
            default,
            ~"inbox",
            ~"%{count} message",
            ~"%{count} messages",
            5,
            ~"pt_BR",
            #{}
        )
    ).

%% count => N auto-bound for the contextual plural family.
npgettextf_auto_binds_count(Config) ->
    ok = load_fmt(Config),
    ?assertEqual(
        ~"8 mensagens",
        erli18n:npgettextf(
            default,
            ~"inbox",
            ~"%{count} message",
            ~"%{count} messages",
            8,
            ~"pt_BR",
            #{}
        )
    ).

%% Caller-supplied count WINS over the auto-bound N.
npgettextf_caller_count_overrides(Config) ->
    ok = load_fmt(Config),
    ?assertEqual(
        ~"42 mensagens",
        erli18n:npgettextf(
            default,
            ~"inbox",
            ~"%{count} message",
            ~"%{count} messages",
            3,
            ~"pt_BR",
            #{count => 42}
        )
    ).

%% Contextual plural: form selection (N) and rendered count (override) are
%% independent. N=2 selects the plural msgstr ("mensagens"), override
%% count=1 is the number rendered.
npgettextf_plural_form_with_count_override(Config) ->
    ok = load_fmt(Config),
    ?assertEqual(
        ~"1 mensagens",
        erli18n:npgettextf(
            default,
            ~"inbox",
            ~"%{count} message",
            ~"%{count} messages",
            2,
            ~"pt_BR",
            #{count => 1}
        )
    ).

%% An `undefined` context makes npgettextf/7 resolve the bare plural msgid
%% (no `msgctxt`) exactly like the non-contextual ngettext path, then
%% interpolate the auto-bound count.
npgettextf_undefined_context_like_ngettext(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"en"),
    %% The "%{count} tree"/"%{count} trees" plural exists with NO context.
    Expected = erli18n:ngettextf(
        default, ~"%{count} tree", ~"%{count} trees", 3, ~"pt_BR", #{}
    ),
    ?assertEqual(~"3 árvores", Expected),
    ?assertEqual(
        Expected,
        erli18n:npgettextf(
            default,
            undefined,
            ~"%{count} tree",
            ~"%{count} trees",
            3,
            ~"pt_BR",
            #{}
        )
    ).

dnpgettextf_alias(Config) ->
    ok = load_fmt(Config),
    ok = erli18n:setlocale(~"pt_BR"),
    ?assertEqual(
        erli18n:npgettextf(
            my_domain, ~"inbox", ~"%{count} message", ~"%{count} messages", 2, #{}
        ),
        erli18n:dnpgettextf(
            my_domain, ~"inbox", ~"%{count} message", ~"%{count} messages", 2, #{}
        )
    ),
    ?assertEqual(
        erli18n:npgettextf(
            my_domain,
            ~"inbox",
            ~"%{count} message",
            ~"%{count} messages",
            2,
            ~"pt_BR",
            #{}
        ),
        erli18n:dnpgettextf(
            my_domain,
            ~"inbox",
            ~"%{count} message",
            ~"%{count} messages",
            2,
            ~"pt_BR",
            #{}
        )
    ).

dcnpgettextf_alias(Config) ->
    ok = load_fmt(Config),
    ?assertEqual(
        erli18n:npgettextf(
            my_domain,
            ~"inbox",
            ~"%{count} message",
            ~"%{count} messages",
            2,
            ~"pt_BR",
            #{}
        ),
        erli18n:dcnpgettextf(
            my_domain,
            ~"inbox",
            ~"%{count} message",
            ~"%{count} messages",
            2,
            ~"pt_BR",
            #{}
        )
    ).
