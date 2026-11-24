-- Run once, as the owner, after installing pg_crdt in a dedicated demo DB.
begin;
create schema crdt_demo;
revoke all on schema crdt_demo from public;

create table crdt_demo.counters (
  id uuid primary key,
  state crdt.pn not null default crdt.pn_empty(),
  expires_at timestamptz not null
);
create index counters_expires_at_idx on crdt_demo.counters (expires_at);
revoke all on crdt_demo.counters from public;

-- Set the password separately with psql's \password command.
create role crdt_demo_app login;
grant usage on schema crdt, crdt_demo to crdt_demo_app;
grant select, insert, update, delete on crdt_demo.counters to crdt_demo_app;
alter table crdt_demo.counters enable row level security;
-- The server authenticates the signed demo session before issuing SQL. Only
-- this restricted server role can access rows; browser/API roles have no grants.
create policy demo_server_access on crdt_demo.counters
  for all to crdt_demo_app using (true) with check (true);
alter role crdt_demo_app set statement_timeout = '5s';
alter role crdt_demo_app set lock_timeout = '3s';
commit;
