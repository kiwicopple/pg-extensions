-- Benchmark seed, part 8 (design E only): one select policy that calls
-- cedar_is_authorized_current on every row, with the row's org as a resource
-- attribute. Loaded last; it replaces both select policies. The visible sets
-- must equal the parents phase's (bench/run.sh compares them in the run).
--
--   org_readers: permit (principal, action == Action::"read", resource is Document)
--                when { principal in resource.readers };
-- with resource_attrs => {"readers": Role::"<org_id>/viewer"} from the row:
-- the members of any role of the org (admin in editor in viewer) may read.
-- Shares and folder viewers come from the stored links and parents, as
-- before. Every row is in a permit's scope (resource is Document), so every
-- row runs the full per-row check: this is the worst case of the per-row
-- path, not the recommended policy for a list view.

\set ON_ERROR_STOP 1

select permissions.cedar_put_policy(policy_id => 'org_readers',
    policy => 'permit (principal, action == Action::"read", resource is Document) when { principal in resource.readers };');

drop policy documents_select on public.documents;
drop policy documents_select_cedar on public.documents;
create policy documents_select_row on public.documents for select to authenticated using (
    permissions.cedar_is_authorized_current('Action::"read"', 'Document::"' || id || '"',
        resource_attrs => jsonb_build_object('readers', jsonb_build_object('__entity',
                              jsonb_build_object('type', 'Role', 'id', org_id || '/viewer')))));
