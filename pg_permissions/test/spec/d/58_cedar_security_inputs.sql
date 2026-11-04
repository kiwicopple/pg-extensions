-- Security regression: the optimized row-attribute path must validate the
-- same Cedar values as the general parser, before either kind of permit.
select permissions.cedar_put_policy('typed',
    'permit (principal, action == Action::"typed", resource) when { resource.owner is Admin };');
select permissions.cedar_put_policy('open',
    'permit (principal, action == Action::"open", resource);');
select permissions.cedar_put_policy('closed',
    'forbid (principal, action == Action::"closed", resource);');

select tap.plan(7);
set role authenticated;
select set_config('permissions.subject_id', 'alice', false);
select tap.is(permissions.cedar_is_authorized_current('Action::"typed"', 'Doc::"secret"',
    '{"owner":{"__entity":{"type":"Admin"}}}'), false,
    'a missing entity id cannot satisfy an Admin type test');
select tap.is(permissions.cedar_is_authorized_current('Action::"typed"', 'Doc::"secret"',
    '{"owner":{"__entity":{"type":"Admin","id":""}}}'), true,
    'an explicitly empty id is a valid Cedar entity id');
select tap.is(permissions.cedar_is_authorized_current('Action::"typed"', 'Doc::"secret"',
    '{"owner":{"__entity":{"type":"user","id":"alice"}}}'), false,
    'a user entity does not satisfy the Admin type test');
select tap.is((select count(*)::int from (values
    ('{"owner":{"__entity":{"type":"Admin"}}}'::jsonb),
    ('{"owner":{"__entity":{"id":"alice"}}}'::jsonb),
    ('{"owner":{"__entity":{"type":"Admin","id":null}}}'::jsonb),
    ('{"owner":null}'::jsonb), ('{"level":1.5}'::jsonb),
    ('{"level":9223372036854775808}'::jsonb), ('[]'::jsonb),
    ('{"__entity":{"type":"Admin","id":"alice"}}'::jsonb)
) x(attrs) where permissions.cedar_is_authorized_current('Action::"open"', 'Doc::"secret"', attrs)), 0,
    'an unconditional permit does not skip malformed attribute validation');
select tap.is(permissions.cedar_is_authorized_current('Action::"open"', 'Doc::"secret"',
    '{"owner":{"__entity":{"type":"Admin","id":"alice"}},"level":2}'), true,
    'valid plain attributes still allow');
select tap.is(permissions.cedar_is_authorized_current('Action::"open"', 'Doc::"secret"',
    '{"labels":["a","b"],"nested":{"enabled":true}}'), true,
    'valid sets and records still allow');
select tap.is(permissions.cedar_is_authorized_current('Action::"closed"', 'Doc::"secret"',
    '{"owner":{"__entity":{"type":"Admin"}}}'), false, 'malformed attributes never override a forbid');
reset role;
select * from tap.finish();
