#!/usr/bin/env bash
# Does check() measure the index that was approved, and only that one?
#
# Up to 0.2.3 a baseline stored the index name the way regclass::text printed it
# in the approving session: unqualified whenever its schema was on that session's
# search_path. check() turned it back into an index with ::regclass under the
# CHECKING session's search_path, and PostgreSQL searches pg_temp first for
# relations when the path does not name it. Two consequences, both measured here
# against 0.2.3 before the fix:
#
#   * a temporary index with the approved name stood in for the real one. The
#     real index lost its recall and check() answered `ok`, measuring the
#     temporary one;
#   * an index outside public, approved with its schema on the path, could not
#     be measured from a session without it -- pg_cron's, typically -- and every
#     check came back NO SE PUDO MEDIR.
#
# From 0.2.4 the name is stored schema-qualified and every function runs with
# pg_temp last. The upgrade qualifies existing baselines when the name matches
# exactly one index, and leaves it alone when it would have to guess.
#
# Each tooth has its control: the same check without the temporary index, or
# from the approving path, so a red here means the defect and not the setup.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init && test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/pg_temp.sh
#   RG_VERSION=0.2.3 test/pg_temp.sh      # the same teeth against an older release

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$RAIZ/.testcluster} PGPORT=${PGPORT:-5496}
BASE=recall_guard_test_pgtemp
VERSION=${RG_VERSION:-}
fallos=0

if [ ! -f "$("$PG_CONFIG" --sharedir)/extension/vector.control" ]; then
    echo "DID NOT RUN: pgvector is not installed in this PostgreSQL" >&2
    exit 2
fi
if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_database where datname = '$BASE'")" = 1 ]; then
    echo "a database $BASE already exists: not dropping it, somebody else made it" >&2
    exit 2
fi
trap '$PSQL -X -d postgres -qc "drop database if exists $BASE" >/dev/null 2>&1 || true' EXIT

q() { $PSQL -X -d "$BASE" -tA "$@" 2>&1 || true; }

comprobar() {
    local que="$1" esperado="$2" obtenido="$3"
    if [ "$obtenido" = "$esperado" ]; then
        echo "  ok   $que"
    else
        echo "  FAIL $que"
        echo "       expected: $esperado"
        echo "       got:      $obtenido"
        fallos=$((fallos + 1))
    fi
}

crear() {
    $PSQL -X -d postgres -qc "drop database if exists $BASE" >/dev/null
    $PSQL -X -d postgres -qc "create database $BASE"
    $PSQL -X -d "$BASE" -q -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE EXTENSION vector;
CREATE EXTENSION pg_recall_guard ${1:+VERSION '$1'} CASCADE;
SELECT setseed(0.42);
-- public.docs: an ivfflat index. Approved with every list probed (exact), checked
-- with one: its recall really drops, so the honest answer is critico.
CREATE TABLE docs (id int PRIMARY KEY, emb vector(16));
INSERT INTO docs SELECT g, (SELECT array_agg(random())::vector(16)
                              FROM generate_series(1, 16) WHERE g > 0)
  FROM generate_series(1, 5000) g;
CREATE INDEX docs_idx ON docs USING ivfflat (emb vector_l2_ops) WITH (lists = 100);
-- app.items: an index outside public, healthy.
CREATE SCHEMA app;
CREATE TABLE app.items (id int PRIMARY KEY, emb vector(16));
INSERT INTO app.items SELECT id, emb FROM docs WHERE id <= 2000;
CREATE INDEX items_idx ON app.items USING hnsw (emb vector_l2_ops);
-- The same relname in two schemas: an unqualified baseline for it is ambiguous.
CREATE TABLE dup (id int PRIMARY KEY, emb vector(16));
CREATE TABLE app.dup (id int PRIMARY KEY, emb vector(16));
INSERT INTO dup SELECT id, emb FROM docs WHERE id <= 500;
INSERT INTO app.dup SELECT id, emb FROM docs WHERE id <= 500;
CREATE INDEX dup_idx ON dup USING hnsw (emb vector_l2_ops);
CREATE INDEX dup_idx ON app.dup USING hnsw (emb vector_l2_ops);
ANALYZE;
SQL
}

# A temporary table and index with the approved names, in the checking session.
SUPLANTAR="CREATE TEMP TABLE docs (id int PRIMARY KEY, emb vector(16));
INSERT INTO docs SELECT id, emb FROM public.docs WHERE id <= 300;
CREATE INDEX docs_idx ON docs USING hnsw (emb vector_l2_ops);
ANALYZE docs;"

APROBAR="SET ivfflat.probes = 100;
SELECT recall_guard.approve('public.docs_idx', 10, 30) IS NOT NULL;
RESET ivfflat.probes;
SET search_path = app, public;
SELECT recall_guard.approve('items_idx', 10, 30) IS NOT NULL;"

echo "== ${VERSION:-repo} =="
crear "$VERSION"
q -q -c "$APROBAR" >/dev/null
# From 0.2.8 check() measures under the settings recorded at approval. This test is about which
# index is measured, not about settings: the baseline is set to search as the index is searched now,
# with one probe, where the real ivfflat's recall drops and a temporary hnsw's would not.
[ -z "$VERSION" ] && q -q -c "update recall_guard.baselines set settings = coalesce(settings, '{}') || '{\"ivfflat.probes\": \"1\"}' where index_name = 'public.docs_idx'" >/dev/null

veredicto="select coalesce(verdict, 'null') from recall_guard.check() where index_name like '%docs_idx'"
comprobar "control: the real docs_idx, one probe, is critico" "critico" \
    "$(q -c "$veredicto")"
comprobar "a temporary docs_idx does not stand in for the approved one" "critico" \
    "$(q -c "$SUPLANTAR" -c "$veredicto" | tail -1)"

items="select coalesce(left(verdict, 15), 'null') from recall_guard.check() where index_name like '%items_idx'"
comprobar "control: app.items_idx from the approving path is ok" "ok" \
    "$(q -c "set search_path = app, public" -c "$items" | tail -1)"
comprobar "app.items_idx is measured from a session without app on its path" "ok" \
    "$(q -c "$items")"

comprobar "a baseline names its index with the schema" "app.items_idx|public.docs_idx" \
    "$(q -c "select string_agg(index_name, '|' order by index_name) from recall_guard.baselines")"

# The upgrade: baselines written by 0.2.3 with unqualified names.
if [ -z "$VERSION" ]; then
    crear 0.2.3
    q -q -c "$APROBAR" >/dev/null
    q -q -c "SET search_path = app, public" \
         -c "INSERT INTO recall_guard.baselines (index_name, k, sample_size, recall) VALUES ('dup_idx', 10, 30, 1)" >/dev/null
    comprobar "control: 0.2.3 stored the names unqualified" "docs_idx|dup_idx|items_idx" \
        "$(q -c "select string_agg(index_name, '|' order by index_name) from recall_guard.baselines")"
    q -q -c "ALTER EXTENSION pg_recall_guard UPDATE" >/dev/null
    comprobar "the upgrade qualifies the names that match one index, and leaves the ambiguous one" \
        "app.items_idx|dup_idx|public.docs_idx" \
        "$(q -c "select string_agg(index_name, '|' order by index_name) from recall_guard.baselines")"
    comprobar "after the upgrade, a temporary docs_idx does not stand in either" "critico" \
        "$(q -c "$SUPLANTAR" -c "$veredicto" | tail -1)"
    comprobar "after the upgrade, app.items_idx is measured from the default path" "ok" \
        "$(q -c "$items")"
fi

if [ "$fallos" -ne 0 ]; then
    echo "$fallos check(s) failed"
    exit 1
fi
echo "check() measures the index that was approved, from any search_path"
