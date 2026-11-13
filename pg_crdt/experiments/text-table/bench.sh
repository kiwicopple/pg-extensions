#!/usr/bin/env bash
# Shape B (ydoc_) benchmark. Prints Markdown for experiments/text-table/NOTES.md.
# A measurement tool, not polished.
#
#   experiments/text-table/bench.sh            # sizes 1k, 10k, 100k, 1M + trace
#   experiments/text-table/bench.sh --quick    # sizes 1k, 10k, 100k; trace prefix
#   experiments/text-table/bench.sh --impl x.sql   # another build of pg_crdt--0.0.1.sql
#   ONLY=trace,keys experiments/text-table/bench.sh   # some sections only:
#       sizes pos render cache conc merge keys compact replica trace
#
# ydoc_ is preserved in the research snapshot (section "ydoc_");
# this loads that combined snapshot. variants/*.sql are ydoc_-only builds: they
# load after the extension file with its ydoc_ section cut out.
#
# Throwaway cluster from pg_crdt/test/lib/cluster.sh (temp dir, Unix socket),
# full_page_writes=on as in bench/pn-counter.sh, so WAL includes full-page
# images after a CHECKPOINT. Each measured statement runs as its own
# transaction through pgbench (one client unless stated).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(cd "$HERE/../.." && pwd)
. "$EXT_DIR/test/lib/cluster.sh"

IMPL="$EXT_DIR/research/ydoc/pg_crdt--0.0.1.sql"
QUICK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1; shift ;;
        --impl) IMPL=$2; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
TRACE_DIR="$HERE/../text-ref/traces"
ONLY=${ONLY:-}
COMPACT_NOTES=""
want() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }

export PG_EXTRA_OPTS="-c full_page_writes=on -c max_connections=40 -c shared_buffers=512MB -c max_wal_size=8GB ${PG_EXTRA_OPTS:-}"
start_cluster
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ydoc-bench.XXXXXX")
trap 'rm -rf "$WORK"; stop_cluster' EXIT

P() { "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 "$@"; }
PT() { "$PGBIN/psql" -X -q -tA -v ON_ERROR_STOP=1 "$@"; }

# The extension file without its ydoc_ section: the base for variants/*.sql.
python3 - "$IMPL" "$WORK/pn-base.sql" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.rindex('-- ====', 0, s.index('-- ydoc_: collaborative text'))
b = s.rindex('-- ====', 0, s.index('-- Privileges'))
open(sys.argv[2], 'w').write(s[:a] + s[b:])
PY

newdb() {  # newdb name [impl]: a complete build of the extension file, or a variant
    psql_admin -c "drop database if exists $1" -c "create database $1 encoding 'UTF8' template template0"
    case "${2:-$IMPL}" in
        "$HERE/variants/"*) P -d "$1" -f "$WORK/pn-base.sql" -f "$2" ;;
        *) P -d "$1" -f "${2:-$IMPL}" ;;
    esac
    P -d "$1" <<'SQL'
create schema bench;
-- Grow document 1 by random-position inserts of 8-char words from three
-- replicas, with a delete of 1..8 chars for every tenth step, until it has
-- `target` visible chars. Commits every 500 steps.
create procedure bench.grow(d text, target int) language plpgsql as $$
declare
    i int := 0;
    len int;
begin
    perform setseed(0.25);
    loop
        len := crdt.ydoc_length(d);
        exit when len >= target;
        i := i + 1;
        if i % 10 = 0 and len > 16 then
            perform crdt.ydoc_delete(d, floor(random() * (len - 8))::int, 1 + floor(random() * 8)::int, 'w' || i % 3);
        else
            perform crdt.ydoc_insert(d, floor(random() * (len + 1))::int,
                                     substr(md5(i::text), 1, least(8, target - len)), 'w' || i % 3);
        end if;
        if i % 500 = 0 then commit; end if;
    end loop;
end;
$$;
SQL
}

echo "Postgres: $(PT -d postgres -c 'show server_version')"
if [ "$(uname -s)" = Darwin ]; then
    echo "Machine:  $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) CPU, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)"
fi
echo "Impl:     ${IMPL#$EXT_DIR/}"
echo "Date:     $(date '+%Y-%m-%d %H:%M %Z')"
echo

# --- pgbench helpers --------------------------------------------------------
CHUNK=$(python3 -c "print(('lorem ipsum dolor sit amet, consectetur adipiscing elit. ' * 20)[:1000])")
PARA=$(python3 -c "print(('A replaced paragraph of about three hundred characters. ' * 6)[:300])")
cat > "$WORK/ins1.sql" <<'EOF'
select crdt.ydoc_insert('1', (random() * crdt.ydoc_length('1'))::int, 'x', 'bench');
EOF
cat > "$WORK/del1.sql" <<'EOF'
select crdt.ydoc_delete('1', (random() * (crdt.ydoc_length('1') - 1))::int, 1, 'bench');
EOF
printf "select crdt.ydoc_insert('1', (random() * crdt.ydoc_length('1'))::int, '%s', 'bench');\n" "$CHUNK" > "$WORK/paste.sql"
printf "select crdt.ydoc_set('1', overlay(s.v placing '%s' from s.p for 300), 'bench') from (select crdt.ydoc_value('1') as v, 1 + floor(random() * (crdt.ydoc_length('1') - 300))::int as p) s;\n" "$PARA" > "$WORK/set.sql"
cat > "$WORK/value.sql" <<'EOF'
select length(crdt.ydoc_value('1'));
EOF
cat > "$WORK/since_cur.sql" <<'EOF'
select length(crdt.ydoc_ops_since('1', crdt.ydoc_version('1'))::text);
EOF
cat > "$WORK/since_all.sql" <<'EOF'
select length(crdt.ydoc_ops_since('1', '{}')::text);
EOF
cat > "$WORK/version.sql" <<'EOF'
select crdt.ydoc_version('1');
EOF

# bench_op db script transactions [clients] -> "latency_ms wal_bytes_per_tx tps"
# CHECKPOINT, then a warm-up run of the same size (not measured: it takes the
# full-page images of the pages it touches), then the measured run. So WAL is
# close to the steady state; the first edits after a checkpoint log more.
bench_op() {
    local db=$1 script=$2 n=$3 c=${4:-1}
    PT -d "$db" -c checkpoint
    "$PGBIN/pgbench" -n -f "$script" -t "$n" -c "$c" -j "$c" "$db" >/dev/null 2>&1
    local l0 l1 out
    l0=$(PT -d "$db" -c "select pg_current_wal_insert_lsn()")
    out=$("$PGBIN/pgbench" -n -f "$script" -t "$n" -c "$c" -j "$c" "$db" 2>&1)
    l1=$(PT -d "$db" -c "select pg_current_wal_insert_lsn()")
    local lat tps wal
    lat=$(printf '%s\n' "$out" | sed -n 's/^latency average = \([0-9.]*\) ms$/\1/p')
    tps=$(printf '%s\n' "$out" | sed -n 's/^tps = \([0-9.]*\) .*/\1/p')
    wal=$(PT -d "$db" -c "select round(pg_wal_lsn_diff('$l1', '$l0') / ($n * $c))")
    # records and full-page images, per transaction
    local rf
    rf="0 0"
    if [ "$l0" != "$l1" ]; then
        rf=$( ("$PGBIN/pg_waldump" -p "$PGCRDT_TMP/data/pg_wal" -s "$l0" -e "$l1" --stats=record 2>/dev/null || true) \
             | awk -v n=$((n * c)) '/^Total/ {printf "%d %d", $3 / n, $5 / n}')
    fi
    echo "$lat $wal $tps ${rf:-0 0}"
}

# ensure_doc size: database b_<size> with document 1 grown to size chars
ensure_doc() {
    local db="b_$1"
    if [ "$(PT -d postgres -c "select count(*) from pg_database where datname = '$db'")" = 0 ]; then
        newdb "$db"
        P -d "$db" -c "select crdt.ydoc_create('1')" -c "call bench.grow('1', $1)" -c "vacuum analyze" >/dev/null
    fi
}

# --- 1. edit and read latency, WAL, storage by size ------------------------
if want sizes; then
if [ $QUICK = 1 ]; then SIZES="1000 10000 100000"; else SIZES="1000 10000 100000 1000000"; fi
echo "### Latency and WAL by document size"
echo
echo "Document built by random-position inserts of 8-char words from three replicas, one delete of 1-8 chars per ten steps (a fragmented document: about 4 chars per row). Latency: pgbench average, one client, one transaction per statement (includes the client round trip). WAL: bytes per transaction, measured after a CHECKPOINT and a warm-up run of the same statements (full_page_writes=on)."
echo
echo "| size (chars) | rows | tombstone rows | blocks | build ms per row | insert 1 char | delete 1 char | paste 1k | set (300-char paragraph) | value() | version() | ops_since(current) | ops_since({}) |"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
WALROWS=""
STORROWS=""
for size in $SIZES; do
    db="b_$size"
    newdb "$db"
    t0=$(python3 -c 'import time; print(time.time())')
    P -d "$db" -c "select crdt.ydoc_create('1')" -c "call bench.grow('1', $size)" >/dev/null
    t1=$(python3 -c 'import time; print(time.time())')
    edits=$(PT -d "$db" -c "select count(*) from crdt.ydoc_items i join crdt.ydoc_replicas r on r.doc = i.doc and r.id = i.replica where r.name like 'w%'")
    build_ms=$(python3 -c "print(round(($t1 - $t0) * 1000 / max(1, $edits), 2))")
    # storage of the document as built, compacted
    P -d "$db" -c "vacuum full crdt.ydoc_items" -c "vacuum full crdt.ydoc_blocks" -c "vacuum full crdt.ydoc_docs" -c "analyze"
    st=$(PT -d "$db" -F ' ' -c "select octet_length(crdt.ydoc_value('1')),
        pg_relation_size('crdt.ydoc_items'), pg_total_relation_size('crdt.ydoc_items') - pg_relation_size('crdt.ydoc_items'),
        pg_total_relation_size('crdt.ydoc_blocks') + pg_total_relation_size('crdt.ydoc_docs') + pg_total_relation_size('crdt.ydoc_deps'),
        round(avg(pg_column_size(i.*))), count(*), (select count(*) from crdt.ydoc_deps), pg_total_relation_size('crdt.ydoc_deps')
        from crdt.ydoc_items i")
    read -r tb heap idx other avgrow nrows ndeps depsb <<<"$st"
    total=$((heap + idx + other))
    ratio=$(python3 -c "print(round($total / $tb, 1))")
    STORROWS="$STORROWS| $size | $tb | $nrows | $avgrow | $heap | $idx | $ndeps | $depsb | $other | $total | ${ratio}x |
"
    if [ "$size" -ge 1000000 ]; then n1=300; np=20; ns=10; nv=10; else n1=500; np=20; ns=30; nv=30; fi
    stats=$(PT -d "$db" -F ' ' -c "select count(*), count(*) filter (where del_gen is not null), (select count(*) from crdt.ydoc_blocks) from crdt.ydoc_items")
    read -r rows tomb blocks <<<"$stats"
    # reads first, then edits that keep the size (insert 1 / delete 1), then
    # set, then paste (which grows the document by 40k chars)
    read -r lv _ _ _ _ < <(bench_op "$db" "$WORK/value.sql" $nv)
    read -r lver _ _ _ _ < <(bench_op "$db" "$WORK/version.sql" $nv)
    read -r lsc _ _ _ _ < <(bench_op "$db" "$WORK/since_cur.sql" $nv)
    read -r lsa _ _ _ _ < <(bench_op "$db" "$WORK/since_all.sql" $nv)
    read -r li wi _ ri fi < <(bench_op "$db" "$WORK/ins1.sql" $n1)
    read -r ld wd _ rd fd < <(bench_op "$db" "$WORK/del1.sql" $n1)
    read -r ls ws _ rs fs < <(bench_op "$db" "$WORK/set.sql" $ns)
    read -r lp wp _ rp fp < <(bench_op "$db" "$WORK/paste.sql" $np)
    echo "| $size | $rows | $tomb | $blocks | $build_ms | $li ms | $ld ms | $lp ms | $ls ms | $lv ms | $lver ms | $lsc ms | $lsa ms |"
    WALROWS="$WALROWS| $size | $wi ($ri + $fi) | $wd ($rd + $fd) | $wp ($rp + $fp) | $ws ($rs + $fs) |
"
done
echo
echo "WAL bytes per edit, one transaction each: total (records + full-page images, from pg_waldump). Full-page images are the first change of each page after a checkpoint; random positions in a large document touch many pages, so they dominate there."
echo
echo "| size (chars) | insert 1 char | delete 1 char | paste 1k | set (300-char paragraph) |"
echo "|---|---|---|---|---|"
printf '%s' "$WALROWS"
echo
echo "Storage of the document as built (VACUUM FULL):"
echo
echo "| size (chars) | text bytes | rows | avg row bytes | items heap | items indexes | deps rows (V3) | deps bytes | blocks + docs + deps | total bytes | total / text |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"
printf '%s' "$STORROWS"
echo
fi

# --- 2. positional index: blocks vs one running sum over the document -------
if want pos; then
echo "### Positional index: blocks vs a running sum over the whole document"
echo
sed 's/language sql immutable parallel safe return 512;/language sql immutable parallel safe return 2147483647;/' "$IMPL" > "$WORK/impl-scan.sql"
echo "| size (chars) | variant | insert 1 char | delete 1 char |"
echo "|---|---|---|---|"
for size in 10000 100000; do
    for variant in blocks scan; do
        db="b_pos_${variant}_$size"
        if [ $variant = scan ]; then newdb "$db" "$WORK/impl-scan.sql"; else newdb "$db"; fi
        P -d "$db" -c "select crdt.ydoc_create('1')" -c "call bench.grow('1', $size)" -c "vacuum analyze" >/dev/null
        read -r li _ _ < <(bench_op "$db" "$WORK/ins1.sql" 500)
        read -r ld _ _ < <(bench_op "$db" "$WORK/del1.sql" 500)
        echo "| $size | $variant | $li ms | $ld ms |"
        psql_admin -c "drop database $db"
    done
done
echo

fi

# --- 3. order key vs a linked list walked by a recursive CTE ---------------
if want render; then
echo "### Render: order key vs pointer chasing (recursive CTE)"
echo
echo "A proxy for 'no order key': each row stores the key of its successor, and render walks the list with a recursive CTE (one index probe per row). An order derived from origins alone needs at least this walk, plus the YjsMod sibling order."
echo
echo "| size (chars) | rows | string_agg order by ord | recursive walk |"
echo "|---|---|---|---|"
for size in 10000 100000; do
    db="b_$size"
    ensure_doc $size
    PT -d "$db" <<'SQL'
create table bench.nxt as select doc, ord, lead(ord) over (order by ord) as next, del_gen, content from crdt.ydoc_items where doc = 1;
create unique index on bench.nxt (doc, ord);
analyze bench.nxt;
create function bench.ms(q text, n int) returns numeric language plpgsql as $$
declare t0 timestamptz; best numeric; x text;
begin
    for i in 1..n loop
        t0 := clock_timestamp(); execute q into x;
        best := least(best, extract(epoch from clock_timestamp() - t0) * 1000);
    end loop;
    return round(best, 2);
end $$;
SQL
    r=$(PT -d "$db" -F ' ' -c "select (select count(*) from bench.nxt),
        bench.ms('select crdt.ydoc_value(''1'')', 5),
        bench.ms('with recursive w(ord, next, del_gen, content, n) as (
                    (select ord, next, del_gen, content, 1 from bench.nxt where doc = 1 order by ord limit 1)
                    union all
                    select x.ord, x.next, x.del_gen, x.content, w.n + 1 from w join bench.nxt x on x.doc = 1 and x.ord = w.next)
                  select string_agg(content, '''' order by n) from w where del_gen is null', 3)")
    read -r rows a b <<<"$r"
    echo "| $size | $rows | $a ms | $b ms |"
done
echo

fi

# --- 4. cached text for full-text search ------------------------------------
if want cache; then
echo "### Cached plain text in the app's table (for full-text search)"
echo
echo "posts(id, body_doc, body_text) with a GIN index on to_tsvector('simple', body_text). 'cached' = the edit also runs update posts set body_text = crdt.ydoc_value(body_doc). WAL per edit and latency, insert 1 char at a random position."
echo
echo "| size (chars) | variant | latency | WAL bytes per edit | FTS query on 1 post |"
echo "|---|---|---|---|---|"
for size in 10000 100000; do
    db="b_$size"
    ensure_doc $size
    P -d "$db" <<'SQL'
create table if not exists bench.nxt (x int);
create or replace function bench.ms(q text, n int) returns numeric language plpgsql as $$
declare t0 timestamptz; best numeric; x text;
begin
    for i in 1..n loop
        t0 := clock_timestamp(); execute q into x;
        best := least(best, extract(epoch from clock_timestamp() - t0) * 1000);
    end loop;
    return round(best, 2);
end $$;
create table bench.posts (id int primary key, body_doc text, body_text text);
insert into bench.posts values (1, '1', crdt.ydoc_value('1'));
create index on bench.posts using gin (to_tsvector('simple', body_text));
vacuum analyze bench.posts;
SQL
    cat > "$WORK/ins1_cached.sql" <<'EOF'
begin;
select crdt.ydoc_insert('1', (random() * crdt.ydoc_length('1'))::int, 'x', 'bench');
update bench.posts set body_text = crdt.ydoc_value(body_doc) where id = 1;
commit;
EOF
    read -r l1 w1 _ < <(bench_op "$db" "$WORK/ins1.sql" 300)
    read -r l2 w2 _ < <(bench_op "$db" "$WORK/ins1_cached.sql" 300)
    q1=$(PT -d "$db" -c "select bench.ms(\$q\$select count(*)::text from bench.posts where id = 1 and to_tsvector('simple', crdt.ydoc_value(body_doc)) @@ to_tsquery('simple', 'lorem')\$q\$, 5)")
    q2=$(PT -d "$db" -c "select bench.ms(\$q\$select count(*)::text from bench.posts where to_tsvector('simple', body_text) @@ to_tsquery('simple', 'lorem')\$q\$, 5)")
    echo "| $size | render on read | $l1 ms | $w1 | $q1 ms |"
    echo "| $size | cached column | $l2 ms | $w2 | $q2 ms |"
done
echo

fi

# --- 5. concurrency: N sessions editing one document ------------------------
if want conc; then
echo "### Concurrency: N sessions inserting at random positions"
echo
echo "pgbench -c N -j N, 300 transactions per client, 10k-char document. 'one doc': every client edits document 1 (writes serialize on its row lock). 'own doc': each client edits its own copy of it (documents 2-9; baseline)."
echo
db=b_conc
newdb "$db"
P -d "$db" -c "select crdt.ydoc_create(g::text) from generate_series(1, 9) g" >/dev/null
P -d "$db" -c "call bench.grow('1', 10000)" >/dev/null
P -d "$db" -c "delete from crdt.ydoc_blocks where doc > 1" >/dev/null
for d in 2 3 4 5 6 7 8 9; do P -d "$db" -c "insert into crdt.ydoc_items (doc, ord, ins, seq, ol_seq, or_seq, replica, ol_replica, or_replica, del_gen, len, content) select $d, ord, ins, seq, ol_seq, or_seq, replica, ol_replica, or_replica, del_gen, len, content from crdt.ydoc_items where doc = 1" -c "insert into crdt.ydoc_blocks select $d, lo, vis, n from crdt.ydoc_blocks where doc = 1" -c "update crdt.ydoc_docs set len = (select len from crdt.ydoc_docs where id = 1) where id = $d" >/dev/null; done
P -d "$db" -c "vacuum analyze"
cat > "$WORK/ins_own.sql" <<'EOF'
\set d 2 + :client_id
select crdt.ydoc_insert(:d::text, (random() * crdt.ydoc_length(:d::text))::int, 'x', 'c' || :client_id);
EOF
cat > "$WORK/ins_one.sql" <<'EOF'
select crdt.ydoc_insert('1', (random() * crdt.ydoc_length('1'))::int, 'x', 'c' || :client_id);
EOF
echo "| clients | one doc: tps | one doc: latency | own doc: tps | own doc: latency |"
echo "|---|---|---|---|---|"
for c in 1 2 4 8; do
    read -r l1 _ t1 _ _ < <(bench_op "$db" "$WORK/ins_one.sql" 300 $c)
    read -r l2 _ t2 _ _ < <(bench_op "$db" "$WORK/ins_own.sql" 300 $c)
    echo "| $c | ${t1%.*} | $l1 ms | ${t2%.*} | $l2 ms |"
done
lost=$(PT -d "$db" -c "select (select sum(v::int) from jsonb_each_text(crdt.ydoc_version('1')) e(k, v) where k like 'c%') = 2 * 300 * (1 + 2 + 4 + 8)")
echo
echo "Every concurrent insert integrated exactly once (the version vector of document 1 counts the 9,000 inserts of the clients, warm-up runs included): $lost"
echo

echo
fi

# --- 6a. offline merge -------------------------------------------------------
if want merge; then
echo "### Offline merge"
echo
echo "Two servers share a 10k-char document, then each makes N edits (random-position inserts of 1-8 chars, every fifth a delete) without syncing. Then each applies ydoc_ops_since(other, own version) from the other. Time of one merge call, and the size of the ops."
echo
echo "| N edits per side | ops_since + merge (ms) | ops bytes | converged |"
echo "|---|---|---|---|"
db=b_merge
newdb "$db"
P -d "$db" -c "select crdt.ydoc_create('1')" -c "call bench.grow('1', 10000)" >/dev/null
for n in 100 1000 5000; do
    r=$(PT -d "$db" -F ' ' <<SQL | tail -1
select crdt.ydoc_create() as x, crdt.ydoc_create() as y \gset
select crdt.ydoc_merge(:'x', crdt.ydoc_ops_since('1', '{}')), crdt.ydoc_merge(:'y', crdt.ydoc_ops_since('1', '{}'));
select set_config('bench.x', :'x', false), set_config('bench.y', :'y', false);
do \$\$
declare l int; d text;
begin
    perform setseed(0.6);
    for i in 1..$n loop
        foreach d in array array[current_setting('bench.x'), current_setting('bench.y')] loop
            l := crdt.ydoc_length(d);
            if i % 5 = 0 then perform crdt.ydoc_delete(d, floor(random() * (l - 4))::int, 1 + floor(random() * 4)::int, 's' || d);
            else perform crdt.ydoc_insert(d, floor(random() * (l + 1))::int, substr(md5(random()::text), 1, 1 + floor(random() * 8)::int), 's' || d);
            end if;
        end loop;
    end loop;
end \$\$;
select crdt.ydoc_version(:'x') as vx, crdt.ydoc_version(:'y') as vy \gset
select octet_length(crdt.ydoc_ops_since(:'x', :'vy')::text) as bytes \gset
select clock_timestamp() as t0 \gset
select crdt.ydoc_merge(:'y', crdt.ydoc_ops_since(:'x', :'vy')) \g /dev/null
select round(extract(epoch from clock_timestamp() - :'t0'::timestamptz) * 1000) as ms \gset
select crdt.ydoc_merge(:'x', crdt.ydoc_ops_since(:'y', :'vx')) \g /dev/null
select :ms, :bytes, crdt.ydoc_value(:'x') = crdt.ydoc_value(:'y');
SQL
)
    read -r ms bytes ok <<<"$r"
    echo "| $n | $ms | $bytes | $ok |"
done
echo

fi

# --- 6b. order key: bytea fractional keys vs bigint labels -------------------
if want keys; then
if [ -f "$TRACE_DIR/automerge-paper.patches.jsonl" ] && [ -f "$HERE/variants/bytea-keys.sql" ]; then
    echo "### Order key: byte-string fractional keys vs bigint labels with relabelling"
    echo
    echo "First 100,000 ops of automerge-paper, local replay (insert/delete by position), commit every 1,000 ops."
    echo
    echo "| variant | us per op | WAL bytes per op | rows | avg key bytes | max key bytes | ord index bytes |"
    echo "|---|---|---|---|---|---|---|"
    for variant in labels bytea; do
        db=b_key_$variant
        if [ $variant = bytea ]; then newdb "$db" "$HERE/variants/bytea-keys.sql"; else newdb "$db"; fi
        r=$(PT -d "$db" -F ' ' <<SQL | tail -1
create table bench.patches (n bigserial primary key, p jsonb);
\copy bench.patches (p) from '$TRACE_DIR/automerge-paper.patches.jsonl' with (format csv, delimiter E'\x01', quote E'\x02')
delete from bench.patches where n > 100000;
create table bench.r (ms numeric, wal numeric);
create procedure bench.go() language plpgsql as \$\$
declare r record; t0 timestamptz := clock_timestamp(); l0 pg_lsn := pg_current_wal_insert_lsn(); k int := 0;
begin
    -- ydoc_create of the extension takes the id; the bytea variant (older, bigint ids) does not
    if to_regprocedure('crdt.ydoc_create(text)') is not null then perform crdt.ydoc_create('1'); else perform crdt.ydoc_create(); end if;
    for r in select p from bench.patches order by n loop
        if (r.p ->> 1)::int > 0 then perform crdt.ydoc_delete('1', (r.p ->> 0)::int, (r.p ->> 1)::int, 'paper');
        else perform crdt.ydoc_insert('1', (r.p ->> 0)::int, r.p ->> 2, 'paper'); end if;
        k := k + 1;
        if k % 1000 = 0 then commit; end if;
    end loop;
    insert into bench.r values (extract(epoch from clock_timestamp() - t0) * 1000, pg_wal_lsn_diff(pg_current_wal_insert_lsn(), l0));
end \$\$;
checkpoint;
call bench.go();
select round(ms * 1000 / 100000), round(wal / 100000), (select count(*) from crdt.ydoc_items),
       (select round(avg(pg_column_size(ord)), 1) from crdt.ydoc_items), (select max(pg_column_size(ord)) from crdt.ydoc_items),
       pg_relation_size(case when '$variant' = 'bytea' then 'crdt.ydoc_items_pkey' else 'crdt.ydoc_items_ord' end::regclass)
from bench.r;
SQL
)
        echo "| $variant | $(echo $r | tr ' ' '|' | sed 's/|/ | /g') |"
        psql_admin -c "drop database $db"
    done
    echo
fi

fi

# --- 6c. storage: ydoc_compact -----------------------------------------------
if want compact && [ -f "$TRACE_DIR/automerge-paper.patches.jsonl" ]; then
    echo "### Storage: ydoc_compact"
    echo
    echo "Before and after crdt.ydoc_compact(doc) (horizon = now). 'trace': the automerge-paper document after a local replay (commit every 5,000 ops). 'random 100k': the 100k-char random-insert document of the size table. Sizes after VACUUM FULL. Latency and WAL per edit as in the size table (pgbench, warm-up run, records + full-page images); value() is the render."
    echo
    echo "| document | state | rows | tombstone rows | total bytes | bytes per char | insert 1 char | delete 1 char | value() | WAL per insert | WAL per delete |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
    db=b_compact
    newdb "$db"
    P -d "$db" <<SQL
create table bench.patches (n bigserial primary key, p jsonb);
\copy bench.patches (p) from '$TRACE_DIR/automerge-paper.patches.jsonl' with (format csv, delimiter E'\x01', quote E'\x02')
create procedure bench.replay() language plpgsql as \$\$
declare r record; k int := 0;
begin
    perform crdt.ydoc_create('1');
    for r in select p from bench.patches order by n loop
        if (r.p ->> 1)::int > 0 then perform crdt.ydoc_delete('1', (r.p ->> 0)::int, (r.p ->> 1)::int, 'paper');
        else perform crdt.ydoc_insert('1', (r.p ->> 0)::int, r.p ->> 2, 'paper'); end if;
        k := k + 1;
        if k % 5000 = 0 then commit; end if;
    end loop;
end \$\$;
call bench.replay();
drop table bench.patches;
SQL
    ensure_doc 100000
    for pair in "trace b_compact" "random_100k b_100000"; do
        set -- $pair
        name=$1; db=$2
        for state in before after; do
            if [ $state = after ]; then
                t0=$(python3 -c 'import time; print(time.time())')
                l0=$(PT -d "$db" -c "select pg_current_wal_insert_lsn()")
                removed=$(PT -d "$db" -c "select crdt.ydoc_compact('1')")
                l1=$(PT -d "$db" -c "select pg_current_wal_insert_lsn()")
                t1=$(python3 -c 'import time; print(time.time())')
                cms=$(python3 -c "print(round(($t1 - $t0) * 1000))")
                cwal=$(PT -d "$db" -c "select pg_size_pretty(pg_wal_lsn_diff('$l1', '$l0'))")
                COMPACT_NOTES="$COMPACT_NOTES
- $name: ydoc_compact removed $removed rows in $cms ms, $cwal of WAL."
            fi
            P -d "$db" -c "vacuum full crdt.ydoc_items" -c "vacuum full crdt.ydoc_blocks" -c "vacuum full crdt.ydoc_docs" -c "analyze"
            st=$(PT -d "$db" -F ' ' -c "select (select count(*) from crdt.ydoc_items where doc = 1),
                (select count(*) from crdt.ydoc_items where doc = 1 and del_gen is not null),
                pg_total_relation_size('crdt.ydoc_items') + pg_total_relation_size('crdt.ydoc_blocks') + pg_total_relation_size('crdt.ydoc_docs'),
                crdt.ydoc_length('1')")
            read -r rows tomb total len <<<"$st"
            per=$(python3 -c "print(round($total / $len, 1))")
            read -r lv _ _ _ _ < <(bench_op "$db" "$WORK/value.sql" 20)
            read -r li wi _ ri fi < <(bench_op "$db" "$WORK/ins1.sql" 500)
            read -r ld wd _ rd fd < <(bench_op "$db" "$WORK/del1.sql" 500)
            echo "| $name | $state | $rows | $tomb | $total | $per | $li ms | $ld ms | $lv ms | $wi ($ri + $fi) | $wd ($rd + $fd) |"
        done
    done
    printf '%s\n\n' "$COMPACT_NOTES"
fi

# --- 6d. replica ids: a short id vs a UUID -----------------------------------
if want replica && [ -f "$TRACE_DIR/automerge-paper.patches.jsonl" ]; then
    echo "### Replica id length: 'paper' vs a 36-char UUID"
    echo
    echo "automerge-paper, local replay as replica R (commit every 5,000 ops), then pgbench edits as a second replica of the same kind (insert/delete 1 char, 500 each, warm-up run; WAL = records + full-page images), value(); sizes after VACUUM FULL, before and after ydoc_compact(doc)."
    echo
    echo "| replica ids | rows | bytes per char | bytes per char after compact | insert 1 char | delete 1 char | value() | WAL per insert | WAL per delete | replay us per op |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
    for kind in short uuid; do
        if [ $kind = short ]; then R=paper; R2=bench; else R=6f1c2a0e-3b7d-4c55-9e21-8a4f0d6b7c19; R2=0b9e5d4a-71c3-4f08-a6d2-5c8e1f3a9b70; fi
        db=b_rep_$kind
        newdb "$db"
        P -d "$db" <<SQL
create table bench.patches (n bigserial primary key, p jsonb);
\copy bench.patches (p) from '$TRACE_DIR/automerge-paper.patches.jsonl' with (format csv, delimiter E'\x01', quote E'\x02')
create table bench.r (ms numeric);
create procedure bench.replay(rep text) language plpgsql as \$\$
declare r record; k int := 0; t0 timestamptz := clock_timestamp();
begin
    perform crdt.ydoc_create('1');
    for r in select p from bench.patches order by n loop
        if (r.p ->> 1)::int > 0 then perform crdt.ydoc_delete('1', (r.p ->> 0)::int, (r.p ->> 1)::int, rep);
        else perform crdt.ydoc_insert('1', (r.p ->> 0)::int, r.p ->> 2, rep); end if;
        k := k + 1;
        if k % 5000 = 0 then commit; end if;
    end loop;
    insert into bench.r values (extract(epoch from clock_timestamp() - t0) * 1000);
end \$\$;
call bench.replay('$R');
drop table bench.patches;
vacuum full crdt.ydoc_items;
vacuum full crdt.ydoc_blocks;
analyze;
SQL
        st=$(PT -d "$db" -F ' ' -c "select (select count(*) from crdt.ydoc_items),
            round((pg_total_relation_size('crdt.ydoc_items') + pg_total_relation_size('crdt.ydoc_blocks'))::numeric / crdt.ydoc_length('1'), 1),
            round((select ms from bench.r) * 1000 / 259778)")
        read -r rows per us <<<"$st"
        printf "select crdt.ydoc_insert('1', (random() * crdt.ydoc_length('1'))::int, 'x', '%s');\n" "$R2" > "$WORK/ins_r.sql"
        printf "select crdt.ydoc_delete('1', (random() * (crdt.ydoc_length('1') - 1))::int, 1, '%s');\n" "$R2" > "$WORK/del_r.sql"
        read -r lv _ _ _ _ < <(bench_op "$db" "$WORK/value.sql" 20)
        read -r li wi _ ri fi < <(bench_op "$db" "$WORK/ins_r.sql" 500)
        read -r ld wd _ rd fd < <(bench_op "$db" "$WORK/del_r.sql" 500)
        per2=$(PT -d "$db" -c "select crdt.ydoc_compact('1')" -c "vacuum full crdt.ydoc_items" -c "vacuum full crdt.ydoc_blocks" \
            -c "select round((pg_total_relation_size('crdt.ydoc_items') + pg_total_relation_size('crdt.ydoc_blocks'))::numeric / crdt.ydoc_length('1'), 1)" | tail -1)
        echo "| $kind | $rows | $per | $per2 | $li ms | $ld ms | $lv ms | $wi ($ri + $fi) | $wd ($rd + $fd) | $us |"
        psql_admin -c "drop database $db"
    done
    echo
fi

# --- 6. editing trace --------------------------------------------------------
if want trace; then
if [ -f "$TRACE_DIR/automerge-paper.patches.jsonl" ]; then
    echo "### automerge-paper trace"
    echo
    db=b_trace
    # count relabels: the same impl with one logging line
    python3 - "$IMPL" "$WORK/impl-instr.sql" <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace("    olds := la || ra;\n", "    olds := la || ra;\n    insert into public.bench_relabel_log values (nl + nr);\n", 1)
open(sys.argv[2], 'w').write("create table public.bench_relabel_log (rows int);\n" + s)
PY
    newdb "$db" "$WORK/impl-instr.sql"
    if [ $QUICK = 1 ]; then LIMIT=50000; else LIMIT=1000000; fi
    P -d "$db" <<SQL
create table bench.patches (n bigserial primary key, p jsonb);
\copy bench.patches (p) from '$TRACE_DIR/automerge-paper.patches.jsonl' with (format csv, delimiter E'\x01', quote E'\x02')
create table bench.ops (n bigserial primary key, op jsonb);
\copy bench.ops (op) from '$TRACE_DIR/automerge-paper.ops.jsonl' with (format csv, delimiter E'\x01', quote E'\x02')
create table bench.batch (n bigserial primary key, op jsonb);
\copy bench.batch (op) from '$TRACE_DIR/automerge-paper.batch100.jsonl' with (format csv, delimiter E'\x01', quote E'\x02')
delete from bench.patches where n > $LIMIT;
delete from bench.ops where n > $LIMIT;
create table bench.result (what text, ops int, ms numeric, wal numeric);
-- 1. local edits by position, one transaction per op (commit per op)
create procedure bench.replay_local(d text) language plpgsql as \$\$
declare r record; t0 timestamptz := clock_timestamp(); l0 pg_lsn := pg_current_wal_insert_lsn(); k int := 0;
begin
    for r in select p from bench.patches order by n loop
        if (r.p ->> 1)::int > 0 then perform crdt.ydoc_delete(d, (r.p ->> 0)::int, (r.p ->> 1)::int, 'paper');
        else perform crdt.ydoc_insert(d, (r.p ->> 0)::int, r.p ->> 2, 'paper'); end if;
        k := k + 1;
        commit;
    end loop;
    insert into bench.result values ('local insert/delete by position, commit per op', k,
        extract(epoch from clock_timestamp() - t0) * 1000, pg_wal_lsn_diff(pg_current_wal_insert_lsn(), l0));
    commit;
end \$\$;
-- 2. the same ops through ydoc_merge (the remote path), commit per op
create procedure bench.replay_merge(d text, tbl text) language plpgsql as \$\$
declare r record; t0 timestamptz := clock_timestamp(); l0 pg_lsn := pg_current_wal_insert_lsn(); k int := 0;
begin
    for r in execute format('select op from bench.%I order by n', tbl) loop
        perform crdt.ydoc_merge(d, r.op);
        k := k + 1;
        commit;
    end loop;
    insert into bench.result values ('ydoc_merge of ' || tbl || ', commit per call', k,
        extract(epoch from clock_timestamp() - t0) * 1000, pg_wal_lsn_diff(pg_current_wal_insert_lsn(), l0));
    commit;
end \$\$;
-- 3. the same ops through ydoc_apply (the untrusted path, rules V0-V7), commit per op
create procedure bench.replay_apply(d text, tbl text) language plpgsql as \$\$
declare r record; t0 timestamptz := clock_timestamp(); l0 pg_lsn := pg_current_wal_insert_lsn(); k int := 0;
begin
    for r in execute format('select op from bench.%I order by n', tbl) loop
        perform crdt.ydoc_apply(d, r.op, 'paper');
        k := k + 1;
        commit;
    end loop;
    insert into bench.result values ('ydoc_apply (validated) of ' || tbl || ', commit per call', k,
        extract(epoch from clock_timestamp() - t0) * 1000, pg_wal_lsn_diff(pg_current_wal_insert_lsn(), l0));
    commit;
end \$\$;
SQL
    P -d "$db" -c "select crdt.ydoc_create('1'), crdt.ydoc_create('2'), crdt.ydoc_create('3'), crdt.ydoc_create('4'), crdt.ydoc_create('5')" >/dev/null
    P -d "$db" -c checkpoint -c "call bench.replay_local('1')"
    P -d "$db" -c checkpoint -c "call bench.replay_merge('2', 'ops')"
    if [ $QUICK = 0 ]; then P -d "$db" -c checkpoint -c "call bench.replay_merge('3', 'batch')"; fi
    P -d "$db" -c checkpoint -c "call bench.replay_apply('4', 'ops')"
    if [ $QUICK = 0 ]; then P -d "$db" -c checkpoint -c "call bench.replay_apply('5', 'batch')"; fi
    P -d "$db" -c "vacuum analyze"
    echo "| replay | calls | total s | us per call | WAL bytes per call | final text md5 ok |"
    echo "|---|---|---|---|---|---|"
    PT -d "$db" -F ' ' -c "select what, ops, round(ms / 1000, 1), round(ms * 1000 / ops), round(wal / ops),
        case when what like 'local%' then md5(crdt.ydoc_value('1'))
             when what like 'ydoc_apply%batch%' then md5(crdt.ydoc_value('5'))
             when what like 'ydoc_apply%' then md5(crdt.ydoc_value('4'))
             when what like '%batch%' then md5(crdt.ydoc_value('3')) else md5(crdt.ydoc_value('2')) end = 'f6ee9cff45a87f3b7f29d60920bfce10'
        from bench.result order by what" | while read -r line; do
        what=$(printf '%s' "$line" | sed 's/ [0-9.]* [0-9.]* [0-9.]* [0-9.]* [tf]$//')
        rest=${line#"$what "}
        set -- $rest
        echo "| $what | $1 | $2 | $3 | $4 | $5 |"
    done
    echo
    echo "Document after the trace (document 1, local replay):"
    echo
    PT -d "$db" -F ' | ' -c "select '| ' || crdt.ydoc_length('1'), octet_length(crdt.ydoc_value('1')), count(*), count(*) filter (where del_gen is not null),
        (select count(*) || ' (' || coalesce(sum(rows), 0) || ' rows rewritten)' from public.bench_relabel_log),
        pg_size_pretty(pg_total_relation_size('crdt.ydoc_items') / 5) || ' |' from crdt.ydoc_items where doc = 1" \
        | sed '1i\
| chars | text bytes | rows | tombstone rows | relabels (all five replays) | items + indexes (per doc, approx) |\
|---|---|---|---|---|---|'
    echo
fi
fi
