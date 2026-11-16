// Entry point: serves the API on $PORT (default 8080) and shuts down gracefully on SIGTERM/SIGINT.
import { buildApp } from './app.js';

const app = buildApp({ logger: true });
const port = Number.parseInt(process.env.PORT || '8080', 10);

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.once(signal, async () => {
    app.log.info({ signal }, 'shutting down');
    await app.close();
    process.exit(0);
  });
}

try {
  // 0.0.0.0: the container's only interface is the pod network.
  await app.listen({ host: '0.0.0.0', port });
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
