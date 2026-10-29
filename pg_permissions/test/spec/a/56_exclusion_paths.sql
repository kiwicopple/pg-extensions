-- Goal: exclusions, wildcards, group cycles and expiry along multi-hop paths give the
-- same answer from check_for (bidirectional search), list_objects_for (forward walk)
-- and list_subjects (backward walk). Regression for the bidirectional check_for: a
-- backward search that ignores exclusions finds a path through a blocked node.
-- PROVISIONAL: uses Design A's zanzibar-level API.
--
-- Every user also holds a few unrelated direct grants (decoys). A user with a single
-- tuple has a one-node forward frontier, which makes the search start forwards; with
-- decoys the first steps run backwards from the object, so the backward direction
-- is the one under test.
--
-- Exclusion semantics (designs/a-tuple-core.md section 12.3): a `blocked` tuple on an
-- object removes that object's relation for that user, whatever path leads there,
-- and everything derived through it. A direct grant on a child still applies.

select permissions.define_type('user');
select permissions.define_type('team');
select permissions.define_type('org');
select permissions.define_type('folder');
select permissions.define_type('document');

select permissions.define_relation('team', 'member');
select permissions.define_relation('org', 'admin');
select permissions.define_relation('org', 'member', '{admin}');
select permissions.define_relation('org', 'viewer', '{member}');
select permissions.define_relation('folder', 'parent');
select permissions.define_relation('folder', 'blocked');
select permissions.define_relation('folder', 'viewer', from_parent => '{viewer}', unless => '{blocked}');
select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'blocked');
select permissions.define_relation('document', 'viewer', from_parent => '{viewer}', unless => '{blocked}');

-- One verdict from all three read paths, or the disagreement. list_subjects names
-- a user only through its own tuples or a wildcard, so agree_pub also accepts '*'.
create function public.agree(p_user text, p_type text, p_id text, p_rel text)
returns text
language sql
as $$
    select case
        when c and o and s then 'allow'
        when not c and not o and not s then 'deny'
        else format('DISAGREE check_for=%s list_objects_for=%s list_subjects=%s', c, o, s)
    end
    from (select permissions.check_for('user', p_user, p_type, p_id, p_rel) c,
                 p_id = any (permissions.list_objects_for('user', p_user, p_type, p_rel)) o,
                 exists (select 1 from permissions.list_subjects(p_type, p_id, p_rel) l
                         where l.subject_type = 'user' and l.subject_id = p_user) s) x
$$;

create function public.agree_pub(p_user text, p_type text, p_id text, p_rel text)
returns text
language sql
as $$
    select case
        when c and o and s_any then 'allow'
        when not c and not o and not s_star then 'deny'
        when not c and not o and s_star then 'deny, wildcard still listed'
        else format('DISAGREE check_for=%s list_objects_for=%s list_subjects=%s/%s', c, o, s_any, s_star)
    end
    from (select permissions.check_for('user', p_user, p_type, p_id, p_rel) c,
                 p_id = any (permissions.list_objects_for('user', p_user, p_type, p_rel)) o,
                 exists (select 1 from permissions.list_subjects(p_type, p_id, p_rel) l
                         where l.subject_type = 'user' and l.subject_id in (p_user, '*')) s_any,
                 exists (select 1 from permissions.list_subjects(p_type, p_id, p_rel) l
                         where l.subject_type = 'user' and l.subject_id = '*') s_star) x
$$;

create function public.decoys(p_user text)
returns void
language sql
as $$
    select permissions.grant('team', 'decoy1', 'member', 'user', p_user);
    select permissions.grant('team', 'decoy2', 'member', 'user', p_user);
    select permissions.grant('org', 'decoy-org', 'member', 'user', p_user);
$$;

-- ---------------------------------------------------------------------------
-- 1. Exclusion in the middle of a parent chain: org o1 -> folder f1 -> document d1,
--    f1 -> subfolder sf -> d5, and org o1 -> folder f2 -> d2.
-- ---------------------------------------------------------------------------
select permissions.set_parent('folder', 'f1', 'org', 'o1');
select permissions.set_parent('folder', 'f2', 'org', 'o1');
select permissions.set_parent('folder', 'sf', 'folder', 'f1');
select permissions.set_parent('document', 'd1', 'folder', 'f1');
select permissions.set_parent('document', 'd5', 'folder', 'sf');
select permissions.set_parent('document', 'd2', 'folder', 'f2');

select public.decoys(u) from unnest(array['ub', 'uo', 'ud', 'ub2']) u;
select permissions.grant('org', 'o1', 'member', 'user', u) from unnest(array['ub', 'uo', 'ud', 'ub2']) u;
select permissions.grant('folder', 'f1', 'blocked', 'user', 'ub');     -- blocked on the folder
select permissions.grant('folder', 'f1', 'blocked', 'user', 'ud');     -- blocked on the folder ...
select permissions.grant('document', 'd1', 'viewer', 'user', 'ud');    -- ... but granted d1 directly
select permissions.grant('document', 'd2', 'blocked', 'user', 'ub2');  -- blocked on the document itself

select tap.plan(31);

select tap.is(public.agree('uo', 'document', 'd1', 'viewer'), 'allow', 'control: an org member views d1 through f1');
select tap.is(public.agree('uo', 'document', 'd2', 'viewer'), 'allow', 'control: an org member views d2 through f2');
select tap.is(public.agree('uo', 'document', 'd5', 'viewer'), 'allow', 'control: an org member views d5 through sf and f1');

select tap.is(public.agree('ub', 'document', 'd1', 'viewer'), 'deny',  'blocked on f1: d1 (one level below) is denied');
select tap.is(public.agree('ub', 'document', 'd5', 'viewer'), 'deny',  'blocked on f1: d5 (two levels below, through sf) is denied');
select tap.is(public.agree('ub', 'folder', 'f1', 'viewer'),   'deny',  'blocked on f1: f1 itself is denied');
select tap.is(public.agree('ub', 'folder', 'sf', 'viewer'),   'deny',  'blocked on f1: the subfolder sf is denied');
select tap.is(public.agree('ub', 'document', 'd2', 'viewer'), 'allow', 'blocked on f1: d2 under f2 is still allowed');
select tap.is(public.agree('ub', 'folder', 'f2', 'viewer'),   'allow', 'blocked on f1: f2 is still allowed');

select tap.is(public.agree('ud', 'document', 'd1', 'viewer'), 'allow', 'blocked on f1 but granted d1 directly: d1 is allowed');
select tap.is(public.agree('ud', 'document', 'd5', 'viewer'), 'deny',  'blocked on f1 and no direct grant: d5 is denied');
select tap.is(public.agree('ud', 'document', 'd2', 'viewer'), 'allow', 'blocked on f1: d2 is allowed');

select tap.is(public.agree('ub2', 'document', 'd2', 'viewer'), 'deny',  'blocked on the document d2: d2 is denied');
select tap.is(public.agree('ub2', 'document', 'd1', 'viewer'), 'allow', 'blocked on d2: d1 is allowed (blocks are per object)');

-- ---------------------------------------------------------------------------
-- 2. Wildcard user:* reached through a parent. org pub grants viewer to everyone:
--    pub -> folder fp -> document dp. org og gets it through a team that
--    everyone is in: og -> folder fg -> document dg. org np has no wildcard.
-- ---------------------------------------------------------------------------
select permissions.set_parent('folder', 'fp', 'org', 'pub');
select permissions.set_parent('document', 'dp', 'folder', 'fp');
select permissions.grant('org', 'pub', 'viewer', 'user', '*');

select permissions.grant('team', 'everyone', 'member', 'user', '*');
select permissions.grant('org', 'og', 'member', 'team', 'everyone', 'member');
select permissions.set_parent('folder', 'fg', 'org', 'og');
select permissions.set_parent('document', 'dg', 'folder', 'fg');

select permissions.set_parent('folder', 'fn', 'org', 'np');
select permissions.set_parent('document', 'dn', 'folder', 'fn');

select public.decoys(u) from unnest(array['us', 'ubw', 'ubg']) u;
select permissions.grant('folder', 'fp', 'blocked', 'user', 'ubw');
select permissions.grant('folder', 'fg', 'blocked', 'user', 'ubg');

select tap.is(public.agree_pub('us', 'document', 'dp', 'viewer'), 'allow', 'a stranger views dp: user:* on the org, through folder and parent');
select tap.is(public.agree_pub('us', 'document', 'dg', 'viewer'), 'allow', 'a stranger views dg: user:* in a team that is a member of the org');
select tap.is(public.agree_pub('us', 'document', 'dn', 'viewer'), 'deny',  'a stranger cannot view dn: its org has no wildcard');
select tap.is(public.agree_pub('ubw', 'document', 'dp', 'viewer'), 'deny, wildcard still listed', 'blocked on fp: the wildcard does not reach dp (user:* stays listed for everyone else)');
select tap.is(public.agree_pub('ubw', 'document', 'dg', 'viewer'), 'allow', 'blocked on fp only: dg is allowed');
select tap.is(public.agree_pub('ubg', 'document', 'dg', 'viewer'), 'deny, wildcard still listed', 'blocked on fg: the group wildcard does not reach dg');
select tap.is(public.agree_pub('ubg', 'document', 'dp', 'viewer'), 'allow', 'blocked on fg only: dp is allowed');

-- ---------------------------------------------------------------------------
-- 3. Group cycle: c1 <- c2 <- c3 <- c1 (each is a member of the previous one).
--    org o3 admits c1's members: o3 -> folder f3 -> document d3.
-- ---------------------------------------------------------------------------
select permissions.grant('team', 'c1', 'member', 'team', 'c2', 'member');
select permissions.grant('team', 'c2', 'member', 'team', 'c3', 'member');
select permissions.grant('team', 'c3', 'member', 'team', 'c1', 'member');
select permissions.grant('org', 'o3', 'member', 'team', 'c1', 'member');
select permissions.set_parent('folder', 'f3', 'org', 'o3');
select permissions.set_parent('document', 'd3', 'folder', 'f3');

select public.decoys(u) from unnest(array['x', 'xb', 'y']) u;
select permissions.grant('team', 'c3', 'member', 'user', 'x');
select permissions.grant('team', 'c2', 'member', 'user', 'xb');
select permissions.grant('folder', 'f3', 'blocked', 'user', 'xb');

select tap.is(public.agree('x', 'document', 'd3', 'viewer'), 'allow', 'a member of c3 views d3 around the cycle');
select tap.is(public.agree('x', 'team', 'c1', 'member'), 'allow', 'a member of c3 is a member of c1 (cycle terminates)');
select tap.is(public.agree('y', 'document', 'd3', 'viewer'), 'deny',  'a user outside the cycle cannot view d3 (cycle terminates)');
select tap.is(public.agree('y', 'team', 'c1', 'member'), 'deny',  'a user outside the cycle is not a member of c1');
select tap.is(public.agree('xb', 'document', 'd3', 'viewer'), 'deny',  'a member of c2 blocked on f3 cannot view d3');

-- ---------------------------------------------------------------------------
-- 4. Expired membership along the path: org o4 admits team te's members
--    (o4 -> folder f4 -> document d4).
-- ---------------------------------------------------------------------------
select permissions.grant('org', 'o4', 'member', 'team', 'te', 'member');
select permissions.set_parent('folder', 'f4', 'org', 'o4');
select permissions.set_parent('document', 'd4', 'folder', 'f4');

select public.decoys(u) from unnest(array['e', 'f', 'g']) u;
select permissions.grant('team', 'te', 'member', 'user', 'e');
select permissions.grant('team', 'te', 'member', 'user', 'f', p_expires_at => now() + interval '1 day');
select permissions.grant('team', 'te', 'member', 'user', 'g');
select permissions.grant('folder', 'f4', 'viewer', 'user', 'g');
select permissions.grant('org', 'o4', 'member', 'user', 'h', p_expires_at => now() + interval '1 day');
update permissions.tuples set expires_at = now() - interval '1 hour'
where (object_type, object_id, subject_id) in (('team', 'te', 'e'), ('team', 'te', 'g'), ('org', 'o4', 'h'));

select tap.is(public.agree('f', 'document', 'd4', 'viewer'), 'allow', 'control: an unexpired team membership reaches d4');
select tap.is(public.agree('e', 'document', 'd4', 'viewer'), 'deny',  'an expired team membership does not reach d4');
select tap.is(public.agree('e', 'team', 'te', 'member'), 'deny',  'an expired membership is not a membership');
select tap.is(public.agree('g', 'document', 'd4', 'viewer'), 'allow', 'expired membership but a live direct grant on f4: d4 is allowed');
select tap.is(public.agree('h', 'document', 'd4', 'viewer'), 'deny',  'an expired direct org membership does not reach d4');

select * from tap.finish();
