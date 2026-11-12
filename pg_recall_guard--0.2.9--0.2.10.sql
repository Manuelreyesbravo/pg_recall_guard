-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_recall_guard 0.2.9 -> 0.2.10
--
-- tsm_system_rows is no longer required. measure() sampled with TABLESAMPLE SYSTEM_ROWS until
-- 0.2.7; since 0.2.8 it draws its sample with ORDER BY random() (thinned first with BERNOULLI,
-- built in, on a large table) and nothing here names system_rows. The control file kept
-- `requires = 'tsm_system_rows'`, so CREATE EXTENSION without CASCADE failed for a dependency
-- the code does not use. The control file no longer requires it; an existing installation
-- keeps the dependency it was created with, and tsm_system_rows can be dropped with
-- DROP EXTENSION tsm_system_rows once nothing else uses it.
--
-- No object changes.

\echo Use "ALTER EXTENSION pg_recall_guard UPDATE TO '0.2.10'" to load this file. \quit
