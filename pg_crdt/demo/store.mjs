export const MERGE_SQL = `
  insert into crdt_demo.counters as counter (id, state, expires_at)
  values ($1, crdt.pn_apply_delta(crdt.pn_empty(), $2::crdt.pn, 'demo'), to_timestamp($3))
  on conflict (id) do update
    set state = crdt.pn_apply_delta(counter.state, $2::crdt.pn, 'demo')
  returning state, crdt.pn_value(state)::text as value
`;

// Cleanup is bounded and indexed, and runs on writes, not page views.
export const CLEANUP_SQL = `
  delete from crdt_demo.counters where id in (
    select id from crdt_demo.counters where expires_at < now()
    order by expires_at limit 100 for update skip locked
  )
`;

export async function syncCounter(db, session, delta) {
  await db.query(CLEANUP_SQL);
  const { rows } = await db.query(MERGE_SQL, [session.id, JSON.stringify(delta), session.expires]);
  return rows[0];
}
