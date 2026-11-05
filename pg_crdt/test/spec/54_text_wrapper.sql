-- Goal: the deployment model. Clients get no privileges on the crdt.ydoc_
-- tables, so calling the API directly fails (42501). The app grants the
-- tables to the role that owns its wrappers; a SECURITY DEFINER wrapper checks
-- that the caller may edit the post, then calls crdt.ydoc_apply with the
-- identity it trusts (here session_user). Reads go through an app function.
drop role if exists app_owner;
drop role if exists writer_alice;
drop role if exists writer_bob;
create role app_owner nologin;
create role writer_alice nologin;
create role writer_bob nologin;
grant select, insert, update, delete on crdt.ydoc_docs, crdt.ydoc_replicas, crdt.ydoc_items, crdt.ydoc_blocks,
    crdt.ydoc_pending, crdt.ydoc_pending_deletes, crdt.ydoc_deps, crdt.ydoc_pending_ops, crdt.ydoc_rejected to app_owner;
grant references on crdt.ydoc_docs to app_owner;
grant usage on sequence crdt.ydoc_ins, crdt.ydoc_docs_id_seq to app_owner;

grant create on schema public to app_owner;
create table public.posts (id int primary key, body_doc text not null references crdt.ydoc_docs (uid), editors text[] not null);
alter table public.posts owner to app_owner;
insert into public.posts values (1, crdt.ydoc_create(), '{writer_alice}');

set role app_owner;
create function public.edit_post(post_id int, ops jsonb) returns void
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare d text;
begin
    select body_doc into d from public.posts where id = post_id and session_user::text = any (editors);
    if not found then
        raise exception 'not an editor of post %', post_id using errcode = '42501';
    end if;
    perform crdt.ydoc_apply(d, ops, session_user::text);
end;
$$;
-- Reads: a view would not do, because crdt.ydoc_value reads the tables with
-- the privileges of the caller, not of the view's owner. A SECURITY DEFINER
-- read function (with the app's own read check) does.
create function public.post_body(post_id int) returns text
language sql stable security definer set search_path = pg_catalog, pg_temp
return (select crdt.ydoc_value(body_doc) from public.posts where id = post_id);
revoke all on function public.edit_post(int, jsonb) from public;
grant execute on function public.edit_post(int, jsonb) to writer_alice, writer_bob;
grant execute on function public.post_body(int) to writer_alice, writer_bob;
reset role;

select body_doc as d from public.posts where id = 1 \gset

select tap.plan(8);
select tap.ok(not has_table_privilege('writer_alice', 'crdt.ydoc_items', 'select'), 'clients have no privileges on the item table');
set session authorization writer_alice;
select tap.throws_ok(format('select crdt.ydoc_insert(%L, 0, %L, %L)', :'d', 'x', 'writer_alice'), '42501', 'calling the API directly: permission denied');
select tap.throws_ok(format('select crdt.ydoc_value(%L)', :'d'), '42501', 'reading directly: permission denied');
select tap.lives_ok($$select public.edit_post(1, '{"v": {}, "i": [["writer_alice", 1, null, null, "hi"]]}')$$, 'an editor writes through the wrapper');
select tap.throws_ok($$select public.edit_post(1, '{"v": {}, "i": [["writer_bob", 1, null, null, "x"]]}')$$, '42501', 'the wrapper passes session_user: forged ids rejected');
select tap.is(public.post_body(1), 'hi', 'reads through the app''s read function');
reset session authorization;
set session authorization writer_bob;
select tap.throws_ok($$select public.edit_post(1, '{"v": {}, "i": [["writer_bob", 1, null, null, "x"]]}')$$, '42501', 'a non-editor is refused by the app''s check');
reset session authorization;
select tap.is(crdt.ydoc_value(:'d'), 'hi', 'only the editor''s write landed');

select * from tap.finish();
