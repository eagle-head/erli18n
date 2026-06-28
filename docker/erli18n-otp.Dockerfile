# syntax=docker/dockerfile:1.7
#
# erli18n-otp: one build environment per supported OTP release.
#
# Parameterized by ARG OTP_VERSION (27 / 28 / 29); docker-compose.yml builds it
# three times to form the OTP matrix. FROM erlang:${OTP_VERSION} gives OTP +
# rebar3 preinstalled (the image's bundled rebar3 is used on purpose: it tracks
# the OTP release it ships with, which matters for the OTP 29 lane — pinning an
# older rebar3 could pre-date OTP 29 support; CI pins rebar3 3.24 via
# erlef/setup-beam for the hosted-runner lanes).
#
# The toolchain layered on top mirrors .github/workflows/ci.yml: GNU gettext
# (msgfmt) for the parity oracle, the pt_BR/ru_RU UTF-8 locales the plural and
# parity suites depend on, and ELP (matching this image's OTP major) because the
# hardened `--full` gate hard-FAILS when elp is absent.
#
# The project is NOT copied in: docker-compose.yml bind-mounts the repo at /work
# and points REBAR_BASE_DIR at a per-OTP named volume so the three concurrent
# builds never touch the host `_build` or clobber each other.

ARG OTP_VERSION=28
FROM erlang:${OTP_VERSION}

# Pre-FROM ARGs are scoped to the FROM line only; re-declare so the build body
# below (the ELP asset selection) can read the OTP version.
ARG OTP_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# System dependencies, mirroring the CI workflow's "Install system dependencies"
# step: gettext (msgfmt) drives erli18n_parity_SUITE's oracle path; locales +
# the pt_BR/ru_RU UTF-8 locales drive the plural/parity suites; curl/tar/
# ca-certificates fetch and unpack the ELP release below.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        gettext \
        locales \
        curl \
        ca-certificates \
        tar; \
    sed -i \
        's/^# *\(en_US.UTF-8 UTF-8\)/\1/; s/^# *\(pt_BR.UTF-8 UTF-8\)/\1/; s/^# *\(ru_RU.UTF-8 UTF-8\)/\1/' \
        /etc/locale.gen; \
    locale-gen en_US.UTF-8 pt_BR.UTF-8 ru_RU.UTF-8; \
    locale -a | grep -E 'pt_BR|ru_RU'; \
    msgfmt --version | head -1; \
    rm -rf /var/lib/apt/lists/*

# Install ELP matching this image's OTP major (derived from OTP_VERSION). The
# `--full` gate REQUIRES elp (it records a hard FAIL when absent), so a missing
# or failed install must redden the build, not silently skip. Asset names are
# elp-linux-x86_64-unknown-linux-gnu-otp-<major>[.minor].tar.gz — identical to
# the lookup in .github/workflows/ci.yml.
RUN set -eux; \
    OTP_MAJOR="${OTP_VERSION%%.*}"; \
    URL="$(curl -fsSL https://api.github.com/repos/WhatsApp/erlang-language-platform/releases/latest \
        | grep -oE '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 \
        | grep -E "x86_64-unknown-linux-gnu-otp-${OTP_MAJOR}[.0-9]*\.tar\.gz$" | head -1)"; \
    echo "ELP asset for OTP ${OTP_MAJOR}: ${URL}"; \
    curl -fsSL "${URL}" -o /tmp/elp.tar.gz; \
    tar -xzf /tmp/elp.tar.gz -C /usr/local/bin; \
    chmod +x /usr/local/bin/elp; \
    rm -f /tmp/elp.tar.gz; \
    elp version

# The repo is bind-mounted here at run time; the image carries only the
# toolchain. Keep rebar3's build tree OFF the bind mount via REBAR_BASE_DIR —
# docker-compose.yml overrides it with a per-OTP path on a named volume so the
# three concurrent OTP builds never collide under the shared /work mount.
WORKDIR /work
ENV REBAR_BASE_DIR=/rebar

# erli18n_parity_SUITE reads its oracle path from this env var; the
# gettext-extract service writes parity_oracle.eterm into the shared /artifacts
# mount that docker-compose.yml wires in.
ENV ERLI18N_PARITY_ORACLE=/artifacts/parity_oracle.eterm

# Default command = the gate's parity step (the parity Common Test suite alone),
# so a bare `docker run` of this image exercises the parity check. The compose
# pipeline overrides this with the full gate (`bash bin/quality-gate.sh --full`),
# which runs parity as one hard-fail step among compile/xref/dialyzer/ct/...
CMD ["rebar3", "ct", "--suite", "apps/erli18n/test/erli18n_parity_SUITE"]
