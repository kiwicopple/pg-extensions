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