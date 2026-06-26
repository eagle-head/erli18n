# Releasing

This is the practical, copy-paste runbook for shipping changes and publishing the two Hex packages in this umbrella. The authoritative policy — branching, commit rules, the merge strategy, and the rationale behind the release design — lives in [`WORKFLOW.md`](WORKFLOW.md); this file is the step list you follow on the day.

The umbrella ships two independently-versioned Hex packages:

- **`erli18n`** — the runtime library (`apps/erli18n`).
- **`rebar3_erli18n`** — the rebar3 plugin (`apps/rebar3_erli18n`).

## Ground rules

- **Never push to `main` directly.** `main` is protected with strict required status checks (`full gate (OTP 27)` + `full gate (OTP 28)`) and `enforce_admins` enabled, so a direct push — even a docs-only one — is rejected. Everything lands through a pull request, including documentation.
- **Publishing is triggered by a tag, not by a push to `main`.** Pushing a per-package prefixed tag triggers [`.github/workflows/release.yml`](../.github/workflows/release.yml), which builds and publishes that one package. Hex versions are immutable, so publishing is gated on a deliberate version tag rather than on a merge.
- **The tag version must match the package's `app.src` `vsn`.** The workflow fails fast if they differ, so the git tag and the Hex version can never drift.
- **Publish order is strict: `erli18n` first, then `rebar3_erli18n`.** The plugin declares `{erli18n, "~> X.Y"}`; that requirement can only resolve on Hex once the matching `erli18n` minor is live. The plugin's release job enforces this and fails if `erli18n` is not yet published.
- **The publish pauses for a human approval.** The `hex-publish` environment requires a maintainer to approve the deployment before anything is uploaded. Nothing reaches Hex until that approval — keep it a deliberate, manual step.

## Part 1 — Land changes on `main`

```sh
# 1. Start from an up-to-date main.
git checkout main
git pull --ff-only

# 2. Branch (prefixes: feat/ fix/ chore/ ci/ docs/ build/ refactor/ test/).
git checkout -b feat/my-change

# 3. Commit in focused, granular Conventional Commits (en-US, no AI footer).
#    type(scope): subject  — scope is the Hex package (erli18n / rebar3_erli18n).
git add <files>
git commit -m "feat(erli18n): ..."

# 4. Push the branch (never main).
git push -u origin feat/my-change

# 5. Open the PR against main.
gh pr create --base main --head feat/my-change --title "..." --body-file body.md

# 6. Wait for the required checks (full gate on OTP 27 and OTP 28) to pass.
gh pr checks <PR> --watch

# 7. Rebase-and-merge (preserves the Conventional Commits; linear history).
gh pr merge <PR> --rebase --delete-branch

# 8. Sync local main.
git checkout main
git pull --ff-only
```

This applies to documentation too: there is no direct-to-`main` shortcut for a docs-only change. The CI for a docs change is fast, so the PR is cheap.

Before releasing, make sure the version is bumped: the package's `app.src` `vsn` is the new version and its `CHANGELOG.md` has a matching `## [X.Y.Z]` section (those changes ride in the PR above, so they are on `main` before you tag).

## Part 2 — Publish to Hex (tags)

### A. Publish `erli18n` (always first)

```sh
# 1. Up-to-date main, carrying the version you are about to tag.
git checkout main && git pull --ff-only
grep vsn apps/erli18n/src/erli18n.app.src        # e.g. {vsn, "0.6.0"}

# 2. Create the annotated, prefixed tag (format: erli18n-vX.Y.Z).
git tag -a erli18n-v0.6.0 -m "Release erli18n 0.6.0"

# 3. Push only the tag — this is what triggers release.yml.
git push origin erli18n-v0.6.0
```

The run **"Release · erli18n-v0.6.0"** starts and pauses at the `hex-publish` environment. Approve it (see [Approving the deployment](#approving-the-deployment-the-human-gate)). After approval the workflow validates the tag against `app.src`, builds a dry-run tarball, publishes to Hex (`rebar3 hex publish package --repo hexpm`), publishes the HexDocs, and creates the GitHub Release.

Verify:

```sh
curl -fsSL https://hex.pm/api/packages/erli18n | grep -o '"version":"0.6.0"'
gh release view erli18n-v0.6.0
```

### B. Publish `rebar3_erli18n` (only after `erli18n` is live on Hex)

```sh
grep vsn apps/rebar3_erli18n/src/rebar3_erli18n.app.src   # e.g. {vsn, "0.1.1"}

git tag -a rebar3_erli18n-v0.1.1 -m "Release rebar3_erli18n 0.1.1"
git push origin rebar3_erli18n-v0.1.1
```

The run **"Release · rebar3_erli18n-v0.1.1"** first runs the *erli18n-first* guard — it reads the `{erli18n, "~> X.Y"}` requirement from the plugin's `rebar.config` and checks that a matching `erli18n` release is already on Hex, failing fast otherwise — then pauses at `hex-publish` for approval. After approval it publishes the plugin (with `requirements = {erli18n, "~> X.Y"}`), the HexDocs, and the GitHub Release.

## Approving the deployment (the human gate)

The publish job runs in the `hex-publish` environment, which requires a maintainer to approve it. This is a deliberate checkpoint — do **not** automate it.

1. Find the run: `gh run list --workflow=release.yml` (or open the **Actions** tab).
2. In the run, click **Review deployments** → select **`hex-publish`** → **Approve and deploy**.

Until you approve, nothing is uploaded to Hex. If you decide not to publish, cancel the run instead of approving.

## If something goes wrong

- **Wrong tag, or tagged too early (run still `waiting`):** cancel the run before approving — nothing is published. Then delete the tag locally and on the remote:

  ```sh
  git push origin :erli18n-vX.Y.Z   # delete remote tag
  git tag -d erli18n-vX.Y.Z         # delete local tag
  ```

- **A version was published by mistake:** Hex versions are immutable, but a release can be reverted within 24 hours if nothing depends on it (`rebar3 hex revert erli18n X.Y.Z`, with Hex credentials). After 24 hours, publish a new patch instead.
- **The order guard failed on the plugin:** publish `erli18n` first, confirm it is live on Hex, then re-push the plugin tag.

## See also

- [`WORKFLOW.md`](WORKFLOW.md) — the authoritative contribution and release policy (branching, commit rules, merge strategy, CI-as-gate, and the per-package lib-then-plugin release design).
- [`.github/workflows/release.yml`](../.github/workflows/release.yml) — the data-driven release workflow these steps drive.
