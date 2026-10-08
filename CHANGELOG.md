# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_recall_guard/). Each
upgrade script (`pg_recall_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

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
