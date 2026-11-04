/*
 * pg_crdt experiment, shape B: table-backed text documents (ydoc_).
 *
 * Loads after pg_crdt--0.0.1.sql into the same `crdt` schema. Contract:
 * research/text.md (op wire format, YjsMod order). Design and measurements:
 * experiments/text-table/NOTES.md.
 *
 *   ydoc_docs     one row per document: visible length, write counter (gen)
 *   ydoc_replicas replica ids (entry keys), interned: rows hold an integer
 *   ydoc_items    one row per run of characters: id (replica, seq), length,
 *                 origins of its first character, content, tombstone (del_gen),
 *                 and `ord`, a server-local order label (bigint)
 *   ydoc_blocks   a positional index: per label range, visible length and rows
 *   ydoc_pending  inserts waiting for their origins (causal buffering)
 *   ydoc_pending_deletes  deletes of ids not seen yet
 *
 * The order label is a cache of the YjsMod order, local to this database; it
 * is not part of the wire format. Every write locks the document row first,
 * so writes to one document are serialized and each incoming run is
 * integrated against a stable sequence: the YjsMod scan between originLeft
 * and originRight is an index range scan on (doc, ord), and render is
 * string_agg(content order by ord).
 *
 * Labels are list labeling (order maintenance): a new row takes the midpoint
 * of its neighbours' labels; when there is no integer between them, a window
 * of rows around the spot is relabelled evenly. Labels stay 8 bytes. (Byte
 * string fractional keys, the first version, grew to 288 bytes on the
 * automerge-paper trace; see NOTES.md and variants/bytea-keys.sql.)
 */

-- ============================================================================
-- ydoc_: tables
-- ============================================================================

create table crdt.ydoc_docs (
    id  bigint generated always as identity primary key,
    len integer not null default 0,   -- visible code points
    gen bigint not null default 0,    -- +1 per write call; stamps deletes
    horizon bigint not null default 0 -- ydoc_compact: deletes at or before it may be merged
);

-- Integration order of rows. Writes to one document are serialized, so per
-- document this is the order in which runs were integrated: causal.
create sequence crdt.ydoc_ins;

-- Column order: the columns that change in place (del_gen, len, content) come
-- last, so a same-page update logs only them. ord is unique per document by
-- construction; the index is not unique so that a relabel can rewrite a
-- window of labels in one statement.
-- Replica ids (entry keys: `id` or `id:device`), interned for the whole
-- database. A row names its replica and its origins' replicas with these
-- integers, so an id costs 4 bytes per use however long it is (UUIDs are 36
-- chars). The integer is local to this database and never leaves it: ops in
-- and out carry names, and the YjsMod tie-break compares names (collate "C"),
-- never these integers. Rows are never deleted (ids live as long as the
-- characters that carry them).
create table crdt.ydoc_replicas (
    id   integer generated always as identity primary key,
    name text collate "C" not null unique
);

create table crdt.ydoc_items (
    doc        bigint not null,
    ord        bigint not null,
    ins        bigint not null default nextval('crdt.ydoc_ins'),  -- integration order (causal), for ops_since
    seq        integer not null,
    replica    integer not null,      -- crdt.ydoc_replicas.id
    ol_seq     integer,
    ol_replica integer,
    or_seq     integer,
    or_replica integer,
    del_gen    bigint,                -- null: visible; else the gen of the delete
    len        integer not null,
    content    text not null,
    primary key (doc, replica, seq)
) with (fillfactor = 90);
create index ydoc_items_ord on crdt.ydoc_items (doc, ord);

-- Block b covers the labels from b.lo up to the next block's lo. The first
-- block of a document has lo = the smallest bigint. Positions are found with
-- a running sum over the blocks, then over the rows of one block.
create table crdt.ydoc_blocks (
    doc bigint not null,
    lo  bigint not null,
    vis integer not null default 0,
    n   integer not null default 0,
    primary key (doc, lo)
) with (fillfactor = 50);

-- The buffers keep replica names: they hold input that may never become
-- ready (forged or far-ahead ids), which should not grow ydoc_replicas.
create table crdt.ydoc_pending (
    doc        bigint not null,
    replica    text collate "C" not null,
    seq        integer not null,
    ol_replica text collate "C",
    ol_seq     integer,
    or_replica text collate "C",
    or_seq     integer,
    content    text not null,
    primary key (doc, replica, seq)
);
create index ydoc_pending_ol on crdt.ydoc_pending (doc, ol_replica, ol_seq);
create index ydoc_pending_or on crdt.ydoc_pending (doc, or_replica, or_seq);

create table crdt.ydoc_pending_deletes (
    doc     bigint not null,
    replica text collate "C" not null,
    seq     integer not null,
    len     integer not null,
    primary key (doc, replica, seq)
);

-- pg_dump skips the contents of an extension's tables unless they are marked.
-- Only possible inside CREATE EXTENSION (pg_tle or the control file).
do $$
begin
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_docs', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_replicas', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_items', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_blocks', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_pending', '');
    perform pg_catalog.pg_extension_config_dump('crdt.ydoc_pending_deletes', '');
exception when others then
    null;
end;
$$;

-- ============================================================================
-- ydoc_: internals
-- ============================================================================

-- Tuning constants (functions so variants can replace them).
-- Longest run kept in one row: bounds the WAL of a split or an append.
create function crdt._ydoc_run_cap() returns integer
language sql immutable parallel safe return 256;
-- A block splits in two when it holds more rows than this.
create function crdt._ydoc_block_max() returns integer
language sql immutable parallel safe return 512;
-- Labels live in [-2^60, 2^60]; appends step by 2^30; a relabel spreads
-- rows at least 2^20 apart (20 more halvings at the same spot).
create function crdt._ydoc_label_bound() returns bigint
language sql immutable parallel safe return 1152921504606846976;
create function crdt._ydoc_label_step() returns bigint
language sql immutable parallel safe return 1073741824;
create function crdt._ydoc_label_gap() returns bigint
language sql immutable parallel safe return 1048576;

-- A label strictly between lo and hi (null: unbounded), or null if there is
-- none: the midpoint, or a step past the last (first) label.
create function crdt._ydoc_label(lo bigint, hi bigint)
returns bigint
language sql immutable parallel safe
return case
    when lo is null and hi is null then 0
    when hi is null then case when lo <= crdt._ydoc_label_bound() - crdt._ydoc_label_step() then lo + crdt._ydoc_label_step()
                              when crdt._ydoc_label_bound() - lo >= 2 then lo + (crdt._ydoc_label_bound() - lo) / 2 end
    when lo is null then case when hi >= crdt._ydoc_label_step() - crdt._ydoc_label_bound() then hi - crdt._ydoc_label_step()
                              when hi + crdt._ydoc_label_bound() >= 2 then hi - (hi + crdt._ydoc_label_bound()) / 2 end
    when hi - lo >= 2 then lo + (hi - lo) / 2
end;

-- Makes room between the rows labelled p_prev and p_next (adjacent rows; one
-- may be null for the start or the end). Takes k rows on each side, doubling
-- k until the labels around the window leave at least label_gap per row (or
-- the window is the whole document), and spreads the window evenly, with a
-- double gap between the two sides. Blocks follow their first row. Returns
-- the new labels of the two rows.
create function crdt._ydoc_relabel(p_doc bigint, p_prev bigint, p_next bigint,
    out new_prev bigint, out new_next bigint)
language plpgsql volatile
as $$
declare
    k integer := 8;
    la bigint[];
    ra bigint[];
    lo bigint;
    hi bigint;
    nl integer;
    nr integer;
    sp bigint;
    olds bigint[];
    news bigint[];
    bound bigint := crdt._ydoc_label_bound();
begin
    loop
        la := '{}';
        ra := '{}';
        if p_prev is not null then
            select coalesce(array_agg(x.ord order by x.ord), '{}') into la from (
                select i.ord from crdt.ydoc_items i where i.doc = p_doc and i.ord <= p_prev
                order by i.ord desc limit k) x;
        end if;
        if p_next is not null then
            select coalesce(array_agg(x.ord order by x.ord), '{}') into ra from (
                select i.ord from crdt.ydoc_items i where i.doc = p_doc and i.ord >= p_next
                order by i.ord limit k) x;
        end if;
        nl := pg_catalog.cardinality(la);
        nr := pg_catalog.cardinality(ra);
        lo := -bound - 1;
        hi := bound + 1;
        if nl > 0 then
            select i.ord into lo from crdt.ydoc_items i where i.doc = p_doc and i.ord < la[1]
            order by i.ord desc limit 1;
            lo := coalesce(lo, -bound - 1);
        elsif p_prev is not null then
            raise exception 'crdt._ydoc_relabel: no row labelled %', p_prev using errcode = 'XX000';
        end if;
        if nr > 0 then
            select i.ord into hi from crdt.ydoc_items i where i.doc = p_doc and i.ord > ra[nr]
            order by i.ord limit 1;
            hi := coalesce(hi, bound + 1);
        end if;
        sp := (hi - lo) / (nl + nr + 2);
        exit when sp >= crdt._ydoc_label_gap() or (lo = -bound - 1 and hi = bound + 1);
        k := k * 2;
    end loop;
    if sp < 2 then
        raise exception 'crdt._ydoc_relabel: document % has too many rows', p_doc using errcode = '54000';
    end if;
    olds := la || ra;
    select array_agg(case when g.n <= nl then lo + g.n * sp else lo + (g.n + 1) * sp end order by g.n)
    into news from generate_series(1, nl + nr) g(n);
    update crdt.ydoc_items i set ord = m.new
    from unnest(olds, news) m(old, new)
    where i.doc = p_doc and i.ord = m.old;
    update crdt.ydoc_blocks b set lo = m.new
    from unnest(olds, news) m(old, new)
    where b.doc = p_doc and b.lo = m.old;
    new_prev := case when nl > 0 then news[nl] end;
    new_next := case when nr > 0 then news[nl + 1] end;
end;
$$;

-- A label for a new row between the rows labelled lo and hi; relabels when
-- needed. o_lo and o_hi return the (possibly new) labels of the neighbours.
create function crdt._ydoc_new_label(p_doc bigint, p_lo bigint, p_hi bigint,
    out label bigint, out o_lo bigint, out o_hi bigint)
language plpgsql volatile
as $$
begin
    o_lo := p_lo;
    o_hi := p_hi;
    label := crdt._ydoc_label(p_lo, p_hi);
    if label is null then
        select r.new_prev, r.new_next into o_lo, o_hi from crdt._ydoc_relabel(p_doc, p_lo, p_hi) r;
        label := crdt._ydoc_label(o_lo, o_hi);
    end if;
end;
$$;

-- Highest integrated seq of a replica in a document (0 for none). Integrated
-- ids have no gaps (an insert waits for seq-1), so this is the version vector
-- entry, and (replica, s) is integrated iff s <= clock.
create function crdt._ydoc_clock(p_doc bigint, p_replica integer)
returns integer
language sql stable parallel safe
return coalesce((select i.seq + i.len - 1 from crdt.ydoc_items i
                 where i.doc = p_doc and i.replica = p_replica
                 order by i.seq desc limit 1), 0);

-- Replica name <-> interned integer.
create function crdt._ydoc_rid(p_name text)
returns integer
language sql stable parallel safe
return (select r.id from crdt.ydoc_replicas r where r.name = p_name);

create function crdt._ydoc_rname(p_id integer)
returns text
language sql stable parallel safe
return (select r.name from crdt.ydoc_replicas r where r.id = p_id);

create function crdt._ydoc_rid_make(p_name text)
returns integer
language plpgsql volatile
as $$
declare
    r integer := crdt._ydoc_rid(p_name);
begin
    if r is null then
        insert into crdt.ydoc_replicas (name) values (p_name) on conflict (name) do nothing returning id into r;
        if r is null then
            r := crdt._ydoc_rid(p_name);
        end if;
    end if;
    return r;
end;
$$;

-- The clock of a replica given by name (0 if it has never been seen).
create function crdt._ydoc_clock_name(p_doc bigint, p_name text)
returns integer
language sql stable parallel safe
return crdt._ydoc_clock(p_doc, crdt._ydoc_rid(p_name));

-- Adds to the counters of the block that holds label p_ord; splits it when full.
create function crdt._ydoc_blk(p_doc bigint, p_ord bigint, p_dvis integer, p_dn integer)
returns void
language plpgsql volatile
as $$
declare
    b record;
    hi bigint;
    mid bigint;
    c integer;
    v integer;
begin
    update crdt.ydoc_blocks k set vis = k.vis + p_dvis, n = k.n + p_dn
    where k.doc = p_doc
      and k.lo = (select x.lo from crdt.ydoc_blocks x where x.doc = p_doc and x.lo <= p_ord order by x.lo desc limit 1)
    returning k.lo, k.n into b;
    if b.n <= crdt._ydoc_block_max() then
        return;
    end if;
    -- Split at the middle row.
    select x.lo into hi from crdt.ydoc_blocks x where x.doc = p_doc and x.lo > b.lo order by x.lo limit 1;
    hi := coalesce(hi, 9223372036854775807);
    select i.ord into mid from crdt.ydoc_items i
    where i.doc = p_doc and i.ord >= b.lo and i.ord < hi order by i.ord offset b.n / 2 limit 1;
    select count(*), coalesce(sum(i.len) filter (where i.del_gen is null), 0) into c, v
    from crdt.ydoc_items i where i.doc = p_doc and i.ord >= mid and i.ord < hi;
    update crdt.ydoc_blocks k set vis = k.vis - v, n = k.n - c where k.doc = p_doc and k.lo = b.lo;
    insert into crdt.ydoc_blocks (doc, lo, vis, n) values (p_doc, mid, v, c);
end;
$$;

-- Splits the row that holds char (p_r, p_at) so that it starts a row. The
-- left part keeps its label; returns the label of the right part. The right
-- part's first char has originLeft = its predecessor in the run and the
-- run's originRight, exactly as if the run had been sent as two. A relabel
-- may change other rows' labels: callers re-read labels after a split.
create function crdt._ydoc_split(p_doc bigint, p_r integer, p_at integer)
returns bigint
language plpgsql volatile
as $$
declare
    r record;
    k integer;
    nxt bigint;
    nl record;
begin
    select * into r from crdt.ydoc_items i
    where i.doc = p_doc and i.replica = p_r and i.seq <= p_at order by i.seq desc limit 1;
    k := p_at - r.seq;
    if k <= 0 or k >= r.len then
        raise exception 'crdt._ydoc_split: % is not inside the run', p_at using errcode = 'XX000';
    end if;
    select i.ord into nxt from crdt.ydoc_items i
    where i.doc = p_doc and i.ord > r.ord order by i.ord limit 1;
    select * into nl from crdt._ydoc_new_label(p_doc, r.ord, nxt);
    update crdt.ydoc_items i set len = k, content = pg_catalog.left(r.content, k)
    where i.doc = p_doc and i.replica = p_r and i.seq = r.seq;
    insert into crdt.ydoc_items (doc, ord, ins, seq, ol_seq, or_seq, replica, ol_replica, or_replica, del_gen, len, content)
    values (p_doc, nl.label, r.ins, p_at, p_at - 1, r.or_seq, r.replica, r.replica, r.or_replica, r.del_gen,
            r.len - k, pg_catalog.substr(r.content, k + 1));
    perform crdt._ydoc_blk(p_doc, nl.label, 0, 1);
    return nl.label;
end;
$$;

-- Position of char (replica, seq) in the order: (row label, offset in the row).
create function crdt._ydoc_pos(p_doc bigint, p_replica integer, p_seq integer, out ord bigint, out off integer)
language sql stable
begin atomic
    select i.ord, p_seq - i.seq from crdt.ydoc_items i
    where i.doc = p_doc and i.replica = p_replica and i.seq <= p_seq
    order by i.seq desc limit 1;
end;

-- Integrates one run whose origins and predecessor (replica, s-1) are
-- integrated and whose ids are new. YjsMod (research/text.md), on rows: after
-- splitting so that originLeft ends a row and originRight starts one, every
-- candidate destination is a row boundary, and only the first char of a row
-- can change the scan state (the others have originLeft = their predecessor,
-- which is > left). Returns the visible chars added. Replicas are interned
-- integers; p_rname is the inserting replica's name, for the tie-break.
create function crdt._ydoc_integrate(
    p_doc bigint, p_gen bigint, p_r integer, p_rname text, p_s integer,
    p_olr integer, p_ols integer, p_orr integer, p_ors integer, p_text text)
returns integer
language plpgsql volatile
as $$
declare
    x record;
    o record;
    cur refcursor;
    l_ord bigint;
    l_off integer := -1;
    r_ord bigint;
    prev_ord bigint;
    dest_prev bigint;
    dest_next bigint;
    scanning boolean := false;
    broke boolean := false;
    cl integer;
    cr integer;
    y_ord bigint;
    y_off integer;
    n integer := pg_catalog.length(p_text);
    cap integer := crdt._ydoc_run_cap();
    nl record;
    ci integer;
    part text;
begin
    -- Split so that originLeft ends a row and originRight starts one; then
    -- read the labels (a split can relabel).
    if p_olr is not null then
        select i.seq, i.len into x from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_olr and i.seq <= p_ols order by i.seq desc limit 1;
        if p_ols < x.seq + x.len - 1 then
            perform crdt._ydoc_split(p_doc, p_olr, p_ols + 1);
        end if;
    end if;
    if p_orr is not null then
        select i.seq into y_off from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_orr and i.seq <= p_ors order by i.seq desc limit 1;
        if y_off < p_ors then
            perform crdt._ydoc_split(p_doc, p_orr, p_ors);
        end if;
        select i.ord into r_ord from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_orr and i.seq = p_ors;
    end if;
    if p_olr is not null then
        select i.ord, i.seq, i.len, i.del_gen, i.or_replica, i.or_seq into x from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_olr and i.seq <= p_ols order by i.seq desc limit 1;
        l_ord := x.ord;
        l_off := p_ols - x.seq;
        if r_ord is not null and r_ord <= l_ord then
            raise exception 'crdt.ydoc: insert %:% has originRight before originLeft', p_rname, p_s
                using errcode = '22023';
        end if;
    end if;

    -- The rows strictly between the origins. An explicit cursor, bounded on
    -- both sides when it can be, so the plan is an ordered index range scan
    -- that stops early (a FOR loop over a query got a sort of the document).
    -- This range (l_ord, r_ord) is also where a causal check of an op that
    -- carries its author's version vector belongs: a row here whose ids that
    -- vector covers means the origins were not adjacent for the author.
    prev_ord := l_ord;
    dest_prev := l_ord;
    dest_next := r_ord;
    if r_ord is null then
        open cur for
            select i.ord, i.replica, i.ol_replica, i.ol_seq, i.or_replica, i.or_seq
            from crdt.ydoc_items i
            where i.doc = p_doc and i.ord > coalesce(l_ord, -9223372036854775808)
            order by i.ord;
    else
        open cur for
            select i.ord, i.replica, i.ol_replica, i.ol_seq, i.or_replica, i.or_seq
            from crdt.ydoc_items i
            where i.doc = p_doc and i.ord > coalesce(l_ord, -9223372036854775808) and i.ord < r_ord
            order by i.ord;
    end if;
    loop
        fetch cur into o;
        exit when not found;
        if not scanning then
            dest_prev := prev_ord;
            dest_next := o.ord;
        end if;
        -- o's originLeft against ours
        if o.ol_replica is null then
            cl := case when p_olr is null then 0 else -1 end;
        elsif p_olr is null then
            cl := 1;
        elsif o.ol_replica = p_olr and o.ol_seq = p_ols then
            cl := 0;
        else
            select p.ord, p.off into y_ord, y_off from crdt._ydoc_pos(p_doc, o.ol_replica, o.ol_seq) p;
            cl := case when y_ord < l_ord then -1 when y_ord > l_ord then 1
                       else pg_catalog.sign(y_off - l_off)::integer end;
        end if;
        if cl < 0 then
            broke := true;
            exit;
        end if;
        if cl = 0 then
            -- o's originRight against ours
            if o.or_replica is null then
                cr := case when p_orr is null then 0 else 1 end;
            elsif p_orr is null then
                cr := -1;
            elsif o.or_replica = p_orr and o.or_seq = p_ors then
                cr := 0;
            else
                select p.ord, p.off into y_ord, y_off from crdt._ydoc_pos(p_doc, o.or_replica, o.or_seq) p;
                cr := case when y_ord < r_ord then -1 when y_ord > r_ord then 1
                           else pg_catalog.sign(y_off)::integer end;
            end if;
            if cr < 0 then
                scanning := true;
            elsif cr = 0 then
                -- names, collate "C" (never the interned integers)
                if p_rname collate "C" < crdt._ydoc_rname(o.replica) collate "C" then
                    broke := true;
                    exit;
                end if;
                scanning := false;
            else
                scanning := false;
            end if;
        end if;
        prev_ord := o.ord;
    end loop;
    close cur;
    if not broke and not scanning then
        dest_prev := prev_ord;
        dest_next := r_ord;
    end if;

    -- Typing on: append to the run of the predecessor when it ends just
    -- before us, has our originRight, is visible, and has room.
    if p_olr is not null and p_olr = p_r and p_ols = p_s - 1 and dest_prev = l_ord then
        if x.del_gen is null and x.or_replica is not distinct from p_orr
           and x.or_seq is not distinct from p_ors and x.len + n <= cap then
            update crdt.ydoc_items i set len = i.len + n, content = i.content || p_text
            where i.doc = p_doc and i.replica = p_r and i.seq = x.seq;
            perform crdt._ydoc_blk(p_doc, l_ord, n, 0);
            return n;
        end if;
    end if;

    ci := 0;
    while ci < n loop
        part := pg_catalog.substr(p_text, ci + 1, cap);
        select * into nl from crdt._ydoc_new_label(p_doc, dest_prev, dest_next);
        dest_next := nl.o_hi;
        insert into crdt.ydoc_items (doc, ord, seq, ol_seq, or_seq, replica, ol_replica, or_replica, del_gen, len, content)
        values (p_doc, nl.label, p_s + ci,
                case when ci = 0 then p_ols else p_s + ci - 1 end, p_ors,
                p_r, case when ci = 0 then p_olr else p_r end, p_orr,
                null, pg_catalog.length(part), part);
        perform crdt._ydoc_blk(p_doc, nl.label, pg_catalog.length(part), 1);
        dest_prev := nl.label;
        ci := ci + cap;
    end loop;
    return n;
end;
$$;

-- Tombstones ids (replica, s .. s+n-1). Ids not integrated yet are kept in
-- ydoc_pending_deletes. Already deleted chars keep their first del_gen.
-- Returns the visible chars removed. Rows are addressed by id, not by label,
-- because a split can relabel. p_r is the interned replica (null if never
-- seen); p_rname its name, needed only to buffer (looked up if null).
create function crdt._ydoc_delete_range(p_doc bigint, p_gen bigint, p_r integer, p_rname text, p_s integer, p_n integer)
returns integer
language plpgsql volatile
as $$
declare
    c integer := crdt._ydoc_clock(p_doc, p_r);
    e integer := p_s + p_n - 1;
    first_seq integer;
    x record;
    a integer;
    b integer;
    k bigint;
    removed integer := 0;
begin
    if e > c then
        insert into crdt.ydoc_pending_deletes as pd (doc, replica, seq, len)
        values (p_doc, coalesce(p_rname, crdt._ydoc_rname(p_r)), greatest(p_s, c + 1), e - greatest(p_s, c + 1) + 1)
        on conflict (doc, replica, seq) do update set len = greatest(pd.len, excluded.len);
        e := c;
    end if;
    if e < p_s then
        return 0;
    end if;
    select i.seq into first_seq from crdt.ydoc_items i
    where i.doc = p_doc and i.replica = p_r and i.seq <= p_s order by i.seq desc limit 1;
    for x in
        select i.seq, i.len from crdt.ydoc_items i
        where i.doc = p_doc and i.replica = p_r and i.seq >= coalesce(first_seq, p_s) and i.seq <= e
          and i.del_gen is null
        order by i.seq
    loop
        a := greatest(p_s, x.seq);
        b := least(e, x.seq + x.len - 1);
        continue when a > b;
        if a > x.seq then
            perform crdt._ydoc_split(p_doc, p_r, a);
        end if;
        if b < x.seq + x.len - 1 then
            perform crdt._ydoc_split(p_doc, p_r, b + 1);
        end if;
        update crdt.ydoc_items i set del_gen = p_gen
        where i.doc = p_doc and i.replica = p_r and i.seq = a
        returning i.ord into k;
        perform crdt._ydoc_blk(p_doc, k, -(b - a + 1), 0);
        removed := removed + b - a + 1;
    end loop;
    return removed;
end;
$$;

-- Integrates a ready run, then the pending deletes it satisfies. Returns the
-- change in visible length.
create function crdt._ydoc_settle(
    p_doc bigint, p_gen bigint, p_rname text, p_r integer, p_s integer,
    p_olr integer, p_ols integer, p_orr integer, p_ors integer, p_text text)
returns integer
language plpgsql volatile
as $$
declare
    added integer;
    e integer := p_s + pg_catalog.length(p_text) - 1;
    pd record;
begin
    added := crdt._ydoc_integrate(p_doc, p_gen, p_r, p_rname, p_s, p_olr, p_ols, p_orr, p_ors, p_text);
    for pd in
        delete from crdt.ydoc_pending_deletes x
        where x.doc = p_doc and x.replica = p_rname and x.seq <= e
        returning x.seq, x.len
    loop
        added := added - crdt._ydoc_delete_range(p_doc, p_gen, p_r, p_rname, pd.seq, pd.len);
    end loop;
    return added;
end;
$$;

-- Integrates a run if it is ready: trims ids already integrated, then checks
-- that (replica, seq-1) and both origins are integrated. Returns the change in
-- visible length, or null when the run is not ready (the caller buffers it).
-- On success, o_s is the first new seq (after trimming), or null if the run
-- was a duplicate.
create function crdt._ydoc_try(
    p_doc bigint, p_gen bigint, p_r text, p_s integer,
    p_olr text, p_ols integer, p_orr text, p_ors integer, p_text text,
    out added integer, out o_s integer)
language plpgsql volatile
as $$
declare
    c integer := crdt._ydoc_clock_name(p_doc, p_r);
    n integer := pg_catalog.length(p_text);
    rid integer;
begin
    if p_s + n - 1 <= c then
        added := 0;
        return;
    end if;
    if p_s <= c then
        p_text := pg_catalog.substr(p_text, c - p_s + 2);
        p_olr := p_r;
        p_ols := c;
        p_s := c + 1;
    end if;
    if p_s > c + 1
       or (p_olr is not null and p_olr <> p_r and crdt._ydoc_clock_name(p_doc, p_olr) < p_ols)
       or (p_orr is not null and crdt._ydoc_clock_name(p_doc, p_orr) < p_ors) then
        return;
    end if;
    rid := crdt._ydoc_rid_make(p_r);
    added := crdt._ydoc_settle(p_doc, p_gen, p_r, rid, p_s, crdt._ydoc_rid(p_olr), p_ols,
                               crdt._ydoc_rid(p_orr), p_ors, p_text);
    o_s := p_s;
end;
$$;

-- After ids (replica, s .. e) were integrated: integrate every buffered run
-- that became ready, transitively. An explicit stack, not recursion.
create function crdt._ydoc_drain(p_doc bigint, p_gen bigint, p_r text, p_s integer, p_e integer)
returns integer
language plpgsql volatile
as $$
declare
    st_r text[] := array[p_r];
    st_s integer[] := array[p_s];
    st_e integer[] := array[p_e];
    top integer;
    cr text;
    cs integer;
    ce integer;
    c record;
    t record;
    total integer := 0;
begin
    while pg_catalog.cardinality(st_r) > 0 loop
        top := pg_catalog.cardinality(st_r);
        cr := st_r[top]; cs := st_s[top]; ce := st_e[top];
        st_r := st_r[1:top - 1]; st_s := st_s[1:top - 1]; st_e := st_e[1:top - 1];
        for c in
            select p.* from crdt.ydoc_pending p
            where p.doc = p_doc
              and ((p.replica = cr and p.seq <= ce + 1)
                   or (p.ol_replica = cr and p.ol_seq between cs and ce)
                   or (p.or_replica = cr and p.or_seq between cs and ce))
            order by p.replica, p.seq
        loop
            select * into t from crdt._ydoc_try(p_doc, p_gen, c.replica, c.seq, c.ol_replica, c.ol_seq,
                                                c.or_replica, c.or_seq, c.content);
            continue when t.added is null;
            delete from crdt.ydoc_pending p where p.doc = p_doc and p.replica = c.replica and p.seq = c.seq;
            total := total + t.added;
            if t.o_s is not null then
                st_r := st_r || c.replica;
                st_s := st_s || t.o_s;
                st_e := st_e || (c.seq + pg_catalog.length(c.content) - 1);
            end if;
        end loop;
    end loop;
    return total;
end;
$$;

-- Locks the document row; returns its gen and length. Every write starts here.
create function crdt._ydoc_lock(p_doc bigint, p_fn text, out gen bigint, out len integer)
language plpgsql volatile
as $$
begin
    select d.gen, d.len into gen, len from crdt.ydoc_docs d where d.id = p_doc for no key update;
    if not found then
        raise exception 'crdt.%: document % does not exist', p_fn, p_doc
            using errcode = 'P0002', hint = 'Create documents with crdt.ydoc_create().';
    end if;
end;
$$;

-- The row holding the visible char at index p_pos (0-based): one running sum
-- over the blocks, one over the rows of the block that holds it. Both bounds
-- of the block go into the row query, so that whatever plan the planner
-- picks (a generic plan cannot see that the running sum stops early), it
-- reads one block, not the rest of the document.
create function crdt._ydoc_visible_at(p_doc bigint, p_pos integer,
    out ord bigint, out replica integer, out seq integer, out len integer, out off integer)
language plpgsql stable
as $$
declare
    blo bigint;
    bhi bigint;
    base integer;
begin
    select b.lo, b.hi, b.cum - b.vis into blo, bhi, base from (
        select k.lo, k.vis, sum(k.vis) over (order by k.lo rows unbounded preceding) as cum,
               lead(k.lo) over (order by k.lo) as hi
        from crdt.ydoc_blocks k where k.doc = p_doc
    ) b where b.cum > p_pos order by b.lo limit 1;
    if bhi is null then
        select z.ord, z.replica, z.seq, z.len, p_pos - (z.cum - z.len) into ord, replica, seq, len, off from (
            select i.ord, i.replica, i.seq, i.len, i.del_gen,
                   base + sum(case when i.del_gen is null then i.len else 0 end)
                          over (order by i.ord rows unbounded preceding) as cum
            from crdt.ydoc_items i where i.doc = p_doc and i.ord >= blo
        ) z where z.del_gen is null and z.cum > p_pos order by z.ord limit 1;
    else
        select z.ord, z.replica, z.seq, z.len, p_pos - (z.cum - z.len) into ord, replica, seq, len, off from (
            select i.ord, i.replica, i.seq, i.len, i.del_gen,
                   base + sum(case when i.del_gen is null then i.len else 0 end)
                          over (order by i.ord rows unbounded preceding) as cum
            from crdt.ydoc_items i where i.doc = p_doc and i.ord >= blo and i.ord < bhi
        ) z where z.del_gen is null and z.cum > p_pos order by z.ord limit 1;
    end if;
end;
$$;

create function crdt._ydoc_id(r text, s integer)
returns jsonb
language sql immutable parallel safe
return case when r is null then 'null'::jsonb else pg_catalog.jsonb_build_array(r, s) end;

-- Local insert at visible position p_pos (lock held). The reference
-- convention: originLeft is the visible char at p_pos-1, originRight the next
-- item in the sequence, tombstones included.
create function crdt._ydoc_insert_at(p_doc bigint, p_gen bigint, p_pos integer, p_text text, p_r text,
    out op jsonb, out added integer)
language plpgsql volatile
as $$
declare
    v record;
    olr integer;
    ols integer;
    orr integer;
    ors integer;
    s integer;
    rid integer := crdt._ydoc_rid_make(p_r);
begin
    if p_pos = 0 then
        select i.replica, i.seq into orr, ors from crdt.ydoc_items i
        where i.doc = p_doc order by i.ord limit 1;
    else
        select * into v from crdt._ydoc_visible_at(p_doc, p_pos - 1);
        olr := v.replica;
        ols := v.seq + v.off;
        if v.off < v.len - 1 then
            orr := v.replica;
            ors := ols + 1;
        else
            select i.replica, i.seq into orr, ors from crdt.ydoc_items i
            where i.doc = p_doc and i.ord > v.ord order by i.ord limit 1;
        end if;
    end if;
    s := crdt._ydoc_clock(p_doc, rid) + 1;
    added := crdt._ydoc_settle(p_doc, p_gen, p_r, rid, s, olr, ols, orr, ors, p_text);
    -- names for the op; the common case (typing on) is the writer's own id
    op := pg_catalog.jsonb_build_array(p_r, s,
        crdt._ydoc_id(case when olr = rid then p_r else crdt._ydoc_rname(olr) end, ols),
        crdt._ydoc_id(case when orr = rid then p_r else crdt._ydoc_rname(orr) end, ors), p_text);
end;
$$;

-- Local delete of visible positions [p_pos, p_pos + p_n) (lock held).
-- Returns the delete ops, adjacent ids coalesced.
create function crdt._ydoc_delete_at(p_doc bigint, p_gen bigint, p_pos integer, p_n integer)
returns jsonb
language plpgsql volatile
as $$
declare
    blo bigint;
    bhi bigint;
    base integer;
    cur refcursor;
    z record;
    a integer;
    b integer;
    rs integer[] := '{}';
    ss integer[] := '{}';
    ns integer[] := '{}';
    m integer := 0;
    ops jsonb := '[]';
begin
    -- the block that holds the first char, and the end of the block that
    -- holds the last one (null: the last block)
    select q.lo, q.cum - q.vis into blo, base from (
        select k.lo, k.vis, sum(k.vis) over (order by k.lo rows unbounded preceding) as cum
        from crdt.ydoc_blocks k where k.doc = p_doc
    ) q where q.cum > p_pos order by q.lo limit 1;
    select q.hi into bhi from (
        select k.lo, sum(k.vis) over (order by k.lo rows unbounded preceding) as cum,
               lead(k.lo) over (order by k.lo) as hi
        from crdt.ydoc_blocks k where k.doc = p_doc
    ) q where q.cum >= p_pos + p_n order by q.lo limit 1;
    if bhi is null then
        open cur for
            select y.replica, y.seq, y.len, y.cum from (
                select i.ord, i.replica, i.seq, i.len, i.del_gen,
                       base + sum(case when i.del_gen is null then i.len else 0 end)
                              over (order by i.ord rows unbounded preceding) as cum
                from crdt.ydoc_items i where i.doc = p_doc and i.ord >= blo
            ) y where y.del_gen is null and y.cum > p_pos order by y.ord;
    else
        open cur for
            select y.replica, y.seq, y.len, y.cum from (
                select i.ord, i.replica, i.seq, i.len, i.del_gen,
                       base + sum(case when i.del_gen is null then i.len else 0 end)
                              over (order by i.ord rows unbounded preceding) as cum
                from crdt.ydoc_items i where i.doc = p_doc and i.ord >= blo and i.ord < bhi
            ) y where y.del_gen is null and y.cum > p_pos order by y.ord;
    end if;
    loop
        fetch cur into z;
        exit when not found;
        a := greatest(p_pos, z.cum - z.len);
        exit when a >= p_pos + p_n;
        b := least(p_pos + p_n, z.cum);
        if m > 0 and rs[m] = z.replica and ss[m] + ns[m] = z.seq + (a - (z.cum - z.len)) then
            ns[m] := ns[m] + (b - a);
        else
            m := m + 1;
            rs[m] := z.replica;
            ss[m] := z.seq + (a - (z.cum - z.len));
            ns[m] := b - a;
        end if;
    end loop;
    close cur;
    for j in 1 .. m loop
        perform crdt._ydoc_delete_range(p_doc, p_gen, rs[j], null, ss[j], ns[j]);
        ops := ops || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_array(crdt._ydoc_rname(rs[j]), ss[j], ns[j]));
    end loop;
    return ops;
end;
$$;

-- Common prefix and suffix of two texts, in code points. A binary search on
-- the UTF-8 bytes (bytea comparisons are memcmp; left() on text walks the
-- characters, which made the diff of a 100k-char text cost 9 ms), then the
-- byte boundaries are moved back to character starts and counted.
create function crdt._ydoc_diff(a text, b text, out p integer, out q integer)
language plpgsql immutable parallel safe
as $$
declare
    x bytea := pg_catalog.convert_to(a, 'UTF8');
    y bytea := pg_catalog.convert_to(b, 'UTF8');
    lx integer := pg_catalog.length(x);
    ly integer := pg_catalog.length(y);
    lo integer;
    hi integer;
    mid integer;
    pb integer;
    qb integer;
begin
    lo := 0;
    hi := least(lx, ly);
    while lo < hi loop
        mid := (lo + hi + 1) / 2;
        if pg_catalog.substr(x, 1, mid) = pg_catalog.substr(y, 1, mid) then lo := mid; else hi := mid - 1; end if;
    end loop;
    pb := lo;
    -- back to a character start: the byte after the prefix must not be a
    -- continuation byte (10xxxxxx) in either text
    while pb > 0 and ((pb < lx and pg_catalog.get_byte(x, pb) & 192 = 128)
                      or (pb < ly and pg_catalog.get_byte(y, pb) & 192 = 128)) loop
        pb := pb - 1;
    end loop;
    lo := 0;
    hi := least(lx, ly) - pb;
    while lo < hi loop
        mid := (lo + hi + 1) / 2;
        if pg_catalog.substr(x, lx - mid + 1) = pg_catalog.substr(y, ly - mid + 1) then lo := mid; else hi := mid - 1; end if;
    end loop;
    qb := lo;
    -- forward to a character start: the first byte of the suffix must not be
    -- a continuation byte
    while qb > 0 and pg_catalog.get_byte(x, lx - qb) & 192 = 128 loop
        qb := qb - 1;
    end loop;
    p := pg_catalog.length(pg_catalog.convert_from(pg_catalog.substr(x, 1, pb), 'UTF8'));
    q := pg_catalog.length(pg_catalog.convert_from(pg_catalog.substr(x, lx - qb + 1), 'UTF8'));
end;
$$;

create function crdt._ydoc_is_int(j jsonb, lo bigint, hi bigint)
returns boolean
language sql immutable parallel safe
return case when pg_catalog.jsonb_typeof(j) is distinct from 'number' then false
            else (j::numeric between lo and hi and j::numeric = pg_catalog.trunc(j::numeric)) end;

-- An id [replica key, seq] on the wire.
create function crdt._ydoc_is_id(j jsonb)
returns boolean
language sql immutable parallel safe
return case when pg_catalog.jsonb_typeof(j) is distinct from 'array' then false
            when pg_catalog.jsonb_array_length(j) <> 2 then false
            when pg_catalog.jsonb_typeof(j -> 0) <> 'string' then false
            when (j ->> 0) !~ '^[^:]+(:.+)?$' then false
            else crdt._ydoc_is_int(j -> 1, 1, 2147483647) end;

create function crdt._ydoc_is_insert(v jsonb)
returns boolean
language sql immutable parallel safe
return case when pg_catalog.jsonb_typeof(v) is distinct from 'array' then false
            when pg_catalog.jsonb_array_length(v) <> 5 then false
            when pg_catalog.jsonb_typeof(v -> 0) <> 'string' then false
            when (v ->> 0) !~ '^[^:]+(:.+)?$' then false
            when not crdt._ydoc_is_int(v -> 1, 1, 2147483647) then false
            when pg_catalog.jsonb_typeof(v -> 2) <> 'null' and not crdt._ydoc_is_id(v -> 2) then false
            when pg_catalog.jsonb_typeof(v -> 3) <> 'null' and not crdt._ydoc_is_id(v -> 3) then false
            when pg_catalog.jsonb_typeof(v -> 4) <> 'string' then false
            when pg_catalog.length(v ->> 4) = 0 then false
            when (v ->> 1)::bigint + pg_catalog.length(v ->> 4) - 1 > 2147483647 then false
            -- an origin of the run's own replica must come before the run
            when pg_catalog.jsonb_typeof(v -> 2) = 'array' and (v -> 2 ->> 0) = (v ->> 0)
                 and (v -> 2 ->> 1)::integer >= (v ->> 1)::integer then false
            when pg_catalog.jsonb_typeof(v -> 3) = 'array' and (v -> 3 ->> 0) = (v ->> 0)
                 and (v -> 3 ->> 1)::integer >= (v ->> 1)::integer then false
            when pg_catalog.jsonb_typeof(v -> 2) = 'array' and (v -> 2) = (v -> 3) then false
            else true end;

create function crdt._ydoc_is_delete(v jsonb)
returns boolean
language sql immutable parallel safe
return case when pg_catalog.jsonb_typeof(v) is distinct from 'array' then false
            when pg_catalog.jsonb_array_length(v) <> 3 then false
            when pg_catalog.jsonb_typeof(v -> 0) <> 'string' then false
            when (v ->> 0) !~ '^[^:]+(:.+)?$' then false
            when not crdt._ydoc_is_int(v -> 1, 1, 2147483647) then false
            when not crdt._ydoc_is_int(v -> 2, 1, 2147483647) then false
            else (v ->> 1)::bigint + (v ->> 2)::bigint - 1 <= 2147483647 end;

-- Validates ops, then integrates them: inserts in array order (buffering those
-- that are not ready), then deletes. p_owner null: trusted (any replica).
create function crdt._ydoc_apply(p_doc bigint, p_ops jsonb, p_owner text, p_fn text)
returns void
language plpgsql volatile
as $$
declare
    bad integer;
    lk record;
    g bigint;
    has_pending boolean;
    v jsonb;
    t record;
    delta integer := 0;
    r text;
    s integer;
    txt text;
begin
    if p_ops is null then
        return;
    end if;
    -- "v" (the sender's version vector, research/text.md's causal validation
    -- rules) is accepted and not yet checked.
    if pg_catalog.jsonb_typeof(p_ops) <> 'object' or (p_ops - '{i,d,v}'::text[]) <> '{}'::jsonb
       or coalesce(pg_catalog.jsonb_typeof(p_ops -> 'i'), 'array') <> 'array'
       or coalesce(pg_catalog.jsonb_typeof(p_ops -> 'd'), 'array') <> 'array'
       or coalesce(pg_catalog.jsonb_typeof(p_ops -> 'v'), 'object') <> 'object' then
        raise exception 'crdt.%: ops must be an object {"i": [...], "d": [...]}', p_fn
            using errcode = '22023';
    end if;
    select e.n into bad from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'i', '[]')) with ordinality e(v, n)
    where not crdt._ydoc_is_insert(e.v) limit 1;
    if found then
        raise exception 'crdt.%: insert % is malformed', p_fn, bad - 1
            using errcode = '22023',
                  hint = 'An insert is [replica, seq, originLeft, originRight, text]: seq >= 1, origins null or [replica, seq], text not empty.';
    end if;
    select e.n into bad from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'd', '[]')) with ordinality e(v, n)
    where not crdt._ydoc_is_delete(e.v) limit 1;
    if found then
        raise exception 'crdt.%: delete % is malformed', p_fn, bad - 1
            using errcode = '22023', hint = 'A delete is [replica, seq, len] with seq >= 1 and len >= 1.';
    end if;
    if p_owner is not null then
        select e.v ->> 0 into r from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'i', '[]')) e(v)
        where pg_catalog.split_part(e.v ->> 0, ':', 1) <> p_owner limit 1;
        if found then
            raise exception 'crdt.%: replica % cannot insert characters of replica %', p_fn,
                pg_catalog.quote_literal(p_owner), pg_catalog.quote_literal(r)
                using errcode = '42501',
                      hint = 'Inserts may only carry the writer''s own ids: its replica id, or <replica id>:<device>. Deletes may target any character.';
        end if;
    end if;

    select * into lk from crdt._ydoc_lock(p_doc, p_fn);
    g := lk.gen + 1;
    has_pending := exists (select 1 from crdt.ydoc_pending p where p.doc = p_doc);

    for v in select e.v from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'i', '[]')) e(v) loop
        r := v ->> 0;
        s := (v ->> 1)::integer;
        txt := v ->> 4;
        select * into t from crdt._ydoc_try(p_doc, g, r, s, v -> 2 ->> 0, (v -> 2 ->> 1)::integer,
                                            v -> 3 ->> 0, (v -> 3 ->> 1)::integer, txt);
        if t.added is null then
            insert into crdt.ydoc_pending as p (doc, replica, seq, ol_replica, ol_seq, or_replica, or_seq, content)
            values (p_doc, r, s, v -> 2 ->> 0, (v -> 2 ->> 1)::integer, v -> 3 ->> 0, (v -> 3 ->> 1)::integer, txt)
            on conflict (doc, replica, seq) do update set content = excluded.content
                where pg_catalog.length(excluded.content) > pg_catalog.length(p.content);
            has_pending := true;
        else
            delta := delta + t.added;
            if has_pending and t.o_s is not null then
                delta := delta + crdt._ydoc_drain(p_doc, g, r, t.o_s, s + pg_catalog.length(txt) - 1);
            end if;
        end if;
    end loop;

    for v in select e.v from pg_catalog.jsonb_array_elements(coalesce(p_ops -> 'd', '[]')) e(v) loop
        delta := delta - crdt._ydoc_delete_range(p_doc, g, crdt._ydoc_rid(v ->> 0), v ->> 0,
                                                  (v ->> 1)::integer, (v ->> 2)::integer);
    end loop;

    update crdt.ydoc_docs d set gen = g, len = d.len + delta where d.id = p_doc;
end;
$$;

create function crdt._ydoc_check_replica(p_replica text, p_fn text)
returns void
language plpgsql immutable parallel safe
as $$
begin
    if p_replica is null then
        raise exception 'crdt.%: replica must not be null', p_fn using errcode = '22004';
    end if;
    if p_replica !~ '^[^:]+(:.+)?$' then
        raise exception 'crdt.%: % is not a replica key', p_fn, pg_catalog.quote_literal(p_replica)
            using errcode = '22023',
                  hint = 'A replica key is a non-empty id without ":", optionally followed by ":<device>".';
    end if;
end;
$$;

-- ============================================================================
-- ydoc_: API
-- ============================================================================

create function crdt.ydoc_create()
returns bigint
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    d bigint;
begin
    insert into crdt.ydoc_docs default values returning id into d;
    insert into crdt.ydoc_blocks (doc, lo) values (d, -9223372036854775808);
    return d;
end;
$$;

-- The plain text, or null for a document that does not exist.
create function crdt.ydoc_value(doc bigint)
returns text
language sql stable parallel safe
return case when exists (select 1 from crdt.ydoc_docs d where d.id = ydoc_value.doc)
            then coalesce((select string_agg(i.content, '' order by i.ord) from crdt.ydoc_items i
                           where i.doc = ydoc_value.doc and i.del_gen is null), '') end;

-- Visible length in code points, or null for a document that does not exist.
create function crdt.ydoc_length(doc bigint)
returns integer
language sql stable parallel safe
return (select d.len from crdt.ydoc_docs d where d.id = ydoc_length.doc);

-- The version vector {replica: highest seq}. A loose index scan: one probe
-- per replica, not a read of every row.
create function crdt.ydoc_version(doc bigint)
returns jsonb
language sql stable parallel safe
begin atomic
    with recursive r(replica) as (
        (select i.replica from crdt.ydoc_items i where i.doc = ydoc_version.doc order by i.replica limit 1)
        union all
        select (select i.replica from crdt.ydoc_items i
                where i.doc = ydoc_version.doc and i.replica > r.replica order by i.replica limit 1)
        from r where r.replica is not null
    )
    select coalesce(jsonb_object_agg(n.name, crdt._ydoc_clock(ydoc_version.doc, r.replica)), '{}'::jsonb)
    from r join crdt.ydoc_replicas n on n.id = r.replica;
end;

-- The version an editor starts from, for ydoc_set's base argument: the write
-- counter and the version vector. Read it in the same statement as the text:
--   select crdt.ydoc_value(d), crdt.ydoc_base(d)
create function crdt.ydoc_base(doc bigint)
returns jsonb
language sql stable parallel safe
return (select jsonb_build_object('g', d.gen, 'v', crdt.ydoc_version(d.id))
        from crdt.ydoc_docs d where d.id = ydoc_base.doc);

create function crdt.ydoc_insert(doc bigint, pos integer, chars text, replica text)
returns jsonb
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint := ydoc_insert.doc;
    lk record;
    g bigint;
    res record;
begin
    perform crdt._ydoc_check_replica(replica, 'ydoc_insert');
    if pos is null or chars is null then
        raise exception 'crdt.ydoc_insert: pos and chars must not be null' using errcode = '22004';
    end if;
    select * into lk from crdt._ydoc_lock(v_doc, 'ydoc_insert');
    if pos < 0 or pos > lk.len then
        raise exception 'crdt.ydoc_insert: position % is outside the document (length %)', pos, lk.len
            using errcode = '22023';
    end if;
    if chars = '' then
        return '{"i": [], "d": []}'::jsonb;
    end if;
    g := lk.gen + 1;
    select * into res from crdt._ydoc_insert_at(v_doc, g, pos, chars, replica);
    update crdt.ydoc_docs d set gen = g, len = d.len + res.added where d.id = v_doc;
    return jsonb_build_object('i', jsonb_build_array(res.op), 'd', '[]'::jsonb);
end;
$$;

-- `replica` is accepted for symmetry with ydoc_insert; a delete op does not
-- name its writer.
create function crdt.ydoc_delete(doc bigint, pos integer, len integer, replica text)
returns jsonb
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint := ydoc_delete.doc;
    lk record;
    g bigint;
    ops jsonb;
begin
    perform crdt._ydoc_check_replica(replica, 'ydoc_delete');
    if pos is null or len is null then
        raise exception 'crdt.ydoc_delete: pos and len must not be null' using errcode = '22004';
    end if;
    select * into lk from crdt._ydoc_lock(v_doc, 'ydoc_delete');
    if pos < 0 or len < 0 or pos + len > lk.len then
        raise exception 'crdt.ydoc_delete: range % + % is outside the document (length %)', pos, len, lk.len
            using errcode = '22023';
    end if;
    if len = 0 then
        return '{"i": [], "d": []}'::jsonb;
    end if;
    g := lk.gen + 1;
    ops := crdt._ydoc_delete_at(v_doc, g, pos, len);
    update crdt.ydoc_docs d set gen = g, len = d.len - ydoc_delete.len where d.id = v_doc;
    return jsonb_build_object('i', '[]'::jsonb, 'd', ops);
end;
$$;

-- Replace the text with new_text: common prefix and suffix, then one delete
-- and one insert in the middle. Without base, the diff is against the current
-- text: a save from an editor who started before another editor's save
-- reverts that save in the region between its first and last change. With
-- base (crdt.ydoc_base, read with the text), the diff is against the text at
-- base, and the insert's origins are taken in that version, so concurrent
-- saves to different places both survive (the CRDT merges them).
create function crdt.ydoc_set(doc bigint, new_text text, replica text, base jsonb default null)
returns jsonb
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint := ydoc_set.doc;
    lk record;
    g bigint;
    cur text;
    df record;
    dlen integer;
    ins text;
    dops jsonb := '[]';
    iops jsonb := '[]';
    res record;
    bg bigint;
    bv jsonb;
    z record;
    a integer;
    b integer;
    rs integer[] := '{}';
    ss integer[] := '{}';
    ns integer[] := '{}';
    m integer := 0;
    removed integer := 0;
    olr integer;
    ols integer;
    orr integer;
    ors integer;
    rid integer;
    s integer;
    added integer;
begin
    perform crdt._ydoc_check_replica(replica, 'ydoc_set');
    if new_text is null then
        raise exception 'crdt.ydoc_set: new_text must not be null' using errcode = '22004';
    end if;
    select * into lk from crdt._ydoc_lock(v_doc, 'ydoc_set');
    g := lk.gen + 1;

    if base is null then
        cur := crdt.ydoc_value(v_doc);
        if cur = new_text then
            return '{"i": [], "d": []}'::jsonb;
        end if;
        df := crdt._ydoc_diff(cur, new_text);
        dlen := length(cur) - df.p - df.q;
        ins := substr(new_text, df.p + 1, length(new_text) - df.p - df.q);
        if dlen > 0 then
            dops := crdt._ydoc_delete_at(v_doc, g, df.p, dlen);
        end if;
        if ins <> '' then
            select * into res from crdt._ydoc_insert_at(v_doc, g, df.p, ins, replica);
            iops := jsonb_build_array(res.op);
            added := res.added;
        end if;
        update crdt.ydoc_docs d set gen = g, len = d.len - dlen + coalesce(added, 0) where d.id = v_doc;
        return jsonb_build_object('i', iops, 'd', dops);
    end if;

    -- Three-way: diff against the text at base.
    if jsonb_typeof(base) is distinct from 'object' or not crdt._ydoc_is_int(base -> 'g', 0, 9223372036854775807)
       or jsonb_typeof(base -> 'v') is distinct from 'object'
       or exists (select 1 from jsonb_each(base -> 'v') e
                  where not crdt._ydoc_is_int(e.value, 0, 2147483647)
                     or (e.value)::integer > crdt._ydoc_clock_name(v_doc, e.key))
       or (base ->> 'g')::bigint > lk.gen then
        raise exception 'crdt.ydoc_set: base is not a version of document %', v_doc
            using errcode = '22023', hint = 'Pass the value of crdt.ydoc_base(doc), read together with the text.';
    end if;
    bg := (base ->> 'g')::bigint;
    -- the base's version vector keyed by interned id
    bv := (select coalesce(jsonb_object_agg(r.id::text, e.value), '{}') from jsonb_each(base -> 'v') e
           join crdt.ydoc_replicas r on r.name = e.key);
    -- Compaction merged tombstones stamped at or before the horizon, so the
    -- text at an older base cannot be rebuilt. Refuse rather than guess: a
    -- wrong base text widens the diff and reverts or duplicates text.
    if bg < (select d.horizon from crdt.ydoc_docs d where d.id = v_doc) then
        raise exception 'crdt.ydoc_set: base % of document % is older than its last compaction', bg, v_doc
            using errcode = '22023',
                  hint = 'Read the text and crdt.ydoc_base(doc) again, or call ydoc_set without base (a two-way diff against the current text).';
    end if;
    cur := coalesce((
        select string_agg(left(i.content, least(i.len, (bv ->> i.replica::text)::integer - i.seq + 1)), '' order by i.ord)
        from crdt.ydoc_items i
        where i.doc = v_doc and (bv ->> i.replica::text)::integer >= i.seq and (i.del_gen is null or i.del_gen > bg)), '');
    if cur = new_text then
        return '{"i": [], "d": []}'::jsonb;
    end if;
    df := crdt._ydoc_diff(cur, new_text);
    dlen := length(cur) - df.p - df.q;
    ins := substr(new_text, df.p + 1, length(new_text) - df.p - df.q);

    -- The chars visible at base, with a running count: deletes for
    -- [p, p + dlen), and the visible char at p - 1 for the insert.
    for z in
        select y.ord, y.replica, y.seq, y.bl, y.cum from (
            select i.ord, i.replica, i.seq, x.bl,
                   sum(x.bl) over (order by i.ord rows unbounded preceding) as cum
            from crdt.ydoc_items i
            cross join lateral (select least(i.len, (bv ->> i.replica::text)::integer - i.seq + 1) as bl) x
            where i.doc = v_doc and (bv ->> i.replica::text)::integer >= i.seq and (i.del_gen is null or i.del_gen > bg)
        ) y where y.cum >= df.p order by y.ord
    loop
        if df.p > 0 and olr is null and z.cum >= df.p then
            -- visible char at p - 1
            olr := z.replica;
            ols := z.seq + (df.p - 1 - (z.cum - z.bl));
            if ols < z.seq + z.bl - 1 then
                orr := z.replica;
                ors := ols + 1;
            else
                select i.replica, i.seq into orr, ors from crdt.ydoc_items i
                where i.doc = v_doc and i.ord > z.ord and (bv ->> i.replica::text)::integer >= i.seq
                order by i.ord limit 1;
            end if;
        end if;
        a := greatest(df.p, z.cum - z.bl);
        exit when a >= df.p + dlen;
        b := least(df.p + dlen, z.cum);
        continue when b <= a;
        m := m + 1;
        rs[m] := z.replica;
        ss[m] := z.seq + (a - (z.cum - z.bl));
        ns[m] := b - a;
    end loop;
    if df.p = 0 then
        select i.replica, i.seq into orr, ors from crdt.ydoc_items i
        where i.doc = v_doc and (bv ->> i.replica::text)::integer >= i.seq order by i.ord limit 1;
    end if;

    for j in 1 .. m loop
        removed := removed + crdt._ydoc_delete_range(v_doc, g, rs[j], null, ss[j], ns[j]);
        dops := dops || jsonb_build_array(jsonb_build_array(crdt._ydoc_rname(rs[j]), ss[j], ns[j]));
    end loop;
    if ins <> '' then
        rid := crdt._ydoc_rid_make(replica);
        s := crdt._ydoc_clock(v_doc, rid) + 1;
        added := crdt._ydoc_settle(v_doc, g, replica, rid, s, olr, ols, orr, ors, ins);
        iops := jsonb_build_array(jsonb_build_array(replica, s, crdt._ydoc_id(crdt._ydoc_rname(olr), ols),
                                                    crdt._ydoc_id(crdt._ydoc_rname(orr), ors), ins));
    end if;
    update crdt.ydoc_docs d set gen = g, len = d.len - removed + coalesce(added, 0) where d.id = v_doc;
    return jsonb_build_object('i', iops, 'd', dops);
end;
$$;

-- The write path for untrusted writers, like pn_apply_delta: inserts must
-- carry the writer's own ids (`replica`, or <replica>:<device>); deletes may
-- target any character. Idempotent; inserts whose origins are missing wait.
create function crdt.ydoc_apply(doc bigint, ops jsonb, replica text default crdt.current_replica_id())
returns void
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
begin
    if replica is null then
        raise exception 'crdt.ydoc_apply: the writer has no replica id'
            using errcode = '42501',
                  hint = 'Pass the writer''s identity as the replica argument, or set it up for crdt.current_replica_id() (a JWT claim in request.jwt.claims, or the crdt.replica_id setting).';
    end if;
    if replica !~ '^[^:]+$' then
        raise exception 'crdt.ydoc_apply: % is not a replica id', quote_literal(replica)
            using errcode = '22023',
                  hint = 'A replica id is non-empty and has no ":" (":" separates a replica id from a device suffix).';
    end if;
    perform crdt._ydoc_apply(ydoc_apply.doc, ops, replica, 'ydoc_apply');
end;
$$;

-- The trusted write path: ops from any replica (another server's
-- ydoc_ops_since, a sync job). Same validation, no owner rule.
create function crdt.ydoc_merge(doc bigint, ops jsonb)
returns void
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
begin
    perform crdt._ydoc_apply(ydoc_merge.doc, ops, null, 'ydoc_merge');
end;
$$;

-- The ops a peer with version vector vv lacks: integrated inserts above vv,
-- in integration order (causal, so the peer applies them without buffering),
-- and every delete this document knows (deletes carry no clock; they are
-- idempotent).
create function crdt.ydoc_ops_since(doc bigint, vv jsonb default '{}')
returns jsonb
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint := ydoc_ops_since.doc;
    ins jsonb;
    dels jsonb;
begin
    if not exists (select 1 from crdt.ydoc_docs d where d.id = v_doc) then
        raise exception 'crdt.ydoc_ops_since: document % does not exist', v_doc using errcode = 'P0002';
    end if;
    vv := coalesce(vv, '{}');
    if jsonb_typeof(vv) <> 'object'
       or exists (select 1 from jsonb_each(vv) e where not crdt._ydoc_is_int(e.value, 0, 2147483647)) then
        raise exception 'crdt.ydoc_ops_since: vv must be an object {replica: seq} with whole numbers >= 0'
            using errcode = '22023';
    end if;
    -- Rows above vv (a row half above it is cut), in integration order, then
    -- consecutive rows that continue one run (split by deletes or the row
    -- cap) joined back into one insert.
    select coalesce(jsonb_agg(jsonb_build_array(g.replica, g.s, crdt._ydoc_id(g.olr, g.ols),
                                                crdt._ydoc_id(g.orr, g.ors), g.txt) order by g.grp), '[]')
    into ins
    from (
        select c.grp, (array_agg(c.replica order by c.ins, c.seq))[1] as replica,
               min(c.s) as s, (array_agg(c.olr order by c.ins, c.seq))[1] as olr,
               (array_agg(c.ols order by c.ins, c.seq))[1] as ols,
               (array_agg(c.orr order by c.ins, c.seq))[1] as orr,
               (array_agg(c.ors order by c.ins, c.seq))[1] as ors,
               string_agg(c.txt, '' order by c.ins, c.seq) as txt
        from (
            select b.*, sum(case when b.replica = b.p_replica and b.s = b.p_end and b.olr = b.replica and b.ols = b.s - 1
                                      and b.orr is not distinct from b.p_orr and b.ors is not distinct from b.p_ors
                                 then 0 else 1 end) over (order by b.ins, b.replica, b.seq) as grp
            from (
                select a.*, lag(a.replica) over w as p_replica, lag(a.s + length(a.txt)) over w as p_end,
                       lag(a.orr) over w as p_orr, lag(a.ors) over w as p_ors
                from (
                    select i.ins, r0.name as replica, i.seq,
                           greatest(i.seq, h.have + 1) as s,
                           case when i.seq > h.have then r1.name else r0.name end as olr,
                           case when i.seq > h.have then i.ol_seq else h.have end as ols,
                           r2.name as orr, i.or_seq as ors,
                           case when i.seq > h.have then i.content else substr(i.content, h.have - i.seq + 2) end as txt
                    from crdt.ydoc_items i
                    join crdt.ydoc_replicas r0 on r0.id = i.replica
                    left join crdt.ydoc_replicas r1 on r1.id = i.ol_replica
                    left join crdt.ydoc_replicas r2 on r2.id = i.or_replica
                    cross join lateral (select coalesce((vv ->> r0.name)::integer, 0) as have) h
                    where i.doc = v_doc and i.seq + i.len - 1 > h.have
                ) a
                window w as (order by a.ins, a.replica, a.seq)
            ) b
        ) c
        group by c.grp
    ) g;

    select coalesce(jsonb_agg(jsonb_build_array(u.replica, u.s, u.n) order by u.replica, u.s), '[]')
    into dels
    from (
        select (select r.name from crdt.ydoc_replicas r where r.id = z.replica) as replica, min(z.seq) as s, sum(z.len)::integer as n
        from (select i.replica, i.seq, i.len,
                     i.seq - coalesce(sum(i.len) over (partition by i.replica order by i.seq
                                                       rows between unbounded preceding and 1 preceding), 0) as grp
              from crdt.ydoc_items i where i.doc = v_doc and i.del_gen is not null) z
        group by z.replica, z.grp
        union all
        select p.replica, p.seq, p.len from crdt.ydoc_pending_deletes p where p.doc = v_doc
    ) u;
    return jsonb_build_object('i', ins, 'd', dels);
end;
$$;

-- Maintenance: merges adjacent rows that continue one run (consecutive ids
-- of one replica, the right row's originLeft the left row's last char, the
-- same originRight) and have the same visibility: both visible, or both
-- deleted with equal stamps, or both deleted at or before `horizon` (default:
-- now). Backspacing leaves one tombstone row per char; this is what folds
-- them. A merged tombstone keeps the latest of the stamps, so the text at a
-- base is exact for bases at or after the horizon; ydoc_set refuses older
-- bases (22023). Rows do not merge across a block boundary, and a merged row
-- holds at most about twice the run cap. Returns the number of rows removed.
-- The text, the ids and ops_since's text are unchanged.
create function crdt.ydoc_compact(doc bigint, horizon bigint default null)
returns integer
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint := ydoc_compact.doc;
    lk record;
    h bigint;
    removed integer;
    cap integer := crdt._ydoc_run_cap();
begin
    select * into lk from crdt._ydoc_lock(v_doc, 'ydoc_compact');
    h := coalesce(horizon, lk.gen);
    if h < 0 or h > lk.gen then
        raise exception 'crdt.ydoc_compact: horizon % is outside 0 .. % (the document''s write counter)', h, lk.gen
            using errcode = '22023';
    end if;
    update crdt.ydoc_docs d set horizon = greatest(d.horizon, h) where d.id = v_doc;

    with r as (
        select i.replica, i.seq, i.ord, i.len, i.del_gen, i.ins, i.content,
               i.ol_replica, i.ol_seq, i.or_replica, i.or_seq,
               lag(i.replica) over w as p_r, lag(i.seq + i.len) over w as p_end,
               lag(i.or_replica) over w as p_orr, lag(i.or_seq) over w as p_ors,
               lag(i.del_gen) over w as p_del,
               b.lo is not null as blk_lo
        from crdt.ydoc_items i
        left join crdt.ydoc_blocks b on b.doc = v_doc and b.lo = i.ord
        where i.doc = v_doc
        window w as (order by i.ord)
    ), g as (
        select r.*, sum(case when r.p_r = r.replica and r.p_end = r.seq
                                  and r.ol_replica = r.replica and r.ol_seq = r.seq - 1
                                  and r.or_replica is not distinct from r.p_orr and r.or_seq is not distinct from r.p_ors
                                  and not r.blk_lo
                                  and ((r.del_gen is null and r.p_del is null)
                                       or r.del_gen = r.p_del
                                       or (r.del_gen <= h and r.p_del <= h))
                             then 0 else 1 end) over (order by r.ord) as grp
        from r
    ), gs as (
        -- cut long groups so a merged row stays under about twice the cap
        select g.*, (sum(g.len) over (partition by g.grp order by g.ord) - g.len) / cap as sub
        from g
    ), a as (
        select (array_agg(gs.replica order by gs.ord))[1] as r, min(gs.seq) as s, sum(gs.len)::integer as len,
               string_agg(gs.content, '' order by gs.ord) as content, max(gs.del_gen) as del_gen, min(gs.ins) as ins,
               (array_agg(gs.seq order by gs.ord))[2:] as rest, min(gs.ord) as first_ord
        from gs group by gs.grp, gs.sub having count(*) > 1
    ), u as (
        update crdt.ydoc_items i set len = a.len, content = a.content, del_gen = a.del_gen, ins = a.ins
        from a where i.doc = v_doc and i.replica = a.r and i.seq = a.s
        returning 1
    ), dl as (
        delete from crdt.ydoc_items i
        using (select a.r, unnest(a.rest) as s from a) x
        where i.doc = v_doc and i.replica = x.r and i.seq = x.s
        returning 1
    ), bk as (
        update crdt.ydoc_blocks k set n = k.n - c.cnt
        from (select bl.lo, sum(pg_catalog.cardinality(a.rest))::integer as cnt
              from a cross join lateral (select x.lo from crdt.ydoc_blocks x where x.doc = v_doc and x.lo <= a.first_ord
                                         order by x.lo desc limit 1) bl
              group by bl.lo) c
        where k.doc = v_doc and k.lo = c.lo
        returning 1
    )
    select count(*) into removed from dl;
    return removed;
end;
$$;

create function crdt.ydoc_drop(doc bigint)
returns void
language plpgsql volatile
set search_path = pg_catalog, pg_temp
as $$
declare
    v_doc bigint := ydoc_drop.doc;
begin
    perform crdt._ydoc_lock(v_doc, 'ydoc_drop');
    delete from crdt.ydoc_items i where i.doc = v_doc;
    delete from crdt.ydoc_blocks b where b.doc = v_doc;
    delete from crdt.ydoc_pending p where p.doc = v_doc;
    delete from crdt.ydoc_pending_deletes p where p.doc = v_doc;
    delete from crdt.ydoc_docs d where d.id = v_doc;
end;
$$;

-- ============================================================================
-- ydoc_: privileges
-- ============================================================================

-- The tables belong to the extension. No role but the owner may touch them
-- until a DBA grants them (see NOTES.md, "Security model"): the functions are
-- SECURITY INVOKER, so they run with the caller's table privileges. Execute
-- is granted to public, as for pn_; without table privileges a call fails
-- with 42501.
revoke all on crdt.ydoc_replicas from public;
revoke all on crdt.ydoc_docs, crdt.ydoc_items, crdt.ydoc_blocks, crdt.ydoc_pending,
    crdt.ydoc_pending_deletes from public;
revoke all on all functions in schema crdt from public;
grant execute on all functions in schema crdt to public;
