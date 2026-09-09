import type { PipelineContext, RedFlagSeverity, ResponseCategory } from '../types';

/**
 * Side-Effect Dispatcher — fired after the response completes, WITHOUT being
 * awaited by the request handler (route.ts calls this and does not `await` it,
 * so it never adds latency to the user-visible stream close).
 *
 * ===========================================================================
 * THE TABLE THIS USED TO WRITE DOES NOT EXIST
 *
 * Until now this enqueued into `side_effect_job`, and the query contract has
 * carried five baselined failures against it — one here, four in the worker —
 * all saying `relation "side_effect_job" does not exist`. It is a STUB
 * INVENTION: it exists only in chat-pipeline/db/010, which R10g deletes. The
 * real schema's counterpart is obs.review_queue_item, and that is a better
 * table in every respect — FKs to principal.clinician and safety.clinical_domain,
 * a c_no_implicit_approval CHECK, and trg_queue_claim_in_scope enforcing §2.3.4c
 * (a clinician may not claim a review outside their registered domain).
 *
 * AND THE REROUTE CANNOT BE MADE TODAY. obs.review_queue_item.clinical_domain is
 * NOT NULL with an FK to safety.clinical_domain(code), and nothing in the request
 * path produces a clinical domain. Classifying one is R10b, parked by decision:
 * it decides WHO IS COMPETENT TO REVIEW WHAT, which is the clinical lead's call
 * and not an engineering one. safety.clinical_domain does carry a GENERAL code,
 * and using it would be worse than not writing at all — GENERAL means "not on
 * the Elevated-Risk Topic List", a clinical claim we cannot make, and
 * trg_queue_claim_in_scope reads the domain to decide who may claim the review.
 * A wrong GENERAL would let an out-of-scope clinician review an elevated-risk
 * response, which is the precise thing §2.3.4c exists to prevent.
 *
 * ===========================================================================
 * SO WHERE IS THE OBLIGATION RECORDED? IN THE AUDIT ROW, AND IT ALREADY IS.
 *
 * Decided 9 September. upsertResponseAudit runs BEFORE this function on every
 * exit point and writes obs.response_audit.review_state = 'PENDING' whenever
 * review is required. That row is durable, region-stamped, constraint-checked,
 * and is what a reviewer console would read from anyway — the queue table was
 * only ever an index over it. Nothing is lost by not writing a second record;
 * what is lost is the WORK ITEM, and that is honest, because there is no
 * reviewer console to work it.
 *
 * The old enqueue did not change that. Its consumer — worker/side-effect-worker.mjs,
 * deleted in the same commit — had three handlers, and all three were
 * `console.log('would ...')`. A response that needed review produced a queue row
 * that a worker claimed, logged about, and marked DONE. That is not a review
 * path; it is a review path's shape.
 *
 * EVERY SKIPPED DISPATCH IS LOGGED AT ERROR LEVEL with its audit id, so the
 * gap is visible in the place operators actually look, and countable. §6.5's
 * metrics read obs.response_audit directly and are unaffected.
 *
 * ===========================================================================
 * AND THE EMERGENCY NOTIFY IS NOT SKIPPED — IT WAS ALWAYS REDUNDANT
 *
 * The third enqueue was EMERGENCY_CONCURRENT_NOTIFY. Against the real schema
 * that path is already covered without it: inserting a CRITICAL/EMERGENCY
 * safety.red_flag_event fires trg_event_requires_alert, which calls
 * safety.raise_alert and creates the clinician_alert row itself, and
 * worker/alert-worker.mjs delivers it or records it UNDELIVERABLE (RF6,
 * migration 029). migrations/test/rf6_alert_delivery.sh asserts the alert
 * exists BEFORE the worker runs — "raised by the trigger" — so the database,
 * not this function, is what guarantees §4.0.5's concurrent notification.
 *
 * Dropping it here removes a duplicate, not a control. The handler that used to
 * receive it said so itself: "SUPERSEDED BY RF6 ... notification is no longer
 * this worker's business."
 */

export interface SideEffectSummary {
  ctx: PipelineContext;
  category: ResponseCategory;
  severity: RedFlagSeverity;
  reviewRequired: boolean;
  postHocSampleEligible: boolean;
  templateRendered: boolean;
}

/**
 * Best-effort HTTP nudge to the always-on worker for anything worth acting on
 * sooner than a poll interval. Unchanged in shape and now the ONLY outbound
 * side effect — so its body is the whole message, and a consumer must read
 * obs.response_audit for the detail rather than a queue row that no longer
 * exists. Never awaited by the caller, 2s timeout, failure is a warning: there
 * is no longer a durable queue row behind it, and the audit row it points at is
 * already written by the time this runs.
 */
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
    console.warn('sideEffectDispatcher: worker ping failed; obs.response_audit is the record', err);
  }
}

export async function dispatchSideEffects(summary: SideEffectSummary): Promise<void> {
  const { ctx } = summary;

  if (summary.reviewRequired) {
    // §2.2.5b / §2.3.5b. The obligation is recorded — obs.response_audit.review_state
    // is 'PENDING' for this audit id, written before this ran. What does not exist
    // is anything that will pick it up.
    console.error(
      'REVIEW REQUIRED AND NOT QUEUED: obs.response_audit.review_state=PENDING is the ' +
        'only record. obs.review_queue_item needs a clinical_domain and R10b (response ' +
        'domain classification) is parked — see this module\'s header.',
      {
        auditId: ctx.auditId,
        category: summary.category,
        severity: summary.severity,
        reason:
          summary.severity !== 'NORMAL' && summary.severity !== 'MONITOR'
            ? 'red_flag_severity'
            : 'category_2_2_5b',
      },
    );
  }

  if (summary.postHocSampleEligible) {
    // §2.1.6 / §2.2.5c. Sampling has no destination either, and its RATE is
    // still AMB-10 — unanswered — so nothing downstream is waiting on this.
    console.error('POST-HOC SAMPLE ELIGIBLE AND NOT QUEUED (AMB-10 rate is unset; no sampling sink exists)', {
      auditId: ctx.auditId,
      category: summary.category,
    });
  }

  // NO EMERGENCY BRANCH. See the header: safety.raise_alert already fired from
  // trg_event_requires_alert when recordRedFlagEvent wrote the event, and
  // alert-worker.mjs owns delivery. Adding one here would be a second, weaker
  // copy of a control the database already enforces.

  void pingWorker({
    auditId: ctx.auditId,
    reviewRequired: summary.reviewRequired,
    severity: summary.severity,
  });
}
