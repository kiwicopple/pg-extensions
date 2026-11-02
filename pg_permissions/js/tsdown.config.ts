import { defineConfig } from 'tsdown'

export default defineConfig([
  {
    entry: {
      index: 'src/index.ts',
      rbac: 'src/rbac/index.ts',
      fga: 'src/fga/index.ts',
      cedar: 'src/cedar/index.ts',
      sql: 'src/transport/sql.ts',
      postgrest: 'src/transport/postgrest.ts',
    },
    format: ['esm', 'cjs'],
    fixedExtension: true,
    target: 'es2017',
    platform: 'neutral',
    dts: true,
    // dist/umd is written by the second build; clean only the files of this one.
    clean: ['dist/*.mjs', 'dist/*.cjs', 'dist/*.d.mts', 'dist/*.d.cts'],
    sourcemap: false,
  },
  {
    // The CDN bundle (unpkg, jsDelivr), as supabase-js has: a minified UMD of the
    // umbrella, with the global `permissions` in a <script> tag.
    entry: { permissions: 'src/index.ts' },
    format: 'umd',
    globalName: 'permissions',
    outDir: 'dist/umd',
    // tsdown names it permissions.umd.js; keep the name of supabase-js' bundle.
    outputOptions: { entryFileNames: '[name].js' },
    target: 'es2017',
    platform: 'browser',
    minify: true,
    dts: false,
    clean: true,
    sourcemap: false,
  },
])
