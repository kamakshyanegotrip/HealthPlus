import { defineConfig } from 'vitest/config';
import path from 'node:path';

// route.ts and everything it imports use the `@/*` path alias (see
// tsconfig.json). vitest/esbuild doesn't read tsconfig `paths` on its own,
// so without this, importing route.ts in a test (test/runPipeline.
// integration.test.ts) fails to resolve every `@/lib/...` import inside it.
// The existing unit tests never hit this because they only import via
// relative paths — this file exists specifically for that integration test.
export default defineConfig({
  test: {
    environment: 'node',
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
});
