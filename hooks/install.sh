#!/usr/bin/env bash
#
# One-time setup: tell git to use this repo's `hooks/` directory.
# Requires Git >= 2.9 (core.hooksPath was added then).
#
# Run from anywhere in the repo:
#     ./hooks/install.sh
#
# Idempotent — safe to re-run after pulling new hook updates.
#
set -euo pipefail

readonly REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Not a git repository. Run 'git init' first." >&2
    exit 1
}

cd "$REPO_ROOT"

chmod +x hooks/pre-commit hooks/pre-push hooks/install.sh bin/quality-gate.sh

git config core.hooksPath hooks

echo "Git hooks installed:"
echo "  pre-commit  -> bin/quality-gate.sh --pre-commit  (fast, ~30s)"
echo "  pre-push    -> bin/quality-gate.sh --pre-push    (full, ~5min)"
echo
echo "Manual run:"
echo "  bin/quality-gate.sh           # full"
echo "  bin/quality-gate.sh --fast    # fast subset"
echo "  bin/quality-gate.sh --fix     # auto-fix formatting"
echo
echo "To bypass a hook (escape hatch, use sparingly):"
echo "  git commit --no-verify"
echo "  git push   --no-verify"
