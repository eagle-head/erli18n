# erli18n

Modern internationalization (i18n) library for Erlang, GNU gettext compatible.

## Status

**Pre-release.** Current development tag is `0.1.0`.

Per [Semantic Versioning 2.0.0 §4](https://semver.org/#spec-item-4), `0.x.y` versions are for initial development — the public API is functional but not yet stabilized. Breaking changes may occur on minor bumps (`0.1.0` → `0.2.0`) when triggered by real-world usage feedback. Patch bumps (`0.1.0` → `0.1.1`) are strictly backward-compatible.

A `1.0.0` release commits to API stability. The criteria for `1.0.0` are documented in `CHANGELOG.md`.

## Goals

Build a GNU gettext-compatible i18n library for Erlang that closes the gap between the existing Erlang options and the maturity of `gettext` in the Elixir ecosystem.

Specifically:

- **`.po` / `.pot` file support** — full GNU gettext format compatibility, so translations work with Poedit, Crowdin, Transifex, Weblate, and any standard tooling.
- **Key extraction from source** — via standard GNU `xgettext` CLI (industry standard; same tooling used by C, Python, Ruby, PHP, Java). Compile-time key validation is intentionally out of scope — `erli18n` follows the runtime + tests pattern of Spring Boot MessageSource, Django, Rails I18n, Symfony Translation, and other mainstream i18n libraries.
- **Pluggable output backends** — `.po`, JSON, raw Erlang terms, custom.
- **CLDR-backed pluralization** — proper plural rules for common locales, with header-of-`.po` as runtime source of truth.
- **Telemetry observability** — `:telemetry` events as first-class architectural concern (optional dep).

## Why not just use `gettexter`?

The existing [`gettexter`](https://github.com/seriyps/gettexter) library (Apache 2.0) covers the core gettext runtime but has been mostly idle since 2023 and never received key features the Erlang community has asked for since 2014 — most notably an extraction tool.

`erli18n` starts from a clean slate to avoid being constrained by older design decisions, while staying fully interoperable with the GNU gettext file format so translations remain portable.

## Why not use Elixir `gettext` directly?

Adding Elixir to an Erlang-only project is a non-trivial choice (build toolchain, hiring, team familiarity). `erli18n` exists for projects that want first-class i18n in pure Erlang without that trade-off.

## License

Apache 2.0. See `LICENSE`.

## References

- GNU gettext: https://www.gnu.org/software/gettext/
- gettexter: https://github.com/seriyps/gettexter
- Unicode CLDR: https://cldr.unicode.org/
- SemVer 2.0.0: https://semver.org/
