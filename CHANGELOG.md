# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_recall_guard/). Each
upgrade script (`pg_recall_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

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
  now `NO SE PUDO MEDIR`, where it used to report the twin's recall.
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
  `public` could not be found from pg_cron's session (`NO SE PUDO MEDIR`).
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
