-module(erli18n).

-moduledoc """
Fachada pública (API) da biblioteca `erli18n`.

Espelha a família de macros GNU gettext do C, mapeando cada macro para uma
função homônima:

- Singular: `gettext` / `dgettext` (domínio explícito) / `dcgettext` (com
  categoria — sempre LC_MESSAGES).
- Plural: `ngettext` / `dngettext` / `dcngettext`.
- Contextual singular (`msgctxt`): `pgettext` / `dpgettext` / `dcpgettext`.
- Contextual plural: `npgettext` / `dnpgettext` / `dcnpgettext`.

O locale corrente é estado por processo (dicionário de processo, via
`setlocale/1` e `which_locale/0`); o domínio e o locale default são valores
de `application:env`. As variantes `d*`/`dc*` existem para compatibilidade de
nome com o gettext do C: a categoria nunca é modelada como parâmetro
(`erli18n` é sempre LC_MESSAGES). Toda a carga, recarga e observabilidade de
catálogos é delegada a `erli18n_server`.
""".

%% ============================================================================
%%  Public API façade for `erli18n`.
%%
%%  Mirrors the GNU gettext C macro family:
%%      gettext, dgettext, dcgettext,
%%      ngettext, dngettext, dcngettext,
%%      pgettext, dpgettext, dcpgettext,
%%      npgettext, dnpgettext, dcnpgettext.
%%
%%  Reference: GNU gettext manual, "How Marking Works":
%%      https://www.gnu.org/software/gettext/manual/gettext.html#How-Marking-Works
%%
%%  Parity goal: API surface matches `gettexter.erl` (legacy) — see
%%  `target_business_rules.md` BR-MIGRAR-013/014/015/016/017/018. Existing
%%  consumers should be able to rewrite `gettexter:foo(...)` →
%%  `erli18n:foo(...)` with no other code change.
%%
%%  Lookup rules (R1-R6) come from BR-MIGRAR-001/002 and PSD-003. See the
%%  per-function comments below for citations.
%% ============================================================================

-include("erli18n.hrl").

%% Singular lookup (R1) — gettext/dgettext/dcgettext family.
-export([
    gettext/1, gettext/2, gettext/3,
    dgettext/2, dgettext/3,
    dcgettext/3
]).

%% Plural lookup (R2) — ngettext/dngettext/dcngettext family.
-export([
    ngettext/3, ngettext/4, ngettext/5,
    dngettext/4, dngettext/5,
    dcngettext/5
]).

%% Contextual singular (R3) — pgettext/dpgettext/dcpgettext family.
-export([
    pgettext/2, pgettext/3, pgettext/4,
    dpgettext/3, dpgettext/4,
    dcpgettext/4
]).

%% Contextual plural (R4) — npgettext/dnpgettext/dcnpgettext family.
-export([
    npgettext/4, npgettext/5, npgettext/6,
    dnpgettext/5, dnpgettext/6,
    dcnpgettext/6
]).

%% Per-process state: current locale via process dictionary (gettexter
%% convention, BR-MIGRAR-003).
-export([
    which_locale/0,
    setlocale/1
]).

%% Application-wide defaults.
-export([
    default_locale/0,
    set_default_locale/1,
    textdomain/0,
    textdomain/1
]).

%% Load orchestration passthrough (BR-MIGRAR-017/018).
-export([
    ensure_loaded/3,
    ensure_loaded/4,
    reload/3,
    reload/4,
    unload/2,
    default_po_path/3
]).

%% Observability passthrough.
-export([
    memory_info/0,
    loaded_catalogs/0,
    which_keys/2
]).

%% =========================
%% Types (re-exported / aliases)
%% =========================

%% atom()
-type domain() :: erli18n_server:domain().
%% binary()
-type locale() :: erli18n_server:locale().
%% undefined | binary()
-type context() :: erli18n_server:context().
%% binary()
-type msgid() :: erli18n_server:msgid().
%% the plural-form msgid
-type msgid_plural() :: binary().
%% binary()
-type translation() :: erli18n_server:translation().

-export_type([
    domain/0,
    locale/0,
    context/0,
    msgid/0,
    msgid_plural/0,
    translation/0
]).

%% =========================
%% Internal constants
%% =========================

%% Process-dictionary key for per-caller current locale. The leading
%% `$` prefix is a gettexter convention to make keys easy to spot when
%% inspecting a process state via `erlang:process_info(_, dictionary)`.
-define(LOCALE_KEY, '$erli18n_locale').

%% Application env defaults. `?GETTEXT_DOMAIN` comes from
%% include/erli18n.hrl (= `default`), aligned with the xgettext keyword
%% convention so marker macros and runtime stay in sync.
-define(DEFAULT_LOCALE, <<"en">>).
-define(DEFAULT_DOMAIN, ?GETTEXT_DOMAIN).

%% =========================
%% Singular lookup — gettext family
%% =========================

%% R6: gettext(Msgid) → gettext(textdomain(), Msgid, resolved_locale()).
-doc """
Traduz `Msgid` no domínio default (`textdomain/0`) e no locale resolvido
(locale por processo via `which_locale/0`, ou `default_locale/0` quando não
houver). Retorna a tradução; em caso de miss ou tradução vazia, retorna o
próprio `Msgid` como fallback.
""".
-spec gettext(msgid()) -> translation().
gettext(Msgid) when is_binary(Msgid) ->
    gettext(textdomain(), Msgid, resolved_locale()).

%% gettext/2 with explicit domain. Locale comes from process dict or
%% application default. Maps to the C macro `dgettext(domain, msgid)`.
-doc """
Traduz `Msgid` no domínio `Domain` (explícito) e no locale resolvido. Mapeia
a macro C `dgettext(domain, msgid)`. Em caso de miss ou tradução vazia,
retorna `Msgid`.
""".
-spec gettext(domain(), msgid()) -> translation().
gettext(Domain, Msgid) when is_atom(Domain), is_binary(Msgid) ->
    gettext(Domain, Msgid, resolved_locale()).

%% gettext/3: domain + msgid + explicit locale. Maps to the C macro
%% `dcgettext(domain, msgid, LC_MESSAGES)` (the category argument is
%% always LC_MESSAGES for erli18n — we do not model LC_NUMERIC etc.).
%%
%% R1 (BR-MIGRAR-001, PSD-003):
%%   - If lookup returns {ok, T} with T =/= <<>>, return T.
%%   - Else (miss OR empty translation), fall back to msgid.
%% PSD-003 makes the empty-translation case explicit: `msgstr ""` in a
%% .po file means "untranslated"; the parser is supposed to drop such
%% rows, but we keep the runtime guard for defence-in-depth — an empty
%% binary on the wire should never reach the UI.
-doc """
Forma principal da família singular: traduz `Msgid` no domínio `Domain` e no
locale `Locale` explícitos (sem contexto/`msgctxt`). Mapeia a macro C
`dcgettext(domain, msgid, LC_MESSAGES)`.

Fallback (R1): se o lookup devolve `{ok, T}` com `T` não vazio, retorna `T`;
caso contrário (miss ou tradução vazia — `msgstr ""` significa "não
traduzido"), retorna `Msgid`. Emite telemetria de lookup miss quando a
observabilidade está habilitada.
""".
-spec gettext(domain(), msgid(), locale()) -> translation().
gettext(Domain, Msgid, Locale) when
    is_atom(Domain), is_binary(Msgid), is_binary(Locale)
->
    case erli18n_server:lookup_singular(Domain, Locale, undefined, Msgid) of
        {ok, T} when T =/= <<>> -> T;
        _Other ->
            emit_lookup_miss(gettext, Domain, Locale, undefined, Msgid),
            Msgid
    end.

%% dgettext/2,3 — GNU C-macro names. Aliases for gettext/2,3.
-doc "Alias de `gettext/2` (nome da macro C `dgettext`).".
-spec dgettext(domain(), msgid()) -> translation().
dgettext(Domain, Msgid) -> gettext(Domain, Msgid).

-doc "Alias de `gettext/3` (nome da macro C `dgettext`).".
-spec dgettext(domain(), msgid(), locale()) -> translation().
dgettext(Domain, Msgid, Locale) -> gettext(Domain, Msgid, Locale).

%% dcgettext/3 — GNU C-macro name with explicit category. The category
%% in C is `int LC_MESSAGES`; in `erli18n` it is always implicitly
%% LC_MESSAGES and is therefore not modeled as a parameter. Alias to
%% gettext/3 for source-level compatibility with GNU naming.
-doc """
Alias de `gettext/3` (nome da macro C `dcgettext`). A categoria do C
(LC_MESSAGES) é sempre implícita em `erli18n` e não é um parâmetro.
""".
-spec dcgettext(domain(), msgid(), locale()) -> translation().
dcgettext(Domain, Msgid, Locale) -> gettext(Domain, Msgid, Locale).

%% =========================
%% Plural lookup — ngettext family
%% =========================

%% R2 (BR-MIGRAR-002): N == 1 → msgid; else → msgid_plural. The
%% fallback runs whenever lookup returns `undefined` OR an empty
%% translation (PSD-003). The N parameter is an arbitrary integer
%% (including bignum and negatives); `erli18n_plural:evaluate/2` is
%% bignum-clean.
-doc """
Traduz a forma plural correta para `N` no domínio default (`textdomain/0`) e
no locale resolvido. `Msgid` é a forma singular (`msgid`) e `MsgidPlural` a
forma plural (`msgid_plural`); `N` é a quantidade (inteiro arbitrário,
incluindo negativos e bignums).

Fallback (R2): em miss ou tradução vazia, retorna `Msgid` quando `N == 1` e
`MsgidPlural` caso contrário (convenção C). A seleção da forma plural usa a
regra `Plural-Forms` do header do `.po` carregado; a avaliação é total
(clamp), nunca derruba o chamador.
""".
-spec ngettext(msgid(), msgid_plural(), integer()) -> translation().
ngettext(Msgid, MsgidPlural, N) when
    is_binary(Msgid), is_binary(MsgidPlural), is_integer(N)
->
    ngettext(textdomain(), Msgid, MsgidPlural, N, resolved_locale()).

-doc """
Igual a `ngettext/3`, mas com o domínio `Domain` explícito. O locale é o
resolvido (`which_locale/0` ou `default_locale/0`). Mapeia a macro C
`dngettext(domain, msgid, msgid_plural, n)`.
""".
-spec ngettext(domain(), msgid(), msgid_plural(), integer()) -> translation().
ngettext(Domain, Msgid, MsgidPlural, N) when
    is_atom(Domain),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N)
->
    ngettext(Domain, Msgid, MsgidPlural, N, resolved_locale()).

-doc """
Forma principal da família plural: traduz a forma plural correta para `N` no
domínio `Domain` e no locale `Locale` explícitos. Mapeia a macro C
`dcngettext(domain, msgid, msgid_plural, n, LC_MESSAGES)`.

A forma plural é selecionada pela regra `Plural-Forms` do header do catálogo
carregado (avaliação total/clamp). Fallback (R2): em miss ou tradução vazia,
retorna `Msgid` para `N == 1` e `MsgidPlural` caso contrário. Emite telemetria
de lookup miss quando habilitada.
""".
-spec ngettext(domain(), msgid(), msgid_plural(), integer(), locale()) ->
    translation().
ngettext(Domain, Msgid, MsgidPlural, N, Locale) when
    is_atom(Domain),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N),
    is_binary(Locale)
->
    case
        erli18n_server:lookup_plural_form(
            Domain,
            Locale,
            undefined,
            Msgid,
            N
        )
    of
        {ok, T} when T =/= <<>> -> T;
        _Other ->
            emit_lookup_miss(ngettext, Domain, Locale, undefined, Msgid),
            plural_fallback(Msgid, MsgidPlural, N)
    end.

%% dngettext/4,5 — GNU C-macro names, aliases for ngettext/4,5.
-doc "Alias de `ngettext/4` (nome da macro C `dngettext`).".
-spec dngettext(domain(), msgid(), msgid_plural(), integer()) ->
    translation().
dngettext(Domain, Msgid, MsgidPlural, N) ->
    ngettext(Domain, Msgid, MsgidPlural, N).

-doc "Alias de `ngettext/5` (nome da macro C `dngettext`).".
-spec dngettext(domain(), msgid(), msgid_plural(), integer(), locale()) ->
    translation().
dngettext(Domain, Msgid, MsgidPlural, N, Locale) ->
    ngettext(Domain, Msgid, MsgidPlural, N, Locale).

%% dcngettext/5 — GNU C-macro name with explicit category. See dcgettext.
-doc """
Alias de `ngettext/5` (nome da macro C `dcngettext`). A categoria
(LC_MESSAGES) é sempre implícita e não é um parâmetro.
""".
-spec dcngettext(domain(), msgid(), msgid_plural(), integer(), locale()) ->
    translation().
dcngettext(Domain, Msgid, MsgidPlural, N, Locale) ->
    ngettext(Domain, Msgid, MsgidPlural, N, Locale).

%% =========================
%% Contextual singular — pgettext family
%% =========================

%% R3: lookup with explicit context. On miss OR empty, fall back to
%% msgid (no context-aware fallback — we do NOT retry with
%% Context=undefined; that would silently leak the wrong translation).
-doc """
Traduz `Msgid` desambiguado pelo `Context` (`msgctxt`) no domínio default e
no locale resolvido. `Context` é um binário (ou `undefined` para "sem
contexto"). Em miss ou tradução vazia, retorna `Msgid` (sem retry com
contexto diferente — não vaza tradução de outro contexto).
""".
-spec pgettext(context(), msgid()) -> translation().
pgettext(Context, Msgid) when
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid)
->
    pgettext(textdomain(), Context, Msgid, resolved_locale()).

-doc """
Igual a `pgettext/2`, mas com o domínio `Domain` explícito. O locale é o
resolvido. Mapeia a macro C `dpgettext(domain, msgctxt, msgid)`.
""".
-spec pgettext(domain(), context(), msgid()) -> translation().
pgettext(Domain, Context, Msgid) when
    is_atom(Domain),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid)
->
    pgettext(Domain, Context, Msgid, resolved_locale()).

-doc """
Forma principal da família contextual singular: traduz `Msgid` desambiguado
por `Context` (`msgctxt`) no domínio `Domain` e no locale `Locale`
explícitos. Mapeia a macro C `dcpgettext(domain, msgctxt, msgid,
LC_MESSAGES)`.

Fallback (R3): em miss ou tradução vazia, retorna `Msgid` (não há retry com
`Context = undefined`). Emite telemetria de lookup miss quando habilitada.
""".
-spec pgettext(domain(), context(), msgid(), locale()) -> translation().
pgettext(Domain, Context, Msgid, Locale) when
    is_atom(Domain),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(Locale)
->
    case erli18n_server:lookup_singular(Domain, Locale, Context, Msgid) of
        {ok, T} when T =/= <<>> -> T;
        _Other ->
            emit_lookup_miss(pgettext, Domain, Locale, Context, Msgid),
            Msgid
    end.

%% dpgettext/3,4 — GNU C-macro names, aliases for pgettext/3,4.
-doc "Alias de `pgettext/3` (nome da macro C `dpgettext`).".
-spec dpgettext(domain(), context(), msgid()) -> translation().
dpgettext(Domain, Context, Msgid) ->
    pgettext(Domain, Context, Msgid).

-doc "Alias de `pgettext/4` (nome da macro C `dpgettext`).".
-spec dpgettext(domain(), context(), msgid(), locale()) -> translation().
dpgettext(Domain, Context, Msgid, Locale) ->
    pgettext(Domain, Context, Msgid, Locale).

%% dcpgettext/4 — GNU C-macro name with explicit category. See dcgettext.
-doc """
Alias de `pgettext/4` (nome da macro C `dcpgettext`). A categoria
(LC_MESSAGES) é sempre implícita e não é um parâmetro.
""".
-spec dcpgettext(domain(), context(), msgid(), locale()) -> translation().
dcpgettext(Domain, Context, Msgid, Locale) ->
    pgettext(Domain, Context, Msgid, Locale).

%% =========================
%% Contextual plural — npgettext family
%% =========================

%% R4: contextual + plural. Fallback follows R2 on the msgid /
%% msgid_plural pair when the lookup misses or returns empty.
-doc """
Traduz a forma plural correta para `N`, desambiguada por `Context`
(`msgctxt`), no domínio default e no locale resolvido. `Msgid`/`MsgidPlural`
são as formas singular/plural; `Context` é um binário (ou `undefined`); `N` é
a quantidade.

Fallback: em miss ou tradução vazia, aplica R2 ao par msgid/msgid_plural
(`Msgid` se `N == 1`, senão `MsgidPlural`).
""".
-spec npgettext(context(), msgid(), msgid_plural(), integer()) ->
    translation().
npgettext(Context, Msgid, MsgidPlural, N) when
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N)
->
    npgettext(
        textdomain(),
        Context,
        Msgid,
        MsgidPlural,
        N,
        resolved_locale()
    ).

-doc """
Igual a `npgettext/4`, mas com o domínio `Domain` explícito. O locale é o
resolvido. Mapeia a macro C `dnpgettext(domain, msgctxt, msgid, msgid_plural,
n)`.
""".
-spec npgettext(
    domain(),
    context(),
    msgid(),
    msgid_plural(),
    integer()
) -> translation().
npgettext(Domain, Context, Msgid, MsgidPlural, N) when
    is_atom(Domain),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N)
->
    npgettext(Domain, Context, Msgid, MsgidPlural, N, resolved_locale()).

-doc """
Forma principal da família contextual plural: traduz a forma plural correta
para `N`, desambiguada por `Context` (`msgctxt`), no domínio `Domain` e no
locale `Locale` explícitos. Mapeia a macro C `dcnpgettext(domain, msgctxt,
msgid, msgid_plural, n, LC_MESSAGES)`.

A forma plural vem da regra `Plural-Forms` do header carregado (avaliação
total/clamp). Fallback: em miss ou tradução vazia, aplica R2 ao par
msgid/msgid_plural. Emite telemetria de lookup miss quando habilitada.
""".
-spec npgettext(
    domain(),
    context(),
    msgid(),
    msgid_plural(),
    integer(),
    locale()
) -> translation().
npgettext(Domain, Context, Msgid, MsgidPlural, N, Locale) when
    is_atom(Domain),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N),
    is_binary(Locale)
->
    case
        erli18n_server:lookup_plural_form(
            Domain,
            Locale,
            Context,
            Msgid,
            N
        )
    of
        {ok, T} when T =/= <<>> -> T;
        _Other ->
            emit_lookup_miss(npgettext, Domain, Locale, Context, Msgid),
            plural_fallback(Msgid, MsgidPlural, N)
    end.

%% dnpgettext/5,6 — GNU C-macro names, aliases for npgettext/5,6.
-doc "Alias de `npgettext/5` (nome da macro C `dnpgettext`).".
-spec dnpgettext(
    domain(),
    context(),
    msgid(),
    msgid_plural(),
    integer()
) -> translation().
dnpgettext(Domain, Context, Msgid, MsgidPlural, N) ->
    npgettext(Domain, Context, Msgid, MsgidPlural, N).

-doc "Alias de `npgettext/6` (nome da macro C `dnpgettext`).".
-spec dnpgettext(
    domain(),
    context(),
    msgid(),
    msgid_plural(),
    integer(),
    locale()
) -> translation().
dnpgettext(Domain, Context, Msgid, MsgidPlural, N, Locale) ->
    npgettext(Domain, Context, Msgid, MsgidPlural, N, Locale).

%% dcnpgettext/6 — GNU C-macro name with explicit category. See dcgettext.
-doc """
Alias de `npgettext/6` (nome da macro C `dcnpgettext`). A categoria
(LC_MESSAGES) é sempre implícita e não é um parâmetro.
""".
-spec dcnpgettext(
    domain(),
    context(),
    msgid(),
    msgid_plural(),
    integer(),
    locale()
) -> translation().
dcnpgettext(Domain, Context, Msgid, MsgidPlural, N, Locale) ->
    npgettext(Domain, Context, Msgid, MsgidPlural, N, Locale).

%% =========================
%% Per-process locale state (process dictionary)
%% =========================
%%
%% Per BR-MIGRAR-003 / ADR-0002, the current locale is per-caller state
%% stored in the process dictionary. This mirrors thread-local storage
%% in libc gettext (`uselocale(3)`) and is the idiomatic BEAM choice for
%% "request-scoped" runtime state. Crucially, the dictionary is NOT
%% inherited across `spawn/1`; each new process starts with
%% `which_locale() = undefined` and falls back to default_locale/0.

-doc """
Retorna o locale corrente do processo chamador (definido por `setlocale/1`),
ou `undefined` se nenhum foi definido. O estado é por processo (dicionário de
processo) e NÃO é herdado em `spawn/1`. Crasha com
`{invalid_process_locale, _}` se a chave privada do dicionário tiver sido
sobrescrita por terceiros com um valor não binário.
""".
-spec which_locale() -> locale() | undefined.
which_locale() ->
    %% Process dictionary returns term(); narrow to the documented contract.
    %% `setlocale/1` is guarded with `is_binary(Locale)`, so the only values
    %% ever written under this key are binaries. Any other shape would mean
    %% another module is writing under our private `$erli18n_locale` key,
    %% which is a contract violation that should crash visibly.
    case erlang:get(?LOCALE_KEY) of
        undefined -> undefined;
        Locale when is_binary(Locale) -> Locale;
        Other -> error({invalid_process_locale, {?LOCALE_KEY, Other, expected, binary}})
    end.

-doc """
Define o locale corrente do processo chamador como `Locale` (binário),
afetando todas as buscas subsequentes neste processo que usem o locale
resolvido. Escopo: apenas o processo atual (não herdado por processos
filhos). Retorna `ok`.
""".
-spec setlocale(locale()) -> ok.
setlocale(Locale) when is_binary(Locale) ->
    _ = erlang:put(?LOCALE_KEY, Locale),
    ok.

%% =========================
%% Application-wide defaults
%% =========================
%%
%% Default locale and default domain are application env values, not
%% per-process. They provide the fallback when `which_locale/0` is
%% `undefined` (i.e. the caller has not opted into per-process locale)
%% and the starting domain for the no-domain gettext/1, ngettext/3 etc.

-doc """
Retorna o locale default da aplicação (env `erli18n.default_locale`, padrão
`<<"en">>`). É o fallback usado quando `which_locale/0` é `undefined`. Crasha
com `{invalid_config, _}` se o valor configurado não for um binário.
""".
-spec default_locale() -> locale().
default_locale() ->
    %% `application:get_env/3` returns `term()`; narrow at the boundary so
    %% the public contract (`locale() = binary()`) is enforced. A misconfig
    %% becomes an explicit crash with a descriptive payload instead of a
    %% silent surprise downstream (e.g. an atom default leaking into a
    %% binary-only `gettext/3`).
    case application:get_env(erli18n, default_locale, ?DEFAULT_LOCALE) of
        Locale when is_binary(Locale) -> Locale;
        Other -> error({invalid_config, {erli18n, default_locale, Other, expected, binary}})
    end.

-doc """
Define o locale default da aplicação (env `erli18n.default_locale`) como
`Locale` (binário). Afeta todos os processos que dependem do fallback de
locale. Retorna `ok`.
""".
-spec set_default_locale(locale()) -> ok.
set_default_locale(Locale) when is_binary(Locale) ->
    application:set_env(erli18n, default_locale, Locale).

-doc """
Retorna o domínio default da aplicação (env `erli18n.default_domain`, padrão
`?GETTEXT_DOMAIN` = `default`). É o domínio usado pelas variantes sem domínio
explícito (`gettext/1`, `ngettext/3`, etc.). Crasha com `{invalid_config, _}`
se o valor configurado não for um átomo.
""".
-spec textdomain() -> domain().
textdomain() ->
    %% Same narrowing pattern as `default_locale/0`. `domain()` is `atom()`;
    %% misconfig (e.g. a binary leaking into the env) crashes explicitly.
    case application:get_env(erli18n, default_domain, ?DEFAULT_DOMAIN) of
        Domain when is_atom(Domain) -> Domain;
        Other -> error({invalid_config, {erli18n, default_domain, Other, expected, atom}})
    end.

-doc """
Define o domínio default da aplicação (env `erli18n.default_domain`) como
`Domain` (átomo). Equivalente à função `textdomain(3)` do gettext C. Retorna
`ok`.
""".
-spec textdomain(domain()) -> ok.
textdomain(Domain) when is_atom(Domain) ->
    application:set_env(erli18n, default_domain, Domain).

%% =========================
%% Load orchestration passthrough
%% =========================
%%
%% Thin delegation to `erli18n_server`. The façade is the single
%% documented entry point so existing consumers don't have to learn
%% about the server module.

-doc """
Carrega o catálogo `.po` em `PoPath` para o par `(Domain, Locale)`, de forma
idempotente: se já houver um catálogo carregado, retorna `{ok, already}` sem
reler o disco. O carregamento é atômico (parse, compile de plural e validação
CLDR acontecem antes de qualquer inserção em ETS; um erro deixa o estado
intacto). Retorna `{ok, NumEntries}` no primeiro carregamento, `{ok, already}`
se já presente, ou `{error, Reason}` em falha de arquivo/parse/compile.
Delega a `erli18n_server:ensure_loaded/3`.
""".
-spec ensure_loaded(domain(), locale(), file:filename()) ->
    erli18n_server:ensure_result().
ensure_loaded(Domain, Locale, PoPath) ->
    erli18n_server:ensure_loaded(Domain, Locale, PoPath).

-doc """
Igual a `ensure_loaded/3`, com `Opts` controlando o carregamento. Campos
suportados: `include_fuzzy` (incluir entradas fuzzy), `max_bytes` (recusa o
arquivo, via stat, antes de lê-lo se exceder o limite), `max_entries` (recusa
o catálogo após o parse se tiver mais entradas que o limite) e `timeout` (do
commit). Bounds estourados retornam `{error, {input_too_large, _, _}}` ou
`{error, {too_many_entries, _, _}}`. Delega a
`erli18n_server:ensure_loaded/4`.
""".
-spec ensure_loaded(
    domain(),
    locale(),
    file:filename(),
    erli18n_server:opts()
) ->
    erli18n_server:ensure_result().
ensure_loaded(Domain, Locale, PoPath, Opts) ->
    erli18n_server:ensure_loaded(Domain, Locale, PoPath, Opts).

-doc """
Recarrega (atomicamente) o catálogo de `(Domain, Locale)` a partir de
`PoPath`, mesmo que já esteja carregado. A operação é atômica e sem janela
vazia: o pipeline falível (read/parse/compile) roda sem tocar o ETS e a troca
é um swap atômico (insert-before-prune). Em erro, o catálogo anterior
permanece intacto. Retorna `{ok, NumEntries}` no sucesso ou `{error, Reason}`.
Delega a `erli18n_server:reload/3`.
""".
-spec reload(domain(), locale(), file:filename()) ->
    erli18n_server:ensure_result().
reload(Domain, Locale, PoPath) ->
    erli18n_server:reload(Domain, Locale, PoPath).

-doc """
Igual a `reload/3`, com `Opts` (mesmos campos de `ensure_loaded/4`:
`include_fuzzy`, `max_bytes`, `max_entries`, `timeout`). Mantém a recarga
atômica e o catálogo anterior intacto em caso de erro. Delega a
`erli18n_server:reload/4`.
""".
-spec reload(
    domain(),
    locale(),
    file:filename(),
    erli18n_server:opts()
) ->
    erli18n_server:ensure_result().
reload(Domain, Locale, PoPath, Opts) ->
    erli18n_server:reload(Domain, Locale, PoPath, Opts).

-doc """
Remove da memória o catálogo de `(Domain, Locale)`. Após o unload, as buscas
voltam a cair no fallback (msgid/msgid_plural). É idempotente: descarregar um
catálogo inexistente também retorna `ok`. Delega a
`erli18n_server:unload/2`.
""".
-spec unload(domain(), locale()) -> ok.
unload(Domain, Locale) ->
    erli18n_server:unload(Domain, Locale).

%% Convention-based path resolver: <PrivDir>/locale/<Locale>/LC_MESSAGES/<Domain>.po.
%% See BR-MIGRAR-005 / ADR-0003 (multi-tenant filesystem layout).
-doc """
Resolve o caminho convencional do `.po` para a aplicação `App`: monta
`<PrivDir>/locale/<Locale>/LC_MESSAGES/<Domain>.po` (`PrivDir` é o diretório
`priv/` de `App`). Conveniência para alimentar `ensure_loaded/3,4` e
`reload/3,4` sem montar o caminho manualmente. Delega a
`erli18n_server:default_po_path/3`.
""".
-spec default_po_path(atom(), domain(), locale()) -> file:filename().
default_po_path(App, Domain, Locale) ->
    erli18n_server:default_po_path(App, Domain, Locale).

%% =========================
%% Observability passthrough
%% =========================

-doc """
Retorna um mapa com informações de uso de memória dos catálogos carregados
(p.ex. número de objetos e palavras/bytes consumidos pela tabela ETS). Útil
para observabilidade e diagnóstico. Delega a `erli18n_server:memory_info/0`.
""".
-spec memory_info() -> map().
memory_info() ->
    erli18n_server:memory_info().

-doc """
Lista os catálogos atualmente carregados como tuplas
`{Domain, Locale, NumEntries}` (uma por par domínio/locale). Delega a
`erli18n_server:loaded_catalogs/0`.
""".
-spec loaded_catalogs() ->
    [{domain(), locale(), non_neg_integer()}].
loaded_catalogs() ->
    erli18n_server:loaded_catalogs().

-doc """
Lista as chaves (entradas) do catálogo de `(Domain, Locale)` como tuplas
`{singular, Context, Msgid}` ou `{plural, Context, Msgid}`, onde `Context` é
`undefined` quando não há `msgctxt`. Útil para introspecção/testes. Retorna
lista vazia se o catálogo não estiver carregado. Delega a
`erli18n_server:which_keys/2`.
""".
-spec which_keys(domain(), locale()) ->
    [
        {singular, context(), msgid()}
        | {plural, context(), msgid()}
    ].
which_keys(Domain, Locale) ->
    erli18n_server:which_keys(Domain, Locale).

%% =========================
%% Internal helpers
%% =========================

%% R5: resolved_locale picks per-process locale if set, else falls back
%% to the application-wide default. Hot path: 1 process_info read
%% (~ns) + 1 application:get_env (cached in OTP application controller).
-spec resolved_locale() -> locale().
resolved_locale() ->
    case which_locale() of
        undefined -> default_locale();
        Locale -> Locale
    end.

%% R2 fallback (BR-MIGRAR-002). When no translation is available — the
%% catalog is not loaded, the entry is missing, or the entry exists but
%% the form selected for N is empty (PSD-003) — return the original C
%% convention: msgid for N == 1, msgid_plural otherwise. This matches
%% the GNU manual's "Translating plural forms" §"Plural forms".
-spec plural_fallback(msgid(), msgid_plural(), integer()) -> translation().
plural_fallback(Msgid, _MsgidPlural, 1) -> Msgid;
plural_fallback(_Msgid, MsgidPlural, _) -> MsgidPlural.

%% =========================
%% Telemetry — lookup miss
%% =========================
%%
%% Opt-in per observability.md §6 (overhead policy). The flag is
%% checked first so the fast path stays a single `application:get_env`
%% (ETS read, ~100ns). When the flag is OFF the function returns
%% immediately and no event is constructed.
%%
%% Schema per observability.md §4.2 (`[erli18n, lookup, miss]`):
%%   measurements: `#{count => 1}`
%%   metadata:     `#{domain, locale, msgid, function, context}`
%%
%% Note: the spec's metadata schema in §5 omits `context` for the
%% lookup_miss event, but the §4.2 prose explicitly includes it as the
%% last field. We honour the §4.2 prose (it's the catalogue, treated as
%% authoritative) and surface `context` so the consumer can distinguish
%% pgettext from gettext misses without inferring from the function
%% atom.
-spec emit_lookup_miss(atom(), domain(), locale(), context(), msgid()) ->
    ok.
emit_lookup_miss(Function, Domain, Locale, Context, Msgid) ->
    case erli18n_telemetry:lookup_telemetry_enabled() of
        false ->
            ok;
        true ->
            erli18n_telemetry:emit(
                erli18n_telemetry:event_lookup_miss(),
                #{count => 1},
                #{
                    domain => Domain,
                    locale => Locale,
                    msgid => Msgid,
                    function => Function,
                    context => Context
                }
            ),
            ok
    end.
