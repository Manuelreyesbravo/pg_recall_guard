EXTENSION    = pg_recall_guard
DATA         = pg_recall_guard--0.1.0--0.2.0.sql pg_recall_guard--0.2.0.sql
PG_CONFIG   ?= pg_config

# `make installcheck` corre solo lo que no depende de ninguna extension de
# vectores, para que pase en cualquier PostgreSQL. La prueba de extremo a extremo
# necesita pgvector y vive aparte, en `make installcheck-vector`: un installcheck
# que falla por una dependencia que el usuario no tiene entrena a ignorarlo.
REGRESS      = basic
REGRESS_OPTS = --inputdir=test --outputdir=test

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

installcheck-vector:
	$(pg_regress_installcheck) --inputdir=test --outputdir=test vector

.PHONY: installcheck-vector
