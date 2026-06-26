-module(erli18n_server).

-moduledoc """
Catalog `gen_server`: the serialized writer of the translation catalogs.

## What it is and which problem it solves

This module is the heart of the erli18n runtime: it loads `.po` catalogs, keeps
the translations live and answers lookups (singular, plural and header). It
reconciles two contradictory requirements: translation reads are extremely hot
(every UI string goes through a lookup) and must be lock-free; writes must be
serialized so two concurrent loaders of the same catalog cannot clobber each
other. The solution is a strict split between the write path (serialized by this
process's mailbox) and the read path (straight from `persistent_term`, with no
roundtrip to the server).

## Storage substrate: persistent_term

Each `{Domain, Locale}` catalog is stored as ONE persistent term (key
`{erli18n_catalog, Domain, Locale}`) holding a map of all its entries plus the
header — see `erli18n_pt_store`. `persistent_term:get/2` returns the term WITHOUT
copying it onto the caller's heap, so reads are copy-free and lock-free (the
benchmark measured ~55% faster than the previous per-row ETS storage). The
trade-off is the write side: installing/erasing a catalog defers a node-wide
literal-area cleanup (a major GC on processes still holding the old catalog plus
an all-process heap scan). erli18n loads catalogs once at boot and rarely
reloads, so this is acceptable — but it is a real cost the old ETS storage did
not have, paid once per `reload/3,4` and `unload/2`.

## Mental model

Three layers:

1. **Read path (hot path, lock-free).** `lookup_singular/4`,
   `lookup_plural_form/5` and `lookup_header/2` read `persistent_term` directly
   in the CALLING process — no message reaches the server. N processes read in
   parallel with no bottleneck. The load-bearing rule: each lookup fetches the
   catalog map fresh and lets it be transient; the map is NEVER cached in a
   long-lived process (a holder forces a major GC on reload and would serve a
   stale catalog).

2. **Write path (serialized).** `insert_*`, `unload/2` and the load commits are
   `gen_server:call`s; `handle_call/3` is the only critical section that mutates
   `persistent_term`. The single mailbox closes the check-then-install race that
   `persistent_term` (which has no compare-and-swap) cannot close on its own,
   and lets a batch load issue its puts back to back.

3. **Load orchestration (heavy work OUTSIDE the mailbox).** `ensure_loaded/4`
   and `reload/4` run the heavy, failable phase (size-check, read, parse, plural
   compile, CLDR divergence, map build) in the CALLING process, producing a pure
   in-memory `staged()` — including the fully-built catalog map. Only this
   validated payload travels to the server for a microsecond-scale commit (a
   single `persistent_term:put`). A large/slow/pathological `.po` from one tenant
   never blocks another's load.

**Trusted vs untrusted.** A `.po`'s `Plural-Forms` rule is untrusted input; it is
compiled with bounds (see `erli18n_plural`), whose `evaluate/2` is total — it
clamps malformed rules instead of raising, so `lookup_plural_form/5` evaluates
them directly. The anti-DoS bounds (`max_bytes`, `max_entries`) reject large
catalogs BEFORE any mutation.

**Durability.** `persistent_term` is owned by the runtime, not by this process,
so a crash of this worker destroys NOTHING: every loaded catalog survives the
restart untouched. The server keeps no catalog data in its `State` (it is `#{}`):
the truth lives entirely in `persistent_term`. Because the terms are node-global
and are NOT cleared on application stop, `erli18n_app:stop/1` erases them on
shutdown (otherwise a stop/start cycle would leak stale catalogs).

## When and how a dev touches this module

- To **load/reload** a `.po`: `ensure_loaded/3,4` (idempotent),
  `reload/3,4` (always reinstalls, atomic) or `ensure_loaded_many/1` (batch).
- To **unload**: `unload/2`.
- To **read** a low-level translation (the `erli18n` façade is the usual
  front-door): `lookup_singular/4`, `lookup_plural_form/5`, `lookup_header/2`.
- To **write** individual entries (tests, non-`.po` sources):
  `insert_singular/5`, `insert_plural/5`, `insert_catalog/3`.
- For **observability**: `memory_info/0`, `loaded_catalogs/0`, `which_keys/2`.

## Quickstart

```erlang
1> application:ensure_all_started(erli18n).
{ok, [erli18n]}
2> Po = erli18n_server:default_po_path(my_app, my_domain, <<"fr">>).
"/.../priv/locale/fr/LC_MESSAGES/my_domain.po"
3> erli18n_server:ensure_loaded(my_domain, <<"fr">>, Po).
{ok, 128}
4> erli18n_server:ensure_loaded(my_domain, <<"fr">>, Po).
{ok, already}
5> erli18n_server:lookup_singular(my_domain, <<"fr">>, undefined, <<"Hello">>).
{ok, <<"Bonjour">>}
6> erli18n_server:lookup_plural_form(my_domain, <<"fr">>, undefined, <<"file">>, 2).
{ok, <<"fichiers">>}
7> erli18n_server:memory_info().
#{ets_bytes => 24576, num_catalogs => 1, num_keys => 131}
```

(`num_keys` counts ALL stored keys, including the header; `loaded_catalogs/0`
counts only the 130 data entries — see both functions.)

## Main entry points

- Load: `ensure_loaded/3`, `ensure_loaded/4`, `ensure_loaded_many/1`,
  `reload/3`, `reload/4`.
- Read (lock-free): `lookup_singular/4`, `lookup_plural_form/5`,
  `lookup_header/2`.
- Write: `insert_singular/5`, `insert_plural/5`, `insert_catalog/3`,
  `unload/2`.
- Observability: `memory_info/0`, `loaded_catalogs/0`, `which_keys/2`.
- Lifecycle / OTP: `start_link/0`, `init/1`.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% eqwalizer suppressions for the `term() -> T' boundary casts below. A
%% gen_server reply (and an `erli18n_telemetry:span/3' result) is specced
%% `term()' because the callback module is resolved at runtime; the cast helpers
%% re-announce a type already proven server-side WITHOUT a runtime
%% `eqwalizer:dynamic_cast/1' call (that helper ships only in the test-only
%% `eqwalizer_support' git dependency Hex cannot package). Full rationale at each
%% function.
-eqwalizer({nowarn_function, cast_ensure_result/1}).
-eqwalizer({nowarn_function, cast_commit_many/1}).

%% Write API (serialized via gen_server — only the server mutates persistent_term).
-export([
    start_link/0,
    insert_singular/5,
    insert_plural/5,
    insert_catalog/3,
    unload/2
]).

%% Read API (direct persistent_term lookup from caller process — lock-free hot
%% path, per RISK-012 anti-bottleneck pattern).
%%
%% Finding #16 (lookup-plural-5-exported-footgun-bypasses-form-evaluation): the
%% plural read is exposed ONLY through the form-aware `lookup_plural_form/5',
%% which evaluates the catalog's compiled `Plural-Forms' rule against the count N
%% before reading the form. There is no exported raw, index-based plural read:
%% exporting one invited callers to pass the count N as the form index and
%% silently get the wrong plural form. The index selection lives inside
%% `erli18n_pt_store:get_plural_form/5'.
-export([
    lookup_singular/4,
    lookup_header/2,
    lookup_plural_form/5
]).

%% Observability (read-only from caller process).
-export([
    memory_info/0,
    loaded_catalogs/0,
    loaded_locales/0,
    which_keys/2
]).

%% Load orchestration: parse .po + compile plural + validate vs CLDR + install
%% atomically. Per BR-MIGRAR-022/029 and RISK-012 this is a serialized write
%% path; idempotency makes the second call cheap.
-export([
    ensure_loaded/3,
    ensure_loaded/4,
    ensure_loaded_many/1,
    reload/3,
    reload/4,
    default_po_path/3
]).

%% gen_server callbacks.
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-type domain() :: atom().
-type locale() :: binary().
-type context() :: undefined | binary().
-type msgid() :: binary().
-type translation() :: binary().
-type plural_index() :: non_neg_integer().
-type plural_entries() :: [{plural_index(), translation()}].
-type msgid_plural() :: undefined | binary().
-type singular_entry() :: {singular, context(), msgid(), translation()}.
%% Finding #14: the parsed plural entry carries the `msgid_plural` form text (4th
%% element). It plays no part in lookup keying and is dropped when the catalog
%% map is built (it exists purely so `erli18n_po:dump/1` round-trips faithfully).
-type plural_entry() ::
    {plural, context(), msgid(), msgid_plural(), plural_entries()}.
-type catalog_entry() :: singular_entry() | plural_entry().

%% Load orchestration types (Part 5).
%%
%% Finding #6 (load-pipeline-serialized-in-gen-server-no-bounds-or-timeout):
%% `opts()` gains resource bounds and a tunable commit timeout. Every field is
%% optional; omitting them preserves the legacy behaviour (modulo the safety-cap
%% defaults). The heavy read+parse+compile+build runs in the CALLING process, so
%% these are the boundary knobs a multi-tenant deployment (ADR-0003) needs:
%%   * `max_bytes`   — reject the file (via `filelib:file_size/1`) BEFORE reading
%%                     it whole into memory. `infinity` = no cap.
%%   * `max_entries` — reject the catalog AFTER the parse if it has more than N
%%                     entries. `infinity` = no cap.
%%   * `timeout`     — timeout of the commit `gen_server:call/3'. The heavy phase
%%                     no longer runs behind the mailbox, so the deadline only
%%                     covers the single `persistent_term:put'.
-doc """
Load options accepted by `ensure_loaded/4`, `reload/4` and each item of
`ensure_loaded_many/1`. All fields are optional; omitting one preserves the
legacy behaviour (modulo the safety-cap defaults).

- `include_fuzzy` (default `false`): includes entries marked `#, fuzzy`.
- `max_bytes` (default `application:get_env(erli18n, max_po_bytes)`, 16 MiB):
  rejects the file BEFORE reading it whole (via `filelib:file_size/1`).
  `infinity` disables the cap.
- `max_entries` (default `application:get_env(erli18n, max_po_entries)`,
  500000): rejects the catalog AFTER the parse if it has more than N entries.
  `infinity` disables the cap.
- `timeout` (default 5000 ms): deadline of the commit `gen_server:call/3`. Since
  the heavy phase no longer runs behind the mailbox, the deadline covers only the
  single `persistent_term:put` (microsecond scale).
""".
-type opts() :: #{
    include_fuzzy => boolean(),
    max_bytes => non_neg_integer() | infinity,
    max_entries => non_neg_integer() | infinity,
    timeout => timeout()
}.
-doc """
Result of a load (`ensure_loaded/3,4`, `reload/3,4`).

- `{ok, NewlyLoaded}`: a real load — number of entries parsed, compiled and
  installed.
- `{ok, already}`: idempotent fast-path, the catalog was already loaded (only
  `ensure_loaded`/`ensure_loaded_many`; `reload` never returns this).
- `{error, ensure_error()}`: structured error; the prior catalog stays intact
  (all errors occur BEFORE any mutation).
""".
-type ensure_result() ::
    {ok, NewlyLoaded :: non_neg_integer()}
    | {ok, already}
    | {error, ensure_error()}.
-doc """
Union of all structured errors a load can return. Each variant maps a failable
step of the stage pipeline (in the order it can fail): an I/O error reading the
file (`{file_error, _}`), a `.po` parse error (`erli18n_po:parse_error()`), a
plural-rule compile error (`{plural_compile_error, _}`) and the anti-DoS caps
(`bound_error()`). None of them leaves a catalog mutated.
""".
-type ensure_error() ::
    erli18n_po:parse_error()
    | {plural_compile_error, erli18n_plural:compile_error()}
    | {file_error, file:posix() | badarg | terminated | system_limit}
    | bound_error()
    | {load_failed, term()}.
%% Finding #6: errors introduced by the resource bounds. A subset of
%% `ensure_error()', surfaced from the caller-side heavy phase BEFORE any
%% mutation (same "errors before mutation" ordering the load pipeline always had).
-doc """
Errors from the anti-DoS bounds (finding #6), a subset of `ensure_error()`.
Both are surfaced in the CALLER's heavy phase, BEFORE any mutation:
`input_too_large` when the file size exceeds `max_bytes` (checked without reading
the bytes, via `filelib:file_size/1`); `too_many_entries` when the post-parse
count exceeds `max_entries`. The second element is the observed value, the third
is the configured limit.
""".
-type bound_error() ::
    {input_too_large, Bytes :: non_neg_integer(), Limit :: non_neg_integer()}
    | {too_many_entries, Count :: non_neg_integer(), Limit :: non_neg_integer()}.
%% Finding #6: a single catalog to load in the bulk API. Same positional shape as
%% the `ensure_loaded/4' arguments.
-doc """
A catalog to load in the bulk API `ensure_loaded_many/1`. Same positional shape
as the `ensure_loaded/4` arguments: `{Domain, Locale, PoPath, Opts}`.
""".
-type load_spec() :: {domain(), locale(), file:filename(), opts()}.
-type divergence_info() ::
    none
    | {plural_divergence, binary(), binary()}.
-doc """
Header state of a loaded catalog, returned by `lookup_header/2` and stored under
the catalog map's `'$header'` key. The PRESENCE of the header is the idempotency
signal used by `ensure_loaded/3` ("catalog already loaded").

- `plural`: the ALREADY compiled `Plural-Forms` rule
  (`erli18n_plural:plural_compiled()`), or the atom `fallback` when the `.po`
  came without a plural header (the lookup then uses the C/Germanic default, see
  `lookup_plural_form/5`).
- `plural_raw`: the raw text of the rule (or the fallback rule) for
  observability/round-trip.
- `po_path`: the path of the source `.po`.
- `loaded_at`: `erlang:system_time(millisecond)` at the moment of the load.
- `divergence`: `divergence_info()` — `none` or the vs-CLDR divergence warning.
- `fuzzy_included`: whether the load included `#, fuzzy` entries.
- `num_entries`: entry count (singular + plural aggregated as the parser counts
  them), the number reported in `{ok, NewlyLoaded}`.
""".
-type header_state() :: #{
    plural := erli18n_plural:plural_compiled() | fallback,
    plural_raw := binary(),
    po_path := file:filename(),
    loaded_at := integer(),
    divergence := divergence_info(),
    fuzzy_included := boolean(),
    num_entries := non_neg_integer()
}.

%% Finding #4 (reload-not-atomic-destroys-catalog-and-empty-window) +
%% Finding #6: the product of the pure, failable half of the load pipeline (read
%% + parse + compile + divergence + map build). A `staged/0' is built WITHOUT
%% touching `persistent_term', entirely in the CALLING process, so any error
%% leaves the prior catalog intact. The commit then performs the only observable
%% mutation as a single whole-catalog `persistent_term:put'. `map' is the
%% ready-to-install catalog map (data entries + header); `num_entries' is the
%% count reported back to the caller; `fuzzy_skipped' is the caller-precomputed
%% telemetry count (no re-parse on the server).
-type staged() :: #{
    map := erli18n_pt_store:catalog_map(),
    divergence := divergence_info(),
    domain := domain(),
    locale := locale(),
    num_entries := non_neg_integer(),
    fuzzy_skipped := non_neg_integer()
}.

-export_type([
    domain/0,
    locale/0,
    context/0,
    msgid/0,
    translation/0,
    plural_index/0,
    plural_entries/0,
    singular_entry/0,
    plural_entry/0,
    catalog_entry/0,
    opts/0,
    ensure_result/0,
    ensure_error/0,
    bound_error/0,
    load_spec/0,
    divergence_info/0,
    header_state/0
]).

%% =========================
%% Public API
%% =========================

-doc """
Starts the catalog `gen_server`, registered locally as `erli18n_server`.

Called by the supervisor — in general you do NOT call this by hand. The server
holds NO catalog data in its state (the catalogs live in `persistent_term`), so
`init/1` is trivial and a crash of this worker loses nothing.

```erlang
1> {ok, Pid} = erli18n_server:start_link().
{ok, <0.123.0>}
2> is_pid(Pid).
true
```

See also `init/1`.
""".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Inserts/overwrites a singular translation, serialized by the server.

Low-level write API — to load entire `.po` files prefer `ensure_loaded/3`.
Useful in tests or when feeding translations from a source other than `.po`.

## Parameters
- `Domain`: the catalog's gettext domain (atom).
- `Locale`: the binary locale (e.g. `<<"fr">>`).
- `Context`: the `msgctxt`, or `undefined` when absent.
- `Msgid`: the source text (lookup key).
- `Translation`: the translation to store.

## Return and effects
Merges the entry `{singular, Context, Msgid} => Translation` into the catalog
map for `{Domain, Locale}` (creating the catalog if absent, preserving an
existing header). Synchronous; always returns `ok`. Overwrites any prior
translation for the same key. Does NOT install a header — this entry is readable
via `lookup_singular/4`, but the catalog will not have `lookup_header/2` unless an
`ensure_loaded/3` installs one.

## Failure modes
Arguments outside the guards (e.g. a non-atom `Domain`) crash with
`function_clause` in the caller. A server reply other than `ok` crashes with
`badmatch` (contract break — only `handle_call/3` writes that reply).

```erlang
1> erli18n_server:insert_singular(my_domain, <<"fr">>, undefined, <<"Hello">>, <<"Bonjour">>).
ok
2> erli18n_server:lookup_singular(my_domain, <<"fr">>, undefined, <<"Hello">>).
{ok, <<"Bonjour">>}
```

See also `insert_plural/5`, `insert_catalog/3`, `lookup_singular/4`.
""".
-spec insert_singular(domain(), locale(), context(), msgid(), translation()) -> ok.
insert_singular(Domain, Locale, Context, Msgid, Translation) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(Translation)
->
    %% `gen_server:call/2` is typed `term()`. We pattern-match `ok` so the
    %% public contract is enforced: the matching `handle_call/3` clause is the
    %% only writer of this reply and always returns `{reply, ok, State}`, so any
    %% other shape is a contract break and should crash with badmatch.
    ok = gen_server:call(
        ?MODULE,
        {insert_singular, Domain, Locale, Context, Msgid, Translation}
    ).

-doc """
Inserts/overwrites the plural forms of a `Msgid`, serialized by the server.

## Parameters
- `Domain`, `Locale`, `Context`, `Msgid`: as in `insert_singular/5`.
- `Entries`: the list `[{FormIndex, Translation}]` — one plural form per pair,
  where `FormIndex` is the form index (0 = gettext singular, 1, 2, ...).

## Return and effects
Merges one entry per form, `{plural, Context, Msgid, FormIndex} => Translation`,
into the catalog map. Synchronous; always returns `ok`. **An empty list is a
no-op**: it stores nothing AND does not create the catalog. Selecting the
correct form at read time (evaluating `Plural-Forms` against `N`) is the
responsibility of `lookup_plural_form/5`, NOT of this function: here you supply
the raw indices.

## Failure modes
Arguments outside the guards crash with `function_clause`. Each pair must have an
integer `FormIndex` >= 0; a negative or non-integer index crashes the server
(loud contract, via `erli18n_pt_store`).

The forms are immediately readable via a direct read, but `lookup_plural_form/5`
only SELECTS a form when the `(Domain, Locale)` catalog header is already loaded
(it reads the header first to obtain the `Plural-Forms` rule; without a header it
returns `undefined`). `insert_plural/5` does NOT install any header.

```erlang
1> erli18n_server:insert_plural(my_domain, <<"fr">>, undefined, <<"file">>,
..    [{0, <<"fichier">>}, {1, <<"fichiers">>}]).
ok
%% Without a header, lookup_plural_form/5 is a miss:
2> erli18n_server:lookup_plural_form(my_domain, <<"fr">>, undefined, <<"file">>, 1).
undefined
```

See also `insert_singular/5`, `lookup_plural_form/5`, `ensure_loaded/3`.
""".
-spec insert_plural(domain(), locale(), context(), msgid(), plural_entries()) -> ok.
insert_plural(Domain, Locale, Context, Msgid, Entries) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_list(Entries)
->
    ok = gen_server:call(
        ?MODULE,
        {insert_plural, Domain, Locale, Context, Msgid, Entries}
    ).

-doc """
Inserts a batch of entries (singular and plural) of a catalog in one write.

## Parameters
- `Domain`, `Locale`: the target catalog.
- `Entries`: a list mixing `{singular, Context, Msgid, Translation}` and
  `{plural, Context, Msgid, MsgidPlural, [{Index, Translation}]}`. The
  `MsgidPlural` is preserved in the parsed format for `dump/1` round-trips, but
  plays no part in lookup keying (finding #14).

## Return and effects
Each entry is merged into the catalog map (one key per plural form). Synchronous;
always returns `ok`. **Does NOT install the catalog header** — for the full
pipeline (`.po` parse + plural compile + header) use `ensure_loaded/3`. Without a
header, `lookup_plural_form/5` returns `undefined`; use this function for seeding
singular data or in tests.

## Failure modes
A non-atom `Domain` / non-binary `Locale` / non-list `Entries` crash with
`function_clause`. An entry with an unknown tag crashes the server.

```erlang
1> erli18n_server:insert_catalog(my_domain, <<"fr">>, [
..    {singular, undefined, <<"Hello">>, <<"Bonjour">>},
..    {plural, undefined, <<"file">>, <<"files">>, [{0, <<"fichier">>}, {1, <<"fichiers">>}]}
.. ]).
ok
2> erli18n_server:lookup_singular(my_domain, <<"fr">>, undefined, <<"Hello">>).
{ok, <<"Bonjour">>}
```

See also `insert_singular/5`, `insert_plural/5`, `ensure_loaded/3`.
""".
-spec insert_catalog(domain(), locale(), [catalog_entry()]) -> ok.
insert_catalog(Domain, Locale, Entries) when
    is_atom(Domain), is_binary(Locale), is_list(Entries)
->
    ok = gen_server:call(?MODULE, {insert_catalog, Domain, Locale, Entries}).

-doc """
Removes the `(Domain, Locale)` catalog entirely (entries + header).

## Return and effects
Erases the catalog's single persistent term in O(1). After the unload, `lookup_*`
of that catalog returns `undefined`. Synchronous; always returns `ok`.

**Idempotent**: unloading a never-loaded catalog is a no-op (also returns `ok`).
Emits the telemetry span `[erli18n, catalog, unload]` whose stop metadata
includes `result` (`ok` | `not_loaded`) and `keys_removed`.

The erase defers a node-wide `persistent_term` literal-area cleanup (a major GC
on processes holding the old catalog plus an all-process heap scan) — paid once,
acceptable for the admin-frequency unload but documented honestly.

## Failure modes
A non-atom `Domain` / non-binary `Locale` crash with `function_clause`.

```erlang
1> erli18n_server:ensure_loaded(my_domain, <<"fr">>, "fr.po").
{ok, 128}
2> erli18n_server:unload(my_domain, <<"fr">>).
ok
3> erli18n_server:lookup_header(my_domain, <<"fr">>).
undefined
4> erli18n_server:unload(my_domain, <<"fr">>).   %% idempotent
ok
```

See also `reload/3`, `loaded_catalogs/0`.
""".
-spec unload(domain(), locale()) -> ok.
unload(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    ok = gen_server:call(?MODULE, {unload, Domain, Locale}).

%% Finding #16: guarded so a malformed argument is a loud `function_clause' (a
%% contract break) rather than a silent `undefined' miss — consistent with
%% `lookup_plural_form/5'.
-doc """
Lock-free lookup of a singular translation, straight from `persistent_term`.

The singular read hot path: a single `persistent_term:get/2` + map lookup, with
no roundtrip to the `gen_server`, executed in the calling process (that is why N
processes read in parallel with no bottleneck). The fetched catalog map is
transient — never cache it.

## Parameters
- `Domain`, `Locale`: the catalog.
- `Context`: the `msgctxt`, or `undefined`. A lookup with the wrong `Context` is
  a miss — `msgctxt` is part of the key.
- `Msgid`: the source text being looked up.

## Return
- `{ok, Translation}` if the entry exists.
- `undefined` on a miss (absent catalog or absent key) — it is up to the caller
  (the `erli18n` façade) to apply the fallback to the raw `Msgid`. There is no
  automatic fallback here.

## Failure modes
Arguments outside the guards are `function_clause` (contract break, LOUD
failure), never a silent `undefined` (finding #16).

```erlang
1> erli18n_server:insert_singular(my_domain, <<"fr">>, undefined, <<"Hello">>, <<"Bonjour">>).
ok
2> erli18n_server:lookup_singular(my_domain, <<"fr">>, undefined, <<"Hello">>).
{ok, <<"Bonjour">>}
3> erli18n_server:lookup_singular(my_domain, <<"fr">>, undefined, <<"Missing">>).
undefined
```

See also `lookup_plural_form/5`, `lookup_header/2`.
""".
-spec lookup_singular(domain(), locale(), context(), msgid()) ->
    {ok, translation()} | undefined.
lookup_singular(Domain, Locale, Context, Msgid) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid)
->
    erli18n_pt_store:get_singular(Domain, Locale, Context, Msgid).

-doc """
Lock-free lookup of the `(Domain, Locale)` catalog header, straight from
`persistent_term`.

## Return
- `{ok, HeaderState}` — see `header_state()` for the contents (compiled plural
  rule or `fallback`, raw `Plural-Forms`, `.po` path, load instant, vs-CLDR
  divergence, entry count).
- `undefined` if the catalog is not loaded (or was populated only by `insert_*`).

## Why this matters
The PRESENCE of the header is the idempotency signal `ensure_loaded/3` consults
and what `lookup_plural_form/5` reads first to obtain the plural rule.

## Failure modes
A non-atom `Domain` / non-binary `Locale` crash with `function_clause`.

```erlang
1> erli18n_server:ensure_loaded(my_domain, <<"fr">>, "fr.po").
{ok, 128}
2> {ok, H} = erli18n_server:lookup_header(my_domain, <<"fr">>), maps:get(num_entries, H).
128
3> erli18n_server:lookup_header(my_domain, <<"de">>).
undefined
```

See also `lookup_singular/4`, `lookup_plural_form/5`, `header_state()`.
""".
-spec lookup_header(domain(), locale()) -> {ok, header_state()} | undefined.
lookup_header(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    erli18n_pt_store:lookup_header(Domain, Locale).

-doc """
The CORRECT entry point for plural reads (form-aware, lock-free).

The caller does NOT need to know the form index for `N`: this function reads the
header, evaluates the catalog's compiled `Plural-Forms` rule against the count
`N` to obtain the form index, and then reads the entry at that index. It is the
encapsulation of the locale-specific knowledge the library exists to provide.

## Parameters
- `Domain`, `Locale`, `Context`, `Msgid`: identify the plural msgid.
- `N`: the count (integer) that decides the form. NOT the form index — the
  `Plural-Forms` rule converts it into an index.

## Return
- `{ok, Translation}` when the form exists.
- `undefined` on a miss — it is up to the caller to fall back to `msgid_plural`
  (PSD-003).

## Fallback rules (order matters)
- **Header absent** (catalog not loaded, or populated only by `insert_*`)
  -> `undefined` directly.
- **Header present without `Plural-Forms`** (`plural := fallback`) -> uses the
  C/Germanic default (`N == 1 -> form 0; otherwise form 1`).
- **Header with a compiled rule** -> evaluates the rule. `erli18n_plural:evaluate/2`
  is total (it clamps malformed rules instead of crashing), so the form index is
  computed directly — no per-request `try` on this hot path (finding #1).

## Failure modes
A non-integer `N` (or other args outside the guards) is `function_clause`.

```erlang
1> erli18n_server:lookup_plural_form(my_domain, <<"fr">>, undefined, <<"file">>, 1).
{ok, <<"fichier">>}
2> erli18n_server:lookup_plural_form(my_domain, <<"fr">>, undefined, <<"file">>, 42).
{ok, <<"fichiers">>}
3> erli18n_server:lookup_plural_form(my_domain, <<"de">>, undefined, <<"file">>, 1).
undefined
```

See also `lookup_singular/4`, `lookup_header/2`.
""".
-spec lookup_plural_form(
    domain(),
    locale(),
    context(),
    msgid(),
    integer()
) ->
    {ok, translation()} | undefined.
lookup_plural_form(Domain, Locale, Context, Msgid, N) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_integer(N)
->
    erli18n_pt_store:get_plural_form(Domain, Locale, Context, Msgid, N).

-doc """
Returns the memory usage of the loaded catalogs.

Observability read in the calling process; not a hot path (do not call it per
request — it scans the node's persistent terms). Returns a map with:
- `ets_bytes`: the catalogs' approximate storage in bytes. **The field name is
  historical** (storage is now `persistent_term`, not ETS); it is kept for
  backwards compatibility with the 0.3.0 return shape.
- `num_catalogs`: distinct loaded catalogs that have >=1 data entry (a
  header-only `.po` does not count).
- `num_keys`: total stored keys across all catalogs, INCLUDING each catalog's
  header. So for a single catalog with 130 data entries + 1 header,
  `num_keys = 131`.

```erlang
1> erli18n_server:memory_info().
#{ets_bytes => 24576, num_catalogs => 1, num_keys => 131}
```

See also `loaded_catalogs/0`, `which_keys/2`.
""".
-spec memory_info() ->
    #{
        ets_bytes := non_neg_integer(),
        num_catalogs := non_neg_integer(),
        num_keys := non_neg_integer()
    }.
memory_info() ->
    Catalogs = erli18n_pt_store:all(),
    #{
        ets_bytes => sum_nonneg([erli18n_pt_store:storage_bytes(M) || {_D, _L, M} <- Catalogs]),
        num_keys => sum_nonneg([erli18n_pt_store:key_count(M) || {_D, _L, M} <- Catalogs]),
        num_catalogs =>
            length([yes || {_D, _L, M} <- Catalogs, erli18n_pt_store:data_count(M) > 0])
    }.

%% Total a list of non-negative integers, narrowing the accumulator back to
%% `non_neg_integer()' at the boundary (integer `+' widens to `integer()' under
%% eqwalizer; the guarded clause re-pins the proven non-negativity).
-spec sum_nonneg([non_neg_integer()]) -> non_neg_integer().
sum_nonneg(Ns) ->
    case sum_nonneg(Ns, 0) of
        N when is_integer(N), N >= 0 -> N
    end.

-spec sum_nonneg([non_neg_integer()], non_neg_integer()) -> integer().
sum_nonneg([], Acc) ->
    Acc;
sum_nonneg([N | Rest], Acc) ->
    sum_nonneg(Rest, Acc + N).

-doc """
Lists the loaded catalogs with the data-entry count of each.

Returns `[{Domain, Locale, NumEntries}]`, where `NumEntries` counts the data
entries (singulars + EACH plural form counted separately; the header does NOT
count — that is why this number differs from `header_state()`.`num_entries`,
which counts logical entries). The list order is unspecified. Only catalogs with
>=1 data entry appear (a header-only `.po` is omitted).

```erlang
1> erli18n_server:ensure_loaded(my_domain, <<"fr">>, "fr.po").
{ok, 128}
2> erli18n_server:loaded_catalogs().
[{my_domain, <<"fr">>, 130}]
```

See also `memory_info/0`, `which_keys/2`.
""".
-spec loaded_catalogs() -> [{domain(), locale(), non_neg_integer()}].
loaded_catalogs() ->
    [
        {D, L, erli18n_pt_store:data_count(M)}
     || {D, L, M} <- erli18n_pt_store:all(), erli18n_pt_store:data_count(M) > 0
    ].

-doc """
The sorted, distinct locales across all loaded catalogs — the locale projection
of `loaded_catalogs/0`. Backed by the loaded-catalog index: ONE keyed,
copy-free `persistent_term` read plus a `usort`, NOT a node-wide scan, so it is
cheap enough for the per-request locale-negotiation default path.

See also `loaded_catalogs/0`.
""".
-spec loaded_locales() -> [locale()].
loaded_locales() ->
    erli18n_pt_store:loaded_locales().

-doc """
Enumerates the keys (singular and plural) loaded for `(Domain, Locale)`.

Returns a SORTED list of `{singular, Context, Msgid}` and
`{plural, Context, Msgid}`. Plural entries are DEDUPLICATED by
`(Context, Msgid)`: a plural msgid with N forms appears ONCE, not N times.
Absent catalog -> empty list. Observability, not a hot path.

```erlang
1> erli18n_server:insert_singular(d, <<"fr">>, undefined, <<"Hello">>, <<"Bonjour">>).
ok
2> erli18n_server:insert_plural(d, <<"fr">>, undefined, <<"file">>,
..    [{0, <<"fichier">>}, {1, <<"fichiers">>}]).
ok
3> erli18n_server:which_keys(d, <<"fr">>).
[{plural, undefined, <<"file">>}, {singular, undefined, <<"Hello">>}]
```

See also `loaded_catalogs/0`, `memory_info/0`.
""".
-spec which_keys(domain(), locale()) ->
    [{singular, context(), msgid()} | {plural, context(), msgid()}].
which_keys(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    case erli18n_pt_store:get_map(Domain, Locale) of
        undefined ->
            [];
        Map ->
            {Singulars, PluralSet} =
                split_data_keys(
                    erli18n_pt_store:data_keys(Map), [], sets:new([{version, 2}])
                ),
            Plurals = plural_set_to_list(PluralSet),
            sort_keys(Singulars, Plurals)
    end.

%% Split a catalog's data keys into the singular list and the deduplicated plural
%% set (collapsing a multi-form plural msgid to one `{Context, Msgid}').
-spec split_data_keys(
    [erli18n_pt_store:data_key()],
    [{singular, context(), msgid()}],
    sets:set({context(), msgid()})
) -> {[{singular, context(), msgid()}], sets:set({context(), msgid()})}.
split_data_keys([], Singulars, PluralSet) ->
    {Singulars, PluralSet};
split_data_keys([{singular, Ctx, Msgid} | Rest], Singulars, PluralSet) ->
    split_data_keys(Rest, [{singular, Ctx, Msgid} | Singulars], PluralSet);
split_data_keys([{plural, Ctx, Msgid, _Idx} | Rest], Singulars, PluralSet) ->
    split_data_keys(Rest, Singulars, sets:add_element({Ctx, Msgid}, PluralSet)).

-type key_entry() ::
    {singular, context(), msgid()} | {plural, context(), msgid()}.

-spec sort_keys(
    [{singular, context(), msgid()}],
    [{plural, context(), msgid()}]
) -> [key_entry()].
sort_keys(Singulars, Plurals) ->
    %% `lists:sort/1,2' is specced `[T] -> [T]' but eqwalizer's solver drops the
    %% T binding when T is a union of tuple shapes. A hand-rolled merge sort over
    %% the union type carries the precise type through and is acceptable here
    %% because `which_keys/2' is an observability call, not a hot path.
    Combined = combine_keys(Singulars, Plurals),
    merge_sort(Combined).

-spec merge_sort([key_entry()]) -> [key_entry()].
merge_sort([]) ->
    [];
merge_sort([X]) ->
    [X];
merge_sort(List) ->
    {Left, Right} = split_in_half(List, [], []),
    merge_sorted(merge_sort(Left), merge_sort(Right)).

-spec split_in_half(
    [key_entry()],
    [key_entry()],
    [key_entry()]
) -> {[key_entry()], [key_entry()]}.
split_in_half([], L, R) -> {L, R};
split_in_half([X], L, R) -> {[X | L], R};
split_in_half([X, Y | Rest], L, R) -> split_in_half(Rest, [X | L], [Y | R]).

-spec merge_sorted([key_entry()], [key_entry()]) -> [key_entry()].
merge_sorted([], B) ->
    B;
merge_sorted(A, []) ->
    A;
merge_sorted([Ah | At], [Bh | Bt]) ->
    case Ah =< Bh of
        true -> [Ah | merge_sorted(At, [Bh | Bt])];
        false -> [Bh | merge_sorted([Ah | At], Bt)]
    end.

-spec combine_keys(
    [{singular, context(), msgid()}],
    [{plural, context(), msgid()}]
) -> [{singular, context(), msgid()} | {plural, context(), msgid()}].
combine_keys([], Plurals) ->
    Plurals;
combine_keys([S | Rest], Plurals) ->
    [S | combine_keys(Rest, Plurals)].

%% Materialize the plural set into a precisely-typed list. `sets:to_list/1' has a
%% generic spec eqwalizer can fail to instantiate when the result flows into a
%% heterogeneous context (mixed singular/plural tuples into the sort). Doing the
%% conversion in a helper with an explicit spec is the idiomatic narrow.
-spec plural_set_to_list(sets:set({context(), msgid()})) ->
    [{plural, context(), msgid()}].
plural_set_to_list(Set) ->
    sets:fold(
        fun({C, M}, Acc) -> [{plural, C, M} | Acc] end,
        [],
        Set
    ).

%% =========================
%% Load orchestration (Part 5)
%% =========================

-doc """
Idempotent load of a `.po` catalog. Same as `ensure_loaded/4` with `#{}`.

If `(Domain, Locale)` is already loaded (header present), returns
`{ok, already}` without touching disk. Otherwise it runs the full pipeline (read
file, parse, compile the plural rule, validate against CLDR as a WARNING —
divergence never blocks the load, install in `persistent_term`) and returns
`{ok, NewlyLoaded}`, or `{error, ensure_error()}` leaving any prior catalog
INTACT.

```erlang
1> erli18n_server:ensure_loaded(my_domain, <<"fr">>, "priv/locale/fr/LC_MESSAGES/my_domain.po").
{ok, 128}
2> erli18n_server:ensure_loaded(my_domain, <<"fr">>, "priv/locale/fr/LC_MESSAGES/my_domain.po").
{ok, already}
3> erli18n_server:ensure_loaded(my_domain, <<"fr">>, "/no/such/file.po").
{error, {file_error, enoent}}
```

See `ensure_loaded/4` (options and bounds), `reload/3` (forces reinstall),
`ensure_loaded_many/1` (batch).
""".
-spec ensure_loaded(domain(), locale(), file:filename()) -> ensure_result().
ensure_loaded(Domain, Locale, PoPath) ->
    ensure_loaded(Domain, Locale, PoPath, #{}).

%% Finding #6: the heavy half (read+parse+compile+validate+bounds+map build) runs
%% in the CALLING process inside the `[erli18n, catalog, load]' span, so the
%% measurement is per-tenant and OUTSIDE the server mailbox. Only the validated
%% payload is handed to the server for the microsecond commit, with a
%% caller-tunable timeout. The idempotent fast-path stays a pure read (no disk,
%% no server roundtrip).
-doc """
Idempotent load of a `.po` catalog with resource options.

Idempotent fast-path: if the catalog is already loaded, returns `{ok, already}`
via a pure read (no disk, no server roundtrip). On a miss, the heavy phase
(read+parse+compile+validate+bounds+map build) runs in the CALLING process,
inside the span `[erli18n, catalog, load]`, and only the validated payload is
handed to the server for the microsecond commit.

`Opts` (all optional):
- `include_fuzzy` (default `false`): includes entries marked `#, fuzzy`.
- `max_bytes` (`non_neg_integer() | infinity`): rejects the file BEFORE reading
  it whole (via `filelib:file_size/1`); default `application:get_env(erli18n,
  max_po_bytes)` (16 MiB). `infinity` = no cap.
- `max_entries` (`non_neg_integer() | infinity`): rejects the catalog AFTER the
  parse if it has more than N entries; default `application:get_env(erli18n,
  max_po_entries)` (500000). `infinity` = no cap.
- `timeout` (`timeout()`): deadline of the commit `gen_server:call/3` (default
  5000 ms; the commit is a single `persistent_term:put`).

Returns `{ok, NewlyLoaded}`, `{ok, already}` or `{error, ensure_error()}`
(including `{input_too_large, _, _}` / `{too_many_entries, _, _}`), always before
any mutation.

## Edge cases
- **Check-then-install race**: the idempotent fast-path reads outside the
  serialization, but the commit RE-CHECKS idempotency under the mailbox (mode
  `ensure`), so two concurrent callers of the same catalog do not overwrite each
  other — the second sees `{ok, already}`.
- **CLDR divergence**: never an error; emits a warning log/telemetry and
  proceeds, storing the divergence in the `header_state()`.

```erlang
1> erli18n_server:ensure_loaded(my_domain, <<"fr">>, "fr.po", #{include_fuzzy => true}).
{ok, 131}
2> erli18n_server:ensure_loaded(my_domain, <<"de">>, "big.po", #{max_bytes => 1024}).
{error, {input_too_large, 6553600, 1024}}
```

See `ensure_loaded/3`, `reload/4`, `ensure_loaded_many/1`, `opts()`,
`ensure_error()`.
""".
-spec ensure_loaded(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
ensure_loaded(Domain, Locale, PoPath, Opts) when
    is_atom(Domain), is_binary(Locale), is_map(Opts)
->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    StartMeta = #{
        domain => Domain,
        locale => Locale,
        language => lc_messages,
        po_path => to_binary_path(PoPath),
        fuzzy_included => IncludeFuzzy
    },
    %% `erli18n_telemetry:span/3' is specced `span_result() = term()' — it returns
    %% the first element of the closure tuple, which is always our
    %% `ensure_result()' (proven at the origin: `do_ensure_loaded/4' has a
    %% precise `-spec'). Re-announce that type at the boundary with one typed cast
    %% (findings #12/#18).
    cast_ensure_result(
        erli18n_telemetry:span(
            erli18n_telemetry:event_catalog_load(),
            StartMeta,
            fun() ->
                Inner = do_ensure_loaded(Domain, Locale, PoPath, Opts),
                {Inner, maps:merge(StartMeta, load_stop_metadata(Inner))}
            end
        )
    ).

%% Idempotent fast-path (RISK-012 mitigation 2): a pure read, no disk, no server
%% roundtrip. On a miss the heavy phase (`stage_catalog/4') runs in this process
%% and only the validated payload is committed.
-spec do_ensure_loaded(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
do_ensure_loaded(Domain, Locale, PoPath, Opts) ->
    case lookup_header(Domain, Locale) of
        {ok, _} ->
            {ok, already};
        undefined ->
            case stage_catalog(Domain, Locale, PoPath, Opts) of
                {error, _} = E ->
                    E;
                {ok, Staged} ->
                    %% Mode `ensure': the server re-checks idempotency under
                    %% serialization, closing the check-then-install race between
                    %% two concurrent callers of the same catalog.
                    commit_call({commit, ensure, Domain, Locale, Staged}, Opts)
            end
    end.

%% Reload bypasses the idempotency check: always parses and re-installs.
%% Resolves AMB-001 overwrite semantics.
%%
%% Finding #4 (reload-not-atomic-destroys-catalog-and-empty-window): reload is
%% STAGE -> ATOMIC-INSTALL. The entire failable pipeline (read, parse, plural
%% compile, CLDR divergence, map build) runs into an in-memory `staged/0' WITHOUT
%% touching `persistent_term', so a reload whose new `.po' is invalid returns a
%% structured `{error, _}' and leaves the previously-good catalog FULLY INTACT.
%% On success the only mutation is a single whole-catalog `persistent_term:put':
%% a concurrent reader sees either the entire old catalog or the entire new one,
%% never a half-applied state — atomicity stronger than the old per-row swap.
-doc """
Atomic reload of a `.po` catalog. Same as `reload/4` with `#{}`.

Unlike `ensure_loaded/3`, it NEVER takes the idempotent fast-path: it always
parses and reinstalls, replacing the old catalog wholesale (AMB-001). It never
returns `{ok, already}`. See `reload/4` for the atomic STAGE -> INSTALL
semantics.

```erlang
1> erli18n_server:reload(my_domain, <<"fr">>, "fr.po").
{ok, 128}
%% An invalid .po does NOT destroy the good catalog in use:
2> erli18n_server:reload(my_domain, <<"fr">>, "broken.po").
{error, {parse_error, ...}}
3> erli18n_server:lookup_singular(my_domain, <<"fr">>, undefined, <<"Hello">>).
{ok, <<"Bonjour">>}
```

See `reload/4`, `ensure_loaded/3`.
""".
-spec reload(domain(), locale(), file:filename()) -> ensure_result().
reload(Domain, Locale, PoPath) ->
    reload(Domain, Locale, PoPath, #{}).

%% Finding #6: like `ensure_loaded/4', the heavy STAGE runs in the caller inside
%% the `[erli18n, catalog, reload]' span; only the atomic INSTALL commit travels
%% to the server with a tunable timeout. reload never takes the idempotent
%% fast-path: it always re-stages and re-installs.
-doc """
Atomic reload of a `.po` catalog with resource options (STAGE -> INSTALL).

The entire failable half (read, parse, compile plural, CLDR divergence, map
build) runs in the CALLING process into an in-memory `staged/0` WITHOUT touching
`persistent_term`, so a reload whose new `.po` is invalid returns a structured
`{error, _}` and leaves the previous catalog FULLY INTACT. On success, the only
mutation is a single whole-catalog `persistent_term:put` — a concurrent reader
sees the entire old or the entire new catalog, never a gap.

The heavy phase runs inside the span `[erli18n, catalog, reload]`; only the
install commit travels to the server, with a tunable `timeout`. `Opts` is
identical to `ensure_loaded/4`'s. Returns `{ok, NewlyLoaded}` or
`{error, ensure_error()}` (never `{ok, already}`).

## Edge cases
- The install defers a node-wide `persistent_term` literal-area cleanup (a major
  GC on processes holding the old catalog plus an all-process heap scan) — the
  reload cost the old per-row ETS storage did not have. Paid once per reload;
  negligible for the load-once workload erli18n targets.
- The same `bound_error()`s as `ensure_loaded/4` apply; on any error the previous
  catalog stays intact.

```erlang
1> erli18n_server:reload(my_domain, <<"fr">>, "fr.po", #{timeout => 30000}).
{ok, 128}
```

See `reload/3`, `ensure_loaded/4`, `opts()`.
""".
-spec reload(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
reload(Domain, Locale, PoPath, Opts) when
    is_atom(Domain), is_binary(Locale), is_map(Opts)
->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    StartMeta = #{
        domain => Domain,
        locale => Locale,
        language => lc_messages,
        po_path => to_binary_path(PoPath),
        fuzzy_included => IncludeFuzzy
    },
    %% See `ensure_loaded/4': re-announce the `span_result() = term()' as
    %% `ensure_result()' at the boundary with one typed cast.
    cast_ensure_result(
        erli18n_telemetry:span(
            erli18n_telemetry:event_catalog_reload(),
            StartMeta,
            fun() ->
                Inner =
                    case stage_catalog(Domain, Locale, PoPath, Opts) of
                        {error, _} = E ->
                            E;
                        {ok, Staged} ->
                            commit_call(
                                {commit, reload, Domain, Locale, Staged}, Opts
                            )
                    end,
                {Inner, maps:merge(StartMeta, load_stop_metadata(Inner))}
            end
        )
    ).

%% Hand the validated payload to the server and narrow the reply. The commit is a
%% single `persistent_term:put', so the default 5000ms is generous; the override
%% exists for deployments that want it tighter or `infinity'.
-spec commit_call(commit_msg(), opts()) -> ensure_result().
commit_call(Msg, Opts) ->
    Timeout = maps:get(timeout, Opts, 5000),
    cast_ensure_result(gen_server:call(?MODULE, Msg, Timeout)).

-type commit_msg() ::
    {commit, ensure | reload, domain(), locale(), staged()}.

%% Finding #6, bulk API. Load N catalogs: the heavy phase of each runs in THIS
%% process (sequential prepare — the v0.1 trade-off; a parallel fan-out is a
%% future evolution), and every ready-to-install payload is delivered in a SINGLE
%% commit. That collapses N server roundtrips into one. Already-loaded or failing
%% catalogs are reported individually; one catalog's error never blocks the
%% others.
-doc """
Bulk load of N catalogs with a single commit on the server.

`Specs` is `[{Domain, Locale, PoPath, Opts}]`. The heavy phase of each spec runs
in the calling process (sequential preparation — the v0.1 trade-off; a parallel
fan-out is a future evolution) and all ready payloads are delivered in a SINGLE
commit, collapsing N roundtrips into one. Each `Opts` follows `ensure_loaded/4`.

Returns `[{Domain, Locale, ensure_result()}]` — already-loaded or failed catalogs
are reported individually; one catalog's error never blocks the others.

## Edge cases
- Each result element is an independent `ensure_result()`: you can have a mix of
  `{ok, N}`, `{ok, already}` and `{error, _}` in the same list.
- Empty list -> `[]` (no roundtrip to the server).
- If ALL specs are idempotent/error in the preparation phase, no commit is sent.

```erlang
1> erli18n_server:ensure_loaded_many([
..    {my_domain, <<"fr">>, "fr.po", #{}},
..    {my_domain, <<"de">>, "de.po", #{}},
..    {my_domain, <<"xx">>, "/missing.po", #{}}
.. ]).
[{my_domain, <<"fr">>, {ok, 128}},
 {my_domain, <<"de">>, {ok, 96}},
 {my_domain, <<"xx">>, {error, {file_error, enoent}}}]
```

See `ensure_loaded/4`, `load_spec()`.
""".
-spec ensure_loaded_many([load_spec()]) ->
    [{domain(), locale(), ensure_result()}].
ensure_loaded_many(Specs) when is_list(Specs) ->
    Prepared = [prepare_one(Spec) || Spec <- Specs],
    {ToCommit, Resolved} = partition_prepared(Prepared),
    Committed =
        case ToCommit of
            [] ->
                [];
            [_ | _] ->
                cast_commit_many(
                    gen_server:call(?MODULE, {commit_many, ToCommit})
                )
        end,
    Resolved ++ Committed.

%% Prepare one spec in the caller: idempotent fast-path or heavy stage.
-spec prepare_one(load_spec()) ->
    {domain(), locale(), already}
    | {domain(), locale(), {prepared, {ok, staged()} | {error, ensure_error()}}}.
prepare_one({D, L, Path, Opts}) ->
    case lookup_header(D, L) of
        {ok, _} ->
            {D, L, already};
        undefined ->
            {D, L, {prepared, stage_catalog(D, L, Path, Opts)}}
    end.

%% Split prepared specs into those needing a commit (validated payloads) and
%% those already resolved (idempotent hits and prepare errors).
-spec partition_prepared([
    {domain(), locale(), already}
    | {domain(), locale(), {prepared, {ok, staged()} | {error, ensure_error()}}}
]) ->
    {[{domain(), locale(), staged()}], [{domain(), locale(), ensure_result()}]}.
partition_prepared(Prepared) ->
    lists:foldr(fun partition_one/2, {[], []}, Prepared).

-spec partition_one(
    {domain(), locale(), already}
    | {domain(), locale(), {prepared, {ok, staged()} | {error, ensure_error()}}},
    {[{domain(), locale(), staged()}], [{domain(), locale(), ensure_result()}]}
) ->
    {[{domain(), locale(), staged()}], [{domain(), locale(), ensure_result()}]}.
partition_one({D, L, already}, {Commit, Done}) ->
    {Commit, [{D, L, {ok, already}} | Done]};
partition_one({D, L, {prepared, {ok, Payload}}}, {Commit, Done}) ->
    {[{D, L, Payload} | Commit], Done};
partition_one({D, L, {prepared, {error, _} = Err}}, {Commit, Done}) ->
    {Commit, [{D, L, Err} | Done]}.

%% Findings #12 / #18 — single typed boundary cast.
%%
%% A `gen_server:call/2,3' reply (and an `erli18n_telemetry:span/3' result) is
%% specced `term()' in OTP because the callback module is resolved at RUNTIME.
%% For `erli18n_server' the call is always same-node, same-module, synchronous:
%% every reply is an `ensure_result()' (proven at the ORIGIN — `do_ensure_loaded/4',
%% `do_commit/4', `do_commit_many/1' and `install_staged/3' all carry precise
%% `-spec's). The cast helper returns the value unchanged, annotated with
%% `-eqwalizer({nowarn_function, ...})'. We deliberately do NOT use
%% `eqwalizer:dynamic_cast/1': that is a RUNTIME call into the `eqwalizer' module
%% shipped by `eqwalizer_support', a test-only `git_subdir' dependency Hex cannot
%% package — a published build would crash with `undefined function
%% eqwalizer:dynamic_cast/1'. The static annotation is equivalent at zero runtime
%% cost.
-spec cast_ensure_result(term()) -> ensure_result().
cast_ensure_result(Reply) ->
    Reply.

%% As `cast_ensure_result/1' but for the bulk `{commit_many, _}' reply: the
%% server callback (`do_commit_many/1', specced precisely) returns a list of
%% `{domain(), locale(), ensure_result()}'. One cast re-announces that type.
-spec cast_commit_many(term()) -> [{domain(), locale(), ensure_result()}].
cast_commit_many(Reply) ->
    Reply.

%% Compute the gettext-style convention path for a given application, domain, and
%% locale: `<priv>/locale/<Locale>/LC_MESSAGES/<Domain>.po'.
-doc """
Computes the conventional gettext `.po` path for an application.

## Parameters
- `App`: the OTP application whose `priv` contains the catalogs (resolved via
  `code:priv_dir/1`).
- `Domain`: the gettext domain (becomes the file name `<Domain>.po`).
- `Locale`: the binary locale (becomes the directory segment `<Locale>`).

## Return
Returns `<priv>/locale/<Locale>/LC_MESSAGES/<Domain>.po` (a string). This
function only COMPOSES the path — it does not check whether the file exists.

## Failure modes
Crashes with `{priv_dir_not_found, App}` if the application is unknown
(`code:priv_dir/1` returns `{error, bad_name}`).

```erlang
1> erli18n_server:default_po_path(my_app, my_domain, <<"fr">>).
"/path/to/my_app/priv/locale/fr/LC_MESSAGES/my_domain.po"
```

See `ensure_loaded/3`.
""".
-spec default_po_path(atom(), domain(), locale()) -> file:filename().
default_po_path(App, Domain, Locale) when
    is_atom(App), is_atom(Domain), is_binary(Locale)
->
    %% `code:priv_dir/1' returns `file:filename() | {error, bad_name}'. A
    %% `bad_name' means the application is unknown — crash explicitly so the
    %% operator sees the misconfiguration immediately, instead of silently
    %% building a path with `{error, bad_name}' embedded in it.
    PrivDir =
        case code:priv_dir(App) of
            {error, bad_name} ->
                error({priv_dir_not_found, App});
            Dir when is_list(Dir) ->
                Dir
        end,
    %% `filename:join/1' is specced `file:filename_all()'; we need
    %% `file:filename()' (a string) for the public contract. All inputs are
    %% strings, so the result is a string too; narrow at the boundary so an
    %% impossible binary would surface as a `case_clause' crash.
    Joined = filename:join([
        PrivDir,
        "locale",
        binary_to_list(Locale),
        "LC_MESSAGES",
        atom_to_list(Domain) ++ ".po"
    ]),
    case Joined of
        Str when is_list(Str) -> Str
    end.

%% =========================
%% gen_server callbacks
%% =========================

-doc """
Initialization callback (do not call by hand; the supervisor invokes it via
`start_link/0`).

The catalogs live in `persistent_term`, which is owned by the runtime and
survives a crash of this worker, so there is no table to claim and no index to
rebuild: the `State` is simply `#{}` (the server holds no catalog data). Returns
`{ok, #{}}`.

See `start_link/0`.
""".
-spec init([]) -> {ok, map()}.
init([]) ->
    {ok, #{}}.

-doc """
Serialized critical section — NOTE FOR THE MAINTAINER. This is the ONLY place
where `persistent_term` is mutated; every write in the module passes through here
under the single mailbox, which closes the check-then-install race that
`persistent_term` (no compare-and-swap) cannot close on its own.

## Message protocol (all call variants)
- `{insert_singular, D, L, Ctx, Msgid, T}` -> merges one entry; reply `ok`.
- `{insert_plural, D, L, Ctx, Msgid, Entries}` -> merges one entry per form;
  reply `ok`.
- `{insert_catalog, D, L, Entries}` -> merges the batch; reply `ok`.
- `{unload, D, L}` -> erases the catalog term; emits the span
  `[erli18n, catalog, unload]`; reply ALWAYS `ok` (historical contract).
- `{commit, ensure | reload, D, L, Staged}` -> installs an ALREADY validated
  `staged()` (the heavy phase ran in the caller). Mode `ensure` RE-CHECKS
  idempotency under serialization; mode `reload` always reinstalls. No span here
  — it already fired caller-side.
- `{commit_many, Items}` -> installs N payloads in one critical section, with ONE
  `memory_warning_check` at the end (not N).
- Any other call -> `{reply, {error, unknown_call}, State}`.

## Invariant
The server receives ONLY validated payloads in the commits — no heavy
read/parse/compile/build runs behind this mailbox (finding #6). That is why this
callback is the microsecond section.
""".
handle_call({insert_singular, D, L, Ctx, Msgid, T}, _From, State) ->
    ok = erli18n_pt_store:merge_entries(D, L, [{singular, Ctx, Msgid, T}]),
    {reply, ok, State};
handle_call({insert_plural, D, L, Ctx, Msgid, Entries}, _From, State) ->
    %% `undefined' is the parsed `msgid_plural' slot (irrelevant to keying); the
    %% form-index validation lives in `erli18n_pt_store' (loud on a bad index).
    ok = erli18n_pt_store:merge_entries(D, L, [{plural, Ctx, Msgid, undefined, Entries}]),
    {reply, ok, State};
handle_call({insert_catalog, D, L, Entries}, _From, State) ->
    ok = erli18n_pt_store:merge_entries(D, L, Entries),
    {reply, ok, State};
handle_call({unload, D, L}, _From, State) ->
    %% Span: [erli18n, catalog, unload]. Always-on (admin operation, not hot
    %% path). telemetry:span/3 passes ONLY the stop metadata returned by the
    %% closure to the stop event, so the closure builds the full stop metadata.
    StartMeta = #{domain => D, locale => L},
    _ = erli18n_telemetry:span(
        erli18n_telemetry:event_catalog_unload(),
        StartMeta,
        fun() ->
            {Result, KeysRemoved} = do_unload_with_count(D, L),
            StopMeta = StartMeta#{
                result => Result,
                keys_removed => KeysRemoved
            },
            {ok, StopMeta}
        end
    ),
    %% Preserve the historical public contract of `unload/2'.
    {reply, ok, State};
%% Finding #6: the server receives ONLY validated, ready-to-install payloads. The
%% heavy read+parse+compile+build already ran in the caller (inside the
%% load/reload span), so this clause is the microsecond critical section. The
%% telemetry span fired caller-side, so no span here. `ensure' mode re-checks
%% idempotency UNDER serialization; `reload' always reinstalls.
handle_call({commit, Mode, D, L, Staged}, _From, State) ->
    {reply, do_commit(Mode, D, L, Staged), State};
%% Bulk commit (finding #6): N validated payloads installed in one critical
%% section, with a single deferred `memory_warning_check' at the end instead of
%% one per catalog.
handle_call({commit_many, Items}, _From, State) ->
    {reply, do_commit_many(Items), State};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

-doc """
Inert by design: this server uses no casts (every write is a synchronous `call`,
so the caller gets acknowledgement and backpressure). It exists only to satisfy
the `gen_server` behaviour. Messages are ignored with `{noreply, State}`.
""".
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc """
Inert by design: this server expects no out-of-band messages (there is no ETS
table, no `'ETS-TRANSFER'`). Messages are ignored with `{noreply, State}`.
""".
handle_info(_Info, State) ->
    {noreply, State}.

-doc """
No cleanup to do: the catalogs live in `persistent_term`, which is owned by the
runtime and survives a crash of this worker, so `terminate/2` must NOT erase them
(that would lose every catalog on a transient crash). Application-stop cleanup is
`erli18n_app:stop/1`'s job. Returns `ok`.
""".
terminate(_Reason, _State) ->
    ok.

-doc """
No state migration: the `State` is an empty `#{}` (the truth lives in
`persistent_term`), so a code upgrade has no state to transform.
Returns `{ok, State}`.
""".
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =========================
%% Internal: commit (serialized critical section) — finding #6
%% =========================
%%
%% The heavy half (read+parse+compile+validate+bounds+map build) already ran in
%% the caller (`stage_catalog/4'), producing a validated `staged/0' payload with
%% the fully-built catalog map. `do_commit/4' is the only mutation: a single
%% `persistent_term:put' (atomic whole-catalog replacement). `ensure' re-checks
%% idempotency under serialization; `reload' always reinstalls.
-spec do_commit(ensure | reload, domain(), locale(), staged()) ->
    ensure_result().
do_commit(ensure, Domain, Locale, Staged) ->
    %% Re-check idempotency INSIDE serialization: if a concurrent caller
    %% installed this catalog while we were preparing, we do not overwrite.
    case lookup_header(Domain, Locale) of
        {ok, _} -> {ok, already};
        undefined -> install_staged(Domain, Locale, Staged)
    end;
do_commit(reload, Domain, Locale, Staged) ->
    %% Whole-catalog atomic replacement (finding #4): the put overwrites the
    %% term, so there are no stale entries to prune.
    install_staged(Domain, Locale, Staged).

%% Bulk commit (finding #6): install N validated payloads in one critical
%% section. Each catalog is idempotency-checked and installed without its own
%% `memory_warning_check' — that scan is deferred to a SINGLE call after the whole
%% batch, so a bulk of N is not N memory checks.
-spec do_commit_many([{domain(), locale(), staged()}]) ->
    [{domain(), locale(), ensure_result()}].
do_commit_many(Items) ->
    Results = [commit_one_no_memcheck(Item) || Item <- Items],
    _ = erli18n_telemetry:memory_warning_check(memory_info()),
    Results.

-spec commit_one_no_memcheck({domain(), locale(), staged()}) ->
    {domain(), locale(), ensure_result()}.
commit_one_no_memcheck({D, L, Staged}) ->
    R =
        case lookup_header(D, L) of
            {ok, _} -> {ok, already};
            undefined -> install_staged_no_memcheck(D, L, Staged)
        end,
    {D, L, R}.

%% Install a validated `staged/0': emit the precomputed side-effects, put the
%% catalog map, and run the post-install `memory_warning_check'. Nothing here can
%% fail (the failable work happened in the caller), so the commit is total and
%% cheap.
-spec install_staged(domain(), locale(), staged()) ->
    {ok, non_neg_integer()}.
install_staged(Domain, Locale, Staged) ->
    Result = install_staged_no_memcheck(Domain, Locale, Staged),
    %% Memory warning check runs after the install so the measurement reflects the
    %% post-install state (RISK-011 mitigation 2). Rate-limited inside
    %% `erli18n_telemetry:memory_warning_check/1'.
    _ = erli18n_telemetry:memory_warning_check(memory_info()),
    Result.

%% As `install_staged/3' but WITHOUT the per-catalog memory check, so the bulk
%% path can defer it to one call after the whole batch.
-spec install_staged_no_memcheck(domain(), locale(), staged()) ->
    {ok, non_neg_integer()}.
install_staged_no_memcheck(Domain, Locale, Staged) ->
    #{
        map := Map,
        divergence := Divergence,
        num_entries := NumEntries,
        fuzzy_skipped := FuzzySkipped
    } = Staged,
    emit_divergence_log(Domain, Locale, Divergence),
    %% Telemetry: [erli18n, plural, divergence_warning]. Always-on (load-time,
    %% infrequent).
    emit_divergence_telemetry(Domain, Locale, Divergence),
    emit_fuzzy_skip(Domain, Locale, FuzzySkipped),
    %% The only mutation: a single whole-catalog `persistent_term:put'.
    ok = erli18n_pt_store:put_map(Domain, Locale, Map),
    {ok, NumEntries}.

%% Erase a catalog and report how many stored keys (data entries + header) were
%% removed, for the unload span. `not_loaded' when the catalog was absent.
-spec do_unload_with_count(domain(), locale()) ->
    {ok | not_loaded, non_neg_integer()}.
do_unload_with_count(Domain, Locale) ->
    case erli18n_pt_store:get_map(Domain, Locale) of
        undefined ->
            {not_loaded, 0};
        Map ->
            Removed = erli18n_pt_store:key_count(Map),
            ok = erli18n_pt_store:unload(Domain, Locale),
            {ok, Removed}
    end.

%% Emit the (caller-precomputed) fuzzy-skip count. The heavy second parse that
%% produced this count ran in the caller (`compute_fuzzy_skipped/3'), so the
%% server only fires the telemetry event — no re-parse on the server.
-spec emit_fuzzy_skip(domain(), locale(), non_neg_integer()) -> ok.
emit_fuzzy_skip(_Domain, _Locale, 0) ->
    ok;
emit_fuzzy_skip(Domain, Locale, Count) when Count > 0 ->
    erli18n_telemetry:emit(
        erli18n_telemetry:event_lookup_fuzzy_skip(),
        #{count => Count},
        #{domain => Domain, locale => Locale}
    ),
    ok.

%% Compile the plural header into the in-memory bundle. Returns
%% `{ok, Compiled | fallback}' where `fallback' signals "no header was present" —
%% the lookup hot path then uses the C/Germanic default instead of evaluating an
%% AST. The parser always emits #{plural_forms := _}, so the two clauses are
%% exhaustive; a missing key would be a parser invariant break (function_clause).
%%
%% Findings #12 / #18: this `-spec' anchors the `compile_error()' union at the
%% ORIGIN, so eqwalizer rejects in BUILD any return outside this union.
-spec maybe_compile_plural(erli18n_po:header_map()) ->
    {ok, erli18n_plural:plural_compiled() | fallback}
    | {error, erli18n_plural:compile_error()}.
maybe_compile_plural(#{plural_forms := <<>>}) ->
    {ok, fallback};
maybe_compile_plural(#{plural_forms := PluralRaw}) ->
    case erli18n_plural:compile(PluralRaw) of
        {ok, _} = OK -> OK;
        {error, _} = E -> E
    end.

%% Header divergence vs CLDR is informational only (PSD-004). When the header is
%% absent (`fallback') or the locale is not in the CLDR table, we report `none'.
%%
%% Finding #17: takes the ALREADY compiled plural bundle and hands it straight to
%% `validate_against_cldr_ast/2', which reuses the parsed AST and a memoised
%% CLDR-AST table (no second compile of the same expression).
-spec compute_divergence(
    locale(),
    erli18n_plural:plural_compiled() | fallback
) -> none | {plural_divergence, binary(), binary()}.
compute_divergence(_Locale, fallback) ->
    none;
compute_divergence(Locale, #{} = PluralCompiled) ->
    case erli18n_plural:validate_against_cldr_ast(Locale, PluralCompiled) of
        ok ->
            none;
        {warning, {plural_divergence, _Loc, HdrRule, CldrRule}} ->
            {plural_divergence, HdrRule, CldrRule}
    end.

%% Per BR-MIGRAR-030, log uses OTP logger with `#{domain => [erli18n, server]}'
%% metadata. The divergence info is preserved in the header_state so a telemetry
%% layer can publish it without re-loading the catalog.
emit_divergence_log(_Domain, _Locale, none) ->
    ok;
emit_divergence_log(Domain, Locale, {plural_divergence, HdrRule, CldrRule}) ->
    Report = #{
        event => plural_divergence,
        domain_name => Domain,
        locale => Locale,
        header_rule => HdrRule,
        cldr_rule => CldrRule
    },
    ?LOG_WARNING(Report, #{domain => [erli18n, server]}),
    ok.

%% Telemetry counterpart to the ?LOG_WARNING above. Always emitted on real
%% divergence; skipped on `none'. Emits `[erli18n, plural, divergence_warning]'.
emit_divergence_telemetry(_Domain, _Locale, none) ->
    ok;
emit_divergence_telemetry(
    Domain,
    Locale,
    {plural_divergence, HdrRule, CldrRule}
) ->
    erli18n_telemetry:emit(
        erli18n_telemetry:event_plural_divergence(),
        #{count => 1},
        #{
            domain => Domain,
            locale => Locale,
            po_rule => HdrRule,
            cldr_rule => CldrRule
        }
    ),
    ok.

%% =========================
%% Finding #4/#6: STAGE (heavy phase, runs in the CALLER)
%% =========================
%%
%% `stage_catalog/4' runs the entire FAILABLE, heavy half of the load pipeline —
%% bounds check, file read, parse, plural compile, CLDR divergence, map build —
%% and produces a pure in-memory `staged/0' payload. It performs ZERO mutation,
%% so on `{error, _}' the prior catalog is provably untouched. Finding #6: it runs
%% in the CALLING process, so a large/slow/pathological `.po' from one tenant
%% never blocks another's load.
%%
%% Failure order (all BEFORE any mutation):
%%   0. size cap (filelib:file_size/1, no read) -> {input_too_large, _, _}
%%   1. file:read_file/1                         -> {file_error, Posix}
%%   2. erli18n_po:parse/2                        -> parse_error()
%%   3. entry cap (post-parse)                    -> {too_many_entries, _, _}
%%   4. compile plural header                     -> {plural_compile_error, _}
%%   5. compute_divergence/2                      -> never fails (informational)
-spec stage_catalog(domain(), locale(), file:filename(), opts()) ->
    {ok, staged()} | {error, ensure_error()}.
stage_catalog(Domain, Locale, PoPath, Opts) ->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    MaxBytes = maps:get(max_bytes, Opts, default_max_bytes()),
    MaxEntries = maps:get(max_entries, Opts, default_max_entries()),
    case check_size(PoPath, MaxBytes) of
        {error, _} = SizeErr ->
            SizeErr;
        ok ->
            case file:read_file(PoPath) of
                {error, Posix} ->
                    {error, {file_error, Posix}};
                {ok, Bin} ->
                    case erli18n_po:parse(Bin, #{include_fuzzy => IncludeFuzzy}) of
                        {error, _} = E ->
                            E;
                        {ok, Parsed} ->
                            stage_parsed(
                                Domain,
                                Locale,
                                PoPath,
                                IncludeFuzzy,
                                MaxEntries,
                                Bin,
                                Parsed
                            )
                    end
            end
    end.

%% Size cap applied BEFORE reading the whole file into memory: `filelib:file_size/1'
%% stats the file, it does not load bytes (finding #6). `infinity' = no cap.
-spec check_size(file:filename(), non_neg_integer() | infinity) ->
    ok | {error, bound_error()}.
check_size(_PoPath, infinity) ->
    ok;
check_size(PoPath, MaxBytes) when is_integer(MaxBytes) ->
    case filelib:file_size(PoPath) of
        Size when Size =< MaxBytes ->
            ok;
        Size ->
            {error, {input_too_large, Size, MaxBytes}}
    end.

%% Pure entry-cap + compile + map build half of staging. The entry cap rejects an
%% over-large catalog AFTER the parse; compile failure is the last failable step.
%% On success we build the catalog map and the caller-computed fuzzy_skipped count
%% so the commit has nothing heavy left.
-spec stage_parsed(
    domain(),
    locale(),
    file:filename(),
    boolean(),
    non_neg_integer() | infinity,
    binary(),
    erli18n_po:parsed_catalog()
) -> {ok, staged()} | {error, ensure_error()}.
stage_parsed(Domain, Locale, PoPath, IncludeFuzzy, MaxEntries, Bin, Parsed) ->
    #{header := Header, entries := Entries} = Parsed,
    NumEntries = length(Entries),
    case within_entry_cap(NumEntries, MaxEntries) of
        {too_many, Max} ->
            {error, {too_many_entries, NumEntries, Max}};
        ok ->
            stage_compiled(
                Domain,
                Locale,
                PoPath,
                IncludeFuzzy,
                Bin,
                Header,
                Entries,
                NumEntries
            )
    end.

%% `ok' when within the entry cap, or `{too_many, Max}' carrying the INTEGER cap
%% when exceeded (`infinity' never reaches the error path).
-spec within_entry_cap(non_neg_integer(), non_neg_integer() | infinity) ->
    ok | {too_many, non_neg_integer()}.
within_entry_cap(_N, infinity) ->
    ok;
within_entry_cap(N, Max) when is_integer(Max) ->
    case N =< Max of
        true -> ok;
        false -> {too_many, Max}
    end.

-spec stage_compiled(
    domain(),
    locale(),
    file:filename(),
    boolean(),
    binary(),
    erli18n_po:header_map(),
    [erli18n_po:entry()],
    non_neg_integer()
) -> {ok, staged()} | {error, ensure_error()}.
stage_compiled(Domain, Locale, PoPath, IncludeFuzzy, Bin, Header, Entries, NumEntries) ->
    PluralRaw =
        case maps:get(plural_forms, Header, <<>>) of
            <<>> -> erli18n_plural:fallback_rule();
            Other -> Other
        end,
    case maybe_compile_plural(Header) of
        {error, CompileErr} ->
            {error, {plural_compile_error, CompileErr}};
        {ok, PluralCompiled} ->
            %% Finding #17: pass the ALREADY compiled bundle, not the raw header
            %% map, so the divergence check does not recompile the expression.
            Divergence = compute_divergence(Locale, PluralCompiled),
            HeaderState = #{
                plural => PluralCompiled,
                plural_raw => PluralRaw,
                po_path => PoPath,
                loaded_at => erlang:system_time(millisecond),
                divergence => Divergence,
                fuzzy_included => IncludeFuzzy,
                num_entries => NumEntries
            },
            %% Build the ready-to-install catalog map (data entries + header) off
            %% the write path — the commit then does a single `put'.
            Map = erli18n_pt_store:build_map(Entries, HeaderState),
            FuzzySkipped = compute_fuzzy_skipped(IncludeFuzzy, Bin, NumEntries),
            {ok, #{
                map => Map,
                divergence => Divergence,
                domain => Domain,
                locale => Locale,
                num_entries => NumEntries,
                fuzzy_skipped => FuzzySkipped
            }}
    end.

%% Count the fuzzy entries the default parse dropped, computed in the CALLER
%% (finding #6: the heavy second parse no longer runs on the server). Only
%% re-parses when the consumer opted in to lookup telemetry AND the default
%% (non-fuzzy) load discarded fuzzy entries. The emit happens at commit time from
%% the precomputed count.
-spec compute_fuzzy_skipped(boolean(), binary(), non_neg_integer()) ->
    non_neg_integer().
compute_fuzzy_skipped(true = _IncludeFuzzy, _Bin, _DefaultCount) ->
    %% include_fuzzy => true: nothing was dropped.
    0;
compute_fuzzy_skipped(false, Bin, DefaultCount) ->
    case erli18n_telemetry:lookup_telemetry_enabled() of
        false ->
            0;
        true ->
            %% Re-parse with include_fuzzy => true against the same bytes that
            %% already parsed successfully with include_fuzzy => false. A failure
            %% here would be a parser invariant break, so we match exactly.
            {ok, #{entries := AllEntries}} =
                erli18n_po:parse(Bin, #{include_fuzzy => true}),
            erlang:max(0, length(AllEntries) - DefaultCount)
    end.

%% Bounds defaults (finding #6), configurable via application env so a deployment
%% can tune or disable (`infinity') them.
-spec default_max_bytes() -> non_neg_integer() | infinity.
default_max_bytes() ->
    narrow_bound(application:get_env(erli18n, max_po_bytes, 16 * 1024 * 1024)).

-spec default_max_entries() -> non_neg_integer() | infinity.
default_max_entries() ->
    narrow_bound(application:get_env(erli18n, max_po_entries, 500000)).

%% `application:get_env/3' is specced `term()'; narrow the configured value to the
%% bound shape at the boundary. A non-conforming env value is a deployment
%% misconfiguration and crashes with a descriptive payload.
-spec narrow_bound(term()) -> non_neg_integer() | infinity.
narrow_bound(infinity) -> infinity;
narrow_bound(N) when is_integer(N), N >= 0 -> N;
narrow_bound(Other) -> error({invalid_erli18n_bound, Other}).

%% Build the stop metadata for the catalog load/reload span. Maps the internal
%% load result onto the stop-metadata schema.
load_stop_metadata({ok, already}) ->
    #{result => already, keys_loaded => 0};
load_stop_metadata({ok, N}) when is_integer(N) ->
    #{result => ok, keys_loaded => N};
load_stop_metadata({error, Reason}) ->
    #{result => {error, Reason}, keys_loaded => 0}.

%% The `po_path' metadata field must be binary (the catalog_load_metadata
%% typespec). `file:filename()' can be a list or binary; normalize at the
%% telemetry boundary so handlers never have to guard.
to_binary_path(Path) when is_binary(Path) -> Path;
to_binary_path(Path) when is_list(Path) -> unicode:characters_to_binary(Path).
