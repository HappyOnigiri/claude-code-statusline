.PHONY: repomix clean

REPOMIX_VERSION ?= 1.12.0

repomix:
	@mkdir -p tmp/repomix
	npx --yes repomix@$(REPOMIX_VERSION) --quiet -o tmp/repomix/repomix-core.xml

clean:
	rm -rf tmp/
