-- Security regression: signed Cedar filters cannot resurrect access after
-- a revocation, even when savepoints roll writes back and reuse snapshots.
select permissions.cedar_put_policy('alice',
    'permit (principal == user::"alice", action == Action::"view", resource);');
select 'permissions.cedar_filter_' || md5('Action::"view"') as cache_setting \gset

begin isolation level repeatable read;
select set_config('permissions.subject_id', 'alice', true);
set local role authenticated;
select permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"secret"') as initial_allow \gset
select current_setting(:'cache_setting') as allow_filter \gset
reset role;
savepoint before_revoke;
select permissions.cedar_delete_policy('alice');
set local role authenticated;
select permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"secret"') as after_revoke \gset
select current_setting(:'cache_setting') as deny_filter \gset
select set_config(:'cache_setting', :'allow_filter', true);
select permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"secret"') as replay_allow \gset
reset role;
rollback to savepoint before_revoke;
set local role authenticated;
select set_config(:'cache_setting', :'deny_filter', true);
select permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"secret"') as restored_allow \gset
reset role;
select permissions.cedar_delete_policy('alice');
set local role authenticated;
select set_config(:'cache_setting', :'allow_filter', true);
select permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"secret"') as second_revoke \gset
commit;

select tap.plan(6);
select tap.ok(:'initial_allow'::boolean, 'the original permit allows');
select tap.is(:'after_revoke'::boolean, false, 'revocation invalidates a cached permit in the same transaction');
select tap.is(:'replay_allow'::boolean, false, 'replaying a signed pre-revocation filter cannot restore access');
select tap.ok(:'restored_allow'::boolean, 'rollback restores the permit, and a filter from the aborted write is not reused');
select tap.is(:'second_revoke'::boolean, false, 'a later revocation gets a fresh generation after rollback');
select tap.is(nullif(current_setting(:'cache_setting', true), ''), null, 'the filter does not survive commit');
select * from tap.finish();
