-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_recall_guard 0.1.0 -> 0.2.0
--
-- 0.2.0 does not change the code: it adds the test suite (make installcheck,
-- green on PostgreSQL 18.6 and 19beta2) and with it goes from 'testing' to 'stable'.
-- The script exists anyway because 0.1.0 was published and someone may have it
-- installed: without it, their ALTER EXTENSION ... UPDATE fails.
--
-- The object comments of 0.1.0 were in Spanish. They were translated in every script
-- after 0.2.8 was released, and are set here too, so that an install upgraded from
-- 0.1.0 matches a fresh one.
\echo Use "ALTER EXTENSION pg_recall_guard UPDATE TO '0.2.0'" to load this file. \quit

COMMENT ON VIEW recall_guard.vector_indexes IS
    'Indexes that answer ORDER BY by a distance operator, found through the catalog. '
    'Names no extension: works for pgvector, pgvectorscale, VectorChord or whatever comes next.';

COMMENT ON TABLE recall_guard.baselines IS
    'The recall the owner accepted as good. Without a baseline there is no drift to measure: '
    '"0.82" says nothing, "0.82 where you approved 0.97" says it all.';

COMMENT ON FUNCTION recall_guard.check() IS
    'Measures every approved index again and compares it with its baseline. '
    'Meant to be scheduled with pg_cron: an ANN index degrades gradually '
    'and silently, so the only moment it is detected is when someone looks.';
