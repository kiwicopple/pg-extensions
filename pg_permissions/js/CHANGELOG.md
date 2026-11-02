# Changelog

## 0.3.0

- Adds the Cedar client: `permissions.cedar` with `isAuthorized` and `listResources`, and `cedar.admin` on a server client. The `permissions/cedar` subpath exports `CedarClient`.
- Adds `uid(type, id)`. It builds the same text as the SQL function `cedar_uid`.
- Adds the Cedar error codes. `isCedarError` and `CedarErrorReason` read a `cedar:<code>` detail, for example `cedar:invalid_uid`.
- Cedar needs `pg_permissions` 0.1.0. RBAC and OpenFGA work with 0.0.1 or 0.1.0.

## 0.2.0

- First release of the rewritten client: RBAC and OpenFGA, over SQL on a server or over PostgREST in a browser.
- Adds `currentSubjectId()` and `currentSubjectType()`.
