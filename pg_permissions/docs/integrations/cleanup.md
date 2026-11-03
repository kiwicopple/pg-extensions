# Delete users and clean up permissions

Call `delete_subject` when your application deletes a user. The extension has no users table of its own.

The example below continues the [RBAC walkthrough](../models/rbac/overview.md). Run its app-wide and tenant scenarios first; they define the IDs and assignments used here. The trigger is a fragment to adapt to your own users table.

## Clean up with `delete_subject`

The extension does not track your users table. When you delete a user, the role assignments of the user stay. They accumulate, and reusing an ID can restore the deleted user's access.

`delete_subject` removes a subject from every model in one call. It removes the role assignments of the subject, scoped assignments too. It also removes each OpenFGA tuple that names the subject, as user, as userset or as object. In the Cedar model, it removes the entity `<subject_type>::"<subject_id>"`, its parent edges, the edges that name it as a parent, and each template link whose `?principal` or `?resource` slot names it. Static Cedar policies and templates stay, because they are your application's code. It returns the number of rows that it removed.

Cleanup does not disable an identity. A static Cedar policy that names the deleted principal can still match a future request for that id, even without a stored entity. Your authentication system must stop issuing requests for a deleted user. Review any static policies that name the user, and avoid reusing subject ids.

```sql tab="SQL"
select permissions.rbac_assign_role(
  user_id => :'frank',
  role => 'viewer'
);
select permissions.rbac_assign_role(
  user_id => :'frank',
  role => 'viewer',
  scope => :'acme'
);
select permissions.delete_subject(
  subject_type => 'user',
  subject_id => :'frank'
);
-- 2
select permissions.rbac_user_permissions(user_id => :'frank');
-- {}
```

```ts tab="JavaScript"
await permissions.rbac.admin.assignRole({
  userId: frank,
  role: 'viewer',
})
await permissions.rbac.admin.assignRole({
  userId: frank,
  role: 'viewer',
  scope: acme,
})
const { data: removed } = await permissions.admin.deleteSubject({
  type: 'user',
  id: frank,
})
// 2
const { data: left } = await permissions.rbac.admin.userPermissions({
  userId: frank,
})
// []
```

Call `delete_subject` from a trigger on your users table. `delete_subject` is admin-only, so the trigger function is `security definer`:

```sql
create table public.users (id uuid primary key);
insert into public.users values (:'carol'), (:'dave');

create function public.forget_user() returns trigger
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  perform permissions.delete_subject(
    subject_type => 'user',
    subject_id => old.id::text
  );
  return old;
end;
$$;
create trigger forget_user after delete on public.users
    for each row execute function public.forget_user();

delete from public.users where id = :'carol';
select permissions.rbac_user_permissions(user_id => :'carol');
-- {}: the role of Carol is gone
```

`delete_subject` works for each subject type. For the OpenFGA model, `delete_subject(subject_type => 'team', subject_id => 'eng')` removes each tuple that names `team:eng`. See [the OpenFGA model](../models/openfga/overview.md).

## Clean up when a user is deleted

Integrate the trigger above with your application's user-deletion flow. For a subject type other than `user`, cleanup removes matching OpenFGA tuples and Cedar entities and links; RBAC assignments apply only to users.
