# Security

## Reporting a vulnerability

**Do not open a public issue.** Report it privately, by either:

* GitHub's private vulnerability reporting: the **Security** tab of this
  repository, then **Report a vulnerability**; or
* email to **manuelreyesbravo@gmail.com**, subject starting with
  `[pg_recall_guard security]`.

Please include the PostgreSQL version, the pg_recall_guard version (`SELECT
extversion FROM pg_extension WHERE extname = 'pg_recall_guard'`), and the
smallest sequence of statements that shows it. A case in the style of
`test/sql/*.sql` is ideal, because it becomes a regression test.

You will get an acknowledgement within 72 hours. A confirmed issue is fixed
before it is disclosed, gets a regression case, and is credited to you in the
CHANGELOG unless you prefer otherwise.

## What counts

This extension records a recall baseline you approve for a vector index and
reports when live recall has drifted below it. The report this project most
wants is a way to make it answer that recall is fine when it has in fact
dropped, or a way for a role to read, store or alter a baseline or the recorded
history it should not be able to.

## Supported versions

The latest release. Fixes are not backported while the project is pre-1.0.
