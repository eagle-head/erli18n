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
#
# This is NOT part of the library (scripts/ is excluded from the Hex package
# `files` whitelist). Offline; no network, no install.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

# Which package to document. The umbrella publishes `erli18n` (runtime lib) and
# `rebar3_erli18n` (plugin) as separate Hex packages, each fully self-contained
# under apps/<app>/ with its own README/CHANGELOG/LICENSE and {ex_doc,...} block.
# Default to the runtime lib; override with the first argument, e.g.
#   scripts/gen_docs.sh rebar3_erli18n
APP="${1:-erli18n}"
APP_DIR="apps/${APP}"
APP_SRC="${APP_DIR}/src/${APP}.app.src"
[ -f "$APP_SRC" ] || { echo "error: no app.src for '${APP}' at ${APP_SRC}" >&2; exit 1; }
VSN=$(sed -n 's/.*{[[:space:]]*vsn[[:space:]]*,[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_SRC" | head -1)
# Write the rendered site INSIDE the package's own app dir (apps/<app>/doc), so
# the per-app publish step finds it as a relative `doc/` after `cd apps/<app>`
# (`rebar3 hex publish docs --doc-dir doc`). Each `apps/<app>/doc/` is gitignored
# via the `doc/` rule and is a regenerated artifact.
OUT="${APP_DIR}/doc"

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

# ex_doc config — generated from the {ex_doc,...} block in the PACKAGE's own
# rebar.config (apps/<app>/rebar.config is the single source of truth, owned by
# the published package) via scripts/ex_doc_config.escript. The {extras} entries
# are bare, app-relative filenames (README.md/CHANGELOG.md/LICENSE) so the same
# list also satisfies the Hex tarball globbing; we run ex_doc from the repo root,
# so we pass APP_DIR as the extras-base to resolve them to the app's own copies.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CFG="${TMP}/docs.config"   # ex_doc requires a .config/.exs extension
escript scripts/ex_doc_config.escript "${APP_DIR}/rebar.config" "$CFG" "$APP_DIR"

echo "==> running ex_doc (${EXDOC[*]})"
"${EXDOC[@]}" "$APP" "$VSN" "$EBIN" \
    --output "$OUT" \
    --source-ref "$VSN" \
    --config "$CFG"

echo "==> done -> ${OUT}/index.html"
