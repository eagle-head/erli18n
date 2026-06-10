# erli18n — Remaining Work (post-v0.1.0)

Personal action checklist for finishing the distribution work after credits renew. Everything here is **self-contained** — exact commands, file contents to paste, verification steps. Delete this file once the phases are complete.

Cutoff context (2026-05-18): `v0.1.0` is tagged, pushed, and released on GitHub. Repo is public, license Apache-2.0, topics set. The `.github/workflows/ci.yml` exists but cannot run until Actions quota renews on the 1st of next UTC month.

---

## Phases at a glance

| Phase        | Scope                                                             | Needs CI quota?                                       | Wall time        |
| ------------ | ----------------------------------------------------------------- | ----------------------------------------------------- | ---------------- |
| **Phase 10** | Hex.pm publish v0.1.0 + HexDocs                                   | No (manual local)                                     | ~30min           |
| **Phase 11** | VitePress documentation + GitHub Pages (classic mode)             | No (classic Pages = branch-served, not Actions-built) | ~3–4h first pass |
| **Phase 12** | Repo hardening: issue/PR templates, Dependabot, commit convention | No                                                    | ~30min           |
| **Phase 13** | Automated workflows (release.yml, docs.yml)                       | **YES — defer until quota renews**                    | ~1h              |
| **Appendix** | Optional polishing (CODEOWNERS, Discussions, Security advisories) | Mixed                                                 | varies           |

Recommended execution order: 10 → 12 → 11 → 13. (Hex first because it makes the lib actually consumable. Then 12 because it's cheap. Then 11 because it's the biggest. 13 last because it's quota-gated.)

---

## Phase 10 — Hex.pm publish v0.1.0

**Goal**: ship `erli18n` to https://hex.pm/packages/erli18n so anyone can `{erli18n, "0.1.0"}` in their `rebar.config`. Auto-generates HexDocs at https://hexdocs.pm/erli18n.

**Prereqs**: Hex.pm account (free, https://hex.pm/users/new). `rebar3` already installed via mise.

### Steps

```sh
# 1. Add rebar3_hex to project_plugins in rebar.config.
#    (Manual edit — append to the existing list.)
```

Edit `rebar.config`, find the `{project_plugins, [...]}` block, add `{rebar3_hex, "~> 7.0"}`:

```erlang
{project_plugins, [
    {erlfmt, "~> 1.5"},
    {rebar3_hex, "~> 7.0"},
    {rebar3_hank, "~> 1.4"},
    {rebar3_lint, "~> 3.2"}
]}.
```

```sh
# 2. Verify the plugin loads and re-fetch deps.
rebar3 deps

# 3. Register or authenticate with Hex.pm.
#    First-time only:
rebar3 hex user register      # interactive: username, email, password
#    Or if already have an account:
rebar3 hex user auth          # generates and stores API key in ~/.config/rebar3/hex.config

# 4. Dry-run to verify the tarball contents and metadata.
rebar3 hex publish package --dry-run
#    Inspect the output carefully:
#    - Files included: should be src/, include/, LICENSE, README.md, CHANGELOG.md, rebar.config
#    - Files EXCLUDED: test/, _build/, .github/, compose.yml, Dockerfile.act-runner,
#      mise.toml, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md, .editorconfig, TODO.md
#    - Metadata: description, version, licenses=Apache-2.0, links, deps
#    - If anything is wrong, fix in .app.src or rebar.config and re-run.

# 5. Real publish.
rebar3 hex publish package
#    Confirms the package metadata once more, then uploads.
#    Output ends with: https://hex.pm/packages/erli18n/0.1.0

# 6. Publish API documentation (auto-generated from EDoc).
rebar3 hex publish docs
#    Output: https://hexdocs.pm/erli18n/0.1.0
#    (Note: erli18n's modules need -doc attributes for richer docs;
#    EDoc falls back to module-level comments if -doc is absent.)
```

### Verification

```sh
# Confirm the package is live:
curl -s https://hex.pm/api/packages/erli18n | python3 -m json.tool | head -20

# Confirm docs are live:
curl -sI https://hexdocs.pm/erli18n/0.1.0/ | head -3
```

### Expected outcome

- https://hex.pm/packages/erli18n shows v0.1.0 with description, links (GitHub/Changelog/Issues), license, downloads counter.
- https://hexdocs.pm/erli18n/0.1.0 renders the EDoc.
- Consumers add `{erli18n, "0.1.0"}` to `rebar.config` and it just works.

---

## Phase 11 — VitePress documentation site + GitHub Pages (classic mode)

**Goal**: public documentation site at `https://eagle-head.github.io/erli18n/`, built locally and served by GitHub Pages from the `gh-pages` branch. **Does not use GitHub Actions** — the classic Pages mode just serves the branch contents directly.

**Prereqs**: Node.js 18+. Either install globally (`apt install nodejs npm`) or via mise: `mise use -g node@20`.

### Layout to create

```
docs/
├── .vitepress/
│   ├── config.mjs       # site config
│   └── theme/           # (optional) custom CSS/components
├── index.md             # landing page
├── getting-started.md
├── guide/
│   ├── catalogs.md      # loading .po files
│   ├── lookup-api.md    # gettext / ngettext / pgettext / npgettext
│   ├── pluralization.md
│   ├── telemetry.md
│   └── parity.md        # gettext compatibility notes
├── reference/
│   ├── plurals.md       # CLDR locale coverage
│   └── psds.md          # PO Semantics Decisions 001-009
└── public/              # static assets (favicon, og images)
```

### Step 1 — Initialize VitePress

```sh
cd /home/eduardo/Documents/erlang-programming-language/erli18n
mkdir -p docs/.vitepress

# Create a minimal package.json scoped to the docs build only.
cat > docs/package.json <<'EOF'
{
  "name": "erli18n-docs",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vitepress dev .",
    "build": "vitepress build .",
    "preview": "vitepress preview ."
  },
  "devDependencies": {
    "vitepress": "^1.5.0"
  }
}
EOF

cd docs && npm install && cd ..
```

### Step 2 — Configure VitePress

Create `docs/.vitepress/config.mjs`:

```js
import { defineConfig } from "vitepress";

export default defineConfig({
  lang: "en-US",
  title: "erli18n",
  description:
    "Modern internationalization (i18n) library for Erlang/OTP, GNU gettext compatible.",
  base: "/erli18n/", // required for project Pages (not user/org Pages)
  cleanUrls: true,
  lastUpdated: true,

  head: [
    ["link", { rel: "icon", href: "/erli18n/favicon.ico" }],
    ["meta", { name: "theme-color", content: "#a90533" }],
  ],

  themeConfig: {
    logo: "/logo.svg", // drop one in docs/public/logo.svg later
    nav: [
      { text: "Guide", link: "/getting-started" },
      { text: "Reference", link: "/reference/plurals" },
      { text: "API (HexDocs)", link: "https://hexdocs.pm/erli18n/" },
      {
        text: "v0.1.0",
        items: [
          {
            text: "Changelog",
            link: "https://github.com/eagle-head/erli18n/blob/main/CHANGELOG.md",
          },
          {
            text: "Releases",
            link: "https://github.com/eagle-head/erli18n/releases",
          },
        ],
      },
    ],

    sidebar: {
      "/": [
        {
          text: "Introduction",
          items: [
            { text: "What is erli18n", link: "/" },
            { text: "Getting started", link: "/getting-started" },
          ],
        },
        {
          text: "Guide",
          items: [
            { text: "Loading catalogs", link: "/guide/catalogs" },
            { text: "Lookup API", link: "/guide/lookup-api" },
            { text: "Pluralization", link: "/guide/pluralization" },
            { text: "Telemetry", link: "/guide/telemetry" },
            { text: "gettext parity", link: "/guide/parity" },
          ],
        },
        {
          text: "Reference",
          items: [
            { text: "CLDR plural coverage", link: "/reference/plurals" },
            { text: "PO Semantics Decisions", link: "/reference/psds" },
          ],
        },
      ],
    },

    socialLinks: [
      { icon: "github", link: "https://github.com/eagle-head/erli18n" },
    ],

    editLink: {
      pattern: "https://github.com/eagle-head/erli18n/edit/main/docs/:path",
      text: "Edit this page on GitHub",
    },

    footer: {
      message: "Released under the Apache 2.0 License.",
      copyright: "Copyright © 2026 eagle-head",
    },

    search: { provider: "local" },
  },
});
```

### Step 3 — Stub the landing page

Create `docs/index.md`:

```markdown
---
layout: home
hero:
  name: erli18n
  text: GNU gettext for Erlang
  tagline: Modern internationalization library for Erlang/OTP. Drop-in compatible with the standard gettext toolchain (Poedit, Crowdin, Transifex, msgfmt).
  actions:
    - theme: brand
      text: Get Started
      link: /getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/eagle-head/erli18n
features:
  - icon: 📦
    title: GNU gettext compatible
    details: Full .po / .pot format support. Works with every standard translation tool out of the box.
  - icon: 🔢
    title: CLDR-backed pluralization
    details: 49 locales inlined. PO header is runtime source of truth; CLDR validates at load.
  - icon: 📡
    title: First-class telemetry
    details: Seven :telemetry events. Optional dep — no overhead if you do not ship it.
  - icon: 🧪
    title: 238 tests, 100% behavioral coverage
    details: Common Test + PropEr + fuzz + parity oracle against gettexter + msgfmt.
  - icon: ⚡
    title: Anti-bottleneck hot path
    details: Lookups read lock-free from the caller process. Writes serialized through the gen_server.
  - icon: 🆓
    title: Apache 2.0
    details: Permissive license. Use in commercial, closed-source, or open-source projects.
---
```

Stub `docs/getting-started.md`:

```markdown
# Getting started

## Install

Add to your `rebar.config`:

\`\`\`erlang
{deps, [
{erli18n, "0.1.0"}
]}.
\`\`\`

## Your first translation

(... fill in with actual usage examples; mirror the README quick example and expand.)
```

(Create the other guide/reference stubs similarly. Goal is to publish a usable site even if each page is short — iterate from there.)

### Step 4 — Local development

```sh
cd docs
npm run dev
# Opens http://localhost:5173 with hot reload.
```

### Step 5 — Build and deploy to gh-pages branch (no Actions)

```sh
cd docs
npm run build       # outputs to docs/.vitepress/dist/
cd ..

# Create the gh-pages branch if it doesn't exist.
git worktree add /tmp/erli18n-gh-pages -b gh-pages

# Copy the built site over.
rm -rf /tmp/erli18n-gh-pages/*
cp -r docs/.vitepress/dist/* /tmp/erli18n-gh-pages/

# (Optional) Add a CNAME if you want a custom domain.
# echo "docs.erli18n.dev" > /tmp/erli18n-gh-pages/CNAME

# Disable Jekyll processing (we are using VitePress output as-is).
touch /tmp/erli18n-gh-pages/.nojekyll

cd /tmp/erli18n-gh-pages
git add -A
git commit -m "Deploy docs $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git push origin gh-pages
cd -
git worktree remove /tmp/erli18n-gh-pages
```

### Step 6 — Enable GitHub Pages (classic, no Actions)

```sh
# Set Pages source to the gh-pages branch root.
gh api -X POST repos/eagle-head/erli18n/pages -f source[branch]=gh-pages -f source[path]=/

# Set the repo homepage URL so the "About" sidebar links to the docs.
gh repo edit eagle-head/erli18n --homepage https://eagle-head.github.io/erli18n/
```

### Step 7 — Add badges and links to README

In `README.md`, add a docs badge near the top (after the existing CI badge):

```markdown
[![Docs](https://img.shields.io/badge/docs-eagle--head.github.io%2Ferli18n-blue?logo=vitepress)](https://eagle-head.github.io/erli18n/)
```

And in the **Documentation** section, replace the planned-text with the real URL.

### Update / re-deploy cycle

```sh
cd docs && npm run build && cd ..
git worktree add /tmp/erli18n-gh-pages gh-pages
rm -rf /tmp/erli18n-gh-pages/*
cp -r docs/.vitepress/dist/* /tmp/erli18n-gh-pages/
touch /tmp/erli18n-gh-pages/.nojekyll
cd /tmp/erli18n-gh-pages && git add -A && git commit -m "Update docs" && git push && cd -
git worktree remove /tmp/erli18n-gh-pages
```

(Once CI quota is back, this becomes a `.github/workflows/docs.yml` — see Phase 13.)

### Add `.gitignore` entries

Append to `.gitignore`:

```
# VitePress docs build artifacts
docs/node_modules/
docs/.vitepress/dist/
docs/.vitepress/cache/
```

---

## Phase 12 — Repo hardening files

**Goal**: bring the repo up to the same hygiene level as `eagle-head/timekeeper-countdown`. All static files — no CI runs, no quota.

### File 1: `.github/ISSUE_TEMPLATE/bug_report.yml`

```yaml
name: Bug report
description: Report a bug in erli18n
title: "[bug] "
labels: ["bug", "needs-triage"]
body:
  - type: markdown
    attributes:
      value: |
        Thanks for taking the time to file a report. A minimal reproducer makes the
        triage much faster — ideally a Common Test case or a `.po` fixture that
        exhibits the issue.

  - type: input
    id: otp_version
    attributes:
      label: OTP version
      description: |
        Output of:
        `erl -eval 'io:format("~s", [erlang:system_info(otp_release)])' -s init stop -noshell`
      placeholder: "28"
    validations:
      required: true

  - type: input
    id: erli18n_version
    attributes:
      label: erli18n version
      placeholder: "0.1.0"
    validations:
      required: true

  - type: input
    id: rebar3_version
    attributes:
      label: rebar3 version
      description: Output of `rebar3 --version`
      placeholder: "rebar 3.24.0 on Erlang/OTP 28"

  - type: textarea
    id: reproduction
    attributes:
      label: Steps to reproduce
      description: Minimal reproducer. Ideally a CT case, an Erlang shell session, or a `.po` fixture.
      render: erlang
    validations:
      required: true

  - type: textarea
    id: expected
    attributes:
      label: Expected behavior
    validations:
      required: true

  - type: textarea
    id: actual
    attributes:
      label: Actual behavior
      description: Include stack traces, error tuples, or any relevant output verbatim.
    validations:
      required: true

  - type: textarea
    id: context
    attributes:
      label: Additional context
      description: Anything else — OS, dependencies, related issues, hypotheses.
```

### File 2: `.github/ISSUE_TEMPLATE/feature_request.yml`

```yaml
name: Feature request
description: Suggest a feature or enhancement for erli18n
title: "[feat] "
labels: ["enhancement", "needs-triage"]
body:
  - type: textarea
    id: problem
    attributes:
      label: Problem
      description: What problem does this feature solve? Concrete use case is more compelling than abstract motivation.
    validations:
      required: true

  - type: textarea
    id: proposed_solution
    attributes:
      label: Proposed solution
      description: API sketch or behavior description. Code examples preferred.
      render: erlang
    validations:
      required: true

  - type: textarea
    id: alternatives
    attributes:
      label: Alternatives considered
      description: Other approaches you ruled out and why.

  - type: checkboxes
    id: api_impact
    attributes:
      label: Compatibility scope
      description: Per the 0.x SemVer policy in CHANGELOG.md.
      options:
        - label: This changes public API (triggers minor bump in 0.x, e.g. 0.1.x → 0.2.0)
        - label: This adds a new :telemetry event
        - label: This changes an existing :telemetry event schema (only allowed for @unstable events)
        - label: This changes an application env key
```

### File 3: `.github/ISSUE_TEMPLATE/config.yml`

```yaml
blank_issues_enabled: false
contact_links:
  - name: Security vulnerability
    url: https://github.com/eagle-head/erli18n/security/advisories/new
    about: Report a security vulnerability privately. Do not open a public issue.
  - name: Question or discussion
    url: https://github.com/eagle-head/erli18n/discussions
    about: For usage questions, ideas, or general discussion (enable Discussions in repo settings first).
```

### File 4: `.github/PULL_REQUEST_TEMPLATE.md`

```markdown
## Summary

<!-- 1-3 sentences. What does this PR change and why? -->

Fixes # <!-- issue number, if applicable -->

## Type of change

<!-- Check the one that applies. -->

- [ ] Bug fix (non-breaking)
- [ ] New feature (non-breaking; triggers minor bump in 0.x)
- [ ] Breaking change (triggers minor bump in 0.x, or major after 1.0)
- [ ] Documentation only
- [ ] Refactor (no behavior change)
- [ ] Chore (deps, tooling, CI)

## Test plan

<!-- How is the change verified? -->

- [ ] `bin/quality-gate.sh --full` passes locally
- [ ] New tests cover the change — regression test for bug fixes, behavior coverage for features
- [ ] CHANGELOG.md updated under `[Unreleased]`

## Public API / observability impact

<!-- Skip if no public surface changes. -->

- [ ] No exported functions added, removed, or signature-changed
- [ ] No `:telemetry` event schemas changed (or only `@unstable` events touched)
- [ ] No application env keys added or changed
- [ ] No `rebar.config` dep changes that consumers would notice

## Commit message

<!-- This PR follows the convention in .github/commit-convention.md. -->
```

### File 5: `.github/commit-convention.md`

```markdown
# Commit convention

This project follows [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/).

## Format

\`\`\`
<type>(<scope>): <subject>

<body>

<footer>
\`\`\`

Only `<type>` and `<subject>` are required. Scope, body, and footer are optional.

## Types

| Type       | Description                                         |
| ---------- | --------------------------------------------------- |
| `feat`     | New feature (public API surface)                    |
| `fix`      | Bug fix                                             |
| `docs`     | Documentation only (README, CHANGELOG, EDoc, docs/) |
| `style`    | Code style / formatting (no logic change)           |
| `refactor` | Refactor (no feature, no fix)                       |
| `perf`     | Performance improvement                             |
| `test`     | Adding or updating tests                            |
| `chore`    | Maintenance — deps, tooling, build, config          |
| `ci`       | CI/CD configuration                                 |
| `build`    | Build system or rebar configuration                 |

## Scopes (optional)

Use a scope when the change is localized to one subsystem:

| Scope       | When to use                                  |
| ----------- | -------------------------------------------- |
| `po`        | Changes to `erli18n_po` (PO file parser)     |
| `plural`    | Changes to `erli18n_plural` (CLDR evaluator) |
| `server`    | Changes to `erli18n_server`                  |
| `facade`    | Changes to the `erli18n` public API          |
| `telemetry` | Changes to `erli18n_telemetry` or its events |
| `parity`    | Changes to `erli18n_parity_SUITE` or oracle  |
| `deps`      | Dependency updates                           |
| `docs`      | Documentation site changes                   |

Omit the scope when the change spans multiple subsystems or is project-wide.

## Rules

- Use **imperative mood**: "add feature" not "added feature".
- **Do not capitalize** the first letter of the subject.
- **No period** at the end of the subject.
- Subject line: **max 50 characters**.
- Body: wrap at **72 characters** per line.
- Separate subject from body with a **blank line**.

## Breaking changes

Indicate breaking changes with `!` before the colon:

\`\`\`
feat(facade)!: drop deprecated d_gettext/3 alias
\`\`\`

Or in the footer:

\`\`\`
feat(po): support charset header round-trip

BREAKING CHANGE: erli18n_po:parse/2 now requires #{charset_strategy => ...}
in the options map. Calls without it return {error, missing_option}.
\`\`\`

## Examples

\`\`\`
feat(plural): support nplurals > 6 for legacy Slavic catalogs

fix(po): treat trailing backslash in msgstr as line continuation

refactor(server): extract catalog validation into private helper

docs: add HexDocs link to README badges

chore(deps): bump telemetry to 1.4

test(facade): regression for ngettext fallback on missing plural form
\`\`\`
```

### File 6: `.github/dependabot.yml`

```yaml
# Dependabot configuration.
# https://docs.github.com/en/code-security/dependabot/dependabot-version-updates/configuration-options-for-the-dependabot.yml-file
#
# Note: Dependabot does NOT natively support rebar3/Hex deps for Erlang projects.
# Hex packages are bumped manually via `rebar3 update` + a CHANGELOG entry.
# What Dependabot CAN bump here:
#   * GitHub Actions versions (used in .github/workflows/)
#   * Docker base images (used in Dockerfile.act-runner)
#
# Dependabot runs as a separate GitHub service. It consumes its own quota
# (not Actions minutes) for PR creation. The PRs themselves trigger CI on
# push, which DOES consume Actions minutes — disable that auto-trigger if
# quota is constrained.

version: 2
updates:
  - package-ecosystem: github-actions
    directory: "/"
    schedule:
      interval: weekly
      day: monday
      time: "06:00"
      timezone: "America/Sao_Paulo"
    open-pull-requests-limit: 5
    labels:
      - dependencies
      - github-actions

  - package-ecosystem: docker
    directory: "/" # picks up Dockerfile.act-runner at repo root
    schedule:
      interval: weekly
      day: monday
      time: "06:00"
      timezone: "America/Sao_Paulo"
    open-pull-requests-limit: 3
    labels:
      - dependencies
      - docker

  # Phase 11 docs/ — uncomment once VitePress is set up:
  # - package-ecosystem: npm
  #   directory: "/docs"
  #   schedule:
  #     interval: weekly
  #   labels:
  #     - dependencies
  #     - docs
```

### File 7: `.github/CODEOWNERS` (optional)

```
# Code owners for erli18n.
# https://docs.github.com/en/repositories/managing-your-repositories-settings-and-customizations/customizing-your-repository/about-code-owners
#
# These users/teams are automatically requested for review on PRs that
# modify the listed paths. Since erli18n is a single-maintainer project
# right now, this just makes the auto-assignment explicit.

* @eagle-head

# Public API surface — extra scrutiny.
/src/erli18n.erl              @eagle-head
/src/erli18n_telemetry.erl    @eagle-head
/include/                     @eagle-head

# Architectural decisions — never edit without coordination.
/CHANGELOG.md                 @eagle-head
/SECURITY.md                  @eagle-head
```

### File 8: Append to `.gitignore`

```
# Dependabot updates
# (Dependabot manages branches itself; nothing to ignore locally.)

# VitePress docs build artifacts (only if Phase 11 is done)
docs/node_modules/
docs/.vitepress/dist/
docs/.vitepress/cache/
```

### Phase 12 execution

```sh
mkdir -p .github/ISSUE_TEMPLATE

# Paste each file's content above into the path indicated by its heading.
# Then:

git add .github CODEOWNERS.* dependabot* 2>/dev/null || true
git add .github/
git status
git commit -m "chore: add issue/PR templates, commit convention, dependabot config"
git push
```

---

## Phase 13 — Automated workflows (NEEDS CI quota)

**Defer until Actions minutes are available.** These are workflow files that **trigger** on push/tag and burn quota. Authoring is fine (just YAML); execution is what's gated.

### File: `.github/workflows/release.yml`

Tag-triggered Hex.pm publish. Runs `rebar3 hex publish` and `rebar3 hex publish docs` on every `v*` tag pushed to the repo.

```yaml
name: Release

on:
  push:
    tags: ["v*"]
  workflow_dispatch:
    inputs:
      tag:
        description: "Tag to publish (e.g., v0.2.0)"
        required: true

concurrency:
  group: release-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  publish:
    name: Publish to Hex.pm
    runs-on: ubuntu-24.04
    environment: hex-publish # requires HEX_API_KEY secret defined in this environment
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.inputs.tag || github.ref }}

      - name: Set up Erlang/OTP
        uses: erlef/setup-beam@v1
        with:
          otp-version: "28"
          rebar3-version: "3.24"

      - name: Verify tag matches .app.src vsn
        run: |
          TAG_REF="${GITHUB_REF##*/}"
          TAG_VSN="${TAG_REF#v}"
          APP_VSN=$(awk -F'"' '/{vsn,/ {print $2}' src/erli18n.app.src)
          if [ "$TAG_VSN" != "$APP_VSN" ]; then
            echo "::error::Tag ${TAG_REF} does not match .app.src vsn ${APP_VSN}"
            exit 1
          fi

      - name: Publish package
        env:
          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}
        run: rebar3 hex publish package --yes

      - name: Publish docs
        env:
          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}
        run: rebar3 hex publish docs --yes
```

### File: `.github/workflows/docs.yml`

VitePress build + auto-deploy to `gh-pages` branch (replaces the manual deploy from Phase 11).

```yaml
name: Docs

on:
  push:
    branches: [main]
    paths:
      - "docs/**"
      - ".github/workflows/docs.yml"
  workflow_dispatch:

concurrency:
  group: docs-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: write # needs write to push gh-pages branch

jobs:
  build-and-deploy:
    name: Build VitePress and deploy to gh-pages
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
          cache-dependency-path: docs/package-lock.json

      - name: Install dependencies
        run: npm ci
        working-directory: docs

      - name: Build site
        run: npm run build
        working-directory: docs

      - name: Disable Jekyll
        run: touch docs/.vitepress/dist/.nojekyll

      - name: Deploy to gh-pages
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs/.vitepress/dist
          publish_branch: gh-pages
          force_orphan: true
```

### Required GitHub secrets / environments

For `release.yml`:

```sh
# 1. Create a Hex.pm API key with write scope:
rebar3 hex user key generate --key-name "github-actions-erli18n" --permission api:write

# 2. Define an environment "hex-publish" with the secret HEX_API_KEY:
gh api -X PUT repos/eagle-head/erli18n/environments/hex-publish
gh secret set HEX_API_KEY --env hex-publish --body "<paste the key from step 1>"

# 3. (Optional) Require manual approval to deploy:
# gh api -X PUT repos/eagle-head/erli18n/environments/hex-publish \
#   --input <(echo '{"reviewers":[{"type":"User","id":<your-user-id>}]}')
```

For `docs.yml`: no extra secrets — uses the default `GITHUB_TOKEN`.

---

## Appendix — optional polishing

### A1. Enable GitHub Discussions

```sh
gh repo edit eagle-head/erli18n --enable-discussions
```

Then update `.github/ISSUE_TEMPLATE/config.yml` to link there for questions.

### A2. Enable private vulnerability reporting

```sh
gh api -X PATCH repos/eagle-head/erli18n \
  -f security_and_analysis[secret_scanning][status]=enabled \
  -f security_and_analysis[secret_scanning_push_protection][status]=enabled
```

(Vulnerability reporting itself is enabled via the repo UI: Settings → Security → Enable "Privately report a vulnerability".)

### A3. Pin the repo on your GitHub profile

```sh
# No public API for pinning; do it via the profile UI:
#   github.com/eagle-head → "Customize your pins" → check erli18n.
```

### A4. Funding / sponsorship

If you want sponsorship:

```sh
mkdir -p .github
cat > .github/FUNDING.yml <<'EOF'
github: [eagle-head]
# Or other platforms — ko_fi, buy-me-a-coffee, etc.
EOF
```

### A5. README badges — final set

Once Phases 10 and 11 are done, the full badge stack at the top of README.md should be:

```markdown
[![Status: experimental](https://img.shields.io/badge/Status-experimental-orange.svg)](#status)
[![Hex.pm](https://img.shields.io/hexpm/v/erli18n.svg)](https://hex.pm/packages/erli18n)
[![HexDocs](https://img.shields.io/badge/hex-docs-blueviolet.svg)](https://hexdocs.pm/erli18n/)
[![Docs](https://img.shields.io/badge/docs-eagle--head.github.io%2Ferli18n-blue?logo=vitepress)](https://eagle-head.github.io/erli18n/)
[![CI](https://github.com/eagle-head/erli18n/actions/workflows/ci.yml/badge.svg)](https://github.com/eagle-head/erli18n/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![OTP](https://img.shields.io/badge/OTP-25.3%2B-a90533)](https://www.erlang.org/downloads)
[![SemVer](https://img.shields.io/badge/SemVer-2.0.0-brightgreen)](https://semver.org/spec/v2.0.0.html)
```

### A6. Switch CI workflow auto-trigger off until quota renews (optional)

If the failed CI runs in the Actions tab are noisy, swap `on: push/pull_request` for `on: workflow_dispatch` only in `.github/workflows/ci.yml`. The `act`-based local validation continues to work either way. Revert when quota is back.

---

## Verification checklist (end-state)

After all phases complete:

- [ ] `https://hex.pm/packages/erli18n/0.1.0` shows v0.1.0
- [ ] `https://hexdocs.pm/erli18n/0.1.0/` renders the EDoc
- [ ] `https://eagle-head.github.io/erli18n/` shows the VitePress site
- [ ] `https://github.com/eagle-head/erli18n` shows the latest README with all badges, homepage URL set, Issues tab uses the templates, Pull Request template renders on new PRs
- [ ] `.github/workflows/ci.yml` runs green on push (Phase 13 unblocked)
- [ ] `.github/workflows/release.yml` triggers Hex publish on `v*` tag push (Phase 13)
- [ ] `.github/workflows/docs.yml` auto-deploys docs site on `docs/**` change (Phase 13)
- [ ] Dependabot opens its first PR (typically within 24h of merging `.github/dependabot.yml`)

Delete this `TODO.md` when the checklist is complete.
