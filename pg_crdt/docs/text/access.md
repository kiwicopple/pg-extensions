# Control document access

Use wrapper functions to check who may edit each article. A browser must not have direct update access to the CRDT column: it could forge another writer's entries.

Run this setup once in an empty UTF8 test database with pg_crdt installed, as an administrator who can create and switch to the example roles. `app_owner` owns the tables and functions; `app_writer` can call only the wrappers. Use your own role names in an application.

The complete runnable setup is [text-app.sql](../examples/text-app.sql). Run the script or the blocks below, not both. This setup creates no sample articles. The [form guide](forms.md) creates the first one.

Identity settings in this example are set by a trusted application server after authentication. Direct SQL users must instead be identified by their database login or another source they cannot forge. See [Replicas and identity](../guides/replicas-and-identity.md#trust-model).

## Set up the roles

```sql
create role app_owner nologin;
create role app_writer nologin;
grant create on schema public to app_owner;
```

## Create the articles table

`body` holds the whole document. Its default, `crdt.yseq_new()`, gives each document an id, so that a state from one article cannot be merged or saved into another by mistake. `compression lz4` reduced edit costs in the benchmarks; use a Postgres build with LZ4 support for this example. Compression does not avoid rewriting the value. `body_text` is a stored generated column on `crdt.yseq_value`, which is `IMMUTABLE`: it is current after every write, and a full-text index can use it. Editors are listed in `article_editors`: that is your application's rule, and the wrappers check it.

```sql
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
```

The writer's identity in these examples is the setting `crdt.replica_id`, which your app server sets per transaction after it has authenticated the user (`set local`). `crdt.current_replica_id()` reads it, or a JWT claim when an API layer such as PostgREST verifies a token. A client that has direct SQL access can set any setting, so for such clients pass `session_user` or your own lookup instead. See [Replicas and identity](../guides/replicas-and-identity.md#where-the-identity-comes-from).

## Write the article wrappers

Create every wrapper as `app_owner`, pin `search_path`, and qualify every name. `create_article` writes the first text with `crdt.yseq_set` under the author's replica id and makes the author an editor.

`open_article` returns the text and a copy of the document state, called the base. Keep that base with the form and pass it to `save_article` with the edited text.

`crdt.yseq_set` compares the edited text with the base to work out what this editor changed. It applies those changes to the current document, preserving changes that other editors saved elsewhere in the meantime. This is a three-way save. The base must contain the whole `crdt.yseq` value because the column does not retain the text of deleted characters.

```sql
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
```

Live editors send ops instead of whole texts. `edit_article` hands them to `crdt.yseq_apply`, the write path for input you do not trust: it accepts inserts only under the writer's own replica id (or `<replica id>:<device>`), and checks that the op is consistent with what the writer says it has seen. Each call is one `update`, so the row lock serializes concurrent edits of one article. `sync_article` returns the ops that an editor at version `vv` lacks, and the version to ask from next time.

```sql
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
```

Postgres grants `execute` on a new function to `public`. Take that away and grant the wrappers to `app_writer`:

```sql
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
```

`app_writer` has no privileges on `articles`, so it cannot write the column directly, under any writer's name:

```sql
set role app_writer;
update public.articles set body = crdt.yseq_empty();
-- ERROR:  permission denied for table articles
reset role;
```


## Next

[Save changes from a form](forms.md), or use the same wrappers to [connect a live editor](live-editor.md).
