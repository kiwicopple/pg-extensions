-- Goal: the text is server-readable (research/text.md, "Goal"): a stored
-- generated column on yseq_value, a full-text GIN index on it, an expression
-- index the planner uses, `like`, and REINDEX under the search_path that
-- maintenance commands use (pg_catalog, pg_temp).

select tap.plan(8);

create table posts (
    id int primary key,
    body crdt.yseq not null default crdt.yseq_empty(),
    body_text text generated always as (crdt.yseq_value(body)) stored
);
create index posts_fts on posts using gin (to_tsvector('english', crdt.yseq_value(body)));
create index posts_len on posts (crdt.yseq_length(body));

insert into posts (id, body)
select g, crdt.yseq_insert(crdt.yseq_empty(), 0, 'post number ' || g || case when g % 100 = 0 then ' about postgres replication' else ' about cats' end, 'seed')
from generate_series(1, 2000) g;
update posts set body = crdt.yseq_set(body, 'Conflict-free replicated data types in Postgres', 'alice') where id = 7;
analyze posts;

select tap.is((select body_text from posts where id = 7), 'Conflict-free replicated data types in Postgres', 'the generated column follows updates');
select tap.is((select count(*) from posts where to_tsvector('english', crdt.yseq_value(body)) @@ to_tsquery('english', 'replication')), 21::bigint,
              'full-text search on yseq_value finds the documents');
create function pg_temp.plan(q text) returns text language plpgsql as $$
declare
    x text;
    res text := '';
begin
    for x in execute 'explain ' || q loop
        res := res || x || ' ';
    end loop;
    return res;
end;
$$;
set enable_seqscan = off;
select tap.ok(pg_temp.plan($$select id from posts where to_tsvector('english', crdt.yseq_value(body)) @@ to_tsquery('english', 'replication')$$)
              ~ 'posts_fts', 'the planner uses the GIN index on to_tsvector(yseq_value(body))');
select tap.ok(pg_temp.plan('select id from posts where crdt.yseq_length(body) = 47') ~ 'posts_len',
              'and the expression index on yseq_length');
reset enable_seqscan;
select tap.is((select count(*) from posts where body_text like '%Postgres%'), 1::bigint, 'like on the generated column');
set search_path = pg_catalog, pg_temp;
select tap.lives_ok('reindex table public.posts', 'REINDEX under search_path = pg_catalog, pg_temp');
select tap.lives_ok($$update public.posts set body = crdt.yseq_insert(body, 0, 'x', 'bob') where id = 8$$,
                    'updates recompute the generated column under that search_path');
reset search_path;
select tap.is((select body_text from posts where id = 8), 'xpost number 8 about cats', 'and it is correct');
select * from tap.finish();
