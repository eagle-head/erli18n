# Changelog

All notable changes to `rebar3_erli18n` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## Versioning policy

Per [SemVer 2.0.0 §4](https://semver.org/#spec-item-4), this project is in the
`0.x.y` initial-development phase. The plugin's CLI surface (`rebar3 erli18n
{extract,merge,check,report}`, their flags, and the on-disk catalog layout) may
change in a `0.x` minor with a CHANGELOG note; additive flags and providers are
the norm.

## [Unreleased]

## [0.1.1] — 2026-06-25

### Changed

- **Raised the `erli18n` dependency from `~> 0.5` to `~> 0.6`,** in lockstep with
  the co-released `erli18n` 0.6.0. The plugin still calls only the long-stable
  `erli18n_po:parse/1` / `dump/1` / `escape_string/1` API, so the bump pins the
  exact library line this release is built and tested against rather than
  requiring new API. The publish order is unchanged — `erli18n` 0.6.0 must be
  live on Hex before this plugin, since the published `requirements` resolve
  `~> 0.6`.

### Fixed

- **`extract` and `merge` no longer crash with a `badmatch` when a catalog file
  cannot be written.** Both providers matched `file:write_file/2` (and
  `filelib:ensure_path/1` / `ensure_dir/1`) against a bare `ok =`, so any
  filesystem failure — a read-only `priv/gettext`, an uncreatable parent,
  `enospc` — aborted the whole `extract`/`merge` run on a `{badmatch, {error, _}}`
  stacktrace. `extract`'s `write_pots`/`write_each_pot` and `merge`'s `write_po/2`
  now short-circuit to `{error, {write_failed, Path, Reason}}` on the first
  failure, which `do/1` surfaces as a normal `{error, _}` provider result. No CLI,
  flag, or on-disk-layout change.
- **`rebar3_erli18n_common:format_error/1` renders the new `{write_failed, Path,
  Reason}` reason** as `erli18n: cannot write <path>: <reason>`, so a write
  failure prints a clean human-readable message instead of the raw `~p`
  catch-all.

## [0.1.0] — 2026-06-23

Initial release of the `rebar3_erli18n` catalog-tooling plugin as its own Hex
package. It depends on the runtime library `erli18n` (`{deps, [{erli18n, "~>
0.5"}]}`) and is published **after** `erli18n 0.5.0`. The package is built and
published from its own app directory (`cd apps/rebar3_erli18n && rebar3 hex
publish ...`), which resolves `erli18n` from Hex into a per-app lock as a
level-0 `{pkg,...}` entry — the entry `create_package` carries into the
published `requirements` (verified locally: the per-app build produces tarball
`requirements = {erli18n, "~> 0.5"}`). That resolution can only happen once the
matching `erli18n` minor is live on Hex, which is why the publish order is
`erli18n` first, then the plugin.

### Added

- **Initial `rebar3_erli18n` plugin package.** Promoted from in-repo tooling to
  a first-class, publish-ready rebar3 plugin app under `apps/rebar3_erli18n/`
  in the erli18n umbrella. Ships four providers under the `erli18n` namespace —
  `extract`, `merge`, `check`, and `report` — plus the host seam
  (`rebar3_erli18n_host`), the abstract-form extractor, the Jaro fuzzy matcher,
  the keyword spec, and the PO metadata serializer.
- **README** documenting the opt-in `{plugins, [rebar3_erli18n]}` install, the
  Gettext-style merge contract (`#:` references and extracted comments
  authoritative from the fresh `.pot`; only `msgstr` preserved from the old
  `.po`; new msgids fuzzy-matched against removed ones into `#, fuzzy` entries
  with a `#|` previous-msgid hint; removed msgids demoted to `#~` obsolete),
  the **dynamic-msgid caveat** (only compile-time literal msgids are extracted;
  a runtime-computed id still translates but is not statically discoverable),
  the consumer two-checkouts requirement for local dev, and the rejected
  xref-alternatives note.
- **Apache-2.0 LICENSE.**
- **Executed proof of the plugin → lib load path.** Added a
  `ERLI18N_DIAG_LOADPATH`-gated diagnostic in `rebar3_erli18n_common` that logs
  the loaded location of `erli18n_po` at provider-run time. Driven from
  `examples/erli18n_demo/`, `extract` → `merge --locale pt_BR` → `check` all
  succeed and `code:which(erli18n_po)` resolves under the consumer's
  `_build/<profile>/checkouts/erli18n/ebin/erli18n_po.beam` — proving the
  unpublished runtime library is reached through the consumer's checkout (not a
  Hex fetch) across the `{deps, [erli18n]}` boundary, with no
  `undef erli18n_po:dump/1`. The `providers_SUITE`
  `runtime_lib_reachable_at_provider_run` and `common_SUITE`
  `runtime_lib_path_resolves` cases assert the same edge in-node. See the README
  "Proven cross-package load path" section. Because the path is proven, the
  contingency private escaper/dumper was **not** vendored — the providers reuse
  `erli18n_po:escape_string/1` directly.

### Changed

- **Declared a real dependency on the runtime library**
  (`{deps, [{erli18n, "~> 0.5"}]}`, `{applications, [kernel, stdlib,
  erli18n]}`), replacing the earlier false "build-only, kernel + stdlib, no
  runtime erli18n dep" claim. The providers reuse the published PO API
  (`erli18n_po:parse/1`, `erli18n_po:dump/1`, `erli18n_po:escape_string/1`)
  across this package boundary, in the **plugin → lib** direction (the same as
  `rebar3_gpb_plugin` → `gpb`). This dependency is also what binds an
  unpublished consumer's `_checkouts/erli18n` onto the plugin's runtime path at
  provider-run time.
- **Form walk is now O(nodes).** The abstract-form walk called `lists:flatten`
  at every recursion level (O(extractions × ast-depth)); it now threads a single
  accumulator and reverses once at the top. Behavior is identical.
- **Keyword spec is a compile-time constant.** `rebar3_erli18n_keywords:spec/0`
  built the ~48-entry `{Name, Arity} => slots()` table with `maps:merge/2` on
  **every** call (and `lookup/2` calls it per look-up). It is now a single
  literal map, so the compiler builds it once and every call returns the same
  shared constant; `lookup/2` is a single `maps:find` over that constant. The
  table contents are unchanged.

### Fixed

- **`merge`'s `previous_of/1` now renders in the generated docs.** The
  white-box-only export carried its rationale only in a plain `%%` comment,
  which ex_doc does not read, so the function surfaced on the published doc
  page as undocumented. Its explanation is now a real `-doc` attribute (a
  native EEP-48 Docs chunk), stating that it is a build-tool internal exported
  solely for white-box testing and not part of any published (Hex) API
  surface. No behavior change.
- **`check` now detects a domain whose call sites have all vanished.** The
  freshness check folded only over the freshly-extracted domains, so a domain
  whose every call site was deleted dropped out of extraction entirely and its
  now-orphaned committed `.pot` was never compared — drift was missed and
  `check` wrongly passed. `check` now compares the **union** of the
  freshly-extracted domains and the domains with a committed `<Domain>.pot` on
  disk; a domain present on disk but absent from fresh extraction is compared
  against an empty catalog, so its stale `.pot` correctly reports drift (it
  should be regenerated to empty or removed). The dynamic-key guarantee is
  unaffected — a legitimately dynamic key is never extracted, so it never
  appears in a committed `.pot` and never produces a phantom domain.
- **Extractor no longer crashes on a surrogate-code-point binary msgid.** A
  literal binary msgid whose integer segment is a UTF-16 surrogate
  (`16#D800..16#DFFF`, e.g. `erli18n:gettext(<<16#D800>>)`) passed the
  integer-segment guard but then failed to encode as `<<Int/utf8>>`, raising
  `badarg` and aborting the whole `extract`/`check`/`merge`/`report` run on a
  stacktrace. The integer-segment guard now excludes the surrogate range, so
  such a segment is non-resolvable and the call site is **skipped** exactly like
  any other non-compile-time-literal msgid (the documented dynamic-key-skip
  contract), never crashing.

### Removed

- **The host-beam extraction workaround** (a vendored generator escript that
  extracted the rebar3 host modules into a generated beam directory, plus the
  matching root `rebar.config` project-app-dirs / extra-paths wiring that
  analyzed the plugin as a project app). The rebar3 host modules (`providers`,
  `rebar_state`, `rebar_api`, `rebar_app_info`) are now resolved for xref by a
  scoped `-ignore_xref([...])` in the `rebar3_erli18n_host` seam and a matching
  `{xref_ignores, [...]}` in `rebar.config`, confined to the eight host
  `{M, F, A}` edges — every other module stays under active
  `undefined_function_calls` checking.

### Tests

- **`report`'s console output is now asserted, not just `{ok, _}`.** The four
  `report_*` provider cases previously asserted only that `do/1` returned
  `{ok, _}`, never inspecting the printed table — so a format regression would
  pass silently. They now capture the real per-`(Domain, Locale)` text the
  command prints (by swapping the test process's group leader for a capturing
  I/O server, exercising `do/1` -> `rebar3_erli18n_host:console/2`, not a
  private builder) and assert it byte-for-byte, including the `(no catalog)`
  line, an explicit-`--domain` report, and a fully-translated plural counting
  as `1/1`.
- **Adversarial `.po` coverage for `merge`/`check`/`report`.** Beyond the lone
  truncated-`msgstr` parse error, three committed fixtures under
  `providers_SUITE_data/` now drive the documented fail-soft behavior: an
  **invalid-UTF-8** body (raw `0xFF 0xFE` under a `charset=UTF-8` header) makes
  `merge` and `report` return a structured `{error, _}` naming the file and the
  `charset_conversion` reason — and makes `check` report drift in both the
  default and `--names-only` modes — never a crash; a **line-wrapped** old
  msgid (`"Sign in " "to your account"`) is decoded to the same key as the
  unwrapped fresh `.pot` msgid, so its translation carries over with no fuzzy
  and no obsolete (pinning the wrapping-insensitive equality contract); and a
  **larger** 60-entry old `.po` exercises the `read_old` parse path at scale,
  carrying the one surviving key and demoting the other 59 to `#~` obsolete.

<!--
Per-package release links. The umbrella publishes each package from its own
prefixed tag (`rebar3_erli18n-vX.Y.Z`), so these point at the
`rebar3_erli18n`-scoped tags rather than a bare `vX.Y.Z` tag. See
`.github/workflows/release.yml`.
-->

[Unreleased]: https://github.com/eagle-head/erli18n/compare/rebar3_erli18n-v0.1.1...HEAD
[0.1.1]: https://github.com/eagle-head/erli18n/releases/tag/rebar3_erli18n-v0.1.1
[0.1.0]: https://github.com/eagle-head/erli18n/releases/tag/rebar3_erli18n-v0.1.0
