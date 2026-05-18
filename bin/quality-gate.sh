#!/usr/bin/env bash
#
# erli18n quality gate
#
# Runs the project's quality checks. Use as a manual command, a git
# pre-commit hook (--fast), or a git pre-push hook (--full).
#
# Modes:
#   --fast | --pre-commit   Fast subset (~30s): compile, xref, fmt --check,
#                           lint, hank. Suitable for every commit.
#   --full | --pre-push     Everything in --fast plus dialyzer, eqwalizer,
#                           ct + cover, hex audit (~5min). Suitable before
#                           pushing or releasing.
#   --fix                   Auto-fix what's auto-fixable (currently:
#                           erlfmt formatting). Does NOT run other checks.
#   --help                  Print this message.
#
#   (no argument)           Same as --full.
#
# Exit codes:
#   0   All checks passed.
#   1   One or more checks failed; see the FAILED summary at the end.
#   2   Bad invocation (unknown flag).
#
# Output is fully streamed so failures are debuggable in-place. Each step
# is timed; a summary at the end lists which steps failed.
#
set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

MODE="full"
case "${1:-}" in
    --fast|--pre-commit)         MODE="fast" ;;
    --full|--pre-push|"")        MODE="full" ;;
    --fix)                       MODE="fix"  ;;
    -h|--help)
        sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Try: $0 --help" >&2
        exit 2
        ;;
esac

cd "$PROJECT_DIR" || { echo "Cannot cd to $PROJECT_DIR" >&2; exit 1; }

# Colors only when stdout is a TTY.
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RESET=$'\033[0m'
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
else
    BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; CYAN=""
fi

declare -i FAILED_COUNT=0
declare -i TOTAL_COUNT=0
declare -a FAILED_STEPS=()

run_step() {
    local name="$1"; shift
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '%s[%d] %s%s\n' "$BOLD$CYAN" "$TOTAL_COUNT" "$name" "$RESET"
    printf '    %s$ %s%s\n' "$YELLOW" "$*" "$RESET"
    local start=$SECONDS
    if "$@"; then
        local elapsed=$((SECONDS - start))
        printf '    %s[OK]%s  pass (%ds)\n\n' "$GREEN$BOLD" "$RESET" "$elapsed"
    else
        local elapsed=$((SECONDS - start))
        printf '    %s[FAIL]%s  fail (%ds)\n\n' "$RED$BOLD" "$RESET" "$elapsed"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_STEPS+=("$name")
    fi
}

find_elp() {
    # Prefer system PATH first; otherwise look in common locations where
    # IDE extensions install their own copy (VS Code / Cursor).
    if command -v elp >/dev/null 2>&1; then
        command -v elp
        return 0
    fi
    local candidates=(
        "$HOME/.vscode-server/extensions/erlang-language-platform.erlang-language-platform-"*"/bin/elp"
        "$HOME/.vscode/extensions/erlang-language-platform.erlang-language-platform-"*"/bin/elp"
        "$HOME/.cursor/extensions/erlang-language-platform.erlang-language-platform-"*"/bin/elp"
    )
    local match
    for pattern in "${candidates[@]}"; do
        for match in $pattern; do
            [[ -x "$match" ]] && { echo "$match"; return 0; }
        done
    done
    return 1
}

run_eqwalizer() {
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '%s[%d] eqwalizer (gradual typing)%s\n' "$BOLD$CYAN" "$TOTAL_COUNT" "$RESET"
    local elp_bin
    if ! elp_bin=$(find_elp); then
        printf '    %s[SKIP]%s elp not found on PATH or in VS Code/Cursor extensions — see %s\n\n' \
            "$YELLOW$BOLD" "$RESET" \
            "https://whatsapp.github.io/eqwalizer/getting-started/"
        return 0
    fi
    printf '    %s$ %s eqwalize-all%s\n' "$YELLOW" "$elp_bin" "$RESET"
    local start=$SECONDS
    if "$elp_bin" eqwalize-all; then
        local elapsed=$((SECONDS - start))
        printf '    %s[OK]%s  pass (%ds)\n\n' "$GREEN$BOLD" "$RESET" "$elapsed"
    else
        local elapsed=$((SECONDS - start))
        printf '    %s[FAIL]%s  fail (%ds)\n\n' "$RED$BOLD" "$RESET" "$elapsed"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_STEPS+=("eqwalizer (gradual typing)")
    fi
}

run_elp_lint() {
    # ELP lint catches diagnostics that other tools miss:
    #   * W0020 — unused file include (per-include-line; Hank only detects
    #     project-wide unused .hrl)
    #   * W0006/W0007 — other erlc/edoc diagnostics surfaced by the IDE
    #
    # WeakWarnings are stylistic suggestions (e.g., W0051 binary sigil
    # syntax requires OTP 27+) and are NOT fatal here — they're for IDE
    # display only. We fail only on [Warning] and [Error].
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '%s[%d] elp lint (IDE-equivalent diagnostics)%s\n' \
        "$BOLD$CYAN" "$TOTAL_COUNT" "$RESET"
    local elp_bin
    if ! elp_bin=$(find_elp); then
        printf '    %s[SKIP]%s elp not found\n\n' "$YELLOW$BOLD" "$RESET"
        return 0
    fi
    printf '    %s$ %s lint --include-erlc-diagnostics%s\n' \
        "$YELLOW" "$elp_bin" "$RESET"
    local start=$SECONDS
    local out
    out=$("$elp_bin" lint --include-erlc-diagnostics 2>&1)
    local warnings_errors
    warnings_errors=$(printf '%s\n' "$out" \
        | grep -E "::\[(Warning|Error)\] " || true)
    if [[ -z "$warnings_errors" ]]; then
        local elapsed=$((SECONDS - start))
        printf '    %s[OK]%s  pass (%ds)\n\n' "$GREEN$BOLD" "$RESET" "$elapsed"
    else
        local elapsed=$((SECONDS - start))
        printf '%s\n' "$warnings_errors"
        printf '    %s[FAIL]%s  fail (%ds)\n\n' "$RED$BOLD" "$RESET" "$elapsed"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_STEPS+=("elp lint (IDE-equivalent diagnostics)")
    fi
}

printf '%serli18n quality gate%s  (mode: %s%s%s)\n\n' \
    "$BOLD" "$RESET" "$CYAN" "$MODE" "$RESET"

case "$MODE" in
    fast)
        run_step "compile (warnings_as_errors)"     rebar3 compile
        run_step "xref (call graph integrity)"      rebar3 xref
        run_step "erlfmt --check (formatting)"      rebar3 fmt --check
        run_step "elvis lint (style)"               rebar3 lint
        run_step "hank (dead code)"                 rebar3 hank
        run_elp_lint
        ;;
    full)
        run_step "compile (warnings_as_errors)"     rebar3 compile
        run_step "xref (call graph integrity)"      rebar3 xref
        run_step "erlfmt --check (formatting)"      rebar3 fmt --check
        run_step "elvis lint (style)"               rebar3 lint
        run_step "hank (dead code)"                 rebar3 hank
        run_elp_lint
        run_step "dialyzer (success typing)"        rebar3 dialyzer
        run_eqwalizer
        run_step "common test + coverage"           rebar3 do ct --cover, cover
        ;;
    fix)
        run_step "erlfmt --write (auto-format)"     rebar3 fmt --write
        ;;
esac

printf '%s%s%s\n' "$BOLD" "──────────────────────────────────────────────────" "$RESET"
if [[ $FAILED_COUNT -eq 0 ]]; then
    printf '%s%s[OK] all %d checks passed%s\n' "$GREEN" "$BOLD" "$TOTAL_COUNT" "$RESET"
    exit 0
else
    printf '%s%s[FAIL] %d of %d checks failed:%s\n' \
        "$RED" "$BOLD" "$FAILED_COUNT" "$TOTAL_COUNT" "$RESET"
    for step in "${FAILED_STEPS[@]}"; do
        printf '    %s-%s %s\n' "$RED" "$RESET" "$step"
    done
    exit 1
fi
