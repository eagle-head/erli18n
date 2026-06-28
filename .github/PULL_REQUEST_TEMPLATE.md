<!--
Thanks for contributing to erli18n! This is a lightweight checklist distilled
from CONTRIBUTING.md. For a tiny docs/typo PR: keep the Summary, tick "Docs /
chore / CI only", and skip the items that don't apply — don't let the checklist
deter a one-line fix.
-->

## Summary

<!-- What changes, and *why* (the motivation). Link any related issue: Fixes #123. -->

## Affected package

- [ ] `erli18n` (runtime library)
- [ ] `rebar3_erli18n` (rebar3 plugin)
- [ ] Repo-wide / umbrella tooling or docs

## Type

- [ ] Bug fix (patch)
- [ ] Feature / public-API / `:telemetry` schema / env-key change (minor under the 0.x policy)
- [ ] Docs / chore / CI only

## Checklist

- [ ] Commits follow Conventional Commits with a package scope, e.g. `fix(erli18n): ...` (see `docs/WORKFLOW.md`)
- [ ] Tests added or updated; a **bug fix includes a regression test** that fails on the old code and passes on the new
- [ ] Updated the affected package's `[Unreleased]` CHANGELOG — `apps/erli18n/CHANGELOG.md` or `apps/rebar3_erli18n/CHANGELOG.md`
- [ ] `bin/quality-gate.sh --full` passes locally (compile, xref, erlfmt, elvis, hank, elp lint, actionlint, dialyzer, eqwalize-all, ct + cover, gettext parity, catalog freshness)
- [ ] If a *Type* box above marks this a public-API / telemetry-schema / env-key change, it is called out in the Summary — it forces a **minor** version bump per the 0.x policy

<!--
CI runs the full quality gate on OTP 27, 28, and 29 for same-repo PRs to `main`;
fork PRs run after a maintainer approves the workflow (and run without access to
secrets). Keep `bin/quality-gate.sh --full` as your pre-push discipline
regardless. See CONTRIBUTING.md.
-->
