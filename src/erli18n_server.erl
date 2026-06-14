-module(erli18n_server).

-moduledoc """
Catalog `gen_server`: owner and sole writer of the translations ETS table.

## What it is and which problem it solves

This module is the heart of the erli18n runtime: it loads `.po` catalogs,
keeps the translations live in ETS and answers lookups (singular, plural and
header). The central problem it solves is reconciling two contradictory
requirements: translation reads are extremely hot (every UI string goes
through a lookup) and must be lock-free; writes, on the other hand, must be
serialized to keep the `protected` ETS consistent. The solution is a strict
split between the write path (serialized by this process's mailbox) and the
read path (straight from ETS, with no roundtrip to the server).

## Mental model

Think of this module in three layers:

1. **Read path (hot path, lock-free).** `lookup_singular/4`,
   `lookup_plural_form/5` and `lookup_header/2` run `ets:lookup/2` directly in
   the CALLING process — no message reaches the server mailbox. That is why N
   processes can read in parallel with no bottleneck (RISK-012). The ETS is
   `protected`: any process reads, only the owner (this server) writes.

2. **Write path (serialized).** `insert_*`, `unload/2` and the load commits
   become `gen_server:call/2,3`; `handle_call/3` is the only critical section
   where the ETS is mutated. Since ETS-`set` performs atomic per-row inserts
   under the single mailbox, there is never observable mixed state.

3. **Load orchestration (heavy work OUTSIDE the mailbox).** `ensure_loaded/4`
   and `reload/4` run the heavy, failable phase (size-check, read, parse,
   compile of the plural rule, CLDR divergence, object build, fuzzy count) in
   the CALLING process, producing a pure in-memory `staged()`. Only this
   validated payload travels to the server for a millisecond-scale commit. This
   way a large/slow/pathological `.po` from one tenant never blocks another's
   load (finding #6).

**Trusted vs untrusted.** A `.po`'s `Plural-Forms` rule is untrusted input;
that is why it is compiled with bounds (see `erli18n_plural`) and
`lookup_plural_form/5` wraps the evaluation in a belt-and-suspenders `try`. This
module's anti-DoS bounds (`max_bytes`, `max_entries`) reject large catalogs
BEFORE any ETS mutation.

**ETS-TRANSFER / heir.** This server does NOT create the data table. A
dedicated owner (`erli18n_table_owner`, started before it under `rest_for_one`)
creates the table and hands it over via `give_away/3` (`'ETS-TRANSFER'`
consumed in `init/1`), remaining as `heir`. If this worker crashes, the table
returns INTACT to the owner instead of being destroyed — every loaded catalog
survives the restart. On reclaiming it, `init/1` rebuilds the O(1) catalog
index from the surviving rows.

**Two mental maps of "state".** This `gen_server`'s `State` is an empty map
`#{}` — that is deliberate. The truth lives in TWO ETS tables: the data table
(`?ETS_TABLE`, inherited from the owner) and a server-owned secondary index
(`?CATALOG_INDEX_TABLE`) that stores, per catalog, the `set` of data keys.
The index makes `memory_info/0` O(1) and `unload/2` O(catalog size) instead of
O(total rows) scans (findings #7/#13).

## When and how a dev touches this module

- To **load/reload** a `.po`: `ensure_loaded/3,4` (idempotent),
  `reload/3,4` (always reinstalls, atomic) or `ensure_loaded_many/1` (batch).
- To **unload**: `unload/2`.
- To **read** a low-level translation (the `erli18n` façade is the usual
  front-door): `lookup_singular/4`, `lookup_plural_form/5`, `lookup_header/2`.
- To **write** individual entries (tests, non-`.po` sources):
  `insert_singular/5`, `insert_plural/5`, `insert_catalog/3`.
- For **observability**: `memory_info/0`, `loaded_catalogs/0`,
  `which_keys/2`.

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

(`num_keys` counts ALL rows, including the header; `loaded_catalogs/0` counts
only the 130 data rows — see both functions.)

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

-include("erli18n.hrl").
-include_lib("kernel/include/logger.hrl").

%% eqwalizer suppressions for the `term() -> T' boundary casts below (a
%% gen_server reply or an ETS read, both of which eqwalizer can only type as
%% `term()'). nowarn_function lets these helpers re-announce a server-proven
%% type WITHOUT a runtime `eqwalizer:dynamic_cast/1' call, which would require
%% the test-only `eqwalizer_support' module (a git dependency Hex cannot
%% package) at runtime. Full rationale at each function.
-eqwalizer({nowarn_function, cast_ensure_result/1}).
-eqwalizer({nowarn_function, cast_commit_many/1}).
-eqwalizer({nowarn_function, dynamic_cast_index_keyset/1}).

%% Write API (serialized via gen_server, only owner writes to protected ETS).
-export([
    start_link/0,
    insert_singular/5,
    insert_plural/5,
    insert_catalog/3,
    unload/2
]).

%% Read API (direct ETS lookup from caller process — lock-free hot path,
%% per RISK-012 anti-bottleneck pattern).
%%
%% Finding #16 (lookup-plural-5-exported-footgun-bypasses-form-evaluation):
%% the plural read is exposed ONLY through the form-aware
%% `lookup_plural_form/5`, which evaluates the catalog's compiled
%% `Plural-Forms` rule against the count N before reading the row. The raw,
%% index-based `lookup_plural/5` is intentionally NOT exported: it requires
%% the caller to already know the form index for N — the locale-specific
%% knowledge this library exists to encapsulate — so exporting it invited
%% callers to pass the count N as the index and silently get the wrong
%% plural form. It remains an internal helper used by `lookup_plural_form/5`.
-export([
    lookup_singular/4,
    lookup_header/2,
    lookup_plural_form/5
]).

%% Observability (read-only scan from caller process).
-export([
    memory_info/0,
    loaded_catalogs/0,
    which_keys/2
]).

%% Load orchestration: parse .po + compile plural + validate vs CLDR +
%% insert atomically. Per BR-MIGRAR-022/029 and RISK-012, this is a
%% serialized write path; idempotency makes the second call cheap.
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
%% Finding #14: the parsed plural entry now carries the `msgid_plural` form
%% text (4th element). The server only materializes the ETS lookup objects,
%% which are keyed by `{Domain, Locale, Context, Msgid, Index}` — the
%% `msgid_plural` is irrelevant to lookup and is dropped at materialization
%% (it exists purely so `erli18n_po:dump/1` round-trips faithfully).
-type plural_entry() ::
    {plural, context(), msgid(), msgid_plural(), plural_entries()}.
-type catalog_entry() :: singular_entry() | plural_entry().

%% Finding #13: a single data (non-header) ETS key as stored in the catalog
%% table — exactly the `?SINGULAR_KEY'/`?PLURAL_KEY' macro shapes. The
%% secondary index records a `sets:set/1' of these per catalog so unload
%% deletes them one-by-one (O(catalog size)) instead of full-scanning.
-type data_key() ::
    {singular, domain(), locale(), context(), msgid()}
    | {plural, domain(), locale(), context(), msgid(), plural_index()}.

%% Load orchestration types (Part 5).
%%
%% Finding #6 (load-pipeline-serialized-in-gen-server-no-bounds-or-timeout):
%% `opts()` gains resource bounds and a tunable commit timeout. Every field
%% is optional; omitting them preserves the legacy behaviour (modulo the
%% safety cap defaults). The heavy read+parse+compile now runs in the
%% CALLING process, so these are the boundary knobs a multi-tenant
%% deployment (ADR-0003) needs:
%%   * `max_bytes`   — reject the file (via `filelib:file_size/1`) BEFORE
%%                     reading it whole into memory. `infinity` = no cap.
%%   * `max_entries` — reject the catalog AFTER the parse if it has more
%%                     than N entries. `infinity` = no cap.
%%   * `timeout`     — timeout of the `gen_server:call/3' that performs the
%%                     (now millisecond-scale) commit. The heavy phase no
%%                     longer runs behind the mailbox, so the deadline only
%%                     covers the bulk insert.
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
- `timeout` (default 5000 ms): deadline of the `gen_server:call/3` that performs
  the commit. Since the heavy phase no longer runs behind the mailbox, the
  deadline covers only the bulk insert (millisecond scale).
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
- `{error, ensure_error()}`: structured error; the ETS stays intact (all errors
  occur BEFORE any mutation).
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
(`bound_error()`). None of them leaves the ETS mutated.
""".
-type ensure_error() ::
    erli18n_po:parse_error()
    | {plural_compile_error, erli18n_plural:compile_error()}
    | {file_error, file:posix() | badarg | terminated | system_limit}
    | bound_error()
    | {load_failed, term()}.
%% Finding #6: errors introduced by the resource bounds. A subset of
%% `ensure_error()`, surfaced from the caller-side heavy phase BEFORE any
%% ETS mutation (same "errors before mutation" ordering the load pipeline
%% always had).
-doc """
Errors from the anti-DoS bounds (finding #6), a subset of `ensure_error()`.
Both are surfaced in the CALLER's heavy phase, BEFORE any ETS mutation:
`input_too_large` when the file size exceeds `max_bytes` (checked without
reading the bytes, via `filelib:file_size/1`); `too_many_entries` when the
post-parse count exceeds `max_entries`. The second element is the observed
value, the third is the configured limit.
""".
-type bound_error() ::
    {input_too_large, Bytes :: non_neg_integer(), Limit :: non_neg_integer()}
    | {too_many_entries, Count :: non_neg_integer(), Limit :: non_neg_integer()}.
%% Finding #6: a single catalog to load in the bulk API. Same positional
%% shape as the `ensure_loaded/4' arguments.
-doc """
A catalog to load in the bulk API `ensure_loaded_many/1`. Same positional
shape as the `ensure_loaded/4` arguments:
`{Domain, Locale, PoPath, Opts}`.
""".
-type load_spec() :: {domain(), locale(), file:filename(), opts()}.
-type divergence_info() ::
    none
    | {plural_divergence, binary(), binary()}.
-doc """
Header state of a loaded catalog, returned by `lookup_header/2` and stored in
the `?HEADER_KEY` row. The PRESENCE of this row is the idempotency signal used
by `ensure_loaded/3` ("catalog already loaded").

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

%% Finding #4 (reload-not-atomic-destroys-catalog-and-empty-window):
%% the product of the pure, failable half of the load pipeline (read +
%% parse + compile + divergence). A `staged/0` is built WITHOUT touching
%% ETS, so any error leaves the prior catalog intact; `swap_catalog/3`
%% then performs the only observable mutation as an atomic insert-before-
%% prune. `objects` are the `{Key, Translation}' rows ready for
%% `ets:insert/2'; `new_keys` is their data-key set (for stale pruning);
%% `num_entries` is the count reported back to the caller.
%%
%% Finding #6 (load-pipeline-serialized-in-gen-server-no-bounds-or-timeout):
%% a `staged/0' IS the validated, ready-to-insert load payload. It is built
%% entirely in the CALLING process (read+parse+compile+stage+fuzzy count),
%% and only this value travels through the server mailbox to the commit. To
%% keep the heavy fuzzy re-parse off the server, `fuzzy_skipped' is computed
%% caller-side and carried here, so the commit only EMITS the precomputed
%% count (no re-parse on the owner). `raw_bin' is retained for backwards
%% compatibility with the staging shape but is no longer re-parsed at commit
%% time.
-type staged() :: #{
    objects := [tuple()],
    new_keys := sets:set(data_key()),
    header := header_state(),
    divergence := divergence_info(),
    domain := domain(),
    locale := locale(),
    raw_bin := binary(),
    include_fuzzy := boolean(),
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

Called by the supervisor — in general you do NOT call this by hand. In `init/1`
the server claims the data ETS table from `erli18n_table_owner` via
`'ETS-TRANSFER'` (becoming its owner/writer) and (re)builds the O(1) catalog
index from the surviving rows.

## Failure modes
`init/1` crashes with `{ets_handoff_timeout, _}` if the owner does not hand the
table over within 5s (something structurally broken in the supervision tree),
which makes the supervisor re-evaluate. Since the owner is the table's `heir`, a
crash of THIS worker does not destroy the catalogs: the table returns to the
owner and is re-handed on the next `init/1`.

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
Writes one ETS row under the key `{singular, Domain, Locale, Context, Msgid}`
(the `singular` tag is part of the key — `?SINGULAR_KEY` in `erli18n.hrl`) and
registers that key in the catalog index (which thus starts counting >=1 entry).
Synchronous; always returns `ok`. Overwrites any prior translation for the same
key. Does NOT install a header — this entry is readable via `lookup_singular/4`,
but the catalog will not have `lookup_header/2` unless an `ensure_loaded/3`
installs it.

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
    %% `gen_server:call/2` is typed as `term()`. We pattern-match `ok` so
    %% the public contract is enforced: the matching `handle_call/3`
    %% clause is the only writer of this reply tuple and always returns
    %% `{reply, ok, State}`, so any other shape is a contract break and
    %% should crash with badmatch.
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
Writes one ETS row per form, under the key
`{plural, Domain, Locale, Context, Msgid, FormIndex}` (the `plural` tag is part
of the key — `?PLURAL_KEY` in `erli18n.hrl`), and registers those keys in the
catalog index. Synchronous; always returns `ok`. **An empty list is a no-op**:
it writes no row AND does not register the catalog in the index — by the
membership rule "index row present <=> >=1 data entry". Selecting the correct
form at read time (evaluating `Plural-Forms` against `N`) is the responsibility
of `lookup_plural_form/5`, NOT of this function: here you supply the raw indices.

## Failure modes
Arguments outside the guards crash with `function_clause`. Each pair must have an
integer `FormIndex` >= 0 (validated in `build_plural_objects/5` inside the
server); a negative index would crash the server.

The rows are immediately readable via a direct ETS read, but
`lookup_plural_form/5` only SELECTS a form when the `(Domain, Locale)` catalog
header is already loaded — it reads the header first to obtain the `Plural-Forms`
rule; without a header it returns `undefined` directly (header absent -> miss).
And `insert_plural/5` does NOT install any header.

Important: there is no shortcut to make a hand-inserted form "selectable" after
the fact. `ensure_loaded/3` does NOT install a retroactive header for keys
written via `insert_plural/5`: it either takes the idempotent fast-path (if a
header already exists) and touches nothing, or it stages and installs ONLY the
entries read from the `.po` on disk (see `do_ensure_loaded/4`). For
`lookup_plural_form/5` to select a plural form, the header must have been
installed by a real `.po` load that ALREADY contains those very keys. Without a
`.po`, `insert_plural/5` is only useful for seeding data to be read directly from
ETS in tests, via the tagged key
`{plural, Domain, Locale, Context, Msgid, FormIndex}`:

```erlang
1> erli18n_server:insert_plural(my_domain, <<"fr">>, undefined, <<"file">>,
..    [{0, <<"fichier">>}, {1, <<"fichiers">>}]).
ok
%% Without a header, lookup_plural_form/5 is a miss:
2> erli18n_server:lookup_plural_form(my_domain, <<"fr">>, undefined, <<"file">>, 1).
undefined
%% In tests, read the row directly by the tagged key:
3> ets:lookup(erli18n_catalog, {plural, my_domain, <<"fr">>, undefined, <<"file">>, 1}).
[{{plural, my_domain, <<"fr">>, undefined, <<"file">>, 1}, <<"fichiers">>}]
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
  is discarded when materializing the ETS rows (it does not take part in the
  lookup key — finding #14).

## Return and effects
Each entry is flattened into the corresponding ETS rows (one per plural form) and
the resulting data keys are registered in the catalog index. Synchronous; always
returns `ok`. **Does NOT install the catalog header** — for the full pipeline
(`.po` parse + plural compile + header) use `ensure_loaded/3`. Without a header,
`lookup_plural_form/5` returns `undefined`; use this function for seeding
singular data or in tests.

## Failure modes
A non-atom `Domain` / non-binary `Locale` / non-list `Entries` crash with
`function_clause`. An entry with an unknown tag crashes the server in
`entry_to_objects/3`.

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
O(catalog size) deletion, not O(total rows): it reads the data keys from the
secondary index and deletes each one (O(1) per key on a `set`), then removes the
header by its own key and deregisters the catalog from the index (finding #13).
After the unload, `lookup_*` of that catalog starts returning `undefined`.
Synchronous; always returns `ok`.

**Idempotent**: unloading a never-loaded catalog is a no-op (also returns `ok`).
Emits the telemetry span `[erli18n, catalog, unload]` whose stop metadata
includes `result` (`ok` | `not_loaded`) and `keys_removed`.

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

See also `reload/3` (which does NOT do delete-then-reload), `loaded_catalogs/0`.
""".
-spec unload(domain(), locale()) -> ok.
unload(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    ok = gen_server:call(?MODULE, {unload, Domain, Locale}).

%% Finding #16: guarded so a malformed argument is a loud `function_clause`
%% (a contract break) rather than a silent `undefined` miss — consistent
%% with `lookup_plural_form/5`.
-doc """
Lock-free lookup of a singular translation, straight from ETS in the caller.

The singular read hot path: a single `ets:lookup/2`, with no roundtrip to the
`gen_server`, executed in the calling process (that is why N processes read in
parallel with no bottleneck).

## Parameters
- `Domain`, `Locale`: the catalog.
- `Context`: the `msgctxt`, or `undefined`. A lookup with the wrong `Context` is
  a miss — `msgctxt` is part of the key.
- `Msgid`: the source text being looked up.

## Return
- `{ok, Translation}` if the key `{singular, Domain, Locale, Context, Msgid}`
  exists (the `singular` tag is part of the key — `?SINGULAR_KEY` in
  `erli18n.hrl`; an `ets:lookup/2` with the untagged 4-tuple is always a miss).
- `undefined` on a miss — it is up to the caller (the `erli18n` façade) to apply
  the fallback to the raw `Msgid` itself. There is no automatic fallback here.

## Failure modes
Arguments outside the guards are `function_clause` (contract break, LOUD
failure), never a silent `undefined` — a deliberate choice (finding #16). If the
ETS does not exist (dead server), `ets:lookup/2` crashes with `badarg`.

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
    case ets:lookup(?ETS_TABLE, ?SINGULAR_KEY(Domain, Locale, Context, Msgid)) of
        [{_, Translation}] -> {ok, Translation};
        [] -> undefined
    end.

%% Internal (finding #16): raw, index-based plural read with NO Plural-Forms
%% evaluation. Reached only from `lookup_plural_form/5`, which has already
%% evaluated the compiled rule against N to produce `Index`. Guarded for the
%% same loud-failure contract as the public reads.
-spec lookup_plural(domain(), locale(), context(), msgid(), plural_index()) ->
    {ok, translation()} | undefined.
lookup_plural(Domain, Locale, Context, Msgid, Index) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_integer(Index),
    Index >= 0
->
    case ets:lookup(?ETS_TABLE, ?PLURAL_KEY(Domain, Locale, Context, Msgid, Index)) of
        [{_, Translation}] -> {ok, Translation};
        [] -> undefined
    end.

%% Read-only header lookup. ETS direct from caller process — lock-free
%% hot path, mirrors lookup_singular/lookup_plural shape.
-doc """
Lock-free lookup of the `(Domain, Locale)` catalog header, straight from ETS.

## Return
- `{ok, HeaderState}` — see `header_state()` for the contents (compiled plural
  rule or `fallback`, raw `Plural-Forms`, `.po` path, load instant, vs-CLDR
  divergence, entry count).
- `undefined` if the catalog is not loaded.

## Why this matters
The PRESENCE of the header is the idempotency signal `ensure_loaded/3` consults
("already loaded?") and what `lookup_plural_form/5` reads first to obtain the
plural rule. A catalog loaded WITHOUT `Plural-Forms` still has a header — with
`plural := fallback`. A catalog populated only by `insert_*` (without
`ensure_loaded/3`) does NOT have a header.

## Failure modes
A non-atom `Domain` / non-binary `Locale` crash with `function_clause`.

```erlang
1> erli18n_server:ensure_loaded(my_domain, <<"fr">>, "fr.po").
{ok, 128}
2> {ok, H} = erli18n_server:lookup_header(my_domain, <<"fr">>).
{ok, #{divergence => none,
       fuzzy_included => false,
       loaded_at => 1700000000000,
       num_entries => 128,
       plural => #{nplurals => 2, expr => '...', raw => <<"n>1">>},
       plural_raw => <<"nplurals=2; plural=n>1;">>,
       po_path => <<"fr.po">>}}
3> maps:get(num_entries, H).
128
4> erli18n_server:lookup_header(my_domain, <<"de">>).
undefined
```

(The `plural` value is a `t:erli18n_plural:plural_compiled/0` —
`#{nplurals, expr, raw}`; the `expr` above is abbreviated as `'...'`, it is an
internal AST.)

See also `lookup_singular/4`, `lookup_plural_form/5`, `header_state()`.
""".
-spec lookup_header(domain(), locale()) -> {ok, header_state()} | undefined.
lookup_header(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    case ets:lookup(?ETS_TABLE, ?HEADER_KEY(Domain, Locale)) of
        [{_, HeaderState}] -> {ok, HeaderState};
        [] -> undefined
    end.

%% Plural-aware lookup: looks up the header, evaluates the compiled plural
%% rule against N, then issues a plural lookup at the computed form index.
%% Returns the translation if present, or `undefined` (caller is
%% responsible for msgid_plural fallback per PSD-003).
%%
%% Hot path: 1 ETS lookup for header + 1 ETS lookup for the entry, no
%% gen_server roundtrip. Fallback rule (header missing entirely) uses the
%% C/Germanic default `N == 1 -> form 0; else form 1`.
-doc """
The CORRECT entry point for plural reads (form-aware, lock-free).

Unlike the raw, index-based `lookup_plural/5` (internal, NOT exported — finding
#16), here the caller does NOT need to know the form index for `N`: this
function reads the header, evaluates the catalog's compiled `Plural-Forms` rule
against the count `N` to obtain the form index, and then looks up the entry at
that index. It is the encapsulation of the locale-specific knowledge the library
exists to provide.

## Parameters
- `Domain`, `Locale`, `Context`, `Msgid`: identify the plural msgid.
- `N`: the count (integer) that decides the form. NOT the form index — the
  `Plural-Forms` rule converts it into an index.

## Return
- `{ok, Translation}` when the form exists.
- `undefined` on a miss — it is up to the caller to fall back to `msgid_plural`
  (PSD-003). There is no automatic fallback to the raw text here.

## Hot path
1 header lookup + 1 entry lookup, both direct `ets:lookup/2`, with no roundtrip
to the `gen_server`.

## Fallback rules (order matters)
- **Header absent** (catalog not loaded, or populated only by `insert_*`)
  -> `undefined` directly.
- **Header present without `Plural-Forms`** (`plural := fallback`) -> uses the
  C/Germanic default (`N == 1 -> form 0; otherwise form 1`).
- **Header with a compiled rule** -> evaluates the rule. `erli18n_plural:evaluate/2`
  is total (it clamps malformed rules instead of crashing), and the surrounding
  `try` is belt-and-suspenders that degrades to the Germanic form should a future
  regression reintroduce a throw on this per-request hot path (finding #1,
  anti-DoS). In other words: this function never crashes the calling process
  because of an untrusted plural rule.

## Failure modes
A non-integer `N` (or other args outside the guards) is `function_clause`.

```erlang
%% French catalog loaded with Plural-Forms (n>1 -> form 1).
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
    case lookup_header(Domain, Locale) of
        {ok, #{plural := fallback}} ->
            Index = fallback_form_index(N),
            lookup_plural(Domain, Locale, Context, Msgid, Index);
        {ok, #{plural := Compiled}} ->
            %% Boundary guard (finding #1, plural-eval-throws-per-lookup-
            %% dos, Layer 4). `evaluate/2` is now total — it clamps
            %% malformed rules instead of raising — so this `try` never
            %% fires in practice. It is belt-and-suspenders: should a
            %% future regression reintroduce a throw on this per-request
            %% hot path, we degrade to the default Germanic form index
            %% rather than crash the calling request process.
            Index =
                try
                    erli18n_plural:evaluate(Compiled, N)
                catch
                    error:_ -> fallback_form_index(N)
                end,
            lookup_plural(Domain, Locale, Context, Msgid, Index);
        undefined ->
            undefined
    end.

-doc """
Returns the memory usage of the translations ETS table.

Observability read in the calling process; not a hot path (do not call it per
request). Returns a map with:
- `ets_bytes`: the data table's memory in bytes (words * wordsize).
- `num_catalogs`: distinct loaded catalogs — read in O(1) from the secondary
  index (finding #7), not by scanning. Counts a catalog iff it has >=1 data row
  (a header-only `.po` does not count).
- `num_keys`: total rows in the data table — `ets:info(?ETS_TABLE, size)`,
  counts ALL rows, INCLUDING each catalog's header row. So, for a single catalog
  with 1 header, the invariant
  `num_keys = (data rows from loaded_catalogs/0) + num_catalogs` holds: the data
  rows (`loaded_catalogs/0` does NOT count headers) plus one header row per
  catalog.

## Failure modes
Crashes with `{ets_info_invalid, _}` if the table does not exist (dead server) —
a descriptive payload instead of propagating `undefined`.

```erlang
%% Single catalog with 130 data rows (see loaded_catalogs/0) + 1 header.
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
    %% `ets:info/2` returns `term() | undefined` (eqwalizer view); the
    %% `undefined` only happens when the table doesn't exist. The server
    %% creates the table in `init/1` and never deletes it, so reaching
    %% `undefined` here means the gen_server is dead — at which point
    %% crashing with a descriptive payload is the right answer.
    Words = ets_info_integer(memory),
    Bytes = Words * erlang:system_info(wordsize),
    NumKeys = ets_info_integer(size),
    %% Finding #7: O(1) read of the authoritative side index instead of an
    %% O(total_rows) `ets:tab2list/1' + per-row `sets:add_element/2' scan
    %% on every call (which made N loads O(N^2) and briefly doubled peak
    %% memory by copying the whole table onto the server heap).
    NumCatalogs = index_size(),
    #{
        ets_bytes => Bytes,
        num_catalogs => NumCatalogs,
        num_keys => NumKeys
    }.

%% Narrow `ets:info(?ETS_TABLE, Key)` to `non_neg_integer()`. The `memory`
%% and `size` keys are both documented to return `non_neg_integer()` when
%% the table exists. Any other shape is a contract violation worth crashing
%% on.
-spec ets_info_integer(memory | size) -> non_neg_integer().
ets_info_integer(Key) ->
    case ets:info(?ETS_TABLE, Key) of
        N when is_integer(N), N >= 0 -> N;
        Other -> error({ets_info_invalid, {?ETS_TABLE, Key, Other, expected, non_neg_integer}})
    end.

-doc """
Lists the loaded catalogs with the data-row count of each.

Returns `[{Domain, Locale, NumRows}]`, where `NumRows` counts the data rows
(singulars + EACH plural form counted separately; headers do NOT count — that is
why this number differs from `header_state()`.`num_entries`, which counts logical
entries). The list order is unspecified.

Computed by scanning an `ets:tab2list/1` snapshot (O(total rows)) — it is an
observability read, not a hot path. For just the COUNT of catalogs without the
scan cost, use `memory_info/0` (`num_catalogs`, O(1)).

Relationship with `memory_info/0`: the `NumRows` here are ONLY data rows (no
header), whereas `memory_info/0`.`num_keys` counts everything (data + 1 header
per catalog). For the single catalog below, `num_keys` is `130 + 1 = 131`.

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
    %% Both `ets:foldl/3` and `lists:foldl/3` are specced as returning
    %% `term()` in OTP — eqwalizer can't carry the accumulator type
    %% through. We compute counts by manual recursion over an
    %% `ets:tab2list/1` snapshot, which preserves the precise
    %% accumulator type. Observability path, not a hot path.
    Counts = build_counts(ets:tab2list(?ETS_TABLE), #{}),
    maps:fold(
        fun({D, L}, N, Acc) -> [{D, L, N} | Acc] end,
        [],
        Counts
    ).

-spec build_counts(
    [tuple()],
    #{{domain(), locale()} => non_neg_integer()}
) -> #{{domain(), locale()} => non_neg_integer()}.
build_counts([], Acc) ->
    Acc;
build_counts([Obj | Rest], Acc) ->
    build_counts(Rest, count_per_catalog(Obj, Acc)).

%% Enumerate the keys (singular and plural) currently loaded for a given
%% (Domain, Locale). Plural entries are deduplicated — a single plural
%% msgid with N forms is reported once, not N times.
%%
%% Parity with `gettexter:which_keys/2`. ETS scan in the caller process,
%% no gen_server roundtrip.
-doc """
Enumerates the keys (singular and plural) loaded for `(Domain, Locale)`.

Returns a SORTED list of `{singular, Context, Msgid}` and
`{plural, Context, Msgid}`. Plural entries are DEDUPLICATED by
`(Context, Msgid)`: a plural msgid with N forms appears ONCE, not N times (the
`loaded_catalogs/0` count, by contrast, counts each form). Parity with
`gettexter:which_keys/2`.

ETS scan (`ets:tab2list/1`) in the calling process, with no roundtrip to the
`gen_server` — observability, not a hot path. Absent catalog -> empty list.

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
    %% Encapsulate the `ets:foldl/3` call in a tightly-typed helper so
    %% the resulting accumulator carries the precise shape we built
    %% (rather than the OTP-specced `term()`).
    #{singulars := Sings, plurals := PluralSet} =
        fold_keys(Domain, Locale),
    Plurals = plural_set_to_list(PluralSet),
    %% Sorted output for determinism in tests; not strictly required.
    %% Concat into the explicit union list type so eqwalizer carries the
    %% element type all the way through `lists:sort/1`.
    sort_keys(Sings, Plurals).

-type key_entry() ::
    {singular, context(), msgid()} | {plural, context(), msgid()}.

-spec sort_keys(
    [{singular, context(), msgid()}],
    [{plural, context(), msgid()}]
) -> [key_entry()].
sort_keys(Sings, Plurals) ->
    %% `lists:sort/1,2` is specced `[T] -> [T]` but eqwalizer's solver
    %% drops the T binding when T is a union of tuple shapes. A
    %% hand-rolled merge sort over the union type carries the precise
    %% type through and is acceptable here because `which_keys/2` is an
    %% observability call, not a hot path.
    Combined = combine_keys(Sings, Plurals),
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

%% Materialize the plural set into a precisely-typed list. `sets:to_list/1`
%% has a generic spec that eqwalizer can fail to instantiate when the
%% caller uses the result in heterogeneous contexts (here, mixed singular
%% and plural tuples flowing into `lists:sort/1`). Doing the conversion in
%% a helper with an explicit spec is the idiomatic narrow.
-spec plural_set_to_list(sets:set({context(), msgid()})) ->
    [{plural, context(), msgid()}].
plural_set_to_list(Set) ->
    sets:fold(
        fun({C, M}, Acc) -> [{plural, C, M} | Acc] end,
        [],
        Set
    ).

-type key_acc() ::
    #{
        singulars := [{singular, context(), msgid()}],
        plurals := sets:set({context(), msgid()})
    }.

-spec fold_keys(domain(), locale()) -> key_acc().
fold_keys(Domain, Locale) ->
    %% Manual recursion over an `ets:tab2list/1` snapshot. Same reason
    %% as `loaded_catalogs/0`: both `ets:foldl/3` and `lists:foldl/3`
    %% are typed `term()` and strip the accumulator's precise shape.
    Acc0 = #{
        singulars => [],
        plurals => sets:new([{version, 2}])
    },
    build_keys(ets:tab2list(?ETS_TABLE), Domain, Locale, Acc0).

-spec build_keys([tuple()], domain(), locale(), key_acc()) -> key_acc().
build_keys([], _D, _L, Acc) ->
    Acc;
build_keys([Obj | Rest], Domain, Locale, Acc) ->
    build_keys(Rest, Domain, Locale, collect_key(Domain, Locale, Obj, Acc)).

%% =========================
%% Load orchestration (Part 5)
%% =========================

%% Idempotent load. If the (Domain, Locale) catalog is already loaded,
%% returns `{ok, already}` without touching disk (RISK-012 mitigation 2).
%% Otherwise performs the full pipeline: read file, parse, compile plural
%% rule, validate against CLDR (warning only, never blocks), install in
%% ETS atomically.
-doc """
Idempotent load of a `.po` catalog. Same as `ensure_loaded/4` with `#{}`.

If `(Domain, Locale)` is already loaded (header present), returns
`{ok, already}` without touching disk. Otherwise it runs the full pipeline (read
file, parse, compile the plural rule, validate against CLDR as a WARNING —
divergence never blocks the load, install in ETS atomically) and returns
`{ok, NewlyLoaded}` with the number of inserted entries, or
`{error, ensure_error()}` leaving the ETS INTACT.

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

%% Finding #6: the heavy half (read+parse+compile+validate+bounds) runs in
%% the CALLING process inside the `[erli18n, catalog, load]' span, so the
%% measurement is per-tenant and OUTSIDE the server mailbox. Only the
%% validated payload is handed to the server for the millisecond commit,
%% with a caller-tunable timeout. The idempotent fast-path stays a pure ETS
%% read (no disk, no server roundtrip).
-doc """
Idempotent load of a `.po` catalog with resource options.

Idempotent fast-path: if the catalog is already loaded, returns `{ok, already}`
via a pure ETS read (no disk, no server roundtrip). On a miss, the heavy phase
(read+parse+compile+validate+bounds) runs in the CALLING process, inside the
span `[erli18n, catalog, load]`, and only the validated payload is handed to the
server for the millisecond commit.

`Opts` (all optional):
- `include_fuzzy` (default `false`): includes entries marked `#, fuzzy`.
- `max_bytes` (`non_neg_integer() | infinity`): rejects the file BEFORE reading
  it whole (via `filelib:file_size/1`) if it exceeds the limit; default comes
  from `application:get_env(erli18n, max_po_bytes)` (16 MiB). `infinity` = no cap.
- `max_entries` (`non_neg_integer() | infinity`): rejects the catalog AFTER the
  parse if it has more than N entries; default `application:get_env(erli18n,
  max_po_entries)` (500000). `infinity` = no cap.
- `timeout` (`timeout()`): deadline of the commit `gen_server:call/3` (default
  5000 ms; the commit is only the bulk insert, ~26 ms for 40k entries).

Returns `{ok, NewlyLoaded}`, `{ok, already}` or `{error, ensure_error()}`
(including `{input_too_large, _, _}` / `{too_many_entries, _, _}`), always before
any ETS mutation.

## Edge cases
- **Check-then-insert race**: the idempotent fast-path reads outside the
  serialization, but the commit RE-CHECKS idempotency under the mailbox (mode
  `ensure`), so two concurrent callers of the same catalog do not overwrite each
  other — the second sees `{ok, already}`.
- **CLDR divergence**: never an error; emits a warning log/telemetry and
  proceeds, storing the divergence in the `header_state()`.
- **`timeout` exceeded**: the commit `gen_server:call/3` may crash with
  `{timeout, _}`; since the commit is only the bulk insert, this practically
  only happens with a very tight `timeout`.

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
    %% `erli18n_telemetry:span/3' is specced `span_result() = term()' — it
    %% returns the first element of the closure tuple, which is always our
    %% `ensure_result()' (proven at the origin: `do_ensure_loaded/4' has a
    %% precise `-spec'). Re-announce that type at the boundary with one typed
    %% cast (findings #12/#18): the value is dynamic only because `span/3'
    %% erases it to `term()', not because we need to reconstruct it.
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

%% Idempotent fast-path (RISK-012 mitigation 2): a pure ETS read, no disk,
%% no server roundtrip. On a miss the heavy phase (`stage_catalog/4') runs
%% in this process and only the validated payload is committed.
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
                    %% serialization, closing the check-then-insert race
                    %% between two concurrent callers of the same catalog.
                    commit_call({commit, ensure, Domain, Locale, Staged}, Opts)
            end
    end.

%% Reload bypasses the idempotency check: always parses and re-installs.
%% Resolves AMB-001 overwrite semantics — the new catalog overwrites the
%% old one entry-by-entry.
%%
%% Finding #4 (reload-not-atomic-destroys-catalog-and-empty-window):
%% reload is STAGE -> ATOMIC-SWAP. The entire failable pipeline (read,
%% parse, plural compile, CLDR divergence) runs into an in-memory
%% `staged/0' record WITHOUT touching ETS, so a reload whose new `.po' is
%% invalid (syntax error, unsupported charset, bad Plural-Forms, missing
%% file) returns a structured `{error, _}' and leaves the previously-good
%% catalog FULLY INTACT — never destroyed. On success the only observable
%% mutation is insert-before-prune: every retained key is overwritten
%% old->new by an atomic `ets:insert/2', and only the keys absent from
%% the new catalog are pruned afterwards, so a concurrent reader of a
%% retained key never observes a miss window.
-doc """
Atomic reload of a `.po` catalog. Same as `reload/4` with `#{}`.

Unlike `ensure_loaded/3`, it NEVER takes the idempotent fast-path: it always
parses and reinstalls, overwriting the old catalog entry by entry (AMB-001). It
never returns `{ok, already}`. See `reload/4` for the atomic STAGE -> SWAP
semantics and the zero-miss-window guarantee.

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

%% Finding #6: like `ensure_loaded/4', the heavy STAGE runs in the caller
%% inside the `[erli18n, catalog, reload]' span; only the atomic SWAP commit
%% travels to the server with a tunable timeout. reload never takes the
%% idempotent fast-path: it always re-stages and re-installs.
-doc """
Atomic reload of a `.po` catalog with resource options (STAGE -> SWAP).

reload is an atomic STAGE -> SWAP. The entire failable half (read, parse, compile
plural, CLDR divergence) runs in the CALLING process into an in-memory `staged/0`
WITHOUT touching the ETS, so a reload whose new `.po` is invalid (syntax error,
unsupported charset, bad `Plural-Forms`, missing file) returns a structured
`{error, _}` and leaves the previous catalog FULLY INTACT — never destroyed. On
success, the only observable mutation is insert-before-prune: each retained key
is overwritten old->new by an atomic `ets:insert/2`, and only the keys absent
from the new catalog are pruned afterwards — a concurrent reader of a retained
key never observes a miss window.

The heavy phase runs inside the span `[erli18n, catalog, reload]`; only the swap
commit travels to the server, with a tunable `timeout`. `Opts` is identical to
`ensure_loaded/4`'s (`include_fuzzy`, `max_bytes`, `max_entries`, `timeout`).
Returns `{ok, NewlyLoaded}` or `{error, ensure_error()}` (never `{ok, already}`).

## Edge cases
- **Transient memory doubles** during the swap (old + new rows coexist) — a
  deliberate cost of atomicity.
- **Stale keys** (present in the old catalog, absent in the new) serve the OLD
  translation for microseconds before the prune — consistent with gettext,
  better than a miss.
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

%% Hand the validated payload to the owner and narrow the reply. The commit
%% is only the bulk insert (~26ms for 40k entries measured live), so the
%% default 5000ms is generous; the override exists for deployments that
%% want it tighter or `infinity`.
-spec commit_call(commit_msg(), opts()) -> ensure_result().
commit_call(Msg, Opts) ->
    Timeout = maps:get(timeout, Opts, 5000),
    cast_ensure_result(gen_server:call(?MODULE, Msg, Timeout)).

-type commit_msg() ::
    {commit, ensure | reload, domain(), locale(), staged()}.

%% Finding #6, bulk API. Load N catalogs: the heavy phase of each runs in
%% THIS process (sequential prepare — the v0.1 trade-off documented in the
%% design; a parallel fan-out is a future evolution), and every
%% ready-to-insert payload is delivered in a SINGLE commit. That collapses N
%% server roundtrips into one and (with finding #7's O(1) index) the per-
%% catalog idempotency check is O(1), not an O(total_rows) `tab2list' scan.
%% Already-loaded or failing catalogs are reported individually; one
%% catalog's error never blocks the others.
-doc """
Bulk load of N catalogs with a single commit on the server.

`Specs` is `[{Domain, Locale, PoPath, Opts}]`. The heavy phase of each spec runs
in the calling process (sequential preparation — the v0.1 trade-off; a parallel
fan-out is a future evolution) and all ready payloads are delivered in a SINGLE
commit, collapsing N roundtrips into one and making the per-catalog idempotency
check O(1) (finding #7's O(1) index). Each `Opts` follows `ensure_loaded/4`.

Returns `[{Domain, Locale, ensure_result()}]` — already-loaded or failed catalogs
are reported individually; one catalog's error never blocks the others.

## Edge cases
- Each result element is an independent `ensure_result()`: you can have a mix of
  `{ok, N}`, `{ok, already}` and `{error, _}` in the same list.
- Empty list -> `[]` (no roundtrip to the server).
- If ALL specs are idempotent/error in the preparation phase, no commit is sent
  (`commit_many` only runs when there is >=1 validated payload).

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

%% Findings #12 / #18 — single typed boundary cast (replaces the former
%% ~245-LOC `narrow_*'/`classify_*'/`is_known_*' tree).
%%
%% A `gen_server:call/2,3' reply (and an `erli18n_telemetry:span/3' result)
%% is specced `term()' in OTP because the callback module is resolved at
%% RUNTIME — the type-checker cannot carry the `handle_call/3' reply type
%% across the call. For `erli18n_server' the call is always same-node,
%% same-module, synchronous: every reply is an `ensure_result()' (proven at
%% the ORIGIN — `do_ensure_loaded/4', `do_commit/4', `do_commit_many/1' and
%% `install_staged/3' all carry precise `-spec's). So the boundary only has
%% to re-announce a type that is already proven server-side, not reconstruct
%% it. The cast helper returns the value unchanged and is annotated with
%% `-eqwalizer({nowarn_function, ...})' so the type-checker accepts the
%% `term() -> ensure_result()' boundary. We deliberately do NOT use
%% `eqwalizer:dynamic_cast/1' here: that is a RUNTIME call into the `eqwalizer'
%% module shipped by `eqwalizer_support', a test-only `git_subdir' dependency
%% Hex cannot package — so a published build would crash with `undefined
%% function eqwalizer:dynamic_cast/1'. The static annotation is equivalent for
%% the type-checker at zero runtime cost. Same pattern in
%% `dynamic_cast_index_keyset/1'.
%%
%% This deletes the old hand-maintained enumeration (a 48-clause
%% `narrow_posix/1' restating the entire `file:posix()' set, plus the
%% `is_known'/`narrow_known' twins re-listing `ensure_error()') and the two
%% dead defensive crash branches it embedded — `narrow_posix(Other) ->
%% error({unknown_posix_atom, _})' and the `{load_failed, _}' catch-all —
%% which could only ever fire on a contract the server itself never produces,
%% yet turned a benign structured `file:posix()' error into a CALLER CRASH
%% (finding #18). `file:posix()' is an open union; the cast is total over it
%% by construction, so a future OTP posix atom now flows through as a
%% structured `{error, {file_error, _}}' instead of crashing.
-spec cast_ensure_result(term()) -> ensure_result().
cast_ensure_result(Reply) ->
    Reply.

%% As `cast_ensure_result/1' but for the bulk `{commit_many, _}' reply: the
%% server callback (`do_commit_many/1', specced precisely) returns a list of
%% `{domain(), locale(), ensure_result()}'. One cast re-announces that type.
-spec cast_commit_many(term()) -> [{domain(), locale(), ensure_result()}].
cast_commit_many(Reply) ->
    Reply.

%% Compute the gettext-style convention path for a given application,
%% domain, and locale: `<priv>/locale/<Locale>/LC_MESSAGES/<Domain>.po`.
%% Separation of concerns: the façade (Part 6) decides whether to honour
%% this convention or use a caller-supplied path. `ensure_loaded` itself
%% takes the path explicitly — no implicit resolution inside this module.
-doc """
Computes the conventional gettext `.po` path for an application.

## Parameters
- `App`: the OTP application whose `priv` contains the catalogs (resolved via
  `code:priv_dir/1`).
- `Domain`: the gettext domain (becomes the file name `<Domain>.po`).
- `Locale`: the binary locale (becomes the directory segment `<Locale>`).

## Return
Returns `<priv>/locale/<Locale>/LC_MESSAGES/<Domain>.po` (a string).
This function only COMPOSES the path — it does not check whether the file exists.

## Failure modes
Crashes with `{priv_dir_not_found, App}` if the application is unknown
(`code:priv_dir/1` returns `{error, bad_name}`) — so the operator sees the
misconfiguration immediately, instead of loading a path with `{error, bad_name}`
embedded. Separation of concerns: `ensure_loaded/3` takes the path explicitly;
there is no implicit resolution here — it is the façade that decides whether to
honour this convention or use a caller-supplied path.

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
    %% `code:priv_dir/1` returns `file:filename() | {error, bad_name}`.
    %% A `bad_name` means the application is unknown — crash explicitly
    %% so the operator sees the misconfiguration immediately, instead of
    %% silently building a path with `{error, bad_name}` embedded in it.
    PrivDir =
        case code:priv_dir(App) of
            {error, bad_name} ->
                error({priv_dir_not_found, App});
            Dir when is_list(Dir) ->
                Dir
        end,
    %% `filename:join/1` is specced `file:filename_all()`; we need
    %% `file:filename()` (a string) for the public contract. All inputs
    %% are strings (`PrivDir`, literal strings, `binary_to_list/1`,
    %% `atom_to_list/1` + concat), so the result is a string too.
    %% Narrow at the boundary so an unexpected binary surfaces as a
    %% badmatch instead of corrupting the contract downstream.
    Joined = filename:join([
        PrivDir,
        "locale",
        binary_to_list(Locale),
        "LC_MESSAGES",
        atom_to_list(Domain) ++ ".po"
    ]),
    case Joined of
        Str when is_list(Str) -> Str;
        Other -> error({unexpected_filename_shape, Other, expected, string})
    end.

%% =========================
%% gen_server callbacks
%% =========================

-doc """
Initialization callback — NOTE FOR THE MAINTAINER (do not call by hand; it is
the supervisor that invokes it via `start_link/0`).

## Table acquisition protocol (heir / ETS-TRANSFER)
This server does NOT create the data table (finding #10). It asks
`erli18n_table_owner` (a sibling started BEFORE it under `rest_for_one`) to hand
it over via `give_away/3`. The sequence:
1. `erli18n_table_owner:claim_table/0` (synchronous) — signals the owner to hand
   over.
2. Blocks on `receive {'ETS-TRANSFER', ?ETS_TABLE, _, ?ETS_HANDOFF_DATA}`.
3. Creates the secondary index (`?CATALOG_INDEX_TABLE`) and REBUILDS it from the
   surviving rows of the data table (on initial boot it is a no-op; after a
   crash of this worker, the table comes back populated by the heir and the
   index is rebuilt ONCE here, not per load).

## Invariants
- The `State` is `#{}` (empty): all the truth lives in the two ETS tables. Do not
  keep catalog state in `State`.
- This server is the SOLE writer of both tables, so the O(1) index never diverges
  while the worker is alive.

## Failure modes
If the owner does not hand the table over within 5s, it crashes with
`{ets_handoff_timeout, _}` — something structurally broken in the tree; the
supervisor re-evaluates. After a crash of this worker, the catalogs are NOT lost
(the owner is the heir).

See `start_link/0`.
""".
-spec init([]) -> {ok, map()}.
init([]) ->
    %% Finding #10: the server no longer CREATES the table. It asks the
    %% dedicated owner (`erli18n_table_owner', started before us under
    %% `rest_for_one') to hand it over via `give_away/3'. `claim_table/0'
    %% is synchronous; once it returns, the initial `'ETS-TRANSFER'' is on
    %% its way. We become the table proprietor (writer of the protected
    %% table) by consuming it below. This way an abrupt crash of this
    %% worker transfers the table back to the owner (heir) with all rows
    %% intact instead of destroying every loaded catalog.
    ok = erli18n_table_owner:claim_table(),
    receive
        {'ETS-TRANSFER', ?ETS_TABLE, _OwnerPid, ?ETS_HANDOFF_DATA} ->
            ok
    after 5000 ->
        %% The owner is a sibling child started BEFORE us (rest_for_one);
        %% if it has not handed the table over within 5s something is
        %% structurally broken — crashing is the correct OTP behaviour
        %% (the supervisor re-evaluates).
        error({ets_handoff_timeout, ?ETS_TABLE})
    end,
    %% Finding #7: create the authoritative O(1) catalog index and seed it
    %% from whatever rows survived in the data table. On first boot the
    %% data table is empty so this is a no-op; after a worker crash the
    %% data table comes back (heir handoff) populated, so we rebuild the
    %% index once here instead of scanning the table on every load. The
    %% server is the table's sole writer, so an index it owns can never
    %% diverge while the worker is alive.
    _ = create_catalog_index(),
    ok = rebuild_catalog_index(),
    {ok, #{}}.

%% Create the side index table if it does not already exist. The table is
%% server-owned (dies with the worker, rebuilt on `init/1') and protected:
%% only this process writes to it. Re-entrant so a worker restart that
%% inherits a stale name (it won't — the table dies with the old worker)
%% degrades to a no-op rather than crashing.
-spec create_catalog_index() -> ets:table().
create_catalog_index() ->
    case ets:info(?CATALOG_INDEX_TABLE, name) of
        undefined ->
            ets:new(?CATALOG_INDEX_TABLE, [
                set,
                protected,
                named_table,
                {read_concurrency, true},
                {keypos, 1}
            ]);
        _Existing ->
            ?CATALOG_INDEX_TABLE
    end.

%% Rebuild the index from the data table. Runs exactly once per worker
%% lifetime (in `init/1'), NOT on the per-load path. Cost is O(rows) of
%% the surviving table — paid only after a crash, never repeated. We clear
%% first so a re-entrant rebuild stays idempotent.
-spec rebuild_catalog_index() -> ok.
rebuild_catalog_index() ->
    true = ets:delete_all_objects(?CATALOG_INDEX_TABLE),
    seed_index(ets:tab2list(?ETS_TABLE)),
    ok.

-spec seed_index([tuple()]) -> ok.
seed_index([]) ->
    ok;
seed_index([Obj | Rest]) ->
    _ = index_obj(Obj),
    seed_index(Rest).

%% Register a single surviving data row's key in its catalog's index key
%% set (finding #13). Header rows carry no user-visible entries and are not
%% data keys, so they do NOT register — same rule `memory_info/0' has
%% always used (a header-only `.po' is not a catalog for counting
%% purposes), and they are not range-deleted via the key set on unload
%% (the header is removed by its own O(1) key delete).
-spec index_obj(tuple()) -> ok.
index_obj({{singular, D, L, Ctx, Msgid}, _}) ->
    index_add_keys(D, L, [?SINGULAR_KEY(D, L, Ctx, Msgid)]);
index_obj({{plural, D, L, Ctx, Msgid, Idx}, _}) ->
    index_add_keys(D, L, [?PLURAL_KEY(D, L, Ctx, Msgid, Idx)]);
index_obj(_Other) ->
    ok.

-doc """
Serialized critical section — NOTE FOR THE MAINTAINER. This is the ONLY place
where the ETS is mutated; every write in the module passes through here under the
single mailbox, so there is never observable mixed state (ETS-`set` inserts
atomically per row).

## Message protocol (all call variants)
- `{insert_singular, D, L, Ctx, Msgid, T}` -> writes 1 row + indexes the key;
  reply `ok`. (API: `insert_singular/5`.)
- `{insert_plural, D, L, Ctx, Msgid, Entries}` -> writes 1 row per form +
  indexes; reply `ok`. (API: `insert_plural/5`.)
- `{insert_catalog, D, L, Entries}` -> flattens and writes the batch + indexes;
  reply `ok`. (API: `insert_catalog/3`.)
- `{unload, D, L}` -> O(catalog size) deletion via the index + removes the
  header; emits the span `[erli18n, catalog, unload]`; reply is ALWAYS `ok`
  (historical contract of `unload/2`).
- `{commit, ensure | reload, D, L, Staged}` -> installs an ALREADY validated
  `staged()` (the heavy phase ran in the caller). Mode `ensure` RE-CHECKS
  idempotency under serialization (closes the check-then-insert race); mode
  `reload` does the atomic insert-before-prune swap (finding #4). There is NO
  span here — it already fired caller-side.
- `{commit_many, Items}` -> installs N payloads in one critical section, with ONE
  `memory_warning_check` at the end (not N).
- Any other call -> `{reply, {error, unknown_call}, State}`.

## Invariant
The server receives ONLY validated payloads in the commits — no heavy
read/parse/compile runs behind this mailbox (finding #6). That is why this
callback is the millisecond section.
""".
handle_call({insert_singular, D, L, Ctx, Msgid, T}, _From, State) ->
    Key = ?SINGULAR_KEY(D, L, Ctx, Msgid),
    true = ets:insert(?ETS_TABLE, {Key, T}),
    %% Findings #7/#13: maintain the catalog index incrementally. A
    %% singular insert always writes exactly one data row, so the catalog
    %% now has >=1 entry — record its key (idempotent on the `set').
    index_add_keys(D, L, [Key]),
    {reply, ok, State};
handle_call({insert_plural, D, L, Ctx, Msgid, Entries}, _From, State) ->
    %% Build a strictly-tuple list so `ets:insert/2` sees the precise
    %% type it expects. The list comprehension binds {Idx, T} from each
    %% entry; the result tuple has fixed arity 2 and is always a tuple.
    Objects = build_plural_objects(D, L, Ctx, Msgid, Entries),
    true = ets:insert(?ETS_TABLE, Objects),
    %% Only register the keys actually written. An empty form list inserts
    %% nothing, so it must not bump the catalog count (membership rule:
    %% index row present <=> >=1 data entry).
    index_add_keys(D, L, object_keys(Objects)),
    {reply, ok, State};
handle_call({insert_catalog, D, L, Entries}, _From, State) ->
    Objects = build_catalog_objects(D, L, Entries),
    true = ets:insert(?ETS_TABLE, Objects),
    index_add_keys(D, L, object_keys(Objects)),
    {reply, ok, State};
handle_call({unload, D, L}, _From, State) ->
    %% Span: [erli18n, catalog, unload]. Always-on (frequency is bounded —
    %% admin operation, not hot path).
    %% Metadata schema:
    %%   start:     #{domain, locale}
    %%   stop:      #{domain, locale, result :: ok | not_loaded,
    %%                keys_removed}
    %%   exception: #{domain, locale, kind, reason, stacktrace}
    %%
    %% telemetry:span/3 passes ONLY the stop metadata returned by the
    %% closure to the stop event (NOT merged with the start metadata —
    %% see https://hexdocs.pm/telemetry/telemetry.html#span-3 and the
    %% upstream impl in telemetry/src/telemetry.erl). So the closure
    %% must build the full stop metadata, repeating the base fields.
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
    %% Preserve the historical public contract of `unload/2`.
    {reply, ok, State};
%% Finding #6: the server now receives ONLY validated, ready-to-insert
%% payloads. The heavy read+parse+compile already ran in the caller (inside
%% the load/reload span), so this clause is the millisecond critical section
%% — the only work that requires the owner of the `protected' table. The
%% telemetry span fired caller-side, so no span here.
%%
%% `ensure' mode re-checks idempotency UNDER serialization, closing the
%% check-then-insert race between two concurrent callers preparing the same
%% catalog. `reload' mode does the finding-#4 atomic insert-before-prune
%% swap.
handle_call({commit, Mode, D, L, Staged}, _From, State) ->
    {reply, do_commit(Mode, D, L, Staged), State};
%% Bulk commit (finding #6): N validated payloads installed in one critical
%% section, with a single deferred `memory_warning_check' (finding #7) at
%% the end instead of one per catalog.
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
Inert by design: this server expects no out-of-band messages. The initial
`'ETS-TRANSFER'` is consumed in `init/1` by an explicit `receive`, not here; a
return `'ETS-TRANSFER'` after a crash reaches the OWNER (heir), not this worker.
Messages are ignored with `{noreply, State}`.
""".
handle_info(_Info, State) ->
    {noreply, State}.

-doc """
No cleanup to do: the data table is `protected` and has a `heir` (the owner), so
on a crash of this worker it returns INTACT to the owner instead of being
destroyed — exactly the scenario this architecture protects. The secondary index
is server-owned and dies with the worker, being rebuilt on the next `init/1`.
Returns `ok`.
""".
terminate(_Reason, _State) ->
    ok.

-doc """
No state migration: the `State` is an empty `#{}` (the truth lives in ETS), so a
code upgrade has no state to transform. Returns `{ok, State}`.
""".
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =========================
%% Internal: commit (owner-only critical section) — finding #6
%% =========================
%%
%% The heavy half (read+parse+compile+validate+bounds) already ran in the
%% caller (`stage_catalog/4'), producing a validated `staged/0' payload.
%% `do_commit/4' is the ONLY work that requires the owner of the `protected'
%% table: it is ETS-`set' inserts (atomic per row) under the single mailbox,
%% so no observable mixed state. `ensure' re-checks idempotency under
%% serialization; `reload' does the finding-#4 atomic swap.
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
    %% Atomic insert-before-prune (finding #4): retained keys never miss.
    swap_catalog(Domain, Locale, Staged).

%% Bulk commit (finding #6): install N validated payloads in one critical
%% section. Each catalog is idempotency-checked (O(1) via the finding-#7
%% index) and installed without its own `memory_warning_check' — that scan
%% is deferred to a SINGLE call after the whole batch, so a bulk of N is not
%% N memory checks.
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

%% Install a validated `staged/0' for a fresh (Domain, Locale): insert the
%% data rows + header, register the index keys, emit the precomputed
%% side-effects, and run the post-install `memory_warning_check'. Nothing
%% here can fail (the failable work happened in the caller), so the commit
%% is total and cheap.
-spec install_staged(domain(), locale(), staged()) ->
    {ok, non_neg_integer()}.
install_staged(Domain, Locale, Staged) ->
    Result = install_staged_no_memcheck(Domain, Locale, Staged),
    %% Memory warning check runs after the insert so the measurement
    %% reflects the post-install state (RISK-011 mitigation 2). Rate-limited
    %% inside `erli18n_telemetry:memory_warning_check/1'.
    _ = erli18n_telemetry:memory_warning_check(memory_info()),
    Result.

%% As `install_staged/3' but WITHOUT the per-catalog memory check, so the
%% bulk path can defer it to one call after the whole batch.
-spec install_staged_no_memcheck(domain(), locale(), staged()) ->
    {ok, non_neg_integer()}.
install_staged_no_memcheck(Domain, Locale, Staged) ->
    #{
        objects := Objects,
        new_keys := NewKeys,
        header := HeaderState,
        divergence := Divergence,
        num_entries := NumEntries,
        fuzzy_skipped := FuzzySkipped
    } = Staged,
    emit_divergence_log(Domain, Locale, Divergence),
    %% Telemetry: [erli18n, plural, divergence_warning]. Always-on
    %% (load-time, infrequent).
    emit_divergence_telemetry(Domain, Locale, Divergence),
    emit_fuzzy_skip(Domain, Locale, FuzzySkipped),
    %% Findings #7/#13: register the catalog's data keys (iff >=1 row).
    case Objects of
        [] -> ok;
        [_ | _] -> true = ets:insert(?ETS_TABLE, Objects)
    end,
    %% Register the catalog's exact key set (or drop the row for a
    %% header-only / degenerate-plural catalog), per the finding-#7
    %% membership rule. Same primitive the reload swap uses.
    rewrite_index(Domain, Locale, NewKeys),
    true = ets:insert(
        ?ETS_TABLE,
        {?HEADER_KEY(Domain, Locale), HeaderState}
    ),
    {ok, NumEntries}.

%% Emit the (caller-precomputed) fuzzy-skip count. The heavy second parse
%% that produced this count ran in the caller (`compute_fuzzy_skipped/3'),
%% so the owner only fires the telemetry event — no re-parse on the server.
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
%% `{ok, Compiled | fallback}` where `fallback` signals "no header was
%% present" — the lookup hot path then uses the C/Germanic default
%% (`fallback_form_index/1`) instead of evaluating an AST.
%%
%% This avoids paying compile cost on the load path for catalogs that ship
%% without a `Plural-Forms` header, and lets the runtime branch on a
%% small atom rather than a map.
%% The parser always emits #{plural_forms := _} (see erli18n_po
%% `empty_header/0` and `build_header/1`), so the two clauses below are
%% exhaustive for any header produced by erli18n_po:parse/{1,2}. A
%% missing key here would be a parser invariant break and is allowed to
%% crash with function_clause.
%%
%% Findings #12 / #18: this `-spec' anchors the `compile_error()' union at
%% the ORIGIN. With the reply-boundary narrowing tree gone, the compile error
%% must be proven typed where it is constructed (here), not reclassified at
%% the boundary — so eqwalizer rejects in BUILD any return outside this union
%% (stronger than the deleted runtime re-validation).
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

%% Header divergence vs CLDR is informational only (PSD-004). When the
%% header is absent we have nothing to compare; when the locale is not in
%% the CLDR table we can't compare either. In both cases we report
%% `none`.
%%
%% Finding #17 (compute-divergence-recompiles-header-and-cldr-each-load):
%% takes the ALREADY compiled plural bundle (kept by `maybe_compile_plural/1`
%% at the `stage_compiled` call site) and hands it straight to
%% `validate_against_cldr_ast/2`, which reuses the parsed AST and a
%% memoised CLDR-AST table. The old code passed the header MAP and let
%% `validate_against_cldr/2` recompile the same expression a SECOND time
%% (plus synthesise+compile a CLDR rule and linear-scan the CLDR list) on
%% every real load. The `fallback` atom means the catalog shipped without
%% a `Plural-Forms` header, so there is nothing to compare.
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

%% Per BR-MIGRAR-030, log uses OTP logger with `#{domain => [erli18n,
%% server]}` metadata. Telemetry emission is deferred to Parte 7; the
%% divergence info is preserved in the header_state so a later telemetry
%% layer can publish it without re-loading the catalog.
emit_divergence_log(_Domain, _Locale, none) ->
    ok;
emit_divergence_log(Domain, Locale, {plural_divergence, HdrRule, CldrRule}) ->
    ?LOG_WARNING(
        #{
            event => plural_divergence,
            domain_name => Domain,
            locale => Locale,
            header_rule => HdrRule,
            cldr_rule => CldrRule
        },
        #{domain => [erli18n, server]}
    ),
    ok.

%% Telemetry counterpart to the ?LOG_WARNING above. Always emitted on
%% real divergence; skipped on `none`. Emits the event
%% `[erli18n, plural, divergence_warning]`.
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

%% Build the list of ETS objects for a single plural msgid. Each entry
%% is a `{Index, Translation}` tuple; the output rows are
%% `{?PLURAL_KEY/5, Translation}` tuples. The explicit `tuple()` element
%% spec keeps `ets:insert/2` typed without weakening the inner shape.
-spec build_plural_objects(
    domain(),
    locale(),
    context(),
    msgid(),
    [{plural_index(), translation()}]
) -> [tuple()].
build_plural_objects(_D, _L, _Ctx, _Msgid, []) ->
    [];
build_plural_objects(D, L, Ctx, Msgid, [{Idx, T} | Rest]) when
    is_integer(Idx), Idx >= 0
->
    [
        {?PLURAL_KEY(D, L, Ctx, Msgid, Idx), T}
        | build_plural_objects(D, L, Ctx, Msgid, Rest)
    ].

%% Flatten a list of catalog entries to ETS object tuples. The spec
%% pins the element type to `tuple()` so `ets:insert/2` is typed
%% correctly.
-spec build_catalog_objects(
    domain(),
    locale(),
    [catalog_entry()]
) -> [tuple()].
build_catalog_objects(_D, _L, []) ->
    [];
build_catalog_objects(D, L, [E | Rest]) ->
    entry_to_objects(D, L, E) ++ build_catalog_objects(D, L, Rest).

%% =========================
%% Finding #4/#6: STAGE (heavy phase, runs in the CALLER)
%% =========================
%%
%% `stage_catalog/4' runs the entire FAILABLE, heavy half of the load
%% pipeline — bounds check, file read, parse, plural compile, CLDR
%% divergence, object build, fuzzy count — and produces a pure in-memory
%% `staged/0' payload. It performs ZERO ETS mutation, so on `{error, _}' the
%% prior catalog is provably untouched.
%%
%% Finding #6: this now runs in the CALLING process (not the gen_server), so
%% a large/slow/pathological `.po' from one tenant never blocks another
%% tenant's load, and a slow parse never burns the server mailbox. Only the
%% resulting payload travels to the owner for the millisecond commit.
%%
%% Failure order (all BEFORE any mutation, as before):
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

%% Size cap applied BEFORE reading the whole file into memory:
%% `filelib:file_size/1' stats the file, it does not load bytes. Closes the
%% door on a gigabyte `.po' blowing the heap just to read it (finding #6).
%% `infinity' = no cap (explicit legacy behaviour).
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

%% Pure entry-cap + compile + object build + fuzzy count half of staging.
%% The entry cap rejects an over-large catalog AFTER the parse (we need the
%% parsed entry count); compile failure is the last failable step. On
%% success we materialize the ETS objects, their data-key set, and the
%% caller-computed fuzzy_skipped count so the commit has nothing heavy left.
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
        false ->
            {error, {too_many_entries, NumEntries, narrow_cap(MaxEntries)}};
        true ->
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

-spec within_entry_cap(non_neg_integer(), non_neg_integer() | infinity) ->
    boolean().
within_entry_cap(_N, infinity) -> true;
within_entry_cap(N, Max) when is_integer(Max) -> N =< Max.

%% `within_entry_cap/2' only returns `false' for the integer-cap clause, so
%% in the error path the cap is provably a `non_neg_integer()'. Narrow it for
%% the `too_many_entries' tuple so eqwalizer sees the closed shape.
-spec narrow_cap(non_neg_integer() | infinity) -> non_neg_integer().
narrow_cap(N) when is_integer(N), N >= 0 -> N;
narrow_cap(infinity) -> error(unreachable_infinity_cap).

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
            %% Finding #17: pass the ALREADY compiled bundle, not the raw
            %% header map, so the divergence check does not recompile the
            %% same expression a second time.
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
            Objects = build_catalog_objects(Domain, Locale, Entries),
            NewKeys = sets:from_list(
                object_keys(Objects), [{version, 2}]
            ),
            FuzzySkipped = compute_fuzzy_skipped(IncludeFuzzy, Bin, NumEntries),
            {ok, #{
                objects => Objects,
                new_keys => NewKeys,
                header => HeaderState,
                divergence => Divergence,
                domain => Domain,
                locale => Locale,
                raw_bin => Bin,
                include_fuzzy => IncludeFuzzy,
                num_entries => NumEntries,
                fuzzy_skipped => FuzzySkipped
            }}
    end.

%% Count the fuzzy entries the default parse dropped, computed in the CALLER
%% (finding #6: the heavy second parse no longer runs on the server). Only
%% re-parses when the consumer opted in to lookup telemetry AND the default
%% (non-fuzzy) load discarded fuzzy entries — identical gate to the original
%% `maybe_emit_fuzzy_skip/5'. The emit itself happens at commit time from the
%% precomputed count.
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
            %% Re-parse with include_fuzzy => true against the same bytes
            %% that already parsed successfully with include_fuzzy => false.
            %% The flag only changes which entries are kept; a failure here
            %% would be a parser invariant break, so we match exactly.
            {ok, #{entries := AllEntries}} =
                erli18n_po:parse(Bin, #{include_fuzzy => true}),
            erlang:max(0, length(AllEntries) - DefaultCount)
    end.

%% Bounds defaults (finding #6), configurable via application env so a
%% deployment can tune or disable (`infinity') them. Generous enough for
%% real catalogs (gettext "large" rarely exceeds a few MB) but finite for
%% safety.
-spec default_max_bytes() -> non_neg_integer() | infinity.
default_max_bytes() ->
    narrow_bound(application:get_env(erli18n, max_po_bytes, 16 * 1024 * 1024)).

-spec default_max_entries() -> non_neg_integer() | infinity.
default_max_entries() ->
    narrow_bound(application:get_env(erli18n, max_po_entries, 500000)).

%% `application:get_env/3' is specced `term()'; narrow the configured value
%% to the bound shape at the boundary. A non-conforming env value is a
%% deployment misconfiguration and crashes with a descriptive payload.
-spec narrow_bound(term()) -> non_neg_integer() | infinity.
narrow_bound(infinity) -> infinity;
narrow_bound(N) when is_integer(N), N >= 0 -> N;
narrow_bound(Other) -> error({invalid_erli18n_bound, Other}).

%% `swap_catalog/3' is the ONLY mutating step. It is insert-before-prune:
%%   1. snapshot the OLD catalog's data keys (before any mutation);
%%   2. `ets:insert/2' all new data rows — atomic and isolated, so every
%%      key present in both catalogs flips old->new with no observable
%%      intermediate state (zero miss for retained keys);
%%   3. `ets:insert/2' the header row;
%%   4. delete ONLY the stale keys (old minus new) — retained keys are
%%      never deleted, so a concurrent reader sees old-then-new, never a
%%      gap.
%% Side-effecting emits (divergence log/telemetry, fuzzy_skip) fire here,
%% post-stage, preserving the observable behavior the old `reload' had.
-spec swap_catalog(domain(), locale(), staged()) -> {ok, non_neg_integer()}.
swap_catalog(Domain, Locale, Staged) ->
    #{
        objects := Objects,
        new_keys := NewKeys,
        header := HeaderState,
        divergence := Divergence,
        num_entries := NumEntries,
        fuzzy_skipped := FuzzySkipped
    } = Staged,
    emit_divergence_log(Domain, Locale, Divergence),
    emit_divergence_telemetry(Domain, Locale, Divergence),
    %% Finding #6: the fuzzy count was computed caller-side (no re-parse on
    %% the owner); the commit just emits the precomputed value.
    emit_fuzzy_skip(Domain, Locale, FuzzySkipped),
    %% (1) snapshot the old data keys BEFORE mutating.
    OldKeySet = index_key_set(Domain, Locale),
    %% (2) insert all new data rows (atomic, isolated). An empty catalog
    %% (header-only or degenerate plural) inserts nothing.
    case Objects of
        [] -> ok;
        [_ | _] -> true = ets:insert(?ETS_TABLE, Objects)
    end,
    %% (3) insert the header row (infallible, never indexed).
    true = ets:insert(
        ?ETS_TABLE,
        {?HEADER_KEY(Domain, Locale), HeaderState}
    ),
    %% (4) prune ONLY the stale keys (present in old, absent in new) so
    %% retained keys never miss. The index is rewritten to exactly the new
    %% key set (findings #7/#13 membership rule).
    Stale = sets:subtract(OldKeySet, NewKeys),
    prune_stale_keys(sets:to_list(Stale)),
    rewrite_index(Domain, Locale, NewKeys),
    _ = erli18n_telemetry:memory_warning_check(memory_info()),
    {ok, NumEntries}.

%% Delete each stale data key from the catalog table. O(#stale) on a
%% `set'; retained keys are never in this list.
-spec prune_stale_keys([data_key()]) -> ok.
prune_stale_keys([]) ->
    ok;
prune_stale_keys([Key | Rest]) ->
    true = ets:delete(?ETS_TABLE, Key),
    prune_stale_keys(Rest).

%% Replace the catalog's index row with exactly the new key set. When the
%% new catalog has >=1 data key we install that set; when it is empty
%% (header-only / degenerate plural) we drop the index row entirely so the
%% finding-#7 membership rule ("row present <=> >=1 data entry") holds.
-spec rewrite_index(domain(), locale(), sets:set(data_key())) -> ok.
rewrite_index(Domain, Locale, NewKeys) ->
    case sets:is_empty(NewKeys) of
        true ->
            index_delete(Domain, Locale);
        false ->
            true = ets:insert(
                ?CATALOG_INDEX_TABLE, {{Domain, Locale}, NewKeys}
            ),
            ok
    end.

%% Counts the rows actually deleted so the unload span can report
%% `keys_removed`. The result atom mirrors the schema: `not_loaded` when
%% there was nothing to delete, `ok` otherwise. This is the
%% catalog-removal primitive behind the `unload`
%% handle_call; the `reload` path no longer deletes-then-reloads (finding
%% #4: it STAGEs then atomically swaps via `swap_catalog/3').
%%
%% Finding #13: deletion is O(catalog size), not O(total rows). We read the
%% target catalog's data keys from the secondary index and `ets:delete/2'
%% each (O(1) per key on a `set'), then remove the header by its own O(1)
%% key delete. This replaces the previous `ets:select_delete/2' with a
%% partial-key match spec, which on a `set' table cannot probe by a (D, L)
%% prefix and so scanned EVERY row of ALL resident catalogs.
-spec do_unload_with_count(domain(), locale()) ->
    {ok | not_loaded, non_neg_integer()}.
do_unload_with_count(Domain, Locale) ->
    DataKeys = index_keys(Domain, Locale),
    DataDeleted = delete_keys(DataKeys, 0),
    %% The header is not a data key (no index entry), so delete it directly.
    %% `ets:take/2' removes and returns it atomically, letting us count
    %% whether it was present (a header-only `.po' has a header but no data
    %% keys / no index row — it must still report 1 removed row here, as
    %% the old full-scan match spec did).
    HeaderDeleted =
        case ets:take(?ETS_TABLE, ?HEADER_KEY(Domain, Locale)) of
            [] -> 0;
            [_ | _] -> 1
        end,
    %% Findings #7/#13: drop the catalog from the index. Unload is the only
    %% bulk removal path (the write API has no per-key delete), so this is
    %% where index rows disappear. `index_delete/2' is idempotent — a
    %% never-loaded (Domain, Locale) was never in the index.
    index_delete(Domain, Locale),
    Deleted = DataDeleted + HeaderDeleted,
    Result =
        case Deleted of
            0 -> not_loaded;
            _ -> ok
        end,
    {Result, Deleted}.

%% Delete each data key from the catalog table, tallying how many were
%% present. `ets:delete/2' is O(1) on a `set'; the loop is O(length(Keys))
%% — i.e. O(target catalog size), independent of total resident rows.
%% `ets:member/2' guards the count so a stale index key (which cannot
%% happen while the server is the sole writer) would not inflate the tally.
-spec delete_keys([data_key()], non_neg_integer()) -> non_neg_integer().
delete_keys([], Acc) ->
    Acc;
delete_keys([Key | Rest], Acc) ->
    Acc1 =
        case ets:member(?ETS_TABLE, Key) of
            true ->
                true = ets:delete(?ETS_TABLE, Key),
                Acc + 1;
            false ->
                Acc
        end,
    delete_keys(Rest, Acc1).

%% Build the stop metadata for the catalog load/reload span. Maps the
%% internal load result onto the stop-metadata schema:
%%
%%   {ok, N}             -> #{result => ok,    keys_loaded => N}
%%   {ok, already}       -> #{result => already, keys_loaded => 0}
%%   {error, Term}       -> #{result => {error, Term}, keys_loaded => 0}
load_stop_metadata({ok, already}) ->
    #{result => already, keys_loaded => 0};
load_stop_metadata({ok, N}) when is_integer(N) ->
    #{result => ok, keys_loaded => N};
load_stop_metadata({error, Reason}) ->
    #{result => {error, Reason}, keys_loaded => 0}.

%% The `po_path` metadata field must be binary (the catalog_load_metadata
%% typespec). `file:filename()` can be either a list or binary depending on
%% the build; we normalize at the telemetry boundary so handlers never have
%% to guard.
to_binary_path(Path) when is_binary(Path) -> Path;
to_binary_path(Path) when is_list(Path) -> unicode:characters_to_binary(Path).

%% =========================
%% Internal: helpers
%% =========================

%% Fallback plural index used when the .po has no Plural-Forms header.
%% Same as the GNU manual's "Translating plural forms" §"Plural forms"
%% default: N == 1 -> singular (0); otherwise plural (1).
fallback_form_index(1) -> 0;
fallback_form_index(_) -> 1.

-spec entry_to_objects(domain(), locale(), catalog_entry()) -> [tuple()].
entry_to_objects(D, L, {singular, Ctx, Msgid, T}) ->
    [{?SINGULAR_KEY(D, L, Ctx, Msgid), T}];
entry_to_objects(D, L, {plural, Ctx, Msgid, _MsgidPlural, Entries}) ->
    %% Finding #14: `_MsgidPlural` is retained on the parsed entry for
    %% faithful `dump/1` round-trips but plays no part in lookup keying,
    %% so it is intentionally dropped during materialization.
    build_plural_objects(D, L, Ctx, Msgid, Entries).

%% =========================
%% Internal: O(1) catalog index (findings #7 & #13)
%% =========================
%%
%% The index holds one row `{{Domain, Locale}, KeySet}' per catalog with
%% >=1 data entry, where `KeySet' is a `sets:set/1' of that catalog's data
%% keys (finding #13). The server is its only writer, mutating it in
%% lock-step with the data table inside the serialized `handle_call'
%% callbacks, so the two never diverge. Registration/lookup are O(1);
%% `num_catalogs' is still `ets:info(_, size)' (finding #7). The KeySet
%% drives O(catalog size) unload (`do_unload_with_count/2').

%% Record the given data keys in the catalog's index set, creating the row
%% on first key. Empty `Keys' is a no-op, so a header-only load (or a
%% degenerate plural that flattens to zero rows) does NOT register a
%% catalog — preserving the finding-#7 membership rule "row present <=> >=1
%% data entry". Idempotent: re-adding an existing key leaves the set
%% unchanged (so re-inserting into a loaded catalog cannot corrupt it).
-spec index_add_keys(domain(), locale(), [data_key()]) -> ok.
index_add_keys(_D, _L, []) ->
    ok;
index_add_keys(D, L, [_ | _] = Keys) ->
    Existing = index_key_set(D, L),
    Merged = lists:foldl(fun sets:add_element/2, Existing, Keys),
    Row = {{D, L}, Merged},
    true = ets:insert(?CATALOG_INDEX_TABLE, Row),
    ok.

%% The catalog's set of data keys, or an empty set when not loaded.
-spec index_key_set(domain(), locale()) -> sets:set(data_key()).
index_key_set(D, L) ->
    case ets:lookup(?CATALOG_INDEX_TABLE, {D, L}) of
        [{{_, _}, KeySet}] -> dynamic_cast_index_keyset(KeySet);
        _ -> sets:new([{version, 2}])
    end.

%% The catalog's data keys as a list (finding #13: the unload work set).
%% Empty when the catalog is not loaded.
-spec index_keys(domain(), locale()) -> [data_key()].
index_keys(D, L) ->
    sets:to_list(index_key_set(D, L)).

%% `ets:lookup/2' is typed `[tuple()]' by eqwalizer — it cannot prove the
%% second element is the `sets:set(data_key())' we (the sole writer) always
%% store. The server is the table's only writer and only ever inserts
%% `index_row/0', so this boundary cast is sound. Narrowed in one place,
%% specced precisely, so the rest of the index code stays statically typed.
-spec dynamic_cast_index_keyset(term()) -> sets:set(data_key()).
dynamic_cast_index_keyset(KeySet) ->
    KeySet.

%% Project the data keys out of built ETS objects (the `{Key, Value}'
%% tuples produced by `build_*_objects/_'). Used by the insert paths to
%% feed `index_add_keys/3'.
-spec object_keys([tuple()]) -> [data_key()].
object_keys([]) ->
    [];
object_keys([{Key, _Value} | Rest]) ->
    [object_key(Key) | object_keys(Rest)].

%% Narrow a stored object's key to the `data_key/0' shape. The build paths
%% only ever emit `?SINGULAR_KEY'/`?PLURAL_KEY' tuples (never a header), so
%% the two clauses are exhaustive; anything else is an invariant break.
-spec object_key(tuple()) -> data_key().
object_key({singular, D, L, Ctx, Msgid}) ->
    ?SINGULAR_KEY(D, L, Ctx, Msgid);
object_key({plural, D, L, Ctx, Msgid, Idx}) ->
    ?PLURAL_KEY(D, L, Ctx, Msgid, Idx);
object_key(Other) ->
    error({unexpected_catalog_key, Other}).

%% Deregister a catalog. Idempotent: deleting an absent key is a no-op.
-spec index_delete(domain(), locale()) -> ok.
index_delete(D, L) ->
    true = ets:delete(?CATALOG_INDEX_TABLE, {D, L}),
    ok.

%% O(1) count of distinct loaded catalogs — the whole point of the index.
%% `ets:info(_, size)' is documented O(1); the table only ever exists
%% after `init/1' creates it, so a real `undefined' here means the server
%% is dead and crashing with a descriptive payload is correct.
-spec index_size() -> non_neg_integer().
index_size() ->
    case ets:info(?CATALOG_INDEX_TABLE, size) of
        N when is_integer(N), N >= 0 ->
            N;
        Other ->
            error(
                {ets_info_invalid, {?CATALOG_INDEX_TABLE, size, Other, expected, non_neg_integer}}
            )
    end.

-spec count_per_catalog(
    tuple(),
    #{{domain(), locale()} => non_neg_integer()}
) -> #{{domain(), locale()} => non_neg_integer()}.
count_per_catalog({{singular, D, L, _, _}, _}, Acc) ->
    maps:update_with({D, L}, fun(N) -> N + 1 end, 1, Acc);
count_per_catalog({{plural, D, L, _, _, _}, _}, Acc) ->
    maps:update_with({D, L}, fun(N) -> N + 1 end, 1, Acc);
count_per_catalog({{header, _, _}, _}, Acc) ->
    Acc;
count_per_catalog(_Other, Acc) ->
    Acc.

%% Used by which_keys/2. Singulars are appended verbatim; plurals are
%% collected into a set keyed on (Context, Msgid) so multi-form plural
%% entries collapse to one user-visible row.
-spec collect_key(domain(), locale(), tuple(), key_acc()) -> key_acc().
collect_key(
    Domain,
    Locale,
    {{singular, Domain, Locale, Ctx, Msgid}, _},
    #{singulars := S} = Acc
) ->
    Acc#{singulars := [{singular, Ctx, Msgid} | S]};
collect_key(
    Domain,
    Locale,
    {{plural, Domain, Locale, Ctx, Msgid, _Idx}, _},
    #{plurals := P} = Acc
) ->
    Acc#{plurals := sets:add_element({Ctx, Msgid}, P)};
collect_key(_Domain, _Locale, _Obj, Acc) ->
    Acc.
