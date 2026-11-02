REPO_DIR=$(shell pwd)

.PHONY: help install install.one install.two docs docs.dev docs.sync

help:
	@echo "\nSCRIPTS\n"
	@echo "make reset  					# reset supabase database"
	@echo "make tle.install  			# install all extensions locally"
	@echo "make dbdev.publish.XXX  		# publish XXX extension"
	@echo "make test.pg_permissions  		# run the pg_permissions test suite (the extension by default; IMPL=prototypes/a-tuple-core.sql etc. for a prototype)"
	@echo "make bench.pg_permissions 		# benchmark pg_permissions (the extension by default; IMPL=..., SCALE=small|medium|large)"
	@echo "make docs  				# build the documentation site (pg_permissions/site/dist)"
	@echo "make docs.dev  				# run the documentation site locally with hot reload"
	@echo "make docs.sync  			# re-sync pg_permissions markdown and benchmark data into pg_permissions/site/"

reset:
	supabase db reset

.PHONY: tle.install
tle.install: \
	tle.install.pg_idkit \
	tle.install.is_even \
	tle.install.pg_permissions
	@echo "\n\nDone!"

tle.install.%:
	@echo "\n\nInstalling $*"
	dbdev install --connection postgres://postgres:postgres@localhost:54322/postgres --path $(REPO_DIR)/$*
	PGPASSWORD=postgres psql -U postgres -d postgres -h localhost -p 54322 -c "CREATE EXTENSION $*;" 

tle.update.%:
	@echo "\n\Updating $*"
	dbdev install --connection postgres://postgres:postgres@localhost:54322/postgres --path $(REPO_DIR)/$*

dbdev.publish.%:
	@echo "\n\nPublishing $* \n"
	dbdev publish --path $(REPO_DIR)/$*
# pg_permissions: test suite and benchmarks (see pg_permissions/test/README.md)
IMPL ?= pg_permissions--0.1.0.sql
SCALE ?= small

.PHONY: test.pg_permissions bench.pg_permissions
test.pg_permissions:
	cd $(REPO_DIR)/pg_permissions && ./test/run.sh --impl $(IMPL)

bench.pg_permissions:
	cd $(REPO_DIR)/pg_permissions && ./bench/run.sh --impl $(IMPL) --scale $(SCALE)

# Documentation site (Astro + Starlight): thin wrappers over the npm scripts in
# pg_permissions/package.json. See pg_permissions/site/README.md.
SITE := $(REPO_DIR)/pg_permissions/site
$(SITE)/node_modules: $(SITE)/package-lock.json
	npm --prefix pg_permissions run docs:install

docs: $(SITE)/node_modules
	npm --prefix pg_permissions run docs:build

docs.dev: $(SITE)/node_modules
	npm --prefix pg_permissions run docs:dev

docs.sync: $(SITE)/node_modules
	npm --prefix pg_permissions run docs:sync
