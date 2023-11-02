# Countries

This extension creates a table named `countries` which contains the countries of the world. The countries table contains the following columns:

- `name` - full country name.
- `local_name` - local variation of the name.
- `iso2` - ISO 3166-1 alpha-2 code.
- `iso3` - ISO 3166-1 alpha-3 code.
- `continent` - continent of the country.

## Developers

To publish a new version, run the following command from the root folder of this extension:

`dbdev publish`

If you have `dbdev` CLI version `0.1.3` or older, you will need to specify the path explicitly:

`dbdev publish --path .`
