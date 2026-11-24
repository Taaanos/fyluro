.DEFAULT_GOAL := help

VERSION ?= $(shell tr -d '[:space:]' < VERSION)

.PHONY: help build dev test hig-test hig-test-main hig-snapshots hig-snapshots-main e2e fixtures fixtures-check package smoke check clean

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build debug CLI and launcher binaries
	swift build

dev: ## Build and launch Fyluro-dev.app
	./scripts/run-dev-app.sh

test: ## Run unit tests (swift test)
	swift test

hig-test: ## Run complete macOS HIG UI layout suite
	swift test --filter LauncherHIG

hig-test-main: ## Run main-window macOS HIG UI layout tests only
	swift test --filter LauncherHIGMainWindowTests

hig-snapshots: ## Render Dark Mode HIG PNG snapshots (complete suite)
	FYLURO_RENDER_HIG_SCREENSHOTS=1 swift test --filter "LauncherHIG.*SnapshotsIfRequested"

hig-snapshots-main: ## Render Dark Mode HIG PNG snapshots (main window only)
	FYLURO_RENDER_HIG_SCREENSHOTS=1 swift test --filter LauncherHIGMainWindowTests/testRenderMainWindowHIGSnapshotsIfRequested

e2e: ## Run all E2E test scripts
	./scripts/run-e2e-tests.sh

fixtures: ## Build synthetic E2E source card fixtures
	python3 scripts/build-e2e-fixtures.py --synthetic

fixtures-check: ## Verify E2E source card fixtures against manifest
	python3 scripts/build-e2e-fixtures.py --check

package: ## Package release Fyluro.app, zip, and sha256 (override VERSION=x.y.z)
	./scripts/package-macos-app.sh --version $(VERSION)

smoke: ## Smoke-test packaged dist/Fyluro.app with launcher check
	./scripts/release-app-smoke-test.sh --version $(VERSION) --with-launcher-check

check: test e2e ## Run unit tests and E2E tests

clean: ## Clean Swift build artifacts and dist/
	swift package clean
	rm -rf dist
