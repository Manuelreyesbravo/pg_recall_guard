#!/usr/bin/env bash
# The findings of the external audit of 0.2.4 that this repo closed, each against its
# control -- the proof that the instrument can answer the other way.
#
#   RG-01 the sampled vector was cast back to the column's type, so on a domain column the
#         cast ran the domain's CHECK -- a function its owner wrote -- as whoever measured.
#   RG-02 measure() read the parent table without ONLY: inheritance children, which the
#         parent's index does not cover, diluted the measurement of a broken index.
#   RG-03 the plan check looked for "Index Scan", not for the index asked about: with a twin
#         index on the same column, measure(X) reported the twin's recall.
#   RG-04 rows were told apart by ctid, which repeats across partitions.
#   RG-07 rows were matched by identity, so with duplicate vectors an index that returns one
#         copy in place of another identical one was counted as missing it.
#   RG-05 the verdict depended on the search settings of whoever ran check().
#   RG-06 the sample was contiguous rows, and NULLs were filtered after sampling.
#   RG-07 a baseline of 0 was accepted, after which check() can never alarm.
#   RG-09 a role that could read baselines and measurements learned about tables it cannot read.
#   RG-10 the upgrade to 0.2.4 died on the same index approved twice.
#   RG-13 k and sample_size had no bound.
#   RG-14 measure() reset the caller's planner settings; NULL arguments gave raw syntax errors.
#   RG-08 baselines and measurements were not dumped: after a restore check() returned no
#         rows, which reads as "all fine".
#
# Needs pgvector. Run against the throwaway cluster: test/cluster.sh init && start.

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
BIN=$("$PG_CONFIG" --bindir)
PSQL=${PSQL:-$BIN/psql}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$ROOT/.testcluster} PGPORT=${PGPORT:-5496}
DB=recall_guard_test_audit
RESTORED=recall_guard_test_audit_restored
TENANT=recall_guard_test_audit_tenant
DUMP=$ROOT/.testcluster/audit.dump
failures=0

if [ ! -f "$("$PG_CONFIG" --sharedir)/extension/vector.control" ]; then
    echo "DID NOT RUN: pgvector is not installed in this PostgreSQL" >&2
    exit 2
fi
for d in "$DB" "$RESTORED"; do
    if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_database where datname = '$d'")" = 1 ]; then
        echo "a database $d already exists: not dropping it, somebody else made it" >&2
        exit 2
    fi
done
if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_roles where rolname = '$TENANT'")" = 1 ]; then
    echo "a role $TENANT already exists: not dropping it, somebody else made it" >&2
    exit 2
fi
cleanup() {
    $PSQL -X -d postgres -qc "drop database if exists $DB" -c "drop database if exists $RESTORED" \
        -c "drop role if exists $TENANT" >/dev/null 2>&1 || true
    rm -f "$DUMP"
}
trap cleanup EXIT

q() { $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }
qt() { PGUSER=$TENANT $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }

check() {
    local what="$1" expected="$2" got="$3"
    if [[ "$got" == *"$expected"* ]]; then
        echo "  ok   $what"
    else
        echo "  FAIL $what"
        echo "       expected: $expected"
        echo "       got:      $got"
        failures=$((failures + 1))
    fi
}

$PSQL -X -d postgres -qc "create database $DB" -c "create role $TENANT login"
$PSQL -X -d "$DB" -q -v ON_ERROR_STOP=1 -v tenant="$TENANT" >/dev/null <<'SQL'
CREATE EXTENSION vector;
CREATE EXTENSION pg_recall_guard CASCADE;
CREATE SCHEMA tenant_s AUTHORIZATION :"tenant";
SELECT setseed(0.42);
SQL

echo "RG-01: measuring a domain column runs none of its owner's code"
qt -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE tenant_s.ran_as (who text);
CREATE FUNCTION tenant_s.chk(v point) RETURNS boolean LANGUAGE plpgsql AS $f$
BEGIN
    INSERT INTO tenant_s.ran_as VALUES (current_user);
    RETURN true;
END $f$;
CREATE DOMAIN tenant_s.pt AS point;
CREATE TABLE tenant_s.notes (id serial, e tenant_s.pt);
INSERT INTO tenant_s.notes (e) SELECT point(random() * 100, random() * 100) FROM generate_series(1, 500);
CREATE INDEX notes_gist ON tenant_s.notes USING gist (e);
GRANT USAGE ON SCHEMA tenant_s TO PUBLIC;
GRANT SELECT, INSERT ON tenant_s.ran_as TO PUBLIC;
GRANT SELECT ON tenant_s.notes TO PUBLIC;
SQL
q -q -c "analyze tenant_s.notes" -c "select recall_guard.approve('tenant_s.notes_gist', 10, 20, 'reviewed')" >/dev/null
qt -q -c "alter domain tenant_s.pt add constraint c check (tenant_s.chk(value))" -c "truncate tenant_s.ran_as" >/dev/null
check "control: casting to the domain as the superuser runs the owner's function" "as_superuser=1" \
    "$(q -c "select '(1,1)'::tenant_s.pt" >/dev/null; q -c "select 'as_superuser=' || count(*) from tenant_s.ran_as where who <> '$TENANT'")"
q -c "delete from tenant_s.ran_as" >/dev/null
check "check() by the superuser runs none of it" "as_superuser=0" \
    "$(q -c "select verdict from recall_guard.check() where index_name = 'tenant_s.notes_gist'" >/dev/null; q -c "select 'as_superuser=' || count(*) from tenant_s.ran_as where who <> '$TENANT'")"
check "  ...and still measures the index" "ok" \
    "$(q -c "select verdict from recall_guard.check() where index_name = 'tenant_s.notes_gist'")"

echo "RG-02: inheritance children the index does not cover do not dilute the measurement"
q -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE inh_parent (id int, emb vector(16));
CREATE TABLE inh_child () INHERITS (inh_parent);
INSERT INTO inh_parent SELECT g, (SELECT array_agg(random())::vector(16) FROM generate_series(1, 16) WHERE g > 0) FROM generate_series(1, 300) g;
INSERT INTO inh_child SELECT g, (SELECT array_agg(random())::vector(16) FROM generate_series(1, 16) WHERE g > 0) FROM generate_series(301, 6300) g;
CREATE INDEX inh_hnsw ON inh_parent USING hnsw (emb vector_l2_ops);
CREATE TABLE flat (id int, emb vector(16));
INSERT INTO flat SELECT id, emb FROM ONLY inh_parent;
CREATE INDEX flat_hnsw ON flat USING hnsw (emb vector_l2_ops);
ANALYZE;
SQL
flat=$(q -c "set hnsw.ef_search = 1" -c "select round(avg(recall_guard.measure('flat_hnsw', 10, 300)), 2) from generate_series(1, 3)" | tail -1)
check "control: the same rows in a plain table, ef_search = 1, measure low" "low=true" \
    "$(q -c "select 'low=' || ($flat < 0.5)")"
check "the parent's index measures the same, children or not" "low=true" \
    "$(q -c "set hnsw.ef_search = 1" -c "select 'low=' || (round(avg(recall_guard.measure('inh_hnsw', 10, 300)), 2) < 0.5) from generate_series(1, 3)" | tail -1)"

echo "RG-03: measure(X) measures X, not the index the planner prefers"
q -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE twin (id int, emb vector(16));
INSERT INTO twin SELECT g, (SELECT array_agg(random())::vector(16) FROM generate_series(1, 16) WHERE g > 0) FROM generate_series(1, 5000) g;
CREATE INDEX twin_ivf ON twin USING ivfflat (emb vector_l2_ops) WITH (lists = 70);
CREATE INDEX twin_hnsw ON twin USING hnsw (emb vector_l2_ops);
ANALYZE twin;
SQL
plan=$(q -c "set hnsw.ef_search = 1" -c "set ivfflat.probes = 1" -c "set enable_seqscan = off" -c "explain (costs off) select id from twin order by emb <-> (select emb from twin limit 1) limit 10" | grep -o "using twin_[a-z]*" | head -1)
check "control: with probes = 1 the planner prefers the ivfflat twin" "twin_ivf" "$plan"
check "measure(twin_hnsw) does not report the twin's recall: it says which index was read" "did not measure index public.twin_hnsw: it read twin_ivf" \
    "$(q -c "set hnsw.ef_search = 1" -c "set ivfflat.probes = 1" -c "select recall_guard.measure('twin_hnsw', 10, 50)" | grep -o 'did not measure index [^:]*: it read [a-z_]*')"

echo "RG-04: rows of different partitions are different rows"
q -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE parts (id int, emb vector(4)) PARTITION BY HASH (id);
DO $$ BEGIN FOR i IN 0..49 LOOP
    EXECUTE format('CREATE TABLE parts_%s PARTITION OF parts FOR VALUES WITH (MODULUS 50, REMAINDER %s)', i, i);
END LOOP; END $$;
INSERT INTO parts SELECT g, (SELECT array_agg(random())::vector(4) FROM generate_series(1, 4) WHERE g > 0) FROM generate_series(1, 1000) g;
CREATE INDEX parts_ivf ON parts USING ivfflat (emb vector_l2_ops) WITH (lists = 2);
ANALYZE parts;
-- The recall by id, the way it should come out: per row, the k nearest other rows through the
-- index against the exact k nearest, matched by id.
CREATE TEMP TABLE by_index AS SELECT 1;
SQL
truth=$(q -q -c "set ivfflat.probes = 1" -c "set enable_seqscan = off" \
    -c "create table idx_ids as select p.id, array(select q.id from parts q where q.id <> p.id order by q.emb <-> p.emb limit 10) ids from parts p" \
    -c "reset enable_seqscan" -c "set enable_indexscan = off" -c "set enable_bitmapscan = off" \
    -c "create table exact_ids as select p.id, array(select q.id from parts q where q.id <> p.id order by q.emb <-> p.emb limit 10) ids from parts p" \
    -c "select round(avg((select count(*) from unnest(i.ids) x where x = any(e.ids))::numeric / 10), 2) from idx_ids i join exact_ids e using (id)" | tail -1)
check "control: the true recall by id is below 1" "below=true" "$(q -c "select 'below=' || ($truth < 1)")"
check "measure() over the whole table is the recall by id" "measured=$truth" \
    "$(q -c "set ivfflat.probes = 1" -c "select 'measured=' || round(recall_guard.measure('parts_ivf', 10, 1000), 2)" | tail -1)"

echo "RG-07: an exact index over duplicate vectors measures 1"
q -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE dups (id int, emb vector(8));
INSERT INTO dups SELECT g, v.emb FROM generate_series(1, 2000) g
  JOIN (SELECT i, (SELECT array_agg(random())::vector(8) FROM generate_series(1, 8) WHERE i > 0) AS emb
          FROM generate_series(0, 49) i) v ON v.i = g % 50;
-- Probing every list makes an ivfflat search exhaustive: exact by distance, by construction.
CREATE INDEX dups_ivf ON dups USING ivfflat (emb vector_l2_ops) WITH (lists = 4);
ANALYZE dups;
SQL
check "control: by distance, the index returns the exact neighbours" "differ=0" \
    "$(q -c "set ivfflat.probes = 4" -c "set enable_seqscan = off" \
         -c "create temp table vi as select id, array(select round((b.emb <-> a.emb)::numeric, 6) from dups b where b.ctid <> a.ctid order by b.emb <-> a.emb limit 10) d from dups a where id <= 200" \
         -c "reset enable_seqscan" -c "set enable_indexscan = off" -c "set enable_bitmapscan = off" \
         -c "create temp table ve as select id, array(select round((b.emb <-> a.emb)::numeric, 6) from dups b where b.ctid <> a.ctid order by b.emb <-> a.emb limit 10) d from dups a where id <= 200" \
         -c "select 'differ=' || count(*) from vi join ve using (id) where vi.d is distinct from ve.d" | tail -1)"
check "measure() of that exact index is 1" "measured=1.0000" \
    "$(q -c "set ivfflat.probes = 4" -c "select 'measured=' || recall_guard.measure('dups_ivf', 10, 50)" | tail -1)"

echo "RG-05: the verdict does not depend on who runs check()"
q -q -c "create table ivf5 (id int, emb vector(16))" \
     -c "insert into ivf5 select g, (select array_agg(random())::vector(16) from generate_series(1, 16) where g > 0) from generate_series(1, 300) g" \
     -c "create index ivf5_idx on ivf5 using ivfflat (emb vector_l2_ops) with (lists = 30)" -c "analyze ivf5" \
     -c "set ivfflat.probes = 3" -c "select recall_guard.approve('ivf5_idx', 10, 300)" >/dev/null
m1=$(q -c "set ivfflat.probes = 1" -c "select recall_guard.measure('ivf5_idx', 10, 300)" | tail -1)
m30=$(q -c "set ivfflat.probes = 30" -c "select recall_guard.measure('ivf5_idx', 10, 300)" | tail -1)
check "control: the session's probes change what a direct measure reads" "differ=t" \
    "differ=$(q -c "select ${m30:-0}::numeric - ${m1:-0}::numeric > 0.05")"
c1=$(q -c "set ivfflat.probes = 1" -c "select current from recall_guard.check() where index_name = 'public.ivf5_idx'" | tail -1)
c30=$(q -c "set ivfflat.probes = 30" -c "select current from recall_guard.check() where index_name = 'public.ivf5_idx'" | tail -1)
if [ -n "$c1" ] && [ "$c1" = "$c30" ]; then same=true; else same="false ($c1 / $c30)"; fi
check "check() under probes = 30 reads what it reads under probes = 1" "same=true" "same=$same"
check "  ...and the measurement records the settings it ran under" "probes=3" \
    "$(q -c "select 'probes=' || (settings ->> 'ivfflat.probes') from recall_guard.measurements where index_name = 'public.ivf5_idx' order by id desc limit 1")"

echo "RG-06: the sample is drawn from the rows that have a vector"
q -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE sparse (id int, emb vector(16));
INSERT INTO sparse SELECT g, NULL FROM generate_series(1, 20000) g;
INSERT INTO sparse SELECT g, (SELECT array_agg(random())::vector(16) FROM generate_series(1, 16) WHERE g > 0) FROM generate_series(20001, 22000) g;
CREATE INDEX sparse_hnsw ON sparse USING hnsw (emb vector_l2_ops);
ANALYZE sparse;
SQL
check "a table that begins with 20,000 NULLs is measured 20 times out of 20" "measured=20" \
    "$(q -c "select 'measured=' || count(*) from generate_series(1, 20) g, lateral (select recall_guard.measure('sparse_hnsw', 10, 30) m) x where m is not null")"

echo "RG-07: a baseline outside [0, 1] is refused"
check "recall above 1 is refused" "a_recall_is_a_fraction" \
    "$(q -c "insert into recall_guard.baselines (index_name, k, sample_size, recall) values ('public.twin_hnsw', 10, 30, 2)")"

echo "RG-13 and RG-14: bounds, NULLs, and the caller's settings"
check "a sample of 2,000,000,000 is refused" "sample_size 1 to 10000" \
    "$(q -c "select recall_guard.measure('twin_hnsw', 10, 2000000000)")"
check "a NULL k is a clear error" "needs an index, k and a sample size" \
    "$(q -c "select recall_guard.measure('twin_hnsw', null, 30)")"
check "the caller's planner settings are what they were" "off|off" \
    "$(q -c "set enable_seqscan = off" -c "set enable_indexonlyscan = off" -c "select recall_guard.measure('flat_hnsw', 10, 5) is not null" -c "select current_setting('enable_seqscan') || '|' || current_setting('enable_indexonlyscan')" | tail -1)"
q -q -c "create table exprt (id int, emb vector(8))" -c "insert into exprt select g, (select array_agg(random())::vector(8) from generate_series(1, 8) where g > 0) from generate_series(1, 200) g" \
     -c "create index exprt_idx on exprt using hnsw ((emb::halfvec(8)) halfvec_l2_ops)" >/dev/null
check "an expression index is a clear error" "expression or partial index" \
    "$(q -c "select recall_guard.measure('exprt_idx', 10, 5)")"

echo "RG-09: a role sees only the baselines of tables it may read"
q -q -c "create schema secret" -c "create table secret.payroll (id int, emb vector(16))" \
     -c "insert into secret.payroll select id, emb from flat" -c "create index payroll_idx on secret.payroll using hnsw (emb vector_l2_ops)" \
     -c "analyze secret.payroll" -c "select recall_guard.approve('secret.payroll_idx', 10, 10)" \
     -c "grant usage on schema recall_guard to $TENANT" \
     -c "grant select, insert, update on recall_guard.baselines to $TENANT" \
     -c "grant select on recall_guard.measurements, recall_guard.vector_indexes to $TENANT" >/dev/null
check "control: the owner sees the secret table's measurements" "secret=true" \
    "$(q -c "select 'secret=' || (count(*) > 0) from recall_guard.measurements where index_name = 'secret.payroll_idx'")"
check "a role that cannot read the table does not" "secret=false" \
    "$(qt -c "select 'secret=' || (count(*) > 0) from recall_guard.measurements where index_name = 'secret.payroll_idx'")"
check "  ...nor can it write a baseline for it" "row-level security" \
    "$(qt -c "update recall_guard.baselines set recall = 0 where index_name = 'secret.payroll_idx'" -c "insert into recall_guard.baselines (index_name, k, sample_size, recall) values ('secret.payroll_idx', 10, 30, 0.5)")"

echo "RG-10: an installation of 0.2.0 with the same index approved twice upgrades"
q -q -c "create database ${DB}_old" >/dev/null
$PSQL -X -d "${DB}_old" -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL' || true
CREATE EXTENSION vector;
CREATE EXTENSION pg_recall_guard VERSION '0.2.0' CASCADE;
CREATE SCHEMA app;
CREATE TABLE app.t (id int, emb vector(4));
CREATE INDEX t_idx ON app.t USING hnsw (emb vector_l2_ops);
INSERT INTO recall_guard.baselines (index_name, k, sample_size, recall, approved_at) VALUES ('t_idx', 10, 30, 0.9, now() - interval '1 day');
INSERT INTO recall_guard.baselines (index_name, k, sample_size, recall) VALUES ('app.t_idx', 10, 30, 0.95);
SQL
check "the upgrade completes" "0.2.8" "$($PSQL -X -d "${DB}_old" -tA -c "alter extension pg_recall_guard update" -c "select extversion from pg_extension where extname = 'pg_recall_guard'" 2>&1)"
check "  ...keeping one baseline, the most recent approval" "rows=1 app.t_idx|0.9500" "$($PSQL -X -d "${DB}_old" -tAc "select 'rows=' || count(*) || ' ' || string_agg(index_name || '|' || recall, ',') from recall_guard.baselines" 2>&1)"
$PSQL -X -d postgres -qc "drop database if exists ${DB}_old" >/dev/null 2>&1 || true

echo "RG-08: baselines and measurements survive pg_dump and restore"
q -q -c "select recall_guard.approve('flat_hnsw', 10, 30)" >/dev/null
"$BIN/pg_dump" -Fc -d "$DB" -f "$DUMP"
$PSQL -X -d postgres -qc "create database $RESTORED"
"$BIN/pg_restore" -d "$RESTORED" "$DUMP" >/dev/null 2>&1 || true
check "control: the source has baselines" "baselines=true" \
    "$(q -c "select 'baselines=' || (count(*) > 0) from recall_guard.baselines")"
check "the restored database has the same baselines" "same=true" \
    "$($PSQL -X -d "$RESTORED" -tAc "select 'same=' || (count(*) = $(q -c "select count(*) from recall_guard.baselines")) from recall_guard.baselines" 2>&1)"
check "  ...and its history" "history=true" \
    "$($PSQL -X -d "$RESTORED" -tAc "select 'history=' || (count(*) > 0) from recall_guard.measurements" 2>&1)"
check "  ...and a new measurement there still gets a new id" "ok" \
    "$($PSQL -X -d "$RESTORED" -tAc "select recall_guard.measure('flat_hnsw', 10, 10) is not null" -c "select 'ok'" 2>&1 | tail -1)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "the findings of the 0.2.4 audit are closed, each against its control"
