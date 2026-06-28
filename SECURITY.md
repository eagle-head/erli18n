# Security Policy

## Supported versions

This umbrella publishes two Hex packages: the `erli18n` runtime library and the `rebar3_erli18n` build-time rebar3 plugin. Only the **latest minor release** of each receives security updates. While the project is in the `0.x.y` initial-development phase, this means the most recent `0.x` line of each package is supported; older `0.x` lines are not.

| Package | Version | Supported |
|---|---|---|
| `erli18n` | `0.6.x` (latest) | ✅ |
| `erli18n` | `< 0.6.0` | ❌ |
| `rebar3_erli18n` | `0.1.x` (latest) | ✅ |
| `rebar3_erli18n` | `< 0.1.0` | ❌ |

Once a package reaches `1.0.0`, its support window will be re-evaluated and documented here.

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues, discussions, or pull requests.**

To report a vulnerability, send an email to **eduardokohn15@gmail.com** with:

- A description of the vulnerability and its potential impact.
- Steps to reproduce — a minimal Common Test case or `.po` fixture is ideal.
- The affected version(s).
- Any suggested fix or mitigation, if you have one.
- Whether you would like credit in the release notes (and your preferred name / handle / link).

### What to expect

- **Acknowledgement** within 48 hours confirming receipt.
- **Initial assessment** within 5 business days with an estimated timeline.
- **Resolution** as soon as reasonably possible — typically within 30 days for high-severity issues.
- **Coordinated disclosure**: the release with the fix is published first, then a security advisory linked to the CVE (when applicable) and a CHANGELOG entry under the `### Security` heading per [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

We will keep you informed throughout the process.

## Scope

`erli18n` is a pure Erlang/OTP library with **no network access, no filesystem writes (catalogs are read-only), no persistent storage, and no authentication logic**. The attack surface is intentionally narrow:

- **`.po` / `.pot` parser** (`erli18n_po`) — handles untrusted input. Parsing errors must surface as structured errors, never as silent crashes or arbitrary memory growth. Fuzz scenarios F1–F7 exercise malformed inputs (atomic bombs, oversized strings, integer overflow in plural expressions, etc.); regressions in this surface are top-priority.
- **Plural expression evaluator** (`erli18n_plural`) — evaluates the `Plural-Forms` header expression at lookup time. Denial-of-service via deeply nested or pathological expressions is in scope.
- **HTTP request parsing** (`erli18n_http`, used by the optional `erli18n_cowboy` / `erli18n_elli` adapters) — handles untrusted `Cookie` headers, raw query strings, and `Accept-Language` values. Parsing is total and fail-soft (malformed cookies, percent-escapes, and headers are skipped, never raised) and bounded against abuse (byte caps and capped `;` / `&` splits); denial-of-service via pathological request inputs is in scope. The adapters parse request data only — `erli18n` itself still opens no sockets.
- **CLDR data** — the CLDR plural rules are inlined as a static literal (generated from the committed GNU gettext / CLDR seed); none is loaded from disk at runtime.
- **Telemetry events** (`erli18n_telemetry`) — event payloads must not leak msgid contents that could be sensitive in a multi-tenant context. The default `emit_lookup_telemetry => false` minimizes this surface.
- **`rebar3_erli18n`** — a **build-time** rebar3 plugin, not a runtime component: its extractor parses project-local Erlang source (via `epp`, reading only compile-time-constant operands) and merges `.po` catalogs during the build. It does not handle untrusted runtime input. Report plugin vulnerabilities to the same contact above (**eduardokohn15@gmail.com**).

Out of scope:

- Vulnerabilities in `telemetry` (optional dep) — report upstream to [beam-telemetry/telemetry](https://github.com/beam-telemetry/telemetry).
- Vulnerabilities in `proper` or `eqwalizer_support` (test-only deps).
- Vulnerabilities in the OTP runtime itself — report to [Ericsson OTP security](https://www.erlang.org/news/security).
