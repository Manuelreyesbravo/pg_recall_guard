-- End-to-end test with a real vector index. It NEEDS pgvector, which is why it
-- runs in `make installcheck-vector` and not in `make installcheck`.
--
-- The assertions are on a RANGE, not an exact value: measure() samples queries at
-- random, so a test that demanded "0.9000" would fail every so many runs. A test
-- that fails now and then ends up ignored, and an ignored test protects nothing.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_recall_guard CASCADE;

-- A small corpus, but enough for HNSW to have to choose: 2,000 vectors of 32
-- dimensions, deterministic (setseed) so that the index is the same on every run.
SELECT setseed(0.42);
CREATE TABLE rg_items (id serial PRIMARY KEY, embedding vector(32));
INSERT INTO rg_items (embedding)
SELECT array_agg(random())::vector(32)
  FROM generate_series(1, 2000) g, generate_series(1, 32) d
 GROUP BY g;

CREATE INDEX rg_items_hnsw ON rg_items USING hnsw (embedding vector_cosine_ops);
ANALYZE rg_items;

-- 1. Discovery finds it, with its access method and its operator.
SELECT table_name, access_method, operator, column_name
  FROM recall_guard.vector_indexes WHERE index_name = 'public.rg_items_hnsw';

-- 2. With the index healthy the recall is high.
SET hnsw.ef_search = 100;
SELECT recall_guard.measure('rg_items_hnsw'::regclass, 10, 10) >= 0.90 AS healthy_is_high;

-- 3. And with the index throttled it COLLAPSES. This is the assertion that really
--    matters: if the recall did not drop, the tool would be measuring nothing and
--    every other number would be decorative.
SET hnsw.ef_search = 1;
SELECT recall_guard.measure('rg_items_hnsw'::regclass, 10, 10) < 0.50 AS broken_collapses;

-- 4. The self-match cannot hold up the floor: with ef_search=1 the recall has to
--    be able to reach zero. Before the source ctid was dropped it gave exactly
--    0.1000 (=1/10), the vector finding itself.
SELECT recall_guard.measure('rg_items_hnsw'::regclass, 10, 10) < 0.10 AS no_artificial_floor;

-- 5. Every measurement is recorded.
SELECT count(*) >= 3 AS measurements_kept
  FROM recall_guard.measurements WHERE index_name = 'public.rg_items_hnsw';

-- 6. The full cycle: approve healthy, degrade, and check() calls it `critico`.
SET hnsw.ef_search = 100;
SELECT recall_guard.approve('rg_items_hnsw'::regclass, 10, 10, 'test') >= 0.90 AS baseline_high;

SET hnsw.ef_search = 1;
SELECT index_name, baseline >= 0.90 AS baseline_high, current < 0.50 AS low, verdict
  FROM recall_guard.check();

RESET hnsw.ef_search;
DROP TABLE rg_items CASCADE;
