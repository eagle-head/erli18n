#!/usr/bin/env bash
#
# Generate the erli18n HTML documentation from the native EEP-48 `Docs` chunks
# that the compiler writes into the BEAM files (from the `-doc`/`-moduledoc`
# attributes), by invoking the `ex_doc` escript directly on the compiled
# `ebin/` directory.
#
# Why this exists instead of `rebar3 ex_doc`:
#   `rebar3 ex_doc` first runs EDoc (the legacy `@doc` tool) to generate doc
#   chunks. EDoc parses every `%%` comment through its wiki markup and throws on
#   a Markdown-style backtick (`` `code` ``), aborting the whole command. That
#   EDoc step is vestigial — `ex_doc` reads the docs from the BEAM, not from
#   EDoc's chunks. This script does exactly what the plugin does *after* the
#   EDoc step, minus the crashing precondition.
#   Full write-up: notes/edoc-exdoc-native-doc-bug.md
#
# This is NOT part of the library (scripts/ is excluded from the Hex package
# `files` whitelist). Offline; no network, no install.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

APP_SRC=$(ls src/*.app.src | head -1)
APP=$(basename "$APP_SRC" .app.src)
VSN=$(sed -n 's/.*{[[:space:]]*vsn[[:space:]]*,[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_SRC" | head -1)
OUT="doc"

echo "==> compiling ${APP} ${VSN} (native Docs chunks land in the BEAM)"
rebar3 compile

EBIN="_build/default/lib/${APP}/ebin"
[ -d "$EBIN" ] || { echo "error: ebin dir not found: $EBIN" >&2; exit 1; }

# Prefer a standalone `ex_doc` on PATH; otherwise use the escript bundled in the
# rebar3_ex_doc plugin (matching the running OTP release, falling back down).
if command -v ex_doc >/dev/null 2>&1; then
    EXDOC=(ex_doc)
else
    OTP=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().')
    PRIV="_build/default/plugins/rebar3_ex_doc/priv"
    ESCRIPT=""
    for sub in 0 1 2 3; do
        cand="${PRIV}/ex_doc_otp_$((OTP - sub))"
        [ -f "$cand" ] && { ESCRIPT="$cand"; break; }
    done
    [ -n "$ESCRIPT" ] || { echo "error: no bundled ex_doc escript under $PRIV (run 'rebar3 compile' once to fetch the plugin)" >&2; exit 1; }
    EXDOC=("$ESCRIPT")
fi

# ex_doc config — generated from the {ex_doc,...} block in rebar.config (single
# source of truth) by scripts/ex_doc_config.escript.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CFG="${TMP}/docs.config"   # ex_doc requires a .config/.exs extension
escript scripts/ex_doc_config.escript rebar.config "$CFG"

echo "==> running ex_doc (${EXDOC[*]})"
"${EXDOC[@]}" "$APP" "$VSN" "$EBIN" \
    --output "$OUT" \
    --source-ref "$VSN" \
    --config "$CFG"

echo "==> done -> ${OUT}/index.html"
