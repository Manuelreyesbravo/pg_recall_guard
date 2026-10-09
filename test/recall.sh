#!/usr/bin/env bash
# Does pg_recall_guard detect a recall drop? And does it stay quiet when there is none?
#
# It is the one thing the extension promises, and the regression suite
# (test/sql/basic.sql) does not test it: it runs without pgvector on purpose, so
# that it loads on any PostgreSQL, and so it never measures a vector index. This
# suite does, and that is why it needs pgvector and lives apart, like the ones of
# pg_living_assertions.
#
# BOTH HALVES, because a guard that always says "ok" passes the easy half and one
# that always alarms passes the other:
#   * with the same settings it was approved with, check() says `ok`;
#   * with the index degraded (hnsw.ef_search = 2: the graph returns almost none of
#     what it should), check() says `critical`.
# Measured when it was written (PG 19beta2, pgvector): approved 1.0000, unchanged
# 1.0000 ok, degraded 0.1000 critical.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init
#   PG_CONFIG=/path/to/pg_config test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/recall.sh

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$ROOT/.testcluster} PGPORT=${PGPORT:-5496}
DB=recall_guard_test_recall
failures=0

if [ ! -f "$("$PG_CONFIG" --sharedir)/extension/vector.control" ]; then
    # Not a skip that reads as a pass: without pgvector this suite measured nothing.
    echo "DID NOT RUN: pgvector is not installed in this PostgreSQL" >&2
    exit 2
fi
if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_database where datname = '$DB'")" = 1 ]; then
    echo "a database $DB already exists: not dropping it, somebody else made it" >&2
    exit 2
fi
trap '$PSQL -X -d postgres -qc "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT
$PSQL -X -d postgres -qc "create database $DB"

$PSQL -X -d "$DB" -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION vector;
CREATE EXTENSION pg_recall_guard CASCADE;
SELECT setseed(0.42);
CREATE TABLE docs (id int PRIMARY KEY, emb vector(16));
INSERT INTO docs
SELECT g, (SELECT array_agg(random())::vector(16) FROM generate_series(1, 16) WHERE g > 0)
  FROM generate_series(1, 5000) g;
CREATE INDEX docs_hnsw ON docs USING hnsw (emb vector_l2_ops);
ANALYZE docs;
SQL

check() {
    local what="$1" expected="$2" got="$3"
    if [[ "$got" == *"$expected"* ]]; then
        echo "  ok   $what"
    else
        echo "  FAIL $what"
        echo "       expected: $expected"
        echo "       got:      $got"
        failures=$((failures + 1))
    fi
}

approved=$($PSQL -X -d "$DB" -tAc "select recall_guard.approve('docs_hnsw', 10, 30)" 2>&1 || true)
check "approve measures a high recall on the healthy index" "1.0000" "$approved"

check "with the same settings, check() says ok" "ok" \
    "$($PSQL -X -d "$DB" -tAc "select verdict from recall_guard.check()" 2>&1 || true)"

# Degraded for real, not with a session SET: since 0.2.8 check() measures under the settings it was
# approved with, so a low ef_search in the checking session no longer changes the verdict. The index
# is rebuilt with the same name and bad parameters (m = 2): measured, 1.0000 -> 0.1867.
$PSQL -X -d "$DB" -q -c "drop index docs_hnsw" -c "create index docs_hnsw on docs using hnsw (emb vector_l2_ops) with (m = 2, ef_construction = 4)" >/dev/null
check "with the index degraded, check() says critical" "critical" \
    "$($PSQL -X -d "$DB" -tAc "select verdict from recall_guard.check()" 2>&1 || true)"

check "  ...and every measurement is recorded" "3" \
    "$($PSQL -X -d "$DB" -tAc "select count(*) from recall_guard.measurements" 2>&1 || true)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "the guard alarms when the recall drops, and stays quiet when it does not"
