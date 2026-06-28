#!/usr/bin/env bash
#
# One-time setup: point git at this repo's .githooks/ directory.
#
# Requires Git >= 2.9 (core.hooksPath was added then). Idempotent — safe to
# re-run after pulling new hook updates.
#
# Run from anywhere in the repo:
#     bin/install-git-hooks.sh
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Not a git repository. Run 'git init' first." >&2
    exit 1
}

cd "$REPO_ROOT"

# Make the hooks and gate runnable regardless of how they were checked out.
chmod +x \
    .githooks/pre-commit \
    .githooks/pre-push \
    bin/install-git-hooks.sh \
    bin/quality-gate.sh

# core.hooksPath replaces .git/hooks wholesale; assigning it is idempotent.
git config core.hooksPath .githooks

echo "Git hooks installed (core.hooksPath -> .githooks):"
echo "  pre-commit  -> bin/quality-gate.sh --fast        (fast subset, no docker)"
echo "  pre-push    -> docker-compose full gate          (gettext-extract, then OTP 27/28/29)"
echo
echo "Manual run:"
echo "  bin/quality-gate.sh           # full gate"
echo "  bin/quality-gate.sh --fast    # fast subset"
echo "  bin/quality-gate.sh --fix     # auto-fix formatting"
echo
echo "To bypass a hook once (escape hatch, use sparingly):"
echo "  git commit --no-verify"
echo "  git push   --no-verify"
