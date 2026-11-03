-- Runs the cases that a generated 4x_json_schema_suite*.sql spec loaded into
-- jsts_group and jsts_case: one assertion per case (a skipped case is a SKIP
-- pass), one assertion that json_schema_errors() agrees with json_schema(),
-- and a per-file summary as "#" lines (shown with test/run.sh -v).
create function pg_temp.jsts_run(schema jsonb, data jsonb)
returns text
language plpgsql
as $$
begin
    return validate.json_schema(data, schema)::text;
exception when others then
    return 'error ' || sqlstate || ': ' || sqlerrm;
end;
$$;

create function pg_temp.jsts_errors_agree(schema jsonb, data jsonb, got text)
returns boolean
language plpgsql
as $$
begin
    return got not in ('true', 'false')
        or (got = 'true') = not exists (select 1 from validate.json_schema_errors(data, schema));
exception when others then
    return false;
end;
$$;

update jsts_case c
set got = pg_temp.jsts_run(g.schema, c.data)
from jsts_group g
where g.gid = c.gid and c.skip is null;

select tap.plan((select count(*)::int + 1 from jsts_case));

select case when c.skip is not null
            then tap.pass(format('SKIP %s: %s: %s (%s)', g.file, g.description, c.description, c.skip))
            else tap.is(c.got, c.valid::text, format('%s: %s: %s', g.file, g.description, c.description))
       end
from jsts_case c
join jsts_group g using (gid)
order by c.id;

select tap.is(
    (select count(*)::int from jsts_case c join jsts_group g using (gid)
     where c.skip is null and not pg_temp.jsts_errors_agree(g.schema, c.data, c.got)),
    0, 'json_schema_errors() returns no rows exactly when json_schema() is true, on every case run');

select format('# %-45s %4s passed %4s failed %4s skipped of %4s',
              g.file,
              count(*) filter (where c.skip is null and c.got = c.valid::text),
              count(*) filter (where c.skip is null and c.got is distinct from c.valid::text),
              count(*) filter (where c.skip is not null),
              count(*))
from jsts_case c
join jsts_group g using (gid)
group by g.file
order by g.file;

select * from tap.finish();
