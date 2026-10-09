-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_recall_guard 0.2.0 -- checks that a vector index keeps returning what you approved.
--
-- The problem: a degraded ANN index does NOT fail. It returns k plausible neighbours
-- and never says that four of the ten right ones were left out. No error, no log, no
-- alert -- just like a plan regression, which returns the same rows and only stops
-- using the index.
--
-- What it does: finds the vector indexes by CATALOG (not by extension name), measures
-- their real recall against exact ground truth, keeps a baseline and warns when the
-- recall drifts away from it.
--
-- Agnostic by construction: it works on any index whose access method declares
-- ordering operators (pg_amop.amoppurpose='o'), which today is hnsw, ivfflat, diskann,
-- gist and spgist -- and tomorrow whatever comes, without touching this code.

\echo Use "CREATE EXTENSION pg_recall_guard" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS recall_guard;

-- ---------------------------------------------------------------------------
-- 1. Discovery
-- ---------------------------------------------------------------------------

-- Every index in the cluster that can answer an ORDER BY by a distance operator,
-- with the data needed to rebuild that query.
CREATE VIEW recall_guard.vector_indexes AS
SELECT
    i.indexrelid                              AS index_oid,
    i.indexrelid::regclass::text              AS index_name,
    n.nspname                                 AS schema_name,
    t.relname                                 AS table_name,
    a.attname                                 AS column_name,
    am.amname                                 AS access_method,
    op.oprname                                AS operator,
    -- The operator does NOT live in pg_catalog but wherever the extension that brings
    -- it was installed, so its schema is read from the catalog instead of assumed.
    -- Assuming pg_catalog gives "operator does not exist: vector pg_catalog.<=> vector".
    opn.nspname                               AS operator_schema,
    oc.opcname                                AS opclass,
    pg_relation_size(i.indexrelid)            AS index_bytes
FROM pg_index i
JOIN pg_class     c  ON c.oid  = i.indexrelid
JOIN pg_class     t  ON t.oid  = i.indrelid
JOIN pg_namespace n  ON n.oid  = t.relnamespace
JOIN pg_am        am ON am.oid = c.relam
JOIN pg_opclass   oc ON oc.oid = i.indclass[0]
JOIN pg_attribute a  ON a.attrelid = i.indexrelid AND a.attnum = 1
JOIN pg_amop      ao ON ao.amopfamily = oc.opcfamily AND ao.amoppurpose = 'o'
JOIN pg_operator  op ON op.oid = ao.amopopr
JOIN pg_namespace opn ON opn.oid = op.oprnamespace
WHERE i.indisvalid
  AND n.nspname NOT IN ('pg_catalog', 'information_schema');

COMMENT ON VIEW recall_guard.vector_indexes IS
    'Indexes that answer ORDER BY by a distance operator, found through the catalog. '
    'Names no extension: works for pgvector, pgvectorscale, VectorChord or whatever comes next.';

-- ---------------------------------------------------------------------------
-- 2. Persisted state
-- ---------------------------------------------------------------------------

CREATE TABLE recall_guard.baselines (
    index_name   text        PRIMARY KEY,
    k            int         NOT NULL,
    sample_size  int         NOT NULL,
    recall       numeric(5,4) NOT NULL,
    approved_at  timestamptz NOT NULL DEFAULT now(),
    note         text
);

COMMENT ON TABLE recall_guard.baselines IS
    'The recall the owner accepted as good. Without a baseline there is no drift to measure: '
    '"0.82" says nothing, "0.82 where you approved 0.97" says it all.';

CREATE TABLE recall_guard.measurements (
    id           bigserial   PRIMARY KEY,
    index_name   text        NOT NULL,
    k            int         NOT NULL,
    sample_size  int         NOT NULL,
    recall       numeric(5,4) NOT NULL,
    index_bytes  bigint,
    measured_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON recall_guard.measurements (index_name, measured_at DESC);

-- ---------------------------------------------------------------------------
-- 3. The measurement
-- ---------------------------------------------------------------------------

-- Recall of ONE query: how many of the k neighbours the index returns are among
-- the true k.
--
-- The honesty of this function rests on two things that are CHECKED, not assumed:
-- that the indexed side really used the index, and that the exact side really did
-- NOT. If either fails, the number would be a made-up 1.0000 -- the worst possible
-- result, because it is reassuring and false. So the plan is checked with EXPLAIN
-- and an exception is raised instead of returning anything.
CREATE FUNCTION recall_guard.evaluate_query(
    p_index   regclass,
    p_vector  text,
    p_k       int DEFAULT 10,
    p_exclude tid DEFAULT NULL   -- the source ctid, when the query comes from the table
) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v          record;
    q_indexed  text;
    q_exact    text;
    plan_txt   text;
    tids_idx   tid[];
    tids_exact tid[];
    v_limit    int;
    hits       int;
BEGIN
    -- If the query comes from a row of the table, that row finds itself at distance 0
    -- and gives away a hit in every query: with k=10 the recall can never drop
    -- below 0.1, however broken the index is. One more is asked for
    -- and its own ctid is dropped from both sides.
    v_limit := p_k + CASE WHEN p_exclude IS NULL THEN 0 ELSE 1 END;
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % is not an index with an ordering operator', p_index
            USING HINT = 'See recall_guard.vector_indexes for the ones that are.';
    END IF;

    q_indexed := format(
        'SELECT array_agg(ctid) FROM (SELECT ctid FROM %I.%I ORDER BY %I OPERATOR(%I.%s) %L::%s LIMIT %s) s',
        v.schema_name, v.table_name, v.column_name,
        v.operator_schema, v.operator,
        p_vector, recall_guard._vector_type(p_index), v_limit);
    q_exact := q_indexed;

    -- Indexed side: force the index and CHECK that it was used.
    --
    -- The plan is asked for in JSON, not text, because EXPLAIN (FORMAT TEXT) returns
    -- ONE ROW PER LINE, and an INTO keeps only the first: the "Index Scan"
    -- further down would never be seen and the check would be decorative.
    SET LOCAL enable_seqscan = off;
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || q_indexed INTO plan_txt;
    IF plan_txt NOT LIKE '%Index Scan%' THEN
        RAISE EXCEPTION 'pg_recall_guard: the plan did not use index %', v.index_name
            USING DETAIL = plan_txt,
                  HINT   = 'Without an index scan the measurement would compare the index with itself and always give 1.0.';
    END IF;
    EXECUTE q_indexed INTO tids_idx;
    RESET enable_seqscan;

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
    EXECUTE q_exact INTO tids_exact;
    RESET enable_indexscan; RESET enable_bitmapscan; RESET enable_indexonlyscan;

    -- Drop the self-match from both sides, and only then cut to k. Cutting
    -- first, the gap the dropped row leaves would be filled by neighbour
    -- k+1 and we would count too many again.
    IF p_exclude IS NOT NULL THEN
        SELECT array_agg(x) INTO tids_idx
        FROM (SELECT x FROM unnest(tids_idx) x WHERE x <> p_exclude LIMIT p_k) s;
        SELECT array_agg(x) INTO tids_exact
        FROM (SELECT x FROM unnest(tids_exact) x WHERE x <> p_exclude LIMIT p_k) s;
    END IF;

    IF tids_exact IS NULL OR array_length(tids_exact, 1) IS NULL THEN
        RAISE EXCEPTION 'pg_recall_guard: the ground truth came back empty for %', v.index_name;
    END IF;

    SELECT count(*) INTO hits
    FROM unnest(tids_idx) x
    WHERE x = ANY (tids_exact);

    RETURN round(hits::numeric / array_length(tids_exact, 1), 4);
END;
$$;

-- The type of the indexed column, to cast the vector literal without assuming
-- it is always `vector`: it can be halfvec, sparsevec or whatever the extension
-- at hand brings.
CREATE FUNCTION recall_guard._vector_type(p_index regclass)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT format_type(a.atttypid, a.atttypmod)
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
    WHERE i.indexrelid = p_index;
$$;

-- ---------------------------------------------------------------------------
-- 4. Sampling and aggregate measurement
-- ---------------------------------------------------------------------------

-- Mean recall of the index over a sample of queries.
--
-- The queries come from vectors of the table itself, and that has a trap to
-- disarm: a vector of the table ALWAYS finds itself at distance 0, and that free
-- hit inflates the recall -- with k=10 it is 10 points for free in every query.
-- So k+1 neighbours are asked for and its own ctid is dropped from both sides.
-- It is the difference between measuring the index and measuring that a vector
-- equals itself.
CREATE FUNCTION recall_guard.measure(
    p_index       regclass,
    p_k           int DEFAULT 10,
    p_sample_size int DEFAULT 30
) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v        record;
    v_sample record;
    total    numeric := 0;
    n        int     := 0;
    r        numeric;
BEGIN
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % is not a vector index', p_index;
    END IF;

    -- The ctid comes along with the vector: without it the self-match cannot be dropped
    -- and the recall is left with an artificial floor of 1/k.
    FOR v_sample IN EXECUTE format(
        'SELECT ctid, %I::text AS vec FROM %I.%I TABLESAMPLE SYSTEM_ROWS(%s) WHERE %I IS NOT NULL',
        v.column_name, v.schema_name, v.table_name, p_sample_size, v.column_name)
    LOOP
        r := recall_guard.evaluate_query(p_index, v_sample.vec, p_k, v_sample.ctid);
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

-- ---------------------------------------------------------------------------
-- 5. The baseline and the drift
-- ---------------------------------------------------------------------------

-- "This recall is the one I accept." Without it, a 0.82 says nothing; with it,
-- it says you lost 15 points since you approved it.
CREATE FUNCTION recall_guard.approve(
    p_index       regclass,
    p_k           int DEFAULT 10,
    p_sample_size int DEFAULT 30,
    p_note        text DEFAULT NULL
) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v_name text;
    r      numeric;
BEGIN
    SELECT index_name INTO v_name FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    r := recall_guard.measure(p_index, p_k, p_sample_size);

    INSERT INTO recall_guard.baselines (index_name, k, sample_size, recall, note)
    VALUES (v_name, p_k, p_sample_size, r, p_note)
    ON CONFLICT (index_name) DO UPDATE
        SET k = EXCLUDED.k, sample_size = EXCLUDED.sample_size,
            recall = EXCLUDED.recall, approved_at = now(), note = EXCLUDED.note;

    RETURN r;
END;
$$;

-- The check to schedule: measures everything approved again and reports the drop.
-- Returns rows instead of writing to the log because a monitor consumes them better.
CREATE FUNCTION recall_guard.check()
RETURNS TABLE (
    index_name text,
    baseline   numeric,
    current    numeric,
    drift      numeric,
    verdict    text
)
LANGUAGE plpgsql AS $$
DECLARE
    b record;
    r numeric;
BEGIN
    FOR b IN SELECT * FROM recall_guard.baselines LOOP
        BEGIN
            r := recall_guard.measure(b.index_name::regclass, b.k, b.sample_size);
        EXCEPTION WHEN OTHERS THEN
            -- An index that can no longer be measured is news, not silence.
            index_name := b.index_name; baseline := b.recall;
            current := NULL; drift := NULL;
            verdict := 'COULD NOT MEASURE: ' || SQLERRM;
            RETURN NEXT;
            CONTINUE;
        END;

        index_name := b.index_name;
        baseline   := b.recall;
        current    := r;
        drift      := round(r - b.recall, 4);
        verdict    := CASE
            WHEN r >= b.recall - 0.02 THEN 'ok'
            WHEN r >= b.recall - 0.10 THEN 'degraded'
            ELSE 'critical'
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION recall_guard.check() IS
    'Measures every approved index again and compares it with its baseline. '
    'Meant to be scheduled with pg_cron: an ANN index degrades gradually '
    'and silently, so the only moment it is detected is when someone looks.';
