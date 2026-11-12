// A transport for pg-crdt-client over node-postgres (`pg`), for trusted
// server code that edits as a known writer: an app server acting for a user
// it has authenticated, a bot, an import job.
//
// `client` is a connected pg.Client (or anything with the same `query`).
// `writer` is the replica id that ydoc_apply checks the inserts against.
// To go through your own wrappers instead (edit_post and sync_post in the
// collaborative-text guide), change the two statements.
//
// Errors are node-postgres errors: their `code` is the SQLSTATE, which is
// what the client uses to tell a refused op (22023, 42501, ...) from a
// connection problem.
export function pgTransport(client, writer) {
  return {
    async create(doc) {
      await client.query('select crdt.ydoc_create($1)', [doc])
    },
    async apply(doc, op) {
      const { rows } = await client.query(
        'select crdt.ydoc_apply($1, $2, $3) as status',
        [doc, op, writer],
      )
      return rows[0].status
    },
    async opsSince(doc, vv) {
      const { rows } = await client.query(
        'select crdt.ydoc_ops_since($1, $2) as ops',
        [doc, vv],
      )
      return rows[0].ops
    },
  }
}
