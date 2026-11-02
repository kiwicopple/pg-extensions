-- Benchmark data shape, shared by every design. Loaded first by bench/run.sh.
--
-- Plain integer tables in schema `bench` (not `permissions`, so they don't
-- count toward the permission storage numbers). Each design's seed reads them
-- and writes the same facts through its own API, so the data is identical
-- across designs by construction and only the engine differs. The IDs are the
-- md5-derived UUIDs of seed_rbac.sql:
--   team k   -> md5('team'   || k)::uuid, k in 1 .. teams
--   folder f -> md5('folder' || f)::uuid, f in 0 .. orgs * 10 - 1, in org f % orgs
--
-- psql variables (set by bench/run.sh from --scale and --shape):
--   docs, users, orgs, teams
--   mpu     teams per user (memberships per user)
--   gpt     documents shared with each team (grants per team)
--   nesting tree4: team k > 3 is nested in team k / 4 (4-ary tree, ~5 levels at 500 teams)
--           chain: teams form ceil(teams / levels) chains `levels` deep, users in the leaf teams
--   levels  chain depth (deep shape)
--
-- Shapes (bench/run.sh --shape):
--   default  mpu 1,  gpt 5,  tree4                 (the original sharing seed, unchanged)
--   deep     mpu 1,  gpt 5,  chain of 9 levels     (user -> leaf team -> 8 more teams; with the
--                                                  write_nest_team hop that is depth 10, the max
--                                                  B and C accept)
--   wide     mpu 50, gpt 50, tree4, 4x the teams   (each user in 50 teams, 50 grants per team)

\set ON_ERROR_STOP 1

drop schema if exists bench cascade;
create schema bench;

-- user u is a member of team `team`
create table bench.team_members (u int not null, team int not null);
-- team `child` is nested in team `parent` (child's members are parent's members)
create table bench.team_parents (child int not null, parent int not null);
-- team `team` can view document `doc`
create table bench.team_grants (team int not null, doc int not null);
-- user u can edit document `doc` directly
create table bench.user_grants (u int not null, doc int not null);
-- folder f is in org `org`; documents point at it through documents.folder_id
create table bench.folders (f int not null, org int not null);
-- user u is a viewer of folder f
create table bench.folder_viewers (u int not null, f int not null);

select (:teams + :levels - 1) / :levels as chain_width, :'nesting' = 'chain' as is_chain \gset

\if :is_chain
-- chain c (0 .. width-1) holds teams c+1, c+1+width, c+1+2*width, ...; the
-- deepest one is the leaf, and every user of the chain is a member there.
insert into bench.team_members (u, team)
select u, (c + 1 + :chain_width * ((:teams - c - 1) / :chain_width))::int
from generate_series(1, :users) u, lateral (select u % :chain_width as c) x
order by u;

insert into bench.team_parents (child, parent)
select k, k - :chain_width from generate_series(:chain_width + 1, :teams) k;
\else
-- mpu distinct teams per user, spread by a stride of teams / mpu
insert into bench.team_members (u, team)
select u, ((u + j * (:teams / :mpu)) % :teams + 1)::int
from generate_series(1, :users) u, generate_series(0, :mpu - 1) j
order by u, j;

insert into bench.team_parents (child, parent)
select k, k / 4 from generate_series(4, :teams) k;
\endif

insert into bench.team_grants (team, doc)
select k, ((k::bigint * 9973 + i * 7919) % :docs + 1)::int
from generate_series(1, :teams) k, generate_series(1, :gpt) i
order by k, i;

insert into bench.user_grants (u, doc)
select u, ((u::bigint * 104729 + i * 15485863) % :docs + 1)::int
from generate_series(1, :users) u, generate_series(1, 2) i
order by u, i;

-- about 10 folders per org; documents.folder_id (seed_rbac.sql) matches this
insert into bench.folders (f, org)
select f, f % :orgs from generate_series(0, :orgs * 10 - 1) f;

-- every 5th user views one folder, usually in an org where they hold no role
insert into bench.folder_viewers (u, f)
select u, (u * 37 + 11) % (:orgs * 10)
from generate_series(5, :users, 5) u;

analyze bench.team_members, bench.team_parents, bench.team_grants, bench.user_grants,
        bench.folders, bench.folder_viewers;
