#!/usr/bin/env bash
# Head-to-head benchmark of the two text-CRDT shapes on one blog-post table:
#   shape A  experiments/text-column  jsonb column crdt.yseq   (yseq_ functions)
#   shape B  experiments/text-table   table-backed documents   (ydoc_ functions),
#            now part of the extension (pg_crdt--0.0.1.sql)
# Both load into ONE database (they coexist: different prefixes),
# and every workload runs on both, on the same machine, in one run, so the
# numbers are comparable. Prints Markdown tables for research/benchmarks/text.md.
#
#   bench/text-compare.sh             # full run, about 10 to 20 minutes
#   bench/text-compare.sh --quick     # 100 posts, short runs, a few minutes
#   bench/text-compare.sh --external  # the server from PGHOST/PGPORT/PGUSER
#
# Workloads (a to f of the brief; they run in the order a, d, b, c, e, f so the
# search and list queries see only the loaded posts):
#   a  storage of 1,000 posts of about 5 kB plus one of 100 kB
#   d  render one post, list 50 posts with 200 characters, full-text search
#   b  one-character edits (one statement each): latency and WAL
#   c  form save, three-way, one paragraph changed
#   e  the untrusted path: automerge-paper batch100 replay, single ops
#   f  4 and 8 sessions editing one post
#   x  keystrokes again with fsync=on
#
# Needs the trace files from experiments/text-ref/regen-traces.sh and pgbench
# next to psql. Latency is measured with pgbench (one client, one statement per
# transaction, per-transaction log: mean and 95th percentile as the client
# sees them). WAL is pg_current_wal_insert_lsn() before and after, after a
# CHECKPOINT, with full_page_writes=on, so it includes full-page images.
# The cluster runs with fsync=off (as the other benchmarks; WAL volume does not
# depend on it); workload x measures the keystroke once with fsync=on.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
TRACES="$EXT_DIR/experiments/text-ref/traces"
IMPL_A="$EXT_DIR/experiments/text-column/impl.sql"
IMPL_B="$EXT_DIR/pg_crdt--0.0.1.sql"
. "$EXT_DIR/test/lib/cluster.sh"

QUICK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1; shift ;;
        --external) EXTERNAL=1; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
for f in automerge-paper.ops.jsonl automerge-paper.batch100.jsonl; do
    [ -f "$TRACES/$f" ] || { echo "error: $TRACES/$f is missing; run experiments/text-ref/regen-traces.sh" >&2; exit 2; }
done

if [ $QUICK = 1 ]; then
    NPOSTS=100; EDITS5=40; EDITS100=200
    K5=200; K100=100          # keystroke transactions: 5 kB, 100 kB
    KSAVE=40                  # saves per run
    READ_T=300; FTS_T=100; FTS_SCAN_T=3
    BATCHES=200; ONE_OPS=1000
    CONC_T5=80; CONC_T100=30
else
    NPOSTS=1000; EDITS5=40; EDITS100=800
    K5=1000; K100=500
    KSAVE=200
    READ_T=2000; FTS_T=500; FTS_SCAN_T=8
    BATCHES=2598; ONE_OPS=5000
    CONC_T5=300; CONC_T100=100
fi
BIG=1001                      # plan and post id of the 100 kB post

export PG_EXTRA_OPTS="-c full_page_writes=on -c shared_buffers=512MB -c max_wal_size=8GB -c checkpoint_timeout=30min ${PG_EXTRA_OPTS:-}"
export PGCLIENTENCODING=UTF8
start_cluster
DB=text_compare
psql_admin -c "drop database if exists $DB" -c "create database $DB encoding 'UTF8' template template0"
PSQL=("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$DB")
q() { "${PSQL[@]}" -tA "$@"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgcrdt-text.XXXXXX")
trap 'rm -rf "$WORK"; stop_cluster' EXIT
WARNINGS=0
warn() { echo "WARNING: $*" >&2; echo "> WARNING: $*"; WARNINGS=$((WARNINGS + 1)); }
progress() { echo "[$(date +%H:%M:%S)] $*" >&2; }

"${PSQL[@]}" -f "$IMPL_B" -f "$IMPL_A"

echo "Postgres: $(q -c 'show server_version')"
if [ "$(uname -s)" = Darwin ]; then
    echo "Machine:  $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) CPU, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)"
else
    echo "Machine:  $(uname -m), $(nproc) CPU"
fi
echo "Date:     $(date '+%Y-%m-%d %H:%M %Z')"
echo "Settings: $(q -c "select string_agg(name || '=' || current_setting(name), ', ' order by name) from pg_settings where name in ('shared_buffers','fsync','full_page_writes','synchronous_commit','wal_compression','max_wal_size','checkpoint_timeout','default_toast_compression','autovacuum','wal_level')")"
echo "Impl:     A $(md5 -q "$IMPL_A" 2>/dev/null || md5sum "$IMPL_A" | cut -c1-32), B $(md5 -q "$IMPL_B" 2>/dev/null || md5sum "$IMPL_B" | cut -c1-32) (md5 of A's impl.sql and of the extension file); git $(git -C "$EXT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)$(git -C "$EXT_DIR" diff --quiet -- experiments pg_crdt--0.0.1.sql 2>/dev/null || echo " + uncommitted changes")"
echo "Mode:     $([ $QUICK = 1 ] && echo quick || echo full): $NPOSTS posts of 5 kB, one of 100 kB"
echo

# ---------------------------------------------------------------- helpers

row() { local o="|" a; for a in "$@"; do o+=" $a |"; done; echo "$o"; }
hdr() { row "$@"; local o="|" a; for a in "$@"; do o+=" --- |"; done; echo "$o"; }
f2() { awk -v x="$1" 'BEGIN { if (x >= 100) printf "%.0f", x; else if (x >= 10) printf "%.1f", x; else printf "%.2f", x }'; }
i0() { awk -v x="$1" 'BEGIN { printf "%.0f", x }'; }

# Fills R_MEAN and R_P95 (ms) from the pgbench per-transaction logs.
stats() {
    local s
    s=$(cat "$WORK"/pgb.log.* 2>/dev/null | awk '$3 ~ /^[0-9]+$/ { print $3 }' | sort -n |
        awk '{ a[NR] = $1; t += $1 } END { if (NR) printf "%.4f %.4f", t / NR / 1000, a[int(NR * 0.95 + 0.999)] / 1000; else printf "0 0" }')
    R_MEAN=${s% *}
    R_P95=${s#* }
}

# run SCRIPT CLIENTS TXNS [pgbench args]: checkpoint, run, then set R_OK R_TPS
# R_FAIL R_WAL (bytes) R_WALPER (bytes per successful transaction) R_MEAN R_P95.
run() {
    local script=$1 clients=$2 txns=$3 l0 l1 out
    shift 3
    rm -f "$WORK"/pgb.log.*
    "${PSQL[@]}" -c checkpoint
    l0=$(q -c 'select pg_current_wal_insert_lsn()')
    out=$("$PGBIN/pgbench" -n -c "$clients" -j "$clients" -t "$txns" -f "$script" -l \
        --log-prefix="$WORK/pgb.log" "$@" "$DB" 2>&1) || true
    l1=$(q -c 'select pg_current_wal_insert_lsn()')
    R_WAL=$(q -c "select pg_wal_lsn_diff('$l1', '$l0')")
    R_OK=$(sed -n 's/^number of transactions actually processed: \([0-9]*\)\/.*/\1/p' <<<"$out")
    R_TPS=$(sed -n 's/^tps = \([0-9.]*\) .*/\1/p' <<<"$out")
    R_FAIL=$(sed -n 's/^number of failed transactions: \([0-9]*\) .*/\1/p' <<<"$out")
    R_OK=${R_OK:-0}; R_TPS=${R_TPS:-0}; R_FAIL=${R_FAIL:-0}
    if [ "$R_OK" -gt 0 ]; then R_WALPER=$(awk -v w="$R_WAL" -v n="$R_OK" 'BEGIN { printf "%.0f", w / n }'); else R_WALPER=0; fi
    stats
    if [ "$R_OK" -lt $((clients * txns)) ] && [ "$R_FAIL" = 0 ]; then
        warn "pgbench ran $R_OK of $((clients * txns)) transactions ($(basename "$script")): $(grep -i -m1 'error\|abort' <<<"$out" | cut -c1-200)"
    fi
}

check() {  # description condition_sql
    local ok
    ok=$(q -c "select $2")
    [ "$ok" = t ] || warn "check failed: $1"
}

# ---------------------------------------------------------------- data

progress "generating text and edit plans"
"${PSQL[@]}" -v nposts=$NPOSTS -v edits5=$EDITS5 -v edits100=$EDITS100 -v big=$BIG -v ksave=$KSAVE <<'SQL'
create schema bench;

-- A vocabulary of pseudo-words and prose built from it (Zipf-like word frequencies).
create table bench.vocab (i int primary key, w text not null);
insert into bench.vocab
select row_number() over (order by w), w from (
    select distinct (select string_agg(
               substr('bcdfghjklmnprstvwz', 1 + ('x' || substr(md5(g || ':c' || k), 1, 6))::bit(24)::int % 18, 1) ||
               substr('aeiou', 1 + ('x' || substr(md5(g || ':v' || k), 1, 6))::bit(24)::int % 5, 1), '')
           from generate_series(1, 1 + ('x' || substr(md5(g::text), 1, 4))::bit(16)::int % 4) k) as w
    from generate_series(1, 4000) g) s
where w is not null;

create function bench.words(n int) returns text language plpgsql as $$
declare
    v text[];
    k int;
begin
    select array_agg(w order by i) into v from bench.vocab;
    k := array_length(v, 1);
    return array_to_string(array(select v[1 + floor(power(random(), 3) * k)::int] from generate_series(1, n)), ' ');
end;
$$;

create function bench.gen_text(n int) returns text language plpgsql as $$
declare
    t text := '';
    para text;
    sent text;
begin
    while length(t) < n loop
        para := null;
        for s in 1..(3 + floor(random() * 4))::int loop
            sent := bench.words(8 + floor(random() * 10)::int);
            sent := upper(left(sent, 1)) || substr(sent, 2) || '.';
            para := coalesce(para || ' ', '') || sent;
        end loop;
        t := t || case when t = '' then '' else E'\n\n' end || para;
    end loop;
    return left(t, n);
end;
$$;

-- The edit history of each post: the first text typed by alice, then random
-- edits by three people (70% insert of 1 to 5 words, 30% delete of 5 to 40
-- characters), as fractions of the current length so both shapes replay it
-- the same way.
select setseed(0.42) \g /dev/null
create table bench.plan0 (plan int primary key, t text not null);
insert into bench.plan0 select p, bench.gen_text(5000) from generate_series(1, :nposts) p;
insert into bench.plan0 values (:big, bench.gen_text(100000));
create table bench.plan (plan int, step int, kind text, frac float8, n int, txt text, replica text, primary key (plan, step));
insert into bench.plan
select p, s, case when random() < 0.7 then 'i' else 'd' end, random(), 5 + floor(random() * 36)::int,
       bench.words(1 + floor(random() * 5)::int) || ' ',
       (array['alice', 'bob', 'carol'])[1 + floor(random() * 3)::int]
from generate_series(1, :nposts) p, generate_series(1, :edits5) s;
insert into bench.plan
select :big, s, case when random() < 0.7 then 'i' else 'd' end, random(), 5 + floor(random() * 36)::int,
       bench.words(1 + floor(random() * 5)::int) || ' ',
       (array['alice', 'bob', 'carol'])[1 + floor(random() * 3)::int]
from generate_series(1, :edits100) s;

-- Sizes for the crossover sweep (workload g): 1, 20 and 50 kB, 8 edits per kB.
insert into bench.plan0 values (2001, bench.gen_text(1000)), (2020, bench.gen_text(20000)), (2050, bench.gen_text(50000));
insert into bench.plan
select v.plan, s, case when random() < 0.7 then 'i' else 'd' end, random(), 5 + floor(random() * 36)::int,
       bench.words(1 + floor(random() * 5)::int) || ' ',
       (array['alice', 'bob', 'carol'])[1 + floor(random() * 3)::int]
from (values (2001, 8), (2020, 160), (2050, 400)) v(plan, n), generate_series(1, 400) s
where s <= v.n;

create function bench.build_a(pid int) returns crdt.yseq language plpgsql as $$
declare
    s crdt.yseq;
    r record;
    len int;
begin
    s := crdt.yseq_insert(crdt.yseq_empty(), 0, (select t from bench.plan0 where plan = pid), 'alice');
    for r in select * from bench.plan where plan = pid order by step loop
        len := crdt.yseq_length(s);
        if r.kind = 'i' then
            s := crdt.yseq_insert(s, floor(r.frac * (len + 1))::int, r.txt, r.replica);
        else
            s := crdt.yseq_delete(s, floor(r.frac * (len - r.n))::int, r.n, r.replica);
        end if;
    end loop;
    return s;
end;
$$;

create function bench.build_b(pid int) returns text language plpgsql as $$
declare
    d text := crdt.ydoc_create();
    r record;
    len int;
begin
    perform crdt.ydoc_insert(d, 0, (select t from bench.plan0 where plan = pid), 'alice');
    for r in select * from bench.plan where plan = pid order by step loop
        len := crdt.ydoc_length(d);
        if r.kind = 'i' then
            perform crdt.ydoc_insert(d, floor(r.frac * (len + 1))::int, r.txt, r.replica);
        else
            perform crdt.ydoc_delete(d, floor(r.frac * (len - r.n))::int, r.n, r.replica);
        end if;
    end loop;
    return d;
end;
$$;

-- Form saves: a chain of texts, each one 300-character paragraph different from the last.
create table bench.saves (plan int, i int, t text, primary key (plan, i));
insert into bench.saves
with recursive c(plan, i, t) as (
    select p.plan, 0, crdt.yseq_value(bench.build_a(p.plan)) from (values (1), (:big)) p(plan)
    union all
    select plan, i + 1, overlay(t placing bench.words(50) from (1 + floor(random() * (length(t) - 300)))::int for 300)
    from c where i < :ksave
)
select plan, i, t from c where i > 0;
SQL

progress "loading $NPOSTS posts (+1 of 100 kB) into every table"
"${PSQL[@]}" -v nposts=$NPOSTS -v big=$BIG <<'SQL'
create sequence bench.scratch_id start 10000;

create table posts_plain (id int primary key, title text not null, body text not null);
create table posts_plain_lz4 (id int primary key, title text not null, body text compression lz4 not null);
create table posts_a (id int primary key, title text not null, body crdt.yseq compression lz4 not null);
create table posts_a_pglz (id int primary key, title text not null, body crdt.yseq not null);
create table posts_b (id int primary key, title text not null, body_doc text not null references crdt.ydoc_docs (uid));

create table bench.meta (k text primary key, v numeric);
select clock_timestamp() as t0 \gset
insert into posts_a select p, 'Post ' || p, bench.build_a(p) from generate_series(1, :nposts) p;
insert into posts_a select :big, 'Post ' || :big, bench.build_a(:big);
select extract(epoch from clock_timestamp() - :'t0') as secs_a \gset
select clock_timestamp() as t0 \gset
insert into posts_b select p, 'Post ' || p, bench.build_b(p) from generate_series(1, :nposts) p;
insert into posts_b select :big, 'Post ' || :big, bench.build_b(:big);
select extract(epoch from clock_timestamp() - :'t0') as secs_b \gset
\warn build time of the edit histories, seconds: yseq :secs_a, ydoc :secs_b

insert into posts_plain select id, title, crdt.yseq_value(body) from posts_a;
insert into posts_plain_lz4 select id, title, body || '' from posts_plain;
insert into posts_a_pglz select id, title, body::text::jsonb::crdt.yseq from posts_a;

-- With full-text search: A indexes the expression, B keeps a cached text column.
create table posts_plain_fts (id int primary key, title text not null, body text not null);
create table posts_a_fts (id int primary key, title text not null, body crdt.yseq compression lz4 not null);
create table posts_b_fts (id int primary key, title text not null, body_doc text not null references crdt.ydoc_docs (uid), body_text text not null);
create index on posts_plain_fts using gin (to_tsvector('english', body));
create index on posts_a_fts using gin (to_tsvector('english', crdt.yseq_value(body)));
create index on posts_b_fts using gin (to_tsvector('english', body_text));
insert into posts_plain_fts select * from posts_plain;
insert into posts_a_fts select id, title, body::text::jsonb::crdt.yseq from posts_a;
select clock_timestamp() as t0 \gset
insert into posts_b_fts select id, title, body_doc, crdt.ydoc_value(body_doc) from posts_b;
insert into bench.meta select 'fill_ms', round(extract(epoch from clock_timestamp() - :'t0') * 1000);

-- The same posts must have the same text in every shape.
select (select count(*) from posts_a a join posts_b b using (id) join posts_plain p using (id)
        where crdt.yseq_value(a.body) is distinct from crdt.ydoc_value(b.body_doc) or p.body is distinct from crdt.ydoc_value(b.body_doc)) > 0 as bad \gset
\if :bad
\warn 'ERROR: the shapes disagree on the text of some posts'
\quit 1
\endif
SQL

# vacuum full and analyze everything, then print the sizes
size_tables() {
    "${PSQL[@]}" <<'SQL'
select format('vacuum (full, analyze) %s', c.oid::regclass)
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r' and (n.nspname = 'public' or (n.nspname = 'crdt' and c.relname like 'ydoc\_%')) \gexec
checkpoint;
SQL
}
size_tables

# ---------------------------------------------------------------- a: storage

progress "a: storage"
echo "## a. Storage"
echo
echo "$NPOSTS posts of about 5 kB (40 edits each by three people, so a few dozen runs) plus one of 100 kB (800 edits). Sizes after \`vacuum full\`: table, TOAST and indexes (\`pg_total_relation_size\`), including the primary key. Shape B adds the nine \`crdt.ydoc_*\` tables."
echo
q -c "select format('Text bytes: %s posts, avg %s bytes; the 100 kB post %s bytes. Column compression of posts_a: %s lz4, %s pglz.',
        count(*) filter (where id <> $BIG), round(avg(length(body)) filter (where id <> $BIG)), max(length(body)) filter (where id = $BIG),
        (select count(*) from posts_a where pg_column_compression(body) = 'lz4'), (select count(*) from posts_a where pg_column_compression(body) = 'pglz')) from posts_plain"
echo

"${PSQL[@]}" <<'SQL'
create function bench.ydoc_bytes() returns bigint language sql as $$
    select coalesce(sum(pg_total_relation_size(c.oid)), 0)::bigint
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'crdt' and c.relkind = 'r' and c.relname like 'ydoc\_%' $$;
SQL

# storage_row LABEL TABLE [crdt]  [post filter]: sizes of a table (and the ydoc tables)
storage_table() {  # heading-less rows for the 1,000 posts, then with the big one
    local label=$1 tbl=$2 crdt=${3:-0} n=$4 tot own idx ycr plain
    own=$(q -c "select pg_table_size('$tbl')")
    idx=$(q -c "select pg_indexes_size('$tbl')")
    ycr=0; [ "$crdt" = 1 ] && ycr=$(q -c "select bench.ydoc_bytes()")
    tot=$((own + idx + ycr))
    row "$label" "$(awk -v x=$((own)) 'BEGIN { printf "%.2f", x / 1048576 }')" "$(awk -v x=$idx 'BEGIN { printf "%.2f", x / 1048576 }')" \
        "$(awk -v x=$ycr 'BEGIN { printf "%.2f", x / 1048576 }')" "$(awk -v x=$tot 'BEGIN { printf "%.2f", x / 1048576 }')" \
        "$(awk -v x=$tot -v n="$n" 'BEGIN { printf "%.1f", x / n / 1024 }')" "$(awk -v x=$tot -v p="$STORAGE_PLAIN" 'BEGIN { printf "%.2f", x / p }')"
}

# the total for the plain baseline first (it is the ratio's denominator)
STORAGE_PLAIN=$(q -c "select pg_total_relation_size('posts_plain')")
NALL=$((NPOSTS + 1))
echo "### All $NALL posts (the $NPOSTS small ones and the 100 kB one)"
echo
hdr "schema" "table + TOAST (MB)" "indexes (MB)" "crdt.ydoc_* tables (MB)" "total (MB)" "KB per post" "total / plain text"
storage_table "plain text column (pglz, the default)" posts_plain 0 $NALL
storage_table "plain text column (lz4)" posts_plain_lz4 0 $NALL
storage_table "A: yseq column, pglz" posts_a_pglz 0 $NALL
storage_table "A: yseq column, lz4" posts_a 0 $NALL
storage_table "B: ydoc documents" posts_b 1 $NALL
echo
echo "### With full-text search support"
echo
hdr "schema" "table + TOAST (MB)" "indexes (MB)" "crdt.ydoc_* tables (MB)" "total (MB)" "KB per post" "total / plain text"
STORAGE_PLAIN_FTS=$(q -c "select pg_total_relation_size('posts_plain_fts')")
STORAGE_PLAIN=$STORAGE_PLAIN_FTS
storage_table "plain text + GIN" posts_plain_fts 0 $NALL
storage_table "A: yseq lz4 + GIN on to_tsvector(yseq_value(body))" posts_a_fts 0 $NALL
# B with cache: posts_b_fts plus the crdt tables (posts_b itself is not part of this schema)
storage_table "B: ydoc + cached text column + GIN" posts_b_fts 1 $NALL
echo

echo "### Stored size of one post, in bytes"
echo
hdr "post" "plain text" "A: yseq, pglz" "A: yseq, lz4" "A: yseq state as JSON text" "B: item rows" "B: item rows, bytes (heap only)"
for pid in 1 $BIG; do
    row "$([ $pid = 1 ] && echo '5 kB (post 1)' || echo '100 kB')" "$(q -c "select length(body) from posts_plain where id = $pid")" \
        "$(q -c "select pg_column_size(body) from posts_a_pglz where id = $pid")" \
        "$(q -c "select pg_column_size(body) from posts_a where id = $pid")" \
        "$(q -c "select length(body::text) from posts_a where id = $pid")" \
        "$(q -c "select count(*) from crdt.ydoc_items where doc = (select d.id from crdt.ydoc_docs d join posts_b p on p.body_doc = d.uid where p.id = $pid)")" \
        "$(q -c "select sum(pg_column_size(i)) from crdt.ydoc_items i where doc = (select d.id from crdt.ydoc_docs d join posts_b p on p.body_doc = d.uid where p.id = $pid)")"
done
echo

# ---------------------------------------------------------------- d: reads

progress "d: reads"
echo "## d. Reads"
echo
echo "pgbench, one client, $READ_T transactions per run, one statement each, mean and 95th percentile as the client sees them (ms). The posts are cached in shared_buffers."
echo

cat > "$WORK/r_plain.sql" <<EOF
\set id random(1, $NPOSTS)
select body from posts_plain where id = :id;
EOF
cat > "$WORK/r_a.sql" <<EOF
\set id random(1, $NPOSTS)
select crdt.yseq_value(body) from posts_a where id = :id;
EOF
cat > "$WORK/r_b.sql" <<EOF
\set id random(1, $NPOSTS)
select crdt.ydoc_value(body_doc) from posts_b where id = :id;
EOF
cat > "$WORK/r_b_cached.sql" <<EOF
\set id random(1, $NPOSTS)
select body_text from posts_b_fts where id = :id;
EOF
for s in plain a b b_cached; do sed "s/random(1, $NPOSTS)/random($BIG, $BIG)/" "$WORK/r_$s.sql" > "$WORK/r100_$s.sql"; done

echo "### Render the body of one post"
echo
hdr "post" "plain text" "A: yseq_value" "B: ydoc_value" "B: cached text column"
for size in 5 100; do
    prefix=r; [ $size = 100 ] && prefix=r100
    cells=()
    for s in plain a b b_cached; do
        run "$WORK/${prefix}_$s.sql" 1 $READ_T
        cells+=("$(f2 $R_MEAN) / $(f2 $R_P95)")
    done
    row "$([ $size = 5 ] && echo '5 kB (random post)' || echo '100 kB')" "${cells[@]}"
done
echo
echo "(cells: mean / p95 ms)"
echo

cat > "$WORK/l_plain.sql" <<EOF
\set lo random(1, $((NPOSTS - 49)))
select id, title, left(body, 200) from posts_plain where id between :lo and :lo + 49 order by id;
EOF
cat > "$WORK/l_a.sql" <<EOF
\set lo random(1, $((NPOSTS - 49)))
select id, title, left(crdt.yseq_value(body), 200) from posts_a where id between :lo and :lo + 49 order by id;
EOF
cat > "$WORK/l_b.sql" <<EOF
\set lo random(1, $((NPOSTS - 49)))
select id, title, left(crdt.ydoc_value(body_doc), 200) from posts_b where id between :lo and :lo + 49 order by id;
EOF
cat > "$WORK/l_b_cached.sql" <<EOF
\set lo random(1, $((NPOSTS - 49)))
select id, title, left(body_text, 200) from posts_b_fts where id between :lo and :lo + 49 order by id;
EOF
echo "### List 50 posts with the first 200 characters (\`left(text, 200)\`)"
echo
hdr "query" "mean ms" "p95 ms"
for s in plain a b b_cached; do
    run "$WORK/l_$s.sql" 1 $((READ_T / 4))
    case $s in
        plain) lbl="plain text column" ;;
        a) lbl="A: left(yseq_value(body), 200)" ;;
        b) lbl="B: left(ydoc_value(body_doc), 200)" ;;
        b_cached) lbl="B: left(body_text, 200), cached column" ;;
    esac
    row "$lbl" "$(f2 $R_MEAN)" "$(f2 $R_P95)"
done
echo

# Two words of different frequency: AND of them matches a few dozen posts.
read -r W1 W2 <<<"$(q -F' ' -c "with s as (select word, ndoc from ts_stat('select to_tsvector(''english'', body) from posts_plain')
        where ndoc < (select count(*) from posts_plain) * 0.8)
    select (select word from s order by abs(ndoc - (select count(*) from posts_plain) * 0.30) limit 1),
           (select word from s order by abs(ndoc - (select count(*) from posts_plain) * 0.20) limit 1)")"
TSQ="to_tsquery('simple', '$W1 & $W2')"
cat > "$WORK/f_plain.sql" <<EOF
select count(*) from posts_plain_fts where to_tsvector('english', body) @@ $TSQ;
EOF
cat > "$WORK/f_a.sql" <<EOF
select count(*) from posts_a_fts where to_tsvector('english', crdt.yseq_value(body)) @@ $TSQ;
EOF
cat > "$WORK/f_b.sql" <<EOF
select count(*) from posts_b_fts where to_tsvector('english', body_text) @@ $TSQ;
EOF
cat > "$WORK/f_a_scan.sql" <<EOF
select count(*) from posts_a where to_tsvector('english', crdt.yseq_value(body)) @@ $TSQ;
EOF
cat > "$WORK/f_b_scan.sql" <<EOF
select count(*) from posts_b where to_tsvector('english', crdt.ydoc_value(body_doc)) @@ $TSQ;
EOF
HITS=$(q -f "$WORK/f_plain.sql")
check "FTS: A matches plain" "(select count(*) from posts_a_fts where to_tsvector('english', crdt.yseq_value(body)) @@ $TSQ) = $HITS"
check "FTS: B cached matches plain" "(select count(*) from posts_b_fts where to_tsvector('english', body_text) @@ $TSQ) = $HITS"
check "FTS: B unindexed matches plain" "(select count(*) from posts_b where to_tsvector('english', crdt.ydoc_value(body_doc)) @@ $TSQ) = $HITS"
q -c "set enable_seqscan = off" -c "explain select count(*) from posts_a_fts where to_tsvector('english', crdt.yseq_value(body)) @@ $TSQ" | grep -q 'Bitmap Index Scan' || warn "the A full-text query does not use its GIN index"
q -c "explain select count(*) from posts_a_fts where to_tsvector('english', crdt.yseq_value(body)) @@ $TSQ" | grep -q 'Bitmap Index Scan' || echo "> note: without enable_seqscan=off the planner does not pick the A index at this size"

echo "### Full-text search across the posts"
echo
echo "\`to_tsvector('english', ...) @@ to_tsquery('simple', '$W1 & $W2')\`, $HITS of $NALL posts match. 'index' is a GIN index on the text (A: on the expression \`to_tsvector('english', crdt.yseq_value(body))\`, B: on the cached column \`body_text\`). 'no index' renders and tokenizes every post per query."
echo
hdr "query" "mean ms" "p95 ms"
for s in plain a b; do
    run "$WORK/f_$s.sql" 1 $FTS_T
    case $s in
        plain) lbl="plain text, GIN index" ;;
        a) lbl="A: expression GIN index on yseq_value(body)" ;;
        b) lbl="B: GIN index on cached body_text" ;;
    esac
    row "$lbl" "$(f2 $R_MEAN)" "$(f2 $R_P95)"
done
for s in a_scan b_scan; do
    run "$WORK/f_$s.sql" 1 $FTS_SCAN_T
    case $s in
        a_scan) lbl="A: no index (yseq_value of every post)" ;;
        b_scan) lbl="B: no index, no cache (ydoc_value of every post)" ;;
    esac
    row "$lbl" "$(f2 $R_MEAN)" "$(f2 $R_P95)"
done
echo
REFRESH_MS=$("${PSQL[@]}" -tA <<'SQL'
select clock_timestamp() as t0 \gset
update posts_b_fts set body_text = crdt.ydoc_value(body_doc);
select round(extract(epoch from clock_timestamp() - :'t0') * 1000);
SQL
)
echo "Refreshing the cached column of B for all $NALL posts (\`update posts_b_fts set body_text = crdt.ydoc_value(body_doc)\`, GIN index in place): $REFRESH_MS ms (the initial fill took $(q -c "select v from bench.meta where k = 'fill_ms'") ms)."
echo

# ---------------------------------------------------------------- b: keystrokes

# scratch KIND PLAN -> id of a new post with the history of PLAN in table KIND
scratch() {
    local kind=$1 plan=$2 id
    id=$(q -c "select nextval('bench.scratch_id')")
    case $kind in
        plain) q -c "insert into posts_plain_lz4 select $id, 'scratch', crdt.yseq_value(bench.build_a($plan)) || ''" ;;
        a) q -c "insert into posts_a select $id, 'scratch', bench.build_a($plan)" ;;
        a_fts) q -c "insert into posts_a_fts select $id, 'scratch', bench.build_a($plan)" ;;
        b) q -c "insert into posts_b select $id, 'scratch', bench.build_b($plan)" ;;
        b_fts)
            local d
            d=$(q -c "select bench.build_b($plan)")
            q -c "insert into posts_b_fts values ($id, 'scratch', '$d', crdt.ydoc_value('$d'))" ;;
    esac
    echo "$id"
}
doc_len() {  # kind id
    case $1 in
        plain) q -c "select length(body) from posts_plain_lz4 where id = $2" ;;
        a) q -c "select crdt.yseq_length(body) from posts_a where id = $2" ;;
        a_fts) q -c "select crdt.yseq_length(body) from posts_a_fts where id = $2" ;;
        b) q -c "select crdt.ydoc_length(body_doc) from posts_b where id = $2" ;;
        b_fts) q -c "select crdt.ydoc_length(body_doc) from posts_b_fts where id = $2" ;;
    esac
}

# keystroke_script KIND ID MODE LEN: writes $WORK/k.sql and sets K_D (pgbench -D args)
# MODE: ins (random position), del (random), type (insert at the cursor, moving right), bs (delete before the cursor, moving left)
keystroke_script() {
    local kind=$1 id=$2 mode=$3 len=$4 half=$(($4 / 2)) stmt pos
    K_D=()
    case $mode in
        ins) echo "\\set pos random(0, $half)" > "$WORK/k.sql"; pos=":pos" ;;
        del) echo "\\set pos random(0, $half)" > "$WORK/k.sql"; pos=":pos" ;;
        type) : > "$WORK/k.sql"; pos=":pos"; K_D=(-D "pos=$half") ;;
        bs) : > "$WORK/k.sql"; pos=":pos"; K_D=(-D "pos=$half") ;;
    esac
    local op=ins
    if [ "$mode" = del ] || [ "$mode" = bs ]; then op=del; fi
    case "$kind:$op" in
        plain:ins) stmt="update posts_plain_lz4 set body = overlay(body placing 'x' from $pos + 1 for 0) where id = $id;" ;;
        plain:del) stmt="update posts_plain_lz4 set body = overlay(body placing '' from $pos + 1 for 1) where id = $id;" ;;
        a:ins) stmt="update posts_a set body = crdt.yseq_insert(body, $pos, 'x', 'bench') where id = $id;" ;;
        a:del) stmt="update posts_a set body = crdt.yseq_delete(body, $pos, 1, 'bench') where id = $id;" ;;
        a_fts:ins) stmt="update posts_a_fts set body = crdt.yseq_insert(body, $pos, 'x', 'bench') where id = $id;" ;;
        a_fts:del) stmt="update posts_a_fts set body = crdt.yseq_delete(body, $pos, 1, 'bench') where id = $id;" ;;
        b:ins) stmt="select crdt.ydoc_insert((select body_doc from posts_b where id = $id), $pos, 'x', 'bench');" ;;
        b:del) stmt="select crdt.ydoc_delete((select body_doc from posts_b where id = $id), $pos, 1, 'bench');" ;;
        b_cached:ins) stmt="begin;
select crdt.ydoc_insert((select body_doc from posts_b_fts where id = $id), $pos, 'x', 'bench');
update posts_b_fts set body_text = crdt.ydoc_value(body_doc) where id = $id;
end;" ;;
    esac
    echo "$stmt" >> "$WORK/k.sql"
    case $mode in type) echo '\set pos :pos + 1' >> "$WORK/k.sql" ;; bs) echo '\set pos :pos - 1' >> "$WORK/k.sql" ;; esac
}

progress "b: keystrokes"
echo "## b. Keystroke editing"
echo
echo "One character per statement, one statement per transaction (pgbench, one client). A: \`update posts set body = crdt.yseq_insert(body, pos, 'x', 'bench') where id = ...\` (and \`yseq_delete\`). B: \`select crdt.ydoc_insert(body_doc, pos, 'x', 'bench')\` (and \`ydoc_delete\`); it returns the op. 'random' edits a random position in the first half of the post; 'cursor' types forward from the middle (insert at pos, pos+1, ...), 'backspace' deletes backwards from the middle. Latency in ms (mean, p95); WAL bytes per edit, measured after a CHECKPOINT with \`full_page_writes=on\`, so the first touch of each page includes a full-page image. Each run edits a fresh post with the same history. 'A + GIN' is posts with the expression GIN index of workload d; 'B + cache' also refreshes a cached text column in the same transaction as every keystroke (what B's NOTES advise against)."
echo
hdr "post" "edit" "shape" "mean ms" "p95 ms" "WAL B per edit"
keystroke_run() {  # size_label plan K mode shape...
    local label=$1 plan=$2 K=$3 mode=$4 kind sk len id desc m
    shift 4
    for kind in "$@"; do
        sk=$kind
        if [ "$kind" = b_cached ]; then sk=b_fts; fi
        id=$(scratch "$sk" "$plan")
        len=$(doc_len "$sk" "$id")
        keystroke_script "$kind" "$id" "$mode" "$len"
        run "$WORK/k.sql" 1 "$K" "${K_D[@]+"${K_D[@]}"}"
        case $kind in
            plain) desc="plain text (lz4)" ;;
            a) desc="A: yseq (lz4)" ;;
            a_fts) desc="A + GIN" ;;
            b) desc="B: ydoc" ;;
            b_cached) desc="B + cache" ;;
        esac
        case $mode in
            ins) m="insert 1 char, random" ;;
            del) m="delete 1 char, random" ;;
            type) m="insert 1 char, cursor" ;;
            bs) m="backspace 1 char" ;;
        esac
        row "$label" "$m" "$desc" "$(f2 $R_MEAN)" "$(f2 $R_P95)" "$R_WALPER"
    done
}
for spec in "5 kB:1:$K5" "100 kB:$BIG:$K100"; do
    IFS=: read -r label plan K <<<"$spec"
    keystroke_run "$label" "$plan" "$K" ins plain a a_fts b b_cached
    keystroke_run "$label" "$plan" "$K" del a a_fts b
    keystroke_run "$label" "$plan" "$K" type a a_fts b
    keystroke_run "$label" "$plan" "$K" bs a a_fts b
done
echo

# ---------------------------------------------------------------- c: form save

progress "c: form save"
echo "## c. Form save"
echo
echo "The app loads a post, the user rewrites one 300-character paragraph, the app saves the whole text. $KSAVE saves per run, each from the previous text. A: \`update posts set body = crdt.yseq_set(body, \$text, 'bench', base => body) where id = ...\`. B: \`select crdt.ydoc_set(body_doc, \$text, 'bench', crdt.ydoc_base(body_doc))\`. The new text comes from a table (the same for every shape), so no client-to-server transfer is in the timing, and shape A's base (the whole loaded state, three to four times the text) is not shipped back either; with no concurrent edits the base equals the current value, so this is the cost of the three-way path without the transfers. 'A + GIN' has the expression GIN index; 'B + cache' refreshes the cached text column in the same transaction."
echo
hdr "post" "shape" "mean ms" "p95 ms" "WAL B per save"
save_run() {
    local label=$1 plan=$2 kind id table last want
    for kind in plain a a2 a_fts b b2 b_cached; do
        local sk=$kind desc
        case $kind in a2) sk=a ;; b2) sk=b ;; esac
        case $kind in b_cached) sk=b_fts ;; esac
        id=$(scratch "$sk" "$plan")
        case $kind in
            plain)
                echo "\\set i :i + 1
update posts_plain_lz4 set body = (select t from bench.saves where plan = $plan and i = :i) where id = $id;" > "$WORK/s.sql"; desc="plain text (lz4)" ;;
            a)
                echo "\\set i :i + 1
update posts_a set body = crdt.yseq_set(body, (select t from bench.saves where plan = $plan and i = :i), 'bench', base => body) where id = $id;" > "$WORK/s.sql"; desc="A: yseq (lz4)" ;;
            a2)
                echo "\\set i :i + 1
update posts_a set body = crdt.yseq_set(body, (select t from bench.saves where plan = $plan and i = :i), 'bench') where id = $id;" > "$WORK/s.sql"; desc="A: yseq, two-way (no base)" ;;
            a_fts)
                echo "\\set i :i + 1
update posts_a_fts set body = crdt.yseq_set(body, (select t from bench.saves where plan = $plan and i = :i), 'bench', base => body) where id = $id;" > "$WORK/s.sql"; desc="A + GIN" ;;
            b)
                echo "\\set i :i + 1
select crdt.ydoc_set(d.body_doc, (select t from bench.saves where plan = $plan and i = :i), 'bench', crdt.ydoc_base(d.body_doc)) from posts_b d where d.id = $id;" > "$WORK/s.sql"; desc="B: ydoc" ;;
            b2)
                echo "\\set i :i + 1
select crdt.ydoc_set(d.body_doc, (select t from bench.saves where plan = $plan and i = :i), 'bench') from posts_b d where d.id = $id;" > "$WORK/s.sql"; desc="B: ydoc, two-way (no base)" ;;
            b_cached)
                echo "\\set i :i + 1
begin;
select crdt.ydoc_set(d.body_doc, (select t from bench.saves where plan = $plan and i = :i), 'bench', crdt.ydoc_base(d.body_doc)) from posts_b_fts d where d.id = $id;
update posts_b_fts set body_text = crdt.ydoc_value(body_doc) where id = $id;
end;" > "$WORK/s.sql"; desc="B + cache" ;;
        esac
        run "$WORK/s.sql" 1 "$KSAVE" -D i=0
        want=$(q -c "select md5(t) from bench.saves where plan = $plan and i = $KSAVE")
        case $kind in
            plain) last=$(q -c "select md5(body) from posts_plain_lz4 where id = $id") ;;
            a|a2) last=$(q -c "select md5(crdt.yseq_value(body)) from posts_a where id = $id") ;;
            a_fts) last=$(q -c "select md5(crdt.yseq_value(body)) from posts_a_fts where id = $id") ;;
            b|b2) last=$(q -c "select md5(crdt.ydoc_value(body_doc)) from posts_b where id = $id") ;;
            b_cached) last=$(q -c "select md5(crdt.ydoc_value(body_doc)) from posts_b_fts where id = $id") ;;
        esac
        [ "$last" = "$want" ] || warn "form save ($desc, $label): the final text differs from the last saved text"
        row "$label" "$desc" "$(f2 $R_MEAN)" "$(f2 $R_P95)" "$R_WALPER"
    done
}
save_run "5 kB" 1
save_run "100 kB" $BIG
echo

# ---------------------------------------------------------------- e: untrusted path

progress "e: untrusted path (apply)"
echo "## e. The untrusted write path"
echo
echo "The automerge-paper editing trace (259,778 single-character edits by one writer, final text 104,852 characters) as ops with \`v\`, through \`yseq_apply\` (an UPDATE of the row) and \`ydoc_apply\`, one call per transaction, replica id 'paper'. 'batch100' is the reference's batching: $BATCHES calls of 100 patches each. 'single ops' is one op per call, the first $ONE_OPS ops."
echo
"${PSQL[@]}" <<SQL
create table bench.batch100 (n bigint generated always as identity primary key, op jsonb not null);
create table bench.ops (n bigint generated always as identity primary key, op jsonb not null);
\copy bench.batch100 (op) from '$TRACES/automerge-paper.batch100.jsonl' with (format csv, quote e'\x01', delimiter e'\x02')
\copy bench.ops (op) from program 'head -n $ONE_OPS $TRACES/automerge-paper.ops.jsonl' with (format csv, quote e'\x01', delimiter e'\x02')
SQL
EXPECT_MD5=f6ee9cff45a87f3b7f29d60920bfce10   # md5 of the trace's endContent
hdr "replay" "shape" "calls" "total s" "mean ms per call" "p95 ms" "WAL B per call"
for what in batch100 ops; do
    if [ $what = batch100 ]; then N=$BATCHES; lbl="batch100 (100 patches per call)"; else N=$ONE_OPS; lbl="single ops"; fi
    for kind in a b; do
        if [ $kind = a ]; then
            id=$(q -c "select nextval('bench.scratch_id')")
            q -c "insert into posts_a values ($id, 'replay', crdt.yseq_empty())"
            echo "\\set n :n + 1
update posts_a set body = crdt.yseq_apply(body, (select op from bench.$what where n = :n), 'paper') where id = $id;" > "$WORK/e.sql"
            desc="A: yseq_apply (lz4 row)"
        else
            id=$(q -c "select nextval('bench.scratch_id')")
            q -c "insert into posts_b values ($id, 'replay', crdt.ydoc_create())"
            echo "\\set n :n + 1
select crdt.ydoc_apply((select body_doc from posts_b where id = $id), (select op from bench.$what where n = :n), 'paper');" > "$WORK/e.sql"
            desc="B: ydoc_apply"
        fi
        run "$WORK/e.sql" 1 "$N" -D n=0
        total=$(awk -v n="$R_OK" -v t="$R_TPS" 'BEGIN { if (t > 0) printf "%.1f", n / t; else print 0 }')
        if [ $kind = a ]; then M=$(q -c "select md5(crdt.yseq_value(body)) from posts_a where id = $id")
        else M=$(q -c "select md5(crdt.ydoc_value(body_doc)) from posts_b where id = $id"); fi
        eval "MD5_${what}_$kind=$M"
        if [ $what = batch100 ]; then eval "TRACE_ID_$kind=$id"; fi
        if [ $what = batch100 ] && [ $QUICK = 0 ] && [ "$M" != "$EXPECT_MD5" ]; then warn "$desc: final text of the batch100 replay differs from the trace's endContent"; fi
        row "$lbl" "$desc" "$N" "$total" "$(f2 $R_MEAN)" "$(f2 $R_P95)" "$R_WALPER"
    done
done
[ "$MD5_batch100_a" = "$MD5_batch100_b" ] || warn "batch100: A and B ended with different texts"
[ "$MD5_ops_a" = "$MD5_ops_b" ] || warn "single ops: A and B ended with different texts"
echo

progress "e2: the post the trace left behind"
echo "### A heavily edited 100 kB post"
echo
echo "The post the batch100 replay above left behind: the final text of the trace (104,852 characters) after 182,315 typed and 77,463 deleted characters by one writer. It has far more runs than the 100 kB post of the other workloads (800 edits). Random-position insert of one character, $K100 transactions as in workload b, and the render of the body. 'B after ydoc_compact' is shape B's maintenance call run on that document."
echo
hdr "shape" "runs / item rows" "stored bytes" "render ms (mean)" "insert 1 char mean ms" "p95 ms" "WAL B per edit"
trace_row() {  # label kind id
    local label=$1 kind=$2 id=$3 len rows stored rmean
    len=$(doc_len $kind $id)
    if [ $kind = a ]; then
        rows=$(q -c "select sum(array_length(x::int[], 1) / 7) from posts_a, jsonb_array_elements_text(body -> 'm') x where id = $id")
        stored=$(q -c "select pg_column_size(body) from posts_a where id = $id")
        echo "select crdt.yseq_value(body) from posts_a where id = $id;" > "$WORK/t.sql"
    else
        rows=$(q -c "select count(*) from crdt.ydoc_items where doc = (select d.id from crdt.ydoc_docs d join posts_b p on p.body_doc = d.uid where p.id = $id)")
        stored=$(q -c "select round(sum(pg_column_size(i)) * pg_total_relation_size('crdt.ydoc_items')::numeric / pg_relation_size('crdt.ydoc_items')) from crdt.ydoc_items i where doc = (select d.id from crdt.ydoc_docs d join posts_b p on p.body_doc = d.uid where p.id = $id)")
        echo "select crdt.ydoc_value(body_doc) from posts_b where id = $id;" > "$WORK/t.sql"
    fi
    run "$WORK/t.sql" 1 $((K100 / 2))
    rmean=$R_MEAN
    keystroke_script $kind $id ins "$len"
    run "$WORK/k.sql" 1 "$K100"
    row "$label" "$rows" "$stored" "$(f2 $rmean)" "$(f2 $R_MEAN)" "$(f2 $R_P95)" "$R_WALPER"
}
trace_row "A: yseq (lz4)" a "$TRACE_ID_a"
trace_row "B: ydoc, as replayed" b "$TRACE_ID_b"
q -c "select crdt.ydoc_compact(body_doc) from posts_b where id = $TRACE_ID_b" >/dev/null
"${PSQL[@]}" -c "vacuum (full, analyze) crdt.ydoc_items"
trace_row "B: ydoc after ydoc_compact" b "$TRACE_ID_b"
echo "(B stored bytes: the document's item rows, scaled by the table-wide ratio of heap plus indexes to heap, which includes the other documents' free space; A: the stored, compressed column value. Runs of A are counted from the chunk run lists.)"
echo

# ---------------------------------------------------------------- f: concurrency

progress "f: concurrency"
echo "## f. Concurrency: several sessions editing the same post"
echo
echo "pgbench -c N, each session inserts one character at a random position per transaction (own replica id per session), one statement per transaction. 'same post': all sessions edit one post. 'own posts': each session edits its own post of the same size (no contention; the scaling baseline). The isolation level is READ COMMITTED, then REPEATABLE READ (default_transaction_isolation) to see serialization failures. 'lost' is the number of acknowledged inserts missing from the final length. Failed transactions are not retried."
echo
hdr "post" "sessions" "case" "shape" "isolation" "tps" "mean ms" "p95 ms" "failed" "lost"

conc_run() {  # label plan T range clients case iso
    local label=$1 plan=$2 T=$3 range=$4 clients=$5 mode=$6 iso=$7 kind id id0 where len0 len1 desc saved c
    for kind in a b; do
        id0=""
        for ((c = 0; c < clients; c++)); do
            id=$(scratch $kind "$plan")
            if [ -z "$id0" ]; then id0=$id; fi
            if [ $mode = same ]; then break; fi
        done
        if [ $mode = same ]; then where="id = $id0"; else where="id between $id0 and $((id0 + clients - 1))"; fi
        if [ $mode = same ]; then target="$id0"; else target=":id"; fi
        {
            echo "\\set pos random(0, $range)"
            if [ $mode != same ]; then echo "\\set id $id0 + :client_id"; fi
            if [ $kind = a ]; then
                echo "update posts_a set body = crdt.yseq_insert(body, :pos, 'x', 'c' || :client_id) where id = $target;"
            else
                echo "select crdt.ydoc_insert((select body_doc from posts_b where id = $target), :pos, 'x', 'c' || :client_id);"
            fi
        } > "$WORK/c.sql"
        if [ $kind = a ]; then
            desc="A: yseq"
            len0=$(q -c "select sum(crdt.yseq_length(body)) from posts_a where $where")
        else
            desc="B: ydoc"
            len0=$(q -c "select sum(crdt.ydoc_length(body_doc)) from posts_b where $where")
        fi
        saved=${PGOPTIONS:-}
        if [ "$iso" = rr ]; then export PGOPTIONS="$saved -c default_transaction_isolation=repeatable\\ read"; fi
        run "$WORK/c.sql" "$clients" "$T"
        export PGOPTIONS=$saved
        if [ $kind = a ]; then
            len1=$(q -c "select sum(crdt.yseq_length(body)) from posts_a where $where")
        else
            len1=$(q -c "select sum(crdt.ydoc_length(body_doc)) from posts_b where $where")
        fi
        row "$label" "$clients" "$([ $mode = same ] && echo 'same post' || echo 'own posts')" "$desc" \
            "$([ "$iso" = rr ] && echo 'repeatable read' || echo 'read committed')" \
            "$(i0 "$R_TPS")" "$(f2 "$R_MEAN")" "$(f2 "$R_P95")" "$R_FAIL" "$((R_OK - (len1 - len0)))"
    done
}
for n in 4 8; do
    conc_run "5 kB" 1 $CONC_T5 4000 $n same rc
done
conc_run "5 kB" 1 $CONC_T5 4000 8 own rc
conc_run "5 kB" 1 $CONC_T5 4000 8 same rr
for n in 4 8; do
    conc_run "100 kB" $BIG $CONC_T100 90000 $n same rc
done
conc_run "100 kB" $BIG $CONC_T100 90000 8 own rc
echo


# ---------------------------------------------------------------- g: size sweep

progress "g: size sweep"
echo "## g. Where the shapes cross: random-position insert of one character by document size"
echo
echo "As workload b (one statement per transaction, $K5 transactions, fresh post each), for posts of 1, 5, 20, 50 and 100 kB. Posts have 8 edits per kB (the 5 and 100 kB rows are the posts of workload b). WAL is bytes per edit."
echo
hdr "post" "plain text mean ms / WAL" "A mean ms / WAL" "A + GIN mean ms / WAL" "B mean ms / WAL"
sweep_cell() {  # kind plan -> "mean / wal"
    local kind=$1 plan=$2 id len
    id=$(scratch "$kind" "$plan")
    len=$(doc_len "$kind" "$id")
    keystroke_script "$kind" "$id" ins "$len"
    run "$WORK/k.sql" 1 "$K5"
    echo "$(f2 $R_MEAN) / $R_WALPER"
}
for spec in "1 kB:2001" "5 kB:1" "20 kB:2020" "50 kB:2050" "100 kB:$BIG"; do
    IFS=: read -r label plan <<<"$spec"
    row "$label" "$(sweep_cell plain $plan)" "$(sweep_cell a $plan)" "$(sweep_cell a_fts $plan)" "$(sweep_cell b $plan)"
done
echo

# ---------------------------------------------------------------- x: fsync on

progress "x: keystrokes with fsync=on"
echo "## x. Keystrokes with fsync=on"
echo
if [ "${EXTERNAL:-0}" = 1 ]; then
    echo "Skipped: --external cannot restart the server."
    echo
else
echo "The random-insert rows of workload b again after restarting the cluster with \`fsync=on\` (synchronous_commit is on, so every commit waits for a WAL flush; on macOS the default wal_sync_method is open_datasync; the machine's SSD decides the cost)."
echo
"$PGBIN/pg_ctl" -D "$PGCRDT_TMP/data" -l "$PGCRDT_TMP/server.log" -w \
    -o "-c listen_addresses='' -k $PGCRDT_TMP -c fsync=off -c full_page_writes=off ${PG_EXTRA_OPTS:-} -c fsync=on" restart >/dev/null
[ "$(q -c 'show fsync')" = on ] || warn "fsync did not switch on"
hdr "post" "edit" "shape" "mean ms" "p95 ms" "WAL B per edit"
for spec in "5 kB:1:$((K5 / 2))" "100 kB:$BIG:$((K100 / 2))"; do
    IFS=: read -r label plan K <<<"$spec"
    keystroke_run "$label" "$plan" "$K" ins plain a b
done
echo
fi

# ---------------------------------------------------------------- compaction

progress "compaction of B"
echo "## y. Shape B after \`ydoc_compact\`"
echo
echo "\`ydoc_compact(doc)\` on the $NALL loaded documents (the tables also hold the scratch documents of the workloads, unchanged by it)."
echo
ROWS0=$(q -c "select count(*) from crdt.ydoc_items where doc in (select d.id from crdt.ydoc_docs d join posts_b p on p.body_doc = d.uid where p.id <= $BIG)")
size_tables
B0=$(q -c "select bench.ydoc_bytes()")
COMPACT_MS=$("${PSQL[@]}" -tA <<SQL
select clock_timestamp() as t0 \\gset
select sum(crdt.ydoc_compact(body_doc)) from posts_b where id <= $BIG \\g /dev/null
select round(extract(epoch from clock_timestamp() - :'t0') * 1000);
SQL
)
size_tables
B1=$(q -c "select bench.ydoc_bytes()")
ROWS1=$(q -c "select count(*) from crdt.ydoc_items where doc in (select d.id from crdt.ydoc_docs d join posts_b p on p.body_doc = d.uid where p.id <= $BIG)")
hdr "state" "item rows of the $NALL posts" "crdt.ydoc_* tables (MB)"
row "as built" "$ROWS0" "$(awk -v x=$B0 'BEGIN { printf "%.2f", x / 1048576 }')"
row "after ydoc_compact (took $COMPACT_MS ms)" "$ROWS1" "$(awk -v x=$B1 'BEGIN { printf "%.2f", x / 1048576 }')"
echo

echo "Warnings: $WARNINGS"
progress "done ($WARNINGS warnings)"
