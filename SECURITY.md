# Security Policy

## Supported versions

Only the **latest minor release** of `erli18n` receives security updates. While the project is in the `0.x.y` initial-development phase, this means the most recent `0.x` line is supported; older `0.x` lines are not.

| Version | Supported |
|---|---|
| `0.3.x` (latest) | ✅ |
| `< 0.3.0` | ❌ |

Once the project reaches `1.0.0`, the support window will be re-evaluated and documented here.

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
- **CLDR data** — inlined for 49 locales; not loaded from disk at runtime.
- **Telemetry events** (`erli18n_telemetry`) — event payloads must not leak msgid contents that could be sensitive in a multi-tenant context. The default `emit_lookup_telemetry => false` minimizes this surface.

Out of scope:

- Vulnerabilities in `telemetry` (optional dep) — report upstream to [beam-telemetry/telemetry](https://github.com/beam-telemetry/telemetry).
- Vulnerabilities in `proper` or `eqwalizer_support` (test-only deps).
- Vulnerabilities in the OTP runtime itself — report to [Ericsson OTP security](https://www.erlang.org/news/security).
