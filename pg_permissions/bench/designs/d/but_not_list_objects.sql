-- Manual measurement, not a bench phase (bench/run.sh doesn't read this file;
-- since phase 5 of session 5 the same workload is the bench's
-- block_list_objects, phase 7, seed_blocklist.sql):
-- ListObjects on a relation with `but not`, on a database the D benchmark
-- left behind (docker/run-matrix.sh bench ... --keep-running, or a local
-- bench/run.sh --external run). bench/baselines/D.md, "Diagnosis" 3 and
-- "opt2".
--
-- Writes a second model, which becomes the latest: the benchmark's model with
--   define blocked: [user]
--   define viewer: ([user, team#member] or editor or viewer from parent) but not blocked
-- and one blocked tuple for user 7 on one of the documents they see. Then
-- times fga_list_object_ids_current('document', 'viewer') for user 7 and users
-- 1-30, set-based (the compiled diff_relation), and the per-candidate path
-- (diff_relation cleared inside a rolled-back transaction) for user 7, and a
-- Check on the relation. Prints one row per measurement.
--
--   psql -X -d pgperm_bench -f bench/designs/d/but_not_list_objects.sql

\set ON_ERROR_STOP 1

select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user"}, {"type": "team", "relation": "member"}]}}}},
    {"type": "folder", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "document",
     "relations": {
       "parent": {"this": {}},
       "editor": {"this": {}},
       "blocked": {"this": {}},
       "viewer": {"difference": {
         "base": {"union": {"child": [
           {"this": {}},
           {"computedUserset": {"relation": "editor"}},
           {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}},
         "subtract": {"computedUserset": {"relation": "blocked"}}}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder"}]},
       "editor": {"directly_related_user_types": [{"type": "user"}]},
       "blocked": {"directly_related_user_types": [{"type": "user"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]}}}}
  ]}$m$::jsonb) is not null as model_written;

select set_config('permissions.subject_id', md5('user' || 7)::uuid::text, false);
select permissions.fga_write_tuple('user:' || md5('user' || 7)::uuid, 'blocked',
                                   'document:' || min(x))
from permissions.fga_list_object_ids_current('document', 'viewer') x;

create function pg_temp.time_list(p_users int[], p_reps int)
returns table (calls int, ms_per_call numeric, ids_per_call numeric)
language plpgsql as $$
declare
    t0 timestamptz;
    n bigint := 0;
    c bigint;
    u int;
begin
    perform set_config('permissions.subject_id', md5('user' || p_users[1])::uuid::text, false);
    perform count(*) from permissions.fga_list_object_ids_current('document', 'viewer');   -- warm
    t0 := clock_timestamp();
    for r in 1 .. p_reps loop
        foreach u in array p_users loop
            perform set_config('permissions.subject_id', md5('user' || u)::uuid::text, false);
            select count(*) into c from permissions.fga_list_object_ids_current('document', 'viewer');
            n := n + c;
        end loop;
    end loop;
    calls := p_reps * cardinality(p_users);
    ms_per_call := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / calls, 2);
    ids_per_call := round(n::numeric / calls, 1);
    return next;
end;
$$;

create function pg_temp.time_check(p_reps int)
returns numeric
language plpgsql as $$
declare
    t0 timestamptz;
    d text;
begin
    perform set_config('permissions.subject_id', md5('user' || 7)::uuid::text, false);
    select max(x) into d from permissions.fga_list_object_ids_current('document', 'viewer') x;
    t0 := clock_timestamp();
    for r in 1 .. p_reps loop
        perform permissions.fga_check_current('viewer', 'document:' || d);
    end loop;
    return round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / p_reps, 3);
end;
$$;

select 'set-based, user 7' as measurement, * from pg_temp.time_list('{7}', 20);
select 'set-based, users 1-30' as measurement, * from pg_temp.time_list(array(select generate_series(1, 30)), 3);
begin;
update permissions.fga_relations set diff_relation = null
where model_id = (select id from permissions.fga_models order by seq desc limit 1)
  and type = 'document' and relation = 'viewer';
select 'per-candidate, user 7' as measurement, * from pg_temp.time_list('{7}', 2);
rollback;
select 'check (top-down), user 7' as measurement, pg_temp.time_check(500) as ms_per_call;
