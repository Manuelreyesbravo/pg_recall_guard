#!/usr/bin/env bash
# What measure() reports for one hnsw index as hnsw.ef_search changes, on a generated
# dataset: ROWS vectors of DIM dimensions, uniform in [-1, 1], from setseed(SEED) (the same
# data on every run). For each ef_search, measure() runs three times with k = 10 and
# SAMPLE query vectors (sampled at random, so the three differ). Results are recorded in
# bench/results.md.
#
# Runs against the server PGHOST/PGPORT point at, with pg_recall_guard and pgvector
# installed; creates the database recall_guard_bench (refuses if it exists) and drops it at
# the end.
#
#   PGHOST=... PGPORT=... bash bench/ef_search.sh
set -euo pipefail

ROWS=${ROWS:-20000}
DIM=${DIM:-64}
SAMPLE=${SAMPLE:-100}
SEED=${SEED:-0.42}
EFS=${EFS:-"1 10 40 100"}
PSQL=${PSQL:-psql}
DB=recall_guard_bench
q() { $PSQL -X -v ON_ERROR_STOP=1 -tAq -d "$DB" "$@"; }

[ -z "$($PSQL -X -tA -d postgres -c "select 1 from pg_database where datname = '$DB'")" ] ||
    { echo "database $DB exists: not touching it" >&2; exit 2; }
trap '$PSQL -X -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT
$PSQL -X -q -d postgres -c "create database $DB"
q <<SQL
CREATE EXTENSION vector;
CREATE EXTENSION pg_recall_guard CASCADE;
CREATE TABLE items (id int PRIMARY KEY, emb vector($DIM));
SELECT setseed($SEED);
INSERT INTO items
SELECT i, (SELECT array_agg(random() * 2 - 1) FROM generate_series(1, $DIM) WHERE i > 0)::vector($DIM)
  FROM generate_series(1, $ROWS) i;
CREATE INDEX items_hnsw ON items USING hnsw (emb vector_cosine_ops);
ANALYZE items;
SQL

echo "server: $(q -c 'select version()')"
echo "pgvector $(q -c "select extversion from pg_extension where extname = 'vector'"), pg_recall_guard $(q -c "select extversion from pg_extension where extname = 'pg_recall_guard'")"
echo "data: $ROWS rows of vector($DIM), uniform in [-1, 1], setseed($SEED); hnsw (m 16, ef_construction 64, cosine); k = 10, $SAMPLE sampled queries"
echo "index: $(q -c "select index_name || ' ' || access_method || ' ' || operator from recall_guard.vector_indexes")"
for ef in $EFS; do
    r=$(q -c "set hnsw.ef_search = $ef" \
          -c "select string_agg(recall_guard.measure('items_hnsw', 10, $SAMPLE)::text, ' ') from generate_series(1, 3)" | tail -1)
    printf 'ef_search %4s: measured recall %s\n' "$ef" "$r"
done
