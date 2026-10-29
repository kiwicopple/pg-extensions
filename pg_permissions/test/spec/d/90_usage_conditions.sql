-- Goal: every example in usage/conditions.md ("OpenFGA conditions") works as
-- written, in the page's order. Statements without a result are copied from
-- the page; queries that return something appear as tap.is(<the same
-- expression>, <the documented answer>), errors as fga_test.error_of(<the
-- statement>).
\ir ../../fixtures/fga_suite.sql

select tap.plan(29);

-- ============================================================================
-- A model with conditions
-- ============================================================================

-- `fga model transform` of the page's DSL (openfga/cli v0.8.2), verbatim but for its \u003c, written as <
-- (psql's \set would turn \u003c into u003c):
\set model '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user"},{"condition":"non_expired_grant","type":"user"},{"condition":"in_office_network","type":"user"}]}}},"relations":{"viewer":{"this":{}}},"type":"document"}],"conditions":{"in_office_network":{"expression":"user_ip.in_cidr(cidr)","name":"in_office_network","parameters":{"cidr":{"type_name":"TYPE_NAME_STRING"},"user_ip":{"type_name":"TYPE_NAME_IPADDRESS"}}},"non_expired_grant":{"expression":"current_time < grant_time + grant_duration","name":"non_expired_grant","parameters":{"current_time":{"type_name":"TYPE_NAME_TIMESTAMP"},"grant_duration":{"type_name":"TYPE_NAME_DURATION"},"grant_time":{"type_name":"TYPE_NAME_TIMESTAMP"}}}}}'

select tap.is((fga_test.error_of(format('select permissions.fga_write_authorization_model(%L::jsonb)',
    jsonb_set(:'model'::jsonb, '{conditions,non_expired_grant,expression}', '"current_time < \"2030-01-01\""')))).msg,
    'failed to compile expression on condition ''non_expired_grant'' - found no matching overload for ''_<_'' applied to ''(timestamp, string)'' (column 14)',
    'model: comparing a timestamp with a string is refused when the model is written');
select tap.is((fga_test.error_of(format('select permissions.fga_write_authorization_model(%L::jsonb)',
    jsonb_set(:'model'::jsonb, '{conditions,non_expired_grant,expression}', '"current_time < \"2030-01-01\""')))).detail,
    'openfga:2056 invalid_authorization_model', 'model: ... with 2056');
select tap.ok((fga_test.error_of(format('select permissions.fga_write_authorization_model(%L::jsonb)',
    jsonb_set(:'model'::jsonb, '{conditions,non_expired_grant,expression}', '"current_time < \"2030-01-01\""')))).hint
    like 'CEL has no implicit conversions: both operands of an operator need the same type %', 'model: ... and the hint');

select permissions.fga_write_authorization_model(:'model');

-- ============================================================================
-- Expiring access
-- ============================================================================

select permissions.fga_write('[{"user": "user:anne", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "non_expired_grant",
                "context": {"grant_time": "2026-01-01T00:00:00Z", "grant_duration": "720h"}}}]');

select tap.is(permissions.fga_check('user:anne', 'viewer', 'document:roadmap',
                             context => '{"current_time": "2026-01-15T00:00:00Z"}'), true, 'expiry: within the grant');
select tap.is(permissions.fga_check('user:anne', 'viewer', 'document:roadmap',
                             context => '{"current_time": "2026-03-01T00:00:00Z"}'), false, 'expiry: 30 days have passed');

select tap.is((select r.tuples #> '{0,key,condition}' from permissions.fga_read('document:roadmap') r),
              '{"name": "non_expired_grant", "context": {"grant_time": "2026-01-01T00:00:00Z", "grant_duration": "720h"}}'::jsonb,
              'expiry: Read returns the condition');

select tap.ok((fga_test.error_of($$ select permissions.fga_check('user:anne', 'viewer', 'document:roadmap') $$)).msg
              like 'failed to evaluate relationship condition: ''non_expired_grant'' - context is missing parameters ''[current_time]'' %',
              'expiry: without current_time, Check fails');
select tap.is((fga_test.error_of($$ select permissions.fga_check('user:anne', 'viewer', 'document:roadmap') $$)).detail,
              'openfga:2000 validation_error', 'expiry: ... with 2000');
select tap.ok((fga_test.error_of($$ select permissions.fga_check('user:anne', 'viewer', 'document:roadmap') $$)).hint
              like 'Pass every parameter the condition declares, in the request''s context argument or in the tuple''s condition context, %',
              'expiry: ... and the hint');
select tap.is(permissions.fga_check('user:anne', 'viewer', 'document:roadmap', context => jsonb_build_object('current_time', now())),
              now() < '2026-01-31 00:00:00+00', 'expiry: now() as current_time');

-- ============================================================================
-- An IP range
-- ============================================================================

select permissions.fga_write('[{"user": "user:bob", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "in_office_network", "context": {"cidr": "10.20.0.0/16"}}}]');

select tap.is(permissions.fga_check('user:bob', 'viewer', 'document:roadmap', context => '{"user_ip": "10.20.3.4"}'), true, 'ip: inside the range');
select tap.is(permissions.fga_check('user:bob', 'viewer', 'document:roadmap', context => '{"user_ip": "192.168.1.9"}'), false, 'ip: outside');

-- ============================================================================
-- Lists
-- ============================================================================

select permissions.fga_write('[{"user": "user:carl", "relation": "viewer", "object": "document:handbook"}]');

select tap.is(array(select permissions.fga_list_users('document:roadmap', 'viewer', '{user}',
    context => '{"current_time": "2026-01-15T00:00:00Z", "user_ip": "10.20.3.4"}') order by 1), '{user:anne,user:bob}'::text[],
    'lists: ListUsers with both parameters');
select tap.is(array(select permissions.fga_list_objects('user:bob', 'document', 'viewer',
    context => '{"user_ip": "10.20.3.4"}')), '{document:roadmap}'::text[], 'lists: ListObjects for Bob');
select tap.is((fga_test.error_of($$ select permissions.fga_list_users('document:roadmap', 'viewer', '{user}',
    context => '{"current_time": "2026-01-15T00:00:00Z"}') $$)).detail, 'openfga:2000 validation_error',
    'lists: without user_ip, ListUsers on the roadmap fails at Bob''s tuple');
select tap.is(array(select permissions.fga_list_objects('user:carl', 'document', 'viewer')), '{document:handbook}'::text[],
    'lists: ListObjects for Carl needs no context');

-- ============================================================================
-- Which context wins
-- ============================================================================

select tap.is(permissions.fga_check('user:anne', 'viewer', 'document:roadmap',
    context => '{"current_time": "2026-03-01T00:00:00Z", "grant_duration": "9000h"}'), false,
    'precedence: the tuple''s grant_duration wins over the request''s');

-- ============================================================================
-- Contextual tuples
-- ============================================================================

select tap.is(permissions.fga_check('user:dana', 'viewer', 'document:roadmap',
    contextual_tuples => '[{"user": "user:dana", "relation": "viewer", "object": "document:roadmap",
                            "condition": {"name": "in_office_network", "context": {"cidr": "10.20.0.0/16"}}}]',
    context => '{"user_ip": "10.20.9.9"}'), true, 'contextual: a contextual tuple with a condition');

-- ============================================================================
-- Writing conditioned tuples
-- ============================================================================

select tap.is((fga_test.error_of($$ select permissions.fga_write('[{"user": "user:erin", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "in_office_network", "context": {"cidr": "10.20.0.0/16", "region": "eu"}}}]') $$)).msg,
  'Invalid tuple ''document:roadmap#viewer@user:erin''. Reason: found invalid context parameter: region', 'writing: a context key that is not a parameter');
select tap.is((fga_test.error_of($$ select permissions.fga_write('[{"user": "user:erin", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "in_office_network", "context": {"cidr": "10.20.0.0/16", "region": "eu"}}}]') $$)).detail,
  'openfga:2000 validation_error', 'writing: ... is 2000');

select tap.is((fga_test.error_of($$ select permissions.fga_write('{"tuple_keys": [{"user": "user:bob", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "in_office_network", "context": {"cidr": "10.0.0.0/8"}}}], "on_duplicate": "ignore"}') $$)).detail,
  'openfga:2017 write_failed_due_to_invalid_input', 'writing: the same key with another condition is 2017, even with on_duplicate ignore');
select tap.is((fga_test.error_of($$ select permissions.fga_write(
    writes  => '[{"user": "user:bob", "relation": "viewer", "object": "document:roadmap", "condition": {"name": "in_office_network", "context": {"cidr": "10.0.0.0/8"}}}]',
    deletes => '[{"user": "user:bob", "relation": "viewer", "object": "document:roadmap"}]') $$)).detail,
  'openfga:2004 cannot_allow_duplicate_tuples_in_one_request', 'writing: the same key in writes and deletes is 2004');
begin;
select permissions.fga_write(deletes => '[{"user": "user:bob", "relation": "viewer", "object": "document:roadmap"}]');
select permissions.fga_write('[{"user": "user:bob", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "in_office_network", "context": {"cidr": "10.0.0.0/8"}}}]');
commit;
select tap.is(permissions.fga_check('user:bob', 'viewer', 'document:roadmap', context => '{"user_ip": "10.99.0.1"}'), true,
              'writing: the tuple was replaced, with the new range');
select tap.is((fga_test.error_of($$ select permissions.fga_write(deletes => '[{"user": "user:carl", "relation": "viewer", "object": "document:handbook"}]') $$)).st,
              null, 'writing: a delete need not name the condition');

-- ============================================================================
-- When a condition can't be evaluated
-- ============================================================================

select tap.is(permissions.fga_check('user:zoe', 'viewer', 'document:roadmap', context => '{"user_ip": "10.0.0.1"}'), false,
              'errors: Zoe''s search reads only her own tuples and the usersets: Anne''s condition is not evaluated');
select tap.is(permissions.fga_check('user:bob', 'viewer', 'document:roadmap', context => '{"user_ip": "10.0.0.1"}'), true,
              'errors: ... but a true path wins');

-- ============================================================================
-- In RLS policies
-- ============================================================================

set permissions.subject_id = 'bob';
select tap.is(permissions.fga_check_current('viewer', 'document:roadmap'), false,
              'rls: a condition that needs a request parameter is denied, without an error');
reset permissions.subject_id;

select tap.is(permissions.fga_read_authorization_model() ->> 'conditions' is not null, true, 'the model kept its conditions');
select tap.is((select count(*)::int from permissions.fga_read('document:roadmap') r, jsonb_array_elements(r.tuples) t), 2, 'two tuples on the roadmap');

select * from tap.finish();
