# Changelog

All notable changes to `erli18n` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## Versioning policy

Per [SemVer 2.0.0 §4](https://semver.org/#spec-item-4), this project is in the `0.x.y` initial-development phase:

- **`0.x.y` → `0.x.y+1`** (patch): backward-compatible bug fixes only.
- **`0.x.y` → `0.x+1.0`** (minor): may introduce backward-incompatible changes, announced in advance via CHANGELOG. Additive changes (new functions, new arities, new opt-in flags, new telemetry events) are the norm.
- **Telemetry events** are versioned per the schema policy documented in the `erli18n_telemetry` module `-moduledoc`; events marked `@stable` cannot change schema within `0.x` series, events marked `@unstable` may.

## Criteria for `1.0.0`

The `1.0.0` release commits to API stability. Tag bumps to `1.0.0` only when **all** of the following hold:

1. At least one external project uses `erli18n` in production for ≥ 6 months without reporting breaking issues.
2. The Post-0.1.0 Roadmap items that affect public API surface (charset support, hot upgrade behavior, async load) are either implemented or formally rejected with rationale.
3. Parity SUITE (`erli18n_parity_SUITE`) passes end-to-end against the real GNU `gettext` / `ngettext` CLI (`gettext-tools` ≥ 0.21) as oracle (currently 6 scenarios; target ≥ 20 covering the full PSD-001…009 semantics matrix).
4. No unfixed `@unstable` telemetry events remain — all events either promoted to `@stable` or removed.
5. CHANGELOG documents zero behavioral changes for at least 2 consecutive minor releases.

## [Unreleased]

## [0.6.0] — 2026-06-25

Phase 5: **per-request localization middleware for Cowboy and Elli**, plus the
pure negotiation core, structural performance/correctness fixes on the new
per-request path, and two general latent-bug fixes surfaced by a test-adequacy
audit (UTF-8 truncation in the interpolator, non-UTF-8 byte escaping in the PO
serializer). Additive under the `0.x` SemVer policy — new optional adapter
modules, a new public core module, and one new facade function; the default
`kernel` + `stdlib` build is unchanged.

### Added

- **Per-request localization middleware for Cowboy and Elli** (roadmap Phase 5).
  Two new **optional** adapter modules make per-request locale negotiation
  turnkey:
  - `erli18n_cowboy` — a `cowboy_middleware` that negotiates the request locale
    and calls `erli18n:setlocale/1` before the handler runs.
  - `erli18n_elli` — the Elli `elli_middleware` counterpart (`preprocess/2`).

  Both delegate to the existing `erli18n_negotiate` engine via a new pure,
  framework-agnostic core, `erli18n_http`, which resolves the locale from an
  ordered set of sources — default precedence **query > cookie > `Accept-Language`
  header > default** (configurable), with cookie/query overrides canonicalized
  and the header parsed by the fail-soft RFC 9110 parser. The chosen locale is
  also placed in the Cowboy `Env` (`erli18n_locale`) and, by default, in `logger`
  process metadata.

  Per-request resolution is **lazy and short-circuiting**: each source is
  extracted only when it is reached, and negotiation stops at the first source
  that yields a supported locale — so a request answered by an earlier-precedence
  source never pays for the cookie split or header parse of the later ones. The
  adapters resolve `available` / `default` lazily too: `erli18n:loaded_locales/0`
  is forced only once a source actually yields a value, `erli18n:default_locale/0`
  only on a total miss, and an explicitly-supplied `available` / `default` is
  zero-cost. Both the Cowboy and Elli query seams are **total and fail-soft**:
  each adapter feeds the **raw** query binary (from the framework's own total
  accessor — `cowboy_req:qs/1`, `elli_request:query_str/1`) to a single pure-core
  parser, `erli18n_http:query_value/2`, instead of the framework's raising query
  decoder. A value-less `?locale` and a malformed percent-escape (`?locale=%ZZ`,
  a bare `?%`, a truncated `?locale=%E0%`) are skipped rather than crashing the
  request. Per-request option **values** are validated at the `run/2` boundary:
  a malformed `default` (non-binary) or `available` (not a list, or a list with
  bad elements) is dropped so the documented default applies
  (`erli18n:default_locale/0` / `erli18n:loaded_locales/0`), emitting a one-time
  `logger:warning` — operator misconfiguration is **fail-soft-and-observable**,
  never request-fatal.

  `cowboy` and `elli` are optional in the same way as `telemetry`: they are
  declared in `optional_applications` and are **not** runtime dependencies of the
  published package, which still builds and runs on `kernel` + `stdlib` alone.
  The module docs document the per-process / not-inherited-across-spawn locale
  model and the broader cross-process handoff hazard (pooled workers, shared
  `gen_server`s, `Task`-style spawns, Cowboy stream handlers that offload), the
  mitigations, and a Phoenix interop note (no Elixir dependency).
- **`erli18n:loaded_locales/0`** — returns the distinct, sorted locales that have
  at least one catalog loaded: the authoritative *available* set for negotiation
  (the default `available` set the new adapters use). It is backed by a dedicated
  loaded-locale index kept as its own keyed `persistent_term` and maintained on
  every catalog add/remove path (load/reload/put/merge-that-creates/unload/
  erase_all), so the read is a single copy-free keyed lookup plus a `usort` rather
  than a scan of every term on the node. Index writes are **compare-before-put**:
  reloading an already-indexed catalog (or unloading an absent pair) leaves the
  index term untouched and skips the node-wide literal-area GC that a
  `persistent_term:put` would otherwise trigger.
- **`erli18n_http` — public framework-agnostic negotiation core.** Exposes
  `negotiate_locale/3` (resolve the request locale from an ordered candidate
  list against an available set, with a `default` fall-through),
  `negotiate_locale_lazy/4` (the lazy, short-circuiting engine the adapters drive,
  taking an on-demand extraction callback and `available` / `default` thunks),
  `cookie_value/2` (total, fail-soft single-cookie extraction from a raw
  `Cookie` header, bounded against abuse), and `query_value/2` (total, fail-soft
  single-parameter extraction from a raw query binary, percent-decoding the
  matched value fail-soft and bounded against abuse). It is pure (no `setlocale`,
  no logger, no I/O) and is the supported entry point for wiring frameworks the
  bundled adapters do not cover. The canonical available-locale index is built
  **once per negotiation call** and reused across every candidate; the cookie
  parser bounds the split **itself** (peeling at most `MAX_COOKIE_PAIRS`
  `;`-segments and dropping the tail unscanned, O(cap) rather than O(header
  length)); and a `locale="pt_BR"` cookie in RFC 6265 quoted-string form is
  unquoted byte-level and total.

### Added (negotiation core)

- **`erli18n_negotiate:available_index/1` + `negotiate_with_index/2`** — the
  canonical available-locale index (`#{canonicalize(Original) => Original}`) is
  now a public, reusable value: build it once with `available_index/1` and
  negotiate many preference lists against it with `negotiate_with_index/2`,
  instead of rebuilding the index per call. `negotiate/2` is exactly
  `negotiate_with_index(Preferred, available_index(Available))`; its semantics are
  unchanged.
- **The `?MAX_RANGES` anti-DoS cap on `to_locale_list/2` is now honest on every
  consumed cell.** The budget is a **per-consumed-cell** cap (at most 32 input
  cells inspected) rather than a per-accepted-entry one: the wildcard-skip and
  oversized-tag-skip branches now also decrement the budget, so a skip-heavy
  adversarial preference list stops at 32 cells instead of walking the whole list.
  Now reachable through the newly-public `negotiate/2` / `negotiate_with_index/2`.
  Output is byte-identical for any input whose first 32 consumed cells are all
  acceptable; it differs only when acceptable entries appear *after* 32 consumed
  (including skipped) cells — which is exactly the documented anti-DoS contract.

### Fixed

- **`erli18n_interp` truncation now cuts on a UTF-8 codepoint boundary.** Both the
  per-value clamp (`clamp_value/1`, at `?MAX_VALUE_BYTES`) and the output cap
  (`append_and_check/2`, at `?MAX_OUTPUT_BYTES`) previously truncated with a
  fixed-offset `binary:part/3`; because neither cap is codepoint-aligned, a cut
  could split a multi-byte codepoint and leave a dangling partial sequence —
  invalid UTF-8. A new total `truncate_utf8/2` (with `codepoint_start/2` /
  `is_utf8_continuation/1`) backs off to the codepoint's lead byte when the cut
  lands inside a multi-byte sequence, so a value that was valid UTF-8 stays valid
  after clamping or truncation. Output for any value within the cap is unchanged.
- **`erli18n_po:escape_string/1` is now total over any `binary()`.** A byte that is
  not part of a valid UTF-8 sequence (e.g. a lone `0xFF`) matched no clause and
  raised `function_clause`, crashing `dump/1` on a catalog value carrying arbitrary
  bytes. A final byte-wise clause now passes such a byte through verbatim — the same
  way the PO reader tolerates raw bytes on parse — honoring the
  `-spec binary() -> binary()` totality contract. The five GNU gettext escapes and
  all valid-UTF-8 output are byte-for-byte unchanged.

## [0.5.0] — 2026-06-22

Packaging and public-API minor. Two coupled changes drive the minor bump under
the `0.x` SemVer policy above: a new public export (`erli18n_po:escape_string/1`,
detailed under **Added**) and the repository's move to a rebar3 umbrella in which
`erli18n` is now a fully self-contained Hex package (detailed under
**Packaging**).

### Added

- **`erli18n_po:escape_string/1` is now exported as public API** — a
  **runtime/published-module change** to `erli18n_po` (not a layout-only one).
  It applies the five GNU gettext PO escapes (backslash, double-quote,
  newline, tab, carriage return) and is the exact escaping `dump/1` already
  used internally. It is promoted to public API so the separate
  `rebar3_erli18n` plugin can serialize the PO metadata it owns (the `#|`
  previous-msgid lines) byte-identically to `dump/1` across the published
  `{deps, [erli18n]}` boundary, instead of vendoring a duplicate escaper that
  would have to stay in lock-step forever. Additive only; no existing behavior
  changes.

### Security

- **`erli18n_po:parse/1,2` plural-index validation no longer allocates a list
  sized by the untrusted `nplurals=` header (anti-DoS).** The PSD-009 cross-check
  in `validate_plural_indices/3` previously built `lists:seq(0, Nplurals - 1)`,
  where `Nplurals` comes straight from the `.po` `Plural-Forms` header. The
  loader only caps that value's DIGIT COUNT (7 digits, up to 9,999,999), so a
  ~158-byte adversarial `.po` declaring `nplurals=9999999` plus a single
  `msgstr[0]` line forced a ~10-million-element list (~80 MB, reproduced at
  ~340 ms versus ~0.1 ms for a real catalog) before reporting the mismatch. The
  validation now checks the index set without ever materializing the
  header-sized sequence — it requires the present indices to be a dense 0-based
  prefix (sized by the bytes actually in the file) whose length equals
  `Nplurals` — so the same malicious input is rejected in bounded time. The
  structured `{plural_count_mismatch, Msgid, Nplurals, Indices}` error a genuine
  count mismatch returns is byte-for-byte unchanged; only the resource bound is
  fixed.

### Fixed

- **`erli18n_po:parse/1,2` continuation-line accumulation is now genuinely
  O(total).** A `msgid`/`msgstr`/`msgctxt`/`msgid_plural`/`msgstr[N]` field
  spread across many continuation lines was accumulated by appending a growing
  binary held inside the parser's per-entry record
  (`<<Prev/binary, Bin/binary>>`); because that accumulator had more than one
  reference, the runtime's in-place binary-append optimization did not apply and
  the build degraded to super-linear on a many-continuation field. Each
  continuation segment is now prepended onto a reversed list in O(1) and the
  whole field is joined exactly once at finalization (`iolist_to_binary/1`), so
  the per-field build is linear in the total byte count by construction rather
  than depending on a runtime heuristic. The parsed bytes are unchanged.

### Packaging

- **`erli18n` is now a self-contained Hex package inside the umbrella.** Its
  `README.md`, `CHANGELOG.md`, and `LICENSE` were relocated from the repo root
  into `apps/erli18n/` so the published tarball ships them, and the package's
  `ex_doc` / `{hex, [{doc, #{provider => ex_doc}}]}` configuration moved from
  the root `rebar.config` into `apps/erli18n/rebar.config`. The root keeps only
  umbrella-wide and shared-community files. Required because `rebar3_hex`
  computes the package file set strictly inside the app directory: with the
  package files at the repo root, the `0.4.0` tarball shipped only
  `include/erli18n.hrl`, `rebar.config`, and `src/*.erl` — no
  `README`/`CHANGELOG`/`LICENSE`. No runtime module behavior changed.

### Changed

- **The test suite no longer makes a runtime `eqwalizer:dynamic_cast/1`
  call.** The nine property/fuzz/CT modules that bridged PropEr's
  statically-`term()` generator boundaries
  (`erli18n_po_props`, `erli18n_negotiate_props`, `erli18n_lookup_props`,
  `erli18n_plural_props`, `erli18n_interp_props`, `erli18n_po_fuzz`,
  `erli18n_server_SUITE`, `erli18n_pt_store_SUITE`, `erli18n_loader_SUITE`)
  now reconcile those boundaries with a static
  `-eqwalizer({nowarn_function, F/A}).` annotation on each affected function —
  the same zero-runtime-dep pattern already used in the runtime modules
  `erli18n_server` and `erli18n_pt_store` — instead of calling the
  `eqwalizer:dynamic_cast/1` helper at run time. The previous runtime call
  `undef`-crashed under Common Test because the `eqwalizer_support`
  `git_subdir` checkout lands the helper's beam at a double-nested path that
  rebar3's ct provider never adds to the code path. The suites are green again
  with no skips, coverage stays at 100% on every touched module, and no
  runtime/published module was edited for this change.
- **`eqwalizer_support` is RETAINED as the eqwalizer toolchain dependency
  (not dropped).** It is the required `git_subdir` dep every eqwalizer project
  declares per the official getting-started instructions; it anchors the
  OTP/stdlib type overlays `elp eqwalize-all` needs. Removing it was tried and
  rejected: without it, `elp eqwalize-all` cannot narrow stdlib results and
  reports `incompatible_types` against `term()` across every `src` module
  (a locally-reproduced 174-error degrade of an otherwise-green type gate). It
  is now justified solely as the build-time type-checker anchor — it is no
  longer on the test suites' runtime code path (see the previous entry), so its
  `git_subdir` double-nesting no longer causes `{undef, dynamic_cast}`.
- **`bin/quality-gate.sh --full` now hard-requires `elp`.** A new
  `require_elp` step records a real FAIL (counted in the gate total, forcing a
  non-zero exit) when `elp` is not found, instead of letting the eqwalizer and
  `elp lint` steps silently SKIP-to-green. In `--full` those two steps now run
  strictly (a missing `elp` is a FAIL, not a SKIP); only the cheap `--fast`
  lane keeps the soft-skip with an install hint. This closes the SKIP-passes
  hole so a machine without `elp` can no longer pass the strict gate.
- **Repository converted to a rebar3 umbrella.** The runtime library now
  lives in `apps/erli18n/` (its `src/`, `test/`, and `erli18n.app.src` moved
  verbatim) instead of the repo root. This is a layout-only change with **no
  runtime module edits**: the published `erli18n` package's modules and public
  API are byte-for-byte unchanged. The Hex publish path is
  `cd apps/erli18n && rebar3 hex publish package` (each package is published
  from its own self-contained app directory, not via `--app` from the umbrella
  root). Contributors should note that the lib's runtime dependency
  (`telemetry ~> 1.3`), compile options, doc config, and its own
  `{project_plugins, [rebar3_hex, rebar3_ex_doc]}` now live in
  `apps/erli18n/rebar.config`; the root `rebar.config` carries only
  umbrella-wide tooling (dev/test plugins, the `test` profile, and the
  dialyzer/xref/hank/erlfmt policy).
- **Documentation swept to the two-package umbrella reality.** `README.md`,
  `CONTRIBUTING.md`, the plugin's `apps/rebar3_erli18n/README.md`, and
  `.github/workflows/release.yml` now describe the shipped layout consistently:
  the umbrella project tree (`apps/erli18n/`, `apps/rebar3_erli18n/`,
  `examples/erli18n_demo/`); the Erlang-native `rebar3 erli18n` extractor as a
  separate, opt-in `{plugins, [rebar3_erli18n]}` package depending on the
  library in the **plugin → lib** direction; the proven cross-package
  `_checkouts/{erli18n, rebar3_erli18n}` load-path requirement; the scoped xref
  host-seam ignore and why (the rebar3 host modules are escript-internal, not a
  fetchable Hex dep); and the `--full` gate's hard `elp` requirement (soft-skip
  only in `--fast`). The release workflow publishes both packages from
  per-package prefixed tags (`erli18n-vX.Y.Z`, `rebar3_erli18n-vX.Y.Z`),
  `erli18n` first. Prose is en-US throughout. Documentation only; no runtime or
  published-module edits.

### Added

- **Catalog tooling promoted to a separate publish-ready plugin package,
  `rebar3_erli18n`** (`apps/rebar3_erli18n/`). The four catalog providers
  (`rebar3 erli18n extract|merge|check|report`) now ship as their own rebar3
  plugin Hex package rather than being bundled into the runtime library — the
  dominant rebar3 idiom for a tool with a real runtime consumer (the
  gpb/`rebar3_gpb_plugin` pattern). The plugin declares a real dependency on
  this library (`{deps, [{erli18n, "~> 0.5"}]}`) and reuses the published PO
  API across that boundary. Consumers opt in with
  `{plugins, [rebar3_erli18n]}`. The plugin carries its own
  `README`/`CHANGELOG`/`LICENSE` (Apache-2.0) and is published as a separate
  Hex package, after this library, against `{erli18n, "~> 0.5"}`. See
  `apps/rebar3_erli18n/CHANGELOG.md`.
- **Real downstream-consumer example, `examples/erli18n_demo/`.** A separate
  rebar3 project (deliberately under `examples/`, NOT `apps/`, so the umbrella
  does not auto-discover it) that consumes BOTH umbrella packages exactly as a
  real downstream app would: its `rebar.config` declares
  `{deps, [{erli18n, "~> 0.5"}]}` and `{plugins, [rebar3_erli18n]}`, and its
  production modules (`erli18n_demo_greeting`, `erli18n_demo_errors`,
  `erli18n_demo_accounts`) contain genuine compile-time-literal
  `erli18n:gettext`/`ngettext`/`pgettextf`/`npgettext`/`dgettext`/`gettextf`
  call sites
  across the `default`, `errors`, and `accounts` domains. Running
  `rebar3 erli18n extract → merge --locale pt_BR → check` against it produces
  the committed baseline `.pot` templates and the translated `pt_BR` `.po`
  catalogs under `examples/erli18n_demo/priv/gettext/`, which the
  `rebar3 erli18n check` gate compares against (it FAILS on drift, PASSES in
  sync — the non-vacuous CI gate the library repo itself cannot host, because
  the facade never calls itself and extraction there yields zero `.pot`). The
  example also documents the **dynamic-msgid caveat**: `dynamic_label/1` calls
  `erli18n:gettext/1` with a runtime (non-literal) key, so it is NOT extracted
  and never causes a false drift failure, while still translating at runtime.
  Because the example is developed in-tree (against the umbrella sources, not a
  Hex fetch) and rebar3 has no native `{path, ...}` resource, it surfaces both
  in-repo apps through rebar3's documented `_checkouts/` override
  (`_checkouts/erli18n`, `_checkouts/rebar3_erli18n`); those links and the
  example's `_build/` are git-ignored recreatable artifacts, while the baseline
  catalogs are tracked.
- **Executed proof of the cross-package plugin → lib load path.** An
  `ERLI18N_DIAG_LOADPATH`-gated diagnostic in `rebar3_erli18n_common` logs the
  loaded location of `erli18n_po` at provider-run time. Driven from
  `examples/erli18n_demo/`, the `extract → merge → check` run confirms
  `code:which(erli18n_po)` resolves under the consumer's
  `_build/default/checkouts/erli18n/ebin/erli18n_po.beam` — the unpublished
  runtime library is reached through the consumer's checkout (not a Hex fetch)
  across the `{deps, [erli18n]}` boundary, with no `undef erli18n_po:dump/1`.
  So the runtime `erli18n_po:escape_string/1` reuse is reachable cross-package,
  and the relocated `rebar3 erli18n check` gate can meaningfully pass/fail
  rather than undef-crash. The contingency private escaper/dumper was **not**
  vendored. No runtime/published module behavior changed in this step.
- **The translation-freshness gate now runs inside the consumer example.**
  `bin/quality-gate.sh` runs `rebar3 erli18n check` from inside
  `examples/erli18n_demo/` (via a new `run_step_in <dir> <name> -- <cmd...>`
  helper that executes in a `( cd <dir> && … )` subshell, so the gate's own
  working directory is never mutated and a failure is accounted exactly like
  any other step). The check re-extracts the demo's real `erli18n:gettext`
  call sites and FAILS the build on drift against the committed catalogs, in
  the same load context where `erli18n_po` is on the plugin path through the
  demo's `_checkouts/erli18n`. Before the step, `ensure_demo_checkouts`
  idempotently (re)creates both `examples/erli18n_demo/_checkouts/erli18n` and
  `…/_checkouts/rebar3_erli18n` so the git-ignored links are always present.
  This replaces the previous in-library invocation, which was vacuous (the
  facade never calls itself, so extraction in the library repo yields zero
  `.pot` and the check protected nothing). A deliberate negative-drift
  integration test (`providers_SUITE:check_drift_cycle_in_load_context`)
  encodes the FAIL-on-drift → PASS-when-fresh cycle through the real provider
  entry points and asserts up front that `code:which(erli18n_po)` is reachable,
  so a cross-package load-path regression fails the test explicitly instead of
  masquerading as drift. No runtime/published module behavior changed in this
  step.
- **PO-metadata edge-case assertions in `po_meta_SUITE`** (the plugin's
  metadata serializer suite). Four serialize-side cases were added to pin
  contracts the existing golden tests did not assert: an explicit empty-binary
  context emits `msgctxt ""` while the absent-context `undefined` omits the
  line (the no-context invariant, on the write side); an obsolete PLURAL entry
  `#~ `-prefixes every line of its multi-line block (`msgid`, `msgid_plural`,
  each `msgstr[N]`); an obsolete entry with a translator comment keeps the
  `# ` comment un-prefixed while `#~ `-prefixing the body (including
  `#~ msgctxt`); and a plural entry carrying both an `#.` extracted comment and
  `#:` references emits them in canonical GNU order before the plural block.
  Coverage of `rebar3_erli18n_po_meta` stays at 100%. These edge cases were
  mined from the discarded runtime preserve-mode CT work (see the design note
  below); no runtime/published module was edited.

### Decided (design)

- **The runtime `erli18n_po:parse/1` preserve-mode WIP is abandoned.** An
  earlier in-progress design added an opt-in `erli18n_po:parse(Po, #{preserve
  => true})` mode that retained the full GNU metadata channel (translator and
  extracted comments, `#:` references, `#,` flags incl. `fuzzy`, `#|`
  previous-msgid, and `#~` obsolete entries) on the runtime READ/parse side.
  That mode is deliberately NOT shipped: `erli18n_po:parse/1` stays lossy by
  design, collapsing all metadata and dropping fuzzy (PSD-001) and obsolete
  (PSD-007) entries, so the runtime API surface stays minimal. PO metadata is
  structurally owned by the plugin's WRITE/serialize side
  (`rebar3_erli18n_po_meta`), not the runtime parser. This matches the Gettext
  merge contract the plugin implements: `#:` references and comments are
  authoritative from the freshly extracted POT, and only `msgstr` is preserved
  from the old PO, so the runtime read side has no need to round-trip the
  metadata channel. The discarded suite's edge-case assertions worth keeping
  (the PSD-001/PSD-007 fuzzy/obsolete and no-context cases) were ported to the
  plugin-side `po_meta_SUITE` instead (see above). No runtime/published module
  was edited for this decision.

### Removed

- **The host-beam extraction workaround** that previously let the in-repo
  plugin satisfy the root project's xref as a project app (a vendored escript
  that extracted the rebar3 host modules into a generated beam directory, plus
  the matching root `rebar.config` project-app-dirs / extra-paths wiring). As a
  normal rebar3 plugin, `rebar3_erli18n` receives the rebar3 host modules at
  plugin-load time; xref resolution for the host seam is now a scoped
  `-ignore_xref`/`{xref_ignores}` confined to the eight host `{M, F, A}` edges.
  No runtime module edits.

## [0.4.0] — 2026-06-21

Storage migration: the translation-catalog substrate moves from ETS to
`persistent_term`. The benchmark proved `persistent_term` reads roughly 55%
faster for this read-hot / load-once library because `persistent_term:get/2`
returns the term without copying it onto the caller's heap. The public API and
all lookup/fallback/idempotency semantics are unchanged; the only observable
differences are documented below. The minor bump follows the `0.x` SemVer
policy above.

### Changed

- **Catalog storage migrated from ETS to `persistent_term`** (new module
  `erli18n_pt_store`). Each `{Domain, Locale}` catalog is one persistent term
  (key `{erli18n_catalog, Domain, Locale}`) holding a single map of its entries
  plus the header. Reads are copy-free and lock-free from the calling process.
  There is **no lookup behavior change**: `lookup_singular/4`,
  `lookup_plural_form/5` and `lookup_header/2` keep their exact specs, guards,
  miss semantics (`undefined`) and return shapes.
- **`reload/3,4` and `unload/2` now trigger a node-wide `persistent_term`
  literal-area garbage collection.** Replacing or erasing the catalog map
  defers a cleanup in which every process still referencing the old map runs a
  major (fullsweep) GC and all processes are made runnable to scan their heaps.
  This cost is paid once per (re)load or unload and is negligible for erli18n's
  load-once-at-boot workload, but it is a real cost the previous ETS storage did
  not have. It is documented here and in the `erli18n_server` /
  `erli18n_pt_store` module docs, never hidden.
- **`memory_info/0`** — the `ets_bytes` field now reports the approximate
  `persistent_term` storage size in bytes. The field name is kept for backwards
  compatibility with the 0.3.0 return shape (the storage is no longer ETS).
- **A lookup against a stopped catalog now returns `undefined` instead of
  crashing.** Because the catalogs live in runtime-owned `persistent_term`
  rather than in a process-owned ETS table, a missing or unloaded catalog is a
  clean miss on the read path, not an access to a dead table.

### Removed

- **`erli18n_table_owner`** and the entire ETS heir / `'ETS-TRANSFER'` /
  `give_away/3` handoff subsystem. That machinery existed only so ETS catalogs
  survived a worker crash (Finding #10). `persistent_term` is node-global and
  runtime-owned, so a worker crash destroys nothing: the supervisor collapses to
  a single `erli18n_server` child under `one_for_one` (was `rest_for_one` with
  an owner-first ordering), and the secondary ETS catalog index and the
  associated `erli18n.hrl` macros are gone with it.

## [0.3.0] — 2026-06-19

Phase 2: **canonicalization-aware BCP-47 fallback chain + `Accept-Language`
negotiation (opt-in)**. This release is additive — a new module, four new
facade functions, one new application-env key defaulting to `off`, and one new
telemetry event under the existing opt-in flag. With the default configuration
every public function behaves exactly as in 0.2.0; the exact-match lookup hot
path is byte-for-byte unchanged and reads nothing extra. The minor bump follows
the `0.x` SemVer policy above.

### Added

- **`erli18n_negotiate`** — a pure, total, dependency-free engine for locale
  canonicalization, fallback-chain construction, and `Accept-Language`
  negotiation. Holds no state (no `gen_server`, ETS, or process dictionary) and
  is property-tested in isolation.
  - **`canonicalize/1`** — folds a BCP-47 / POSIX tag to the erli18n
    catalog-key shape (`<<"pt-BR">>` → `<<"pt_BR">>`): hyphen/underscore
    equivalence, RFC 5646 §2.1.1 positional casing (language lowercase, script
    Titlecase, region UPPERCASE), POSIX charset/modifier suffix stripping
    (`pt_BR.UTF-8`, `ca_ES@valencia`), and a **closed** legacy-language alias
    table (`in`→`id`, `iw`→`he`, `ji`→`yi`, `jw`→`jv`, `mo`→`ro`). Total and
    idempotent. **Out of scope (documented non-goals):** macrolanguage/script
    inference such as `zh_Hans` ⇄ `zh_CN` (needs the CLDR *Add Likely Subtags*
    algorithm) and grandfathered/irregular tags.
  - **`fallback_chain/2`** — the ordered RFC 4647 *Lookup* candidate list
    (`pt-BR` + default `en` → `[<<"pt_BR">>, <<"pt">>, <<"en">>]`), canonicalized,
    order-preserving-deduplicated, and bounded.
  - **`parse_accept_language/1`** — parses an HTTP `Accept-Language` header
    (RFC 9110 §12.5.4) into `[{Range, Q}]` with `Q` as an integer in milli-units
    (`0..1000`); absent `q` = `1000`, well-formed `q=0` dropped, sorted by
    descending quality with a stable header-order tiebreak. Total and fail-soft;
    output shape matches cowlib's `cow_http_hd:parse_accept_language/1`.
  - **`negotiate/2,3`** and **`best_match/3`** — RFC 4647 *Lookup* of a
    preference list against an available-locale set, returning the first
    supported match (preserving the available entry's original casing), a
    default, or `error`.
- **Facade additions on `erli18n`** — `negotiate/2` (always returns a usable
  locale, defaulting to `default_locale/0` on no match), `parse_accept_language/1`,
  `canonicalize_locale/1`, and `set_locale_fallback/1`. None changes an existing
  arity.
- **Opt-in lookup fallback chain** — the four lookup families
  (`gettext` / `ngettext` / `pgettext` / `npgettext`, and so the interpolating
  `f`-family that delegates to them) consult the fallback chain **only on an
  exact-match miss** and **only** when enabled, so a `pt_BR` request resolves a
  loaded `pt` catalog instead of returning the raw `msgid`.
- **Config `erli18n.locale_fallback`** (env, default `off`):
  - `off` — exact match only (0.2.0 behavior; the hit path reads nothing extra).
  - `base_language` — RFC 4647 *Lookup* chain (`pt_BR` → `pt` → `default_locale`).
  - `{explicit, Map}` — `Map :: #{locale() => [locale()]}` override layer; an
    unlisted locale falls through to `base_language`.
- **Telemetry `[erli18n, locale, fallback]`** — emitted when a non-exact locale
  resolves a translation through the chain, with a `chain_depth` measurement and
  `requested_locale` / `resolved_locale` metadata. **Opt-in** under the existing
  `emit_lookup_telemetry` flag and kept entirely off the exact-hit path.
- **`event_locale_fallback/0`** on `erli18n_telemetry`.

### Performance & safety

- **Zero-overhead exact hit.** All fallback work runs strictly in the post-miss
  branch and only when enabled; an exact hit remains a single `ets:lookup` with
  no extra allocation or config read (verified by a dedicated CT case). On a
  miss with fallback on, cost is O(chain length) extra reads, short-circuiting
  on the first hit.
- **Total / fail-soft & anti-DoS.** Parsing untrusted tags and headers never
  raises and never interns atoms (no `binary_to_atom`); bounded by per-tag
  (35 B), subtag (8), chain (8), header (4096 B), element (64), and range (32)
  caps. An invalid `locale_fallback` value degrades to `off` rather than
  breaking a lookup.

### Caveats

- **Likely-subtags inference is not performed.** `zh-CN` canonicalizes to
  `zh_CN`, not `zh_Hans`; a script-only catalog (`zh_Hans`) is not matched by a
  region-only request (`zh_CN`) or vice versa. Load catalogs under the keys your
  clients send, or supply an `{explicit, Map}` mapping.

## [0.2.0] — 2026-06-16

Phase 1: **named `%{var}` interpolation**. This release is additive — every
change is a new function, type, or module; the existing `gettext` / `ngettext` /
`pgettext` / `npgettext` families (and their `d` / `dc` variants) are
behaviorally unchanged. The minor bump follows the `0.x` SemVer policy above.

### Added

- **`erli18n_interp`** — a pure, dependency-free substituter for named
  `%{name}` placeholders. `format/2` (lenient) is **total and fail-soft**: for
  any input and any bindings it returns a binary and never raises. `format/3`
  takes an `opts()` map whose single key, `on_missing`, selects the
  missing-binding policy (`lenient` | `strict`).
  - **Named placeholders.** `%{name}` decouples wording from argument order — a
    translator can move or repeat `%{name}` and the binding still resolves by
    name (atom keys). Values may be a binary, an iolist/string, an integer, a
    float, or an atom, and are coerced to UTF-8 text.
  - **Escaping.** A literal percent is `%%`; to emit a literal, un-substituted
    `%{name}`, write `%%{name}` (the `%%` collapses to `%`, leaving `{name}`
    untouched).
  - **`lenient` vs `strict`.** Lenient leaves an unbound `%{name}` in place
    literally; strict raises `{erli18n_interp, {missing_binding, Name}}`.
  - **Anti-DoS caps.** Output is bounded by `?MAX_OUTPUT_BYTES` (65536): every
    append (literal chunk, coerced bound value, literal placeholder) is
    size-checked in O(1) and the result is truncated to fit before scanning
    stops. Placeholder expansion is bounded by `?MAX_EXPANSIONS` (1024); past
    that, placeholders are emitted literally. Truncation/clamp paths use
    `binary:copy/1` so the returned binary does not pin a large parent binary.
- **`bindings/0` type** — `#{atom() => term()}`, exported from `erli18n_interp`
  (alongside `on_missing/0` and `opts/0`).
- **Interpolating `f`-suffix façade family** — **24** new functions on
  `erli18n`: `gettextf`, `ngettextf`, `pgettextf`, `npgettextf` and their
  `d` / `dc` domain-explicit variants, each with a process-locale and an
  explicit-locale arity. Every `f` function resolves the translation exactly
  like its non-`f` sibling, then splices `%{var}` values from a trailing
  `Bindings :: map()`. The façade `f` family is **lenient** (unbound
  placeholders stay literal; never raises); opt into `strict` by calling
  `erli18n_interp:format/3` directly.
- **Plural count auto-bind.** The `ngettextf` / `npgettextf` families auto-bind
  `count => N`, so `%{count}` is always available without passing it; a
  caller-supplied `count` wins.

### Caveats

- **Bidi / RTL.** Interpolation does **not** auto-insert Unicode bidi isolation
  marks (U+2066–U+2069) around spliced values. Placing an RTL value into an LTR
  sentence (or the reverse) can reorder neighboring punctuation under the
  Unicode Bidirectional Algorithm. Isolate mixed-direction values yourself until
  a future version offers opt-in isolation.

## [0.1.0] — 2026-06-14

Initial development release. The public API is functional but subject to backward-incompatible
changes on minor bumps per the `0.x` SemVer policy.

**Requires OTP 27 or newer.** The public modules carry native `-doc` / `-moduledoc`
documentation attributes (EEP-59), which only compile on OTP 27+; OTP 25.3 and 26 reject
them at compile time with `attribute doc after function definitions`.

### Added

- **Core OTP application**: `erli18n_app`, `erli18n_sup` (intensity `{5, 10}` hardcoded per AMB-002).
- **`erli18n_server`** — gen_server + ETS catalog store with anti-bottleneck pattern (hot path `lookup_*` is lock-free direct ETS from caller process; writes serialized through `protected` table owner).
- **`erli18n_po`** — hand-written recursive-descent parser for GNU gettext `.po` format. Honors PSDs 001-009:
  - PSD-001: fuzzy entries dropped by default; opt-in via `#{include_fuzzy => true}`.
  - PSD-002: charset support restricted to UTF-8, Latin-1, US-ASCII (native to `unicode:characters_to_binary/3`).
  - PSD-003: empty `msgstr` preserved; fallback-to-msgid handled at lookup.
  - PSD-004: header `Plural-Forms` is runtime source of truth; CLDR consulted at load only for divergence warning.
  - PSD-005: BOM UTF-8 stripped silently.
  - PSD-006: msgctxt stored as a separate ETS key field, matching how GNU gettext keys contextual entries (`msgctxt` + `EOT` + `msgid`).
  - PSD-007: obsolete `#~` entries skipped.
  - PSD-008: degenerate plural (`nplurals=1`) accepted.
  - PSD-009: `nplurals` mismatch rejected with structured error.
- **`erli18n_plural`** — recursive-descent C-expression evaluator for `Plural-Forms` header. CLDR data inlined for 49 locales. Bignum-clean.
- **`erli18n_server:ensure_loaded/3,4` and `reload/3,4`** — atomic catalog load (parse → compile plural → validate vs CLDR → insert), with idempotency fast-path (RISK-012 mitigation).
- **`erli18n`** (façade) — full GNU gettext C-macro API surface: `gettext` family (singular), `ngettext` family (plural), `pgettext` family (contextual), `npgettext` family (contextual + plural), with `d`/`dc` aliases. Per-process locale via process dictionary; application-wide defaults via `application:get_env/2`.
- **`erli18n_telemetry`** — 7 `:telemetry` events as first-class observability concern (catalog load/reload/unload spans; lookup miss/fuzzy_skip opt-in; plural divergence warning; memory warning rate-limited). `telemetry` declared as optional dep via `optional_applications` (OTP 24+).
- **Test suite**: 289 Common Test cases, green on OTP 27 and 28 — façade API, gen_server / catalog, `.po` parser, plural evaluator, loader, and telemetry suites, plus PropEr properties (200 runs each) and fuzz scenarios (100–500 runs each). 6 of these are parity scenarios run against the real GNU `gettext` / `ngettext` CLI oracle; that suite skips cleanly when `gettext-tools` or the `pt_BR.UTF-8` / `ru_RU.UTF-8` locales are absent.
- **Coverage**: 100% of behaviorally reachable lines. Dead defensive code removed (no silent fallbacks for invariant violations — crashes are explicit via `function_clause` / `case_clause` / `badmatch`).
- **Apache 2.0 license**.
- **GitHub Actions CI** (`.github/workflows/ci.yml`) — three jobs on pinned `ubuntu-24.04` runners: `lint` (fast quality gate on OTP 28), `test` (Common Test + coverage across OTP 27 and 28, with `gettext` installed and the `pt_BR.UTF-8` / `ru_RU.UTF-8` locales generated so `erli18n_parity_SUITE` exercises the oracle path), `dialyzer` (isolated job with PLT cache). CI runs automatically only on `main`; every other branch runs on demand via `workflow_dispatch`. Concurrency cancellation per ref, least-privilege `contents: read` token, rebar3 build cache keyed per OTP.
- **Local CI emulation** via `act` and a custom runner image (`Dockerfile.act-runner`): extends `ghcr.io/catthehacker/ubuntu:full-24.04` with ELP `2026-02-27` (SHA256-verified per SLSA v0.2). Reuses the workflow YAML unchanged — GitHub-hosted runners gracefully `[SKIP]` the ELP steps in real CI. Bootstrap is declarative in `compose.yml` (`act-toolcache` volume init + image build). `actionlint 1.7.12` pinned via `mise.toml` for static workflow analysis.
- **Repo hygiene**: `README.md` (with usage / install / compatibility / dev sections), `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 3.0), `.editorconfig`.

### Architecture decisions

The design rationale is captured inline in the source: PO-semantics decisions
(`PSD-001`…`PSD-009`), risk mitigations (`RISK-*`), and ambiguity resolutions
(`AMB-*`) are referenced from the relevant module `-moduledoc` / `-doc` attributes
and code comments. The internal planning corpus that originally tracked them is not
part of the published package.

<!--
Per-package release links. The umbrella publishes each package from its own
prefixed tag (`erli18n-vX.Y.Z`), so these point at the `erli18n`-scoped tags
rather than the legacy single `vX.Y.Z` tags. See `.github/workflows/release.yml`.
-->

[Unreleased]: https://github.com/eagle-head/erli18n/compare/erli18n-v0.6.0...HEAD
[0.6.0]: https://github.com/eagle-head/erli18n/releases/tag/erli18n-v0.6.0
[0.5.0]: https://github.com/eagle-head/erli18n/releases/tag/erli18n-v0.5.0
[0.4.0]: https://github.com/eagle-head/erli18n/releases/tag/erli18n-v0.4.0
[0.3.0]: https://github.com/eagle-head/erli18n/releases/tag/erli18n-v0.3.0
[0.2.0]: https://github.com/eagle-head/erli18n/releases/tag/erli18n-v0.2.0
[0.1.0]: https://github.com/eagle-head/erli18n/releases/tag/erli18n-v0.1.0
