import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const COMPOSE_FILE = fileURLToPath(new URL('../docker-compose.yml', import.meta.url))

/**
 * Starts test/docker-compose.yml (Postgres 17 + pg_permissions + PostgREST) and
 * waits until both are healthy. The stack stays up after the run, so the next
 * run is fast; `pnpm db:down` removes it. Set PERMISSIONS_TEST_DOWN=1 to stop it
 * after the run.
 */
export default function setup(): () => void {
  const docker = spawnSync('docker', ['version', '--format', '{{.Server.Version}}'], { encoding: 'utf8' })
  if (docker.error || docker.status !== 0) {
    throw new Error(
      'The integration tests need Docker with the compose plugin, and a running Docker daemon.\n' +
        (docker.error ? String(docker.error) : docker.stderr),
    )
  }
  const up = spawnSync('docker', ['compose', '-f', COMPOSE_FILE, 'up', '-d', '--wait'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  if (up.status !== 0) {
    throw new Error(`docker compose up failed (exit ${up.status}):\n${up.stderr}\n${up.stdout}`)
  }
  return () => {
    if (process.env.PERMISSIONS_TEST_DOWN === '1') {
      spawnSync('docker', ['compose', '-f', COMPOSE_FILE, 'down', '-v'], { stdio: 'inherit' })
    }
  }
}
