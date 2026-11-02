-- One assertion per row of the cases table (see cases.sql).
select tap.is(
    pg_temp.call(fn, input),
    want,
    format('%s(%s) is %s%s', fn, coalesce(quote_literal(input), 'null'), coalesce(want::text, 'null'),
           coalesce(' -- ' || note, '')))
from cases
order by id;
