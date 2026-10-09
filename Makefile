EXTENSION    = pg_recall_guard
DATA         = pg_recall_guard--0.1.0--0.2.0.sql pg_recall_guard--0.2.0.sql pg_recall_guard--0.2.0--0.2.1.sql pg_recall_guard--0.2.1--0.2.2.sql \
               pg_recall_guard--0.2.2--0.2.3.sql pg_recall_guard--0.2.3--0.2.4.sql \
               pg_recall_guard--0.2.4--0.2.5.sql \
               pg_recall_guard--0.2.5--0.2.6.sql \
               pg_recall_guard--0.2.6--0.2.7.sql \
               pg_recall_guard--0.2.7--0.2.8.sql
PG_CONFIG   ?= pg_config

# `make installcheck` runs only what depends on no vector extension, so that it
# passes on any PostgreSQL. The end-to-end test needs pgvector and lives apart, in
# `make installcheck-vector`: an installcheck that fails over a dependency the user
# does not have teaches people to ignore it.
REGRESS      = basic
REGRESS_OPTS = --inputdir=test --outputdir=test

# Does it detect a recall drop, and stay quiet when there is none? The one thing
# it promises, which installcheck cannot test without pgvector. Run against the
# throwaway cluster: test/cluster.sh init && test/cluster.sh start.
.PHONY: check-recall
check-recall:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/recall.sh

# Does check() measure the index that was approved, from any search_path? Needs
# pgvector; run against the throwaway cluster like check-recall.
# The findings of the external audit of 0.2.4, each against its control. Needs pgvector.
.PHONY: check-audit
check-audit:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/audit.sh

.PHONY: check-pgtemp
check-pgtemp:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/pg_temp.sh

# Every suite in SUITES, in a throwaway cluster built from PG_CONFIG's binaries and
# stopped afterwards, whatever the suites answered. PostgreSQL 18 or later: the
# cluster loads this checkout through extension_control_path. CI runs exactly
# this on 18 and 19.
SUITES = check-pgtemp check-recall check-audit
.PHONY: check-suites
check-suites:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh init
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh start
	@st=0; for s in $(SUITES); do echo "== $$s"; \
	    $(MAKE) --no-print-directory $$s PG_CONFIG=$(PG_CONFIG) || st=1; done; \
	 PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh stop; exit $$st

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

installcheck-vector:
	$(pg_regress_installcheck) --inputdir=test --outputdir=test vector

.PHONY: installcheck-vector
