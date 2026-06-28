# syntax=docker/dockerfile:1.7
#
# gettext-extract: the oracle producer for the parity gate.
#
# A small Debian image carrying the LATEST generally-available GNU gettext
# (msgfmt/msginit/msgmerge/...). It is the single source of truth the parity
# suite is graded against: at run time it executes `bin/extract-gettext-table.sh
# /artifacts`, which drives the real GNU gettext CLI to emit two artifacts into
# the shared /artifacts mount —
#   * plural_forms.extracted.eterm  (every locale gettext knows + its plural rule)
#   * parity_oracle.eterm           (expected gettext output for every scenario in
#                                     apps/erli18n/test/parity_matrix.eterm)
#
# `debian:stable-slim` is used deliberately: it tracks the current Debian stable,
# so `apt-get install gettext` pulls the latest GA GNU gettext without pinning a
# version that would rot. apt runs as root inside the container — no sudo needed.
#
# The project itself is NOT copied into the image: docker-compose.yml bind-mounts
# the repo read-write at /work (WORKDIR), so the entrypoint always runs the live
# extraction script and reads the live parity matrix. The image carries only the
# gettext toolchain + the UTF-8 locales the suites exercise.

FROM debian:stable-slim

# C.UTF-8 is a glibc built-in (no locale-gen needed) — a safe UTF-8 default so
# msgfmt never falls back to an ASCII locale when handling non-ASCII msgstrs.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# gettext is the toolchain under test; `locales` + the generated UTF-8 locales
# match the environment the plural/parity suites run under; ca-certificates is
# there so any HTTPS the script may touch resolves cleanly.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        gettext \
        locales \
        ca-certificates; \
    sed -i \
        's/^# *\(en_US.UTF-8 UTF-8\)/\1/; s/^# *\(pt_BR.UTF-8 UTF-8\)/\1/; s/^# *\(ru_RU.UTF-8 UTF-8\)/\1/' \
        /etc/locale.gen; \
    locale-gen en_US.UTF-8 pt_BR.UTF-8 ru_RU.UTF-8; \
    locale -a | grep -E 'pt_BR|ru_RU'; \
    msgfmt --version | head -1; \
    rm -rf /var/lib/apt/lists/*

# The repo is bind-mounted here at run time by docker-compose.yml.
WORKDIR /work

# Print the detected gettext version (diagnosability), then run the extractor
# against the shared artifacts mount. The script is invoked through `bash` so it
# runs regardless of its executable bit (the working tree may carry it 0644) and
# tolerant of any shell extension; it writes its two artifacts into /artifacts.
ENTRYPOINT ["bash", "-c", "msgfmt --version | head -1 && exec bash bin/extract-gettext-table.sh /artifacts"]
