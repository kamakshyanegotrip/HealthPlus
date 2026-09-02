import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { PipelineContext, ResponseCategory, RetrievedClaim } from '@/lib/types';
import { requireAuth, AuthError } from '@/lib/auth';
import { classifyIntentComplexity } from '@/lib/pipeline/intentComplexity';
import { classifyCategory, reconcileAfterRetrieval } from '@/lib/pipeline/categoryClassifier';
import { CLINICAL_DECISION_REFUSAL } from '@/lib/prompts/annexB';
import { scanRedFlags, loadSafetyTemplate, recordRedFlagEvent, deriveActionTaken, getSessionFloor, applySessionFloor, resolveTemplateRequirement } from '@/lib/pipeline/redFlagEngine';
import { lookupPatientProfile } from '@/lib/pipeline/patientProfile';
import { lookupKnowledge, flattenClaims } from '@/lib/pipeline/knowledgeLookup';
import { buildReasoningBrief } from '@/lib/pipeline/clinicalReasoning';
import { beginSynthesis } from '@/lib/pipeline/synthesis';
import { validateStream } from '@/lib/pipeline/emissionValidator';
import { recordAuditEvent, upsertResponseAudit, persistResponseContent } from '@/lib/pipeline/auditLog';
import { dispatchSideEffects } from '@/lib/pipeline/sideEffectDispatcher';
import { SEVERITY_ORDER } from '@/lib/types';

export const runtime = 'nodejs'; // needs pg + node:crypto; not the edge runtime
export const maxDuration = 800; // Vercel Pro ceiling, HP-ADR-001 §3.4 — this route stays well under it

const RequestSchema = z.object({
  sessionId: z.string().uuid(),
  message: z.string().min(1).max(4000),
});

/**
 * One chat turn, end to end, streamed over SSE.
 *
 * Pipeline order (per spec, with the two additions the Charter requires):
 * intent+complexity -> RESPONSE_CATEGORY (persisted before generation,
 * §2.0.1/§2.0.4) -> if CLINICAL_DECISION: short-circuit to §2.3.6 refusal
 * (structurally required — Category C is DB-disabled, DR-001) -> red-flag
 * scan (ALWAYS runs, §4.0.1, independent of category) -> if
 * CRITICAL/EMERGENCY: short-circuit to §4.0.5 static template (wins over
 * everything, including the CLINICAL_DECISION refusal path — an emergency
 * inside a clinical-decision-shaped message still needs the emergency
 * banner) -> patient profile lookup -> parallel knowledge lookup -> clinical
 * reasoning (population-level only) -> synthesis (streamed) -> emission
 * validator (sentence-by-sentence, §3.0.3) -> audit persistence -> fire
 * side-effect dispatch WITHOUT awaiting it.
 *
 * Auth: verifies the caller's JWT against HP-SEC-001's Supabase custom
 * claims (src/lib/auth.ts) — signature, expiry, and a recognized
 * `user_role` are all checked before anything else runs. Only `patient` may
 * call this route: `patientProfile.lookupPatientProfile` reads the caller's
 * own profile by `userId`, and RLS's patient-visibility policy (HP-SEC-001
 * §4) is scoped to a patient reading their own row — a clinician or
 * hospital_admin token authenticating successfully here would still hit an
 * RLS wall downstream, so this checks the role up front instead of letting
 * that surface as a confusing empty-profile response three steps in.
 */
export async function POST(req: Request): Promise<Response> {
  // §6.5: "latency measured from first byte of the INBOUND message, not
  // scanner start." Captured as the very first statement in the handler —
  // see PipelineContext.receivedAt's doc comment for the caveat that this is
  // an application-layer approximation, not a transport-layer timestamp.
  const firstByteAt = new Date();
  const auditId = randomUUID();

  let auth;
  try {
    auth = await requireAuth(req);
  } catch (err) {
    const status = err instanceof AuthError ? err.status : 401;
    return Response.json({ error: err instanceof Error ? err.message : 'unauthenticated' }, { status });
  }
  if (auth.userRole !== 'patient') {
    return Response.json({ error: 'this endpoint is patient-facing only' }, { status: 403 });
  }

  const body = await req.json().catch(() => null);
  const parsed = RequestSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: 'invalid request', details: parsed.error.flatten() }, { status: 400 });
  }

  const ctx: PipelineContext = {
    sessionId: parsed.data.sessionId,
    userId: auth.userId,
    message: parsed.data.message,
    dataRegion: auth.dataRegion ?? process.env.DATA_REGION ?? 'IN',
    auditId,
    receivedAt: firstByteAt.toISOString(),
    authClaims: {
      sub: auth.userId,
      user_role: auth.userRole,
      hospital_id: auth.hospitalId,
      admin_scopes: auth.adminScopes,
    },
  };

  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (event: string, data: unknown) => {
        controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
      };

      try {
        await runPipeline(ctx, send);
      } catch (err) {
        console.error('pipeline error', { auditId, err });
        send('error', { message: 'Something went wrong generating this response. Please try again.' });
      } finally {
        send('done', { auditId });
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no', // disable proxy buffering so SSE actually streams
    },
  });
}

/**
 * GAP RESOLVED (Turn 5 punch list — "orchestration layer never actually
 * run/tested end-to-end"): exported (was module-private) specifically so
 * test/runPipeline.integration.test.ts can drive it directly against a real
 * local Postgres with a mocked Anthropic client (see anthropic.ts's
 * __setAnthropicClientForTesting), asserting the SSE event sequence and the
 * branching behaviour (emergency short-circuit vs CLINICAL_DECISION refusal
 * vs the normal path, §2.0.2 post-retrieval reconciliation) rather than only
 * type-checking. `POST` above still does the real request→SSE plumbing
 * (auth, body parsing, ReadableStream/ Response); this function is the part
 * that's actually testable without a running HTTP server.
 */
export async function runPipeline(ctx: PipelineContext, send: (event: string, data: unknown) => void) {
  // ---- 1. Intent + complexity classifier (Haiku) --------------------------
  const intent = await classifyIntentComplexity(ctx);
  send('intent', { intent: intent.intent, complexity: intent.complexity });

  // ---- 2. RESPONSE_CATEGORY classifier (Haiku), persisted before generation
  const classification = await classifyCategory(ctx);
  await recordAuditEvent(ctx, 'CATEGORY_ASSIGNED', 'system', {
    category: classification.category,
    classifier_version: classification.classifierVersion,
    confidence: classification.confidence,
    ambiguous: classification.ambiguous,
    inputs_digest: classification.inputsDigest,
  });
  send('category', { category: classification.category });

  // ---- 3. Safety / red-flag engine — ALWAYS runs, independent of category -
  const redFlag = await scanRedFlags(ctx);

  // §4.0.8: apply the session's sticky severity floor BEFORE any
  // severity-based branching below — a session already sitting at WARNING+
  // stays at least there even if this one message, read alone, looks
  // ordinary. Must run before the SEVERITY_ASSIGNED audit event too, since
  // that event should record what severity was actually assigned to this
  // turn, not what the message alone would have produced.
  const sessionFloor = await getSessionFloor(ctx);
  const flooredSeverity = applySessionFloor(redFlag.severity, sessionFloor);
  const sessionFloorApplied = flooredSeverity !== redFlag.severity;
  if (sessionFloorApplied) {
    // BUG FOUND RUNNING test_session_severity_floor_sticks_across_turns
    // (§4.0.8 integration test): bumping redFlag.severity here without also
    // re-deriving templateId/templateVersion left turn 2 with the *original*
    // (pre-floor) template resolution — null, since a NORMAL-severity scan
    // needs no template — while the floored severity was URGENT. That
    // combination hard-fails safety.red_flag_event's own
    // c_urgent_needs_template CHECK downstream in recordRedFlagEvent. This is
    // exactly the composition scanRedFlags itself already performs for a
    // model-side raise (clampSeverity then resolveTemplateRequirement, see
    // its own header comment and the
    // test_hp_esc_4_0_2_model_raised_severity_past_warning_with_no_rule_template_still_gets_one
    // unit test) — a session-floor raise needs the identical treatment.
    const { templateId, templateVersion } = resolveTemplateRequirement(flooredSeverity, redFlag.templateId, redFlag.templateVersion);
    redFlag.templateId = templateId;
    redFlag.templateVersion = templateVersion;
    redFlag.triggerDetail = { ...redFlag.triggerDetail, sessionFloorApplied: true, sessionFloorSeverity: flooredSeverity };
    redFlag.severity = flooredSeverity;
  }

  await recordAuditEvent(ctx, 'SEVERITY_ASSIGNED', 'system', {
    severity: redFlag.severity,
    rule_id: redFlag.ruleId,
    rule_version: redFlag.ruleVersion,
    rule_set_id: redFlag.ruleSetId,
    proposed_by_model: redFlag.proposedSeverityByModel,
    session_floor_applied: sessionFloorApplied,
  });
  send('severity', { severity: redFlag.severity });

  // §4.0.5 — this wins over everything, including a CLINICAL_DECISION
  // classification. Static template, model does not touch the wording,
  // rendered immediately, no gating on review.
  if (SEVERITY_ORDER[redFlag.severity] >= SEVERITY_ORDER['CRITICAL']) {
    const templateText = await loadSafetyTemplate(redFlag.templateId!);
    await recordAuditEvent(ctx, 'TEMPLATE_RENDERED', 'system', { template_id: redFlag.templateId, template_version: redFlag.templateVersion });
    send('sentence', { text: templateText, citedClaimIds: [] });
    const templateDisplayedAt = new Date();
    // BUG FIXED (found by test/runPipeline.integration.test.ts running this
    // for real against Postgres, not by review — same lesson HP-SEC-001 §5
    // already logged once for this codebase): response_content.audit_id is
    // a real FK into response_audit(id) (db/000's stub schema), but
    // persistResponseContent used to run BEFORE upsertResponseAudit in every
    // one of these branches. Every insert here would have thrown a foreign
    // key violation the first time this route actually ran end to end —
    // masked entirely by scripts/smoke-test.mjs, which only ever exercised
    // each statement in isolation with its own hand-picked ordering. Fixed
    // by upserting the audit row (the FK target) first in all four exit
    // points, then persisting the content and the red-flag event.
    await upsertResponseAudit({
      ctx,
      category: 'INFORMATIONAL', // the emergency banner itself is not a clinical determination
      classifierVersion: classification.classifierVersion,
      severity: redFlag.severity,
      ruleId: redFlag.ruleId,
      templateId: redFlag.templateId,
      aggConfidence: 1.0, // a static, clinician-authored template carries no model uncertainty
      modelVersion: 'n/a-static-template',
      promptVersion: 'n/a-static-template',
      citedClaimIds: [],
      reviewRequired: true, // §4.0.5: review is concurrent/post-display, not a precondition — still required
    });
    await persistResponseContent(ctx, templateText);
    // §4.0.7: written after upsertResponseAudit so the FK into
    // response_audit(id) resolves. c_emergency_display_not_gated requires
    // template_displayed_at to be set for CRITICAL/EMERGENCY, which it is —
    // captured immediately after the template actually reached the client.
    await recordRedFlagEvent(ctx, redFlag, deriveActionTaken(redFlag.severity, true), {
      firstByteAt: new Date(ctx.receivedAt),
      scannerStartedAt: new Date(redFlag.scannerStartedAt),
      templateDisplayedAt,
    });
    await recordAuditEvent(ctx, 'PUBLISHED', 'system', { path: 'emergency_template' });
    // §4.0.5: concurrent, post-display notification — fired only now, after
    // the template already reached the user, and NOT awaited.
    void dispatchSideEffects({
      ctx,
      category: 'INFORMATIONAL',
      severity: redFlag.severity,
      reviewRequired: true,
      postHocSampleEligible: false,
      templateRendered: true,
    });
    return;
  }

  // ---- §2.3.6 — CLINICAL_DECISION short-circuit ---------------------------
  // Structurally required: safety.response_category_state.CLINICAL_DECISION
  // .enabled = false and c_category_c_disabled_v1 makes this the only legal
  // outcome for that category in v1. No knowledge lookup, no generation —
  // the refusal text is pre-approved, not model-authored, matching the
  // Charter's posture for anything shown without the normal validator path.
  if (classification.category === 'CLINICAL_DECISION') {
    send('sentence', { text: CLINICAL_DECISION_REFUSAL, citedClaimIds: [] });
    await upsertResponseAudit({
      ctx,
      category: 'INFORMATIONAL', // the refusal message itself is informational, not a clinical decision
      classifierVersion: classification.classifierVersion,
      severity: redFlag.severity,
      ruleId: redFlag.ruleId,
      templateId: null,
      aggConfidence: 1.0,
      modelVersion: 'n/a-static-refusal',
      promptVersion: 'n/a-static-refusal',
      citedClaimIds: [],
      reviewRequired: false,
    });
    await persistResponseContent(ctx, CLINICAL_DECISION_REFUSAL);
    // §4.0.7 — this path is reached regardless of severity (it's a category
    // short-circuit, not a severity one), so the event is only actually
    // written when scanRedFlags found MONITOR+ (recordRedFlagEvent no-ops
    // below that). Never TEMPLATE_SHOWN here: the CRITICAL/EMERGENCY branch
    // above already returned first if that applied.
    await recordRedFlagEvent(ctx, redFlag, deriveActionTaken(redFlag.severity, false), {
      firstByteAt: new Date(ctx.receivedAt),
      scannerStartedAt: new Date(redFlag.scannerStartedAt),
    });
    await recordAuditEvent(ctx, 'PUBLISHED', 'system', { path: 'clinical_decision_refusal' });
    void dispatchSideEffects({
      ctx,
      category: 'INFORMATIONAL',
      severity: redFlag.severity,
      reviewRequired: false,
      postHocSampleEligible: true, // still worth sampling — a rising rate of this path is an AMB-01/product signal
      templateRendered: false,
    });
    return;
  }

  const category = classification.category as Exclude<ResponseCategory, 'CLINICAL_DECISION'>;

  // ---- 4. Patient profile lookup (direct DB read) --------------------------
  const profile = await lookupPatientProfile(ctx);

  // §2.4.3 — a minor's Decision Support requires mandatory pre-publication
  // review regardless of §2.2.5b's usual conditions.
  const minorForcesReview = profile?.isMinor === true;

  // ---- 5. Knowledge Lookup Layer, parallel, direct SQL, no LLM -------------
  const byDomain = await lookupKnowledge(ctx, intent.requiresKnowledgeDomains, category);
  const claims = flattenClaims(byDomain);
  const claimsById = new Map<string, RetrievedClaim>(claims.map((c) => [c.claimId, c]));
  send('sources', { count: claims.length, domains: Array.from(byDomain.keys()) });

  // §2.0.2 monotonic-upward re-check now that retrieval has actually run.
  const retrievalImpliesClinical = claims.some((c) => c.kind === 'TEST_INTERPRETATION');
  const reconciledCategory = reconcileAfterRetrieval(category, retrievalImpliesClinical);
  if (reconciledCategory === 'CLINICAL_DECISION') {
    send('sentence', { text: CLINICAL_DECISION_REFUSAL, citedClaimIds: [] });
    await upsertResponseAudit({
      ctx,
      category: 'INFORMATIONAL',
      classifierVersion: classification.classifierVersion,
      severity: redFlag.severity,
      ruleId: redFlag.ruleId,
      templateId: null,
      aggConfidence: 1.0,
      modelVersion: 'n/a-static-refusal',
      promptVersion: 'n/a-static-refusal',
      citedClaimIds: [],
      reviewRequired: false,
    });
    await persistResponseContent(ctx, CLINICAL_DECISION_REFUSAL);
    // §4.0.7 — same reasoning as the category short-circuit above: this
    // branch is reached via §2.0.2 retrieval-implies-clinical reconciliation,
    // independent of severity, so the write is a no-op unless the scan
    // itself found MONITOR+.
    await recordRedFlagEvent(ctx, redFlag, deriveActionTaken(redFlag.severity, false), {
      firstByteAt: new Date(ctx.receivedAt),
      scannerStartedAt: new Date(redFlag.scannerStartedAt),
    });
    await recordAuditEvent(ctx, 'PUBLISHED', 'system', { path: 'clinical_decision_refusal_post_retrieval' });
    return;
  }

  // ---- 6. Clinical & diagnostic reasoning (Sonnet, escalate Opus if HIGH) -
  const reasoning = await buildReasoningBrief(ctx, intent, category, claims);

  // ---- 7. Personalized recommendation synthesis, streamed -----------------
  const { stream: anthropicStream, finalize } = beginSynthesis(ctx, intent, category, profile, claims, reasoning);

  async function* textDeltas(): AsyncIterable<string> {
    for await (const event of anthropicStream) {
      if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
        yield event.delta.text;
      }
    }
  }

  // ---- 8. Response emission validator, sentence by sentence, §3.0.3 -------
  let visibleSentenceCount = 0;
  let blockedCount = 0;
  const citedClaimIds = new Set<string>();
  let fullVisibleText = '';

  for await (const chunk of validateStream(ctx, category, claimsById, textDeltas())) {
    if (chunk.kind === 'sentence') {
      visibleSentenceCount++;
      fullVisibleText += (fullVisibleText ? ' ' : '') + chunk.text;
      chunk.citedClaimIds.forEach((id) => citedClaimIds.add(id));
      send('sentence', { text: chunk.text, citedClaimIds: chunk.citedClaimIds });
    } else {
      blockedCount++;
      await recordAuditEvent(ctx, 'VALIDATOR_BLOCK', 'system', { reason: 'see obs.fabrication_block for detail' });
    }
  }
  await finalize(blockedCount > 0 ? 'BLOCKED' : 'OK');

  // §3.0.4: abstention is a positive metric, never penalised. If every
  // sentence got blocked, say so plainly rather than sending an empty
  // response — an empty SSE stream with no explanation is a worse failure
  // mode than a visible abstention.
  if (visibleSentenceCount === 0) {
    const abstention =
      "I don't have a sourced answer to this from what I have access to right now. " +
      'I don’t want to guess, so I’m not going to give you an unsourced answer here.';
    send('sentence', { text: abstention, citedClaimIds: [] });
    fullVisibleText = abstention;
  }

  // ---- 9. Audit persistence ------------------------------------------------
  // §3.10.1-consistent aggregate: MIN over cited claims' confidence, per
  // HP-SCHEMA-001 §23.3's reasoning (a mean would let a high-confidence
  // claim carry a low-confidence one into a falsely-high band).
  const citedClaims = claims.filter((c) => citedClaimIds.has(c.claimId));
  const hasCitations = citedClaims.length > 0;

  // BUG FOUND RUNNING test_session_severity_floor_sticks_across_turns (§4.0.8
  // integration test), not caught by any earlier test: emissionValidator only
  // blocks sentences carrying an uncited *numeric claim* (§3.0.3) — a
  // response that streams cleanly but happens to cite nothing at all (no
  // numeric claims in it, e.g. "I don't have specific guidance to add here")
  // is neither blocked nor an abstention (visibleSentenceCount > 0), so it
  // used to fall through to `aggConfidence = 0.0` under a model-scored
  // category. Annex A.5's c_min_conf CHECK has no shape for that: it only
  // allows agg_confidence >= the category's floor, OR exactly 1.00 for the
  // "not model-scored" static template/refusal carve-out already used by the
  // short-circuit branches above. 0.0 under DECISION_SUPPORT/INFORMATIONAL
  // satisfies neither arm, so the INSERT hard-failed with a DB constraint
  // violation — after the response had already been streamed to the client.
  // A response with zero citations is, for scoring purposes, the same case
  // as those static carve-outs: there is no cited claim to aggregate
  // confidence over, so there is nothing for a numeric floor to apply to.
  // Persist it the same way — INFORMATIONAL, agg_confidence 1.00 — and
  // always force review, since "nothing was cited" is not something to wave
  // through as an unreviewed DECISION_SUPPORT/CLINICAL_DECISION publish.
  const aggConfidence = hasCitations ? Math.min(...citedClaims.map((c) => c.confidence)) : 1.0;
  const persistedCategory: Exclude<ResponseCategory, 'CLINICAL_DECISION'> = hasCitations ? category : 'INFORMATIONAL';

  const minConfidenceFloor = persistedCategory === 'INFORMATIONAL' ? 0.65 : 0.7; // Annex A.5 c_min_conf
  const belowFloor = hasCitations && aggConfidence < minConfidenceFloor;
  if (belowFloor) {
    // c_min_conf would reject this row outright; rather than let a DB error
    // surface to the user after we've already streamed a response, downgrade
    // to a review-required, unpublished state and say so.
    send('notice', { message: 'This response is below the published confidence floor and has been queued for review rather than marked published.' });
  } else if (!hasCitations) {
    send('notice', { message: 'This response cited no source claims and has been queued for review rather than marked published.' });
  }

  const reviewRequired =
    minorForcesReview ||
    SEVERITY_ORDER[redFlag.severity] >= SEVERITY_ORDER['WARNING'] ||
    (aggConfidence >= 0.7 && aggConfidence <= 0.74) || // §2.2.5b band
    belowFloor ||
    !hasCitations;

  await upsertResponseAudit({
    ctx,
    category: persistedCategory,
    classifierVersion: classification.classifierVersion,
    severity: redFlag.severity,
    ruleId: redFlag.ruleId,
    templateId: redFlag.templateId,
    aggConfidence,
    modelVersion: reasoning.modelUsed,
    promptVersion: process.env.PROMPT_VERSION_COMPOSE ?? 'compose-2026.08.1',
    citedClaimIds: Array.from(citedClaimIds),
    reviewRequired,
  });
  await persistResponseContent(ctx, fullVisibleText);
  // §4.0.7 — the normal completion path. Same no-op-below-MONITOR rule as
  // the other three exit points; this is the only one of the four where the
  // pipeline actually reached synthesis, so it's also the one where
  // deriveActionTaken's ESCALATED branch most plausibly correlates with
  // reviewRequired — though reviewRequired can be true for reasons this
  // event's action_taken doesn't capture (minorForcesReview, the confidence
  // band), since action_taken is specifically a red-flag-severity signal,
  // not a general "was this reviewed" one.
  await recordRedFlagEvent(ctx, redFlag, deriveActionTaken(redFlag.severity, false), {
    firstByteAt: new Date(ctx.receivedAt),
    scannerStartedAt: new Date(redFlag.scannerStartedAt),
  });

  await recordAuditEvent(ctx, reviewRequired ? 'REVIEW_REQUESTED' : 'PUBLISHED', 'system', {
    review_required: reviewRequired,
    agg_confidence: Number(aggConfidence.toFixed(2)),
    blocked_sentence_count: blockedCount,
    uncited: !hasCitations,
  });

  // ---- 10. Side-effect dispatcher — fired, NOT awaited ---------------------
  // Uses persistedCategory, not the pre-retrieval `category`, so this always
  // matches what upsertResponseAudit actually wrote to response_audit.
  void dispatchSideEffects({
    ctx,
    category: persistedCategory,
    severity: redFlag.severity,
    reviewRequired,
    postHocSampleEligible: !reviewRequired, // reviewed responses don't also need post-hoc sampling
    templateRendered: false,
  });
}
