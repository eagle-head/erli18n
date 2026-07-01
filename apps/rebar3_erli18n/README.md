# rebar3_erli18n

A [rebar3](https://rebar3.org/) plugin that extracts, merges, checks, reports,
and (opt-in) **compiles** [gettext](https://www.gnu.org/software/gettext/)
catalogs for the [`erli18n`](https://hex.pm/packages/erli18n) runtime library.
It is the Erlang counterpart to `mix gettext.extract` / `mix gettext.merge`.

```
rebar3 erli18n extract   # walk Erlang abstract forms into .pot templates
rebar3 erli18n merge     # msgmerge-style sync of .po catalogs against the .pot
rebar3 erli18n check     # CI gate: fail the build on .pot drift
rebar3 erli18n report    # per-(Domain, Locale) translation completeness
rebar3 erli18n compile   # opt-in: bake .po catalogs into BEAM carrier modules
```

## Distribution model — a SEPARATE package from `erli18n`

This plugin is published as its own Hex package, **separate** from the runtime
`erli18n` library, and it depends on that library (`{deps, [{erli18n, "~>
0.7"}]}`, `{applications, [kernel, stdlib, erli18n]}`). The dependency points
**plugin → lib** — the same direction as
[`rebar3_gpb_plugin`](https://github.com/lrascao/rebar3_gpb_plugin) → `gpb`,
`rebar3_proper` → `proper`, and `rebar3_lint` → `elvis_core`.

The split is forced by rebar3's design, not a preference:

- **rebar3 has no auto-discovery.** Mix loads any `Mix.Tasks.*` BEAM shipped by
  any dependency with zero registration, so Gettext can ship its runtime and
  its `mix gettext.*` tasks in one package. rebar3 surfaces a provider only
  when the consumer lists the plugin in `{plugins, ...}` and rebar3 calls its
  `init/1`. A tooling module merely *bundled* into the `erli18n` Hex tarball
  could never be invoked downstream.
- **The runtime library must stay pure.** The providers reuse the published PO
  read/serialize API — `erli18n_po:parse/1`, `erli18n_po:dump/1`, and
  `erli18n_po:escape_string/1` — across the package boundary. Bundling the
  providers into `erli18n` would drag rebar3-host-coupled modules
  (`rebar_state`, `rebar_app_info`, `rebar_api`, the `provider` behavior, all
  of which live inside the rebar3 escript and are **not** a fetchable Hex
  dependency) into a pure runtime library.

The clean reconciliation is a real `{deps, [erli18n]}` boundary in the
**plugin → lib** direction, never lib → plugin.

## Installation

Add the plugin to your project's `rebar.config`. You also need `erli18n`
itself as a normal runtime dependency, since your code calls
`erli18n:gettext/1` and friends:

```erlang
{deps, [{erli18n, "~> 0.7"}]}.
{plugins, [rebar3_erli18n]}.
```

The plugin registers five providers under the `erli18n` namespace, so the
commands are spelled `rebar3 erli18n <provider>`.

## The catalog layout

The plugin uses the standard gettext on-disk layout, rooted at each app's
`priv/gettext`:

```
priv/gettext/<Domain>.pot                              # template (extract output)
priv/gettext/<Locale>/LC_MESSAGES/<Domain>.po          # translated catalog
```

`--pot-dir` overrides the `priv/gettext` root; `--domain`/`-d` restricts to a
single domain; `--locale`/`-l` selects a target locale for `merge`/`report`.

## What gets extracted — the dynamic-msgid caveat

Extraction walks the **abstract forms** of your source (one `epp` pass per
file) and recognizes the full `erli18n` facade family by name **and** arity:
`gettext`/`dgettext`/`dcgettext`, `ngettext`/`dngettext`/`dcngettext`,
`pgettext`/`dpgettext`/`dcpgettext`, `npgettext`/`dnpgettext`/`dcnpgettext`,
plus the `*f` interpolation variants.

Only **compile-time literals** are extracted. A `msgid`, `msgid_plural`, or
`msgctxt` argument is collected only when it is a literal string/charlist (and,
for `Domain`, a literal atom). This matches the Gettext contract exactly:

```erlang
%% Extracted — literal msgid:
erli18n:gettext(<<"Hello">>).
erli18n:ngettext(<<"1 file">>, <<"%{count} files">>, N).
erli18n:pgettext(<<"menu">>, <<"Save">>).

%% NOT extracted — the msgid is a runtime value, not a literal. This still
%% TRANSLATES correctly at runtime; it just cannot be discovered statically,
%% so you must ensure the msgid is present in the catalog by other means.
Key = choose_key(),
erli18n:gettext(Key).
```

A call whose literal slot is not a compile-time literal is **skipped**, never
mis-keyed. This is the same limitation Gettext documents for `*gettext_noop`
and runtime-computed ids.

## The merge contract

`rebar3 erli18n merge` syncs an existing `.po` against the freshly extracted
`.pot`, adopting the GNU `msgmerge` / `mix gettext.merge` semantics:

- **`#:` references and extracted comments are authoritative from the fresh
  `.pot`.** The merge takes the up-to-date source locations from re-extraction.
- **Only `msgstr` (the translation) is preserved from the old `.po`.** For a
  msgid that still exists, its existing translation is carried over.
- **New msgids are fuzzy-matched against removed ones** using Jaro similarity
  (`rebar3_erli18n_jaro`). A renamed string carries its old translation
  forward as a `#, fuzzy` entry with a `#|` previous-msgid hint, so a
  translator only has to confirm it.
- **A removed msgid that is not consumed as a fuzzy source is demoted to a
  `#~` obsolete entry** (its translation bytes preserved) rather than silently
  deleted.

## The `check` gate (CI)

`rebar3 erli18n check` is the `mix gettext --check-up-to-date` experience for
Erlang: it re-extracts in memory and fails the build (non-zero exit) when a
committed `.pot` is out of date. By **default** it detects FULL drift — both
the msgid set **and** the `#:` references change is drift. Pass `--names-only`
for the laxer msgid-set-only comparison (stable against pure line churn) when a
team finds reference drift noisy. A missing `.pot` for a domain that has call
sites is itself drift.

Because only compile-time literals are extracted, a runtime-computed msgid can
never produce a false drift failure in either mode — the dynamic-key
guarantee.

## The `report` completeness view

`rebar3 erli18n report` is a read-only view of per-`(Domain, Locale)`
*translation completeness* — distinct from the `check` gate. `check` answers
"is the committed `.pot` template in sync with the call sites?" and fails the
build on drift; `report` never fails the build. Instead it parses each
`.po` catalog and counts, for every domain and locale, how many entries are
translated versus missing. An entry counts as translated when its `msgstr`
(singular) is non-empty, or — for a plural entry — every plural form is
non-empty. The counts reflect what the **runtime** would actually serve:
`#, fuzzy` entries are dropped on load (per the runtime's parse contract), so
they are not counted as translated.

Run from a project with catalogs under `priv/gettext`:

```console
$ cd examples/erli18n_demo
$ rebar3 erli18n report
erli18n translation report
==========================

domain: accounts
  pt_BR    4/4 translated  (0 missing)

domain: default
  pt_BR    4/4 translated  (0 missing)

domain: errors
  pt_BR    4/4 translated  (0 missing)
```

One block is printed per domain (every `*.pot` under the root, or just the one
named by `--domain`), and one line per locale (every locale directory found, or
just the one named by `--locale`). A locale with no catalog for a domain is
reported as `(no catalog)` rather than omitted.

## Compile-time catalogs (opt-in) — `rebar3 erli18n compile`

By default `erli18n` loads catalogs at runtime from `.po` files with
`erli18n:ensure_loaded/3,4` (read + parse + plural compile at boot). `rebar3
erli18n compile` is an **opt-in** alternative: it bakes each catalog — ALREADY
parsed, with its `Plural-Forms` rule ALREADY compiled — into a generated BEAM
carrier module, so the consumer's boot registers it with **no `.po` parse and no
plural compile**.

For every `(Domain, Locale)` catalog under the root it parses the `.po` and
compiles the plural rule ahead of time, then emits
`erli18n_cc_<Domain>__<Locale>.erl` into the `gen_dir`. The emitter uses only
`erl_parse:abstract/2` + `erl_pp` from stdlib (no `merl`, no `erl_syntax`, no
parse transform), and the normal app-compile step turns those carriers into
BEAM. Orphaned carriers (from a deleted `.po`) are pruned, and a `.gitignore`
marks the `gen_dir` as a build artifact.

The whole surface is off until you opt in. With no `{compiled_catalogs, true}`
in `rebar.config`, the provider is a loud-logged no-op that writes nothing.

### Wiring it up

```erlang
%% rebar.config
{plugins, [rebar3_erli18n]}.

{erli18n, [
    {compiled_catalogs, true},            % master gate (default: false)
    {key_check, warn},                    % off | warn | strict (default: warn)
    {compiled_domains, [default, errors]},% all (default) or an explicit list
    {gen_dir, "src/erli18n_gen"},         % carrier output dir (default shown)
    {include_fuzzy, false},               % bake #, fuzzy entries (default: false)
    {gen_eqwalizer_nowarn, true},         % nowarn on generated catalog/0 (default: true)
    {max_po_bytes, 16777216},             % reject a .po larger than this before reading (infinity disables; default 16 MiB)
    {max_entries, 500000}                 % reject a parsed catalog with more entries (infinity disables; default)
]}.

%% Regenerate the carriers on every build, before the app compile:
{provider_hooks, [{pre, [{compile, {erli18n, compile}}]}]}.
```

Then register the baked catalogs once, in the consuming app's `start/2`,
**before** the supervision tree starts, so every catalog is live before any
worker can look one up:

```erlang
%% my_app_app.erl
start(_Type, _Args) ->
    _ = erli18n:register_compiled_catalogs(my_app),
    my_app_sup:start_link().
```

`register_compiled_catalogs/1` is additive and idempotent: it composes with
runtime `ensure_loaded/3` and reports `{ok, already}` for a catalog already
present. The honest framing is **no parse / no compile at startup — NOT
zero-load**: registration still installs each catalog through the runtime's
single serialized writer; the cost is the install, not the parsing.

### The compile-time key check

After codegen the provider compares every compile-time-literal facade call site
(the same `extract` walk) against the per-`(Domain)` key universe of the
*compiled* catalogs and reports each call site whose `{Context, Msgid}` has no
matching compiled key. It is scoped to the domains actually being compiled, so
it never flags a domain you did not opt into. The `{key_check, ...}` policy is
`off | warn | strict` (default `warn` — log and continue; `strict` fails the
build). CLI overrides take precedence over the config, in this order:
`--no-key-check` > `--strict` / `--check` > the `{key_check}` config.

### CI one-liner

```console
$ rebar3 erli18n compile --check
```

`--check` is a dry run: it parses every catalog, compiles every plural rule, and
runs the key check **in strict mode** while writing **no** carriers — so CI fails
fast on a broken `Plural-Forms` rule or a call site missing from the compiled
catalogs, without mutating the tree.

### Runtime vs compiled — which to use

Compiled catalogs are an optimization for a specific shape of project; the
runtime loader stays the default and the right choice for most.

- **Runtime `ensure_loaded/3,4`** (the default): catalogs are plain `.po` files
  shipped in `priv/`, editable and reloadable without a recompile
  (`erli18n:reload/3`). Best when translations change independently of code, are
  supplied per tenant, or are edited by translators against a running release.
- **Compiled `register_compiled_catalogs/1`**: catalogs are frozen into the
  release at build time. Best when translations ship **with** the code and you
  want boot to skip the `.po` read/parse/compile entirely. The trade-off is that
  a translation change now requires a recompile, and the carriers are a generated
  build artifact.

### eqWAlizer note (generated carriers)

Each generated `catalog/0` always carries the precise
`-spec catalog() -> erli18n_server:compiled_spec().`. By default
(`{gen_eqwalizer_nowarn, true}`) it **also** carries a function-scoped
`-eqwalizer({nowarn_function, catalog/0}).`, because a generated catalog can
embed a deeply nested plural-rule literal that eqWAlizer cannot always narrow to
the spec. The nowarn keeps a generated module type-clean without weakening the
precise spec. Set `{gen_eqwalizer_nowarn, false}` to omit the nowarn (for a
catalog simple enough to type-check against the spec without the escape hatch).

### `include_fuzzy` parity caveat

`{include_fuzzy, false}` (the default) matches the runtime parser: `#, fuzzy`
entries are dropped, so a compiled catalog serves exactly what
`erli18n:ensure_loaded/3` would. Setting `{include_fuzzy, true}` bakes fuzzy
entries **in**, which makes the compiled catalog serve translations the runtime
loader would skip — keep it `false` unless you deliberately want fuzzy entries
live, and keep it consistent with how the same catalogs are loaded at runtime so
the two paths stay at parity.

## Local development — the two-checkouts requirement

Until both packages are published, a consumer that wants to drive this plugin
against an in-repo `erli18n` must surface **both** apps through rebar3's native
`_checkouts/` mechanism:

```
<consumer>/_checkouts/erli18n          -> the runtime library app
<consumer>/_checkouts/rebar3_erli18n   -> this plugin app
```

Both are load-bearing (empirically verified against rebar3 3.24 / OTP 28):

- The consumer's `{plugins, [rebar3_erli18n]}` entry by name must still be
  present; `_checkouts/rebar3_erli18n` only takes precedence over a Hex fetch
  for that name.
- The plugin's own `{deps, [{erli18n, "~> 0.7"}]}` declaration is what pulls
  the consumer's `_checkouts/erli18n` onto the plugin's runtime code path at
  provider-run time. **Without** the plugin declaring the `erli18n` dep, the
  consumer's `erli18n` checkout does not land on the plugin path and
  `erli18n_po` is `non_existing` (undef) when a provider runs.
- Removing `_checkouts/erli18n` makes rebar3 resolve `erli18n` from Hex
  instead — so the checkout (not Hex) is what binds the unpublished lib in
  local dev.

rebar3 has **no** native `{path, ...}` dependency resource (that requires the
third-party `rebar3_path_deps` plugin), so `_checkouts` is the idiomatic way to
consume an unpublished in-repo plugin, per
[rebar3.org/docs/configuration/dependencies](https://rebar3.org/docs/configuration/dependencies/).
After publish, the consumer drops the checkouts and resolves both packages from
Hex normally.

## Proven cross-package load path

The plugin -> lib boundary is not asserted, it is **executed and captured** on
the real packages. The in-repo consumer `examples/erli18n_demo/` surfaces both
apps through the two `_checkouts` above and drives the full pipeline. Each
provider reaches the runtime library through `rebar3_erli18n_common`, which
logs the *loaded* location of `erli18n_po` when the `ERLI18N_DIAG_LOADPATH`
environment variable is set:

```console
$ cd examples/erli18n_demo
$ ERLI18N_DIAG_LOADPATH=1 rebar3 erli18n extract
===> erli18n: runtime lib erli18n_po loaded from \
       .../examples/erli18n_demo/_build/default/checkouts/erli18n/ebin/erli18n_po.beam
===> erli18n: wrote .../priv/gettext/default.pot (4 entries)
...
$ ERLI18N_DIAG_LOADPATH=1 rebar3 erli18n merge --locale pt_BR   # merges 3 catalogs
$ ERLI18N_DIAG_LOADPATH=1 rebar3 erli18n check                  # exit 0, catalogs up to date
```

At provider-run time `code:which(erli18n_po)` resolves under the consumer's
`_build/<profile>/checkouts/erli18n/ebin/erli18n_po.beam` — so the **checkout**,
not a Hex fetch, backs the `erli18n_po:parse/1`, `erli18n_po:dump/1`, and
`erli18n_po:escape_string/1` calls that `extract`/`merge`/`check`/`report`
make across the published `{deps, [erli18n]}` boundary. rebar3 itself confirms
the resolution (`App erli18n is a checkout dependency and cannot be locked`),
there is no `Fetching erli18n` line, and no `undef erli18n_po:dump/1`. The
`providers_SUITE` `runtime_lib_reachable_at_provider_run` case and the
`common_SUITE` `runtime_lib_path_resolves` case assert the same edge in-node
(the lib is never `non_existing` and its API is callable).

Because that load path is proven, the providers reuse `erli18n_po` directly:
the plugin does **not** vendor a private copy of the escaper/dumper, so no
duplicate escaper exists to drift out of sync with
`erli18n_po:escape_string/1`.

## Xref and the rebar3 host API

Every call into rebar3's own modules (`providers`, `rebar_state`, `rebar_api`,
`rebar_app_info`) is funneled through a single seam,
`rebar3_erli18n_host.erl`. Those modules are supplied by the rebar3 escript at
plugin-load time and are **not** a fetchable Hex dependency, so `rebar3 xref`
(which scans this app because `apps/*` is the umbrella's discovery root) reports
each of the eight host calls as an undefined function. The seam carries a
scoped `-ignore_xref([...])` listing exactly those eight `{M, F, A}` edges (and
the seam's own wrappers), mirrored by an `{xref_ignores, [...]}` block in
`rebar.config`. Every other module stays under active
`undefined_function_calls`/`undefined_functions` checking, so the ignore is
load-bearing, not a blanket suppression.

Rejected alternatives:

- **(a) declare `rebar3` as a build dependency** — impossible: there is no
  `rebar`/`rebar3` Hex package carrying those host modules.
- **(b) extract the host beams out of the running escript onto an extra xref
  path** — version-coupled to the local rebar3, and needs a generator escript
  plus a git-ignored beam directory; the scoped ignore avoids all of that.
- **(c) exclude the whole plugin app from xref** — over-broad; it would silence
  real undefined-call bugs in the plugin's own logic modules.

## License

Apache-2.0. See [LICENSE](LICENSE).
