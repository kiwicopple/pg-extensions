import { defineConfig } from 'vitest/config'

// Needs Docker. global-setup.ts starts test/docker-compose.yml (Postgres 17 with
// pg_permissions + PostgREST) and leaves it running; `pnpm db:down` stops it.
export default defineConfig({
  test: {
    include: ['test/integration/**/*.test.ts'],
    globalSetup: ['test/integration/global-setup.ts'],
    // One shared database: files must not run in parallel.
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 120_000,
  },
})
