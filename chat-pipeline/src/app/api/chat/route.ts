import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { PipelineContext, ResponseCategory, RetrievedClaim } from '@/lib/types';
import { newPendingTelemetry } from '@/lib/types';
import { getOrMintSubjectKey } from '@/lib/subjectKey';
import { requireAuth, AuthError } from '@/lib/auth';
import { classifyIntentComplexity } from '@/lib/pipeline/intentComplexity';
import { classifyCategory, reconcileAfterRetrieval } from '@/lib/pipeline/categoryClassifier';
import { CLINICAL_DECISION_REFUSAL } from '@/lib/prompts/annexB';
import { scanRedFlags, loadSafetyTemplate, recordRedFlagEvent, deriveActionTaken, getSessionFloor, applySessionFloor, recordRedFlagLog } from '@/lib/pipeline/redFlagEngine';
import { resolveTemplateForSeverity } from '@/lib/pipeline/templateResolution';
import { makePrepareTemplate } from '@/lib/pipeline/templateSlots';
import { resolveEmergencyNumber } from '@/lib/pipeline/unavailability';
import { lookupPatientProfile, minorGateRequiresReview, highRiskProfileRequiresReview } from '@/lib/pipeline/patientProfile';
import { lookupKnowledge, flattenClaims } from '@/lib/pipeline/knowledgeLookup';
import { buildReasoningBrief } from '@/lib/pipeline/clinicalReasoning';
import { beginSynthesis } from '@/lib/pipeline/synthesis';
import { resolveConstraints, applyConstraints } from '@/lib/pipeline/constraintSet';
import { planCoverage, detectDimensions, DEFERRABLE_DIMENSIONS } from '@/lib/pipeline/coveragePlan';
import { disclosureFor } from '@/lib/pipeline/disclosure';
import { validateStream } from '@/lib/pipeline/emissionValidator';
import { recordAuditEvent, upsertResponseAudit, persistResponseContent } from '@/lib/pipeline/auditLog';
import { checkElevatedTopics, topicGateRequiresReview, topicAuditTrigger } from '@/lib/pipeline/elevatedTopic';
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

  // ADR-003 §2.4's per-subject key, resolved ONCE for the whole turn — every
  // pseudonym written below derives from this salt and the response ciphertext
  // is encrypted under this DEK. Minted on the subject's first turn.
  //
  // BEFORE THE STREAM OPENS, deliberately. A failure here is a failure to
  // establish who this turn is about, and there is nothing safe to do with a
  // turn like that: pseudonymize.ts would refuse, obs.response_content could not
  // be written, and the audit trail would be a response with no subject. Failing
  // as an HTTP error is honest; failing three steps into an SSE stream, after the
  // user has already seen sentences, is not. The one case this deliberately
  // rejects rather than works around is a DESTROYED key — an erased subject
  // whose token still authenticates (HP-ESC 2.3.4g).
  let subjectKey;
  try {
    subjectKey = await getOrMintSubjectKey(auth.userId);
  } catch (err) {
    console.error('subject key resolution failed', { auditId, userId: auth.userId, err });
    return Response.json({ error: 'this account cannot be served right now' }, { status: 503 });
  }

  const ctx: PipelineContext = {
    sessionId: parsed.data.sessionId,
    userId: auth.userId,
    message: parsed.data.message,
    dataRegion: auth.dataRegion ?? process.env.DATA_REGION ?? 'IN',
    auditId,
    receivedAt: firstByteAt.toISOString(),
    subjectKey,
    pending: newPendingTelemetry(),
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

  // §0.6 / AMB-17 — the adoption gate, checked before ANY severity-based
  // branching below. If it is closed, no clinically adopted rule existed to
  // scan this message with, so `redFlag.severity` is NORMAL by absence rather
  // than by assessment. Every branch after this point reads that NORMAL as a
  // finding; none of them can tell the difference. So the difference is made
  // here, and it is made by returning rather than by setting a flag someone
  // downstream has to remember to check.
  //
  // This is deliberately NOT a triage outcome: nothing is asserted about this
  // person's symptoms, no template is shown, no severity is claimed. See
  // unavailability.ts for why the copy is shaped the way it is.
  if (redFlag.adoptionGate === 'FAIL_CLOSED') {
    const unavailable = redFlag.unavailability!;
    await recordAuditEvent(ctx, 'SEVERITY_ASSIGNED', 'system', {
      severity: 'NORMAL',
      adoption_gate: 'FAIL_CLOSED',
      reason: unavailable.internalReason,
    });
    send('unavailable', {
      heading: unavailable.heading,
      body: unavailable.body,
      emergencyNumber: unavailable.emergencyNumber,
      humanContact: unavailable.humanContact,
      suppressed: unavailable.suppressed,
      permitted: unavailable.permitted,
      copyVersion: unavailable.copyVersion,
    });
    await upsertResponseAudit({
      ctx,
      // The notice is product chrome about the service, not a determination
      // about this person — see unavailability.ts. Recording it as anything
      // else would put a clinical category on a message nobody assessed.
      category: 'INFORMATIONAL',
      classifierVersion: classification.classifierVersion,
      severity: 'NORMAL',
      ruleId: null,
      ruleVersion: null,
      templateId: null,
      templateVersion: null,
      aggConfidence: 1.0, // static, non-clinical copy; no model uncertainty
      modelVersion: 'n/a-safety-unavailable',
      promptVersion: 'n/a-safety-unavailable',
      citedClaimIds: [],
      // Nothing was generated, so there is nothing to review. The thing that
      // needs human attention is the unsigned rule set (AMB-17), and that is a
      // governance item, not a per-response review queue entry.
      reviewRequired: false,
    });
    await recordRedFlagLog(ctx, redFlag, {
      eventId: null,
      branch: 'FAIL_CLOSED',
      commercialSuppressed: true,
      generationBlocked: true,
      needsReview: false,
      scannerCompletedAt: new Date(),
      templateDisplayedAt: null,
    });
    send('done', { reason: 'SAFETY_UNAVAILABLE' });
    return;
  }

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
    // model-side raise (clampSeverity then resolveTemplateForSeverity, see
    // its own header comment and the
    // test_hp_esc_4_0_2_model_raised_severity_past_warning_with_no_rule_template_still_gets_one
    // unit test) — a session-floor raise needs the identical treatment.
    // R2: re-resolve through the §4.3.3 ladder at the floored severity. The
    // original bug this block fixes is unchanged in shape — a floor raise past
    // WARNING must not leave the pre-floor (null) template behind, which would
    // hard-fail red_flag_event's c_urgent_needs_template — but the resolution
    // is now by (severity, jurisdiction, language) rather than by an FK the
    // real schema does not have.
    // RF4: same prepare hook as the primary resolution in redFlagEngine, so a
    // floor raise cannot land on a template whose slots do not fill. Without
    // it this path would be the one place a placeholder could still reach a
    // user — and it is the path that only runs when a session has already been
    // escalated, which is the worst place to leave a gap.
    const floorSelection = await resolveTemplateForSeverity(
      flooredSeverity,
      ctx.statedCountry ?? ctx.dataRegion,
      ctx.language ?? 'en',
      undefined,
      makePrepareTemplate(ctx, ctx.language ?? 'en', resolveEmergencyNumber),
    ).catch(() => null);
    redFlag.templateId = floorSelection?.template.id ?? null;
    redFlag.templateVersion = floorSelection?.template.version ?? null;
    redFlag.templateBody = floorSelection?.renderedText ?? floorSelection?.template.body ?? null;
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
    const loadedTemplate = loadSafetyTemplate(redFlag.templateBody);
    const templateText = loadedTemplate.body;
    await recordAuditEvent(ctx, 'TEMPLATE_RENDERED', 'system', {
      template_id: redFlag.templateId,
      template_version: redFlag.templateVersion,
      // J3-5: an emergency rendered from the unapproved hard-coded fallback
      // must be distinguishable in the audit trail from a clinician-authored
      // one. Before this, the two were identical in the record.
      template_source: loadedTemplate.source,
      template_load_failure: loadedTemplate.failure,
    });
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
      ruleVersion: redFlag.ruleVersion,
      templateId: redFlag.templateId,
      templateVersion: redFlag.templateVersion,
      aggConfidence: 1.0, // a static, clinician-authored template carries no model uncertainty
      modelVersion: 'n/a-static-template',
      promptVersion: 'n/a-static-template',
      citedClaimIds: [],
      /**
       * FALSE, AND THE REAL SCHEMA IS WHAT DECIDES IT.
       *
       * This said `true` with the comment "§4.0.5: review is concurrent/
       * post-display, not a precondition — still required". Against the real
       * schema that write does not fail a policy or a lint; it is REFUSED:
       *
       *   new row for relation "response_audit" violates check constraint
       *   "c_emergency_not_gated"
       *   CHECK (severity NOT IN ('CRITICAL','EMERGENCY')
       *          OR review_state <> 'PENDING')
       *
       * So at CRITICAL or EMERGENCY the audit projection may not sit in
       * PENDING at all, and `reviewRequired: true` is exactly what produced
       * PENDING. The stub had no such constraint, which is why this stood.
       *
       * WHAT THE CONSTRAINT MEANS, rather than what it costs. On this
       * projection PENDING means "held, awaiting a reviewer" — that is what
       * §2.2.5b's gate writes and what the review queue reads. §4.0.5 forbids
       * an emergency display being gated on anything, so a row that is both
       * CRITICAL and PENDING is a contradiction the schema refuses to store.
       * It is the pair to c_emergency_display_not_gated, which requires
       * template_displayed_at to be SET on the same rows.
       *
       * THE REVIEW OBLIGATION IS NOT LOST, AND IT IS NOT LEFT TO THIS FIELD.
       * safety.red_flag_event carries two triggers — trg_raise_alert_for_event
       * raises the clinician alert, and trg_event_requires_alert refuses the
       * event row unless one exists. recordRedFlagEvent runs three lines below,
       * so the obligation is created by the database, on an alert row with an
       * SLA and a delivery worker behind it (RF6), rather than by a column on a
       * projection that nothing pages on. That is a stronger record than the
       * one being given up, which is the reason to follow the schema here
       * rather than argue with it.
       *
       * Recorded for SR review rather than settled in a comment: §4.0.5's
       * "still required" is now discharged entirely through the alert path, so
       * a response published under an emergency template never appears in the
       * review queue. If the clinical lead wants it in both places, that is a
       * schema question (a review_state value that is not PENDING and not
       * NOT_REQUIRED), not an application one.
       */
      reviewRequired: false,
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
      // Matches the audit row written above, and must. sideEffectDispatcher
      // logs a review obligation at ERROR level precisely because the audit
      // row is the only record of one; claiming an obligation the row cannot
      // hold would make that log say something untrue. The emergency
      // obligation travels on the clinician alert instead — see the long note
      // on `reviewRequired` in the upsertResponseAudit call above.
      reviewRequired: false,
      postHocSampleEligible: false,
      templateRendered: true,
    });
    return;
  }

  // ---- §2.3.6 — CLINICAL_DECISION handling (HP-JOB-011) -------------------
  //
  // Category C is never published: safety.response_category_state
  // .CLINICAL_DECISION.enabled = false, and c_category_c_disabled_v1 makes
  // that structural rather than conventional. Neither is touched here.
  //
  // WHAT CHANGED. §2.3.6 has three parts and this pipeline implemented two.
  // (a) say plainly it cannot interpret the individual's situation and (b)
  // explain who can were the static CLINICAL_DECISION_REFUSAL below. (c) —
  // "offer the adjacent permitted help ... reproducing published criteria
  // with citation, or preparing a question list for the user's clinician" —
  // was not implemented at all, so a question that asked for four things we
  // cannot determine ALONGSIDE six we can (blueprint §42's worked example is
  // exactly that shape) lost all ten to §2.0.2's monotonic-upward rule.
  //
  // Now: a turn classified CLINICAL_DECISION is planned (coveragePlan.ts). If
  // any dimension is answerable from admitted evidence, the turn publishes as
  // DECISION_SUPPORT with its Category C dimensions deferred in §2.3.6 form —
  // taking DECISION_SUPPORT's safeguards IN FULL, including §2.2.4's
  // disclaimer and every §2.2.5b review trigger. If nothing is answerable, the
  // flat refusal below runs exactly as it always did.
  //
  // The cheap gate first: a question asking ONLY for determinations we cannot
  // make never reaches retrieval, so a pure Category C turn costs no more than
  // it did before this change.
  const wasClinicalDecision = classification.category === 'CLINICAL_DECISION';
  const anyAnswerableDimensionRequested =
    !wasClinicalDecision ||
    detectDimensions(ctx.message, intent.requiresKnowledgeDomains).some((k) => !DEFERRABLE_DIMENSIONS.has(k));

  if (wasClinicalDecision && !anyAnswerableDimensionRequested) {
    send('sentence', { text: CLINICAL_DECISION_REFUSAL, citedClaimIds: [] });
    await upsertResponseAudit({
      ctx,
      category: 'INFORMATIONAL', // the refusal message itself is informational, not a clinical decision
      classifierVersion: classification.classifierVersion,
      severity: redFlag.severity,
      ruleId: redFlag.ruleId,
      ruleVersion: redFlag.ruleVersion,
      templateId: null,
      templateVersion: null,
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

  // The category this turn will PUBLISH under. A turn the classifier called
  // CLINICAL_DECISION publishes as DECISION_SUPPORT with its Category C
  // components deferred — never as CLINICAL_DECISION, which has no publishable
  // form in v1. Retrieval below is gated on THIS value, so `evidence.policy_for`
  // is always evaluated at DECISION_SUPPORT: strictly narrower than Category C
  // would allow, never wider. Nothing about the deferral path widens what is
  // retrievable, and coveragePlan.ts's header states the four walls a reviewer
  // can check that against.
  const category: Exclude<ResponseCategory, 'CLINICAL_DECISION'> = wasClinicalDecision
    ? 'DECISION_SUPPORT'
    : (classification.category as Exclude<ResponseCategory, 'CLINICAL_DECISION'>);

  // ---- 4. Patient profile lookup (direct DB read) --------------------------
  const profile = await lookupPatientProfile(ctx);

  // §2.4.3 — a minor's Decision Support requires mandatory pre-publication
  // review regardless of §2.2.5b's usual conditions.
  //
  // Was `profile?.isMinor === true`, which answered "is this definitely a
  // minor?" when the clause asks "may this be published without review?".
  // Those differ on exactly the cases where nothing is known: no profile row,
  // or a row that does not establish age. §3.0.3 resolves an unestablished
  // fact closed, so both now force review. HP-SR-001 §4; the reasoning and the
  // two things this deliberately does NOT fix live on the helper.
  const minorForcesReview = minorGateRequiresReview(profile);

  // §2.2.5b TRIGGER 1 — "the user carries a flagged high-risk profile (§4.6)".
  // HP-SR-001 recorded this as absent; it was worse than absent, because the
  // flags were being READ and then discarded. Nine of the ten never reached a
  // decision. See highRiskProfileRequiresReview for why it is ANY flag and what
  // that costs in reviewer load.
  const highRiskProfileForcesReview = highRiskProfileRequiresReview(profile);

  // §2.2.5b TRIGGER 2 — the Elevated-Risk Topic List (§2.4.1). Three-valued:
  // an unadopted list forces review rather than passing silently. Runs on the
  // redflag pool because hp_app deliberately reaches nothing in `safety`.
  const topicCheck = await checkElevatedTopics(ctx);
  const topicForcesReview = topicGateRequiresReview(topicCheck);

  // ---- 5. Knowledge Lookup Layer, parallel, direct SQL, no LLM -------------
  const byDomain = await lookupKnowledge(ctx, intent.requiresKnowledgeDomains, category);
  const retrievedClaims = flattenClaims(byDomain);

  // ---- 5a. Constraint ladder and coverage plan (HP-JOB-011) ---------------
  // The ladder decides WHICH published content is shown; it never decides what
  // is true of the patient. constraintSet.ts's header carries that distinction
  // in full — it is the line between Category B selection and the Category C
  // §11/§15 engines §2.4.1a prohibits.
  const constraints = resolveConstraints(profile, {
    redFlagSeverityAtLeastWarning: SEVERITY_ORDER[redFlag.severity] >= SEVERITY_ORDER['WARNING'],
  });
  const application = applyConstraints(constraints, retrievedClaims);

  // The composer and the validator both see the ADMITTED set, not the retrieved
  // one. A claim the ladder withheld must not be citable: if it were still in
  // claimsById the validator would happily pass a sentence citing content the
  // composer was never shown, which is a citation to something not retrieved
  // for this response in everything but name (§3.9.2).
  const claims = application.admitted;
  const claimsById = new Map<string, RetrievedClaim>(claims.map((c) => [c.claimId, c]));
  send('sources', {
    count: claims.length,
    domains: Array.from(byDomain.keys()),
    withheldByConstraint: application.suppressed.length,
  });

  const plan = planCoverage({
    message: ctx.message,
    intentDomains: intent.requiresKnowledgeDomains,
    admittedClaims: claims,
    categoryWasClinicalDecision: wasClinicalDecision,
  });
  send('coverage', {
    dimensions: plan.dimensions.map((d) => ({ key: d.key, disposition: d.disposition })),
    deferred: plan.deferredDimensions,
  });

  // §2.3.6 fallback. The cheap gate above let this turn through because it
  // ASKED for something answerable; retrieval then found nothing to answer it
  // with. A plan of nothing but DEFERRED and NO_EVIDENCE would compose into
  // "I can't help with any of this", at length and with a model call — worse
  // for the patient than the short pre-approved refusal, and more expensive.
  if (wasClinicalDecision && !plan.publishable) {
    send('sentence', { text: CLINICAL_DECISION_REFUSAL, citedClaimIds: [] });
    await upsertResponseAudit({
      ctx,
      category: 'INFORMATIONAL',
      classifierVersion: classification.classifierVersion,
      severity: redFlag.severity,
      ruleId: redFlag.ruleId,
      ruleVersion: redFlag.ruleVersion,
      templateId: null,
      templateVersion: null,
      aggConfidence: 1.0,
      modelVersion: 'n/a-static-refusal',
      promptVersion: 'n/a-static-refusal',
      citedClaimIds: [],
      reviewRequired: false,
    });
    await persistResponseContent(ctx, CLINICAL_DECISION_REFUSAL);
    await recordRedFlagEvent(ctx, redFlag, deriveActionTaken(redFlag.severity, false), {
      firstByteAt: new Date(ctx.receivedAt),
      scannerStartedAt: new Date(redFlag.scannerStartedAt),
    });
    await recordAuditEvent(ctx, 'PUBLISHED', 'system', { path: 'clinical_decision_refusal_unplannable' });
    void dispatchSideEffects({
      ctx,
      category: 'INFORMATIONAL',
      severity: redFlag.severity,
      reviewRequired: false,
      postHocSampleEligible: true,
      templateRendered: false,
    });
    return;
  }

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
      ruleVersion: redFlag.ruleVersion,
      templateId: null,
      templateVersion: null,
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
  const { stream: anthropicStream, finalize } = beginSynthesis(
    ctx,
    intent,
    category,
    profile,
    claims,
    reasoning,
    plan,
    constraints,
    application,
  );

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

  // §3.3.1 — the patient's own stated budget ceiling is a figure that may
  // legitimately appear without a claim behind it. §3.3.3 tells the composer to
  // NAME an over-budget option rather than drop it, so blocking that number
  // would punish the composer for obeying the Charter. Threaded from the same
  // ladder the composer saw, so the two cannot disagree about what was stated.
  const permittedFigures = constraints.constraints
    .filter((c) => c.ceilingAmount !== undefined && c.ceilingCurrency)
    .map((c) => `${c.ceilingCurrency}:${c.ceilingAmount}`);

  for await (const chunk of validateStream(ctx, category, claimsById, textDeltas(), { permittedFigures })) {
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

  // §2.1.5 / §2.2.4 — the mandatory disclaimer, as UI chrome rather than model
  // output (HP-JOB-011). Emitted HERE, after `persistedCategory` is settled,
  // because the clause that applies is the one the audit row records: a
  // response downgraded to INFORMATIONAL for citing nothing must not carry
  // §2.2.4's "this comparison is decision support" text over the top of it.
  //
  // Before this, no surface rendered either disclaimer. Every response this
  // pipeline has produced shipped without one.
  //
  // `firstContact: true` unconditionally. J11-6, and CLOSED as a decision rather
  // than left as a gap — the server-side narrowing was costed and rejected.
  //
  // §3.11.4 wants the automated-system notice "on request and at first contact
  // in every session". Deriving "first contact" here would mean asking whether
  // this session has an earlier audit row, and that query is unavailable twice
  // over, both checked against the live schema rather than assumed:
  //
  //   * obs.response_audit has ONE index, on (id). No session_id index, so the
  //     check is a sequential scan of an append-only, hash-chained table that
  //     only ever grows — on the request path §6.5 measures latency along.
  //   * hp_app holds no SELECT on obs.response_audit at all
  //     (has_table_privilege -> false). That is deliberate: the app writes
  //     through obs.record_* and cannot read the audit log back. HP-RB-001
  //     locked this table down on purpose.
  //
  // So the "cheap" fix is a migration adding an index AND a grant to the one
  // table the immutability run-book most wants untouched, to remove a single
  // true sentence from a chrome block. Not proportionate.
  //
  // Showing it every turn OVER-satisfies §3.11.4 — the notice is accurate on
  // every turn, and the clause's floor is "at first contact", not "only at
  // first contact". If the repetition ever grates, the surface that knows
  // whether it is rendering a session's first turn is the CLIENT, and it can
  // suppress a repeat without the server growing a read path into the audit
  // log. Recorded as a product choice; no longer an engineering item.
  send('disclosure', disclosureFor(persistedCategory, { firstContact: true }));

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

  // §1.8.3 / §2.2.5b TRIGGER 5 — a Tier 1 vs Tier 2 conflict that no rule broke.
  // The database has detected these since migration 024 and returned the
  // conflict's id on every retrieved row; knowledgeLookup discarded the column
  // until now. `demotionRequired` is the stronger signal (the aggregate was
  // actually pulled down), and `conflictId` alone still counts: §1.8.1(d)'s
  // SURFACED_TO_USER is a decision to show a disagreement, not to settle it.
  const conflictedClaims = citedClaims.filter((c) => c.demotionRequired || c.conflictId !== undefined);
  const tierConflictForcesReview = conflictedClaims.length > 0;

  // ALL FIVE OF §2.2.5b's TRIGGERS, for the first time, plus the two this team
  // added (belowFloor, uncited) which are good ones and are kept.
  const reviewTriggers = [
    minorForcesReview ? 'MINOR_GATE' : null,                       // §2.4.3
    highRiskProfileForcesReview ? 'HIGH_RISK_PROFILE' : null,      // §2.2.5b(1)
    topicAuditTrigger(topicCheck),                                 // §2.2.5b(2)
    SEVERITY_ORDER[redFlag.severity] >= SEVERITY_ORDER['WARNING'] ? 'SEVERITY' : null, // §2.2.5b(3)
    aggConfidence >= 0.7 && aggConfidence <= 0.74 ? 'CONFIDENCE_BAND' : null,          // §2.2.5b(4)
    tierConflictForcesReview ? 'TIER_CONFLICT' : null,             // §2.2.5b(5) / §1.8.3
    belowFloor ? 'BELOW_FLOOR' : null,                             // team addition
    !hasCitations ? 'UNCITED' : null,                              // team addition
  ].filter((t): t is string => t !== null);

  const reviewRequired = reviewTriggers.length > 0;

  await upsertResponseAudit({
    ctx,
    category: persistedCategory,
    classifierVersion: classification.classifierVersion,
    severity: redFlag.severity,
    ruleId: redFlag.ruleId,
    ruleVersion: redFlag.ruleVersion,
    templateId: redFlag.templateId,
    templateVersion: redFlag.templateVersion,
    aggConfidence,
    modelVersion: reasoning.modelUsed,
    // Kept in step with synthesis.ts's own default. These drifting apart means
    // the audit row names a prompt version that never ran, which §6.4 makes
    // load-bearing — test/section42.composition.test.ts pins them together.
    promptVersion: process.env.PROMPT_VERSION_COMPOSE ?? 'compose-2026.09.1',
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
    // WHICH triggers, not just THAT one fired. Without this the audit row cannot
    // answer the question §2.2.5b will actually be audited on — was the topic
    // list checked, or was there none? — and "review_required: false" reads the
    // same whether five triggers were evaluated or two were never implemented.
    review_triggers: reviewTriggers,
    agg_confidence: Number(aggConfidence.toFixed(2)),
    blocked_sentence_count: blockedCount,
    uncited: !hasCitations,
    // HP-JOB-011. §2.0.4 requires the category, the classifier version, the
    // inputs AND "the resulting safeguards" to be persisted. When a turn the
    // classifier called CLINICAL_DECISION publishes as DECISION_SUPPORT, the
    // safeguard that made that legitimate is the deferral of these specific
    // dimensions — so the audit row has to name them, or it records a category
    // downgrade with no account of why it was permitted.
    classified_category: classification.category,
    deferred_dimensions: plan.deferredDimensions,
    covered_dimensions: plan.dimensions.map((d) => `${d.key}:${d.disposition}`),
    constraints_applied: constraints.constraints.map((c) => c.key),
    claims_withheld_by_constraint: application.suppressed.length,
    disclaimer_clause: persistedCategory === 'DECISION_SUPPORT' ? '2.2.4' : '2.1.5',
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
