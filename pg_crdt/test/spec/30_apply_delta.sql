-- Goal: the write path for untrusted writers (architecture.md section 5,
-- sql-integration.md B5). Row-level security decides which rows a writer may
-- change; it cannot see inside a crdt.pn. So writers get no UPDATE on the
-- state column. They call an app-owned SECURITY DEFINER function, which
-- applies their delta with crdt.pn_apply_delta(state, delta, replica).
--
-- The replica is whatever identity the app trusts, passed by the wrapper.
-- This file builds wrappers for two sources:
--   like_post         the default, crdt.current_replica_id(): a JWT claim
--                     (request.jwt.claims, the PostgREST convention), else the
--                     crdt.replica_id setting (an app server's SET LOCAL)
--   like_post_as_role the database role of a direct SQL client (session_user)
-- pn_apply_delta rejects a delta with another replica's entries (42501) or a
-- malformed key or count (22023), and ignores stale entries (a no-op, so a
-- retry or a replayed older delta succeeds). Roles are this file's own, not
-- any platform's.

drop role if exists crdt_writer;
drop role if exists crdt_alice;
drop role if exists crdt_bob;
drop role if exists crdt_stranger;
create role crdt_writer nologin;
create role crdt_alice nologin in role crdt_writer;
create role crdt_bob nologin in role crdt_writer;
create role crdt_stranger nologin;

-- The app: posts with a like counter, readable by writers, not writable.
create table public.posts (
    id int primary key,
    likes crdt.pn not null default crdt.pn_empty()
);
insert into public.posts (id) values (1), (2), (3);
alter table public.posts enable row level security;
create policy posts_read on public.posts for select to crdt_writer using (true);
grant select on public.posts to crdt_writer;

-- Wrapper 1: identity from the default resolver.
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

-- Wrapper 2: identity from the database role (session_user, not current_user,
-- which inside SECURITY DEFINER is the function's owner).
create function public.like_post_as_role(post_id int, delta crdt.pn)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
    result bigint;
begin
    update public.posts
    set likes = crdt.pn_apply_delta(likes, delta, session_user::text)
    where id = post_id
    returning crdt.pn_value(likes) into result;
    return result;
end;
$$;
revoke all on function public.like_post(int, crdt.pn), public.like_post_as_role(int, crdt.pn) from public;
grant execute on function public.like_post(int, crdt.pn), public.like_post_as_role(int, crdt.pn) to crdt_writer;

select tap.plan(49);

-- current_replica_id: a JWT claim first, then the crdt.replica_id setting
select tap.is(crdt.current_replica_id(), null, 'no JWT and no setting: no replica id');
select set_config('crdt.replica_id', 'server-job', false);
select tap.is(crdt.current_replica_id(), 'server-job', 'without a JWT, the crdt.replica_id setting is the replica id');
select set_config('request.jwt.claims', '{"sub": "alice", "role": "web_user"}', false);
select tap.is(crdt.current_replica_id(), 'alice', 'the JWT sub claim wins over the setting');
select set_config('request.jwt.claims', '', false);
select tap.is(crdt.current_replica_id(), 'server-job', 'empty JWT claims fall back to the setting');
select set_config('request.jwt.claims', '{"sub": "alice", "email": "ada@example.com"}', false);
select set_config('crdt.replica_id_claim', 'email', false);
select tap.is(crdt.current_replica_id(), 'ada@example.com', 'crdt.replica_id_claim chooses the claim (email)');
select set_config('request.jwt.claims', '{"user_id": 42}', false);
select set_config('crdt.replica_id_claim', 'user_id', false);
select tap.is(crdt.current_replica_id(), '42', 'a numeric claim is read as text');
select set_config('request.jwt.claims', '{"sub": "alice"}', false);
select tap.is(crdt.current_replica_id(), 'server-job', 'a JWT without the configured claim falls back to the setting');
select set_config('crdt.replica_id_claim', '', false);
select set_config('request.jwt.claims', '', false);
select set_config('crdt.replica_id', '', false);
begin;
set local crdt.replica_id = 'app-user-7';
select tap.is(crdt.current_replica_id(), 'app-user-7', 'an app server''s SET LOCAL crdt.replica_id identifies the writer for one transaction');
commit;
select tap.is(crdt.current_replica_id(), null, 'and after the transaction there is no replica id again');

-- Through wrapper 1, as alice (JWT)
set role crdt_writer;
select set_config('request.jwt.claims', '{"sub": "alice"}', false);

select tap.throws_ok($$ update public.posts set likes = '{"t": "pn", "v": 1, "p": {"bob": 100}, "n": {}}' where id = 1 $$,
                     '42501', 'a writer cannot update the state column directly');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 1}, "n": {}}'), 1::bigint,
              'a valid delta (alice''s own entry) is accepted');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 1}, "n": {}}'), 1::bigint,
              'sending the same delta again changes nothing (a retry)');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 3}, "n": {}}'), 3::bigint,
              'a higher total for alice is accepted');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 2}, "n": {}}'), 3::bigint,
              'a stale delta (alice 2, the server has 3) succeeds and changes nothing');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice:phone": 2}, "n": {}}'), 5::bigint,
              'a device replica of alice (alice:phone) is accepted');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice:phone:2": 1}, "n": {}}'), 6::bigint,
              'a device suffix may itself contain : (alice:phone:2)');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {}, "n": {"alice": 1}}'), 5::bigint,
              'alice''s own decrement entry is accepted');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {}, "n": {"alice": 0}}'), 5::bigint,
              'a stale n entry (0, the server has 1) succeeds and changes nothing');
select tap.is(public.like_post(1, '{"t": "pn", "v": 1, "p": {}, "n": {}}'), 5::bigint,
              'an empty delta changes nothing');

-- Forged and malformed deltas
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"bob": 100}, "n": {}}') $$, '42501',
                     'a delta with another replica''s entry is rejected');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 4, "bob": 1}, "n": {}}') $$, '42501',
                     'a delta mixing alice''s entry with another replica''s is rejected as a whole');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {}, "n": {"bob": 1}}') $$, '42501',
                     'a delta writing another replica''s n entry is rejected');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice:": 1}, "n": {}}') $$, '22023',
                     'a key with an empty device suffix (alice:) is malformed');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {":alice": 1}, "n": {}}') $$, '22023',
                     'a key with an empty owner (:alice) is malformed');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": 3.5}, "n": {}}') $$, '22023',
                     'a delta with an invalid count (3.5) is rejected (pn_apply_delta runs the full validator)');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "p": {"alice": "9"}, "n": {}}') $$, '22023',
                     'a delta with a string count is rejected');
select tap.throws_ok($$ select public.like_post(1, '{"t": "pn", "v": 1, "q": {}}') $$, '23514',
                     'a delta that is not a crdt.pn envelope is rejected by the domain before the function runs');
select tap.is((select likes::jsonb from public.posts where id = 1),
              '{"t": "pn", "v": 1, "p": {"alice": 3, "alice:phone": 2, "alice:phone:2": 1}, "n": {"alice": 1}}'::jsonb,
              'after the rejected deltas the state holds only alice''s accepted entries');

-- Owner = the part before the first ":", compared exactly
select set_config('request.jwt.claims', '{"sub": "abc"}', false);
select tap.is(public.like_post(2, '{"t": "pn", "v": 1, "p": {"abc": 1, "abc:phone": 1}, "n": {}}'), 2::bigint,
              'user abc can write abc and abc:phone');
select tap.throws_ok($$ select public.like_post(2, '{"t": "pn", "v": 1, "p": {"abcd": 1}, "n": {}}') $$, '42501',
                     'user abc cannot write abcd');
select tap.throws_ok($$ select public.like_post(2, '{"t": "pn", "v": 1, "p": {"ab": 1}, "n": {}}') $$, '42501',
                     'user abc cannot write ab');
select tap.throws_ok($$ select public.like_post(2, '{"t": "pn", "v": 1, "p": {"ab:c": 1}, "n": {}}') $$, '42501',
                     'user abc cannot write ab:c (owner ab)');
select set_config('request.jwt.claims', '{"sub": "abc:phone"}', false);
select tap.throws_ok($$ select public.like_post(2, '{"t": "pn", "v": 1, "p": {"abc:phone": 5}, "n": {}}') $$, '22023',
                     'a caller identity that contains : (sub abc:phone) is rejected');

-- Non-UUID identities
select set_config('request.jwt.claims', '{"sub": "ada@example.com"}', false);
select tap.is(public.like_post(3, '{"t": "pn", "v": 1, "p": {"ada@example.com": 1, "ada@example.com:laptop": 1}, "n": {}}'), 2::bigint,
              'an email address works as a replica id, with a device suffix');
select set_config('request.jwt.claims', '{"sub": 42}', false);
select tap.is(public.like_post(3, '{"t": "pn", "v": 1, "p": {"42": 3}, "n": {}}'), 5::bigint,
              'an integer id (a numeric claim) works as a replica id');

-- No identity
select set_config('request.jwt.claims', '{"role": "web_user"}', false);
select tap.throws_ok($$ select public.like_post(3, '{"t": "pn", "v": 1, "p": {"x": 1}, "n": {}}') $$, '42501',
                     'without a replica id every delta is rejected');
reset role;

-- Wrapper 2: the database role is the replica id
set session authorization crdt_alice;
select set_config('request.jwt.claims', '', false);
select tap.is(public.like_post_as_role(3, '{"t": "pn", "v": 1, "p": {"crdt_alice": 2}, "n": {}}'), 7::bigint,
              'session_user identifies a direct SQL client: crdt_alice writes its own entry');
select tap.throws_ok($$ select public.like_post_as_role(3, '{"t": "pn", "v": 1, "p": {"crdt_bob": 2}, "n": {}}') $$, '42501',
                     'crdt_alice cannot write crdt_bob''s entry through the session_user wrapper');
select set_config('crdt.replica_id', 'crdt_bob', false);
select tap.throws_ok($$ select public.like_post_as_role(3, '{"t": "pn", "v": 1, "p": {"crdt_bob": 2}, "n": {}}') $$, '42501',
                     'the session_user wrapper ignores a crdt.replica_id the client set itself');
select tap.is(public.like_post(3, '{"t": "pn", "v": 1, "p": {"crdt_bob": 2}, "n": {}}'), 9::bigint,
              'trust model: through the default resolver, a direct SQL client can claim any crdt.replica_id');
select set_config('crdt.replica_id', '', false);
reset session authorization;

set session authorization crdt_stranger;
select tap.throws_ok($$ select public.like_post(3, '{"t": "pn", "v": 1, "p": {"x": 1}, "n": {}}') $$, '42501',
                     'a role without EXECUTE on the wrapper cannot call it');
reset session authorization;

-- pn_apply_delta itself, with an explicit replica
select set_config('request.jwt.claims', '{"sub": "alice"}', false);
select tap.is(crdt.pn_apply_delta('{"t": "pn", "v": 1, "p": {}, "n": {}}', '{"t": "pn", "v": 1, "p": {"carol": 2}, "n": {}}', 'carol')::jsonb,
              '{"t": "pn", "v": 1, "p": {"carol": 2}, "n": {}}'::jsonb,
              'an explicit replica argument is used instead of the default resolver');
select tap.throws_ok($$ select crdt.pn_apply_delta(crdt.pn_empty(), '{"t": "pn", "v": 1, "p": {"alice": 2}, "n": {}}', 'carol') $$, '42501',
                     'with replica carol, the JWT''s alice cannot write alice''s entry');
select tap.throws_ok($$ select crdt.pn_apply_delta(crdt.pn_empty(), '{"t": "pn", "v": 1, "p": {"x": 1}, "n": {}}', null) $$, '42501',
                     'an explicit null replica is rejected');
select tap.throws_ok($$ select crdt.pn_apply_delta(crdt.pn_empty(), '{"t": "pn", "v": 1, "p": {"x:y": 1}, "n": {}}', 'x:y') $$, '22023',
                     'an explicit replica that contains : is rejected');
select tap.throws_ok($$ select crdt.pn_apply_delta(crdt.pn_empty(), '{"t": "pn", "v": 1, "p": {}, "n": {}}', '') $$, '22023',
                     'an empty replica is rejected');
select tap.is(crdt.pn_apply_delta(null, '{"t": "pn", "v": 1, "p": {"alice": 2}, "n": {}}')::jsonb,
              '{"t": "pn", "v": 1, "p": {"alice": 2}, "n": {}}'::jsonb, 'a null state counts as empty');
select tap.is(crdt.pn_apply_delta('{"t": "pn", "v": 1, "p": {"x": 4}, "n": {}}', null)::jsonb,
              '{"t": "pn", "v": 1, "p": {"x": 4}, "n": {}}'::jsonb, 'a null delta returns the state unchanged');
select tap.is(crdt.pn_apply_delta('{"t": "pn", "v": 1, "p": {"x": 4, "alice": 7}, "n": {"x": 1}}',
                                  '{"t": "pn", "v": 1, "p": {"alice": 5}, "n": {"alice:tab": 2}}')::jsonb,
              crdt.pn_merge('{"t": "pn", "v": 1, "p": {"x": 4, "alice": 7}, "n": {"x": 1}}',
                            '{"t": "pn", "v": 1, "p": {"alice": 5}, "n": {"alice:tab": 2}}')::jsonb,
              'an accepted delta, stale entries included, gives the same state as pn_merge');

select * from tap.finish();

drop owned by crdt_writer, crdt_alice, crdt_bob, crdt_stranger;
drop role crdt_alice;
drop role crdt_bob;
drop role crdt_stranger;
drop role crdt_writer;
