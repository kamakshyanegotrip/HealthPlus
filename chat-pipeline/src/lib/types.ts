/**
 * Shared types for the chat pipeline.
 *
 * These mirror the enums and row shapes committed in the project schema
 * (HP-SCHEMA-001 Annex A Extension, Charter v1.0 Annex A, HP-RB-001).
 * Kept hand-written rather than generated because the DDL for several
 * "stand-in" tables (HP-SEC-001 §2: patient_profile, hospital_*, disease,
 * treatment, guideline, tourism_plan) has not landed as committed migrations
 * yet — reconcile field names here with the real migration when it ships.
 */

// Charter §2.0.1 — the closed three-category enum. CLINICAL_DECISION exists
// in the type system because the classifier must be able to *name* it (so
// §2.3.6 can catch it) even though it can never be persisted as an enabled
// category — see safety.response_category_state and c_category_c_disabled_v1.
export type ResponseCategory = 'INFORMATIONAL' | 'DECISION_SUPPORT' | 'CLINICAL_DECISION';

// Charter §4.0.2 — closed ordinal enum, six levels.
export type RedFlagSeverity = 'NORMAL' | 'MONITOR' | 'WARNING' | 'URGENT' | 'CRITICAL' | 'EMERGENCY';

export const SEVERITY_ORDER: Record<RedFlagSeverity, number> = {
  NORMAL: 0,
  MONITOR: 1,
  WARNING: 2,
  URGENT: 3,
  CRITICAL: 4,
  EMERGENCY: 5,
};

// obs.ai_call.purpose
export type AiCallPurpose =
  | 'CATEGORY_CLASSIFY'
  | 'RED_FLAG_PROPOSE'
  | 'COMPOSE'
  | 'EXTRACT'
  | 'RERANK'
  | 'TRANSLATE'
  | 'EMBED';

// obs.ai_call.outcome
export type AiCallOutcome = 'OK' | 'BLOCKED' | 'ERROR' | 'TIMEOUT' | 'REFUSED_BY_POLICY';

export type SourceTier = 'TIER_1' | 'TIER_2' | 'TIER_3' | 'TIER_4' | 'TIER_5';

export type ClaimKind =
  | 'GENERAL_EDUCATION'
  | 'COST'
  | 'PROVIDER_CREDENTIAL'
  | 'ACCREDITATION'
  | 'LEGAL_REGULATORY'
  | 'GUIDELINE'
  | 'MEDICATION'
  | 'EPIDEMIOLOGY'
  | 'TEST_INTERPRETATION' // deny-only kind, §3.1 / §3.1.7
  | 'PROVIDER_OUTCOME'
  | string; // schema has ~15 kinds total; not all are exercised by this pipeline

export type PolicyDisposition = 'PERMITTED' | 'PERMITTED_ATTRIBUTED' | 'REQUIRES_CORROBORATION' | 'PROHIBITED';

export interface RetrievedClaim {
  claimId: string;
  kind: ClaimKind;
  tier: SourceTier;
  category: ResponseCategory;
  confidence: number; // 0.00-1.00, computed by the DQE (§1.0.5) — never set here
  confidenceBand: 'High' | 'Medium' | 'Low' | 'Insufficient'; // §1.9.4
  citation: string; // rendered from the persisted source record, §1.9.5 — never model-authored
  text: string; // the claim text as stored; the model may reference but not rewrite it
  jurisdiction?: string;
  population?: string; // §1.9.7 — null population blocks publication for range/stat claims
  domain: KnowledgeDomain;
}

export type KnowledgeDomain =
  | 'NUTRITION'
  | 'EXERCISE'
  | 'LIFESTYLE'
  | 'MONITORING'
  | 'COST'
  | 'HOSPITAL'
  | 'VISA'
  | 'ENVIRONMENT'
  | 'GUIDELINE';

export interface IntentComplexityResult {
  intent: string; // e.g. "compare_hospitals", "cost_estimate", "general_education", ...
  complexity: 'LOW' | 'MEDIUM' | 'HIGH';
  requiresKnowledgeDomains: KnowledgeDomain[];
  rationale: string;
}

export interface CategoryClassification {
  category: ResponseCategory;
  classifierVersion: string;
  confidence: number; // classifier's own self-reported confidence — NOT the DQE confidence
  ambiguous: boolean; // §2.0.3 — if true, category was resolved upward per the rule
  inputsDigest: string; // sha256 of (message + retrieval digest), for §2.0.4 audit
}

export interface RedFlagResult {
  severity: RedFlagSeverity;
  ruleId: string | null;
  ruleVersion: number | null;
  ruleSetId: string;
  triggerDetail: Record<string, unknown>; // which pattern matched — no free user text (§4.0.7)
  proposedSeverityByModel: RedFlagSeverity | null; // §4.0.3 — model may only raise
  templateId: string | null; // required when severity >= WARNING (c_urgent_template_only)
  templateVersion: number | null;
  // §6.5: when the scan itself began, ISO 8601. Distinct from
  // PipelineContext.receivedAt (first byte of the inbound message) — the gap
  // between the two is intent/complexity classification time, which §6.5
  // deliberately excludes from the latency figure it cares about.
  scannerStartedAt: string;
  // §0.6 / AMB-17. 'FAIL_CLOSED' means no clinically adopted rule was available
  // to scan with (or the rule table was unreachable) — NOT that the message was
  // scanned and found clean. Required, not optional, so every construction site
  // has to state which it is and no caller can quietly treat the two as the
  // same thing.
  adoptionGate: 'OPEN' | 'FAIL_CLOSED';
  // Non-null iff adoptionGate === 'FAIL_CLOSED'. What the surface must render.
  unavailability: import('./pipeline/unavailability').ServiceUnavailability | null;
}

export interface PatientProfile {
  userId: string;
  dataRegion: string;
  ageBand: string | null;
  statedConditions: Array<{ label: string; provenance: 'stated' | 'inferred' }>; // §3.8.2
  preferences: Record<string, unknown> | null;
  isMinor: boolean; // §2.4.3 — forces mandatory Decision Support review, blocks Category C absolutely
}

export interface PipelineContext {
  sessionId: string;
  userId: string;
  message: string;
  dataRegion: string;
  auditId: string; // uuid, minted at the top of the request, threaded through every log write
  // §6.5: "latency measured from first byte of the INBOUND message, not
  // scanner start." ISO 8601, captured at the very top of route.ts's POST
  // handler, before auth or body parsing. This is an application-layer
  // approximation, not a raw TCP/TLS first-byte timestamp — Next.js's route
  // handler doesn't expose one — flagged here rather than silently treated
  // as exact.
  receivedAt: string;
  // §4.5.1(b): emergency routing uses the patient's STATED CURRENT LOCATION,
  // never their account address. Null when they have not stated one — in which
  // case §3.12.1's generic "call your local emergency number" line stands, and
  // nothing is guessed from the billing country.
  statedCountry?: string | null;
  // HP-SEC-001 RLS (db/020_rls.sql): the caller's verified role/hospital
  // claims, threaded through so any DB access needing row-level enforcement
  // can call db.ts's runAsUser(ctx.authClaims, ...) rather than querying on
  // the bare pooled connection. Populated from src/lib/auth.ts's
  // AuthContext at the top of route.ts, right after requireAuth() succeeds.
  authClaims: {
    sub: string;
    user_role: 'patient' | 'clinician' | 'hospital_admin' | 'platform_admin';
    hospital_id: string | null;
    admin_scopes: string[];
  };
}
