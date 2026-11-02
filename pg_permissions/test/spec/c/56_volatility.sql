-- Goal: the functions RLS policies call are STABLE, not VOLATILE
-- Design C: policies call these inside `array(select unnest(...))`. A STABLE
-- function with constant arguments is evaluated by the planner (to estimate
-- the unnest's row count), so the list functions have a trailing argument
-- whose default is a volatile function that returns null
-- (permissions._unfolded_null), which keeps the call from being pre-evaluated.
-- VOLATILE would also do that, but under read committed a volatile function
-- takes a fresh snapshot for each query it runs, so the grants it reads could
-- be from a later instant than the rows the statement filters. STABLE
-- functions read the statement's snapshot.
select tap.plan(3);

-- provolatile: 's' stable, 'v' volatile
select tap.is(
    (select array_agg(p.proname::text order by p.proname) from pg_proc p
      where p.pronamespace = 'permissions'::regnamespace and p.provolatile <> 's'
        and p.proname in ('can', 'accessible', 'has_permission', 'has_role', 'scopes_with_permission')),
    null::text[],
    'every RLS-facing function is STABLE');

select tap.is(
    (select count(distinct p.proname) from pg_proc p
      where p.pronamespace = 'permissions'::regnamespace and p.provolatile = 's'
        and p.proname in ('can', 'accessible', 'has_permission', 'has_role', 'scopes_with_permission')),
    5::bigint,
    'all 5 RLS-facing functions exist');

-- Only the dummy-argument default is volatile
select tap.is(
    (select provolatile::text from pg_proc where oid = 'permissions._unfolded_null'::regproc),
    'v',
    '_unfolded_null() is VOLATILE, so a call that defaults it isn''t constant');

select * from tap.finish();
