-- Benchmark seed, part 7 (Design D only): ListObjects on relations that are
-- not monotone (`but not`, `and`). Added in phase 5 of session 5; the first
-- workload replaces the side script designs/d/but_not_list_objects.sql.
--
-- Writes a third model (the latest): seed_conditions.sql's, with on document
--
--   define blocked: [user]
--   define muted: [user]
--   define can_view: viewer but not blocked
--   define can_view_unmuted: viewer but not (blocked or muted)
--   define can_edit: editor and viewer
--
-- `viewer` and everything the earlier phases use are unchanged. Each user is
-- blocked on one document they see through a team (the lowest-numbered one
-- shared with any of their teams) and muted on another (the highest):
-- bench.team_members and bench.team_grants, so every shape has them.
--
-- The three relations take different ListObjects paths (designs/d-per-model.md
-- section 5): can_view is the set-based difference (one subtract that is a
-- monotone relation); can_view_unmuted (a union under the subtract) and
-- can_edit (an intersection) were checked candidate by candidate before
-- phase 5.

\set ON_ERROR_STOP 1

select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user"}, {"type": "team", "relation": "member"}]}}}},
    {"type": "cteam", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [
       {"type": "user", "condition": "active"}, {"type": "cteam", "relation": "member", "condition": "active"}]}}}},
    {"type": "folder", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "document",
     "relations": {
       "parent": {"this": {}},
       "editor": {"this": {}},
       "viewer": {"union": {"child": [
         {"this": {}},
         {"computedUserset": {"relation": "editor"}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}},
       "cviewer": {"union": {"child": [
         {"this": {}},
         {"computedUserset": {"relation": "editor"}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}},
       "blocked": {"this": {}},
       "muted": {"this": {}},
       "can_view": {"difference": {
         "base": {"computedUserset": {"relation": "viewer"}},
         "subtract": {"computedUserset": {"relation": "blocked"}}}},
       "can_view_unmuted": {"difference": {
         "base": {"computedUserset": {"relation": "viewer"}},
         "subtract": {"union": {"child": [
           {"computedUserset": {"relation": "blocked"}},
           {"computedUserset": {"relation": "muted"}}]}}}},
       "can_edit": {"intersection": {"child": [
         {"computedUserset": {"relation": "editor"}},
         {"computedUserset": {"relation": "viewer"}}]}}},
     "metadata": {"relations": {
       "parent": {"directly_related_user_types": [{"type": "folder"}]},
       "editor": {"directly_related_user_types": [{"type": "user"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]},
       "cviewer": {"directly_related_user_types": [{"type": "user"}, {"type": "cteam", "relation": "member", "condition": "active"}]},
       "blocked": {"directly_related_user_types": [{"type": "user"}]},
       "muted": {"directly_related_user_types": [{"type": "user"}]}}}}
  ],
  "conditions": {
    "active": {"name": "active",
      "expression": "expires > timestamp(\"2000-01-01T00:00:00Z\")",
      "parameters": {"expires": {"type_name": "TYPE_NAME_TIMESTAMP"}}}}
}$m$::jsonb) is not null as model_written;

select permissions.fga_write(jsonb_build_object('tuple_keys', keys))
from (
    select jsonb_agg(jsonb_build_object('user', 'user:' || md5('user' || u)::uuid, 'relation', r,
                                        'object', 'document:' || md5('doc' || doc)::uuid)) as keys
    from (
        select u, r, doc, (row_number() over () - 1) / 100 as chunk   -- the Write cap (seed_sharing.sql)
        from (
            select m.u, 'blocked' as r, min(g.doc) as doc
            from bench.team_members m join bench.team_grants g on g.team = m.team
            group by m.u
          union all
            select m.u, 'muted', max(g.doc)
            from bench.team_members m join bench.team_grants g on g.team = m.team
            group by m.u
            having max(g.doc) <> min(g.doc)
        ) t
    ) c
    group by chunk
) w;
