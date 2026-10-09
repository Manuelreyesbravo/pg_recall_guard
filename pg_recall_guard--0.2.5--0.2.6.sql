-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_recall_guard 0.2.5 -> 0.2.6
--
-- From an external audit of 0.2.4, each finding measured on 0.2.5 first (test/audit.sh:
-- every tooth red there with its control green).
--
--   * RG-01: evaluate_query() cast the sampled vector back to the column's type. On a
--     domain column that cast runs the domain's CHECK constraints -- functions the domain's
--     owner wrote, which can be added after the index was approved -- as whoever measures,
--     usually a superuser's cron. The literal is now cast to the domain's BASE type, so no
--     constraint of the domain is evaluated; the operator works on the base type anyway.
--   * RG-02: measure() and evaluate_query() read the table without ONLY, so inheritance
--     children -- which the parent's index does not cover -- took part: a parent whose index
--     measured 0.00 alone measured 0.97 with an unindexed child. A plain table is read with
--     ONLY now; a partitioned table still reads its partitions, whose indexes are the
--     partitions of the one measured.
--   * RG-03: the plan check accepted any "Index Scan", so with a twin index on the same
--     column measure(X) reported the twin's recall. Every relation the plan reads must now
--     be read through X or one of its partition indexes, and nothing else; otherwise the
--     measurement fails, saying which index the planner chose.
--   * RG-04: rows were told apart by ctid, which repeats across partitions: the recall of a
--     partitioned index came out inflated (measured 0.97 against 0.95 by id), and excluding
--     the sampled row also excluded every row of another partition with its ctid. Rows are
--     (tableoid, ctid) now, and evaluate_query() takes the sampled row's table.
--   * RG-08: baselines and measurements were not dumped, so after pg_dump and restore
--     check() returned no rows. Both tables and the measurements sequence are extension
--     configuration now.

\echo Use "ALTER EXTENSION pg_recall_guard UPDATE TO '0.2.6'" to load this file. \quit

-- The type a literal is cast to: the indexed column's type, or for a domain the type at the
-- bottom of its chain, with the typmod the nearest level declares.
CREATE OR REPLACE FUNCTION recall_guard._vector_type(p_index regclass)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE chain AS (
        SELECT t.oid, t.typtype, t.typbasetype,
               CASE WHEN a.atttypmod <> -1 THEN a.atttypmod ELSE t.typtypmod END AS mod
          FROM pg_index i
          JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
          JOIN pg_type t ON t.oid = a.atttypid
         WHERE i.indexrelid = p_index
        UNION ALL
        SELECT b.oid, b.typtype, b.typbasetype,
               CASE WHEN c.mod <> -1 THEN c.mod ELSE b.typtypmod END
          FROM chain c JOIN pg_type b ON b.oid = c.typbasetype
         WHERE c.typtype = 'd'
    )
    SELECT format_type(oid, mod) FROM chain WHERE typtype <> 'd';
$$;

-- The index and, for a partitioned one, every index that is a partition of it: the only
-- indexes a plan measuring it may read through.
CREATE FUNCTION recall_guard._index_family(p_index regclass)
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE fam AS (
        SELECT p_index::oid AS oid
        UNION
        SELECT h.inhrelid FROM pg_inherits h JOIN fam f ON h.inhparent = f.oid
    )
    SELECT array_agg(c.relname::text) FROM fam JOIN pg_class c ON c.oid = fam.oid;
$$;

DROP FUNCTION recall_guard.evaluate_query(regclass, text, integer, tid);

CREATE FUNCTION recall_guard.evaluate_query(
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
    rows_exact text[];
    excluded   text;
    family     text[];
    used       text[];
    v_from     text;
    v_limit    int;
    hits       int;
BEGIN
    -- If the query comes from a row of the table, that row finds itself at distance 0
    -- and gives away a hit in every query: with k=10 the recall can never drop
    -- below 0.1, however broken the index is. One more is asked for
    -- and the row itself is dropped from both sides.
    v_limit := p_k + CASE WHEN p_exclude IS NULL THEN 0 ELSE 1 END;
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % is not an index with an ordering operator', p_index
            USING HINT = 'See recall_guard.vector_indexes for the ones that are.';
    END IF;

    -- ONLY for a plain table (0.2.6): its index does not cover inheritance children. A
    -- partitioned table is read whole, through the partitions of the measured index.
    SELECT CASE WHEN t.relkind = 'p' THEN format('%I.%I', v.schema_name, v.table_name)
                ELSE format('ONLY %I.%I', v.schema_name, v.table_name) END
      INTO v_from
      FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid WHERE i.indexrelid = p_index;

    -- A row is its table and its ctid (0.2.6): a ctid alone repeats across partitions. The
    -- literal is cast to the column's base type (0.2.6), so a domain's CHECK never runs.
    q_indexed := format(
        'SELECT array_agg(r) FROM (SELECT tableoid::text || '':'' || ctid::text AS r FROM %s '
        'ORDER BY %I OPERATOR(%I.%s) %L::%s LIMIT %s) s',
        v_from, v.column_name, v.operator_schema, v.operator,
        p_vector, recall_guard._vector_type(p_index), v_limit);
    q_exact := q_indexed;

    -- Indexed side: force the index and CHECK that it was used -- this index, no other
    -- (0.2.6): every relation in the plan is read through it or one of its partitions.
    --
    -- The plan is asked for in JSON, not text, because EXPLAIN (FORMAT TEXT) returns
    -- ONE ROW PER LINE, and an INTO keeps only the first.
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
        RAISE EXCEPTION 'pg_recall_guard: the plan did not measure index %: it read %', v.index_name,
                coalesce(array_to_string(used, ', '), 'no index')
            USING DETAIL = plan_txt,
                  HINT   = 'Measuring another index, or the table without an index, would report a recall other than this one.';
    END IF;
    EXECUTE q_indexed INTO rows_idx;
    RESET enable_seqscan; RESET enable_bitmapscan;

    -- Ground truth: forbid every index access and CHECK that none was used.
    SET LOCAL enable_indexscan  = off;
    SET LOCAL enable_bitmapscan = off;
    SET LOCAL enable_indexonlyscan = off;
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || q_exact INTO plan_txt;
    IF plan_txt LIKE '%Index Scan%' THEN
        RAISE EXCEPTION 'pg_recall_guard: could not get an exact ground truth for %', v.index_name
            USING DETAIL = plan_txt,
                  HINT   = 'The planner kept the index despite enable_*=off.';
    END IF;
    EXECUTE q_exact INTO rows_exact;
    RESET enable_indexscan; RESET enable_bitmapscan; RESET enable_indexonlyscan;

    -- Drop the self-match from both sides, and only then cut to k.
    IF p_exclude IS NOT NULL THEN
        excluded := CASE WHEN p_exclude_table IS NULL THEN NULL
                         ELSE p_exclude_table::text || ':' || p_exclude::text END;
        SELECT array_agg(x) INTO rows_idx
        FROM (SELECT x FROM unnest(rows_idx) x
               WHERE CASE WHEN excluded IS NULL THEN split_part(x, ':', 2) <> p_exclude::text
                          ELSE x <> excluded END
               LIMIT p_k) s;
        SELECT array_agg(x) INTO rows_exact
        FROM (SELECT x FROM unnest(rows_exact) x
               WHERE CASE WHEN excluded IS NULL THEN split_part(x, ':', 2) <> p_exclude::text
                          ELSE x <> excluded END
               LIMIT p_k) s;
    END IF;

    IF rows_exact IS NULL OR array_length(rows_exact, 1) IS NULL THEN
        RAISE EXCEPTION 'pg_recall_guard: the ground truth came back empty for %', v.index_name;
    END IF;

    SELECT count(*) INTO hits
    FROM unnest(rows_idx) x
    WHERE x = ANY (rows_exact);

    RETURN round(hits::numeric / array_length(rows_exact, 1), 4);
END;
$$;

CREATE OR REPLACE FUNCTION recall_guard.measure(p_index regclass, p_k integer DEFAULT 10, p_sample_size integer DEFAULT 30)
RETURNS numeric
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v        record;
    v_sample record;
    v_method text;
    v_from   text;
    total    numeric := 0;
    n        int     := 0;
    r        numeric;
BEGIN
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % is not a vector index', p_index;
    END IF;

    -- The sampling method lives where tsm_system_rows was installed, which is not
    -- on the pinned path: name it with its schema instead of trusting the caller's.
    SELECT format('%I.system_rows', ns.nspname) INTO v_method
    FROM pg_extension e JOIN pg_namespace ns ON ns.oid = e.extnamespace
    WHERE e.extname = 'tsm_system_rows';

    -- The same rows evaluate_query() compares against (0.2.6): ONLY for a plain table,
    -- whose index does not cover inheritance children.
    SELECT CASE WHEN t.relkind = 'p' THEN format('%I.%I', v.schema_name, v.table_name)
                ELSE format('ONLY %I.%I', v.schema_name, v.table_name) END
      INTO v_from
      FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid WHERE i.indexrelid = p_index;

    -- The row (table and ctid) comes along with the vector: without it the self-match
    -- cannot be dropped and the recall is left with an artificial floor of 1/k.
    FOR v_sample IN EXECUTE format(
        'SELECT tableoid, ctid, %I::text AS vec FROM %s TABLESAMPLE %s(%s) WHERE %I IS NOT NULL',
        v.column_name, v_from, v_method, p_sample_size, v.column_name)
    LOOP
        r := recall_guard.evaluate_query(p_index, v_sample.vec, p_k, v_sample.ctid, v_sample.tableoid);
        total := total + r;
        n := n + 1;
    END LOOP;

    IF n = 0 THEN
        RAISE EXCEPTION 'pg_recall_guard: the sample came back empty for %', v.index_name
            USING HINT = 'Does the table have rows where that column is not null?';
    END IF;

    INSERT INTO recall_guard.measurements (index_name, k, sample_size, recall, index_bytes)
    VALUES (v.index_name, p_k, n, round(total / n, 4), v.index_bytes);

    RETURN round(total / n, 4);
END;
$$;

-- What a restore must bring back (RG-08).
SELECT pg_catalog.pg_extension_config_dump('recall_guard.baselines', '');
SELECT pg_catalog.pg_extension_config_dump('recall_guard.measurements', '');
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('recall_guard.measurements', 'id')::regclass, '');
