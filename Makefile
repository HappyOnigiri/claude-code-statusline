.PHONY: run run-silent dry-run run-summarize-only reset setup test ci repomix repomix-full repomix-task repomix-core prep-repomix install-hooks help help-en sync-ruler

REPOMIX_VERSION ?= 1.12.0

repomix:
	@mkdir -p tmp/repomix
	npx --yes repomix@$(REPOMIX_VERSION) --quiet -o tmp/repomix/repomix-core.xml
