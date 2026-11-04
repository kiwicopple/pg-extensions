-- Test helpers for the ydoc_ specs. \i from a spec file.

-- Structural invariants of one document; returns a list of violations ('' if none).
create function pg_temp.ydoc_check(d bigint) returns text language plpgsql as $$
declare
    msg text := '';
    v text := crdt.ydoc_value(d);
begin
    if (select len from crdt.ydoc_docs where id = d) <> length(v) then
        msg := msg || 'docs.len <> length(value); ';
    end if;
    if (select coalesce(sum(vis), 0) from crdt.ydoc_blocks where doc = d) <> length(v) then
        msg := msg || 'sum(blocks.vis) <> length(value); ';
    end if;
    if (select coalesce(sum(n), 0) from crdt.ydoc_blocks where doc = d)
       <> (select count(*) from crdt.ydoc_items where doc = d) then
        msg := msg || 'sum(blocks.n) <> rows; ';
    end if;
    -- per-block counters match the rows in their key range
    if exists (
        select 1 from (select lo, lead(lo) over (order by lo) hi, vis, n from crdt.ydoc_blocks where doc = d) b
        where b.n <> (select count(*) from crdt.ydoc_items i where i.doc = d and i.ord >= b.lo and (b.hi is null or i.ord < b.hi))
           or b.vis <> (select coalesce(sum(len) filter (where del_gen is null), 0) from crdt.ydoc_items i
                        where i.doc = d and i.ord >= b.lo and (b.hi is null or i.ord < b.hi))) then
        msg := msg || 'block counters wrong; ';
    end if;
    if exists (select 1 from crdt.ydoc_items where doc = d and (len <> length(content) or len < 1)) then
        msg := msg || 'len <> length(content); ';
    end if;
    if exists (select 1 from crdt.ydoc_items where doc = d group by ord having count(*) > 1) then
        msg := msg || 'duplicate order labels; ';
    end if;
    if exists (select 1 from crdt.ydoc_items where doc = d and abs(ord) > crdt._ydoc_label_bound()) then
        msg := msg || 'label out of bounds; ';
    end if;
    if exists (select 1 from crdt.ydoc_blocks b where b.doc = d and b.lo <> -9223372036854775808
               and not exists (select 1 from crdt.ydoc_items i where i.doc = d and i.ord = b.lo)) then
        msg := msg || 'block lo is not a row label; ';
    end if;
    -- ids of a replica: contiguous from 1, no overlap
    if exists (
        select 1 from (select replica, seq, len, lag(seq + len) over (partition by replica order by seq) as nxt,
                              row_number() over (partition by replica order by seq) rn
                       from crdt.ydoc_items where doc = d) x
        where (x.rn = 1 and x.seq <> 1) or (x.rn > 1 and x.seq <> x.nxt)) then
        msg := msg || 'ids not contiguous; ';
    end if;
    return msg;
end;
$$;

-- Apply a jsonb array of ops one by one (trusted).
create function pg_temp.merge_all(d bigint, ops jsonb) returns void language plpgsql as $$
declare o jsonb;
begin
    for o in select e from jsonb_array_elements(ops) e loop
        perform crdt.ydoc_merge(d, o);
    end loop;
end;
$$;
