# Postgres Extensions

A few Trusted Language Extensions for database.dev.

## Developers

To publish a new version, run the following command from the root folder of this extension:

`dbdev publish`

If you have `dbdev` CLI version `0.1.3` or older, you will need to specify the path explicitly:

`dbdev publish --path .`


### TLE Commands

- List all versions (???)
- Update a version: `alter extension xxx update to NEW_VERSION`


- `select * from pgtle.available_extensions();` - get all extensions
- `select * from pgtle.available_extension_versions();` -- get all versions

## Research docs

Each extension's research records (`<extension>/research/`) are published together at https://kiwicopple.github.io/pg-extensions/. Build or preview locally with `make research.docs` or `make research.docs.dev`; see [research-site/README.md](research-site/README.md).

## Vercel documentation sites

Each extension documentation site is a separate Vercel project. Set its Root Directory to `pg_idkit`, `pg_crdt`, `pg_permissions` or `pg_validate` (the extension folder, not its `site/` subfolder). Each folder's `vercel.json` supplies the build settings and an `ignoreCommand`.

The ignore command compares the entire extension folder against `VERCEL_GIT_PREVIOUS_SHA`, the last successful deployment for that project and branch. Unchanged folders skip the build; changes anywhere within the folder trigger a build. Comparing against the previous deployment includes changes across multi-commit pushes. First deployments, missing commit history in shallow clones, and Git errors proceed with the build.

The command runs before dependency installation and needs only the shell and Git. It uses Vercel's exit-code convention: `0` skips, `1` builds. To rebuild after changing environment variables or other project settings without changing source files, use Redeploy and uncheck **Use project's Ignore Build Step**.

Keep build inputs within the project's extension folder. If a site begins consuming shared files outside that folder, add those paths to its comparison. New Vercel sites should use the same ignore command with their extension folder as Root Directory. The research site's GitHub Pages workflow already filters its source paths separately.

See Vercel's [Ignored Build Step configuration](https://vercel.com/docs/project-configuration/vercel-json#ignorecommand) and [previous deployment SHA](https://vercel.com/docs/environment-variables/system-environment-variables#vercel_git_previous_sha).
