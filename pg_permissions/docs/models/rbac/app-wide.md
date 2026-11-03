# App-wide roles

Check permissions that apply across your application. You can use the result in a backend request handler, or optionally enforce the permission on a table with RLS.

First run the [RBAC setup](overview.md), including the role definitions and assignments. Use the same psql session or JavaScript variables. The initial checks need no application table. Later SQL examples switch to `authenticated` to test the optional RLS policies.

## Scenario 1: app-wide roles

Alice is an `admin`, Bob is an `editor` and Carol is a `viewer`, all app-wide. Carol can read documents but cannot edit them:

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', :'carol', true);
select permissions.rbac_has_permission(permission => 'documents.read');
-- true
select permissions.rbac_has_permission(permission => 'documents.edit');
-- false
commit;
```

```ts tab="JavaScript"
const asCarol = permissions.as({ id: carol })
const { data: canRead, error: readError } = await asCarol.rbac.hasPermission({
  permission: 'documents.read',
})
if (readError) throw readError
// canRead: true
const { data: canEdit, error: editError } = await asCarol.rbac.hasPermission({
  permission: 'documents.edit',
})
if (editError) throw editError
// canEdit: false
```

Your backend can use these answers before carrying out an operation. See [Check access in your application](../../integrations/checks.md) for the request-handler flow, or continue with [tenant-scoped roles](tenants.md).

## Optional: enforce access with RLS

To enforce the same permissions on table queries, create policies where SELECT needs `documents.read`, UPDATE needs `documents.edit`, and DELETE needs `documents.delete`.

```sql
create table public.documents (
  id uuid primary key default gen_random_uuid(),
  title text not null
);
insert into public.documents (title)
values ('welcome'), ('holidays'), ('expenses');

alter table public.documents enable row level security;
grant select, update, delete on public.documents to authenticated;

create policy documents_select
  on public.documents
  for select
  to authenticated
  using (
    (
      select permissions.rbac_has_permission(
        permission => 'documents.read'
      )
    )
  );
create policy documents_update
  on public.documents
  for update
  to authenticated
  using (
    (
      select permissions.rbac_has_permission(
        permission => 'documents.edit'
      )
    )
  );
create policy documents_delete
  on public.documents
  for delete
  to authenticated
  using (
    (
      select permissions.rbac_has_permission(
        permission => 'documents.delete'
      )
    )
  );
```

The check does not depend on the row, so the policy wraps it in `(select ...)`. Postgres then runs the check once for each query, as an InitPlan, and not once for each row. `EXPLAIN` shows an `InitPlan` and no `SubPlan`.

Each block below starts with the same two statements. The first statement starts a transaction as a client. The second statement sets the subject. The comments show the result:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'carol', true);
select count(*) from public.documents;
-- 3: viewers read all documents
update public.documents set title = upper(title);
-- UPDATE 0: Carol cannot edit
select permissions.rbac_has_permission(permission => 'documents.edit');
-- false
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
update public.documents set title = upper(title);
-- UPDATE 3: editors can update
delete from public.documents where title = 'EXPENSES';
-- DELETE 0: editors cannot delete
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'alice', true);
delete from public.documents where title = 'EXPENSES';
-- DELETE 1: admins can delete
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
-- Dave has no role
select count(*) from public.documents;                        -- 0
select set_config('permissions.subject_id', '', true);
-- no subject
select count(*) from public.documents;                        -- 0
commit;
```

In production, the `set_config` statement is part of your request setup (see [Identity](../../integrations/identity.md#identity)). On Supabase, the JWT does this.

## Next step

Continue with [Tenant-scoped roles](tenants.md).
