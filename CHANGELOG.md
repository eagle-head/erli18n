# Changelog

All notable changes to `erli18n` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## Versioning policy

Per [SemVer 2.0.0 §4](https://semver.org/#spec-item-4), this project is in the `0.x.y` initial-development phase:

- **`0.x.y` → `0.x.y+1`** (patch): backward-compatible bug fixes only.
- **`0.x.y` → `0.x+1.0`** (minor): may introduce backward-incompatible changes, announced in advance via CHANGELOG. Additive changes (new functions, new arities, new opt-in flags, new telemetry events) are the norm.
- **Telemetry events** are versioned per the schema policy in `observability.md` §7; events marked `@stable` cannot change schema within `0.x` series, events marked `@unstable` may.

## Criteria for `1.0.0`

The `1.0.0` release commits to API stability. Tag bumps to `1.0.0` only when **all** of the following hold:

1. At least one external project uses `erli18n` in production for ≥ 6 months without reporting breaking issues.
2. The Post-0.1.0 Roadmap items that affect public API surface (charset support, hot upgrade behavior, async load) are either implemented or formally rejected with rationale.
3. Parity SUITE (`erli18n_parity_SUITE`) passes end-to-end against `gettexter` + `msgfmt` ≥ 0.21 oracle (currently 6 scenarios; target ≥ 20 covering all 9 `.feature` files in the design docs).
4. No unfixed `@unstable` telemetry events remain — all events either promoted to `@stable` or removed.
5. CHANGELOG documents zero behavioral changes for at least 2 consecutive minor releases.

## [Unreleased]

### Added

- **GitHub Actions CI** (`.github/workflows/ci.yml`) — three jobs running on `ubuntu-latest`:
  - `lint`: fast quality gate (`bin/quality-gate.sh --fast`) on OTP 28.
  - `test`: Common Test + coverage matrix across OTP 25.3 (minimum), 27, and 28. Installs GNU `gettext` (msgfmt) so `erli18n_parity_SUITE` exercises the oracle path instead of skipping.
  - `dialyzer`: isolated job with PLT cache keyed on `rebar.config` + `rebar.lock`.
  - Concurrency cancellation per ref, least-privilege `contents: read` token, rebar3 build cache keyed per OTP.
  - Locally runnable via `act` (`mise exec -- act -j lint`).

## [0.1.0] — Initial development release

### Added

- **Core OTP application**: `erli18n_app`, `erli18n_sup` (intensity `{5, 10}` hardcoded per AMB-002).
- **`erli18n_server`** — gen_server + ETS catalog store with anti-bottleneck pattern (hot path `lookup_*` is lock-free direct ETS from caller process; writes serialized through `protected` table owner).
- **`erli18n_po`** — hand-written recursive-descent parser for GNU gettext `.po` format. Honors PSDs 001-009:
  - PSD-001: fuzzy entries dropped by default; opt-in via `#{include_fuzzy => true}`.
  - PSD-002: charset support restricted to UTF-8, Latin-1, US-ASCII (native to `unicode:characters_to_binary/3`).
  - PSD-003: empty `msgstr` preserved; fallback-to-msgid handled at lookup.
  - PSD-004: header `Plural-Forms` is runtime source of truth; CLDR consulted at load only for divergence warning.
  - PSD-005: BOM UTF-8 stripped silently.
  - PSD-006: msgctxt stored as separate ETS key field (paridade com `gettexter`).
  - PSD-007: obsolete `#~` entries skipped.
  - PSD-008: degenerate plural (`nplurals=1`) accepted.
  - PSD-009: `nplurals` mismatch rejected with structured error.
- **`erli18n_plural`** — recursive-descent C-expression evaluator for `Plural-Forms` header. CLDR data inlined for 49 locales. Bignum-clean.
- **`erli18n_server:ensure_loaded/3,4` and `reload/3,4`** — atomic catalog load (parse → compile plural → validate vs CLDR → insert), with idempotency fast-path (RISK-012 mitigation).
- **`erli18n`** (façade) — full GNU gettext C-macro API surface: `gettext` family (singular), `ngettext` family (plural), `pgettext` family (contextual), `npgettext` family (contextual + plural), with `d`/`dc` aliases. Per-process locale via process dictionary; application-wide defaults via `application:get_env/2`.
- **`erli18n_telemetry`** — 7 `:telemetry` events as first-class observability concern (catalog load/reload/unload spans; lookup miss/fuzzy_skip opt-in; plural divergence warning; memory warning rate-limited). `telemetry` declared as optional dep via `optional_applications` (OTP 24+).
- **Test suite**: 238 tests total (10 server, 27 po, 34 plural, 18 loader, 36 façade, 17 telemetry, 9 PropEr properties P1-P5 @ 200 runs each, 7 fuzz scenarios F1-F7 @ 100-500 runs each, 6 parity scenarios skipped without `msgfmt`).
- **Coverage**: 100% of behaviorally reachable lines. Dead defensive code removed (no silent fallbacks for invariant violations — crashes are explicit via `function_clause` / `case_clause` / `badmatch`).
- **Apache 2.0 license**.

### Architecture decisions documented

See `_reversa_sdd/migration/` (in the parent repo) for the full design corpus:
- 9 PSDs (PO Semantics Decisions)
- 21 EXs (parity exceptions)
- 14 RISKs (architectural risks with mitigations)
- 9 AMBs (ambiguity log)
- 5 PropEr properties + 7 fuzz scenarios specifications
- Topology, paradigm, observability, target architecture, and test strategy documents
