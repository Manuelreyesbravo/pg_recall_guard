-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_recall_guard 0.2.3 -> 0.2.4
--
-- A baseline names its index with the schema, and every function runs with pg_temp
-- last.
--
-- Up to 0.2.3 vector_indexes.index_name was regclass::text, which prints the name
-- unqualified whenever its schema is on the CURRENT search_path. approve() stored
-- that text, and check() turned it back into an index with ::regclass under the
-- search_path of whoever ran check(). Measured in test/pg_temp.sh against 0.2.3:
--
--   * PostgreSQL searches pg_temp first for relations when the path does not name
--     it. A temporary index with the approved name stood in for the real one: the
--     real index lost its recall (critico) and check() answered `ok`, measuring
--     the temporary one.
--   * an index outside public, approved with its schema on the path, could not be
--     found from a session without it -- pg_cron's, typically -- so every scheduled
--     check came back NO SE PUDO MEDIR.
--
-- Now index_name is always schema.name, and the functions pin
-- search_path = pg_catalog, pg_temp: nothing they name can be supplied by the
-- caller's path. That includes the TABLESAMPLE method, which is looked up in the
-- schema tsm_system_rows was installed into instead of on the path.
--
-- Existing names are qualified here when they match exactly one vector index. A
-- name that matches indexes in two schemas is left as it is and reported: picking
-- one would be a guess, and a baseline measuring the wrong index is the failure
-- this release removes. Approve it again with a qualified name.

\echo Use "ALTER EXTENSION pg_recall_guard UPDATE TO '0.2.4'" to load this file. \quit

CREATE OR REPLACE VIEW recall_guard.vector_indexes AS
SELECT
    i.indexrelid                              AS index_oid,
    -- Qualified always, never regclass::text: that one depends on the reader's
    -- search_path, and this name is stored and read back by other sessions.
    -- format() over two `name` columns would come out with collation "C", and a
    -- view column cannot change collation: keep the one regclass::text had.
    pg_catalog.format('%I.%I', n.nspname, c.relname) COLLATE pg_catalog."default" AS index_name,
    n.nspname                                 AS schema_name,
    t.relname                                 AS table_name,
    a.attname                                 AS column_name,
    am.amname                                 AS access_method,
    op.oprname                                AS operator,
    -- El operador NO vive en pg_catalog sino donde se instaló la extensión que lo
    -- trae, así que su esquema se lee del catálogo en vez de suponerse. Asumir
    -- pg_catalog acá da "operator does not exist: vector pg_catalog.<=> vector".
    opn.nspname                               AS operator_schema,
    oc.opcname                                AS opclass,
    pg_catalog.pg_relation_size(i.indexrelid) AS index_bytes
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class     c  ON c.oid  = i.indexrelid
JOIN pg_catalog.pg_class     t  ON t.oid  = i.indrelid
JOIN pg_catalog.pg_namespace n  ON n.oid  = t.relnamespace
JOIN pg_catalog.pg_am        am ON am.oid = c.relam
JOIN pg_catalog.pg_opclass   oc ON oc.oid = i.indclass[0]
JOIN pg_catalog.pg_attribute a  ON a.attrelid = i.indexrelid AND a.attnum = 1
JOIN pg_catalog.pg_amop      ao ON ao.amopfamily = oc.opcfamily AND ao.amoppurpose = 'o'
JOIN pg_catalog.pg_operator  op ON op.oid = ao.amopopr
JOIN pg_catalog.pg_namespace opn ON opn.oid = op.oprnamespace
WHERE i.indisvalid
  AND n.nspname NOT IN ('pg_catalog', 'information_schema');

CREATE OR REPLACE FUNCTION recall_guard._vector_type(p_index regclass)
RETURNS text LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT format_type(a.atttypid, a.atttypmod)
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
    WHERE i.indexrelid = p_index;
$$;

-- The bodies of evaluate_query(), approve() and check() do not change: every
-- object they name is already qualified, and the type they cast to comes from
-- format_type(), which qualifies it whenever its schema is off the pinned path.
ALTER FUNCTION recall_guard.evaluate_query(regclass, text, int, tid)
    SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION recall_guard.approve(regclass, int, int, text)
    SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION recall_guard.check()
    SET search_path = pg_catalog, pg_temp;

CREATE OR REPLACE FUNCTION recall_guard.measure(
    p_index       regclass,
    p_k           int DEFAULT 10,
    p_sample_size int DEFAULT 30
) RETURNS numeric
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v        record;
    muestra  record;
    metodo   text;
    total    numeric := 0;
    n        int     := 0;
    r        numeric;
BEGIN
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % no es un índice vectorial', p_index;
    END IF;

    -- The sampling method lives where tsm_system_rows was installed, which is not
    -- on the pinned path: name it with its schema instead of trusting the caller's.
    SELECT format('%I.system_rows', ns.nspname) INTO metodo
    FROM pg_extension e JOIN pg_namespace ns ON ns.oid = e.extnamespace
    WHERE e.extname = 'tsm_system_rows';

    -- Se trae el ctid junto al vector: sin él no se puede descartar el self-match
    -- y el recall queda con un piso artificial de 1/k.
    FOR muestra IN EXECUTE format(
        'SELECT ctid, %I::text AS vec FROM %I.%I TABLESAMPLE %s(%s) WHERE %I IS NOT NULL',
        v.column_name, v.schema_name, v.table_name, metodo, p_sample_size, v.column_name)
    LOOP
        r := recall_guard.evaluate_query(p_index, muestra.vec, p_k, muestra.ctid);
        total := total + r;
        n := n + 1;
    END LOOP;

    IF n = 0 THEN
        RAISE EXCEPTION 'pg_recall_guard: la muestra salió vacía para %', v.index_name
            USING HINT = '¿La tabla tiene filas con esa columna no nula?';
    END IF;

    INSERT INTO recall_guard.measurements (index_name, k, sample_size, recall, index_bytes)
    VALUES (v.index_name, p_k, n, round(total / n, 4), v.index_bytes);

    RETURN round(total / n, 4);
END;
$$;

-- Qualify the names already stored. A stored name is either the bare relname,
-- quoted the way regclass prints it, or schema.relname when the schema was off
-- the approving path; it is rewritten only when exactly one vector index (outside
-- the temporary schemas, which belong to sessions that are gone) answers to it.
WITH indice AS (
    SELECT v.schema_name, c.relname
    FROM recall_guard.vector_indexes v
    JOIN pg_catalog.pg_class c ON c.oid = v.index_oid
    WHERE v.schema_name NOT LIKE 'pg\_temp\_%'
), unico AS (
    SELECT s.viejo, min(pg_catalog.format('%I.%I', x.schema_name, x.relname)) AS nuevo
    FROM (SELECT index_name AS viejo FROM recall_guard.baselines
          UNION
          SELECT index_name FROM recall_guard.measurements) s
    JOIN indice x
      ON s.viejo IN (pg_catalog.quote_ident(x.relname),
                     pg_catalog.format('%I.%I', x.schema_name, x.relname))
    GROUP BY s.viejo
    HAVING count(*) = 1
), b AS (
    UPDATE recall_guard.baselines SET index_name = u.nuevo
    FROM unico u WHERE index_name = u.viejo AND u.viejo <> u.nuevo
)
UPDATE recall_guard.measurements SET index_name = u.nuevo
FROM unico u WHERE index_name = u.viejo AND u.viejo <> u.nuevo;

DO $$
DECLARE
    sin_esquema text;
BEGIN
    SELECT pg_catalog.string_agg(index_name, ', ' ORDER BY index_name) INTO sin_esquema
    FROM recall_guard.baselines
    WHERE pg_catalog.array_length(pg_catalog.parse_ident(index_name, false), 1) = 1;
    IF sin_esquema IS NOT NULL THEN
        RAISE WARNING 'pg_recall_guard: baselines left without a schema: %', sin_esquema
            USING DETAIL = 'Each name matches no vector index, or indexes in more than one schema.',
                  HINT   = 'Approve them again with a qualified name: recall_guard.approve(''schema.index'').';
    END IF;
END;
$$;
