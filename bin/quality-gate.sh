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
#   --full | --pre-push     Everything in --fast plus require_elp, dialyzer,
#                           eqwalizer, ct + cover, and the translation-freshness
#                           check (~5min). Suitable before pushing or releasing.
#                           REQUIRES `elp` to be
#                           installed: if it is missing, --full FAILS (it does
#                           not silently skip the eqwalizer / elp lint steps).
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

# Like run_step, but runs the command with the working directory switched to
# $dir for the duration of the command only. The cwd switch happens inside a
# subshell `( cd "$dir" && "$@" )`, so the gate's own cwd ($PROJECT_DIR) is
# never mutated. Usage:
#   run_step_in <dir> <name> -- <cmd> [args...]
# The literal `--` separates the human name from the command, so a name with
# spaces is unambiguous. Failure is accounted exactly like run_step.
run_step_in() {
    local dir="$1"; shift
    local name="$1"; shift
    # Drop the mandatory `--` separator.
    if [[ "${1:-}" == "--" ]]; then
        shift
    else
        echo "run_step_in: expected '--' before the command" >&2
        exit 2
    fi
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '%s[%d] %s%s\n' "$BOLD$CYAN" "$TOTAL_COUNT" "$name" "$RESET"
    printf '    %s$ (cd %s && %s)%s\n' "$YELLOW" "$dir" "$*" "$RESET"
    local start=$SECONDS
    if ( cd "$dir" && "$@" ); then
        local elapsed=$((SECONDS - start))
        printf '    %s[OK]%s  pass (%ds)\n\n' "$GREEN$BOLD" "$RESET" "$elapsed"
    else
        local elapsed=$((SECONDS - start))
        printf '    %s[FAIL]%s  fail (%ds)\n\n' "$RED$BOLD" "$RESET" "$elapsed"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_STEPS+=("$name")
    fi
}

# The downstream consumer (examples/erli18n_demo) consumes the two unpublished
# in-repo apps through rebar3's native `_checkouts/` override. The links are
# git-ignored recreatable artifacts, so (re)create both idempotently before the
# relocated translation-check step runs from inside the demo. This REPLACES the
# deleted root-level checkout and the deleted host-beam-extraction workaround:
# the demo is now the load context the check runs in.
ensure_demo_checkouts() {
    local demo="$PROJECT_DIR/examples/erli18n_demo"
    local checkouts="$demo/_checkouts"
    mkdir -p "$checkouts"
    # `ln -sfn` is idempotent: it refreshes the symlink target without nesting a
    # link inside an existing directory-link. Targets are relative to the link
    # location so the repo stays relocatable.
    ln -sfn ../../../apps/erli18n        "$checkouts/erli18n"
    ln -sfn ../../../apps/rebar3_erli18n "$checkouts/rebar3_erli18n"
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

ELP_INSTALL_HINT="https://whatsapp.github.io/eqwalizer/getting-started/"

# Hard gate: in --full (and any strict CI path) elp is a REQUIRED toolchain
# component, not an optional nicety. The eqwalizer and elp-lint steps are real
# type/diagnostic gates; letting them silently SKIP when elp is missing turns a
# RED type error into a green build (the "SKIP-passes hole"). This step records
# a real FAIL — counted in TOTAL/FAILED, driving a non-zero gate exit — when
# `find_elp` does not resolve, so a machine without elp cannot pass --full.
# When elp IS present this step passes cheaply and the subsequent run_eqwalizer
# / run_elp_lint steps execute against the now-guaranteed binary.
require_elp() {
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '%s[%d] elp present (required for --full)%s\n' \
        "$BOLD$CYAN" "$TOTAL_COUNT" "$RESET"
    local elp_bin
    if elp_bin=$(find_elp); then
        printf '    %s[OK]%s  found: %s\n\n' "$GREEN$BOLD" "$RESET" "$elp_bin"
    else
        printf '    %s[FAIL]%s  elp is REQUIRED for --full; install per %s\n\n' \
            "$RED$BOLD" "$RESET" "$ELP_INSTALL_HINT"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_STEPS+=("elp present (required for --full)")
    fi
}

run_eqwalizer() {
    # `strict` (1 in --full, 0 in --fast): when set, a missing elp is a FAIL,
    # not a SKIP. In --full the preceding require_elp step has already proven
    # elp present, so this branch should not fire there; the strict-FAIL here is
    # the defense-in-depth that keeps the SKIP-pass hole closed even if this
    # step is ever invoked strictly on its own.
    local strict="${1:-0}"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '%s[%d] eqwalizer (gradual typing)%s\n' "$BOLD$CYAN" "$TOTAL_COUNT" "$RESET"
    local elp_bin
    if ! elp_bin=$(find_elp); then
        if [[ "$strict" == "1" ]]; then
            printf '    %s[FAIL]%s elp REQUIRED but not found — install per %s\n\n' \
                "$RED$BOLD" "$RESET" "$ELP_INSTALL_HINT"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAILED_STEPS+=("eqwalizer (gradual typing)")
            return 0
        fi
        printf '    %s[SKIP]%s elp not found on PATH or in VS Code/Cursor extensions — see %s\n\n' \
            "$YELLOW$BOLD" "$RESET" "$ELP_INSTALL_HINT"
        return 0
    fi
    printf '    %s$ %s eqwalize-all%s\n' "$YELLOW" "$elp_bin" "$RESET"
    local start=$SECONDS
    local out
    # `elp eqwalize-all` returns exit 0 even when it prints type errors, so the
    # exit code alone cannot be trusted (same class of bug worked around in
    # run_elp_lint). Inspect the OUTPUT: fail on an `N ERROR(S)` summary or any
    # `error:` diagnostic line; treat "NO ERRORS" as the only pass.
    out=$("$elp_bin" eqwalize-all 2>&1)
    printf '%s\n' "$out"
    if grep -Eq '^[0-9]+ ERRORS?$|^error:' <<<"$out"; then
        local elapsed=$((SECONDS - start))
        printf '    %s[FAIL]%s  fail (%ds)\n\n' "$RED$BOLD" "$RESET" "$elapsed"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_STEPS+=("eqwalizer (gradual typing)")
    else
        local elapsed=$((SECONDS - start))
        printf '    %s[OK]%s  pass (%ds)\n\n' "$GREEN$BOLD" "$RESET" "$elapsed"
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
    # `strict` (1 in --full, 0 in --fast): a missing elp is a FAIL, not a SKIP.
    local strict="${1:-0}"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '%s[%d] elp lint (IDE-equivalent diagnostics)%s\n' \
        "$BOLD$CYAN" "$TOTAL_COUNT" "$RESET"
    local elp_bin
    if ! elp_bin=$(find_elp); then
        if [[ "$strict" == "1" ]]; then
            printf '    %s[FAIL]%s elp REQUIRED but not found — install per %s\n\n' \
                "$RED$BOLD" "$RESET" "$ELP_INSTALL_HINT"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAILED_STEPS+=("elp lint (IDE-equivalent diagnostics)")
            return 0
        fi
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
        # The non-vacuous translation gate: re-extract the demo consumer's real
        # call sites and FAIL on drift against its committed catalogs. Runs from
        # inside examples/erli18n_demo — the load context where erli18n_po is on
        # the plugin path via the demo's _checkouts/erli18n (proven in S3a).
        ensure_demo_checkouts
        run_step_in examples/erli18n_demo \
            "erli18n catalog freshness (check)" -- rebar3 erli18n check
        ;;
    full)
        run_step "compile (warnings_as_errors)"     rebar3 compile
        run_step "xref (call graph integrity)"      rebar3 xref
        run_step "erlfmt --check (formatting)"      rebar3 fmt --check
        run_step "elvis lint (style)"               rebar3 lint
        run_step "hank (dead code)"                 rebar3 hank
        # --full hard-requires elp: record a real FAIL if it is absent (closing
        # the SKIP-passes hole), then run the two elp-driven gates strictly.
        require_elp
        run_elp_lint 1
        run_step "dialyzer (success typing)"        rebar3 dialyzer
        run_eqwalizer 1
        run_step "common test + coverage"           rebar3 do ct --cover, cover
        # The non-vacuous translation gate (see --fast): re-extract the demo
        # consumer's real call sites and FAIL on drift against its committed
        # catalogs, run from inside examples/erli18n_demo.
        ensure_demo_checkouts
        run_step_in examples/erli18n_demo \
            "erli18n catalog freshness (check)" -- rebar3 erli18n check
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
