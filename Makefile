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
	@echo "make docs.sync  			# re-sync pg_permissions markdown into pg_permissions/site/"
	@echo "make research.docs  			# build the research docs site for all extensions (research-site/dist)"
	@echo "make research.docs.dev  		# run the research docs site locally with hot reload"
	@echo "make test.pg_validate  			# run the pg_validate test suite on a local throwaway Postgres"
	@echo "make test.pg_validate.docker  		# run the pg_validate test suite on Postgres 16, 17 and 18 (Docker)"
	@echo "make docs.pg_validate  			# build the pg_validate documentation site (pg_validate/site/dist)"
	@echo "make test.pg_crdt  			# run the pg_crdt test suite on a local throwaway Postgres"
	@echo "make test.pg_crdt.docker  		# run the pg_crdt test suite on Postgres 16, 17 and 18 with pg_tle (Docker)"
	@echo "make bench.pg_crdt  			# benchmark the pg_crdt PN-Counter (merge latency, WAL per write)"

reset:
	supabase db reset

.PHONY: tle.install
tle.install: \
	tle.install.pg_idkit \
	tle.install.is_even \
	tle.install.pg_permissions \
	tle.install.pg_validate
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

# pg_validate: test suite and documentation site (see pg_validate/test/README.md and
# pg_validate/site/README.md)
PG_VALIDATE_SITE := $(REPO_DIR)/pg_validate/site

.PHONY: test.pg_validate test.pg_validate.docker docs.pg_validate docs.pg_validate.dev
test.pg_validate:
	cd $(REPO_DIR)/pg_validate && ./test/run.sh

test.pg_validate.docker:
	cd $(REPO_DIR)/pg_validate && ./docker/run-matrix.sh

$(PG_VALIDATE_SITE)/node_modules: $(PG_VALIDATE_SITE)/package-lock.json
	npm --prefix pg_validate run docs:install

docs.pg_validate: $(PG_VALIDATE_SITE)/node_modules
	npm --prefix pg_validate run docs:build

docs.pg_validate.dev: $(PG_VALIDATE_SITE)/node_modules
	npm --prefix pg_validate run docs:dev

# pg_crdt: test suite and benchmark (see pg_crdt/test/README.md)
.PHONY: test.pg_crdt test.pg_crdt.docker bench.pg_crdt
test.pg_crdt:
	cd $(REPO_DIR)/pg_crdt && ./test/run.sh

test.pg_crdt.docker:
	cd $(REPO_DIR)/pg_crdt && ./test/docker.sh

bench.pg_crdt:
	cd $(REPO_DIR)/pg_crdt && ./bench/pn-counter.sh

# Research docs site for every <extension>/research/ directory (GitHub Pages). See research-site/README.md.
RESEARCH_SITE := $(REPO_DIR)/research-site

.PHONY: research.docs research.docs.dev
$(RESEARCH_SITE)/node_modules: $(RESEARCH_SITE)/package-lock.json
	npm --prefix research-site ci

research.docs: $(RESEARCH_SITE)/node_modules
	npm --prefix research-site run build

research.docs.dev: $(RESEARCH_SITE)/node_modules
	npm --prefix research-site run dev
