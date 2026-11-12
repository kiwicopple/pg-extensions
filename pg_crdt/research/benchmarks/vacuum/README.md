# Vacuum, bloat and WAL benchmarks

Scripts behind [`../vacuum-wal.md`](../vacuum-wal.md). They measure what
[`../text.md`](../text.md) and [`../pn-counter.md`](../pn-counter.md) did not:
dead tuples and TOAST bloat under sustained writes, what VACUUM and autovacuum
do about them, HOT updates, and WAL split into record payload and full-page
images with `pg_waldump`.

## Run

```sh
research/benchmarks/vacuum/run-all.sh            # everything, about an hour, writes results/*.md
QUICK=1 research/benchmarks/vacuum/run-all.sh    # small counts, a few minutes, for checking the scripts
```

Or one script at a time (each writes one file in `results/`):

| script | measures | default counts | time |
| --- | --- | --- | --- |
| `bloat.sh` | text shapes, autovacuum off: sizes, dead tuples, dead TOAST after 20,000 keystrokes; VACUUM and VACUUM FULL; HOT ratio with an index on another column | 100 documents x 4 sizes x 3 shapes | ~15 min |
| `autovac.sh` | text shapes, autovacuum on (defaults), fsync on: 200 keystrokes/s over 100 documents, and 50/s on one document, 180 s each, sampled every 5 s | 4 sizes x 3 shapes x 2 scenarios | ~30 min per shape (`SHAPES=a` runs one) |
| `autovac.sh` follow-ups | the 10-minute and typing-at-the-end runs of `vacuum-wal.md`; commands below | | ~30 min, in parallel |
| `wal.sh` | WAL per keystroke with `pg_waldump --stats=record`: records vs full-page images, wal_compression off / pglz / lz4, cold / warm / reusing freed space | 2,000 keystrokes per run | ~10 min |
| `ckpt.sh` | FPI share at checkpoint_timeout 30s vs 5min, 100 keystrokes/s for 90 s, fsync on | 5 and 100 kB, 3 shapes | ~20 min |
| `pn.sh` | pn_: state size, bloat, HOT, WAL per increment, delta table and the compaction recipe, autovacuum on | 100 counters, 10 to 10,000 replicas | ~20 min |

Knobs (environment): `NDOCS`, `SIZES` (bytes, default `1000 5000 20000 100000`), `SHAPES`, `EDITS`, `DURATION`, `SPREAD_RATE`, `HOT_RATE`, `RATE`, `REPLICAS`, `OUT`; see the header of each script.

Needs: Postgres with `pg_waldump`, `pgbench`, and the `pgstattuple` and `pg_freespacemap` contrib modules (Postgres.app has them), found as `test/run.sh` finds Postgres (`PGBIN`, else `initdb` on the `PATH`, else Postgres.app). Each script starts its own throwaway cluster through `test/lib/cluster.sh` (Unix socket only, deleted on exit), so scripts can run side by side. Disk: the 100 kB yseq_ and plain runs write a few GB each (`run-all.sh` peaks around 15 GB under `$TMPDIR`).

The follow-up runs (`run-all.sh` does not include them):

```sh
cd research/benchmarks/vacuum
SHAPES=a     SIZES="5000 20000" SCENARIOS=spread DURATION=600 OUT=results/autovac-long-a.md ./autovac.sh
SHAPES=plain SIZES="5000 20000" SCENARIOS=spread DURATION=600 OUT=results/autovac-long-plain.md ./autovac.sh
SHAPES=plain SIZES=100000       SCENARIOS=spread DURATION=600 OUT=results/autovac-long-plain-100k.md ./autovac.sh
SHAPES=a     SCENARIOS=hot-append OUT=results/autovac-append-hot-a.md ./autovac.sh
SHAPES=plain SCENARIOS=hot-append OUT=results/autovac-append-hot-plain.md ./autovac.sh
SHAPES=a SIZES=5000  SCENARIOS=spread-append DURATION=600 OUT=results/autovac-append-long-a-5k.md ./autovac.sh
SHAPES=a SIZES=20000 SCENARIOS=spread-append DURATION=600 OUT=results/autovac-append-long-a-20k.md ./autovac.sh
```

The append scenarios read the document length outside the document lock, so two ydoc_ writers on one document race (`position is outside the document`); they are run for plain and yseq_ only, where the UPDATE re-reads the row.

## Files

- `common.sh`: cluster settings (those of `text.md`: `shared_buffers=512MB`, `full_page_writes=on`, `checkpoint_timeout=30min`, `max_wal_size=8GB`, `fsync=off` unless a script says otherwise), the template database, `edit_script` (the keystroke workload), `snap` (sizes and pgstattuple), `waldump` (parses `pg_waldump --stats=record`).
- `setup.sql`: loaded into the template after the extension and `experiments/text-column/impl.sql`: the text generator and edit plans of `bench/text-compare.sh`, `bench.load` (one documents table per shape), `bench.rels`, `bench.measure`, `bench.pn_state`.
- `results/`: the output of the last full run, plus `*-raw.txt` with every `pg_waldump --stats=record` table the WAL figures were read from.

## The workload

Documents are built as in `bench/text-compare.sh`: generated prose of the given size typed by `alice` in one insert, then a 40-edit history by three replicas (70% insert of 1 to 5 words, 30% delete of 5 to 40 characters). The measured workload is keystrokes: one character per transaction, 80% insert and 20% delete, at a random position in the first half of a random document (or of document 1 for the hot-row runs), through the blessed API:

- plain: `update docs set body = overlay(body placing 'x' from pos + 1 for 0) where id = ...` (body `text compression lz4`)
- yseq_: `update docs set body = crdt.yseq_insert(body, pos, 'x', 'bench') where id = ...` (body `crdt.yseq compression lz4`)
- ydoc_: `select crdt.ydoc_insert((select body_doc from docs where id = ...), pos, 'x', 'bench')`

pn_: `update counters set s = crdt.pn_increment(s, <random replica>, 1) where id = ...`, and for the delta table `insert into deltas (counter, d) values (...)`.
