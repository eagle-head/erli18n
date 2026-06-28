# rebar3_erli18n

A [rebar3](https://rebar3.org/) plugin that extracts, merges, checks, and
reports [gettext](https://www.gnu.org/software/gettext/) catalogs for the
[`erli18n`](https://hex.pm/packages/erli18n) runtime library. It is the Erlang
counterpart to `mix gettext.extract` / `mix gettext.merge`.

```
rebar3 erli18n extract   # walk Erlang abstract forms into .pot templates
rebar3 erli18n merge     # msgmerge-style sync of .po catalogs against the .pot
rebar3 erli18n check     # CI gate: fail the build on .pot drift
rebar3 erli18n report    # per-(Domain, Locale) translation completeness
```

## Distribution model — a SEPARATE package from `erli18n`

This plugin is published as its own Hex package, **separate** from the runtime
`erli18n` library, and it depends on that library (`{deps, [{erli18n, "~>
0.6"}]}`, `{applications, [kernel, stdlib, erli18n]}`). The dependency points
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
{deps, [{erli18n, "~> 0.6"}]}.
{plugins, [rebar3_erli18n]}.
```

The plugin registers four providers under the `erli18n` namespace, so the
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
- The plugin's own `{deps, [{erli18n, "~> 0.6"}]}` declaration is what pulls
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
the plugin does **not** vendor a private copy of the escaper/dumper. A vendored
fallback was specified as a contingency *only* for the case where `erli18n_po`
could not be reached cross-package; that case did not occur, so no duplicate
escaper exists to drift out of sync with `erli18n_po:escape_string/1`.

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
  path** — the old workaround; it was version-coupled to the local rebar3 and
  needed a generator escript plus a git-ignored beam directory. Removed in favor
  of the scoped ignore.
- **(c) exclude the whole plugin app from xref** — over-broad; it would silence
  real undefined-call bugs in the plugin's own logic modules.

## License

Apache-2.0. See [LICENSE](LICENSE).
