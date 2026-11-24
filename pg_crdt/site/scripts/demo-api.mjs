import { Readable } from 'node:stream';
import { loadEnv } from 'vite';
import { handleCounter } from '../../demo/server.mjs';

// Astro stays static in production. Vercel serves api/counter.mjs; this
// middleware runs the same handler for `npm run docs:dev` locally.
export function demoApi() {
  return {
    name: 'crdt-counter-demo-api',
    configureServer(server) {
      const env = { ...loadEnv(server.config.mode, server.config.envDir, 'CRDT_DEMO_'), ...process.env };
      server.middlewares.use(async (req, res, next) => {
        const url = new URL(req.url, 'http://localhost');
        if (url.pathname !== '/api/counter') return next();
        try {
          const request = new Request(url, {
            method: req.method,
            headers: req.headers,
            ...(!['GET', 'HEAD'].includes(req.method) ? { body: Readable.toWeb(req), duplex: 'half' } : {}),
          });
          const response = await handleCounter(request, { env });
          res.writeHead(response.status, Object.fromEntries(response.headers));
          res.end(await response.text());
        } catch {
          res.writeHead(500, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
          res.end(JSON.stringify({ error: 'The demo request failed. Please try again.' }));
        }
      });
    },
  };
}
