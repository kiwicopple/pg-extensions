-- Run once in a fresh database with pg_crdt installed, as an administrator.
-- A trusted server sets crdt.replica_id after authentication. Clients cannot
-- run arbitrary SQL. This is independent of the text-app.sql example.
begin;
create role app_owner nologin;
create role app_writer nologin;
grant create on schema public to app_owner;

set local role app_owner;
create table public.visit_counts (
  id bigint primary key,
  visits crdt.pn not null default crdt.pn_empty()
);
create table public.visit_editors (
  post_id bigint references public.visit_counts (id),
  editor text not null,
  primary key (post_id, editor)
);
insert into public.visit_counts (id) values (1);
insert into public.visit_editors values (1, 'alice');

create function public.apply_visits(post_id bigint, delta crdt.pn)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  writer text := crdt.current_replica_id();
  result bigint;
begin
  update public.visit_counts c
  set visits = crdt.pn_apply_delta(c.visits, delta, replica => writer)
  where c.id = apply_visits.post_id
    and exists (
      select 1 from public.visit_editors e
      where e.post_id = c.id and e.editor = writer
    )
  returning crdt.pn_value(c.visits) into result;
  if not found then
    raise exception 'not allowed to update this counter'
      using errcode = '42501';
  end if;
  return result;
end;
$$;

revoke all on function public.apply_visits(bigint, crdt.pn) from public;
grant execute on function public.apply_visits(bigint, crdt.pn)
to app_writer;
commit;
