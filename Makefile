# MLB Fan Agent — convenience wrapper around Mix tasks.
#
# Requires Elixir 1.18.4-otp-26 via asdf (see .tool-versions).
# All targets delegate to Mix so the pinned toolchain is always used.
#
# Usage:
#   make           — print this help
#   make check     — full local gate (format + lint + audit + test)
#   make ci        — identical gate run in CI

.DEFAULT_GOAL := help

# ─────────────────────────────────────────────────────────────────────────────
# All phony targets (no output files produced)
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: help setup server \
        test test.unit \
        format format.check \
        lint lint.security \
        audit check ci \
        docker.build docker.up docker.down

# ─────────────────────────────────────────────────────────────────────────────
# Help (auto-generated from ## comments)
# ─────────────────────────────────────────────────────────────────────────────
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
	  /^[a-zA-Z_.-]+:.*##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ─────────────────────────────────────────────────────────────────────────────
# Development
# ─────────────────────────────────────────────────────────────────────────────

setup: ## Install deps, create & migrate DB, build assets (mix setup)
	mix setup

server: ## Start the Phoenix dev server (mix phx.server)
	mix phx.server

# ─────────────────────────────────────────────────────────────────────────────
# Test
# ─────────────────────────────────────────────────────────────────────────────

test: ## Run full test suite — requires Postgres (mix test)
	mix test

test.unit: ## Run DB-free unit suite: streaks, SSE, pricing, parsers (mix test.unit)
	mix test.unit

# ─────────────────────────────────────────────────────────────────────────────
# Code quality
# ─────────────────────────────────────────────────────────────────────────────

format: ## Auto-format all source files (mix format)
	mix format

format.check: ## Fail if any file is not formatted (mix format --check-formatted)
	mix format --check-formatted

lint: ## Run Credo linter — non-strict, matches CI gate (mix credo)
	mix credo

lint.security: ## Run Sobelow Phoenix security scanner (mix sobelow --config)
	mix sobelow --config

# ─────────────────────────────────────────────────────────────────────────────
# Security / dependency audit
#
# The earmark 1.4.49 advisory (GHSA-52mm-h59v-f3c7) is mitigated by the
# Earmark escape:true + HtmlSanitizeEx.markdown_html sanitizer pipeline
# (see security.md LOW-1).  We ignore this single advisory by ID so that
# NEW advisories still cause an immediate non-zero exit.
# ─────────────────────────────────────────────────────────────────────────────

audit: ## Run deps.audit + sobelow security scan
	mix deps.audit --ignore-advisory-ids GHSA-52mm-h59v-f3c7
	mix sobelow --config

# ─────────────────────────────────────────────────────────────────────────────
# Gates
# ─────────────────────────────────────────────────────────────────────────────

check: format.check lint audit test ## Full local gate: format + lint + audit + test

ci: format.check lint audit test ## Gate that mirrors what CI runs (same as check)

# ─────────────────────────────────────────────────────────────────────────────
# Docker
# ─────────────────────────────────────────────────────────────────────────────

docker.build: ## Build the Docker production image (docker compose build)
	docker compose build

docker.up: ## Start all services in detached mode (docker compose up -d)
	docker compose up -d

docker.down: ## Stop and remove all service containers (docker compose down)
	docker compose down
