# Denies, row attributes, and trusted context

A model check does not read your application tables. RLS can add rules on row attributes and enforce denies across models.

First complete [Combine permission models](combine-models.md), including the policies. The examples below use its data and alter its policies. Run them in order. The restrictive ban in that walkthrough shows how to deny access granted by either model.

## Mistakes in names raise errors

In an OpenFGA call, a misspelled relation or type is an error. It is not a silent "no access". This is also true in policies. The error needs a subject, because a call with no subject returns false first:

```js tab="JavaScript"
import { isFgaError } from 'permissions'

const bob = permissions.as({ id: '22222222-2222-2222-2222-222222222222' })
try {
  await bob.fga.check({ relation: 'editr', object: 'document:x' })
} catch (error) {
  if (!isFgaError(error, 2000)) throw error
  console.log(error.hint) // Did you mean 'editor'? ...
}
try {
  await bob.fga.listObjects({ type: 'documnt', relation: 'viewer', idsOnly: true })
} catch (error) {
  if (!isFgaError(error, 2000)) throw error
  console.log(error.message) // type 'documnt' not found
}
```

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', :'bob', true);
select permissions.fga_check_current(
  relation => 'editr',
  object => 'document:x'
);
-- ERROR:  relation 'document#editr' not found
-- DETAIL:  openfga:2000 validation_error
-- HINT:  Did you mean 'editor'? Relations on type 'document': editor, owner, published, reader, viewer.
rollback;

begin;
select set_config('permissions.subject_id', :'bob', true);
select permissions.fga_list_object_ids_current(
  type => 'documnt',
  relation => 'viewer'
);
-- ERROR:  type 'documnt' not found
-- DETAIL:  openfga:2000 validation_error
rollback;
```

RBAC works the other way. An unknown permission gives false. A policy that names a dropped permission denies access, and does not break each query:

```js tab="JavaScript"
const { data: allowed } = await bob.rbac.hasPermission({
  permission: 'documents.reed',
})
// false
```

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', :'bob', true);
select permissions.rbac_has_permission(permission => 'documents.reed');
-- false
commit;
```

## Row attributes that only RLS sees

When using RLS, a policy can add a rule on a column of the row. For example: drafts are visible to editors only. A backend can enforce the same rule in its own decision logic, or pass trusted attributes to a model check.

```sql
create policy documents_published
  on public.documents
  as restrictive
  for select
  to authenticated
  using (
    status = 'published'
    or id = any (
      array(
        select permissions.fga_list_object_ids_current(
          type => 'document',
          relation => 'editor'
        )::uuid
      )
    )
  );
```

The check functions do not read your tables, so they do not know this rule. Bob views the draft through his team. RLS hides the draft, but `fga_check_current` still returns true:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select title from public.documents order by title;
-- acme readme, globex notes: no draft
select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:' || :'draft'
);
-- true
commit;
```

In this example, RLS includes an extra draft rule that the standalone check does not evaluate, so the RLS query determines which rows are returned. In an application that enforces access in its backend instead, include that rule in the backend decision. Checks are not limited to UI hints; they must include the rules needed for the operation they authorize.

If a check must use the attribute, pass the attribute in. The model has the relations `published` and `reader`. A backend sends the status of the row as a contextual tuple. The extension never writes a contextual tuple:

```js tab="JavaScript"
// Load the row from the application's trusted database connection.
const rowId = 'd0000000-0000-0000-0000-000000000003'
const { rows: [doc] } = await pool.query(
  'select id, status from public.documents where id = $1',
  [rowId],
)
if (!doc) throw new Error('Document not found')
const object = 'document:' + doc.id
const { data: mayRead } = await permissions.fga.admin.check({
  user: 'user:22222222-2222-2222-2222-222222222222',
  relation: 'reader',
  object,
  contextualTuples: doc.status === 'published'
    ? [{ user: 'user:*', relation: 'published', object }]
    : [],
})
// true for the published notes
```

```sql tab="SQL"
select permissions.fga_check(
  subject => 'user:' || :'bob',
  relation => 'reader',
  object => 'document:' || d.id,
  contextual_tuples => case
    when d.status = 'published' then
      jsonb_build_array(
        jsonb_build_object(
          'user', 'user:*',
          'relation', 'published',
          'object', 'document:' || d.id
        )
      )
  end
)
from public.documents d
where d.id = :'notes';
-- true
-- the same query for :'draft' is false: no published tuple, and Bob
-- does not edit it
```

This needs `fga_check`, which is admin-only. The current-subject functions take no contextual tuples, because a client could pass any tuple. An attribute on a relationship, such as an expiry or an IP range, is an [OpenFGA condition](../models/openfga/conditions.md). The next section shows conditions in policies.

Cedar takes row attributes in the policy itself. The function `cedar_is_authorized_current` has the argument `resource_attrs`, which gives the columns of the row to the Cedar policies. A Cedar policy can then read `resource.status` and still be a check on a trusted subject. See [Writes: check the row](policies.md#writes-check-the-row).

## Conditions in policies

The current-subject functions take no request `context` either. A client could claim any time or address. In a policy, a conditioned tuple counts when its condition is true with the context stored in the tuple only.

The policy denies a tuple whose condition needs a request value. It also denies an answer that depends on a condition that the extension cannot evaluate. For example, a `but not` that fails denies access. It does not let the user through. A policy never fails because of a condition.

Erin gets 30 days of access to the acme plan. The condition `non_expired_grant` needs `current_time`. The tuple stores `grant_time` and `grant_duration`, but not `current_time`:

```sql
select permissions.fga_write(
  writes => jsonb_build_array(
    jsonb_build_object(
      'user', 'user:' || :'erin',
      'relation', 'viewer',
      'object', 'document:' || :'plan',
      'condition', jsonb_build_object(
        'name', 'non_expired_grant',
        'context', jsonb_build_object(
          'grant_time', now() - interval '1 day',
          'grant_duration', '720h'
        )
      )
    )
  )
);

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'erin', true);
select id from public.documents;
-- no rows: the policies have no current_time
select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:' || :'plan'
);
-- false, not an error
commit;
```

A value that the server can trust, such as the time, can come from a function of your own. The function calls `fga_check` and adds the value. `fga_check` is admin-only, so the function is `security definer`, like the trigger in [RBAC](../integrations/cleanup.md#clean-up-with-delete_subject):

```sql
create function public.fga_check_now(
  relation text,
  object text
) returns boolean
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  return permissions.fga_check(
    subject => 'user:' || permissions.current_subject_id(),
    relation => relation,
    object => object,
    context => jsonb_build_object('current_time', now())
  );
exception when invalid_parameter_value then
  return false;
  -- no subject, or a condition that still cannot be evaluated
  -- (openfga:2000): deny
end;
$$;
revoke all on function public.fga_check_now(text, text) from public;
grant execute on function public.fga_check_now(text, text)
  to authenticated;

create policy documents_select_timed
  on public.documents
  for select
  to authenticated
  using (
    public.fga_check_now(
      relation => 'viewer',
      object => 'document:' || id
    )
  );

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'erin', true);
select title from public.documents;   -- acme plan, for 29 more days
commit;
```

This policy runs one Check for each row, and each Check has an exception block (a subtransaction). Use it for one row or a short list. It is slow for a wide table.
