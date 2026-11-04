-- Goal: the RLS-safe write path (architecture.md section 5, sql-integration.md
-- B5). RLS decides which rows a client may change; it cannot see inside a
-- crdt.pn. So clients do not get UPDATE on the state column. They call an
-- app-owned SECURITY DEFINER function, which applies their delta with
-- crdt.pn_apply_delta(state, delta). pn_apply_delta takes the replica id
-- from the caller (the JWT `sub`, else the crdt.replica_id setting), not from
-- the input, and rejects a delta that writes another replica's entries or
-- lowers a count. This file builds that app the way the README shows it.

-- The app: posts with a like counter, readable by clients, not writable.
create table public.posts (
    id int primary key,
    likes crdt.pn not null default crdt.pn_empty()
);
insert into public.posts (id) values (1), (2);
alter table public.posts enable row level security;
create policy posts_read on public.posts for select to authenticated, anon using (true);
grant select on public.posts to authenticated, anon;

-- The app's RPC: the only way a client changes likes.
create function public.like_post(post_id int, delta crdt.pn)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
    result bigint;
begin
    update public.posts
    set likes = crdt.pn_apply_delta(likes, delta)
    where id = post_id
    returning crdt.pn_value(likes) into result;
    if not found then
        raise exception 'post % not found', post_id using errcode = 'P0002';
    end if;
    return result;
end;
$$;
revoke all on function public.like_post(int, crdt.pn) from public;
grant execute on function public.like_post(int, crdt.pn) to authenticated;

select tap.plan(29);

-- current_replica_id: JWT sub first, then the setting
select tap.is(crdt.current_replica_id(), null, 'no JWT and no setting: no replica id');
select set_config('crdt.replica_id', 'server-job', false);
select tap.is(crdt.current_replica_id(), 'server-job', 'the crdt.replica_id setting is the fallback (server jobs, plain Postgres)');
select set_config('request.jwt.claims', '{"sub": "alice", "role": "authenticated"}', false);
select tap.is(crdt.current_replica_id(), 'alice', 'the JWT sub claim wins over the setting');
select set_config('request.jwt.claims', '', false);
select tap.is(crdt.current_replica_id(), 'server-job', 'empty JWT claims fall back to the setting');
select set_config('request.jwt.claims', '{"role": "anon"}', false);
select set_config('crdt.replica_id', '', false);
select tap.is(crdt.current_replica_id(), null, 'a JWT without sub and an empty setting: no replica id');

-- As alice, through the app's RPC
set role authenticated;
select set_config('request.jwt.claims', '{"sub": "alice", "role": "authenticated"}', false);

select tap.throws_ok($$ update public.posts set likes = '{"t": "pn", "v": 1, "p": {"bob": 100}, "n": {}}' where id = 1 $$,
                     '42501', 'a client cannot update the state column directly');

select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 1}, "n": {}}'), 1::bigint,
              'a valid delta (alice''s own entry) is accepted');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 1}, "n": {}}'), 1::bigint,
              'sending the same delta again changes nothing (idempotent)');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 3}, "n": {}}'), 3::bigint,
              'a higher total for alice is accepted');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice:phone": 2}, "n": {}}'), 5::bigint,
              'a device replica of alice (alice:<device>) is accepted');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {}, "n": {"alice": 1}}'), 4::bigint,
              'alice''s own decrement entry is accepted');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {}, "n": {}}'), 4::bigint,
              'an empty delta changes nothing');

-- Forged deltas
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"bob": 100}, "n": {}}') $$, '42501',
                     'a delta with another replica''s entry is rejected');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 4, "bob": 1}, "n": {}}') $$, '42501',
                     'a delta mixing alice''s entry with another replica''s is rejected as a whole');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {}, "n": {"bob": 1}}') $$, '42501',
                     'a delta writing another replica''s n entry is rejected');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice2": 1}, "n": {}}') $$, '42501',
                     'a replica id that only starts with alice (alice2) is not alice''s');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 2}, "n": {}}') $$, '22023',
                     'a delta that lowers alice''s p count (3 to 2) is rejected');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {}, "n": {"alice": 0}}') $$, '22023',
                     'a delta that lowers alice''s n count (1 to 0) is rejected');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 3.5}, "n": {}}') $$, '22023',
                     'a delta with an invalid count (3.5) is rejected (pn_apply_delta runs the full validator)');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": "9"}, "n": {}}') $$, '22023',
                     'a delta with a string count is rejected');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "q": {}}') $$, '23514',
                     'a delta that is not a crdt.pn envelope is rejected by the domain before the function runs');
select tap.is((select likes::jsonb from public.posts where id = 1),
              '{"t": "pn", "v": 1, "p": {"alice": 3, "alice:phone": 2}, "n": {"alice": 1}}'::jsonb,
              'after the rejected deltas the state holds only alice''s accepted entries');

-- Another user, the same row
select set_config('request.jwt.claims', '{"sub": "bob", "role": "authenticated"}', false);
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"bob": 1}, "n": {}}'), 5::bigint,
              'bob''s own delta is accepted on the same row');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 10}, "n": {}}') $$, '42501',
                     'bob cannot raise alice''s entry');

-- No identity
select set_config('request.jwt.claims', '{"role": "authenticated"}', false);
select tap.throws_ok($$ select public.like_post(2, '{"t": "pn", "v": 1, "p": {"alice": 1}, "n": {}}') $$, '42501',
                     'without a replica id every delta is rejected');
reset role;

set role anon;
select set_config('request.jwt.claims', '{"role": "anon"}', false);
select tap.throws_ok($$ select public.like_post(2, '{"t": "pn", "v": 1, "p": {"x": 1}, "n": {}}') $$, '42501',
                     'anon cannot call the app''s RPC');
reset role;

-- pn_apply_delta itself
select set_config('request.jwt.claims', '{"sub": "carol"}', false);
select tap.is(crdt.pn_apply_delta(null, '{"t": "pn", "v": 1, "p": {"carol": 2}, "n": {}}')::jsonb,
              '{"t": "pn", "v": 1, "p": {"carol": 2}, "n": {}}'::jsonb, 'pn_apply_delta: a null state counts as empty');
select tap.is(crdt.pn_apply_delta('{"t": "pn", "v": 1, "p": {"x": 4}, "n": {}}', null)::jsonb,
              '{"t": "pn", "v": 1, "p": {"x": 4}, "n": {}}'::jsonb, 'pn_apply_delta: a null delta returns the state unchanged');
select tap.is(crdt.pn_apply_delta('{"t": "pn", "v": 1, "p": {"x": 4, "carol": 1}, "n": {"x": 1}}',
                                  '{"t": "pn", "v": 1, "p": {"carol": 5}, "n": {"carol:tab": 2}}')::jsonb,
              crdt.pn_merge('{"t": "pn", "v": 1, "p": {"x": 4, "carol": 1}, "n": {"x": 1}}',
                            '{"t": "pn", "v": 1, "p": {"carol": 5}, "n": {"carol:tab": 2}}')::jsonb,
              'an accepted delta gives the same state as pn_merge');

select * from tap.finish();
