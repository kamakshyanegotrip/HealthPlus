import { describe, it, expect, afterEach } from 'vitest';
import { __setAnthropicClientForTesting, streamClaude, type AnthropicLike } from '../src/lib/anthropic';
import { MODELS, supportsTemperature } from '../src/lib/pricing';
import { newPendingTelemetry } from '../src/lib/types';

/**
 * HP-JOB-011 §6 — the regression test for the defect the live composer eval
 * found on its first real run.
 *
 * The API returns `400 invalid_request_error: "temperature is deprecated for
 * this model."` for Opus 5 and Sonnet 5. `anthropic.ts` sent `temperature` on
 * every call, so **every COMPOSE request died with a 400 before a token was
 * generated** — the composer could not make one successful call in production.
 *
 * WHY NOTHING CAUGHT IT, AND WHY THIS TEST IS SHAPED THE WAY IT IS. Every other
 * suite stubs the Anthropic client, and a stub accepts whatever arguments it is
 * handed — which is precisely how a request body can be wrong for a year without
 * a single test going red. So this test does not check that a call *succeeds*;
 * it captures the ARGUMENTS and asserts on the request body itself. That is the
 * only thing a mocked client can honestly tell you about a wire format.
 *
 * `streamClaude` rather than `callClaude` because it is the composer's path (the
 * broken one), and because it builds the request synchronously and returns —
 * only `finalize()` touches the database, and we never call it. So this stays a
 * pure unit test with no Postgres.
 *
 * The key must be ABSENT, not `undefined`: the assertions below use
 * `not.toHaveProperty` rather than checking for undefined, because a key present
 * with an undefined value still serialises on some SDK paths and the API refuses
 * the whole request rather than ignoring the field.
 */

function capturingClient(): { client: AnthropicLike; calls: Record<string, unknown>[] } {
  const calls: Record<string, unknown>[] = [];
  const client = {
    messages: {
      create: (async (opts: Record<string, unknown>) => {
        calls.push(opts);
        return { content: [], usage: { input_tokens: 0, output_tokens: 0 } };
      }) as unknown as AnthropicLike['messages']['create'],
      stream: ((opts: Record<string, unknown>) => {
        calls.push(opts);
        return {
          async *[Symbol.asyncIterator]() {
            /* no events needed — we assert on the request, not the response */
          },
          finalMessage: async () => ({ usage: { input_tokens: 0, output_tokens: 0 } }),
        };
      }) as unknown as AnthropicLike['messages']['stream'],
    },
  } as unknown as AnthropicLike;
  return { client, calls };
}

const ctx = { auditId: '00000000-0000-4000-8000-0000000000bb', pending: newPendingTelemetry() };

function streamWith(model: string) {
  const { client, calls } = capturingClient();
  __setAnthropicClientForTesting(client);
  streamClaude({
    meta: { ctx, purpose: 'COMPOSE', model, promptVersion: 'test' },
    system: 'sys',
    messages: [{ role: 'user', content: 'hi' }],
    maxTokens: 16,
    temperature: 0.3,
  });
  return calls[0]!;
}

afterEach(() => __setAnthropicClientForTesting(null));

describe('temperature deprecation (HP-JOB-011 §6)', () => {
  it('test_opus_5_request_omits_temperature_entirely', () => {
    // THE ONE THAT WAS BROKEN. Opus 5 is the composer's default model.
    expect(streamWith(MODELS.OPUS)).not.toHaveProperty('temperature');
  });

  it('test_sonnet_5_request_omits_temperature_entirely', () => {
    // Reached when ALLOW_OPUS_ON_LIVE_PATH=false, i.e. the configuration that
    // stays literally inside HP-ADR-001 §3.6. It was equally broken.
    expect(streamWith(MODELS.SONNET)).not.toHaveProperty('temperature');
  });

  it('test_haiku_4_5_still_sends_temperature', () => {
    // The deny-list is a narrowing, not a blanket removal. Determinism on the
    // category classifier and the red-flag propose channel is a safety property
    // worth keeping where the API still accepts it — see pricing.ts.
    expect(streamWith(MODELS.HAIKU)).toHaveProperty('temperature', 0.3);
  });

  it('test_the_rest_of_the_request_is_unchanged', () => {
    // A spread that drops one key is an easy way to drop three. Assert the
    // request is otherwise intact for the model that lost the parameter.
    const req = streamWith(MODELS.OPUS);
    expect(req).toMatchObject({ model: MODELS.OPUS, max_tokens: 16, system: 'sys' });
    expect(req.messages).toEqual([{ role: 'user', content: 'hi' }]);
  });

  it('test_supports_temperature_is_a_deny_list_not_an_allow_list', () => {
    // An unknown model must default to SENDING temperature, not withholding it.
    // Getting this backwards would silently strip determinism from every future
    // model the moment it is added, which is the failure direction that hides.
    expect(supportsTemperature('claude-some-future-model')).toBe(true);
    expect(supportsTemperature(MODELS.OPUS)).toBe(false);
    expect(supportsTemperature(MODELS.SONNET)).toBe(false);
    expect(supportsTemperature(MODELS.HAIKU)).toBe(true);
  });
});
