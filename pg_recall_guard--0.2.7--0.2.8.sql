-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_recall_guard 0.2.7 -> 0.2.8
--
-- The Medium and Low findings of the external audit of 0.2.4 left open, each measured on 0.2.7
-- first (test/audit.sh: every tooth red there with its control green).
--
--   * RG-05: the verdict depended on the search settings of whoever ran check(): a role whose
--     ivfflat.probes was 70 read ok on an index the cron, at 2, read critico. approve() records the
--     index's search settings (hnsw.*, ivfflat.*, diskann.*) with the baseline, and check() measures
--     under them; every measurement records the settings it ran under.
--   * RG-06: TABLESAMPLE SYSTEM_ROWS returns contiguous rows, and the NULL filter ran after it: one
--     run sampled the old cluster (1.0) and the next the new one (0.32), and a table that began
--     with 20,000 NULLs gave an empty sample 39 times out of 40. Rows are now drawn at random from
--     the non-NULL ones.
--   * RG-07: approve() accepted a baseline of 0, after which check() can never alarm. A recall
--     outside [0, 1] is refused, and approving one below 0.5 warns.
--   * RG-09: whoever could read baselines and measurements learned the row count and index size of
--     tables it cannot read. Both tables now show a role only the rows of indexes on tables it may
--     read (row level security; the owner, and so pg_dump, see all).
--   * RG-11: approve() of a temporary index stored a baseline that outlives the session. Refused.
--     A baseline is still bound to the index's name, not its identity (see README).
--   * RG-13: k and sample_size had no bound: a sample of 2,000,000,000 ran a seq scan per row.
--     k is 1 to 1000, sample_size 1 to 10,000.
--   * RG-14: measure() RESET the planner settings it changed, undoing the caller's own values; a
--     NULL argument gave a raw syntax error; an expression index gave one too. Fixed, and the plan
--     check reads node types, not a substring a table named "Index Scan" could contain.

\echo Use "ALTER EXTENSION pg_recall_guard UPDATE TO '0.2.8'" to load this file. \quit

ALTER TABLE recall_guard.baselines ADD COLUMN settings jsonb;
ALTER TABLE recall_guard.measurements ADD COLUMN settings jsonb;
ALTER TABLE recall_guard.baselines
    ADD CONSTRAINT a_recall_is_a_fraction CHECK (recall >= 0 AND recall <= 1) NOT VALID;
DO $$
BEGIN
    ALTER TABLE recall_guard.baselines VALIDATE CONSTRAINT a_recall_is_a_fraction;
EXCEPTION WHEN check_violation THEN
    RAISE WARNING 'pg_recall_guard: a baseline outside [0, 1] exists; it stays, and new ones are refused';
END $$;

-- The search settings of the vector index access methods, as this session has them.
CREATE FUNCTION recall_guard._search_settings()
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $f$
    SELECT coalesce(jsonb_object_agg(name, setting ORDER BY name), '{}')
      FROM pg_settings WHERE name ~ '^(hnsw|ivfflat|diskann)\.';
$f$;

-- Whether the current role may read the table an index (named as baselines name it) is on.
CREATE FUNCTION recall_guard._can_read_index(p_index_name text)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $f$
    -- By the catalog, not to_regclass(): that one raises for a schema the role may not use.
    SELECT coalesce((SELECT has_schema_privilege(n.oid, 'USAGE') AND has_table_privilege(i.indrelid, 'SELECT')
                       FROM pg_index i
                       JOIN pg_class c ON c.oid = i.indexrelid
                       JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE pg_catalog.format('%I.%I', n.nspname, c.relname) = p_index_name), false);
$f$;

ALTER TABLE recall_guard.baselines ENABLE ROW LEVEL SECURITY;
ALTER TABLE recall_guard.measurements ENABLE ROW LEVEL SECURITY;
CREATE POLICY only_readable_indexes ON recall_guard.baselines
    USING (recall_guard._can_read_index(index_name)) WITH CHECK (recall_guard._can_read_index(index_name));
CREATE POLICY only_readable_indexes ON recall_guard.measurements
    USING (recall_guard._can_read_index(index_name)) WITH CHECK (recall_guard._can_read_index(index_name));

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
    prev_seq   text := pg_catalog.current_setting('enable_seqscan');
    prev_bmp   text := pg_catalog.current_setting('enable_bitmapscan');
    prev_idx   text := pg_catalog.current_setting('enable_indexscan');
    prev_ios   text := pg_catalog.current_setting('enable_indexonlyscan');
    family     text[];
    used       text[];
    v_from     text;
    v_limit    int;
    kth        float8;
    hits       int;
    n_exact    int;
BEGIN
    -- If the query comes from a row of the table, that row finds itself at distance 0
    -- and gives away a hit in every query. One more is asked for
    -- and the row itself is dropped from both sides.
    v_limit := p_k + CASE WHEN p_exclude IS NULL THEN 0 ELSE 1 END;
    IF p_index IS NULL OR p_vector IS NULL OR p_k IS NULL THEN
        RAISE EXCEPTION 'pg_recall_guard: evaluate_query needs an index, a vector and k';
    END IF;
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % is not an index with an ordering operator', p_index
            USING HINT = 'See recall_guard.vector_indexes for the ones that are.';
    END IF;
    -- What cannot be measured says so (0.2.8): an expression index has no column to compare
    -- against, and a partial index answers only the queries its predicate covers.
    IF EXISTS (SELECT 1 FROM pg_index i WHERE i.indexrelid = p_index AND (i.indkey[0] = 0 OR i.indpred IS NOT NULL)) THEN
        RAISE EXCEPTION 'pg_recall_guard: % is an expression or partial index, which this cannot measure', v.index_name;
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

    -- Indexed side: force the index and CHECK that it was used -- this index, no other (0.2.6).
    PERFORM set_config('enable_seqscan', 'off', true);
    PERFORM set_config('enable_bitmapscan', 'off', true);
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
    EXECUTE q_indexed INTO rows_idx, dist_idx;
    -- The caller's values back (0.2.8), not the defaults: RESET undid even a SET LOCAL of theirs.
    PERFORM set_config('enable_seqscan', prev_seq, true);
    PERFORM set_config('enable_bitmapscan', prev_bmp, true);

    -- Ground truth: forbid every index access and CHECK that none was used.
    PERFORM set_config('enable_seqscan', 'on', true);
    PERFORM set_config('enable_indexscan', 'off', true);
    PERFORM set_config('enable_bitmapscan', 'off', true);
    PERFORM set_config('enable_indexonlyscan', 'off', true);
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || q_exact INTO plan_txt;
    IF plan_txt ~ '"Node Type": "Index (Only )?Scan"' THEN
        RAISE EXCEPTION 'pg_recall_guard: could not get an exact ground truth for %', v.index_name
            USING DETAIL = plan_txt,
                  HINT   = 'The planner kept the index despite enable_*=off.';
    END IF;
    EXECUTE q_exact INTO rows_exact, dist_exact;
    PERFORM set_config('enable_seqscan', prev_seq, true);
    PERFORM set_config('enable_indexscan', prev_idx, true);
    PERFORM set_config('enable_bitmapscan', prev_bmp, true);
    PERFORM set_config('enable_indexonlyscan', prev_ios, true);

    -- Drop the self-match from both sides, and only then cut to k.
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
        RAISE EXCEPTION 'pg_recall_guard: the ground truth came back empty for %', v.index_name;
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

CREATE OR REPLACE FUNCTION recall_guard.measure(p_index regclass, p_k integer DEFAULT 10, p_sample_size integer DEFAULT 30)
RETURNS numeric
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v        record;
    v_from   text;
    est      real;
    sampling text := '';
    toids    oid[];
    ctids    tid[];
    vecs     text[];
    total    numeric := 0;
    n        int     := 0;
    r        numeric;
BEGIN
    -- Bounded, and a clear word for a NULL (0.2.8).
    IF p_index IS NULL OR p_k IS NULL OR p_sample_size IS NULL THEN
        RAISE EXCEPTION 'pg_recall_guard: measure needs an index, k and a sample size';
    END IF;
    IF p_k NOT BETWEEN 1 AND 1000 OR p_sample_size NOT BETWEEN 1 AND 10000 THEN
        RAISE EXCEPTION 'pg_recall_guard: k must be 1 to 1000 and sample_size 1 to 10000 (got % and %)', p_k, p_sample_size;
    END IF;
    SELECT * INTO v FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_recall_guard: % is not a vector index', p_index;
    END IF;

    SELECT CASE WHEN t.relkind = 'p' THEN format('%I.%I', v.schema_name, v.table_name)
                ELSE format('ONLY %I.%I', v.schema_name, v.table_name) END,
           t.reltuples
      INTO v_from, est
      FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid WHERE i.indexrelid = p_index;

    -- At random, among the rows that have a vector (0.2.8). SYSTEM_ROWS took contiguous rows and
    -- filtered NULLs after: a sample was one cluster, or empty. A large table is thinned with
    -- BERNOULLI first, four times the sample; if that comes back short, the whole table is drawn.
    IF est > 50000 THEN
        sampling := format('TABLESAMPLE BERNOULLI (%s)', least(100, greatest(0.001, 400.0 * p_sample_size / est)));
    END IF;
    LOOP
        EXECUTE format(
            'SELECT array_agg(o), array_agg(c), array_agg(x) FROM ('
            'SELECT tableoid AS o, ctid AS c, %I::text AS x FROM %s %s WHERE %I IS NOT NULL '
            'ORDER BY random() LIMIT %s) s',
            v.column_name, v_from, sampling, v.column_name, p_sample_size)
          INTO toids, ctids, vecs;
        EXIT WHEN sampling = '' OR coalesce(cardinality(vecs), 0) >= p_sample_size;
        sampling := '';
    END LOOP;

    FOR i IN 1 .. coalesce(cardinality(vecs), 0) LOOP
        r := recall_guard.evaluate_query(p_index, vecs[i], p_k, ctids[i], toids[i]);
        total := total + r;
        n := n + 1;
    END LOOP;

    IF n = 0 THEN
        RAISE EXCEPTION 'pg_recall_guard: the sample came back empty for %', v.index_name
            USING HINT = 'Does the table have rows where that column is not null?';
    END IF;

    INSERT INTO recall_guard.measurements (index_name, k, sample_size, recall, index_bytes, settings)
    VALUES (v.index_name, p_k, n, round(total / n, 4), v.index_bytes, recall_guard._search_settings());

    RETURN round(total / n, 4);
END;
$$;

CREATE OR REPLACE FUNCTION recall_guard.approve(p_index regclass, p_k integer DEFAULT 10, p_sample_size integer DEFAULT 30, p_note text DEFAULT NULL)
RETURNS numeric
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_name   text;
    v_schema text;
    r        numeric;
BEGIN
    SELECT index_name, schema_name INTO v_name, v_schema FROM recall_guard.vector_indexes WHERE index_oid = p_index;
    -- A temporary index ends with its session; its baseline would outlive it (0.2.8).
    IF v_schema LIKE 'pg\_temp\_%' THEN
        RAISE EXCEPTION 'pg_recall_guard: % is a temporary index: it ends with this session, a baseline does not', v_name;
    END IF;
    r := recall_guard.measure(p_index, p_k, p_sample_size);
    -- A baseline near zero cannot alarm (0.2.8, RG-07): check() reads ok down to it.
    IF r < 0.5 THEN
        RAISE WARNING 'pg_recall_guard: approving a recall of % for %: check() alarms only below it', r, v_name;
    END IF;

    INSERT INTO recall_guard.baselines (index_name, k, sample_size, recall, note, settings)
    VALUES (v_name, p_k, p_sample_size, r, p_note, recall_guard._search_settings())
    ON CONFLICT (index_name) DO UPDATE
        SET k = EXCLUDED.k, sample_size = EXCLUDED.sample_size,
            recall = EXCLUDED.recall, approved_at = now(), note = EXCLUDED.note,
            settings = EXCLUDED.settings;

    RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION recall_guard."check"()
RETURNS TABLE(index_name text, baseline numeric, current numeric, drift numeric, verdict text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    b    record;
    r    numeric;
    s    record;
    prev jsonb;
BEGIN
    FOR b IN SELECT * FROM recall_guard.baselines LOOP
        -- Under the search settings the baseline was approved with (0.2.8): otherwise the verdict
        -- is whatever the caller's session happens to have. The caller's values come back after.
        prev := '{}';
        FOR s IN SELECT key, value FROM jsonb_each_text(coalesce(b.settings, '{}')) LOOP
            prev := prev || jsonb_build_object(s.key, current_setting(s.key, true));
            PERFORM set_config(s.key, s.value, true);
        END LOOP;
        BEGIN
            r := recall_guard.measure(b.index_name::regclass, b.k, b.sample_size);
        EXCEPTION WHEN OTHERS THEN
            r := NULL;
            index_name := b.index_name; baseline := b.recall;
            current := NULL; drift := NULL;
            verdict := 'NO SE PUDO MEDIR: ' || SQLERRM;
        END;
        FOR s IN SELECT key, value FROM jsonb_each_text(prev) LOOP
            IF s.value IS NOT NULL THEN
                PERFORM set_config(s.key, s.value, true);
            END IF;
        END LOOP;
        IF r IS NULL THEN
            RETURN NEXT;
            CONTINUE;
        END IF;

        index_name := b.index_name;
        baseline   := b.recall;
        current    := r;
        drift      := round(r - b.recall, 4);
        verdict    := CASE
            WHEN r >= b.recall - 0.02 THEN 'ok'
            WHEN r >= b.recall - 0.10 THEN 'degradado'
            ELSE 'critico'
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION recall_guard._search_settings() FROM PUBLIC;
