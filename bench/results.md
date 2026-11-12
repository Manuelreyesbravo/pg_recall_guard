# bench/ef_search.sh results

What `measure()` reports for one hnsw index as `hnsw.ef_search` changes. Method: the script
generates 20,000 `vector(64)` rows, uniform in [-1, 1], from `setseed(0.42)`; builds an hnsw
index (`vector_cosine_ops`, default `m` 16 and `ef_construction` 64); then, for each
`ef_search`, runs `measure('items_hnsw', 10, 100)` three times (k = 10, 100 query vectors drawn
at random from the table, so the three runs differ).

- Date: 2026-11-12
- Code: pg_recall_guard 0.2.9 (`measure()` is unchanged in 0.2.10); `bench/ef_search.sh` as
  committed in 142564a.
- PostgreSQL 13.23, built from `REL_13_STABLE` 05f6c9ec2c4, `CFLAGS=-O2`, no assertions;
  pgvector 0.8.6.
- Machine: AMD Ryzen AI 9 HX 370, Fedora, Linux 7.3.3. Recall does not depend on the machine;
  it depends on the data, the index build and the sample.
- Command: `PGHOST=<socket dir> PGPORT=<port> bash bench/ef_search.sh`

| `hnsw.ef_search` | measured recall, 3 runs |
|---|---|
| 1 | 0.0020, 0.0030, 0.0030 |
| 10 | 0.8460, 0.8470, 0.8250 |
| 40 (default) | 0.9100, 0.9120, 0.9140 |
| 100 | 0.9540, 0.9490, 0.9520 |

These replace a table the README carried without a script behind it (PostgreSQL 19beta2,
pgvector 0.8.6 and pgvectorscale 0.9.0, 38,352 `vector(768)` rows: 0.0000 / 0.9000 / 1.0000).
