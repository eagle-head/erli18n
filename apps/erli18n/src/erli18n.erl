-module(erli18n).

-moduledoc """
Public façade (API) of the `erli18n` library — the single entry point for
anyone using the library in an application (GNU gettext family).

## What it is and what problem it solves

`erli18n` translates strings (`msgid`s) using `.po` catalogs compatible with
GNU gettext (Poedit, Crowdin, Transifex, Weblate, `xgettext`). This module
mirrors the C gettext macro family, mapping each macro to an eponymous function:

- Singular: `gettext/1,2,3` / `dgettext/2,3` (explicit domain) / `dcgettext/3`
  (category — always LC_MESSAGES).
- Plural: `ngettext/3,4,5` / `dngettext/4,5` / `dcngettext/5`.
- Contextual singular (`msgctxt`): `pgettext/2,3,4` / `dpgettext/3,4` /
  `dcpgettext/4`.
- Contextual plural: `npgettext/4,5,6` / `dnpgettext/5,6` / `dcnpgettext/6`.

Each family also has an interpolating `f`-suffix sibling that takes a
trailing `Bindings :: map()` and substitutes named `%{name}` placeholders
in the resolved translation: `gettextf`, `ngettextf`, `pgettextf`,
`npgettextf` (plus the `d`/`dc` aliases). The plural members auto-bind
`count => N`. Substitution is total and fail-soft — see `erli18n_interp`
for the grammar (`%{name}`, `%%`/`%%{name}` escaping), value coercion, the
`lenient`/`strict` missing-binding policy, the anti-DoS caps, and the
bidi/RTL caveat.

You almost never need to touch `erli18n_server` directly: this façade is the
documented door, and the load/observability functions here are thin
passthroughs to the server.

## Mental model

- **The current locale is PER-PROCESS state.** `setlocale/1` writes to the
  caller's process dictionary and `which_locale/0` reads it back. This state is
  **not inherited** by processes created with `spawn/1`: each new process starts
  with `which_locale() = undefined` and falls back to `default_locale/0`. It is
  the BEAM equivalent of libc's `uselocale(3)` (thread-local).
- **The default domain and locale are `application:env`** (node-global), not
  per-process state. They are the fallback when the caller has not opted into a
  per-process locale, and the starting point for the no-domain variants
  (`gettext/1`, `ngettext/3`, ...). See `default_locale/0`,
  `set_default_locale/1`, `textdomain/0`, `textdomain/1`.
- **The resolved locale** of each lookup is `which_locale/0` if set, otherwise
  `default_locale/0` (internal function `resolved_locale/0`).
- **Reads are lock-free.** The `erli18n_server` `lookup_*` functions read
  directly from `persistent_term` in the caller's own process (copy-free); only
  writes (load/reload) go through the writer `gen_server`. There is no process
  bottleneck on the read path.
- **The category is always LC_MESSAGES.** The `d*`/`dc*` variants exist solely
  for NAME parity with C gettext; the category is never a parameter.
- **Graceful degradation.** On a miss (missing catalog, nonexistent entry) or an
  empty translation (`msgstr ""`), the lookup returns the original `msgid` (or
  `msgid_plural` in the plural form, according to `N`). A crash of
  `erli18n_server` (the writer) does **not** empty the catalogs: they live in
  `persistent_term`, which is node-global and owned by the runtime, so they
  survive a writer crash with no heir machinery — on restart the writer only
  re-derives its observability view and lookups keep serving the loaded
  translations (see `erli18n_server` and `erli18n_pt_store`).
- **Plural evaluation is total (anti-DoS).** The `Plural-Forms` rule from the
  `.po` header is the source of truth at runtime. Evaluation clamps
  (libintl-style: out-of-range form → 0, zero divisor → 0) and large ASTs are
  rejected at load time. The error reaches the caller of this façade
  **enveloped** in `{plural_compile_error, _}` (part of
  `erli18n_server:ensure_error()`), with the internal detail coming from
  `erli18n_plural:compile_error()` — that is, an AST that is too large appears as
  `{error, {plural_compile_error, {expr_too_complex, _,
  _}}}` in the return of `ensure_loaded/3,4` and `reload/3,4`. Thus a
  pathological rule neither brings down the request process nor stalls the hot
  path.

## When you touch this module

1. At app boot: `application:ensure_all_started(erli18n)` and load the
   catalogs with `ensure_loaded/3,4` (use `default_po_path/3` to assemble the
   conventional path).
2. Per request: optionally `setlocale/1` in the process serving the
   request.
3. In UI code: call `gettext/1`, `ngettext/3`, `pgettext/2`, etc.

## Quickstart

```erlang
1> application:ensure_all_started(erli18n).
{ok, [erli18n]}
2> PoPath = erli18n:default_po_path(my_app, my_domain, <<"fr">>).
"/.../my_app/priv/locale/fr/LC_MESSAGES/my_domain.po"
3> {ok, N} = erli18n:ensure_loaded(my_domain, <<"fr">>, PoPath).
{ok, 12}
%% N = 12 (entries loaded). Re-running this step would return
%% {ok, already} (idempotent), not an integer — see `ensure_loaded/3`.
4> erli18n:setlocale(<<"fr">>).
ok
5> erli18n:gettext(my_domain, <<"Hello, world">>).
<<"Bonjour, monde">>
6> erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42).
<<"42 fichiers">>
7> erli18n:pgettext(my_domain, <<"month">>, <<"May">>).
<<"Mai">>
8> erli18n:gettextf(my_domain, <<"Hello, %{name}">>, #{name => <<"Ada">>}).
<<"Bonjour, Ada">>
9> erli18n:ngettextf(my_domain, <<"%{count} file">>, <<"%{count} files">>, 3, #{}).
<<"3 fichiers">>
```

## Key functions

- Lookup: `gettext/3`, `ngettext/5`, `pgettext/4`, `npgettext/6` (the main
  forms; the other arities resolve domain/locale and delegate to these).
- Interpolating lookup: `gettextf/2,3,4`, `ngettextf/4,5,6`,
  `pgettextf/3,4,5`, `npgettextf/5,6,7` — resolve as above, then substitute
  `%{name}` placeholders (`erli18n_interp`).
- Locale state: `setlocale/1`, `which_locale/0`.
- App defaults: `default_locale/0`, `textdomain/0`.
- Catalog lifecycle: `ensure_loaded/3`, `reload/3`, `unload/2`,
  `default_po_path/3`.
- Observability: `loaded_catalogs/0`, `loaded_locales/0`, `memory_info/0`,
  `which_keys/2`.
- Locale negotiation & fallback (Phase 2, opt-in): `negotiate/2`,
  `parse_accept_language/1`, `canonicalize_locale/1`, `set_locale_fallback/1`
  (and the `locale_fallback` app env). See `erli18n_negotiate`.

## Lookup rules (R1-R6)

This module's internal comments label the lookup behavior with `R1`-`R6`
(coming from `BR-MIGRAR-001/002` and `PSD-003`). What each one means, for anyone
who has never seen the project:

- `R1` — singular: `gettext`/`dgettext`/`dcgettext` family.
- `R2` — plural: `ngettext`/`dngettext`/`dcngettext` family, including the
  plural fallback (`Msgid` if `N == 1`, otherwise `MsgidPlural`).
- `R3` — contextual singular (`msgctxt`):
  `pgettext`/`dpgettext`/`dcpgettext` family.
- `R4` — contextual plural: `npgettext`/`dnpgettext`/`dcnpgettext` family.
- `R5` — locale resolution: uses `which_locale/0` if the process set one via
  `setlocale/1`, otherwise `default_locale/0` (see internal helper
  `resolved_locale/0`).
- `R6` — default domain resolution: the no-domain variants (`gettext/1`,
  `ngettext/3`, ...) use `textdomain/0` as the domain.
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

%% Interpolating `f`-suffix family (Phase 1 — named `%{name}`
%% interpolation). Each member delegates to its non-`f` sibling above to
%% resolve the string, then runs `erli18n_interp:format/2` over it with a
%% trailing `Bindings :: map()`. The plural members auto-bind `count => N`
%% (caller override wins). The category is always LC_MESSAGES.

%% Singular `f` — gettextf/dgettextf/dcgettextf.
-export([
    gettextf/2, gettextf/3, gettextf/4,
    dgettextf/3, dgettextf/4,
    dcgettextf/4
]).

%% Plural `f` — ngettextf/dngettextf/dcngettextf.
-export([
    ngettextf/4, ngettextf/5, ngettextf/6,
    dngettextf/5, dngettextf/6,
    dcngettextf/6
]).

%% Contextual singular `f` — pgettextf/dpgettextf/dcpgettextf.
-export([
    pgettextf/3, pgettextf/4, pgettextf/5,
    dpgettextf/4, dpgettextf/5,
    dcpgettextf/5
]).

%% Contextual plural `f` — npgettextf/dnpgettextf/dcnpgettextf.
-export([
    npgettextf/5, npgettextf/6, npgettextf/7,
    dnpgettextf/6, dnpgettextf/7,
    dcnpgettextf/7
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
    loaded_locales/0,
    which_keys/2
]).

%% Locale negotiation & fallback (Phase 2). Opt-in BCP-47 canonicalization,
%% fallback chain, and Accept-Language negotiation; thin facade over
%% `erli18n_negotiate`. The fallback chain itself is wired into the four
%% lookup families' miss arms and gated by the `locale_fallback` app env.
-export([
    negotiate/2,
    parse_accept_language/1,
    canonicalize_locale/1,
    set_locale_fallback/1
]).

%% =========================
%% Types (re-exported / aliases)
%% =========================

-doc """
Translation domain (`atom()`). Partitions the `msgid` space — each pair
`(Domain, Locale)` is an independent `.po` catalog. The default domain comes
from `textdomain/0`.
""".
-type domain() :: erli18n_server:domain().
-doc """
BCP-47 locale as a binary (`binary()`), e.g. `<<"en">>`, `<<"pt_BR">>`. It is
the catalog key and the basis of plural-form selection.
""".
-type locale() :: erli18n_server:locale().
-doc """
`msgctxt` context (`undefined | binary()`) that disambiguates homographs (e.g.
the same `msgid` "May" as a month vs. a verb). `undefined` means "no context".
""".
-type context() :: erli18n_server:context().
-doc """
Translation source key (`binary()`): the text in the source language, exactly
as extracted by `xgettext`. It is also the fallback value when there is no
translation.
""".
-type msgid() :: erli18n_server:msgid().
-doc """
Plural form of the source key (`binary()`): the `.po` `msgid_plural`. Used as
the fallback when `N /= 1` and there is no translation.
""".
-type msgid_plural() :: binary().
-doc """
Translated text returned to the caller (`binary()`). On a miss or an empty
translation, it is the `msgid` itself (or `msgid_plural`), never `undefined`.
""".
-type translation() :: erli18n_server:translation().
-doc """
Map of `%{name}` interpolation bindings for the `f`-suffix family
(`gettextf`, `ngettextf`, `pgettextf`, `npgettextf` and their `d`/`dc`
aliases). Keys are atoms (the placeholder names) and values are coerced
to UTF-8 text totally by `erli18n_interp:format/2`. The plural members
auto-bind `count => N` (a caller-supplied `count` wins). See
`erli18n_interp` for the full grammar, value coercion, and anti-DoS caps.
""".
-type bindings() :: erli18n_interp:bindings().

-export_type([
    domain/0,
    locale/0,
    context/0,
    msgid/0,
    msgid_plural/0,
    translation/0,
    bindings/0
]).

%% =========================
%% Internal constants
%% =========================

%% Process-dictionary key for per-caller current locale. The leading
%% `$` prefix is a gettexter convention to make keys easy to spot when
%% inspecting a process state via `erlang:process_info(_, dictionary)`.
-define(LOCALE_KEY, '$erli18n_locale').

%% Application env defaults. The default domain is `default`, aligned with the
%% xgettext keyword convention so marker macros and runtime stay in sync.
-define(DEFAULT_LOCALE, <<"en">>).
-define(DEFAULT_DOMAIN, default).

%% =========================
%% Singular lookup — gettext family
%% =========================

%% R6: gettext(Msgid) → gettext(textdomain(), Msgid, resolved_locale()).
-doc """
Translates `Msgid` in the default domain and the resolved locale — the most
common form in UI code.

- `Msgid` — key in the source language, exactly as `xgettext` extracted it.

The domain is `textdomain/0` and the locale is the resolved one: `which_locale/0`
if the process set one via `setlocale/1`, otherwise `default_locale/0`. On a miss
(catalog not loaded or nonexistent entry) or an empty translation (`msgstr ""`),
it returns `Msgid` itself.

```erlang
1> erli18n:setlocale(<<"pt_BR">>).
ok
2> erli18n:gettext(<<"Hello">>).
<<"Olá">>
3> erli18n:gettext(<<"No registered translation">>).
<<"No registered translation">>
```

Crashes (`function_clause`) if `Msgid` is not a binary. For an explicit domain use
`gettext/2`; for an explicit locale, `gettext/3`.
""".
-spec gettext(msgid()) -> translation().
gettext(Msgid) when is_binary(Msgid) ->
    gettext(textdomain(), Msgid, resolved_locale()).

%% gettext/2 with explicit domain. Locale comes from process dict or
%% application default. Maps to the C macro `dgettext(domain, msgid)`.
-doc """
Translates `Msgid` in an explicit domain `Domain`, in the resolved locale. Maps
the C macro `dgettext(domain, msgid)`.

- `Domain` — domain/catalog to look in (not `textdomain/0`).
- `Msgid` — key in the source language.

The locale is the resolved one (`which_locale/0` or `default_locale/0`). On a
miss or an empty translation, it returns `Msgid`.

```erlang
1> erli18n:setlocale(<<"pt_BR">>).
ok
2> erli18n:gettext(errors, <<"Not found">>).
<<"Não encontrado">>
```

Crashes (`function_clause`) if `Domain` is not an atom or `Msgid` is not a binary.
See `gettext/3` (explicit locale) and `dgettext/2` (alias).
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
Main form of the singular family: translates `Msgid` in the domain `Domain` and
the locale `Locale`, both explicit (no context/`msgctxt`). All other singular
arities resolve domain/locale and delegate here. Maps the C macro
`dcgettext(domain, msgid, LC_MESSAGES)`.

- `Domain` — domain/catalog to look in.
- `Msgid` — key in the source language.
- `Locale` — exact locale (does not go through `which_locale/0`).

Return semantics (R1): if `erli18n_server:lookup_singular/4` returns
`{ok, T}` with `T` non-empty, it returns `T`; otherwise — miss OR an empty
translation (`msgstr ""` is "untranslated"; the empty-binary guard is
defence-in-depth) — it returns `Msgid`. On that miss path, it emits the
telemetry event `[erli18n, lookup, miss]` when observability is enabled
(see internal function `emit_lookup_miss/5`).

```erlang
1> erli18n:gettext(my_domain, <<"Save">>, <<"de">>).
<<"Speichern">>
2> erli18n:gettext(my_domain, <<"Save">>, <<"nonexistent_locale">>).
<<"Save">>
```

Crashes (`function_clause`) if any argument violates the type. See `pgettext/4`
(contextual variant) and the aliases `dgettext/3` / `dcgettext/3`.
""".
-spec gettext(domain(), msgid(), locale()) -> translation().
gettext(Domain, Msgid, Locale) when
    is_atom(Domain), is_binary(Msgid), is_binary(Locale)
->
    case erli18n_server:lookup_singular(Domain, Locale, undefined, Msgid) of
        {ok, T} when T =/= <<>> -> T;
        _Other ->
            %% Exact miss. Try the opt-in fallback chain (no-op when
            %% `locale_fallback = off`); only then record the miss + msgid.
            case fallback_lookup_singular(gettext, Domain, undefined, Msgid, Locale) of
                {ok, T2} ->
                    T2;
                miss ->
                    emit_lookup_miss(gettext, Domain, Locale, undefined, Msgid),
                    Msgid
            end
    end.

%% dgettext/2,3 — GNU C-macro names. Aliases for gettext/2,3.
-doc """
Alias of `gettext/2` (C macro name `dgettext`). Same semantics and fallback;
it exists solely for name parity with C gettext.

```erlang
1> erli18n:dgettext(my_domain, <<"Hello">>) =:= erli18n:gettext(my_domain, <<"Hello">>).
true
```
""".
-spec dgettext(domain(), msgid()) -> translation().
dgettext(Domain, Msgid) -> gettext(Domain, Msgid).

-doc """
Alias of `gettext/3` (C macro name `dgettext`). Same semantics and fallback.

```erlang
1> erli18n:dgettext(my_domain, <<"Hello">>, <<"de">>).
<<"Hallo">>
```
""".
-spec dgettext(domain(), msgid(), locale()) -> translation().
dgettext(Domain, Msgid, Locale) -> gettext(Domain, Msgid, Locale).

%% dcgettext/3 — GNU C-macro name with explicit category. The category
%% in C is `int LC_MESSAGES`; in `erli18n` it is always implicitly
%% LC_MESSAGES and is therefore not modeled as a parameter. Alias to
%% gettext/3 for source-level compatibility with GNU naming.
-doc """
Alias of `gettext/3` (C macro name `dcgettext`). The C category
(LC_MESSAGES) is always implicit in `erli18n` and is therefore not a parameter —
there is no `LC_NUMERIC`, `LC_TIME`, etc. Same semantics and fallback as
`gettext/3`.

```erlang
1> erli18n:dcgettext(my_domain, <<"Hello">>, <<"de">>).
<<"Hallo">>
```
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
Translates the correct plural form for `N` in the default domain and the
resolved locale.

- `Msgid` — singular form (`msgid`), also the fallback when `N == 1`.
- `MsgidPlural` — plural form (`msgid_plural`), the fallback when `N /= 1`.
- `N` — count. Arbitrary integer: negatives and bignums are accepted (evaluation
  is bignum-clean).

The plural form is chosen by the `Plural-Forms` rule from the loaded `.po` header
(not by the count of forms in the code). Evaluation is total: it clamps à la
libintl (out-of-range form → 0, zero divisor → 0) and never brings down the
caller; pathological rules are already rejected at load time. Fallback (R2): on a
miss or an empty translation, it returns `Msgid` if `N == 1`, otherwise
`MsgidPlural`.

```erlang
1> erli18n:setlocale(<<"en">>).
ok
2> erli18n:ngettext(<<"file">>, <<"files">>, 1).
<<"file">>
3> erli18n:ngettext(<<"file">>, <<"files">>, 3).
<<"files">>
```

Crashes (`function_clause`) if `Msgid`/`MsgidPlural` are not binaries or `N` is
not an integer. See `ngettext/4` (domain) and `ngettext/5` (locale).
""".
-spec ngettext(msgid(), msgid_plural(), integer()) -> translation().
ngettext(Msgid, MsgidPlural, N) when
    is_binary(Msgid), is_binary(MsgidPlural), is_integer(N)
->
    ngettext(textdomain(), Msgid, MsgidPlural, N, resolved_locale()).

-doc """
Same as `ngettext/3`, but with the domain `Domain` explicit; the locale is the
resolved one (`which_locale/0` or `default_locale/0`). Maps the C macro
`dngettext(domain, msgid, msgid_plural, n)`.

```erlang
1> erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42).
<<"42 fichiers">>
```

Same plural-form selection, fallback (R2), and crash modes as `ngettext/3`.
See `ngettext/5` for an explicit locale and `dngettext/4` (alias).
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
Main form of the plural family: translates the correct plural form for `N` in
the domain `Domain` and the locale `Locale`, both explicit. The other plural
arities delegate here. Maps the C macro
`dcngettext(domain, msgid, msgid_plural, n, LC_MESSAGES)`.

- `Domain` — domain/catalog to look in.
- `Msgid` / `MsgidPlural` — singular/plural forms and the fallbacks.
- `N` — count (arbitrary integer, incl. negatives and bignums).
- `Locale` — exact locale (does not go through `which_locale/0`).

Calls `erli18n_server:lookup_plural_form/5`, which chooses the form by the
`Plural-Forms` rule from the loaded header (total evaluation/clamp — see the
moduledoc). Fallback (R2): on a miss or an empty translation, it returns `Msgid`
if `N == 1`, otherwise `MsgidPlural`. On the miss path it emits
`[erli18n, lookup, miss]` when observability is enabled.

```erlang
1> erli18n:ngettext(my_domain, <<"1 file">>, <<"%d files">>, 1, <<"en">>).
<<"1 file">>
2> erli18n:ngettext(my_domain, <<"1 file">>, <<"%d files">>, 5, <<"en">>).
<<"%d files">>
```

Crashes (`function_clause`) if any argument violates the type. See `npgettext/6`
(contextual plural) and the aliases `dngettext/5` / `dcngettext/5`.
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
            case fallback_lookup_plural(ngettext, Domain, undefined, Msgid, N, Locale) of
                {ok, T2} ->
                    T2;
                miss ->
                    emit_lookup_miss(ngettext, Domain, Locale, undefined, Msgid),
                    plural_fallback(Msgid, MsgidPlural, N)
            end
    end.

%% dngettext/4,5 — GNU C-macro names, aliases for ngettext/4,5.
-doc """
Alias of `ngettext/4` (C macro name `dngettext`). Same semantics and fallback.

```erlang
1> erli18n:dngettext(my_domain, <<"file">>, <<"files">>, 2).
<<"2 fichiers">>
```
""".
-spec dngettext(domain(), msgid(), msgid_plural(), integer()) ->
    translation().
dngettext(Domain, Msgid, MsgidPlural, N) ->
    ngettext(Domain, Msgid, MsgidPlural, N).

-doc """
Alias of `ngettext/5` (C macro name `dngettext`). Same semantics and fallback.

```erlang
1> erli18n:dngettext(my_domain, <<"file">>, <<"files">>, 2, <<"fr">>).
<<"2 fichiers">>
```
""".
-spec dngettext(domain(), msgid(), msgid_plural(), integer(), locale()) ->
    translation().
dngettext(Domain, Msgid, MsgidPlural, N, Locale) ->
    ngettext(Domain, Msgid, MsgidPlural, N, Locale).

%% dcngettext/5 — GNU C-macro name with explicit category. See dcgettext.
-doc """
Alias of `ngettext/5` (C macro name `dcngettext`). The category (LC_MESSAGES)
is always implicit and is not a parameter. Same semantics and fallback as
`ngettext/5`.

```erlang
1> erli18n:dcngettext(my_domain, <<"file">>, <<"files">>, 2, <<"fr">>).
<<"2 fichiers">>
```
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
Translates `Msgid` disambiguated by `Context` (`msgctxt`) in the default domain
and the resolved locale. Use it when the same `msgid` needs different
translations per role (e.g. "May" as a month vs. a verb).

- `Context` — `msgctxt` binary, or `undefined` for "no context"
  (then equivalent to `gettext/1`).
- `Msgid` — key in the source language.

On a miss or an empty translation, it returns `Msgid`. Important: there is **no
retry** with another context — an entry from a different `Context` never leaks;
the miss falls straight back to `Msgid`.

```erlang
1> erli18n:pgettext(<<"month">>, <<"May">>).
<<"Maio">>
2> erli18n:pgettext(<<"verb">>, <<"May">>).
<<"Pode">>
```

Crashes (`function_clause`) if `Context` is not `undefined`/a binary or `Msgid`
is not a binary. See `pgettext/3` (domain) and `pgettext/4` (locale).
""".
-spec pgettext(context(), msgid()) -> translation().
pgettext(Context, Msgid) when
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid)
->
    pgettext(textdomain(), Context, Msgid, resolved_locale()).

-doc """
Same as `pgettext/2`, but with the domain `Domain` explicit; the locale is the
resolved one. Maps the C macro `dpgettext(domain, msgctxt, msgid)`.

```erlang
1> erli18n:pgettext(my_domain, <<"month">>, <<"May">>).
<<"Mai">>
```

Same fallback (no context retry) and crashes as `pgettext/2`. See
`pgettext/4` (explicit locale) and `dpgettext/3` (alias).
""".
-spec pgettext(domain(), context(), msgid()) -> translation().
pgettext(Domain, Context, Msgid) when
    is_atom(Domain),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid)
->
    pgettext(Domain, Context, Msgid, resolved_locale()).

-doc """
Main form of the contextual singular family: translates `Msgid` disambiguated by
`Context` (`msgctxt`) in the domain `Domain` and the locale `Locale`, both
explicit. The other contextual singular arities delegate here. Maps the C macro
`dcpgettext(domain, msgctxt, msgid, LC_MESSAGES)`.

- `Domain` — domain/catalog.
- `Context` — `msgctxt` (binary) or `undefined`.
- `Msgid` — key in the source language.
- `Locale` — exact locale.

Calls `erli18n_server:lookup_singular/4` WITH the `Context`. Fallback (R3): on a
miss or an empty translation, it returns `Msgid` — deliberately **without** a
retry with `Context = undefined`, so as not to leak the translation of another
context. On the miss path it emits `[erli18n, lookup, miss]` (with the `context`
in the metadata) when observability is enabled.

```erlang
1> erli18n:pgettext(my_domain, <<"menu">>, <<"Open">>, <<"de">>).
<<"Öffnen">>
2> erli18n:pgettext(my_domain, <<"nonexistent_context">>, <<"Open">>, <<"de">>).
<<"Open">>
```

Crashes (`function_clause`) if any argument violates the type. See `npgettext/6`
(contextual plural) and the aliases `dpgettext/4` / `dcpgettext/4`.
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
            case fallback_lookup_singular(pgettext, Domain, Context, Msgid, Locale) of
                {ok, T2} ->
                    T2;
                miss ->
                    emit_lookup_miss(pgettext, Domain, Locale, Context, Msgid),
                    Msgid
            end
    end.

%% dpgettext/3,4 — GNU C-macro names, aliases for pgettext/3,4.
-doc """
Alias of `pgettext/3` (C macro name `dpgettext`). Same semantics and fallback.

```erlang
1> erli18n:dpgettext(my_domain, <<"month">>, <<"May">>).
<<"Mai">>
```
""".
-spec dpgettext(domain(), context(), msgid()) -> translation().
dpgettext(Domain, Context, Msgid) ->
    pgettext(Domain, Context, Msgid).

-doc """
Alias of `pgettext/4` (C macro name `dpgettext`). Same semantics and fallback.

```erlang
1> erli18n:dpgettext(my_domain, <<"month">>, <<"May">>, <<"de">>).
<<"Mai">>
```
""".
-spec dpgettext(domain(), context(), msgid(), locale()) -> translation().
dpgettext(Domain, Context, Msgid, Locale) ->
    pgettext(Domain, Context, Msgid, Locale).

%% dcpgettext/4 — GNU C-macro name with explicit category. See dcgettext.
-doc """
Alias of `pgettext/4` (C macro name `dcpgettext`). The category (LC_MESSAGES)
is always implicit and is not a parameter. Same semantics and fallback as
`pgettext/4`.

```erlang
1> erli18n:dcpgettext(my_domain, <<"month">>, <<"May">>, <<"de">>).
<<"Mai">>
```
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
Translates the correct plural form for `N`, disambiguated by `Context`
(`msgctxt`), in the default domain and the resolved locale. Combines context and
plural.

- `Context` — `msgctxt` (binary) or `undefined`.
- `Msgid` / `MsgidPlural` — singular/plural forms and the fallbacks.
- `N` — count (arbitrary integer).

The plural form comes from the `Plural-Forms` rule of the loaded header (total
evaluation/clamp). Fallback: on a miss or an empty translation, it applies R2 to
the msgid/msgid_plural pair (`Msgid` if `N == 1`, otherwise `MsgidPlural`).

```erlang
1> erli18n:npgettext(<<"email">>, <<"message">>, <<"messages">>, 1).
<<"mensagem">>
2> erli18n:npgettext(<<"email">>, <<"message">>, <<"messages">>, 5).
<<"mensagens">>
```

Crashes (`function_clause`) if any argument violates the type. See `npgettext/5`
(domain) and `npgettext/6` (locale).
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
Same as `npgettext/4`, but with the domain `Domain` explicit; the locale is the
resolved one. Maps the C macro `dnpgettext(domain, msgctxt, msgid, msgid_plural,
n)`.

```erlang
1> erli18n:npgettext(my_domain, <<"email">>, <<"message">>, <<"messages">>, 3).
<<"3 messages">>
```

Same plural-form selection, fallback, and crashes as `npgettext/4`. See
`npgettext/6` (explicit locale) and `dnpgettext/5` (alias).
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
Main form of the contextual plural family: translates the correct plural form
for `N`, disambiguated by `Context` (`msgctxt`), in the domain `Domain` and the
locale `Locale`, both explicit. The other contextual plural arities delegate
here. Maps the C macro `dcnpgettext(domain, msgctxt, msgid, msgid_plural, n,
LC_MESSAGES)`.

- `Domain` — domain/catalog.
- `Context` — `msgctxt` (binary) or `undefined`.
- `Msgid` / `MsgidPlural` — singular/plural forms and the fallbacks.
- `N` — count (arbitrary integer).
- `Locale` — exact locale.

Calls `erli18n_server:lookup_plural_form/5` WITH the `Context`; the form comes
from the `Plural-Forms` rule of the loaded header (total evaluation/clamp).
Fallback: on a miss or an empty translation, it applies R2 to the
msgid/msgid_plural pair. On the miss path it emits `[erli18n, lookup, miss]`
(with the `context` in the metadata) when observability is enabled.

```erlang
1> erli18n:npgettext(my_domain, <<"email">>, <<"message">>, <<"messages">>, 1, <<"de">>).
<<"Nachricht">>
2> erli18n:npgettext(my_domain, <<"email">>, <<"message">>, <<"messages">>, 5, <<"de">>).
<<"Nachrichten">>
```

Crashes (`function_clause`) if any argument violates the type. See the aliases
`dnpgettext/6` / `dcnpgettext/6`.
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
            case fallback_lookup_plural(npgettext, Domain, Context, Msgid, N, Locale) of
                {ok, T2} ->
                    T2;
                miss ->
                    emit_lookup_miss(npgettext, Domain, Locale, Context, Msgid),
                    plural_fallback(Msgid, MsgidPlural, N)
            end
    end.

%% dnpgettext/5,6 — GNU C-macro names, aliases for npgettext/5,6.
-doc """
Alias of `npgettext/5` (C macro name `dnpgettext`). Same semantics and
fallback.

```erlang
1> erli18n:dnpgettext(my_domain, <<"email">>, <<"message">>, <<"messages">>, 3).
<<"3 messages">>
```
""".
-spec dnpgettext(
    domain(),
    context(),
    msgid(),
    msgid_plural(),
    integer()
) -> translation().
dnpgettext(Domain, Context, Msgid, MsgidPlural, N) ->
    npgettext(Domain, Context, Msgid, MsgidPlural, N).

-doc """
Alias of `npgettext/6` (C macro name `dnpgettext`). Same semantics and
fallback.

```erlang
1> erli18n:dnpgettext(my_domain, <<"email">>, <<"message">>, <<"messages">>, 3, <<"de">>).
<<"3 Nachrichten">>
```
""".
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
Alias of `npgettext/6` (C macro name `dcnpgettext`). The category
(LC_MESSAGES) is always implicit and is not a parameter. Same semantics and
fallback as `npgettext/6`.

```erlang
1> erli18n:dcnpgettext(my_domain, <<"email">>, <<"message">>, <<"messages">>, 3, <<"de">>).
<<"3 Nachrichten">>
```
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
%% Interpolating `f`-suffix family (Phase 1 — named `%{name}`)
%% =========================
%%
%% Each `f` member is thin and additive: it DELEGATES to its non-`f`
%% sibling above to resolve the translation (reusing the same
%% domain/locale/context resolution, plural-form selection, miss/fallback,
%% and telemetry), then runs `erli18n_interp:format/2` over the resolved
%% binary with the trailing `Bindings` map. Nothing here reimplements
%% lookup. The plural members auto-bind `count => N` via `bind_count/2`
%% (a caller-supplied `count` overrides the auto-bound value). The
%% interpolation is TOTAL and fail-soft on the default (lenient) policy —
%% see `erli18n_interp`. The category is always LC_MESSAGES.

%% Singular `f` — gettextf/dgettextf/dcgettextf.

-doc """
Like `gettext/1`, then interpolates `%{name}` placeholders in the resolved
translation using `Bindings`.

Resolves the translation in the default domain (`textdomain/0`) and the
resolved locale (`which_locale/0` or `default_locale/0`) exactly as
`gettext/1`, then applies `erli18n_interp:format/2` with `Bindings`. On a
miss the resolution falls back to `Msgid`, and interpolation still runs
over that fallback. Interpolation is total and fail-soft: an unbound
placeholder is left literal and nothing crashes.

```erlang
1> erli18n:setlocale(<<"fr">>).
ok
2> erli18n:gettextf(<<"Hello, %{name}!">>, #{name => <<"Ada">>}).
<<"Bonjour, Ada!">>
```

Crashes (`function_clause`) if `Msgid` is not a binary or `Bindings` is not
a map. See `gettextf/3` (domain) and `gettextf/4` (locale).
""".
-spec gettextf(msgid(), bindings()) -> translation().
gettextf(Msgid, Bindings) when is_binary(Msgid), is_map(Bindings) ->
    erli18n_interp:format(gettext(Msgid), Bindings).

-doc """
Like `gettext/2` (explicit domain), then interpolates `%{name}`
placeholders using `Bindings`. Maps the interpolating form of `dgettext`.

```erlang
1> erli18n:gettextf(my_domain, <<"Hello, %{name}!">>, #{name => <<"Ada">>}).
<<"Bonjour, Ada!">>
```

Same resolution and fallback as `gettext/2`. See `gettextf/4` (explicit
locale) and `dgettextf/3` (alias).
""".
-spec gettextf(domain(), msgid(), bindings()) -> translation().
gettextf(Domain, Msgid, Bindings) when
    is_atom(Domain), is_binary(Msgid), is_map(Bindings)
->
    erli18n_interp:format(gettext(Domain, Msgid), Bindings).

-doc """
Main interpolating singular form: like `gettext/3` (explicit domain and
locale), then interpolates `%{name}` placeholders using `Bindings`.

Resolves via `gettext/3` (ignoring the per-process locale) and applies
`erli18n_interp:format/2`. On a miss the resolution falls back to `Msgid`,
over which interpolation still runs.

```erlang
1> erli18n:gettextf(my_domain, <<"Hello, %{name}!">>, <<"fr">>,
1>                  #{name => <<"Ada">>}).
<<"Bonjour, Ada!">>
```

Crashes (`function_clause`) if any argument violates the type. See the
aliases `dgettextf/4` / `dcgettextf/4`.
""".
-spec gettextf(domain(), msgid(), locale(), bindings()) -> translation().
gettextf(Domain, Msgid, Locale, Bindings) when
    is_atom(Domain), is_binary(Msgid), is_binary(Locale), is_map(Bindings)
->
    erli18n_interp:format(gettext(Domain, Msgid, Locale), Bindings).

-doc """
Alias of `gettextf/3` (C macro name `dgettext`, interpolating). Same
semantics and fallback.
""".
-spec dgettextf(domain(), msgid(), bindings()) -> translation().
dgettextf(Domain, Msgid, Bindings) ->
    gettextf(Domain, Msgid, Bindings).

-doc """
Alias of `gettextf/4` (C macro name `dgettext`, interpolating). Same
semantics and fallback.
""".
-spec dgettextf(domain(), msgid(), locale(), bindings()) -> translation().
dgettextf(Domain, Msgid, Locale, Bindings) ->
    gettextf(Domain, Msgid, Locale, Bindings).

-doc """
Alias of `gettextf/4` (C macro name `dcgettext`, interpolating). The
category (LC_MESSAGES) is always implicit and is not a parameter. Same
semantics and fallback as `gettextf/4`.
""".
-spec dcgettextf(domain(), msgid(), locale(), bindings()) -> translation().
dcgettextf(Domain, Msgid, Locale, Bindings) ->
    gettextf(Domain, Msgid, Locale, Bindings).

%% Plural `f` — ngettextf/dngettextf/dcngettextf.

-doc """
Like `ngettext/3`, then interpolates `%{name}` placeholders using
`Bindings` with `count => N` auto-bound.

Resolves the correct plural form for `N` in the default domain and the
resolved locale exactly as `ngettext/3`, then applies
`erli18n_interp:format/2` over the resolved string. `count => N` is merged
into `Bindings` automatically (a caller-supplied `count` wins). On a miss
the resolution falls back to `Msgid` (when `N == 1`) or `MsgidPlural`,
over which interpolation still runs.

```erlang
1> erli18n:setlocale(<<"en">>).
ok
2> erli18n:ngettextf(<<"%{count} file">>, <<"%{count} files">>, 3, #{}).
<<"3 files">>
```

Crashes (`function_clause`) if `Msgid`/`MsgidPlural` are not binaries, `N`
is not an integer, or `Bindings` is not a map. See `ngettextf/5` (domain)
and `ngettextf/6` (locale).
""".
-spec ngettextf(msgid(), msgid_plural(), integer(), bindings()) ->
    translation().
ngettextf(Msgid, MsgidPlural, N, Bindings) when
    is_binary(Msgid), is_binary(MsgidPlural), is_integer(N), is_map(Bindings)
->
    erli18n_interp:format(
        ngettext(Msgid, MsgidPlural, N), bind_count(N, Bindings)
    ).

-doc """
Like `ngettext/4` (explicit domain), then interpolates `%{name}`
placeholders using `Bindings` with `count => N` auto-bound (caller
override wins).

```erlang
1> erli18n:ngettextf(my_domain, <<"%{count} file">>, <<"%{count} files">>,
1>                   42, #{}).
<<"42 fichiers">>
```

Same plural-form selection and fallback as `ngettext/4`. See `ngettextf/6`
(locale) and `dngettextf/5` (alias).
""".
-spec ngettextf(domain(), msgid(), msgid_plural(), integer(), bindings()) ->
    translation().
ngettextf(Domain, Msgid, MsgidPlural, N, Bindings) when
    is_atom(Domain),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N),
    is_map(Bindings)
->
    erli18n_interp:format(
        ngettext(Domain, Msgid, MsgidPlural, N), bind_count(N, Bindings)
    ).

-doc """
Main interpolating plural form: like `ngettext/5` (explicit domain and
locale), then interpolates `%{name}` placeholders using `Bindings` with
`count => N` auto-bound (caller override wins).

Resolves via `ngettext/5` (ignoring the per-process locale) and applies
`erli18n_interp:format/2` over the resolved string. On a miss the
resolution falls back to `Msgid` (when `N == 1`) or `MsgidPlural`, over
which interpolation still runs.

```erlang
1> erli18n:ngettextf(my_domain, <<"%{count} file">>, <<"%{count} files">>,
1>                   5, <<"en">>, #{}).
<<"5 files">>
```

Crashes (`function_clause`) if any argument violates the type. See the
aliases `dngettextf/6` / `dcngettextf/6`.
""".
-spec ngettextf(
    domain(), msgid(), msgid_plural(), integer(), locale(), bindings()
) -> translation().
ngettextf(Domain, Msgid, MsgidPlural, N, Locale, Bindings) when
    is_atom(Domain),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N),
    is_binary(Locale),
    is_map(Bindings)
->
    erli18n_interp:format(
        ngettext(Domain, Msgid, MsgidPlural, N, Locale),
        bind_count(N, Bindings)
    ).

-doc """
Alias of `ngettextf/5` (C macro name `dngettext`, interpolating). Same
semantics, fallback, and `count => N` auto-binding.
""".
-spec dngettextf(domain(), msgid(), msgid_plural(), integer(), bindings()) ->
    translation().
dngettextf(Domain, Msgid, MsgidPlural, N, Bindings) ->
    ngettextf(Domain, Msgid, MsgidPlural, N, Bindings).

-doc """
Alias of `ngettextf/6` (C macro name `dngettext`, interpolating). Same
semantics, fallback, and `count => N` auto-binding.
""".
-spec dngettextf(
    domain(), msgid(), msgid_plural(), integer(), locale(), bindings()
) -> translation().
dngettextf(Domain, Msgid, MsgidPlural, N, Locale, Bindings) ->
    ngettextf(Domain, Msgid, MsgidPlural, N, Locale, Bindings).

-doc """
Alias of `ngettextf/6` (C macro name `dcngettext`, interpolating). The
category (LC_MESSAGES) is always implicit and is not a parameter. Same
semantics, fallback, and `count => N` auto-binding as `ngettextf/6`.
""".
-spec dcngettextf(
    domain(), msgid(), msgid_plural(), integer(), locale(), bindings()
) -> translation().
dcngettextf(Domain, Msgid, MsgidPlural, N, Locale, Bindings) ->
    ngettextf(Domain, Msgid, MsgidPlural, N, Locale, Bindings).

%% Contextual singular `f` — pgettextf/dpgettextf/dcpgettextf.

-doc """
Like `pgettext/2`, then interpolates `%{name}` placeholders in the
resolved translation using `Bindings`.

Resolves the contextual singular in the default domain and the resolved
locale exactly as `pgettext/2`, then applies `erli18n_interp:format/2`. On
a miss the resolution falls back to `Msgid` (it never leaks a translation
from a different context), over which interpolation still runs.

```erlang
1> erli18n:pgettextf(<<"menu">>, <<"Open %{file}">>, #{file => <<"a.txt">>}).
<<"Abrir a.txt">>
```

Crashes (`function_clause`) if `Context`/`Msgid` are not binaries (or
`Context` `undefined`) or `Bindings` is not a map. See `pgettextf/4`
(domain) and `pgettextf/5` (locale).
""".
-spec pgettextf(context(), msgid(), bindings()) -> translation().
pgettextf(Context, Msgid, Bindings) when
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_map(Bindings)
->
    erli18n_interp:format(pgettext(Context, Msgid), Bindings).

-doc """
Like `pgettext/3` (explicit domain), then interpolates `%{name}`
placeholders using `Bindings`. Maps the interpolating form of `dpgettext`.

Same contextual resolution and fallback as `pgettext/3`. See `pgettextf/5`
(locale) and `dpgettextf/4` (alias).
""".
-spec pgettextf(domain(), context(), msgid(), bindings()) -> translation().
pgettextf(Domain, Context, Msgid, Bindings) when
    is_atom(Domain),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_map(Bindings)
->
    erli18n_interp:format(pgettext(Domain, Context, Msgid), Bindings).

-doc """
Main interpolating contextual singular form: like `pgettext/4` (explicit
domain and locale), then interpolates `%{name}` placeholders using
`Bindings`.

Resolves via `pgettext/4` (ignoring the per-process locale) and applies
`erli18n_interp:format/2`. On a miss the resolution falls back to `Msgid`,
over which interpolation still runs.

```erlang
1> erli18n:pgettextf(my_domain, <<"menu">>, <<"Open %{file}">>, <<"pt_BR">>,
1>                   #{file => <<"a.txt">>}).
<<"Abrir a.txt">>
```

Crashes (`function_clause`) if any argument violates the type. See the
aliases `dpgettextf/5` / `dcpgettextf/5`.
""".
-spec pgettextf(domain(), context(), msgid(), locale(), bindings()) ->
    translation().
pgettextf(Domain, Context, Msgid, Locale, Bindings) when
    is_atom(Domain),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(Locale),
    is_map(Bindings)
->
    erli18n_interp:format(
        pgettext(Domain, Context, Msgid, Locale), Bindings
    ).

-doc """
Alias of `pgettextf/4` (C macro name `dpgettext`, interpolating). Same
semantics and fallback.
""".
-spec dpgettextf(domain(), context(), msgid(), bindings()) -> translation().
dpgettextf(Domain, Context, Msgid, Bindings) ->
    pgettextf(Domain, Context, Msgid, Bindings).

-doc """
Alias of `pgettextf/5` (C macro name `dpgettext`, interpolating). Same
semantics and fallback.
""".
-spec dpgettextf(domain(), context(), msgid(), locale(), bindings()) ->
    translation().
dpgettextf(Domain, Context, Msgid, Locale, Bindings) ->
    pgettextf(Domain, Context, Msgid, Locale, Bindings).

-doc """
Alias of `pgettextf/5` (C macro name `dcpgettext`, interpolating). The
category (LC_MESSAGES) is always implicit and is not a parameter. Same
semantics and fallback as `pgettextf/5`.
""".
-spec dcpgettextf(domain(), context(), msgid(), locale(), bindings()) ->
    translation().
dcpgettextf(Domain, Context, Msgid, Locale, Bindings) ->
    pgettextf(Domain, Context, Msgid, Locale, Bindings).

%% Contextual plural `f` — npgettextf/dnpgettextf/dcnpgettextf.

-doc """
Like `npgettext/4`, then interpolates `%{name}` placeholders using
`Bindings` with `count => N` auto-bound (caller override wins).

Resolves the contextual plural form for `N` in the default domain and the
resolved locale exactly as `npgettext/4`, then applies
`erli18n_interp:format/2`. On a miss the resolution falls back to `Msgid`
(when `N == 1`) or `MsgidPlural`, over which interpolation still runs.

```erlang
1> erli18n:npgettextf(<<"inbox">>, <<"%{count} message">>,
1>                    <<"%{count} messages">>, 3, #{}).
<<"3 messages">>
```

Crashes (`function_clause`) if any argument violates the type. See
`npgettextf/6` (domain) and `npgettextf/7` (locale).
""".
-spec npgettextf(context(), msgid(), msgid_plural(), integer(), bindings()) ->
    translation().
npgettextf(Context, Msgid, MsgidPlural, N, Bindings) when
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N),
    is_map(Bindings)
->
    erli18n_interp:format(
        npgettext(Context, Msgid, MsgidPlural, N), bind_count(N, Bindings)
    ).

-doc """
Like `npgettext/5` (explicit domain), then interpolates `%{name}`
placeholders using `Bindings` with `count => N` auto-bound (caller
override wins). Maps the interpolating form of `dnpgettext`.

Same contextual plural-form selection and fallback as `npgettext/5`. See
`npgettextf/7` (locale) and `dnpgettextf/6` (alias).
""".
-spec npgettextf(
    domain(), context(), msgid(), msgid_plural(), integer(), bindings()
) -> translation().
npgettextf(Domain, Context, Msgid, MsgidPlural, N, Bindings) when
    is_atom(Domain),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N),
    is_map(Bindings)
->
    erli18n_interp:format(
        npgettext(Domain, Context, Msgid, MsgidPlural, N),
        bind_count(N, Bindings)
    ).

-doc """
Main interpolating contextual plural form: like `npgettext/6` (explicit
domain and locale), then interpolates `%{name}` placeholders using
`Bindings` with `count => N` auto-bound (caller override wins).

Resolves via `npgettext/6` (ignoring the per-process locale) and applies
`erli18n_interp:format/2`. On a miss the resolution falls back to `Msgid`
(when `N == 1`) or `MsgidPlural`, over which interpolation still runs.

```erlang
1> erli18n:npgettextf(my_domain, <<"inbox">>, <<"%{count} message">>,
1>                    <<"%{count} messages">>, 5, <<"de">>, #{}).
<<"5 Nachrichten">>
```

Crashes (`function_clause`) if any argument violates the type. See the
aliases `dnpgettextf/7` / `dcnpgettextf/7`.
""".
-spec npgettextf(
    domain(),
    context(),
    msgid(),
    msgid_plural(),
    integer(),
    locale(),
    bindings()
) -> translation().
npgettextf(Domain, Context, Msgid, MsgidPlural, N, Locale, Bindings) when
    is_atom(Domain),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(MsgidPlural),
    is_integer(N),
    is_binary(Locale),
    is_map(Bindings)
->
    erli18n_interp:format(
        npgettext(Domain, Context, Msgid, MsgidPlural, N, Locale),
        bind_count(N, Bindings)
    ).

-doc """
Alias of `npgettextf/6` (C macro name `dnpgettext`, interpolating). Same
semantics, fallback, and `count => N` auto-binding.
""".
-spec dnpgettextf(
    domain(), context(), msgid(), msgid_plural(), integer(), bindings()
) -> translation().
dnpgettextf(Domain, Context, Msgid, MsgidPlural, N, Bindings) ->
    npgettextf(Domain, Context, Msgid, MsgidPlural, N, Bindings).

-doc """
Alias of `npgettextf/7` (C macro name `dnpgettext`, interpolating). Same
semantics, fallback, and `count => N` auto-binding.
""".
-spec dnpgettextf(
    domain(),
    context(),
    msgid(),
    msgid_plural(),
    integer(),
    locale(),
    bindings()
) -> translation().
dnpgettextf(Domain, Context, Msgid, MsgidPlural, N, Locale, Bindings) ->
    npgettextf(Domain, Context, Msgid, MsgidPlural, N, Locale, Bindings).

-doc """
Alias of `npgettextf/7` (C macro name `dcnpgettext`, interpolating). The
category (LC_MESSAGES) is always implicit and is not a parameter. Same
semantics, fallback, and `count => N` auto-binding as `npgettextf/7`.
""".
-spec dcnpgettextf(
    domain(),
    context(),
    msgid(),
    msgid_plural(),
    integer(),
    locale(),
    bindings()
) -> translation().
dcnpgettextf(Domain, Context, Msgid, MsgidPlural, N, Locale, Bindings) ->
    npgettextf(Domain, Context, Msgid, MsgidPlural, N, Locale, Bindings).

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
Returns the current locale of the calling process, or `undefined` if none has
been set.

The value is what `setlocale/1` wrote to this process's dictionary. Since the
state is per-process and is **not** inherited across `spawn/1`, a freshly created
process reads `undefined` here (and, on the lookup path, falls back to
`default_locale/0`).

```erlang
1> erli18n:which_locale().
undefined
2> erli18n:setlocale(<<"pt_BR">>).
ok
3> erli18n:which_locale().
<<"pt_BR">>
```

Crashes with `error({invalid_process_locale, _})` if the private dictionary key
(`'$erli18n_locale'`) has been overwritten by a third party with a non-binary
value — `setlocale/1` only writes binaries, so any other shape is a contract
violation and must fail visibly. See `setlocale/1` (write) and
`default_locale/0` (fallback).
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
Sets the current locale of the calling process to `Locale` (binary) and returns
`ok`.

- `Locale` — locale to use in this process's subsequent lookups that depend on
  the resolved locale (`gettext/1`, `ngettext/3`, ...).

Scope: **the current process only**. The value lives in the process dictionary
and is not inherited by child processes — each request process must call
`setlocale/1` on its own. Typically called once at the start of handling each
request.

```erlang
1> erli18n:setlocale(<<"de">>).
ok
2> erli18n:which_locale().
<<"de">>
```

Crashes (`function_clause`) if `Locale` is not a binary. See `which_locale/0`
(read) and `set_default_locale/1` (app-global default).
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
Returns the application's default locale (env `erli18n.default_locale`, default
`<<"en">>`).

It is the locale fallback used by every lookup when the calling process has not
set a locale via `setlocale/1` (that is, when `which_locale/0` is `undefined`).

```erlang
1> erli18n:default_locale().
<<"en">>
2> erli18n:set_default_locale(<<"pt_BR">>).
ok
3> erli18n:default_locale().
<<"pt_BR">>
```

Crashes with `error({invalid_config, _})` if the value configured in the env is
not a binary — the boundary is narrowed so a misconfiguration becomes a
descriptive crash here, rather than a silent surprise downstream (e.g. an atom
leaking into a `gettext/3` that only accepts a binary). See `set_default_locale/1`
and `which_locale/0`.
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
Sets the application's default locale (env `erli18n.default_locale`) to
`Locale` (binary) and returns `ok`.

- `Locale` — new node-global default.

Affects **all** processes that rely on the locale fallback (those that have not
called `setlocale/1`). It is `application:env` state, not per-process.
Typically called once at app boot.

```erlang
1> erli18n:set_default_locale(<<"fr">>).
ok
2> erli18n:default_locale().
<<"fr">>
```

Crashes (`function_clause`) if `Locale` is not a binary. See `default_locale/0`
(read) and `setlocale/1` (per-process override).
""".
-spec set_default_locale(locale()) -> ok.
set_default_locale(Locale) when is_binary(Locale) ->
    application:set_env(erli18n, default_locale, Locale).

-doc """
Returns the application's default domain (env `erli18n.default_domain`, default
`default`).

It is the domain used by the variants without an explicit domain — `gettext/1`,
`ngettext/3`, `pgettext/2`, `npgettext/4`.

```erlang
1> erli18n:textdomain().
default
2> erli18n:textdomain(my_domain).
ok
3> erli18n:textdomain().
my_domain
```

Crashes with `error({invalid_config, _})` if the value configured in the env is
not an atom (same narrowing strategy as `default_locale/0`). See
`textdomain/1` (write).
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
Sets the application's default domain (env `erli18n.default_domain`) to
`Domain` (atom) and returns `ok`. Equivalent to C gettext's `textdomain(3)`
function.

- `Domain` — new node-global default domain.

Affects all subsequent calls to the variants without an explicit domain. It is
`application:env` state, not per-process.

```erlang
1> erli18n:textdomain(errors).
ok
2> erli18n:textdomain().
errors
```

Crashes (`function_clause`) if `Domain` is not an atom. See `textdomain/0`
(read).
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
Loads the `.po` catalog at `PoPath` for the pair `(Domain, Locale)`,
idempotently. It is the typical boot call: load each catalog once.

- `Domain` — catalog domain.
- `Locale` — catalog locale.
- `PoPath` — path to the `.po` (use `default_po_path/3` for the conventional
  layout).

Idempotence: if the pair is already loaded, it returns `{ok, already}` **without
re-reading from disk** — to force a re-read, use `reload/3`. Loading is atomic:
parse, plural-rule compilation, and CLDR validation run before any catalog
install; on error the state stays intact.

Return: `{ok, NumEntries}` on the first load, `{ok, already}` if already
present, or `{error, Reason}` on a file/parse/compile failure (e.g.
`{error, {file_error, enoent}}`, `{error, {plural_compile_error, _}}`).

```erlang
1> erli18n:ensure_loaded(my_domain, <<"fr">>, "priv/locale/fr/LC_MESSAGES/my_domain.po").
{ok, 12}
2> erli18n:ensure_loaded(my_domain, <<"fr">>, "priv/locale/fr/LC_MESSAGES/my_domain.po").
{ok, already}
```

Delegates to `erli18n_server:ensure_loaded/3`. See `ensure_loaded/4` (with `Opts`
and anti-DoS limits), `reload/3`, and `unload/2`.
""".
-spec ensure_loaded(domain(), locale(), file:filename()) ->
    erli18n_server:ensure_result().
ensure_loaded(Domain, Locale, PoPath) ->
    erli18n_server:ensure_loaded(Domain, Locale, PoPath).

-doc """
Same as `ensure_loaded/3`, with `Opts` controlling the load — use this form
when the `.po` is untrusted input (multi-tenant) and you want explicit anti-DoS
limits.

- `Opts` — map with the supported fields:
  - `include_fuzzy` — include entries marked as fuzzy.
  - `max_bytes` — rejects the file (via `filelib:file_size/1`, **without reading**
    the bytes) if it exceeds the limit.
  - `max_entries` — rejects the catalog (after the parse) if it has more entries
    than the limit.
  - `timeout` — commit timeout.

Exceeded bounds return `{error, {input_too_large, _, _}}` (byte limit)
or `{error, {too_many_entries, _, _}}` (entry limit). The other semantics
(idempotence, atomicity) are the same as `ensure_loaded/3`.

```erlang
1> erli18n:ensure_loaded(my_domain, <<"fr">>, "fr.po", #{max_bytes => 1048576}).
{ok, 12}
2> erli18n:ensure_loaded(my_domain, <<"fr">>, "huge.po", #{max_bytes => 1024}).
{error, {input_too_large, _, _}}
```

Delegates to `erli18n_server:ensure_loaded/4`. See `reload/4`.
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
Reloads (atomically) the `(Domain, Locale)` catalog from `PoPath`,
**even if it is already loaded** — it is the path to apply changes to the `.po`
without restarting the app (unlike `ensure_loaded/3`, which is a no-op if already
present).

- `Domain` / `Locale` — catalog pair to reload.
- `PoPath` — path to the `.po` (always re-read from disk).

The operation is atomic and **without an empty window**: the fallible pipeline
(read/parse/compile) runs without touching the live catalog, and the install is a
single atomic persistent_term overwrite (whole-catalog replacement), so
concurrent lookups never see an empty or half-applied catalog.
On error, the previous catalog stays intact.

Return: `{ok, NumEntries}` on success or `{error, Reason}` on failure.

```erlang
1> erli18n:reload(my_domain, <<"fr">>, "priv/locale/fr/LC_MESSAGES/my_domain.po").
{ok, 15}
```

Delegates to `erli18n_server:reload/3`. See `reload/4` (with `Opts`) and
`ensure_loaded/3`.
""".
-spec reload(domain(), locale(), file:filename()) ->
    erli18n_server:ensure_result().
reload(Domain, Locale, PoPath) ->
    erli18n_server:reload(Domain, Locale, PoPath).

-doc """
Same as `reload/3`, with `Opts` (the same fields as `ensure_loaded/4`:
`include_fuzzy`, `max_bytes`, `max_entries`, `timeout`). Keeps the reload atomic
and the previous catalog intact in case of error.

```erlang
1> erli18n:reload(my_domain, <<"fr">>, "fr.po", #{max_entries => 5000}).
{ok, 15}
```

Delegates to `erli18n_server:reload/4`. See `reload/3` and `ensure_loaded/4`.
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
Removes the `(Domain, Locale)` catalog from memory and returns `ok`.

- `Domain` / `Locale` — catalog pair to unload.

After the unload, lookups for that pair fall back again (returning the
`msgid`/`msgid_plural`). It is idempotent: unloading a nonexistent catalog
also returns `ok`.

```erlang
1> erli18n:unload(my_domain, <<"fr">>).
ok
2> erli18n:unload(my_domain, <<"never_loaded">>).
ok
```

Delegates to `erli18n_server:unload/2`. See `ensure_loaded/3` and
`loaded_catalogs/0`.
""".
-spec unload(domain(), locale()) -> ok.
unload(Domain, Locale) ->
    erli18n_server:unload(Domain, Locale).

%% Convention-based path resolver: <PrivDir>/locale/<Locale>/LC_MESSAGES/<Domain>.po.
%% See BR-MIGRAR-005 / ADR-0003 (multi-tenant filesystem layout).
-doc """
Resolves the conventional `.po` path for the application `App`.

- `App` — name of the OTP application whose `priv/` contains the catalogs.
- `Domain` — domain (becomes the file name `<Domain>.po`).
- `Locale` — locale (becomes the directory `<Locale>`).

Assembles `<PrivDir>/locale/<Locale>/LC_MESSAGES/<Domain>.po`, where `PrivDir` is
the `priv/` directory of `App` (via `code:priv_dir/1`). A convenience to feed
`ensure_loaded/3,4` and `reload/3,4` without assembling the path manually.

```erlang
1> erli18n:default_po_path(my_app, my_domain, <<"fr">>).
"/.../my_app/priv/locale/fr/LC_MESSAGES/my_domain.po"
```

Delegates to `erli18n_server:default_po_path/3`.
""".
-spec default_po_path(atom(), domain(), locale()) -> file:filename().
default_po_path(App, Domain, Locale) ->
    erli18n_server:default_po_path(App, Domain, Locale).

%% =========================
%% Observability passthrough
%% =========================

-doc """
Returns a map with memory-usage information for the loaded catalogs. Useful
for observability and operational diagnostics (growth alerts,
dashboards).

The return has three fixed keys:

- `ets_bytes` — approximate bytes consumed by the catalog storage (already
  converted from VM words to bytes; multiplied by `erlang:system_info(wordsize)`).
  **The field name is historical** (storage is now `persistent_term`, not ETS);
  it is kept for backwards compatibility with the 0.3.0 return shape.
- `num_catalogs` — number of loaded `(Domain, Locale)` catalogs.
- `num_keys` — total number of entries (keys) across all catalogs.

```erlang
1> erli18n:memory_info().
#{ets_bytes => 24576, num_catalogs => 3, num_keys => 130}
```

This façade's `-spec` weakens to `map()`, but the server guarantees exactly
these three keys (`erli18n_server:memory_info/0`). See `loaded_catalogs/0`.
""".
-spec memory_info() -> map().
memory_info() ->
    erli18n_server:memory_info().

-doc """
Lists the currently loaded catalogs as `{Domain, Locale, NumEntries}` tuples,
one per domain/locale pair. Returns an empty list if nothing is
loaded.

```erlang
1> erli18n:loaded_catalogs().
[{my_domain, <<"fr">>, 12}, {my_domain, <<"de">>, 11}]
```

Delegates to `erli18n_server:loaded_catalogs/0`. See `which_keys/2` (keys of a
specific catalog) and `memory_info/0`.
""".
-spec loaded_catalogs() ->
    [{domain(), locale(), non_neg_integer()}].
loaded_catalogs() ->
    erli18n_server:loaded_catalogs().

-doc """
Lists the distinct locales that currently have at least one catalog loaded, in
sorted order — the authoritative *available* set for locale negotiation.

This is the locale projection of `loaded_catalogs/0`, deduplicated across
domains: you can only serve a locale you have actually loaded, so this — not a
side configuration list — is what a request middleware negotiates against. Pass
it as the `Available` argument to `negotiate/2`. Returns an empty list when
nothing is loaded.

```erlang
1> erli18n:loaded_locales().
[<<"de">>, <<"fr">>, <<"pt_BR">>]
2> erli18n:negotiate(erli18n:parse_accept_language(<<"fr;q=0.9, de">>),
..                   erli18n:loaded_locales()).
{ok, <<"de">>}
```

See `loaded_catalogs/0` (the full per-catalog list) and the optional
`erli18n_cowboy` / `erli18n_elli` request adapters, which default their available
set to this function.
""".
-spec loaded_locales() -> [locale()].
loaded_locales() ->
    erli18n_server:loaded_locales().

-doc """
Lists the keys (entries) of the `(Domain, Locale)` catalog, useful for
introspection and tests (e.g. asserting that a `.po` loaded the expected entry).

- `Domain` / `Locale` — catalog pair to inspect.

Each key is `{singular, Context, Msgid}` or `{plural, Context, Msgid}`, where
`Context` is `undefined` when there is no `msgctxt`. Returns an empty list if the
catalog is not loaded.

```erlang
1> erli18n:which_keys(my_domain, <<"fr">>).
[{singular, undefined, <<"Hello">>},
 {plural, undefined, <<"file">>},
 {singular, <<"month">>, <<"May">>}]
```

Delegates to `erli18n_server:which_keys/2`. See `loaded_catalogs/0`.
""".
-spec which_keys(domain(), locale()) ->
    [
        {singular, context(), msgid()}
        | {plural, context(), msgid()}
    ].
which_keys(Domain, Locale) ->
    erli18n_server:which_keys(Domain, Locale).

%% =========================
%% Locale negotiation & fallback (Phase 2) — public facade
%% =========================

-doc """
Chooses the best supported locale for a client preference list, always
returning a usable locale.

`Preferred` is an ordered preference list — either `[locale()]` or the
`[{locale(), 0..1000}]` output of `parse_accept_language/1` — where position
encodes priority. `Available` is the list of locales the caller supports
(typically the `Locale` field of `loaded_catalogs/0`). Each preference is
canonicalized and resolved through its BCP-47 fallback chain against
`Available`; the first hit wins and is returned in its original `Available`
casing. When nothing matches, returns `{ok, default_locale()}` so the result
is always safe to feed to `setlocale/1`.

This helper is **pure** and independent of the `locale_fallback` env: it is
the negotiation primitive for request middleware, distinct from the catalog
lookup-time fallback chain (which the four lookup families apply on a miss).

```erlang
1> erli18n:negotiate([<<"pt-BR">>], [<<"pt">>, <<"en">>]).
{ok,<<"pt">>}
2> erli18n:negotiate(
..    erli18n:parse_accept_language(<<"fr-CH, fr;q=0.9, en;q=0.5">>),
..    [<<"en">>, <<"de">>]).
{ok,<<"en">>}
```

See `parse_accept_language/1`, `canonicalize_locale/1`, and the lower-level
`erli18n_negotiate:negotiate/2` (which returns `error` instead of the
default on no match).
""".
-spec negotiate(
    [locale()] | [{locale(), erli18n_negotiate:qvalue()}], [locale()]
) -> {ok, locale()}.
negotiate(Preferred, Available) ->
    erli18n_negotiate:negotiate(Preferred, Available, default_locale()).

-doc """
Parses an HTTP `Accept-Language` header into a priority-ordered
`[{LanguageRange, Q}]` list (`Q` an integer in milli-units, `0..1000`).

Total and fail-soft: malformed elements are skipped and a hostile or empty
header yields `[]` — it never raises. Bounded against header/element DoS. The
output is sorted by descending quality (stable on ties) and is drop-in
compatible with `cowboy_req:parse_header(<<"accept-language">>, Req)`. Feed it
straight into `negotiate/2`.

```erlang
1> erli18n:parse_accept_language(<<"da, en-gb;q=0.8, en;q=0.7">>).
[{<<"da">>,1000},{<<"en-gb">>,800},{<<"en">>,700}]
```

Delegates to `erli18n_negotiate:parse_accept_language/1`.
""".
-spec parse_accept_language(binary()) ->
    [{erli18n_negotiate:language_range(), erli18n_negotiate:qvalue()}].
parse_accept_language(Header) ->
    erli18n_negotiate:parse_accept_language(Header).

-doc """
Canonicalizes one BCP-47 / POSIX locale tag to erli18n catalog-key shape
(`<<"pt-BR">>` → `<<"pt_BR">>`, `<<"iw">>` → `<<"he">>`).

Total and idempotent over binary content; see `erli18n_negotiate:canonicalize/1`
for the full algorithm, the legacy-alias table, and the documented non-goals
(the script⇄region inference `zh_Hans` ⇄ `zh_CN` is out of scope).

```erlang
1> erli18n:canonicalize_locale(<<"PT_br.UTF-8">>).
<<"pt_BR">>
```
""".
-spec canonicalize_locale(binary()) -> binary().
canonicalize_locale(Tag) ->
    erli18n_negotiate:canonicalize(Tag).

-doc """
Sets the application's locale-fallback mode (env `erli18n.locale_fallback`)
and returns `ok`.

Modes:
- `off` (default) — exact-match only; behavior is identical to 0.2.0 and the
  lookup hot path reads nothing extra.
- `base_language` — on an exact miss, try the canonicalization-aware BCP-47
  fallback chain (`pt_BR` → `pt` → `default_locale/0`) before falling back to
  the msgid.
- `{explicit, Map}` — `Map :: #{locale() => [locale()]}`; for a listed locale
  the chain is the (canonicalized) override list, else it falls through to
  `base_language`. An override layer, not an allowlist.

The fallback chain runs only on a lookup MISS and only when this mode is not
`off`, so enabling it never slows an exact hit. An invalid stored value is
treated as `off` (fail-soft) at lookup time rather than crashing a translation.

```erlang
1> erli18n:set_locale_fallback(base_language).
ok
```

See `negotiate/2` (request-time negotiation) and `erli18n_negotiate`.
""".
-spec set_locale_fallback(off | base_language | {explicit, #{locale() => [locale()]}}) -> ok.
set_locale_fallback(off) ->
    application:set_env(erli18n, locale_fallback, off);
set_locale_fallback(base_language) ->
    application:set_env(erli18n, locale_fallback, base_language);
set_locale_fallback({explicit, Map}) when is_map(Map) ->
    application:set_env(erli18n, locale_fallback, {explicit, Map}).

%% =========================
%% Internal helpers
%% =========================

-doc """
Internal helper: the effective locale of each lookup (rule R5).

Returns `which_locale/0` if the process set a locale via `setlocale/1`, otherwise
`default_locale/0`. It is the single point that reconciles the per-process state
with the global default; every arity that receives an implicit locale goes
through here. Hot path: 1 read of the process dictionary (~ns) + 1
`application:get_env` (cached in the OTP application controller).
""".
-spec resolved_locale() -> locale().
resolved_locale() ->
    case which_locale() of
        undefined -> default_locale();
        Locale -> Locale
    end.

-doc """
Internal helper: the plural fallback shared by `ngettext/5` and `npgettext/6`
(rule R2).

Triggered when there is no usable translation — catalog not loaded, missing
entry, or an entry present but with the form selected for `N` empty
(PSD-003). It applies the C convention: `Msgid` when `N == 1`, `MsgidPlural`
otherwise. Note that the decision uses raw `N` (not the evaluated plural form),
which matches GNU's `ngettext(3)` behavior without needing the catalog. Total
and side-effect-free.
""".
-spec plural_fallback(msgid(), msgid_plural(), integer()) -> translation().
plural_fallback(Msgid, _MsgidPlural, 1) -> Msgid;
plural_fallback(_Msgid, MsgidPlural, _) -> MsgidPlural.

-doc """
Internal helper: auto-bind `count => N` for the interpolating plural
families (`ngettextf`, `npgettextf` and their `d`/`dc` aliases).

Merges the count `N` into the caller's `Bindings` under the `count` key so
a `%{count}` placeholder in the translation resolves without the caller
having to repeat `N`. The merge order makes the CALLER's `Bindings` WIN:
if the caller supplies an explicit `count`, that value is rendered instead
of `N` (while `N` still drives the plural-form selection upstream). Total
and side-effect-free.
""".
-spec bind_count(integer(), bindings()) -> bindings().
bind_count(N, Bindings) ->
    maps:merge(#{count => N}, Bindings).

%% =========================
%% Telemetry — lookup miss
%% =========================
%%
%% Opt-in (overhead policy). The flag is checked first so the fast path
%% stays a single `application:get_env` (ETS read, ~100ns). When the flag
%% is OFF the function returns immediately and no event is constructed.
%%
%% Schema of `[erli18n, lookup, miss]`:
%%   measurements: `#{count => 1}`
%%   metadata:     `#{domain, locale, msgid, function, context}`
%%
%% Note: we surface `context` in the metadata so the consumer can
%% distinguish pgettext from gettext misses without inferring from the
%% function atom.
-doc """
Internal helper: emits the lookup-miss telemetry event
(`[erli18n, lookup, miss]`), invoked by all fallback paths of the four families.

`Function` identifies the family that originated the miss (`gettext`, `ngettext`,
`pgettext`, `npgettext`); the other arguments go into the metadata
(`#{domain, locale, msgid, function, context}`) with `measurements` `#{count =>
1}`.

Opt-in (overhead policy): the flag `erli18n_telemetry:lookup_telemetry_enabled/0`
is checked FIRST; when OFF the function returns `ok` immediately, without building
the event — the fast path stays a single `application:get_env` (ETS read,
~100ns). Important for multi-tenant: with the flag OFF, the `msgid` (which can be
sensitive) is never exposed in an event. Always returns `ok` (side effect
only).
""".
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

%% =========================
%% Locale fallback chain (Phase 2) — internal, MISS-path only
%% =========================
%%
%% These helpers are reached ONLY from the `_Other ->` (miss) arm of the four
%% lookup families, so they add ZERO cost to an exact hit: on a hit, control
%% returns from the first `case` clause and none of this runs — no config
%% read, no canonicalization, no allocation. The first act on the miss path is
%% the `off` short-circuit (`locale_fallback_mode/0`), so the feature is also
%% free when disabled (the default).

-doc """
Internal helper: resolve a singular lookup MISS through the opt-in fallback
chain. Returns `{ok, Translation}` on a fallback hit (and emits the
`[erli18n, locale, fallback]` event), or `miss` when fallback is disabled
(`locale_fallback = off`) or the whole chain misses.

`Function` is the originating family (for telemetry); `Locale` is the locale
already tried verbatim by the exact lookup (its canonical form is dropped from
the chain head to avoid a redundant catalog read).
""".
-spec fallback_lookup_singular(atom(), domain(), context(), msgid(), locale()) ->
    {ok, translation()} | miss.
fallback_lookup_singular(Function, Domain, Context, Msgid, Locale) ->
    case locale_fallback_mode() of
        off ->
            miss;
        Mode ->
            {Chain, Depth0} = chain_after_exact(fallback_chain_for(Mode, Locale), Locale),
            case resolve_singular(Chain, Domain, Context, Msgid, Depth0) of
                {ok, T, Resolved, Depth} ->
                    emit_locale_fallback(Function, Domain, Locale, Resolved, Context, Depth),
                    {ok, T};
                miss ->
                    miss
            end
    end.

-doc """
Internal helper: the plural-form counterpart of `fallback_lookup_singular/5`.
Walks the same fallback chain but resolves each candidate via
`erli18n_server:lookup_plural_form/5` (each candidate catalog selects the form
by its own compiled `Plural-Forms` rule against `N`).
""".
-spec fallback_lookup_plural(atom(), domain(), context(), msgid(), integer(), locale()) ->
    {ok, translation()} | miss.
fallback_lookup_plural(Function, Domain, Context, Msgid, N, Locale) ->
    case locale_fallback_mode() of
        off ->
            miss;
        Mode ->
            {Chain, Depth0} = chain_after_exact(fallback_chain_for(Mode, Locale), Locale),
            case resolve_plural(Chain, Domain, Context, Msgid, N, Depth0) of
                {ok, T, Resolved, Depth} ->
                    emit_locale_fallback(Function, Domain, Locale, Resolved, Context, Depth),
                    {ok, T};
                miss ->
                    miss
            end
    end.

%% Walk the candidate chain, one catalog read per entry, first non-empty hit
%% wins; `Depth` is the 0-based index of the candidate that hit (telemetry).
-spec resolve_singular([locale()], domain(), context(), msgid(), non_neg_integer()) ->
    {ok, translation(), locale(), non_neg_integer()} | miss.
resolve_singular([], _Domain, _Context, _Msgid, _Depth) ->
    miss;
resolve_singular([Cand | Rest], Domain, Context, Msgid, Depth) ->
    case erli18n_server:lookup_singular(Domain, Cand, Context, Msgid) of
        {ok, T} when T =/= <<>> -> {ok, T, Cand, Depth};
        _ -> resolve_singular(Rest, Domain, Context, Msgid, Depth + 1)
    end.

-spec resolve_plural([locale()], domain(), context(), msgid(), integer(), non_neg_integer()) ->
    {ok, translation(), locale(), non_neg_integer()} | miss.
resolve_plural([], _Domain, _Context, _Msgid, _N, _Depth) ->
    miss;
resolve_plural([Cand | Rest], Domain, Context, Msgid, N, Depth) ->
    case erli18n_server:lookup_plural_form(Domain, Cand, Context, Msgid, N) of
        {ok, T} when T =/= <<>> -> {ok, T, Cand, Depth};
        _ -> resolve_plural(Rest, Domain, Context, Msgid, N, Depth + 1)
    end.

%% Build the candidate chain for the active mode. `fallback_default_locale/0`
%% is the chain floor for both modes; both delegate the bounding/dedup (and the
%% shared `?MAX_CHAIN` cap) to `erli18n_negotiate`.
-spec fallback_chain_for(base_language | {explicit, map()}, locale()) -> [locale(), ...].
fallback_chain_for(base_language, Locale) ->
    erli18n_negotiate:fallback_chain(Locale, fallback_default_locale());
fallback_chain_for({explicit, Map}, Locale) ->
    explicit_chain(Map, Locale, fallback_default_locale()).

%% `{explicit, Map}` mode: for a listed (canonical) locale the chain is the
%% canonicalized override list (built and bounded by `erli18n_negotiate:override_chain/3`,
%% which applies the same `?MAX_CHAIN` cap as every other chain); an unlisted
%% locale falls through to the `base_language` chain (override layer, not
%% allowlist).
-spec explicit_chain(map(), locale(), locale() | undefined) -> [locale(), ...].
explicit_chain(Map, Locale, Default) ->
    Canon = erli18n_negotiate:canonicalize(Locale),
    case maps:get(Canon, Map, undefined) of
        List when is_list(List) ->
            erli18n_negotiate:override_chain(Locale, List, Default);
        _ ->
            erli18n_negotiate:fallback_chain(Locale, Default)
    end.

%% The chain floor for the fallback path. Reads the configured default locale
%% but — unlike `default_locale/0` — does NOT crash on a misconfigured value:
%% enabling the opt-in fallback feature must never turn a lookup MISS (which
%% returned the `msgid` in 0.2.0) into a crash. An invalid default simply
%% yields no floor (`undefined`), and the chain is built without it.
-spec fallback_default_locale() -> locale() | undefined.
fallback_default_locale() ->
    case application:get_env(erli18n, default_locale, ?DEFAULT_LOCALE) of
        Locale when is_binary(Locale) -> Locale;
        _Other -> undefined
    end.

%% The exact lookup already tried `Locale` verbatim and missed. If the chain
%% head equals it (the common already-canonical case), skip that one redundant
%% catalog read by dropping the head — but report the starting telemetry
%% `chain_depth` as 1 (the dropped head was depth 0), so an identical fallback
%% reports the SAME depth whether the request arrived canonical (`pt_BR`) or
%% not (`pt-BR`). Returns `{ChainToWalk, StartDepth}`.
-spec chain_after_exact([locale()], locale()) -> {[locale()], non_neg_integer()}.
chain_after_exact([Locale | Rest], Locale) -> {Rest, 1};
chain_after_exact(Chain, _Locale) -> {Chain, 0}.

-doc """
Internal helper: read the resolved `locale_fallback` mode from app env.

`off` (the default) is the cheapest branch. An invalid stored value is
normalized to `off` (fail-soft) rather than crashing: this read happens on the
lookup miss path of user-facing code, so a misconfiguration must only disable
the new feature, never break translation. (Contrast with `default_locale/0`,
which crashes loudly — there a wrong value cannot be silently substituted.)
""".
-spec locale_fallback_mode() -> off | base_language | {explicit, map()}.
locale_fallback_mode() ->
    case application:get_env(erli18n, locale_fallback, off) of
        off -> off;
        base_language -> base_language;
        {explicit, Map} when is_map(Map) -> {explicit, Map};
        _Other -> off
    end.

-doc """
Internal helper: emits the locale-fallback telemetry event
(`[erli18n, locale, fallback]`) when a non-exact locale resolved a translation
through the fallback chain.

Opt-in under the SAME flag as the lookup-miss event
(`erli18n_telemetry:lookup_telemetry_enabled/0`), checked FIRST so a disabled
flag builds no event. `Depth` is the 0-based position in the chain of the
candidate that hit. Always returns `ok`.
""".
-spec emit_locale_fallback(atom(), domain(), locale(), locale(), context(), non_neg_integer()) ->
    ok.
emit_locale_fallback(Function, Domain, Requested, Resolved, Context, Depth) ->
    case erli18n_telemetry:lookup_telemetry_enabled() of
        false ->
            ok;
        true ->
            erli18n_telemetry:emit(
                erli18n_telemetry:event_locale_fallback(),
                #{count => 1, chain_depth => Depth},
                #{
                    domain => Domain,
                    requested_locale => Requested,
                    resolved_locale => Resolved,
                    function => Function,
                    context => Context
                }
            ),
            ok
    end.
