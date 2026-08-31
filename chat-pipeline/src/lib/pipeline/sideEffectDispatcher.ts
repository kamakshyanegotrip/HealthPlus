import { db, DATA_REGION } from '../db';
import { sessionPseudonym } from '../pseudonymize';
import type { PipelineContext, RedFlagSeverity, ResponseCategory } from '../types';

/**
 * Side-Effect Dispatcher — fired after the response completes, WITHOUT
 * being awaited by the request handler (route.ts calls this and does not
 * `await` it, so it never adds latency to the user-visible stream close).
 *
 * Two mechanisms, deliberately not one:
 *
 * 1. A transactional enqueue into `side_effect_job`, a plain Postgres table
 *    read by a worker loop — the "Graphile Worker on the same Postgres"
 *    pattern HP-ADR-001 §3.2 chose over n8n specifically because "Postgres-
 *    backed queueing lets you insert the claim and enqueue its scoring job
 *    in one transaction ... the correct primitive when [something] must
 *    never exist unsourced." Here the something is "a review-required
 *    response must never exist without a queued review job" — so THIS half
 *    is awaited internally (it's one fast local INSERT) even though the
 *    caller doesn't await the whole function; durability comes from the
 *    row existing, not from the HTTP call succeeding.
 * 2. A best-effort HTTP ping to the always-on Fly.io worker
 *    (SIDE_EFFECT_DISPATCH_URL) for anything latency-sensitive — e.g.
 *    nudging an on-call clinician's pager for a §2.2.5b mandatory-review
 *    case sooner than the worker's normal poll interval. If this fails, the
 *    enqueued row above is still the source of truth and the worker's own
 *    poll loop picks it up regardless.
 *
 * What actually gets dispatched, mapped to Charter clauses:
 * - §2.2.5b / §2.3.5b: queue a clinician review job when required. Reviews
 *   "block and never time out" per HP-ADR-001 §2 — durable state in the
 *   transactional boundary is why this can't be HTTP-call-only.
 * - §2.1.6 / §2.2.5c: post-hoc sampled review — queue a sample-eligible job
 *   at the configured rate (rate itself is AMB-10, still open; this reads
 *   whatever rate is configured, including zero).
 * - §4.0.5: at CRITICAL/EMERGENCY, human involvement is "concurrent and
 *   post-display, never a precondition" — the notification fires after the
 *   template has already reached the user, never before or gating it.
 * - Analytics / §6.5 safety metrics: block rates, abstention rates, latency
 *   — read from obs.* tables by a separate job, not computed inline here.
 */

export interface SideEffectSummary {
  ctx: PipelineContext;
  category: ResponseCategory;
  severity: RedFlagSeverity;
  reviewRequired: boolean;
  postHocSampleEligible: boolean;
  templateRendered: boolean;
}

async function enqueueJob(kind: string, payload: Record<string, unknown>) {
  await db().query(
    `INSERT INTO side_effect_job (id, kind, payload, data_region, enqueued_at, status)
     VALUES (gen_random_uuid(), $1, $2::jsonb, $3, now(), 'PENDING')`,
    [kind, JSON.stringify(payload), DATA_REGION],
  );
}

async function pingWorker(body: Record<string, unknown>) {
  const url = process.env.SIDE_EFFECT_DISPATCH_URL;
  if (!url) return;
  try {
    await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(2000),
    });
  } catch (err) {
    // Best-effort only — the enqueued job row is the durable record.
    console.warn('sideEffectDispatcher: worker ping failed, relying on queued job', err);
  }
}

/**
 * Not awaited by the caller. Internally awaits only the durable enqueue
 * (fast, local), then fires the worker ping without blocking its own
 * caller either, so a slow/unreachable worker can never add latency
 * anywhere in the request path.
 */
export async function dispatchSideEffects(summary: SideEffectSummary): Promise<void> {
  const { ctx } = summary;

  if (summary.reviewRequired) {
    await enqueueJob('CLINICIAN_REVIEW', {
      auditId: ctx.auditId,
      sessionPseudonym: sessionPseudonym(ctx.sessionId).toString('hex'),
      category: summary.category,
      severity: summary.severity,
      reason: summary.severity !== 'NORMAL' && summary.severity !== 'MONITOR' ? 'red_flag_severity' : 'category_2_2_5b',
    });
  }

  if (summary.postHocSampleEligible) {
    await enqueueJob('POST_HOC_SAMPLE_REVIEW', { auditId: ctx.auditId, category: summary.category });
  }

  if (summary.severity === 'CRITICAL' || summary.severity === 'EMERGENCY') {
    await enqueueJob('EMERGENCY_CONCURRENT_NOTIFY', {
      auditId: ctx.auditId,
      severity: summary.severity,
      // §4.0.5: this fires AFTER the template already reached the user —
      // callers must only invoke dispatchSideEffects post-emission.
    });
  }

  // Fire-and-forget from this function's own perspective too — do not await.
  void pingWorker({ auditId: ctx.auditId, reviewRequired: summary.reviewRequired, severity: summary.severity });
}
