/**
 * HealthPlus — shared Anthropic client.
 *
 * ADR-001 §3.6: Claude, tiered by job, behind a thin provider adapter. This
 * is that adapter's construction point — one client, imported everywhere a
 * job needs to call the model, so the residency escape hatch (Bedrock's EU
 * inference profile) is a one-file change later rather than a grep-and-edit.
 *
 * ADR-001 §3.6 also flags three constraints every caller must respect:
 *   - The Batch API is excluded from Anthropic's BAA — do not route anything
 *     that could carry user health data through it.
 *   - Fable 5 / Mythos 5 mandate 30-day retention and are ZDR-ineligible —
 *     never select them for a user- or patient-data path.
 *   - Rate limits are currently uniform across tiers; what the tiers gate is
 *     the monthly spend cap. Plan for spend, not throughput.
 */
import Anthropic from '@anthropic-ai/sdk';

export const anthropic = new Anthropic({
  apiKey: process.env.ANTHROPIC_API_KEY,
});

/**
 * ADR-001 §3.6: "Opus 5 ($5/$25) for offline claim extraction and conflict
 * resolution." This is an offline, non-user-facing job (Open Items Register
 * Build Queue #4), so it is the Opus tier, not Haiku or Sonnet.
 *
 * The exact API model identifier changes as Anthropic ships new snapshots.
 * Confirm the current Opus 5 model string against Anthropic's model list
 * (https://docs.claude.com/en/docs/about-claude/models) before deploying,
 * and prefer overriding via env rather than hard-coding a string that will
 * silently go stale.
 */
export const ANTHROPIC_MODEL_CLAIM_EXTRACTION =
  process.env.ANTHROPIC_MODEL_CLAIM_EXTRACTION ?? 'claude-opus-4-5';
