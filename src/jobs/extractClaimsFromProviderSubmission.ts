/**
 * HealthPlus — pg-boss task: extractClaimsFromProviderSubmission
 * ============================================================================
 *
 * Queue name:  extract-claims-from-provider-submission
 *
 * TRIGGER
 *   Enqueued by the upstream partner-portal parsing step, once a
 *   `domain.provider_submission` row transitions RECEIVED -> PARSED (Charter
 *   §1.4.1; HP-SCHEMA-001 provider_submission.state). This is Build Queue
 *   item #4 in the Open Items Register ("Ingestion pipeline on pg-boss") —
 *   the "extract" stage of ADR-001 §5's fetch -> parse -> extract -> embed ->
 *   score pipeline. It is NEVER invoked from a live user request: nothing on
 *   this path talks to a patient, and §4.0.1's synchronous red-flag scanner
 *   is a separate, in-request component untouched by this job.
 *
 * INPUT PAYLOAD
 *   { submissionId: string (uuid) }
 *   Deliberately a bare reference, not the submission's content — the job
 *   re-reads `domain.provider_submission` fresh under `FOR UPDATE` so it
 *   always acts on the current row, never a payload snapshot that might be
 *   stale by the time the job runs.
 *
 * LOGIC
 *   1. Load and row-lock the `domain.provider_submission` (FOR UPDATE). If
 *      missing, fail permanently. If `state` is not 'PARSED', no-op — this
 *      job already ran (or is running) for this submission; pg-boss is
 *      at-least-once, so this call must be idempotent.
 *   2. Load the owning `principal.provider_org` for publisher name and
 *      jurisdiction, both required on `evidence.evidence_source`.
 *   3. Call the Anthropic API (Opus tier, ADR-001 §3.6) with the shared
 *      Phase 3.1 safety fragment as the system-prompt base plus this job's
 *      extraction-specific instructions, and the submission's `payload` as
 *      the only permitted source of truth. Force structured tool-use output.
 *   4. Deterministically validate every candidate claim the model returns
 *      against the actual `payload` — JSON-path resolution plus literal-value
 *      anchoring — and against schema rules (§1.9.7 population requirement,
 *      §1.7.1 decay-row requirement for COST). A candidate that does not
 *      anchor to a real field is rejected, never coerced into a guess.
 *   5. If nothing survives validation (including the model's own
 *      `unable_to_extract` signal), abstain: mark the submission REJECTED,
 *      write one `obs.data_quality_flag` explaining why, commit, return.
 *      No evidence_source, no claim, no follow-on job.
 *   6. Otherwise, in the SAME transaction: insert one Tier 4
 *      `evidence.evidence_source` row for the submission; for each validated
 *      candidate insert `evidence.claim` + `evidence.claim_source` (Tier 4
 *      confidence computed by code per `claimKindPolicy`, never by the
 *      model — Charter §1.0.5) and enqueue the downstream `embed-claim` job
 *      through pg-boss's `db` adapter option, so the claim insert and its
 *      follow-on job commit or roll back together — the transactional-
 *      enqueue guarantee ADR-001 §3.2 point 7 calls out.
 *   7. Any candidate that individually failed validation, while others in
 *      the same submission succeeded, gets its own `data_quality_flag` row
 *      rather than being silently dropped.
 *   8. Mark the submission CLAIMS_CREATED, commit, return a summary.
 *
 * ANTHROPIC MODEL
 *   Opus tier (ADR-001 §3.6: "Opus 5 ... for offline claim extraction and
 *   conflict resolution") — see ANTHROPIC_MODEL_CLAIM_EXTRACTION in
 *   ../lib/anthropicClient. Standard Messages API, not the Batch API (ADR-001
 *   §3.6: the Batch API is excluded from Anthropic's BAA).
 *
 * SAFETY SYSTEM PROMPT
 *   Imported verbatim from ../safety/systemPromptFragments — the same module
 *   the live-surface "Part B" task imports from. This file never inlines or
 *   paraphrases Charter language; see that module's header comment.
 *
 * HP-DR-002 — TRANSPLANT COMMERCIAL DATA
 *   §2.4.2, as scoped by HP-DR-002, forbids the commercial engine from ever
 *   applying to transplantation. This job does NOT enforce that, and the
 *   reason is worth stating rather than leaving as an omission: it writes
 *   `evidence.claim` and `evidence.claim_source` only. It never writes
 *   `evidence.domain_attribute`, so at no point does it know which treatment
 *   a candidate claim is about — and a keyword scan of the statement text
 *   would be exactly the confidence-based decision §2.4.2's final sentence
 *   rules out.
 *
 *   Enforcement lives at the bind step instead, in the database: migration
 *   028's trigger on `evidence.domain_attribute` refuses to attach a COST or
 *   PROVIDER_OUTCOME claim to a treatment flagged
 *   `involves_donated_organ_or_tissue`, whichever code attempts it, including
 *   code nobody has written yet. That is stronger than a check inside this
 *   job, not weaker: the data never lands, for every writer.
 *
 *   WHEN THE ENTITY-BINDING STEP IS BUILT, it must catch that trigger's
 *   exception and turn it into a `data_quality_flag` plus a REJECTED
 *   submission — the same abstain-and-explain shape step 5 uses below — and
 *   not let it surface as an unhandled error. A provider that submits
 *   transplant pricing should get a clean rejection with a reason, and the
 *   figure should never reach a claim binding at all.
 *
 * TABLES READ
 *   domain.provider_submission, principal.provider_org, evidence.claim_kind_decay
 * TABLES WRITTEN
 *   domain.provider_submission (state), evidence.evidence_source,
 *   evidence.claim, evidence.claim_source, obs.data_quality_flag
 */
import type PgBoss from 'pg-boss';
import type { PoolClient } from 'pg';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { pgPool } from '../db/pool';
import { anthropic, ANTHROPIC_MODEL_CLAIM_EXTRACTION } from '../lib/anthropicClient';
import { PHASE_3_1_SAFETY_FRAGMENT } from '../safety/systemPromptFragments';
import {
  PROVIDER_SUBMISSION_CLAIM_KINDS,
  KINDS_REQUIRING_EXPIRY,
  computeTier4Confidence,
  confidenceSourceFor,
  requiresClinicalCapAndMarker,
  SELF_REPORT_MARKER,
  type ProviderSubmissionClaimKind,
} from '../lib/claimKindPolicy';

export const QUEUE_NAME = 'extract-claims-from-provider-submission';
const EMBED_CLAIM_QUEUE_NAME = 'embed-claim';
const JOB_IDENTITY = 'extract_claims_from_provider_submission_v1';

// ---------------------------------------------------------------------------
// Job input
// ---------------------------------------------------------------------------

export const jobInputSchema = z.object({
  submissionId: z.string().uuid(),
});
export type JobInput = z.infer<typeof jobInputSchema>;

// ---------------------------------------------------------------------------
// Model output contract (forced via tool-use — see callExtractionModel)
// ---------------------------------------------------------------------------

const candidateClaimSchema = z.object({
  kind: z.enum(PROVIDER_SUBMISSION_CLAIM_KINDS as unknown as [ProviderSubmissionClaimKind, ...ProviderSubmissionClaimKind[]]),
  statement: z.string().min(1),
  // A JSON path into the submission's payload, e.g. "packages[2].price_inr" —
  // proof of where the model says this came from. Validated in step 4; never
  // trusted on its own.
  source_field_path: z.string().min(1),
  population: z.string().nullable(),
  effective_at: z.string().nullable(),
  currency: z.string().nullable(),
  is_accreditation_assertion: z.boolean(),
});
type CandidateClaim = z.infer<typeof candidateClaimSchema>;

const extractionResultSchema = z.object({
  candidates: z.array(candidateClaimSchema),
  unable_to_extract: z.boolean(),
  abstain_reason: z.string().nullable(),
});
type ExtractionResult = z.infer<typeof extractionResultSchema>;

const EXTRACTION_TOOL_NAME = 'submit_candidate_claims';

const EXTRACTION_TASK_INSTRUCTIONS = `You are extracting structured factual claims from a hospital/provider
partner-portal submission (Tier 4 per HP-ESC §1.4 — self-reported by a party
with a direct commercial interest). The submission payload, given below as
SUBMISSION_PAYLOAD, is your ONLY permitted source. Do not use any outside
knowledge about this or any other hospital.

For every fact you extract, you MUST supply "source_field_path": a JSON path
into SUBMISSION_PAYLOAD (dot/bracket notation, e.g. "packages[2].price_inr")
pointing at the exact field the statement restates. Your "statement" text
must literally contain the value found at that path. If you cannot point to
a real field for a fact, do not include it as a candidate.

Only extract these claim kinds: COST (a listed price, fee, or package cost),
PROVIDER_OUTCOME (any success/complication/survival/volume/comparative-
superiority figure the provider asserts about itself), PROVIDER_CREDENTIAL
(a registration number, accreditation, certification, or "centre of
excellence"-style designation), LOGISTICS (address, opening hours, spoken
languages, published contact details). Set "is_accreditation_assertion" true
only for PROVIDER_CREDENTIAL candidates that assert an accreditation or
certification status rather than a plain administrative fact.

For a PROVIDER_OUTCOME candidate you MUST supply "population" (who the
figure applies to, e.g. "adult knee replacement patients, 2023 cohort") —
if the payload does not state a population for the figure, do not extract it
as a candidate at all.

If the payload contains nothing you can extract under these rules, call the
tool with an empty "candidates" array, "unable_to_extract": true, and a short
"abstain_reason". Do not pad the candidate list to appear useful.`;

// ---------------------------------------------------------------------------
// Deterministic JSON-path resolution and anchoring (§3.0.3: structural, not
// persuasive — this is code, not a prompt instruction, and it is what makes
// "never estimate or infer" enforceable rather than aspirational).
// ---------------------------------------------------------------------------

export function resolveJsonPath(root: unknown, path: string): unknown {
  const tokens = path
    .replace(/\[(\d+)\]/g, '.$1')
    .split('.')
    .map((t) => t.trim())
    .filter(Boolean);
  let current: unknown = root;
  for (const token of tokens) {
    if (current === null || current === undefined || typeof current !== 'object') {
      return undefined;
    }
    current = (current as Record<string, unknown>)[token];
  }
  return current;
}

export function isStructurallyAnchored(candidate: CandidateClaim, payload: unknown): boolean {
  const resolved = resolveJsonPath(payload, candidate.source_field_path);
  if (resolved === undefined || resolved === null || resolved === '') return false;
  const resolvedStr = String(resolved).trim();
  if (resolvedStr.length === 0) return false;
  return candidate.statement.includes(resolvedStr);
}

// ---------------------------------------------------------------------------
// pg-boss <-> raw `pg` transaction adapter.
// pg-boss's `db` option for send()/insert() accepts any object implementing
// `executeSql(text, values) => Promise<{ rows }>` (see pg-boss's ORM
// Transaction Adapters docs — Knex/Kysely/Drizzle/Prisma all ship equivalent
// wrappers; this project uses raw `pg`, so it needs its own one-liner).
// ---------------------------------------------------------------------------

export function fromPgClient(client: PoolClient) {
  return {
    async executeSql(text: string, values: unknown[]) {
      const result = await client.query(text, values);
      return { rows: result.rows };
    },
  };
}

// ---------------------------------------------------------------------------
// Row shapes
// ---------------------------------------------------------------------------

interface ProviderSubmissionRow {
  id: string;
  provider_org_id: string;
  submitted_by: string;
  submitted_at: Date;
  payload: unknown;
  content_hash: string;
  state: 'RECEIVED' | 'PARSED' | 'CLAIMS_CREATED' | 'REJECTED';
  data_region: string;
}

interface ProviderOrgRow {
  id: string;
  // VERIFIED 5 Sep 2026 against the committed principal.provider_org DDL, which
  // is (id, legal_name, country, status). The previous version of this
  // interface said `name`, and the query below selected `name` — a column that
  // does not exist. This job would have thrown on its second statement against
  // the real schema, every time.
  //
  // The comment that used to sit here said the column names were "assumed ...
  // confirm against the committed DDL". That was honest and it was right to
  // flag; nothing then confirmed it. `country` was assumed correctly.
  // `name` was not.
  //
  // What let it survive: this job had no CI until PR #3, and its test doubles
  // `principal.provider_org` with a fake returning `{ id, name, country }` —
  // so the fake encoded the same wrong assumption as the code, and the test
  // passed for exactly the reason the code was broken. The fake is corrected
  // too. Found by PREPAREing every SQL literal in the repository against the
  // real schema (register item R10's survey), not by reading.
  legal_name: string;
  country: string;
}

interface ClaimKindDecayRow {
  half_life_days: number | null;
  hard_expiry_days: number | null;
}

// ---------------------------------------------------------------------------
// Step 3 — the Anthropic call
// ---------------------------------------------------------------------------

async function callExtractionModel(payload: unknown): Promise<ExtractionResult> {
  const systemPrompt = [PHASE_3_1_SAFETY_FRAGMENT, EXTRACTION_TASK_INSTRUCTIONS].join('\n\n');

  const response = await anthropic.messages.create({
    model: ANTHROPIC_MODEL_CLAIM_EXTRACTION,
    max_tokens: 4096,
    system: systemPrompt,
    messages: [
      {
        role: 'user',
        content: `SUBMISSION_PAYLOAD:\n${JSON.stringify(payload, null, 2)}`,
      },
    ],
    tools: [
      {
        name: EXTRACTION_TOOL_NAME,
        description: 'Submit the candidate claims extracted from SUBMISSION_PAYLOAD.',
        input_schema: {
          type: 'object',
          properties: {
            candidates: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  kind: { type: 'string', enum: PROVIDER_SUBMISSION_CLAIM_KINDS as unknown as string[] },
                  statement: { type: 'string' },
                  source_field_path: { type: 'string' },
                  population: { type: ['string', 'null'] },
                  effective_at: { type: ['string', 'null'] },
                  currency: { type: ['string', 'null'] },
                  is_accreditation_assertion: { type: 'boolean' },
                },
                required: [
                  'kind',
                  'statement',
                  'source_field_path',
                  'population',
                  'effective_at',
                  'currency',
                  'is_accreditation_assertion',
                ],
              },
            },
            unable_to_extract: { type: 'boolean' },
            abstain_reason: { type: ['string', 'null'] },
          },
          required: ['candidates', 'unable_to_extract', 'abstain_reason'],
        },
      },
    ],
    tool_choice: { type: 'tool', name: EXTRACTION_TOOL_NAME },
  });

  const toolUse = response.content.find(
    (block): block is Extract<typeof block, { type: 'tool_use' }> => block.type === 'tool_use',
  );
  if (!toolUse) {
    // Fail-safe per §3.0.1: no structured output means no basis to publish
    // anything. Treat exactly like an explicit abstention.
    return { candidates: [], unable_to_extract: true, abstain_reason: 'Model returned no tool_use block.' };
  }
  return extractionResultSchema.parse(toolUse.input);
}

// ---------------------------------------------------------------------------
// Step 8 helper — one data_quality_flag row
// ---------------------------------------------------------------------------

async function insertDataQualityFlag(
  client: PoolClient,
  args: {
    sourceId: string | null;
    severity: 'INFO' | 'WARNING' | 'CRITICAL';
    reason: string;
    charterClause: string;
    detail: Record<string, unknown>;
  },
) {
  await client.query(
    `INSERT INTO obs.data_quality_flag
       (id, flag_kind, source_id, entity_type, entity_id, severity, reason,
        detected_at, detected_by, charter_clause, detail)
     VALUES ($1, 'MISSING_SOURCE', $2, 'provider_submission', $3, $4, $5, now(), $6, $7, $8::jsonb)`,
    [
      randomUUID(),
      args.sourceId,
      args.detail.submissionId,
      args.severity,
      args.reason,
      JOB_IDENTITY,
      args.charterClause,
      JSON.stringify(args.detail),
    ],
  );
}

// ---------------------------------------------------------------------------
// The handler
// ---------------------------------------------------------------------------

export async function extractClaimsFromProviderSubmission(
  job: PgBoss.Job<JobInput>,
  boss: PgBoss,
): Promise<{ status: 'no_op' | 'abstained' | 'claims_created'; claimIds: string[] }> {
  const { submissionId } = jobInputSchema.parse(job.data);

  const client = await pgPool.connect();
  try {
    await client.query('BEGIN');

    // ---- Step 1: load and lock the submission ------------------------------
    const submissionResult = await client.query<ProviderSubmissionRow>(
      `SELECT id, provider_org_id, submitted_by, submitted_at, payload, content_hash, state, data_region
         FROM domain.provider_submission
        WHERE id = $1
        FOR UPDATE`,
      [submissionId],
    );
    const submission = submissionResult.rows[0];
    if (!submission) {
      await client.query('ROLLBACK');
      throw new Error(`provider_submission ${submissionId} does not exist — permanent failure, do not retry.`);
    }
    if (submission.state !== 'PARSED') {
      // Idempotency under pg-boss's at-least-once delivery: this submission
      // was already handled (or is mid-flight) by a previous attempt.
      await client.query('COMMIT');
      return { status: 'no_op', claimIds: [] };
    }

    // ---- Step 2: load the provider org for publisher/jurisdiction ---------
    const orgResult = await client.query<ProviderOrgRow>(
      `SELECT id, legal_name, country FROM principal.provider_org WHERE id = $1`,
      [submission.provider_org_id],
    );
    const providerOrg = orgResult.rows[0];
    if (!providerOrg) {
      await client.query('ROLLBACK');
      throw new Error(`principal.provider_org ${submission.provider_org_id} not found — permanent failure.`);
    }

    // ---- Step 3: call the model ---------------------------------------------
    const extraction = await callExtractionModel(submission.payload);

    // ---- Step 4: deterministic validation -----------------------------------
    const accepted: Array<{
      candidate: CandidateClaim;
      confidence: number;
      requiresMarker: boolean;
    }> = [];
    const rejected: Array<{ candidate: CandidateClaim; reason: string }> = [];

    for (const candidate of extraction.candidates) {
      if (!isStructurallyAnchored(candidate, submission.payload)) {
        rejected.push({
          candidate,
          reason: `source_field_path "${candidate.source_field_path}" does not resolve to a payload value the statement literally contains.`,
        });
        continue;
      }
      // §1.9.7: population-dependent claim kinds may not publish with a null
      // population — enforced here AND by evidence.claim's own pop_required
      // CHECK, belt-and-braces per the project's own stated pattern.
      if (candidate.kind === 'PROVIDER_OUTCOME' && !candidate.population) {
        rejected.push({
          candidate,
          reason: 'HP-ESC 1.9.7: PROVIDER_OUTCOME claim has no population; population is not optional.',
        });
        continue;
      }
      const requiresMarker = requiresClinicalCapAndMarker({
        kind: candidate.kind,
        isAccreditationAssertion: candidate.is_accreditation_assertion,
      });
      const confidence = computeTier4Confidence({
        kind: candidate.kind,
        isAccreditationAssertion: candidate.is_accreditation_assertion,
      });
      accepted.push({ candidate, confidence, requiresMarker });
    }

    // ---- Step 5: total abstention -------------------------------------------
    if (accepted.length === 0) {
      const reason =
        extraction.abstain_reason ??
        (rejected.length > 0
          ? `All ${rejected.length} candidate(s) failed structural validation against the submitted payload.`
          : 'Model returned no extractable candidates.');
      await insertDataQualityFlag(client, {
        sourceId: null,
        severity: 'WARNING',
        reason: `Submission ${submissionId}: no claim could be sourced — ${reason}`,
        charterClause: 'HP-ESC 3.0.1',
        detail: { submissionId, rejected, modelAbstainReason: extraction.abstain_reason },
      });
      await client.query(
        `UPDATE domain.provider_submission SET state = 'REJECTED', rejected_reason = $2 WHERE id = $1`,
        [submissionId, reason.slice(0, 2000)],
      );
      await client.query('COMMIT');
      return { status: 'abstained', claimIds: [] };
    }

    // ---- Step 6: evidence_source + claim + claim_source, and enqueue -------
    const now = new Date();
    const evidenceSourceId = randomUUID();
    const portalBaseUrl = process.env.PROVIDER_PORTAL_BASE_URL ?? 'https://provider.healthplus.internal';

    await client.query(
      `INSERT INTO evidence.evidence_source
         (id, tier, source_type, publisher, title, url, doi, published_at, effective_at,
          retrieved_at, last_verified_at, data_year, version, jurisdiction, population,
          evidence_level, language, retracted, coi_declared, content_hash)
       VALUES
         ($1, 'TIER_4', 'provider_portal_submission', $2, $3, $4, NULL, $5, $5,
          $6, $6, $7, NULL, $8, NULL,
          NULL, 'en', false, NULL, $9)`,
      [
        evidenceSourceId,
        providerOrg.legal_name,
        `Provider submission ${submission.id} — ${providerOrg.legal_name}`,
        `${portalBaseUrl}/submissions/${submission.id}`,
        submission.submitted_at,
        now,
        submission.submitted_at.getUTCFullYear(),
        providerOrg.country,
        submission.content_hash,
      ],
    );

    const claimIds: string[] = [];
    for (const { candidate, confidence, requiresMarker } of accepted) {
      let expiresAt: Date | null = null;
      if (KINDS_REQUIRING_EXPIRY.has(candidate.kind)) {
        const decayResult = await client.query<ClaimKindDecayRow>(
          `SELECT half_life_days, hard_expiry_days
             FROM evidence.claim_kind_decay
            WHERE kind = $1 AND effective_from <= now()
            ORDER BY effective_from DESC
            LIMIT 1`,
          [candidate.kind],
        );
        const decay = decayResult.rows[0];
        if (!decay || decay.hard_expiry_days === null) {
          // §1.7.1/§3.3.8: a COST-class claim MUST decay. If the policy row
          // can't tell us when, we cannot construct a compliant expires_at —
          // abstain on this one candidate rather than inventing a horizon.
          rejected.push({
            candidate,
            reason: 'No adopted claim_kind_decay row with a hard_expiry_days for this kind — cannot set required expires_at.',
          });
          continue;
        }
        expiresAt = new Date(submission.submitted_at.getTime() + decay.hard_expiry_days * 86_400_000);
      }

      const statement = requiresMarker ? `${candidate.statement} ${SELF_REPORT_MARKER}` : candidate.statement;

      const claimId = randomUUID();
      await client.query(
        `INSERT INTO evidence.claim (id, kind, statement, jurisdiction, population, effective_at, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [
          claimId,
          candidate.kind,
          statement,
          providerOrg.country,
          candidate.population,
          candidate.effective_at ?? submission.submitted_at,
          expiresAt,
        ],
      );

      await client.query(
        `INSERT INTO evidence.claim_source
           (claim_id, source_id, confidence, computed_by, policy_version, modifier_trail, computed_at)
         VALUES ($1, $2, $3, $4, $5, $6::jsonb, now())`,
        [
          claimId,
          evidenceSourceId,
          confidence,
          confidenceSourceFor(candidate.kind),
          'HP-SCHEMA-001 v0.5 / claimKindPolicy v1',
          JSON.stringify(
            requiresMarker
              ? [{ step: 'HP-ESC-1.4.4-CLINICAL-CAP', to: confidence }]
              : [{ step: 'HP-ESC-1.4.3-TIER4-DEFAULT', to: confidence }],
          ),
        ],
      );

      // Transactional enqueue (ADR-001 §3.2 point 7): the follow-on "embed"
      // stage job is created through the SAME client, via pg-boss's `db`
      // adapter option, so it commits or rolls back with the claim insert
      // above — a claim can never exist without its embedding job having
      // been durably scheduled, and vice versa.
      await boss.send(
        EMBED_CLAIM_QUEUE_NAME,
        { claimId, sourceId: evidenceSourceId },
        { db: fromPgClient(client) },
      );

      claimIds.push(claimId);
    }

    // ---- Step 7: per-candidate abstentions among an otherwise-successful run
    for (const { candidate, reason } of rejected) {
      await insertDataQualityFlag(client, {
        sourceId: accepted.length > 0 ? evidenceSourceId : null,
        severity: 'WARNING',
        reason: `Submission ${submissionId}, candidate kind=${candidate.kind}: ${reason}`,
        charterClause: 'HP-ESC 3.0.3',
        detail: { submissionId, candidate },
      });
    }

    if (claimIds.length === 0) {
      // Every accepted candidate lost its expiry check in step 6 — this is
      // functionally a total abstention discovered late; treat it as one.
      await insertDataQualityFlag(client, {
        sourceId: evidenceSourceId,
        severity: 'WARNING',
        reason: `Submission ${submissionId}: all candidates ultimately unpublishable (see individual flags above).`,
        charterClause: 'HP-ESC 3.0.1',
        detail: { submissionId },
      });
      await client.query(
        `UPDATE domain.provider_submission SET state = 'REJECTED', rejected_reason = $2 WHERE id = $1`,
        [submissionId, 'All candidates failed validation after decay-policy lookup.'],
      );
      await client.query('COMMIT');
      return { status: 'abstained', claimIds: [] };
    }

    // ---- Step 8: close out the submission and commit ------------------------
    await client.query(`UPDATE domain.provider_submission SET state = 'CLAIMS_CREATED' WHERE id = $1`, [
      submissionId,
    ]);
    await client.query('COMMIT');
    return { status: 'claims_created', claimIds };
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}

/** Registers this task's handler on a started PgBoss instance. */
export async function registerExtractClaimsFromProviderSubmissionWorker(boss: PgBoss): Promise<void> {
  await boss.createQueue(QUEUE_NAME);
  await boss.work<JobInput>(QUEUE_NAME, async ([job]) => {
    await extractClaimsFromProviderSubmission(job, boss);
  });
}
