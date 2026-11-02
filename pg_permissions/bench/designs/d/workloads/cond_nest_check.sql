-- Conditions: one Check through a nested, conditioned team. The conditioned
-- twin of nest_check: user md5('nest-user' || i) is in cteam md5('nest-src'),
-- nested in cteam :teams, which can view the document through `cviewer`;
-- both memberships and the grant carry the condition.
\set i random(1, 1000)
\set j random(1, 5)
\set d (:teams * 9973 + :j * 7919) % :docs + 1
begin;
select set_config('permissions.subject_id', md5('nest-user' || :i)::uuid::text, true);
set local role authenticated;
select permissions.fga_check_current('cviewer', 'document:' || md5('doc' || :d)::uuid);
commit;
