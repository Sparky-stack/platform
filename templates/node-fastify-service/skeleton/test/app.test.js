import { afterAll, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';

describe('api', () => {
  const app = buildApp({ greeting: 'tere', version: 'abc1234' });
  afterAll(() => app.close());

  it('GET / returns the greeting', async () => {
    const res = await app.inject({ method: 'GET', url: '/' });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.message).toBe('tere');
    expect(body.version).toBe('abc1234');
    expect(body.hostname).toBeTruthy();
  });

  it('GET /healthz is ok', async () => {
    const res = await app.inject({ method: 'GET', url: '/healthz' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ status: 'ok' });
  });

  it('GET /version returns the version', async () => {
    const res = await app.inject({ method: 'GET', url: '/version' });
    expect(res.json()).toEqual({ version: 'abc1234' });
  });

  it('unknown routes are 404', async () => {
    const res = await app.inject({ method: 'GET', url: '/nope' });
    expect(res.statusCode).toBe(404);
  });
});

describe('defaults', () => {
  it('reads GREETING from the environment', async () => {
    process.env.GREETING = 'hei';
    const app = buildApp();
    const res = await app.inject({ method: 'GET', url: '/' });
    expect(res.json().message).toBe('hei');
    expect(res.json().version).toBe(process.env.APP_VERSION || 'dev');
    await app.close();
    delete process.env.GREETING;
  });
});
