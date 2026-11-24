# Shared documentation theme

`theme.css` styles all three Starlight sites: `pg_permissions/site`,
`pg_validate/site`, and `research-site` (including every extension's research
pages). Each site's `src/styles/custom.css` imports it; keep site-specific
overrides there and shared colors, fonts, and typography here.

To update all docs, edit `theme.css` and rebuild the three sites. No generated
Markdown or individual pages need changes. New Starlight sites should import
this file from their `customCss` stylesheet too.

The palette uses [Supabase green and neutral surfaces](https://supabase.com/brand),
with a darker accessible green for links in light mode. Starlight's semantic
warning/error colors and the research charts' categorical colors are preserved.
The font families match Supabase: Manrope for headings, Inter for body/UI, and
Source Code Pro for code. Manrope is sourced from
[Google Fonts](https://github.com/google/fonts/tree/main/ofl/manrope), with its
SIL Open Font License in `fonts/Manrope-LICENSE.txt`.

Inter is self-hosted, bundled by Vite with base-aware asset URLs, and uses
`font-display: swap`. Its variable font and SIL Open Font License come from
[rsms/inter](https://github.com/rsms/inter); keep `fonts/Inter-LICENSE.txt` when
updating the font. Code uses self-hosted [Source Code Pro](https://github.com/adobe-fonts/source-code-pro),
with its license in `fonts/SourceCodePro-LICENSE.md`. Shared code-block settings
(font size, spacing, frames, and GitHub syntax themes) live in
`expressive-code.mjs`, imported by all three Astro configs. Code surface colors
remain in `theme.css` so they follow the selected light/dark mode.

Validation from the repository root:

```sh
npm --prefix pg_permissions/site run build
npm --prefix pg_validate/site run build
npm --prefix research-site run build
```

The research GitHub Pages workflow watches this directory. For Vercel projects
rooted at an extension directory, enable **Include source files outside of the
Root Directory in the Build Step** so the shared theme is available, and ensure
any custom ignored-build rules include `docs-theme/**`. Deploy/rebuild all sites
after a shared theme update.
