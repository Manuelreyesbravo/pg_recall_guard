-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_recall_guard 0.2.6 -> 0.2.7
--
-- RG-07 (external audit of 0.2.4): recall was computed by row identity. With duplicate vectors
-- -- common in RAG corpora, where a chunk is stored more than once -- an index that returns one
-- copy in place of another identical copy was counted as having missed it. Measured on 0.2.6
-- (test/audit.sh): an index that is exact by distance, over 50 vectors stored 40 times each,
-- measured 0.3878. And in a real database: idx_insights_emb, 22 rows of which only 10 distinct,
-- read `degradado` (0.9227 against an approved 0.9455) for a week while returning exactly the
-- right distances in every query.
--
-- Recall is now by distance, with ties counted: a returned row is a hit if it is no farther
-- than the k-th exact neighbour. That is what recall means for a nearest-neighbour index -- it
-- cannot be asked which of two equidistant rows to return. Without duplicates the number is the
-- same as before.
--
-- A baseline approved before 0.2.7 over a table with duplicates was approved low; the next
-- check() can read above it. It is not drift and needs no action, but re-approving it records
-- the number the index really has.

\echo Use "ALTER EXTENSION pg_recall_guard UPDATE TO '0.2.7'" to load this file. \quit

CREATE OR REPLACE FUNCTION recall_guard.evaluate_query(
    p_index regclass, p_vector text, p_k integer DEFAULT 10, p_exclude tid DEFAULT NULL,
    p_exclude_table oid DEFAULT NULL)
RETURNS numeric
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v          record;
    q_indexed  text;
    q_exact    text;
    plan_txt   text;
    rows_idx   text[];
    dist_idx   float8[];
    rows_exact text[];
    dist_exact float8[];
    excluded   text;
    family     text[];
    used       text[];
    v_from     text;
    v_limit    int;
    kth        float8;
    hits       int;
    n_exact    int;
BEGIN
    -- Si la consulta sale de una fila de la tabla, esa fila se encuentra a sí misma
    -- a distancia 0 y regala un acierto en todas las consultas. Se pide uno de más
    -- y se descarta la propia fila de los dos lados.
    v_limit := p_k + CASE WHEN p_exclude IS NULL THEN 0 ELSE 1 END;
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % no es un índice con operador de ordenamiento', p_index
            USING HINT = 'Mira recall_guard.vector_indexes para los que sí lo son.';
    END IF;

    -- ONLY for a plain table (0.2.6): its index does not cover inheritance children.
    SELECT CASE WHEN t.relkind = 'p' THEN format('%I.%I', v.schema_name, v.table_name)
                ELSE format('ONLY %I.%I', v.schema_name, v.table_name) END
      INTO v_from
      FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid WHERE i.indexrelid = p_index;

    -- Each neighbour with its distance (0.2.7): recall is judged by distance, so that two
    -- equidistant rows are interchangeable. A row is its table and ctid (0.2.6); the literal is
    -- cast to the column's base type (0.2.6), so a domain's CHECK never runs.
    q_indexed := format(
        'SELECT array_agg(r ORDER BY d, r), array_agg(d ORDER BY d, r) FROM ('
        'SELECT tableoid::text || '':'' || ctid::text AS r, '
        '(%I OPERATOR(%I.%s) %L::%s)::float8 AS d FROM %s '
        'ORDER BY %I OPERATOR(%I.%s) %L::%s LIMIT %s) s',
        v.column_name, v.operator_schema, v.operator, p_vector, recall_guard._vector_type(p_index),
        v_from,
        v.column_name, v.operator_schema, v.operator, p_vector, recall_guard._vector_type(p_index),
        v_limit);
    q_exact := q_indexed;

    -- Lado indexado: forzar el índice y COMPROBAR que se usó -- este índice, no otro (0.2.6).
    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_bitmapscan = off;
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || q_indexed INTO plan_txt;
    family := recall_guard._index_family(p_index);
    SELECT array_agg(m[1]) INTO used
      FROM regexp_matches(plan_txt, '"Index Name": "((?:[^"\\]|\\.)*)"', 'g') AS m;
    IF used IS NULL
       OR NOT used <@ family
       OR (SELECT count(*) FROM regexp_matches(plan_txt, '"Relation Name":', 'g'))
          <> array_length(used, 1) THEN
        RAISE EXCEPTION 'pg_recall_guard: el plan no midió el índice %: leyó %', v.index_name,
                coalesce(array_to_string(used, ', '), 'ningún índice')
            USING DETAIL = plan_txt,
                  HINT   = 'Medir otro índice, o la tabla sin índice, reportaría un recall que no es el de este.';
    END IF;
    EXECUTE q_indexed INTO rows_idx, dist_idx;
    RESET enable_seqscan; RESET enable_bitmapscan;

    -- Ground truth: prohibir todo acceso por índice y COMPROBAR que no se usó.
    SET LOCAL enable_indexscan  = off;
    SET LOCAL enable_bitmapscan = off;
    SET LOCAL enable_indexonlyscan = off;
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || q_exact INTO plan_txt;
    IF plan_txt LIKE '%Index Scan%' THEN
        RAISE EXCEPTION 'pg_recall_guard: no se pudo obtener ground truth exacto para %', v.index_name
            USING DETAIL = plan_txt,
                  HINT   = 'El planner insistió con el índice pese a los enable_*=off.';
    END IF;
    EXECUTE q_exact INTO rows_exact, dist_exact;
    RESET enable_indexscan; RESET enable_bitmapscan; RESET enable_indexonlyscan;

    -- Fuera el self-match de ambos lados, y recién ahí recortar a k.
    excluded := CASE WHEN p_exclude IS NULL THEN NULL
                     WHEN p_exclude_table IS NULL THEN NULL
                     ELSE p_exclude_table::text || ':' || p_exclude::text END;
    SELECT array_agg(d ORDER BY o) INTO dist_idx
      FROM (SELECT d, o FROM unnest(rows_idx, dist_idx) WITH ORDINALITY AS u(r, d, o)
             WHERE p_exclude IS NULL
                OR CASE WHEN excluded IS NULL THEN split_part(r, ':', 2) <> p_exclude::text
                        ELSE r <> excluded END
             ORDER BY o LIMIT p_k) s;
    SELECT array_agg(d ORDER BY o) INTO dist_exact
      FROM (SELECT d, o FROM unnest(rows_exact, dist_exact) WITH ORDINALITY AS u(r, d, o)
             WHERE p_exclude IS NULL
                OR CASE WHEN excluded IS NULL THEN split_part(r, ':', 2) <> p_exclude::text
                        ELSE r <> excluded END
             ORDER BY o LIMIT p_k) s;

    n_exact := coalesce(array_length(dist_exact, 1), 0);
    IF n_exact = 0 THEN
        RAISE EXCEPTION 'pg_recall_guard: el ground truth salió vacío para %', v.index_name;
    END IF;

    -- A hit is a returned neighbour no farther than the k-th exact one (0.2.7). The tolerance
    -- absorbs the last bits of floating point, not a real difference in distance.
    kth := dist_exact[n_exact];
    SELECT count(*) INTO hits
      FROM unnest(dist_idx) d
     WHERE d <= kth + greatest(abs(kth), 1) * 1e-9;

    RETURN round(least(hits, n_exact)::numeric / n_exact, 4);
END;
$$;
