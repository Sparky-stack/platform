// Golden-path Node.js API (Sparky-stack/platform templates/node-fastify-service): JSON API, health and version endpoints.
// Replace the routes with your own; keep /healthz (the platform's probes and smoke tests use it).
import os from 'node:os';
import Fastify from 'fastify';

export function buildApp({
  greeting = process.env.GREETING || 'hello',
  version = process.env.APP_VERSION || 'dev',
  logger = false,
} = {}) {
  const app = Fastify({ logger });

  app.get('/', async () => ({ message: greeting, hostname: os.hostname(), version }));
  app.get('/healthz', async () => ({ status: 'ok' }));
  app.get('/version', async () => ({ version }));

  return app;
}
