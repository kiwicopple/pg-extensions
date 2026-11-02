-- Roles and grants for the integration tests, as in Supabase. Runs after
-- pg_permissions--0.1.0.sql (see docker-compose.yml).

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role authenticator login password 'authenticator' noinherit;
grant anon, authenticated, service_role to authenticator;

grant usage on schema permissions to anon, authenticated, service_role;

-- The admin functions, for the trusted backend role. From
-- docs/reference.md#privileges and docs/fga.md#privileges. fga_delete_store()
-- stays with the owner, as the docs advise.
grant execute on function
    permissions.rbac_create_role(text, text[], text[]),
    permissions.rbac_drop_role(text),
    permissions.rbac_assign_role(text, text, text),
    permissions.rbac_unassign_role(text, text, text),
    permissions.rbac_user_permissions(text, text),
    permissions.rbac_users_with_role(text, text),
    permissions.delete_subject(text, text)
to service_role;

grant execute on function
    permissions.fga_write_authorization_model(jsonb),
    permissions.fga_read_authorization_model(text),
    permissions.fga_read_authorization_models(),
    permissions.fga_write(jsonb, jsonb, text),
    permissions.fga_write_tuple(text, text, text),
    permissions.fga_delete_tuple(text, text, text),
    permissions.fga_read(text, text, text, integer, text),
    permissions.fga_check(text, text, text, jsonb, text, jsonb),
    permissions.fga_list_objects(text, text, text, jsonb, text, jsonb),
    permissions.fga_list_users(text, text, text[], jsonb, text, jsonb)
to service_role;
