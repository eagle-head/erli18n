#!/bin/sh
# =====================================================================
# extract-gettext-table.sh — build the gettext-derived gate artifacts.
#
# Drives the REAL GNU gettext command-line tools (`msgfmt`, `gettext`,
# `ngettext`, `msginit`) and writes two artifacts into the output
# directory given as $1:
#
#   <dir>/parity_oracle.eterm
#       The expected GNU gettext output for every scenario in
#       apps/erli18n/test/parity_matrix.eterm, keyed by scenario id:
#           {<<"scenario_id">>, <<Byte, Byte, ...>>}.
#       The bytes are the EXACT stdout of the gettext CLI (one trailing
#       newline stripped), stored as a raw byte binary so any encoding
#       round-trips losslessly. `erli18n_parity_SUITE` consults this file
#       and compares it against erli18n's output byte-for-byte.
#
#   <dir>/plural_forms.extracted.eterm
#       A sorted list of {<<Locale>>, NPlurals, <<PluralExpr>>} rows for
#       every UTF-8 locale `gettext` knows on this host, derived from the
#       `Plural-Forms:` header that `msginit` fills in from its built-in
#       table. Same shape as the committed seed
#       apps/erli18n/priv/gettext/plural_forms.eterm, so the two can be
#       diffed locale-by-locale to detect drift on a gettext/CLDR release.
#
# The detected gettext version is printed to stdout for diagnosability.
#
# Locale requirements (parity oracle): the GNU gettext CLI only applies a
# catalog when the LC_MESSAGES locale is a real, non-C locale. This script
# therefore activates gettext with ONE generated UTF-8 base locale
# (ERLI18N_PARITY_BASE_LOCALE, default en_US.UTF-8) and selects each
# scenario's catalog with the `LANGUAGE` override, which does NOT require
# the scenario's own locale to be installed. The base locale's charset is
# UTF-8, so translations round-trip unchanged. Generate it once in the
# environment (Debian/Ubuntu: `localedef -i en_US -f UTF-8 en_US.UTF-8`).
#
# Dry run: set ERLI18N_EXTRACT_DRY_RUN=1 to parse the matrix and print the
# normalized scenario stream WITHOUT invoking gettext. This validates the
# matrix <-> parser contract on a host without the GNU gettext toolchain
# (the parity-oracle and plural-table steps are skipped).
#
# POSIX sh. All content is en-US (repo standard).
# =====================================================================

set -eu

usage() {
    echo "usage: $0 <output-dir>" >&2
    exit 64
}

[ "$#" -ge 1 ] || usage
OUTDIR=$1
mkdir -p "$OUTDIR"

# Resolve the repository root from this script's location so the matrix is
# found regardless of the caller's working directory.
SCRIPT_DIR=$(dirname -- "$0")
SCRIPT_DIR=$(cd "$SCRIPT_DIR" >/dev/null 2>&1 && pwd)
ROOT=$(dirname -- "$SCRIPT_DIR")
MATRIX="$ROOT/apps/erli18n/test/parity_matrix.eterm"

[ -f "$MATRIX" ] || { echo "ERROR: parity matrix not found: $MATRIX" >&2; exit 65; }

DRY_RUN=${ERLI18N_EXTRACT_DRY_RUN:-0}
BASE_LOCALE=${ERLI18N_PARITY_BASE_LOCALE:-en_US.UTF-8}

# Field separators shared by the awk parser and the shell consumer. FS
# (0x1E) separates the scenario FIELDS and US (0x1F) separates the elements
# of the translations list. Both are NON-whitespace control characters, so
# the shell `read`/`for` consumers preserve empty fields rather than
# collapsing consecutive separators the way they would with tab/space. TAB
# is used only for the internal plural-rows file, whose fields are never
# empty.
FS_CHAR=$(printf '\036')
US=$(printf '\037')
TAB=$(printf '\t')
EOT=$(printf '\004')
OIFS=$IFS

# Report the gettext version (diagnostic).
if command -v msgfmt >/dev/null 2>&1; then
    echo "gettext: $(msgfmt --version | head -n1)"
else
    echo "gettext: NOT FOUND (msgfmt missing)"
fi

# ---------------------------------------------------------------------
# Matrix parser (awk): emits one TAB-separated record per scenario:
#   id op locale domain plural_forms context msgid msgid_plural n present trans
# where `context`/`msgid_plural`/`n` are empty when undefined and `trans`
# is the US-joined msgstr list. Every binary value is read as the text
# between `<<"` and the next `"`, which is unambiguous because no value
# contains a double quote (see the FORMAT CONTRACT in parity_matrix.eterm).
# ---------------------------------------------------------------------
AWK_PARSE='
BEGIN { SEP = sprintf("%c", 30); US = sprintf("%c", 31); inscen = 0 }

function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }

# Inner text of the first <<"..."> > on the line.
function bin_inner(s,   r, q) {
    if (match(s, /<<"/)) {
        r = substr(s, RSTART + 3)
        q = index(r, "\"")
        if (q > 0) return substr(r, 1, q - 1)
    }
    return ""
}

# US-joined inner texts of every <<"..."> > on the line (the msgstr list).
function trans_list(s,   out, r, q, inner) {
    out = ""
    while (match(s, /<<"/)) {
        r = substr(s, RSTART + 3)
        q = index(r, "\"")
        if (q <= 0) break
        inner = substr(r, 1, q - 1)
        out = (out == "") ? inner : out US inner
        s = substr(r, q + 1)
    }
    return out
}

function reset() {
    id=""; op=""; locale=""; domain=""; pf=""; ctx=""
    msgid=""; mp=""; n=""; present=""; trans=""
}

# Fields are joined with SEP (0x1E), a NON-whitespace separator, so the
# shell `read` consumer preserves empty fields (context/msgid_plural/n)
# instead of collapsing them as it would with tab/space.
function emit() {
    printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
        id, SEP, op, SEP, locale, SEP, domain, SEP, pf, SEP, ctx, SEP, \
        msgid, SEP, mp, SEP, n, SEP, present, SEP, trans
}

{
    t = trim($0)
    if (t ~ /^%%/) next
    if (t ~ /^#\{/) { reset(); inscen = 1; next }
    if (inscen && (t == "}" || t == "},")) { emit(); inscen = 0; next }
    if (!inscen) next

    p = index($0, "=>")
    if (p == 0) next
    key = substr($0, 1, p - 1); gsub(/[ \t]/, "", key)
    val = trim(substr($0, p + 2)); sub(/,$/, "", val); val = trim(val)

    if (key == "id") id = bin_inner(val)
    else if (key == "op") op = val
    else if (key == "locale") locale = bin_inner(val)
    else if (key == "domain") domain = bin_inner(val)
    else if (key == "plural_forms") pf = bin_inner(val)
    else if (key == "context") ctx = (val == "undefined") ? "" : bin_inner(val)
    else if (key == "msgid") msgid = bin_inner(val)
    else if (key == "msgid_plural") mp = (val == "undefined") ? "" : bin_inner(val)
    else if (key == "n") n = (val == "undefined") ? "" : val
    else if (key == "present") present = val
    else if (key == "translations") trans = trans_list(val)
    # description is intentionally ignored
}
'

SCENARIOS=$(awk "$AWK_PARSE" "$MATRIX")

if [ "$DRY_RUN" = "1" ]; then
    echo "DRY RUN: parsed $(printf '%s\n' "$SCENARIOS" | grep -c .) scenarios from $MATRIX"
    # Render the control separators visibly so the stream is human-readable.
    printf '%s\n' "$SCENARIOS" | sed "s/$FS_CHAR/ | /g; s/$US/,/g"
    exit 0
fi

# From here on the real GNU gettext toolchain is required.
for tool in msgfmt gettext ngettext; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required GNU gettext tool not found: $tool" >&2
        exit 69
    }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/erli18n-extract.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---------------------------------------------------------------------
# Artifact 1: parity_oracle.eterm
# ---------------------------------------------------------------------
ORACLE="$OUTDIR/parity_oracle.eterm"
{
    echo "%% Generated by bin/extract-gettext-table.sh from"
    echo "%% apps/erli18n/test/parity_matrix.eterm against $(msgfmt --version | head -n1)."
    echo "%% One term per scenario: {<<\"id\">>, <<Bytes>>}. — the exact GNU"
    echo "%% gettext stdout (one trailing newline stripped) as raw bytes."
} > "$ORACLE"

# A leading {gettext_version, <<...>>} term records the toolchain version for
# diagnosability; the parity suite filters it out of the {Id, Bytes} results.
printf '{gettext_version, <<"%s">>}.\n' \
    "$(msgfmt --version | head -n1 | awk '{print $NF}')" >> "$ORACLE"

# Encode the gettext output file as a comma-separated decimal byte list,
# dropping exactly one trailing newline if present. Empty output -> "".
encode_bytes() {
    f=$1
    sz=$(wc -c < "$f" | tr -d ' ')
    if [ "$sz" -gt 0 ]; then
        last=$(tail -c 1 "$f" | od -An -tu1 | tr -d ' \n')
        if [ "$last" = "10" ]; then
            head -c "$((sz - 1))" "$f" > "$f.trim"
        else
            cp "$f" "$f.trim"
        fi
    else
        : > "$f.trim"
    fi
    if [ -s "$f.trim" ]; then
        od -An -v -tu1 "$f.trim" | tr -s ' \n' ',' | sed 's/^,//; s/,$//'
    fi
}

printf '%s\n' "$SCENARIOS" | while IFS="$FS_CHAR" read -r id op locale domain pf ctx msgid mp n present trans; do
    [ -n "$id" ] || continue
    sdir="$WORK/$id"
    msgdir="$sdir/$locale/LC_MESSAGES"
    mkdir -p "$msgdir"
    po="$sdir/scenario.po"

    # Build the scenario .po (header + at most one entry).
    {
        printf 'msgid ""\n'
        printf 'msgstr ""\n'
        printf '"Content-Type: text/plain; charset=UTF-8\\n"\n'
        printf '"Language: %s\\n"\n' "$locale"
        printf '"Plural-Forms: %s\\n"\n' "$pf"
        if [ "$present" = "true" ]; then
            printf '\n'
            [ -n "$ctx" ] && printf 'msgctxt "%s"\n' "$ctx"
            printf 'msgid "%s"\n' "$msgid"
            if [ -n "$mp" ]; then
                printf 'msgid_plural "%s"\n' "$mp"
                i=0
                IFS="$US"
                for msg in $trans; do
                    printf 'msgstr[%d] "%s"\n' "$i" "$msg"
                    i=$((i + 1))
                done
                IFS=$OIFS
            else
                # Singular: the first translation, or an empty msgstr.
                first=$(printf '%s' "$trans" | cut -d"$US" -f1)
                printf 'msgstr "%s"\n' "$first"
            fi
        fi
    } > "$po"

    msgfmt -o "$msgdir/$domain.mo" "$po"

    # Run the matching CLI op against the compiled catalog.
    out="$sdir/out.bin"
    case "$op" in
        gettext)
            LANGUAGE="$locale" LC_ALL="$BASE_LOCALE" TEXTDOMAINDIR="$sdir" \
                gettext -d "$domain" "$msgid" > "$out"
            ;;
        pgettext)
            key="${ctx}${EOT}${msgid}"
            LANGUAGE="$locale" LC_ALL="$BASE_LOCALE" TEXTDOMAINDIR="$sdir" \
                gettext -d "$domain" "$key" > "$out"
            ;;
        ngettext)
            LANGUAGE="$locale" LC_ALL="$BASE_LOCALE" TEXTDOMAINDIR="$sdir" \
                ngettext -d "$domain" "$msgid" "$mp" "$n" > "$out"
            ;;
        npgettext)
            key="${ctx}${EOT}${msgid}"
            LANGUAGE="$locale" LC_ALL="$BASE_LOCALE" TEXTDOMAINDIR="$sdir" \
                ngettext -d "$domain" "$key" "$mp" "$n" > "$out"
            ;;
        *)
            echo "ERROR: unknown op '$op' for scenario '$id'" >&2
            exit 70
            ;;
    esac

    bytes=$(encode_bytes "$out")
    printf '{<<"%s">>, <<%s>>}.\n' "$id" "$bytes" >> "$ORACLE"
done

echo "wrote $ORACLE"

# ---------------------------------------------------------------------
# Artifact 2: plural_forms.extracted.eterm
#
# Enumerate every UTF-8 locale this host knows (`locale -a`) and ask
# `msginit` for the `Plural-Forms:` header it fills in from gettext's
# built-in per-language table. Parse `nplurals`/`plural` and emit a sorted,
# deduplicated list. Locales whose plural form msginit leaves as the
# `nplurals=INTEGER; plural=EXPRESSION;` placeholder are skipped.
# ---------------------------------------------------------------------
EXTRACTED="$OUTDIR/plural_forms.extracted.eterm"
ROWS="$WORK/plural_rows.tsv"
: > "$ROWS"

if command -v msginit >/dev/null 2>&1 && command -v locale >/dev/null 2>&1; then
    POT="$WORK/empty.pot"
    {
        printf 'msgid ""\n'
        printf 'msgstr ""\n'
        printf '"Content-Type: text/plain; charset=UTF-8\\n"\n'
    } > "$POT"

    locale -a 2>/dev/null | while IFS= read -r loc; do
        case "$loc" in
            *.utf8 | *.UTF-8 | *.utf-8 | *.UTF8) ;;
            *) continue ;;
        esac
        base=${loc%.*}
        hdr=$(msginit --no-translator --locale="$base" -i "$POT" -o - 2>/dev/null \
                | sed -n 's/^"Plural-Forms: \(.*\)\\n"$/\1/p' | head -n1) || true
        [ -n "$hdr" ] || continue
        np=$(printf '%s' "$hdr" | sed -n 's/.*nplurals=\([0-9][0-9]*\).*/\1/p')
        pe=$(printf '%s' "$hdr" | sed -n 's/.*plural=\(.*\);[[:space:]]*$/\1/p')
        [ -n "$np" ] || continue
        [ -n "$pe" ] || continue
        case "$pe" in *EXPRESSION*) continue ;; esac
        printf '%s\t%s\t%s\n' "$base" "$np" "$pe" >> "$ROWS"
    done
else
    echo "WARNING: msginit/locale unavailable — skipping plural table" >&2
fi

{
    echo "%% Generated by bin/extract-gettext-table.sh from the host's"
    echo "%% installed UTF-8 locales via msginit ($(msgfmt --version | head -n1))."
    echo "%% Shape matches apps/erli18n/priv/gettext/plural_forms.eterm:"
    echo "%% sorted {<<Locale>>, NPlurals, <<PluralExpr>>} rows."
} > "$EXTRACTED"

sort -u "$ROWS" | sort -t"$TAB" -k1,1 | awk -F'\t' '
    BEGIN { print "[" }
    { rows[NR] = $0 }
    END {
        for (i = 1; i <= NR; i++) {
            split(rows[i], a, "\t")
            sep = (i < NR) ? "," : ""
            printf "    {<<\"%s\">>, %s, <<\"%s\">>}%s\n", a[1], a[2], a[3], sep
        }
        print "]."
    }
' >> "$EXTRACTED"

echo "wrote $EXTRACTED"
