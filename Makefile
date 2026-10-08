EXTENSION    = pg_recall_guard
DATA         = pg_recall_guard--0.1.0--0.2.0.sql pg_recall_guard--0.2.0.sql pg_recall_guard--0.2.0--0.2.1.sql pg_recall_guard--0.2.1--0.2.2.sql \
               pg_recall_guard--0.2.2--0.2.3.sql pg_recall_guard--0.2.3--0.2.4.sql
PG_CONFIG   ?= pg_config

# `make installcheck` corre solo lo que no depende de ninguna extension de
# vectores, para que pase en cualquier PostgreSQL. La prueba de extremo a extremo
# necesita pgvector y vive aparte, en `make installcheck-vector`: un installcheck
# que falla por una dependencia que el usuario no tiene entrena a ignorarlo.
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
.PHONY: check-pgtemp
check-pgtemp:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/pg_temp.sh

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

installcheck-vector:
	$(pg_regress_installcheck) --inputdir=test --outputdir=test vector

.PHONY: installcheck-vector
