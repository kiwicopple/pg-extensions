-- Goal: the typed write path (phase 5 of session 5) changes nothing but
-- speed. fga_write_tuple and fga_delete_tuple validate and write a key
-- without building JSON for fga_write, and _fga_tuple_for_write accepts a
-- key without a condition with one lookup (_fga_write_key_ok) instead of six.
-- For every key below, in the same starting state:
--   - fga_write_tuple has the outcome of the JSON path it replaced
--     (fga_write with that key and on_duplicate ignore): the same error
--     (SQLSTATE, message, DETAIL, HINT) or the same tuples afterwards;
--   - fga_delete_tuple likewise against fga_write deletes with on_missing
--     ignore;
--   - fga_write itself has the outcome its slow path gives, written out
--     here (the fast path may only accept what the slow path accepts).
\ir ../../fixtures/fga_suite.sql
select tap.plan(68);

-- an outcome: the tuples after the statement (key and condition), or its
-- error; the statement is always rolled back
create function pg_temp.outcome(p_sql text)
returns text
language plpgsql
as $$
declare
    st text; msg text; det text; hnt text;
begin
    begin
        execute p_sql;
        raise exception using errcode = 'P0001', message = 'pg_temp.outcome rollback', detail = (
            select coalesce(string_agg(format('%s:%s#%s@%s%s', x.object_type, x.object_id, x.relation,
                                              permissions._fga_user_string(x.user_type, x.user_id, x.user_relation),
                                              case when x.condition_name <> '' then format(' [%s %s]', x.condition_name, x.condition_context) else '' end),
                                       ', ' order by x.object_type, x.object_id, x.relation, x.user_type, x.user_id, x.user_relation), '')
            from permissions.fga_tuples x);
    exception when others then
        get stacked diagnostics st = returned_sqlstate, msg = message_text, det = pg_exception_detail, hnt = pg_exception_hint;
        if st = 'P0001' and msg = 'pg_temp.outcome rollback' then
            return 'ok: ' || det;
        end if;
        return format('%s | %s | %s | %s', st, msg, det, hnt);
    end;
end;
$$;

create function pg_temp.json_write(u text, r text, o text)
returns text language sql as $$
    select format('select permissions.fga_write(%L::jsonb)',
                  jsonb_build_object('tuple_keys', jsonb_build_array(jsonb_build_object('user', u, 'relation', r, 'object', o)),
                                     'on_duplicate', 'ignore'))
$$;
create function pg_temp.json_delete(u text, r text, o text)
returns text language sql as $$
    select format('select permissions.fga_write(deletes => %L::jsonb)',
                  jsonb_build_object('tuple_keys', jsonb_build_array(jsonb_build_object('user', u, 'relation', r, 'object', o)),
                                     'on_missing', 'ignore'))
$$;

create temp table keys (n serial, u text, r text, o text, why text);
insert into keys (u, r, o, why) values
-- no model yet: 2020 from both paths
('user:anne', 'viewer', 'doc:1', 'no model');

select tap.is(pg_temp.outcome(format('select permissions.fga_write_tuple(%L, %L, %L)', u, r, o)),
              pg_temp.outcome(pg_temp.json_write(u, r, o)), 'fga_write_tuple, ' || why || ': as the JSON path')
from keys order by n;
select tap.is(pg_temp.outcome(format('select permissions.fga_delete_tuple(%L, %L, %L)', u, r, o)),
              pg_temp.outcome(pg_temp.json_delete(u, r, o)), 'fga_delete_tuple, ' || why || ': as the JSON path')
from keys order by n;
truncate keys;

-- type user
-- type team
--   relations
--     define member: [user, team#member]
-- type folder
--   relations
--     define viewer: [user]
-- type doc
--   relations
--     define parent: [folder]
--     define owner: [user with cx]
--     define viewer: [user, user:*, team#member, user with cx] or viewer from parent
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]}}}},
    {"type": "folder", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "doc",
     "relations": {
       "parent": {"this": {}},
       "owner": {"this": {}},
       "viewer": {"union": {"child": [
         {"this": {}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder"}]},
       "owner": {"directly_related_user_types": [{"type": "user", "condition": "cx"}]},
       "viewer": {"directly_related_user_types": [
         {"type": "user"}, {"type": "user", "wildcard": {}}, {"type": "team", "relation": "member"},
         {"type": "user", "condition": "cx"}]}}}}],
  "conditions": {"cx": {"name": "cx", "expression": "x < 100", "parameters": {"x": {"type_name": "TYPE_NAME_INT"}}}}}$m$::jsonb) is not null as model_written;

-- the starting state: one plain tuple, one stored with a condition
select permissions.fga_write('[{"user": "user:anne", "relation": "viewer", "object": "doc:1"},
                               {"user": "user:cat", "relation": "viewer", "object": "doc:1", "condition": {"name": "cx", "context": {"x": 1}}}]');

insert into keys (u, r, o, why) values
('user:bob', 'viewer', 'doc:1', 'new plain user'),
('user:anne', 'viewer', 'doc:1', 'exists, same (no) condition'),
('user:cat', 'viewer', 'doc:1', 'exists with a condition'),
('user:*', 'viewer', 'doc:2', 'typed wildcard'),
('team:eng#member', 'viewer', 'doc:2', 'userset'),
('folder:f1', 'parent', 'doc:2', 'tupleset, plain object'),
('folder:*', 'parent', 'doc:2', 'tupleset, wildcard'),
('folder:f1#viewer', 'parent', 'doc:2', 'tupleset, userset'),
('user:bob', 'owner', 'doc:2', 'conditioned restriction only'),
('team:eng', 'viewer', 'doc:2', 'type not allowed'),
('team:*', 'viewer', 'doc:2', 'wildcard not allowed'),
('user:bob#member', 'viewer', 'doc:2', 'userset relation on a type without it'),
('team:eng#viewer', 'viewer', 'doc:2', 'unknown userset relation'),
('robot:r1', 'viewer', 'doc:2', 'unknown user type'),
('user:bob', 'viewr', 'doc:2', 'unknown relation'),
('user:bob', 'viewer', 'paper:2', 'unknown object type'),
('user:bob', 'viewer', 'doc:*', 'wildcard object'),
('user:bob', 'vie wer', 'doc:2', 'malformed relation'),
('user:bob', '', 'doc:2', 'empty relation'),
('user:bob', null, 'doc:2', 'null relation'),
('userbob', 'viewer', 'doc:2', 'malformed user'),
('user:bob', 'viewer', 'doc2', 'malformed object'),
('user:bob#', 'viewer', 'doc:2', 'empty userset relation'),
('team:*#member', 'viewer', 'doc:2', 'wildcard userset'),
('user:b ob', 'viewer', 'doc:2', 'space in the user id'),
(null, 'viewer', 'doc:2', 'null user'),
('user:bob', 'viewer', null, 'null object');

select tap.is(pg_temp.outcome(format('select permissions.fga_write_tuple(%L, %L, %L)', u, r, o)),
              pg_temp.outcome(pg_temp.json_write(u, r, o)), 'fga_write_tuple, ' || why || ': as the JSON path')
from keys order by n;
select tap.is(pg_temp.outcome(format('select permissions.fga_delete_tuple(%L, %L, %L)', u, r, o)),
              pg_temp.outcome(pg_temp.json_delete(u, r, o)), 'fga_delete_tuple, ' || why || ': as the JSON path')
from keys order by n;

-- fga_write's own outcome, which the fast path in _fga_tuple_for_write must
-- not change: accepted keys give these tuples, rejected keys these errors
create temp table expect (n serial, u text, r text, o text, want text);
insert into expect (u, r, o, want) values
('user:bob', 'viewer', 'doc:2', 'ok: doc:1#viewer@user:anne, doc:1#viewer@user:cat [cx {"x": 1}], doc:2#viewer@user:bob'),
('user:*', 'viewer', 'doc:2', 'ok: doc:1#viewer@user:anne, doc:1#viewer@user:cat [cx {"x": 1}], doc:2#viewer@user:*'),
('team:eng#member', 'viewer', 'doc:2', 'ok: doc:1#viewer@user:anne, doc:1#viewer@user:cat [cx {"x": 1}], doc:2#viewer@team:eng#member'),
('folder:f1', 'parent', 'doc:2', 'ok: doc:1#viewer@user:anne, doc:1#viewer@user:cat [cx {"x": 1}], doc:2#parent@folder:f1'),
('folder:*', 'parent', 'doc:2', '22023 | Invalid tuple ''doc:2#parent@folder:*''. Reason: unexpected wildcard relationship with tupleset relation ''doc#parent''%'),
('folder:f1#viewer', 'parent', 'doc:2', '22023 | Invalid tuple ''doc:2#parent@folder:f1#viewer''. Reason: unexpected user ''folder:f1#viewer'' with tupleset relation ''doc#parent''%'),
('user:bob', 'owner', 'doc:2', '22023 | Invalid tuple ''doc:2#owner@user:bob''. Reason: condition is missing%'),
('team:eng', 'viewer', 'doc:2', '22023 | Invalid tuple ''doc:2#viewer@team:eng''. Reason: type ''team'' is not an allowed type restriction for ''doc#viewer''%'),
('team:*', 'viewer', 'doc:2', '22023 | Invalid tuple ''doc:2#viewer@team:*''. Reason: the typed wildcard ''team:*'' is not an allowed type restriction for ''doc#viewer''%'),
('user:bob', 'viewer', 'doc:*', '22023 | Invalid tuple ''doc:*#viewer@user:bob''. Reason: the ''object'' field cannot reference a typed wildcard: doc:*%');
select tap.ok(pg_temp.outcome(format('select permissions.fga_write(%L::jsonb)', jsonb_build_array(jsonb_build_object('user', u, 'relation', r, 'object', o))))
              like want,
              format('fga_write %s#%s@%s: %s', o, r, u, split_part(want, ' | ', 1)))
from expect order by n;

-- contextual tuples take the same path (_fga_ctx -> _fga_tuple_for_write)
select tap.is(permissions.fga_check('user:dan', 'viewer', 'doc:3', '[{"user": "user:dan", "relation": "viewer", "object": "doc:3"}]'),
              true, 'a contextual tuple on the fast path counts');
select tap.throws_ok($$ select permissions.fga_check('user:dan', 'viewer', 'doc:3', '[{"user": "user:dan", "relation": "owner", "object": "doc:3"}]') $$,
                     '22023', 'a contextual tuple the fast path refuses still fails (condition is missing)');

select * from tap.finish();
