-- Tests that depend on no vector extension, so they run on any PostgreSQL. They
-- cover what must hold even when the user has no pgvector installed: that the
-- extension loads, that discovery does not invent indexes, and that errors
-- teach instead of returning a number.

-- Without this, the CONTEXT of each error carries the line number in the plpgsql
-- function ("line 19 at RAISE") and the test breaks every time someone edits the
-- SQL, even when the behaviour is identical. A test that fails for reasons that
-- are not failures ends up ignored.
\set SHOW_CONTEXT never

CREATE EXTENSION IF NOT EXISTS pg_recall_guard CASCADE;

-- The view exists and does not break in a database without vector indexes.
SELECT count(*) >= 0 AS view_answers FROM recall_guard.vector_indexes;

-- The state tables exist and start empty.
SELECT count(*) AS baselines FROM recall_guard.baselines;
SELECT count(*) AS measurements FROM recall_guard.measurements;

-- check() with nothing approved returns zero rows, not an error.
SELECT count(*) AS checks FROM recall_guard.check();

-- An index that does NOT order by a distance operator must be refused with a
-- message that says where to look. It is the most likely misuse: someone points
-- the tool at any btree.
CREATE TABLE rg_t (id int PRIMARY KEY, txt text);
CREATE INDEX rg_btree ON rg_t (txt);

\set ON_ERROR_STOP off
SELECT recall_guard.evaluate_query('rg_btree'::regclass, '[1,2,3]', 10);
SELECT recall_guard.measure('rg_btree'::regclass, 10, 5);
\set ON_ERROR_STOP on

-- Nor may a btree show up in discovery.
SELECT count(*) AS btree_discovered
  FROM recall_guard.vector_indexes WHERE index_name = 'public.rg_btree';

DROP TABLE rg_t;
