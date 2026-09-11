import { mergeConfig, defineConfig } from 'vitest/config';
import base from './vitest.config';

/**
 * J11-9, the other half. `"test:integration": "RUN_PIPELINE_INTEGRATION=1
 * vitest run ..."` had the same POSIX-only shape and predates HP-JOB-011, so
 * this suite has never been runnable via npm on Windows either.
 *
 * Only the opt-in FLAG is set here. DATABASE_URL, DATABASE_URL_REASONER,
 * DATABASE_URL_REDFLAG, SEED_DATABASE_URL, DATA_REGION and
 * SUBJECT_KEY_WRAPPING_KEY stay in the environment where they belong — they are
 * connection strings and key material, and a config file checked into git is
 * the wrong home for either.
 */
export default mergeConfig(
  base,
  defineConfig({
    test: {
      env: { RUN_PIPELINE_INTEGRATION: '1' },
    },
  }),
);
