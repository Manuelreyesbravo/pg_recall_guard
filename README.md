# pg_recall_guard

[![CI](https://github.com/Manuelreyesbravo/pg_recall_guard/actions/workflows/ci.yml/badge.svg)](https://github.com/Manuelreyesbravo/pg_recall_guard/actions/workflows/ci.yml)

**Watch vector indexes for recall drift against a baseline you approved.**

A degraded ANN index does not fail. It returns *k* plausible neighbours and never
mentions that four of the ten good ones were left out. No error, no log entry, no
alert — you find out when a user tells you the search "feels worse", or when you
happen to run a benchmark months later.

This extension measures the recall of any vector index against exact ground truth,
records the number you accepted as good, and tells you when it drifts.

```sql
CREATE EXTENSION pg_recall_guard;

-- What can be measured? Discovered from the catalog, no configuration.
SELECT index_name, table_name, access_method, operator
  FROM recall_guard.vector_indexes;

--  index_name | table_name | access_method | operator
-- ------------+------------+---------------+----------
--  items_hnsw | items      | hnsw          | <=>
--  docs_dann  | docs       | diskann       | <=>

-- Record what you consider good.
SELECT recall_guard.approve('items_hnsw', p_k => 10, p_sample_size => 100);

-- Later — from pg_cron, from your monitoring, from a shell:
SELECT * FROM recall_guard.check();

--  index_name | baseline | current |  drift  | verdict
-- ------------+----------+---------+---------+---------
--  items_hnsw |   0.9800 |  0.8100 | -0.1700 | critico
```

## Works with any vector index, because it never names one

Indexes are found through `pg_amop.amoppurpose = 'o'` — access methods that can
answer an `ORDER BY` on a distance operator. That is a PostgreSQL property, not an
extension's. Today it covers **hnsw** and **ivfflat** (pgvector), **diskann**
(pgvectorscale), **gist** and **spgist**; tomorrow it covers whatever ships next,
with no change here.

Verified on PostgreSQL 19beta2 against pgvector 0.8.6 and pgvectorscale 0.9.0, over
38,352 `vector(768)` rows:

| `hnsw.ef_search` | measured recall |
|---|---|
| 1 | 0.0000 |
| 10 | 0.9000 |
| 40 (default) | 1.0000 |

## It is built so it cannot flatter itself

Two failure modes would produce a reassuring `1.0000` that means nothing. Both are
checked rather than assumed:

- **The indexed side must actually use the index.** If the planner ignores it, the
  measurement compares the index against itself and always scores perfect. The plan
  is inspected and the function raises instead of returning a number.
- **The ground truth must not use it.** Same reasoning, other direction.

There is a third trap that is easy to miss. Sample queries are drawn from rows of
the table itself, and a stored vector always finds *itself* at distance zero — a
free hit in every single query, which with `k = 10` means recall can never drop
below `0.1` no matter how broken the index is. `pg_recall_guard` asks for `k+1`
neighbours and discards the originating `ctid` from both sides. That is the
difference between measuring the index and measuring that a vector equals itself:
at `ef_search = 1` the naive version reports `0.1000`, this one reports `0.0000`.

## Cost

`check()` runs one exact sequential scan per sampled query, so it is not free and
it is not meant to run on every request. It is meant to run on a schedule, on a
sample, the way you would run `ANALYZE` — the degradation it looks for is gradual
and silent, so the only moment it gets caught is when something bothers to look.

Start with `p_sample_size => 30` and raise it if the numbers move around between
runs.

## Tested on

Measured on 2026-09-16, not assumed: `make installcheck` was run against each
of these releases, every one in a container of the official image for that
version (19beta2 is a local build).

| 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 |
|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  |

Every release still receiving updates, and three that are not.

## Install

```sh
pgxn install pg_recall_guard
```


Or from source:

```sh
make install    # or: make PG_CONFIG=/path/to/pg_config install
```

Then, in the database you want to watch:

```sql
CREATE EXTENSION pg_recall_guard CASCADE;
```

The `CASCADE` pulls in `tsm_system_rows` (PostgreSQL contrib), which `measure()`
uses to sample query vectors. Without it, `CREATE EXTENSION` fails immediately and
tells you so — rather than installing cleanly and failing at the first
measurement.

## Prior art, and where this differs

VectorChord 0.5 added `vchordrq_evaluate_query_recall` and query sampling — a good
design, and this extension borrows the shape of it. But by their own documentation
it is *"not supported by vchordg"*: it works for their IVF+RaBitQ index only. That
is a rational choice for a vendor and a gap for everyone else, since each vector
extension has an incentive to measure its own index and none has an incentive to
measure the others'.

`pg_recall_guard` is the neutral version: it belongs to no index, so it can watch
all of them.

## Tests

```sh
make installcheck            # no vector extension required
make installcheck-vector     # end-to-end, requires pgvector
```

They are split on purpose. `installcheck` covers what must hold on any PostgreSQL
— the extension loads, discovery invents nothing, and pointing it at a plain btree
fails with a message that says where to look. `installcheck-vector` builds a real
HNSW index and asserts the thing that matters: that **recall collapses when the
index is throttled**. If it did not, the tool would not be measuring anything and
every other number it prints would be decorative.

Assertions are ranges, not exact values, because `measure()` samples queries at
random — a test demanding `0.9000` would fail every few runs, and a test that
fails for reasons that are not failures gets ignored.

`installcheck` is green on **PostgreSQL 18.6 and 19beta2**, with the same expected
output on both. Earlier versions are not tested: `META.json` claims 13 as the
minimum because nothing in the SQL is newer than 9.5 (`TABLESAMPLE`,
`tsm_system_rows`, `ON CONFLICT`, `EXPLAIN (FORMAT JSON)`, `format()` with
`%I`/`%L`), but that is reasoning from the source, not a passing test. If you run
it on 13–17, a report either way is welcome.

## Maturity

**0.2.0, released as `stable`** — the test suite is what earned the label, not
time in the field. What that means concretely: the mechanism is tested, including
the assertion that recall *collapses* when an index is throttled, and it is green
on two PostgreSQL versions with identical expected output.

What it does **not** mean, and is worth knowing before you rely on it:

- The performance figures above come from **one machine and one dataset** (38,352
  vectors, 768 dimensions), on `hnsw` and `diskann`. Other dimensions, `m` and
  `ef_search` values are untested.
- **PostgreSQL 13–17 are untested.** Green on 18.6 and 19beta2.
- **Nobody has run this against a production workload.** The 0.1.0 release was
  `testing`, which meant `pgxn install` skipped it by default and nobody could
  find it — so field reports had no way of arriving. That is the main reason this
  release is `stable`.
- The sampling strategy — drawing query vectors from rows of the table — is a
  reasonable proxy for real traffic, not real traffic. Capturing actual queries
  needs an executor hook in C, which this does not have.

Treat the recall numbers it reports as trustworthy and its coverage as narrow.
Reports from other datasets, dimensions and index parameters are the single most
useful thing anyone could send.

## License

PostgreSQL License -- see [LICENSE](LICENSE). Copyright 2026 Manuel Reyes Bravo.

The name is not licensed with the code: see [TRADEMARK.md](TRADEMARK.md).
