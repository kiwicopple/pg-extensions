-- Both JSON model shapes are accepted by OpenFGA v1.22.1. Its list
-- excludes direct grants on the subtract, and errors on an incomplete
-- conditional subtract even when Check never reaches that object.
\ir ../../fixtures/fga_suite.sql
select permissions.fga_write_authorization_model('{
 "schema_version":"1.1","type_definitions":[{"type":"user"},
 {"type":"team","relations":{"member":{"this":{}}},"metadata":{"relations":{
   "member":{"directly_related_user_types":[{"type":"user"}]}}}},
 {"type":"doc","relations":{
   "owner":{"this":{}}, "blocked":{"this":{}},
   "viewer":{"difference":{"base":{"computedUserset":{"relation":"owner"}},"subtract":{"this":{}}}},
   "reader":{"computedUserset":{"relation":"viewer"}},
   "safe":{"difference":{"base":{"computedUserset":{"relation":"owner"}},"subtract":{"computedUserset":{"relation":"blocked"}}}}
 },"metadata":{"relations":{
   "owner":{"directly_related_user_types":[{"type":"user"}]},
   "viewer":{"directly_related_user_types":[{"type":"user"},{"type":"user","wildcard":{}},{"type":"team","relation":"member"},{"type":"user","condition":"cc"}]},
   "blocked":{"directly_related_user_types":[{"type":"user","condition":"cc"}]}
 }}}],"conditions":{"cc":{"name":"cc","expression":"x","parameters":{"x":{"type_name":"TYPE_NAME_BOOL"}}}}}');
select permissions.fga_write_tuple('user:a','owner','doc:' || n) from generate_series(1,4) n;
select permissions.fga_write_tuple('user:a','viewer','doc:1');
select permissions.fga_write_tuple('user:*','viewer','doc:3');
select permissions.fga_write_tuple('team:t#member','viewer','doc:4');
select permissions.fga_write_tuple('user:a','member','team:t');
select permissions.fga_write('[{"user":"user:a","relation":"blocked","object":"doc:5","condition":{"name":"cc"}}]');

select tap.plan(15);
select tap.is(array(select n from generate_series(1,4) n where permissions.fga_check('user:a','viewer','doc:' || n)),
              '{2}'::int[], 'Check subtracts direct users, wildcards and usersets');
select tap.is(array(select permissions.fga_list_objects('user:a','doc','viewer')), '{doc:2}'::text[], 'ListObjects agrees with Check');
select tap.is(array(select permissions.fga_list_objects('user:a','doc','reader')), '{doc:2}'::text[], 'a computed relation inherits the same exclusions');
select tap.is(array(select permissions.fga_list_objects('user:a','doc','viewer',
              contextual_tuples => '[{"user":"user:a","relation":"viewer","object":"doc:2"}]')), '{}'::text[], 'subtract a contextual direct tuple');
select tap.is(permissions.fga_check('user:a','safe','doc:2'), true, 'Check allows the reachable base');
select tap.is(permissions.fga_check('user:a','safe','doc:5'), false, 'Check skips the subtract when the base is false');
select tap.ok((select detail like 'openfga:2000 %' from fga_test.error_of($q$select permissions.fga_list_objects('user:a','doc','safe')$q$)),
              'explicit ListObjects raises the iterator condition error, as the pinned server does');

create table documents(id text);
insert into documents select n::text from generate_series(1,5) n;
alter table documents enable row level security;
grant select on documents to authenticated;
create policy visible on documents for select using (id in (select permissions.fga_list_object_ids_current('doc','viewer')));
set role authenticated;
set permissions.subject_id = 'a';
select tap.is(permissions.fga_check_current('viewer','doc:1'), false, 'subject check rejects the excluded object');
select tap.is(array(select permissions.fga_list_objects_current('doc','viewer')), '{doc:2}'::text[], 'subject list of objects');
select tap.is(array(select permissions.fga_list_object_ids_current('doc','viewer')), '{2}'::text[], 'subject list of ids');
select tap.is(array(select id from documents), '{2}'::text[], 'actual RLS read matches Check');
select tap.is(array(select permissions.fga_list_object_ids_current('doc','safe') order by 1), '{1,2,3,4}'::text[], 'an unrelated malformed exclusion does not break subject reads');
reset role;
-- The same negative leaf must apply conditions in the right direction.
select permissions.fga_write('[{"user":"user:a","relation":"viewer","object":"doc:2","condition":{"name":"cc"}}]');
select tap.is(array(select permissions.fga_list_objects('user:a','doc','viewer',context=>'{"x":true}')), '{}'::text[], 'a true condition excludes the object');
select tap.is(array(select permissions.fga_list_objects('user:a','doc','viewer',context=>'{"x":false}')), '{doc:2}'::text[], 'a false condition does not exclude the object');
set role authenticated;
select tap.is(array(select permissions.fga_list_object_ids_current('doc','viewer')), '{}'::text[], 'missing context on a direct exclusion denies the candidate');
reset role;
select * from tap.finish();
