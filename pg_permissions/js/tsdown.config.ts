import { defineConfig } from 'tsdown'

export default defineConfig({
  entry: {
    index: 'src/index.ts',
    rbac: 'src/rbac/index.ts',
    fga: 'src/fga/index.ts',
    sql: 'src/transport/sql.ts',
    postgrest: 'src/transport/postgrest.ts',
  },
  format: ['esm', 'cjs'],
  fixedExtension: true,
  target: 'es2017',
  platform: 'neutral',
  dts: true,
  clean: true,
  sourcemap: false,
})
