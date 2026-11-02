import { createHmac } from 'node:crypto'

const b64url = (input: string | Buffer) => Buffer.from(input).toString('base64url')

/** Signs an HS256 JWT. For tests only. */
export function signJwt(payload: Record<string, unknown>, secret: string, expiresInSeconds = 3600): string {
  const now = Math.floor(Date.now() / 1000)
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
  const body = b64url(JSON.stringify({ iat: now, exp: now + expiresInSeconds, ...payload }))
  const signature = createHmac('sha256', secret).update(`${header}.${body}`).digest('base64url')
  return `${header}.${body}.${signature}`
}
