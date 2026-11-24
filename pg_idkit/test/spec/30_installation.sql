begin;
set local role idkit_owner;
select plan(7);
select ok((select bool_and(proowner = 'idkit_owner'::regrole) from pg_proc
    where pronamespace = 'ids'::regnamespace), 'all functions belong to the ordinary installer');
select is((select nspowner::regrole::text from pg_namespace where nspname = 'ids'),
    'idkit_owner', 'functions use the requested schema');
select is((select count(*) from idkit_test.installation), 1::bigint, 'one installation is under test');
select mode = 'plain' as plain, upgraded from idkit_test.installation \gset
\if :plain
    select ok(not exists(select from pg_extension where extname like 'pg_idkit%'),
        'direct loading creates no extension membership');
    select is((select count(*) from pg_depend d join pg_proc p on p.oid = d.objid
        where d.classid = 'pg_proc'::regclass and d.deptype = 'e' and p.pronamespace = 'ids'::regnamespace),
        0::bigint, 'directly loaded functions are independent objects');
\else
    select is((select e.extversion from pg_extension e join idkit_test.installation i on i.extension_name = e.extname),
        (select version from idkit_test.installation), 'extension reached the requested version');
    select is((select count(*) from pg_depend d join pg_proc p on p.oid = d.objid
        join pg_extension e on e.oid = d.refobjid join idkit_test.installation i on i.extension_name = e.extname
        where d.classid = 'pg_proc'::regclass and d.refclassid = 'pg_extension'::regclass
        and d.deptype = 'e' and p.pronamespace = 'ids'::regnamespace),
        6::bigint, 'all six functions are members of the installed extension');
\endif
\if :upgraded
    select is((select count(*) from idkit_test.existing_rows), 2::bigint,
        'pre-upgrade data and column defaults survive the upgrade');
    select ok((select count(*) = 5 and bool_and(p.prosrc = o.body)
        from idkit_test.old_functions o join pg_proc p on p.proname = o.name
        and p.pronamespace = 'ids'::regnamespace), 'upgrade preserves all five original function bodies');
\else
    select is((select count(*) from idkit_test.old_functions), 0::bigint, 'fresh installation starts without legacy snapshots');
    select ok(to_regclass('idkit_test.existing_rows') is null, 'fresh installation starts without legacy data');
\endif
select * from finish();
rollback;
