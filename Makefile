EXTENSION = pg_recall_guard
DATA = pg_recall_guard--1.0.sql
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
