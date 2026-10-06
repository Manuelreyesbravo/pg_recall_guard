# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_recall_guard/). Each
upgrade script (`pg_recall_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

## 0.2.1

No schema change. Adds project governance and legal files (NOTICE, AUTHORS,
SECURITY, CONTRIBUTING, TRADEMARK). The database objects are byte-for-byte those
of 0.2.0; the `0.2.0--0.2.1` upgrade is empty on purpose.

## 0.2.0 and earlier

See the header of each `pg_recall_guard--*--*.sql` upgrade script and the
release notes on PGXN.
