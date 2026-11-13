-- Goal: non-superuser install, schema guards and column dependencies.
\set ON_ERROR_STOP off

select current_database() as orig_db \gset
select exists (select 1 from pg_available_extensions where name = 'pg_tle')
       and current_setting('shared_preload_libraries') ~ '\mpg_tle\M' as tle_avail \gset
select exists (select 1 from pg_available_extensions where name = 'pg_crdt') as ctl_avail \gset

-- Defaults, so a failed step leaves a visible value instead of an unset variable.
\set own_super ''
\set schema_owner ''
\set funcs ''
\set unowned ''
\set c_funcs ''
\set smoke ''
\set guard_owner_out ''
\set guard_create_out ''
\set tle_installed ''
\set tle_schema ''
\set tle_members ''
\set tle_smoke ''
\set tle_drop_restrict ''
\set tle_drop_cascade ''
\set ctl_schema ''
\set ctl_reloc ''
\set ctl_smoke ''
\set yseq_smoke ''
\set tle_yseq_restrict ''
\set tle_yseq_cascade ''
\set ctl_yseq_restrict ''
\set ctl_yseq_cascade ''
\set column_dump ''
\set column_after_dump ''
\set default_acl_left ''

-- Leftovers from an earlier run
drop database if exists pgcrdt_install_plain with (force);
drop database if exists pgcrdt_install_guard with (force);
drop database if exists pgcrdt_install_tle with (force);
drop database if exists pgcrdt_install_ctl with (force);
drop database if exists pgcrdt_install_restore with (force);
drop role if exists crdt_owner;
drop role if exists crdt_other;

create role crdt_owner nosuperuser createdb nologin;
create role crdt_other nosuperuser nologin;
-- SQL_ASCII on purpose: the file must also install in a database that is not
-- UTF8 (no U& literals with non-ASCII characters in function bodies).
create database pgcrdt_install_plain owner crdt_owner encoding 'SQL_ASCII' template template0;
create database pgcrdt_install_guard owner crdt_owner;

-- 1. Plain install (psql -f) as the non-superuser
\connect pgcrdt_install_plain
set session authorization crdt_owner;
select current_setting('is_superuser') as own_super \gset
-- The installer's default privileges must not leak onto the crdt objects
-- (the privileges section of the file strips them).
alter default privileges grant all on tables to crdt_other;
alter default privileges grant all on sequences to crdt_other;
alter default privileges grant execute on functions to crdt_other;

\i :impl_path

select nspowner::regrole::text as schema_owner from pg_namespace where nspname = 'crdt' \gset
select (select count(*) from pg_proc where pronamespace = 'crdt'::regnamespace) as funcs,
       (select count(*) from pg_proc where pronamespace = 'crdt'::regnamespace and proowner <> 'crdt_owner'::regrole)
     + (select count(*) from pg_type where typnamespace = 'crdt'::regnamespace and typowner <> 'crdt_owner'::regrole)
     + (select count(*) from pg_class where relnamespace = 'crdt'::regnamespace and relowner <> 'crdt_owner'::regrole) as unowned,
       (select count(*) from pg_proc p join pg_language l on l.oid = p.prolang
        where p.pronamespace = 'crdt'::regnamespace and l.lanname = 'c') as c_funcs \gset

create table counters (id int primary key, s crdt.pn not null default crdt.pn_empty());
insert into counters values (1);
update counters set s = crdt.pn_increment(s, 'a', 5) where id = 1;
update counters set s = crdt.pn_merge(s, crdt.pn_decrement(crdt.pn_empty(), 'b', 2)) where id = 1;
select (crdt.pn_value(s) = 3 and crdt.pn_value((select crdt.pn_merge_agg(s) from counters)) = 3)::text as smoke
from counters where id = 1 \gset
create table notes (
    id int primary key,
    body crdt.yseq not null default crdt.yseq_new(),
    body_text text generated always as (crdt.yseq_value(body)) stored
);
insert into notes (id) values (1);
update notes set body = crdt.yseq_insert(body, 0, 'hello', 'a') where id = 1;
update notes set body = crdt.yseq_set(body, 'hello, world', 'b') where id = 1;
select (body_text = 'hello, world' and crdt.yseq_is_valid(body))::text as yseq_smoke from notes where id = 1 \gset
select (select count(*) from pg_class c
        cross join lateral aclexplode(coalesce(c.relacl, acldefault(case c.relkind when 'S' then 's' else 'r' end::"char", c.relowner))) x
        where c.relnamespace = 'crdt'::regnamespace and x.grantee = 'crdt_other'::regrole)
     + (select count(*) from pg_proc p
        cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) x
        where p.pronamespace = 'crdt'::regnamespace and x.grantee = 'crdt_other'::regrole) as default_acl_left \gset

-- 2. The schema guard: a crdt schema owned by another non-superuser, then one
-- where another role has CREATE. Each install must stop at the guard.
\connect pgcrdt_install_guard
create schema crdt authorization crdt_other;
\set guard_owner_out `psql -X -q -v ON_ERROR_STOP=1 -d pgcrdt_install_guard -c 'set session authorization crdt_owner' -f :'impl_path' 2>&1`
alter schema crdt owner to crdt_owner;
grant create on schema crdt to crdt_other;
\set guard_create_out `psql -X -q -v ON_ERROR_STOP=1 -d pgcrdt_install_guard -c 'set session authorization crdt_owner' -f :'impl_path' 2>&1`

-- 3. pg_tle (only if the server has it loaded)
\if :tle_avail
    \connect postgres
    create database pgcrdt_install_tle owner crdt_owner;
    \connect pgcrdt_install_tle
    create extension pg_tle;
    grant pgtle_admin to crdt_owner;
    set session authorization crdt_owner;
    -- pg_tle refuses a name that also has a control file on disk
    -- (test/docker.sh installs one for the control-file branch).
    select case when :'ctl_avail' then 'pg_crdt_tle' else 'pg_crdt' end as tle_name \gset
    -- Backticks interpolate :name and :'name' (shell-quoted), not :"name".
    \set impl_body `cat :'impl_path'`
    select pgtle.install_extension(
        name => :'tle_name',
        version => '0.0.1',
        description => 'pg_crdt test install',
        ext => :'impl_body',
        schema => 'crdt'
    );
    create extension :"tle_name";
    select count(*)::text as tle_installed from pg_extension where extname = :'tle_name' \gset
    select extnamespace::regnamespace::text as tle_schema from pg_extension where extname = :'tle_name' \gset
    select count(*)::text as tle_members
    from pg_depend d
    where d.refclassid = 'pg_extension'::regclass and d.deptype = 'e'
      and d.refobjid = (select oid from pg_extension where extname = :'tle_name')
      and ((d.classid = 'pg_proc'::regclass and d.objid in (select oid from pg_proc where pronamespace = 'crdt'::regnamespace))
        or (d.classid = 'pg_type'::regclass and d.objid = 'crdt.pn'::regtype)
        or (d.classid = 'pg_class'::regclass and d.objid in (select oid from pg_class where relnamespace = 'crdt'::regnamespace))) \gset
    create table counters (id int primary key, s crdt.pn not null default crdt.pn_empty());
    insert into counters values (1);
    update counters set s = crdt.pn_increment(s, 'a', 2) where id = 1;
    select (crdt.pn_value(s) = 2)::text as tle_smoke from counters \gset
    create table notes (id int primary key, body crdt.yseq not null default crdt.yseq_empty(),
                        body_text text generated always as (crdt.yseq_value(body)) stored);
    insert into notes (id, body) values (1, crdt.yseq_insert(null, 0, 'tle', 'a'));
    -- restrict: blocked by the column; cascade: drops the column
    select set_config('crdt_test.tle_name', :'tle_name', false);
    do $$
    begin
        execute format('drop extension %I', current_setting('crdt_test.tle_name'));
        perform set_config('crdt_test.drop_restrict', 'dropped', false);
    exception when dependent_objects_still_exist then
        perform set_config('crdt_test.drop_restrict', 'blocked', false);
    end;
    $$;
    select current_setting('crdt_test.drop_restrict', true) as tle_drop_restrict \gset
    -- the same with only the crdt.yseq column left
    alter table counters drop column s;
    do $$
    begin
        execute format('drop extension %I', current_setting('crdt_test.tle_name'));
        perform set_config('crdt_test.yseq_restrict', 'dropped', false);
    exception when dependent_objects_still_exist then
        perform set_config('crdt_test.yseq_restrict', 'blocked', false);
    end;
    $$;
    select current_setting('crdt_test.yseq_restrict', true) as tle_yseq_restrict \gset
    alter table counters add column s crdt.pn not null default crdt.pn_empty();
    drop extension :"tle_name" cascade;
    select (not exists (select 1 from pg_attribute where attrelid = 'counters'::regclass and attname = 's' and not attisdropped)
            and to_regtype('crdt.pn') is null)::text as tle_drop_cascade \gset
    select (to_regclass('notes') is not null
            and (select string_agg(attname, ',' order by attnum) from pg_attribute
                 where attrelid = 'notes'::regclass and attnum > 0 and not attisdropped) = 'id'
            and to_regtype('crdt.yseq') is null)::text as tle_yseq_cascade \gset
\endif

-- 4. The control file in the extension directory (only if it is installed there)
\if :ctl_avail
    \connect postgres
    create database pgcrdt_install_ctl owner crdt_owner;
    \connect pgcrdt_install_ctl
    set session authorization crdt_owner;
    create extension pg_crdt;
    select extnamespace::regnamespace::text as ctl_schema, extrelocatable::text as ctl_reloc
    from pg_extension where extname = 'pg_crdt' \gset
    select (crdt.pn_value(crdt.pn_merge(crdt.pn_increment(null, 'a', 4), crdt.pn_decrement(null, 'b', 1))) = 3)::text as ctl_smoke \gset
    -- A crdt.yseq column (with a generated column on yseq_value) blocks drop
    -- extension with 2BP01; CASCADE drops both columns and keeps the table.
    create table notes (
        id int primary key,
        body crdt.yseq not null default crdt.yseq_new(),
        body_text text generated always as (crdt.yseq_value(body)) stored
    );
    insert into notes (id) values (1);
    update notes set body = crdt.yseq_insert(body, 0, 'kept?', 'a') where id = 1;
    -- A dump keeps the full column state, its document id, and generated text.
    select md5(body::text) as before_dump from notes where id = 1 \gset
    reset session authorization;
    \connect postgres
    create database pgcrdt_install_restore;
    \set dump_out `pg_dump --no-owner -d pgcrdt_install_ctl | psql -X -q -v ON_ERROR_STOP=1 -d pgcrdt_install_restore 2>&1`
    \connect pgcrdt_install_restore
    select (md5(body::text) = :'before_dump' and body_text = 'kept?'
            and crdt.yseq_is_valid(body))::text as column_dump from notes where id = 1 \gset
    update notes set body = crdt.yseq_insert(body, 5, '!', 'b') where id = 1;
    select (body_text = 'kept?!')::text as column_after_dump from notes where id = 1 \gset
    \connect pgcrdt_install_ctl
    set session authorization crdt_owner;

    do $$
    begin
        drop extension pg_crdt;
        perform set_config('crdt_test.ctl_yseq_restrict', 'dropped', false);
    exception when others then
        perform set_config('crdt_test.ctl_yseq_restrict', sqlstate, false);
    end;
    $$;
    select current_setting('crdt_test.ctl_yseq_restrict', true) as ctl_yseq_restrict \gset
    drop extension pg_crdt cascade;
    select (to_regclass('notes') is not null
            and (select string_agg(attname, ',' order by attnum) from pg_attribute
                 where attrelid = 'notes'::regclass and attnum > 0 and not attisdropped) = 'id'
            and (select count(*) from notes) = 1
            and to_regtype('crdt.yseq') is null)::text as ctl_yseq_cascade \gset
\endif

-- Back to the spec database as the superuser for the assertions.
\connect :"orig_db"

select tap.plan(17);

select tap.is(:'own_super'::text, 'off', 'the install session is not a superuser');
select tap.is(:'schema_owner'::text, 'crdt_owner', 'schema crdt is owned by the installing non-superuser');
select tap.ok(:'funcs'::text ~ '^[1-9]' and :'unowned'::text = '0',
              'every function and type in schema crdt is owned by the installing role (funcs: '
              || :'funcs'::text || ', not owned: ' || :'unowned'::text || ')');
select tap.is(:'c_funcs'::text, '0', 'no function is written in C');
select tap.is(:'smoke'::text, 'true', 'smoke: a crdt.pn column, increment, merge and the aggregate work after a non-superuser install');
select tap.is(:'yseq_smoke'::text, 'true', 'smoke: a crdt.yseq column with a generated column on yseq_value, yseq_insert and yseq_set work after a non-superuser install');
select tap.is(:'default_acl_left'::text, '0', 'the installer''s default privileges are stripped from every crdt table, sequence and function');
select tap.ok(:'guard_owner_out'::text like '%schema crdt is owned by role crdt_other%',
              'the install stops when schema crdt belongs to another non-superuser');
select tap.ok(:'guard_create_out'::text like '%another role has CREATE on schema crdt%',
              'the install stops when another role has CREATE on schema crdt');

\if :tle_avail
    select tap.ok(:'tle_installed'::text = '1' and :'tle_schema'::text = 'crdt' and :'tle_members'::text ~ '^[1-9]',
                  'pgtle.install_extension + create extension works as a non-superuser, in schema crdt (members: '
                  || :'tle_members'::text || ')');
    select tap.is(:'tle_smoke'::text, 'true', 'smoke: a crdt.pn column works under pg_tle');
    select tap.ok(:'tle_drop_restrict'::text = 'blocked' and :'tle_drop_cascade'::text = 'true',
                  'drop extension is blocked by a crdt.pn column, and drop extension ... cascade drops the column (restrict: '
                  || :'tle_drop_restrict'::text || ', cascade: ' || :'tle_drop_cascade'::text || ')');
    select tap.ok(:'tle_yseq_restrict'::text = 'blocked' and :'tle_yseq_cascade'::text = 'true',
                  'under pg_tle: drop extension is blocked by a crdt.yseq column, and cascade drops it and its generated column (restrict: '
                  || :'tle_yseq_restrict'::text || ', cascade: ' || :'tle_yseq_cascade'::text || ')');
\else
    \echo '# pg_tle is not available on this server; the pgtle.install_extension path was NOT tested'
    select tap.pass('SKIP pg_tle not available: install_extension');
    select tap.pass('SKIP pg_tle not available: smoke');
    select tap.pass('SKIP pg_tle not available: drop extension restrict and cascade');
    select tap.pass('SKIP pg_tle not available: drop extension with a crdt.yseq column');
\endif

\if :ctl_avail
    select tap.ok(:'ctl_schema'::text = 'crdt' and :'ctl_reloc'::text = 'false' and :'ctl_smoke'::text = 'true',
                  'create extension pg_crdt from the control file works as a non-superuser, in schema crdt, not relocatable');
    select tap.is(:'column_dump'::text, 'true', 'pg_dump restores the full text-column state, document id and generated text');
    select tap.is(:'column_after_dump'::text, 'true', 'a restored text column accepts edits and refreshes generated text');
    select tap.ok(:'ctl_yseq_restrict'::text = '2BP01' and :'ctl_yseq_cascade'::text = 'true',
                  'drop extension fails with 2BP01 while a crdt.yseq column exists; cascade drops it and its generated column, and keeps the table and rows (restrict: '
                  || :'ctl_yseq_restrict'::text || ', cascade: ' || :'ctl_yseq_cascade'::text || ')');
\else
    \echo '# pg_crdt is not in this server''s extension directory; the control-file path was NOT tested'
    select tap.pass('SKIP control file not installed: create extension pg_crdt');
    select tap.pass('SKIP control file not installed: text-column dump and restore');
    select tap.pass('SKIP control file not installed: editing after restore');
    select tap.pass('SKIP control file not installed: drop extension with a crdt.yseq column');
\endif

-- Cleanup
drop database if exists pgcrdt_install_plain with (force);
drop database if exists pgcrdt_install_guard with (force);
drop database if exists pgcrdt_install_tle with (force);
drop database if exists pgcrdt_install_ctl with (force);
drop database if exists pgcrdt_install_restore with (force);
drop role if exists crdt_owner;
drop role if exists crdt_other;

select * from tap.finish();
