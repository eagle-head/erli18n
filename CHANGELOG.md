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

_No unreleased changes._

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
  There is **no lookup behaviour change**: `lookup_singular/4`,
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
  sentence (or the reverse) can reorder neighbouring punctuation under the
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
