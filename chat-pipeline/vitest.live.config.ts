import { mergeConfig, defineConfig } from 'vitest/config';
import base from './vitest.config';

/**
 * J11-9 — the opt-in flag, set somewhere cmd.exe can reach.
 *
 * `"eval:composer": "RUN_LIVE_COMPOSER_EVAL=1 vitest run ..."` is POSIX
 * env-prefix syntax. npm runs scripts through cmd.exe on Windows, which parses
 * that as a command named `RUN_LIVE_COMPOSER_EVAL=1` and fails with "is not
 * recognized as an internal or external command." The script had therefore
 * NEVER WORKED on the machine this project is actually developed on — and
 * neither had `test:integration`, which predates HP-JOB-011 and has the same
 * shape. Found by running it on Windows, not by reading it.
 *
 * Fixed with a config rather than `cross-env` deliberately: ADR-002's zero-cost
 * ladder and this repo's general posture argue against adding a dependency to
 * solve a syntax problem, and `test.env` is a first-class vitest feature that
 * costs nothing and works identically on both platforms.
 *
 * The var is still readable from the shell too — setting it by hand and calling
 * `npx vitest run` directly remains valid, which is how the first live runs were
 * done.
 */
export default mergeConfig(
  base,
  defineConfig({
    test: {
      env: { RUN_LIVE_COMPOSER_EVAL: '1' },
    },
  }),
);
