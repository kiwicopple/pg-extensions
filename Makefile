REPO_DIR=$(shell pwd)

.PHONY: help install install.one install.two

help:
	@echo "\nSCRIPTS\n"
	@echo "make reset  					# reset supabase database"
	@echo "make tle.install  			# install all extensions locally"
	@echo "make dbdev.publish.XXX  		# publish XXX extension"

reset:
	supabase db reset

.PHONY: tle.install
tle.install: \
	tle.install.pg_idkit \
	tle.install.is_even
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