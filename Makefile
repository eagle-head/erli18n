# erli18n orchestration Makefile
#
# THIN entry point: every target delegates to docker-compose, the quality
# gate, or the bin/ scripts. The real logic lives in those shell scripts,
# never here -- this file only wires targets together and sets dependencies.
#
# Quick start:
#   make help          List every target.
#   make gate-fast     Fast local gate (the pre-commit check).
#   make gate-full     Full dockerized gate across OTP 27/28/29 (the pre-push check).
#
# All comments and output are en-US (repo standard).

# --- Configuration (override on the command line, e.g. `make COMPOSE=docker-compose`) ---

# Container orchestrator. Compose v2 ("docker compose") by default; override
# with `make COMPOSE=docker-compose` on legacy v1 hosts.
COMPOSE ?= docker compose

# The gate pipeline lives in the repo-root docker-compose.yml. Pass it
# explicitly so a legacy ./compose.yml (the act bootstrap file) can never
# shadow it during Compose's default file lookup.
COMPOSE_FILE ?= docker-compose.yml
DC := $(COMPOSE) -f $(COMPOSE_FILE)

# Host side of the shared bind-mount (container path: /artifacts). The
# extractor writes plural_forms.extracted.eterm and parity_oracle.eterm here.
ARTIFACTS_DIR ?= .gate/artifacts
PARITY_ORACLE ?= $(ARTIFACTS_DIR)/parity_oracle.eterm

# The three supported OTP releases, as named in docker-compose.yml.
OTP_SERVICES := erli18n-otp27 erli18n-otp28 erli18n-otp29

.DEFAULT_GOAL := help

.PHONY: help gate-fast gate-full extract parity release-check hooks-install otp-matrix pull

help: ## List the available targets.
	@echo "erli18n make targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*## "} {printf "  %-14s %s\n", $$1, $$2}'

gate-fast: ## Fast local gate (compile/xref/fmt/lint); mirrors the pre-commit hook.
	bash bin/quality-gate.sh --fast

extract: ## Run the GNU gettext extractor once; writes the oracle + plural table to .gate/artifacts.
	@mkdir -p $(ARTIFACTS_DIR)
	$(DC) run --rm -T gettext-extract

otp-matrix: extract ## Run the full in-container gate across OTP 27/28/29 (reuses the single extraction).
	$(DC) run --rm -T --no-deps erli18n-otp27
	$(DC) run --rm -T --no-deps erli18n-otp28
	$(DC) run --rm -T --no-deps erli18n-otp29

pull: ## Rebuild the gate images, pulling the latest base (newest OTP minor + gettext).
	$(DC) build --pull

gate-full: pull otp-matrix ## Full dockerized gate: refresh to the latest OTP minor, extract once, then OTP 27/28/29; mirrors the pre-push hook.
	@echo "Full gate passed across $(OTP_SERVICES)."

parity: extract ## Run only the gettext-parity suite locally against the freshly extracted oracle.
	ERLI18N_PARITY_ORACLE=$(abspath $(PARITY_ORACLE)) \
		rebar3 ct --suite=apps/erli18n/test/erli18n_parity_SUITE

release-check: ## Full local release-readiness gate (requires elp); run before tagging a release.
	bash bin/quality-gate.sh --full

hooks-install: ## Point git at .githooks (pre-commit=--fast, pre-push=--full).
	bash bin/install-git-hooks.sh
