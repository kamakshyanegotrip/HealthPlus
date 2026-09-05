import { defineConfig } from 'vitest/config';

/**
 * Root package test scope.
 *
 * Without this, `vitest run` at the repo root walks the whole tree and picks up
 * chat-pipeline/test/*.test.ts as well — which then fail to resolve, because
 * those tests use the `@/` alias that only chat-pipeline's own vitest config
 * defines. Three suites failed that way for no reason other than scope, which
 * is very likely why nothing ever ran this package's tests in CI (register item
 * CI-1), and why B6's thirty clause-named emission-validator tests sat
 * unverified while being cited as closed.
 *
 * chat-pipeline is a separate package with its own config, its own tsconfig
 * paths and its own CI job. It is excluded here rather than aliased, so there
 * is exactly one place each suite runs.
 */
export default defineConfig({
  test: {
    include: ['src/**/*.test.ts'],
    exclude: ['**/node_modules/**', 'chat-pipeline/**'],
  },
});
