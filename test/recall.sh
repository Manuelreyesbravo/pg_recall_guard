#!/usr/bin/env bash
# ¿Detecta pg_recall_guard una caída de recall? ¿Y se calla cuando no la hay?
#
# Es lo único que la extensión promete, y la regresión (test/sql/basic.sql) no
# lo prueba: corre sin pgvector a propósito, para que cargue en cualquier
# PostgreSQL, así que nunca mide un índice vectorial. Esta suite sí, y por eso
# necesita pgvector y vive aparte, como las de pg_living_assertions.
#
# LAS DOS MITADES, porque un vigilante que siempre dice "ok" pasa la mitad
# fácil y uno que siempre alarma pasa la otra:
#   * con la misma configuración con que se aprobó, check() dice `ok`;
#   * con el índice degradado (hnsw.ef_search = 2: el grafo devuelve casi nada de
#     lo que debía), check() dice `critico`.
# Medido al escribirla (PG 19beta2, pgvector): aprobado 1.0000, igual 1.0000 ok,
# degradado 0.1000 critico.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init
#   PG_CONFIG=/path/to/pg_config test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/recall.sh

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$RAIZ/.testcluster} PGPORT=${PGPORT:-5496}
BASE=recall_guard_test_recall
fallos=0

if [ ! -f "$("$PG_CONFIG" --sharedir)/extension/vector.control" ]; then
    # No es un skip que se lea como pasada: sin pgvector esta suite no midió nada.
    echo "NO CORRIÓ: pgvector no está instalado en este PostgreSQL" >&2
    exit 2
fi
if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_database where datname = '$BASE'")" = 1 ]; then
    echo "ya existe una base $BASE: no la borro, la creó otro" >&2
    exit 2
fi
trap '$PSQL -X -d postgres -qc "drop database if exists $BASE" >/dev/null 2>&1 || true' EXIT
$PSQL -X -d postgres -qc "create database $BASE"

$PSQL -X -d "$BASE" -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
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

comprobar() {
    local que="$1" esperado="$2" obtenido="$3"
    if [[ "$obtenido" == *"$esperado"* ]]; then
        echo "  ok   $que"
    else
        echo "  FAIL $que"
        echo "       esperaba: $esperado"
        echo "       obtuvo:   $obtenido"
        fallos=$((fallos + 1))
    fi
}

aprobado=$($PSQL -X -d "$BASE" -tAc "select recall_guard.approve('docs_hnsw', 10, 30)" 2>&1 || true)
comprobar "approve mide un recall alto con el índice sano" "1.0000" "$aprobado"

comprobar "con la misma configuración, check() dice ok" "ok" \
    "$($PSQL -X -d "$BASE" -tAc "select verdict from recall_guard.check()" 2>&1 || true)"

comprobar "con el índice degradado, check() dice critico" "critico" \
    "$($PSQL -X -d "$BASE" -tA -c "set hnsw.ef_search = 2" -c "select verdict from recall_guard.check()" 2>&1 || true)"

comprobar "  ...y cada medición queda registrada" "3" \
    "$($PSQL -X -d "$BASE" -tAc "select count(*) from recall_guard.measurements" 2>&1 || true)"

if [ "$fallos" -ne 0 ]; then
    echo "$fallos comprobación(es) fallaron"
    exit 1
fi
echo "el vigilante alarma cuando el recall cae, y se calla cuando no cae"
