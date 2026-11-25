# Connect your app

Use your usual Postgres driver or API. pg_crdt stores and combines data; your app moves updates between devices and the database.

## Handle one update

1. Sign in the user and check that they may change this row.
2. Identify the writer from your authenticated session.
3. Apply the incoming update inside the SQL statement that stores it.
4. Commit, then return the result to the device.

Choose the function for the input you receive:

| Input | Function |
| --- | --- |
| A counter update from a client | `crdt.pn_apply_delta` |
| Text edits from a client | `crdt.yseq_apply` |
| A form's text and original base | `crdt.yseq_set` |
| A full state from a trusted server | `crdt.pn_merge` or `crdt.yseq_merge` |

An **apply** function checks the client's update, including which writer owns its entries. It does not sign the user in or decide which rows they may edit. Those are your app's decisions. A writer may still lie about their own count; use server-controlled updates when counts must be verified.

For clients sending their own data, expose a database function that checks access and applies it. This is often called a **wrapper**. Give the client permission to call the wrapper, without permission to replace the state column directly. The [application reference](../reference/application.md) has complete counter and text examples.

## Give writers separate names

Use names such as `alice:phone` and `alice:laptop`. Here `alice` is the owner and the part after `:` identifies a device. Each independent copy needs its own stable key.

Your server supplies the authenticated owner. Never trust an owner name supplied by the browser. If users connect directly to Postgres, identify them by their database login; they can change session settings themselves. See [identity settings](../reference/shared.md).

## Save and retry safely

Let the database merge against the current column value in one `update`. Reading a value into your app and later replacing the column with it can erase another writer's changes.

After a timeout, send the same recorded counter totals or text operations again. Creating a new increment or insertion can duplicate the action. If Postgres returns error `40001`, retry the whole transaction. Keep all statements in a transaction on the same database connection.

## Keep the full data

Back up the CRDT columns, not just their visible numbers or text. Devices need the stored history to merge later. For text, that history grows with editing and every save rewrites it; measure [storage costs](../reference/storage.md) for your workload.

You have reached the end of the guide. Use the [reference](../README.md#reference) for function signatures, working app examples, storage and troubleshooting.
