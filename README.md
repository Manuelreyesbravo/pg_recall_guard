# pg_recall_guard

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

## Install

```sh
pgxn install --testing pg_recall_guard
```

The `--testing` is required: `pgxn install` looks for the latest **stable**
release by default, and this one is released as `testing` on purpose (see
[Maturity](#maturity)). The flag will stop being necessary when a stable release
exists.

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

## Maturity

**0.1.0, released as `testing`.** The mechanism is verified and the numbers above
are real, but they come from one machine, one dataset of 38,352 vectors, two index
types and a single PostgreSQL version (19beta2). Nobody has run this against a
production workload yet, and the sampling strategy — drawing query vectors from
rows of the table — is a reasonable proxy for real traffic, not real traffic.

Treat the recall numbers it reports as trustworthy and its coverage as unproven.
Reports from other datasets, dimensions and index parameters are the most useful
thing anyone could send.

## License

PostgreSQL License.
