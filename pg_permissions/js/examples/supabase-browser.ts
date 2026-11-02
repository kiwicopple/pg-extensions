// pg_permissions in a browser app with Supabase.
//
// Setup, once:
//
// 1. Add `permissions` to "Exposed schemas" in the Supabase dashboard
//    (Project Settings > API > Data API). The client calls PostgREST
//    at /rest/v1/rpc/<function> with the header
//    `Content-Profile: permissions`.
//
// 2. Create the roles and assignments on a server, with
//    createServerClient (see node-server.ts) or with SQL. Admin calls
//    never go over HTTP.
//
// 3. Use the same checks in RLS policies. From
//    pg_permissions/README.md: the policy lets a user read the
//    rows of each organization where the user has `documents.read`:
//
//    create table public.documents (
//        id     uuid primary key default gen_random_uuid(),
//        org_id uuid not null,
//        title  text not null
//    );
//    create index on public.documents (org_id);
//    alter table public.documents enable row level security;
//    grant select on public.documents to authenticated;
//
//    create policy documents_select
//        on public.documents
//        for select
//        to authenticated
//        using (
//            org_id = any (array(
//                select unnest(
//                    permissions.rbac_scopes_with_permission(
//                        permission => 'documents.read'
//                    )
//                )::uuid
//            ))
//        );

import {
  createClient as createSupabaseClient,
} from '@supabase/supabase-js'
import { createClient } from 'permissions'

declare const SUPABASE_URL: string
declare const SUPABASE_ANON_KEY: string

const supabase = createSupabaseClient(SUPABASE_URL, SUPABASE_ANON_KEY)

// Each request sends the access token of the session, so the checks
// answer for the signed-in user. Without a session, the anon key is
// sent and every check is false.
async function getAccessToken(): Promise<string | null> {
  const { data } = await supabase.auth.getSession()
  return data.session?.access_token ?? null
}

// The same URL and key as supabase-js.
const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  accessToken: getAccessToken,
})

export async function canEditDocuments(
  orgId: string,
): Promise<boolean> {
  const { data, error } = await permissions.rbac.hasPermission({
    permission: 'documents.edit',
    scope: orgId,
  })
  if (error) throw error
  return data
}

export async function canViewDocument(
  documentId: string,
): Promise<boolean> {
  // OpenFGA check for the current user (the JWT `sub`).
  const { data, error } = await permissions.fga.check({
    relation: 'viewer',
    object: `document:${documentId}`,
  })
  if (error) throw error
  return data
}

export async function visibleDocumentIds(): Promise<string[]> {
  const { data, error } = await permissions.fga.listObjects({
    type: 'document',
    relation: 'viewer',
    idsOnly: true,
  })
  if (error) throw error
  return data
}

// The RLS policy already filters the rows. The permission check is
// for the UI, for example to show an edit button.
export async function listDocuments(orgId: string) {
  const rows = supabase
    .from('documents')
    .select('id, title')
    .eq('org_id', orgId)

  const [{ data: documents, error }, canEdit] = await Promise.all([
    rows,
    canEditDocuments(orgId),
  ])
  if (error) throw error
  return { documents, canEdit }
}
