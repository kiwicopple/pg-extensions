-- Run once as an administrator in a fresh UTF8 test database.
create role app_owner nologin;
create role app_writer nologin;
grant create on schema public to app_owner;

set role app_owner;

create table public.articles (
  id bigint generated always as identity primary key,
  title text not null,
  body crdt.yseq compression lz4 not null default crdt.yseq_new(),
  body_text text generated always as (crdt.yseq_value(body)) stored
);

create index articles_body_search
  on public.articles
  using gin (to_tsvector('english', body_text));

create table public.article_editors (
  article_id bigint references public.articles (id) on delete cascade,
  editor text not null,
  primary key (article_id, editor)
);

reset role;

set role app_owner;

create function public.create_article(title text, body text)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  author text := crdt.current_replica_id();
  article_id bigint;
begin
  if author is null then
    raise exception 'no user' using errcode = '42501';
  end if;
  insert into public.articles (title, body)
  values (title, crdt.yseq_set(crdt.yseq_new(), body, replica => author))
  returning id into article_id;
  insert into public.article_editors values (article_id, author);
  return article_id;
end;
$$;

create function public.open_article(article_id bigint)
returns table (title text, body text, base crdt.yseq)
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
begin atomic
  select a.title, a.body_text, a.body
  from public.articles a
  join public.article_editors e on e.article_id = a.id
  where a.id = open_article.article_id
    and e.editor = crdt.current_replica_id();
end;

create function public.save_article(
  article_id bigint,
  body text,
  base crdt.yseq
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  writer text := crdt.current_replica_id();
  merged text;
begin
  update public.articles a
  set body = crdt.yseq_set(a.body, save_article.body,
                           replica => writer, base => base)
  where a.id = save_article.article_id
    and exists (
      select 1 from public.article_editors e
      where e.article_id = a.id and e.editor = writer
    )
  returning a.body_text into merged;
  if not found then
    raise exception 'not an editor of article %', article_id
      using errcode = '42501';
  end if;
  return merged;
end;
$$;

create function public.edit_article(article_id bigint, ops jsonb)
returns void
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  writer text := crdt.current_replica_id();
begin
  update public.articles a
  set body = crdt.yseq_apply(a.body, ops, replica => writer)
  where a.id = edit_article.article_id
    and exists (
      select 1 from public.article_editors e
      where e.article_id = a.id and e.editor = writer
    );
  if not found then
    raise exception 'not an editor of article %', article_id
      using errcode = '42501';
  end if;
end;
$$;

create function public.sync_article(article_id bigint, vv jsonb)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
return (
  select jsonb_build_object(
    'ops', crdt.yseq_ops_since(a.body, vv),
    'version', crdt.yseq_version(a.body)
  )
  from public.articles a
  join public.article_editors e on e.article_id = a.id
  where a.id = sync_article.article_id
    and e.editor = crdt.current_replica_id()
);

reset role;

revoke all on function
  public.create_article(text, text),
  public.open_article(bigint),
  public.save_article(bigint, text, crdt.yseq),
  public.edit_article(bigint, jsonb),
  public.sync_article(bigint, jsonb)
from public;
grant execute on function
  public.create_article(text, text),
  public.open_article(bigint),
  public.save_article(bigint, text, crdt.yseq),
  public.edit_article(bigint, jsonb),
  public.sync_article(bigint, jsonb)
to app_writer;
