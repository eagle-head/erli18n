# Contribution & release workflow

The authoritative playbook for taking a change from a clean local edit to `main`
and onward to a tagged Hex release for the `erli18n` umbrella (the `erli18n`
library and the `rebar3_erli18n` plugin). It is evidence-based — every rule
traces to an official doc or a recognised authority, cited inline.

## The model

**GitHub Flow with trunk-based discipline.** Short-lived branches off `main`,
rebased often, integrated fast; `main` is always releasable. Git Flow's
`develop`/`release`/`hotfix` layering is deliberately rejected as overkill for a
continuously-delivered library. ([GitHub flow](https://docs.github.com/en/get-started/using-github/github-flow);
Fowler, [_Patterns for Managing Source Code Branches_](https://martinfowler.com/articles/branching-patterns.html)
— "Frequency Reduces Difficulty"; [trunkbaseddevelopment.com](https://trunkbaseddevelopment.com/).)

**The gate that protects `main` is automated CI, not human discipline.** A
self-testing build verifies every integration and keeps the mainline releasable
(Fowler, [_Continuous Integration_](https://martinfowler.com/articles/continuousIntegration.html)).
The local quality gate is _fast feedback_, not the binding barrier.

**PR vs direct merge.** Always open a pull request against `main` — even your
own — as a self-review surface and a durable record, then merge it yourself. The
PR keeps the maintainer path identical to the contributor path.

## Branch naming

Branch from an up-to-date `main`; never commit to `main` directly.

```
git switch main && git pull
git switch -c feat/<slug>        # feat/ fix/ chore/ ci/ docs/ build/ refactor/ test/
```

## Commit rules

Conventional Commits feed the changelog and the SemVer bump, so they are
machine-read and must be exact.
([Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/);
[cbea.ms/git-commit](https://cbea.ms/git-commit/); Pro Git, _Distributed Git_.)

- **Format:** `type(scope): subject`. Types: `feat` (→ MINOR), `fix` (→ PATCH),
  plus `chore`, `ci`, `docs`, `build`, `refactor`, `test`, `perf`.
- **Scope = the Hex package** the change feeds: `erli18n` or `rebar3_erli18n`
  (or omit for repo-wide). A reader must see which package, changelog and tag a
  commit belongs to.
- **Subject:** imperative mood ("add", not "added"), lower-case after the colon,
  no trailing period, ≤ ~50 characters.
- **Body:** separated by a blank line, wrapped at ~72, and it explains the
  **why**, not the how.
- **Atomic:** one commit = one idea. Clean local history with `git rebase -i` /
  `git commit --amend` **before** the first push (safe while unpushed; never
  rewrite `main`).
- **Language:** US English (en-US) everywhere. **No AI/tool footer.**

```
feat(erli18n): add pgettext context fallback

The lookup previously ignored the context on a miss; fall back to the
context-less msgid so a partial catalog still resolves the base string.
```

## The local quality gate (fast feedback)

Run before pushing; install the git hooks once so it runs automatically.

```
bin/quality-gate.sh --full     # compile · xref · erlfmt · elvis · hank · elp lint
                               # · dialyzer · eqwalize · ct+cover (100%) · catalog check
./hooks/install.sh             # --fast on pre-commit, --full on pre-push
```

For a change touching `src/`, the PO parser, plural rules, telemetry, an
`.app.src`, or the publish path, also run the local two-OTP matrix — it is a
_superset_ of CI (both supported OTPs **and** ELP):

```
docker compose -f compose.matrix.yml up     # OTP 27 + 28, full gate, ELP installed
```

## Flow: local change → `main`

1. **Branch** off a green, current `main` (above).
2. **One focused change + tests.** Keep the branch under ~a day and
   single-concern; every behavioural change gets a test, every bug fix a
   regression test that failed on the old code. (Fowler "less than a day"; TBD.)
3. **Update the affected package's `[Unreleased]` changelog** —
   `apps/erli18n/CHANGELOG.md` or `apps/rebar3_erli18n/CHANGELOG.md` (the root
   `CHANGELOG.md` is umbrella-structure history only). ([Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).)
4. **Commit** per the rules above; tidy local history before pushing.
5. **Run the gate** (`--full`, and the OTP matrix for risky changes).
6. **Push and open a self-PR** against `main`:
   ```
   git push -u origin feat/<slug>
   gh pr create --base main --fill
   ```
7. **Wait for CI to pass on the PR**, self-review the rendered diff, then merge
   (see _Merge strategy_) and delete the branch.

## CI as the gate — and keeping control over who triggers it

CI runs the **full** quality gate (the same steps as `--full`, with ELP
installed) on **OTP 27 and 28**, as a **required status check** on `main`.

For this public, open-source repository:

- **GitHub Actions is free** on standard runners for public repos, so PR CI does
  not cost minutes. ([About billing for GitHub Actions](https://docs.github.com/en/billing/managing-billing-for-your-products/about-billing-for-github-actions).)
- **External / fork PRs do NOT run CI automatically.** With _Require approval
  for all outside collaborators_ enabled, a fork PR's workflows are **queued
  pending a maintainer's explicit approval** ("Approve workflows to run"); each
  new push to the fork re-requires approval. The maintainer's own branches (same
  repo) run automatically. ([Approving workflow runs from public forks](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/approve-runs-from-forks).)
- Fork `pull_request` workflows run **without access to secrets** and with a
  read-only token — they can never reach `HEX_API_KEY` or publish.

> **Do NOT** set a required status check on `main` that points at a job which
> never runs on PRs — that would deadlock merges. Require the PR-CI checks (which
> do run) instead.

## Merge strategy

**Rebase and merge via the pull request**, then sync locally. This keeps `main`
linear, preserves the granular Conventional Commits the release tooling reads,
and is consistent with always opening a PR. Squash only a genuinely messy branch;
avoid a plain merge commit (it makes history non-linear). ([About merge methods on GitHub](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/about-merge-methods-on-github).)

```
# On the PR, click "Rebase and merge", then locally:
git switch main && git pull
git branch -d feat/<slug>
```

> **Signed commits only:** GitHub's _Rebase and merge_ re-creates the commits and
> drops signature verification. If you ever GPG/SSH-sign your commits, complete
> the merge as a local fast-forward instead (`git merge --ff-only feat/<slug>`
> then `git push`). This repository does **not** sign commits, so the PR button is
> the correct path.

## Release: `main` → tagged Hex packages (per package, lib-then-plugin)

Versions are immutable on Hex, which is why a deliberate **tag** — not a merge —
triggers publishing. ([SemVer 2.0.0](https://semver.org/) §3; Pro Git, _Tagging_.)

1. **Pick the version (SemVer, 0.x).** Both packages are major-zero. Project
   policy pre-1.0: a public-API / telemetry / env-key change is a **minor**
   bump, a compatible bug fix is a **patch**. (SemVer §4.)
2. **Promote the changelog** of the package being cut: move its `[Unreleased]`
   block under a dated `## [X.Y.Z] - YYYY-MM-DD` heading and reset `[Unreleased]`
   — `release.yml` slices this exact section into the GitHub Release body.
3. **Bump `vsn`** in that package's `src/<app>.app.src` and commit to `main`. If
   the `erli18n` bump crosses the minor the plugin requires, in the same release
   bump `{erli18n, "~> X.Y"}` in `apps/rebar3_erli18n/rebar.config` and the
   plugin's own `vsn`.
4. **Tag the library first** with the prefixed, annotated scheme and push:
   ```
   git tag -a erli18n-v0.6.0 -m "erli18n 0.6.0"
   git push origin erli18n-v0.6.0
   ```
5. **Confirm `erli18n` is live on Hex, then tag the plugin**
   (`rebar3_erli18n-vX.Y.Z`). The `release.yml` "Enforce erli18n-first publish
   order" step fails fast if the required `erli18n` version is not yet on Hex.
6. **Approve the gated publish.** Each package publishes from its own app
   directory (so the per-app lock carries `erli18n` into the plugin's
   `requirements`); the actual Hex push waits on the `hex-publish` environment's
   required reviewer.

**Release is locked to the maintainer** in three layers: the tag-push trigger
needs write access (fork contributors cannot push tags), the `hex-publish`
environment requires the maintainer's approval, and fork workflows have no
secrets. ([Using environments for deployment / required reviewers](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).)

## Activation — required GitHub settings (one-time)

The file-based parts of this workflow live in the repo; these repository
**settings** are not version-controlled and must be configured before the
CI-as-gate model is live:

1. **Settings → Actions → General → Fork pull request workflows from outside
   collaborators →** `Require approval for all outside collaborators`. (Stops
   external PRs from running CI without maintainer approval.)
2. **Add the `pull_request: branches: [main]` trigger and the ELP install +
   `elp lint` / `eqwalize-all` steps to `.github/workflows/ci.yml`** so CI is the
   full gate. (Do this only after step 1.)
3. **Settings → Branches / Rulesets → protect `main`:** require the CI status
   checks; block direct pushes and force-pushes; require linear history; do not
   allow bypassing.
4. **Settings → Environments → `hex-publish` →** add the maintainer as a
   **required reviewer** (locks publishing).
