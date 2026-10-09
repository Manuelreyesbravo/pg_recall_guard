# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_recall_guard/). Each
upgrade script (`pg_recall_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

## 0.2.9 -- 2026-10-09

* **The verdicts `check()` returns are English.** A monitor that filters on the old words
  must be updated: `degradado` -> `degraded`, `critico` -> `critical`,
  `NO SE PUDO MEDIR: <error>` -> `COULD NOT MEASURE: <error>`; `ok` stays.
* **An installed database is English throughout.** The comments, messages and object comments
  of the earlier scripts were translated in place after 0.2.8 was released, so an install from
  PGXN still held the Spanish ones. The 0.2.8 -> 0.2.9 script restates every function and
  object comment: an upgraded install matches a fresh one. No object is added or removed.
* `make installcheck-vector` failed since 0.2.8: it degraded the index with a session `SET`,
  which no longer changes the verdict. It now rebuilds a second index with `m = 2` and keeps the
  healthy one as its control (`ok` and `critical` in the same `check()`).

## 0.2.8 -- 2026-10-09

The Medium and Low findings of the external audit of 0.2.4 left open, each measured on 0.2.7
first (`test/audit.sh`: every tooth red there with its control green).

* **RG-05: the verdict no longer depends on who runs `check()`.** `approve()` records the search
  settings and `check()` measures under them; each measurement records its settings. Measured:
  under `ivfflat.probes = 30` and `= 1` the same baseline read different values; now the same.
* **RG-06: a random sample of the rows that have a vector.** A table that began with 20,000 NULLs
  gave an empty sample 39 times out of 40; 20 out of 20 now.
* **RG-07:** a recall outside [0, 1] is refused, and approving one below 0.5 warns.
* **RG-09:** `baselines` and `measurements` show a role only the rows of indexes on tables it may
  read, and it cannot write one for another.
* **RG-10:** the 0.2.3 -> 0.2.4 script, which an installation still on 0.2.0 runs, no longer dies
  on the same index approved twice: the most recent approval stays.
* **RG-11:** a temporary index cannot be approved. A baseline is still bound to the index's name
  (README).
* **RG-13:** `k` is 1 to 1000, `sample_size` 1 to 10,000.
* **RG-14:** the caller's planner settings are restored, not reset; NULL arguments and expression
  or partial indexes give clear errors; the plan is read by node type.
* RG-12 (the lock `check()` holds) and RG-15 (README contradictions): README.
* The regression tests that degraded an index with a session `SET` now degrade it for real (an
  index rebuilt with `m = 2`), since a `SET` no longer changes the verdict. RG-07's tooth uses an
  exhaustive ivfflat, exact by construction on every PostgreSQL.

## 0.2.7 -- 2026-10-09

* **Recall is judged by distance, ties included (RG-07).** It was computed by row identity,
  so with duplicate vectors an index that returned one copy in place of another identical
  copy was counted as missing it: an index exact by distance over 50 vectors stored 40
  times measured 0.3878 (`test/audit.sh`, red on 0.2.6 with its control green). Found in a
  real database too: an index over 22 rows, 10 of them distinct, read `degraded` for a week
  while returning exactly the right distances. A returned neighbour is now a hit if it is
  no farther than the k-th exact one. Without duplicates the number does not change. A
  baseline approved over duplicates was approved low; re-approving it records the real one.

## 0.2.6 -- 2026-10-09

From an external audit of 0.2.4, each finding measured on 0.2.5 before it was changed
(`test/audit.sh`, `make check-audit`, in `make check-suites`: every tooth red on 0.2.5
with its control green).

* **RG-01: measuring a domain column runs none of its owner's code.** The sampled vector
  was cast back to the column's type, and on a domain that cast ran the domain's
  `CHECK` -- a function its owner wrote, which can be added after approval -- as whoever
  measured, usually a superuser's cron (measured: it ran, and the verdict said `ok`). It
  is cast to the domain's base type now.
* **RG-02: inheritance children do not dilute the measurement.** A plain table is read
  with `ONLY`: an unindexed child turned a parent index that measures 0.00 into 0.97.
* **RG-03: `measure(X)` measures X.** Any `Index Scan` passed the plan check, so with a
  twin index on the same column the twin's recall was reported. Every relation the plan
  reads must now be read through X or one of its partition indexes; otherwise the
  measurement fails and names the index the planner chose. **Behaviour change:** a
  baseline whose index the planner does not choose -- a twin it prefers exists -- is
  now `COULD NOT MEASURE`, where it used to report the twin's recall.
* **RG-04: rows of different partitions are different rows.** Rows are `(tableoid,
  ctid)`: by `ctid` alone a partitioned index measured 0.97 where its recall by id is
  0.95. `evaluate_query()` takes the sampled row's table as a fifth, optional argument.
* **RG-08: baselines and measurements survive `pg_dump`.** Both tables and the
  measurements sequence are extension configuration; after a restore `check()` returned
  no rows, which reads as "all fine".

## 0.2.5 -- 2026-10-08

* **Metadata only.** The PGXN description is two sentences now; the longer
  explanation it carried is in this README. No code changed: the upgrade
  script 0.2.4 -> 0.2.5 changes no object.

## 0.2.4 -- 2026-10-08

* **A baseline measures the index it approved, from any session.** Up to 0.2.3
  the index name was stored the way `regclass::text` printed it in the approving
  session -- unqualified when its schema was on that session's `search_path` -- and
  `check()` resolved it again under the checking session's path, where PostgreSQL
  searches `pg_temp` first. A temporary index with the approved name was measured
  instead of the real one (a degraded index came back `ok`), and an index outside
  `public` could not be found from pg_cron's session (`COULD NOT MEASURE`).
* `vector_indexes.index_name` is now always `schema.name`; filters on it need the
  schema (`index_name = 'public.items_hnsw'`).
* Every function runs with `search_path = pg_catalog, pg_temp`; the `TABLESAMPLE`
  method is named in the schema `tsm_system_rows` was installed into.
* The upgrade qualifies stored names that match exactly one vector index, and
  leaves -- with a WARNING -- any name it would have to guess.
* `test/pg_temp.sh` (`make check-pgtemp`, needs pgvector): red on 0.2.3, green on
  0.2.4, PostgreSQL 18.6 and 19beta2.

## 0.2.3 -- 2026-10-06

* **License: Apache License 2.0**, replacing the PostgreSQL License, from this
  release on. Every version up to and including 0.2.2, already published,
  stays under the PostgreSQL License it was released with. No code changed.

## 0.2.2

Completes the copyright and licensing files: the copyright holder's full legal
name in LICENSE and README, and a per-file SPDX header on every SQL source
file. No schema change.

## 0.2.1

No schema change. Adds project governance and legal files (NOTICE, AUTHORS,
SECURITY, CONTRIBUTING, TRADEMARK). The database objects are byte-for-byte those
of 0.2.0; the `0.2.0--0.2.1` upgrade is empty on purpose.

## 0.2.0 and earlier

See the header of each `pg_recall_guard--*--*.sql` upgrade script and the
release notes on PGXN.
