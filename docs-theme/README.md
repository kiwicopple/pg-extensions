# Shared documentation theme

`theme.css` styles all five Starlight sites: `pg_permissions/site`,
`pg_validate/site`, `pg_idkit/site`, `pg_crdt/site`, and `research-site` (including every extension's research
pages). Each site's `src/styles/custom.css` imports it; keep site-specific
overrides there and shared colors, fonts, and typography here.

To update all docs, edit `theme.css` and rebuild all sites. No generated
Markdown or individual pages need changes. New Starlight sites should import
this file from their `customCss` stylesheet too.

All five sites set `pagination: false` in their Starlight configuration to remove
the previous/next navigation boxes at the bottom of pages. Use the same setting
for new sites; no page-level frontmatter or CSS override is needed.

The palette uses resolved semantic tokens measured from the live
[Supabase Docs](https://supabase.com/docs/guides/database/tables) on 2026-11-24,
including its OKLCH surfaces, foregrounds, translucent borders, primary accents,
and separate solid-button greens. The logo green alone is not the UI palette. Starlight's semantic
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
(font size, spacing, frames, and Supabase syntax themes) live in
`expressive-code.mjs`, imported by all five Astro configs. Code surface colors
remain in `theme.css` so they follow the selected light/dark mode.

Validation from the repository root:

```sh
npm --prefix pg_permissions/site run build
npm --prefix pg_validate/site run build
npm --prefix pg_idkit/site run build
npm --prefix pg_crdt/site run build
npm --prefix research-site run build
```

The research GitHub Pages workflow watches this directory. For Vercel projects
rooted at an extension directory, enable **Include source files outside of the
Root Directory in the Build Step** so the shared theme is available, and ensure
any custom ignored-build rules include `docs-theme/**`. Deploy/rebuild all sites
after a shared theme update.

## Reference audit (2026-11-24)

| Role | Dark | Light |
| --- | --- | --- |
| Page, header, sidebar | `oklch(.19 .0025 157.5)` | `oklch(.995 0 337.5)` |
| Code/card surface | `oklch(.215 .0025 157.5)` | `oklch(1 0 337.5)` |
| Heading text | `oklch(.95 .00275 157.5)` | `oklch(.1 0 337.5)` |
| Body/prose links | `oklch(.798 .00275 157.5)` | `oklch(.394455 0 337.5)` |
| Primary accent | `oklch(.76 .15 157.5)` | `oklch(.525 .12 157.5)` |
| Solid button | `oklch(.43627 .11 157.5)` | `oklch(.525 .12 157.5)` |
| Border | `oklch(.95 .001485 157.5 / .075125)` | `oklch(.1 0 337.5 / .0812725)` |

These are resolved values from Supabase's live CSS and browser computed styles,
not approximations of brand hex colors. Keep them together in `theme.css` when
refreshing against upstream. Typography also follows the observed 34px/22px
heading sizes, 15px prose, and 13px code; font weights are 450 dark / 500 light
for body text and 600 for headings. Syntax themes map Supabase's keyword,
string, comment, function, and constant colors to TextMate scopes. Tokenization
may differ between Supabase's renderer and Expressive Code. Starlight layout,
semantic callouts, and categorical chart-series colors remain purpose-specific.
