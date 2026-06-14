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
  directly from protected ETS in the caller's own process; only writes
  (load/reload) go through the owning `gen_server`. There is no process
  bottleneck on the read path.
- **The category is always LC_MESSAGES.** The `d*`/`dc*` variants exist solely
  for NAME parity with C gettext; the category is never a parameter.
- **Graceful degradation.** On a miss (missing catalog, nonexistent entry) or an
  empty translation (`msgstr ""`), the lookup returns the original `msgid` (or
  `msgid_plural` in the plural form, according to `N`). A crash of
  `erli18n_server` (the worker/writer) does **not** empty the catalogs: the ETS
  table is held by a dedicated owner (`erli18n_table_owner`) that is its `heir`,
  so on restart it comes back INTACT via `'ETS-TRANSFER'` and lookups keep
  serving the loaded translations — there is no loss of the caller's process nor
  of the translations (see `erli18n_server` and `erli18n_table_owner`).
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
2> PoPath = erli18n:default_po_path(minha_app, my_domain, <<"fr">>).
"/.../minha_app/priv/locale/fr/LC_MESSAGES/my_domain.po"
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
```

## Key functions

- Lookup: `gettext/3`, `ngettext/5`, `pgettext/4`, `npgettext/6` (the main
  forms; the other arities resolve domain/locale and delegate to these).
- Locale state: `setlocale/1`, `which_locale/0`.
- App defaults: `default_locale/0`, `textdomain/0`.
- Catalog lifecycle: `ensure_loaded/3`, `reload/3`, `unload/2`,
  `default_po_path/3`.
- Observability: `loaded_catalogs/0`, `memory_info/0`, `which_keys/2`.

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
            emit_lookup_miss(gettext, Domain, Locale, undefined, Msgid),
            Msgid
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
            emit_lookup_miss(ngettext, Domain, Locale, undefined, Msgid),
            plural_fallback(Msgid, MsgidPlural, N)
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
            emit_lookup_miss(pgettext, Domain, Locale, Context, Msgid),
            Msgid
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
            emit_lookup_miss(npgettext, Domain, Locale, Context, Msgid),
            plural_fallback(Msgid, MsgidPlural, N)
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
`?GETTEXT_DOMAIN` = `default`).

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
parse, plural-rule compilation, and CLDR validation run before any ETS
insertion; on error the state stays intact.

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
(read/parse/compile) runs without touching ETS and the swap is atomic
(insert-before-prune), so concurrent lookups never see the empty catalog.
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
1> erli18n:default_po_path(minha_app, my_domain, <<"fr">>).
"/.../minha_app/priv/locale/fr/LC_MESSAGES/my_domain.po"
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

- `ets_bytes` — bytes consumed by the ETS table (already converted from VM words
  to bytes; multiplied by `erlang:system_info(wordsize)`).
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
