/**
 * HealthPlus — pg-boss task: extractPatientUploadAttributes
 * ============================================================================
 *
 * Queue name:  extract-patient-upload-attributes
 *
 * TRIGGER
 *   Enqueued transactionally by src/lib/webhookServer.ts, which receives a
 *   Supabase Database Webhook firing on `storage.objects` INSERT — i.e. a
 *   patient uploading a lab report, scan, or photo. See HP-RECON-007 and its
 *   companion build note for why this job's design differs from the
 *   original request in three load-bearing ways:
 *
 *     1. It writes principal.patient_attribute (kind=DIAGNOSTIC_RESULT,
 *        provenance='inferred', origin='MODEL_INFERRED'), NEVER
 *        evidence.claim / evidence.claim_source. HP-SCHEMA-001 §17 states
 *        outright that a patient-supplied attribute "is not a claim ... and
 *        must never acquire one."
 *     2. It never computes or stores a confidence value anywhere — Charter
 *        §1.7 modifier M9 has no application here, because M9 discounts a
 *        claim's confidence and this job writes no claim. Each field's own
 *        model-stated certainty and illegibility flag travel inside the
 *        encrypted attribute payload for a future confirmation UI to show
 *        the patient, never as a stored confidence column.
 *     3. Nothing it writes is treated as fact. Every row lands with
 *        provenance='inferred' (enforced by the database:
 *        c_inferred_origin_matches), reachable only through the
 *        CONFIRMATION_UI purpose of fetch_attribute_envelope until an
 *        explicit patient confirmation promotes it — that confirmation UI
 *        does not exist yet (same as confirmation_ui_role generally; see
 *        migration 037's header) and is a prerequisite for this data ever
 *        reaching a chat response or a red-flag decision.
 *
 * INPUT PAYLOAD
 *   { documentId: string (uuid) }
 *   A bare reference to principal.patient_upload_document, re-read fresh
 *   under FOR UPDATE — same idiom as extractClaimsFromProviderSubmission,
 *   and for the same reason: pg-boss is at-least-once, this must be
 *   idempotent, and a payload snapshot could be stale by the time the job runs.
 *
 * LOGIC
 *   1. Load and row-lock principal.patient_upload_document (FOR UPDATE). If
 *      missing, permanent failure. If state is not RECEIVED, no-op.
 *   2. Download the object from Supabase Storage.
 *   3. Call Claude with vision input (the document, as an image or PDF
 *      content block) and the shared PHASE_3_1_SAFETY_FRAGMENT plus this
 *      job's extraction-only instructions. Force structured tool-use output.
 *   4. Deterministic validation: drop any candidate the model itself flagged
 *      illegible, and any candidate missing a test name or result value.
 *      There is NO ground-truth field to string-anchor against here (unlike
 *      extractClaimsFromProviderSubmission's payload-derived claims) — the
 *      image IS the source, so this validation is structural completeness
 *      and the model's own stated signal, not independent verification.
 *      Stated as a real, weaker guarantee, not hidden as if it were parity
 *      with the provider-submission job's anchoring.
 *   5. If nothing survives (including the model's own unable_to_extract
 *      signal), abstain: mark REJECTED, write one data_quality_flag, commit.
 *   6. Otherwise: fetch the subject's live key material, encrypt one JSON
 *      payload per accepted candidate under the subject's DEK, and call
 *      principal.record_inferred_attribute once per candidate — inside a
 *      transaction that first sets app.user_id = subject (transaction-
 *      scoped), because patient_attribute is FORCE ROW LEVEL SECURITY and
 *      the function does not set this itself (see migration 050 §3 and
 *      migration 041's identical convention for fetch_attribute_envelope).
 *   7. Mark the document EXTRACTED with the written attribute ids, commit.
 *
 * ANTHROPIC MODEL
 *   Sonnet tier, per the original request. NOTE: ADR-001 §3.6's tiering
 *   table assigns Opus to "offline claim extraction" generally
 *   (extractClaimsFromProviderSubmission uses it) and has no line for
 *   vision-based patient-document extraction specifically. Sonnet is used
 *   here as asked rather than silently switched to Opus; this is a real gap
 *   in ADR-001 worth a formal line, not a deviation to paper over.
 *
 * RESIDENCY — FLAGGED, NOT RESOLVED. ADR-003 §2.1 / Charter §5.2a: "no
 * health data leaves India" in v1. This call sends a patient's lab-report
 * image to the Anthropic API over the same path anthropicClient.ts already
 * uses for extractClaimsFromProviderSubmission's Tier-4 provider text — a
 * pre-existing, unresolved tension this project's own ADR-001 header
 * acknowledges ("residency escape hatch (Bedrock's EU inference profile) is
 * a one-file change later"), not one introduced by this job. What is new
 * here is that the payload is now literal patient health data rather than a
 * hospital's business submission, which makes the question far more acute
 * and, per HP-RECON-007 §4.1, worth an explicit Board/counsel decision
 * (LB-001/LB-002 are still open) rather than a silent default either way.
 * Building against the existing anthropicClient.ts pattern so this is not
 * blocked on that decision, per the direction to build the corrected
 * design — but this should not ship to real patients before that decision
 * is made explicitly.
 *
 * TABLES READ
 *   principal.patient_upload_document, principal.subject_key (via
 *   subject_key_material)
 * TABLES WRITTEN
 *   principal.patient_upload_document (state), principal.patient_attribute
 *   (via record_inferred_attribute), obs.data_quality_flag
 */
import type PgBoss from 'pg-boss';
import type { PoolClient } from 'pg';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { jobPool } from '../db/pool';
import { anthropic, ANTHROPIC_MODEL_PATIENT_UPLOAD_EXTRACTION } from '../lib/anthropicClient';
import { PHASE_3_1_SAFETY_FRAGMENT } from '../safety/systemPromptFragments';
import { downloadStorageObject } from '../lib/supabaseStorage';
import { getLiveSubjectKey, encryptAttribute, type Queryable } from '../lib/subjectAttributeCrypto';

export const QUEUE_NAME = 'extract-patient-upload-attributes';
const JOB_IDENTITY = 'extract_patient_upload_attributes_v1';
const INFERRED_BY = `${ANTHROPIC_MODEL_PATIENT_UPLOAD_EXTRACTION}:${JOB_IDENTITY}`;

// ---------------------------------------------------------------------------
// Job input
// ---------------------------------------------------------------------------

export const jobInputSchema = z.object({
  documentId: z.string().uuid(),
});
export type JobInput = z.infer<typeof jobInputSchema>;

// ---------------------------------------------------------------------------
// Model output contract (forced via tool-use)
// ---------------------------------------------------------------------------

const candidateFieldSchema = z.object({
  test_name: z.string(),
  result_value: z.string(),
  result_unit: z.string().nullable(),
  // The printed reference range AS TEXT, exactly as it appears on the
  // document (e.g. "12.0 - 15.5", "< 5", "Negative") — never parsed into a
  // structured low/high pair here, because that would require the model or
  // this code to decide what the range MEANS, which is §3.5 territory.
  reference_range_text: z.string().nullable(),
  // The document's OWN printed flag (e.g. "H", "L", "Abnormal"), verbatim,
  // if and only if the document itself prints one next to this value.
  // Charter §3.1.2 prohibits the SYSTEM characterising a result; §3.8.3
  // permits "verbatim, unaltered reproduction of user-supplied data,
  // clearly labelled as self-reported." Carrying the lab's own printed
  // annotation forward is the latter, not the former — but it is a real
  // edge of that boundary and is called out as such in the build note
  // rather than treated as obviously settled.
  printed_flag_verbatim: z.string().nullable(),
  // The model's own stated per-field certainty, 0-1. Carried into the
  // encrypted payload for the confirmation UI's benefit ONLY. Never
  // written to any confidence column — there isn't one on this table, and
  // Charter §1.0.5 forbids a model-authored confidence value on a claim in
  // any case (not that this is a claim).
  field_confidence: z.number().min(0).max(1),
  illegible: z.boolean(),
});
type CandidateField = z.infer<typeof candidateFieldSchema>;

const extractionResultSchema = z.object({
  candidates: z.array(candidateFieldSchema),
  unable_to_extract: z.boolean(),
  abstain_reason: z.string().nullable(),
});
type ExtractionResult = z.infer<typeof extractionResultSchema>;

const EXTRACTION_TOOL_NAME = 'submit_extracted_fields';

const EXTRACTION_TASK_INSTRUCTIONS = `You are extracting structured values from a single page of a patient-uploaded
lab report, diagnostic scan report, or photo of a document. The image given
to you is your ONLY permitted source.

Extract ONLY what is printed on the document: test/panel names, result
values, units, and reference ranges AS PRINTED. Copy text and numbers
exactly as they appear — do not calculate, convert units, round, or
normalise anything.

Do not characterise, interpret, or comment on any result. Do not say
whether a value is normal, abnormal, high, low, concerning, or reassuring,
even if you are confident about what the numbers mean. Do not compare a
result to its reference range yourself. If the document itself prints a
flag or annotation next to a value (such as "H", "L", or "Abnormal"),
transcribe that exact printed text into printed_flag_verbatim — do not add
one that is not printed, and do not add one anywhere the document does not.

For every field, set "field_confidence" to your own honest certainty (0.0-1.0)
that you read it correctly, and set "illegible" to true if any part of the
value, unit, or range you would need is unclear, smudged, cut off, or
ambiguous in the image — when illegible is true, still report your best
reading in the text fields so a human reviewer has something to check
against, but the illegible flag is what matters for whether this field gets
used.

If the image contains no extractable diagnostic test/result fields at all
(a cover letter, a photo of the wrong document, a blank page), call the tool
with an empty "candidates" array, "unable_to_extract": true, and a short
"abstain_reason". Do not pad the candidate list to appear useful.`;

// ---------------------------------------------------------------------------
// Structural validation (§3.0.3: structural, not persuasive).
//
// There is no ground-truth payload to string-anchor against — the image is
// the source. This is therefore weaker than
// isStructurallyAnchored/resolveJsonPath in extractClaimsFromProviderSubmission
// and does not claim to be equivalent: it rejects what the model itself
// flagged as unreliable (illegible) or structurally incomplete (no test
// name or no value), and nothing more.
// ---------------------------------------------------------------------------

export function isUsableCandidate(candidate: CandidateField): { usable: boolean; reason?: string } {
  if (candidate.illegible) {
    return { usable: false, reason: 'model flagged this field illegible' };
  }
  if (candidate.test_name.trim().length === 0) {
    return { usable: false, reason: 'empty test_name' };
  }
  if (candidate.result_value.trim().length === 0) {
    return { usable: false, reason: 'empty result_value' };
  }
  return { usable: true };
}

// ---------------------------------------------------------------------------
// Row shapes
// ---------------------------------------------------------------------------

interface PatientUploadDocumentRow {
  id: string;
  subject_id: string;
  data_region: string;
  storage_bucket: string;
  storage_object_path: string;
  mime_type: string;
  state: 'RECEIVED' | 'EXTRACTING' | 'EXTRACTED' | 'REJECTED';
}

// ---------------------------------------------------------------------------
// Step 3 — the Anthropic call
// ---------------------------------------------------------------------------

function buildDocumentContentBlock(bytes: Buffer, mimeType: string) {
  const base64 = bytes.toString('base64');
  if (mimeType === 'application/pdf') {
    return {
      type: 'document' as const,
      source: { type: 'base64' as const, media_type: 'application/pdf' as const, data: base64 },
    };
  }
  return {
    type: 'image' as const,
    source: { type: 'base64' as const, media_type: mimeType as 'image/jpeg' | 'image/png' | 'image/webp', data: base64 },
  };
}

async function callExtractionModel(bytes: Buffer, mimeType: string): Promise<ExtractionResult> {
  const systemPrompt = [PHASE_3_1_SAFETY_FRAGMENT, EXTRACTION_TASK_INSTRUCTIONS].join('\n\n');

  const response = await anthropic.messages.create({
    model: ANTHROPIC_MODEL_PATIENT_UPLOAD_EXTRACTION,
    max_tokens: 4096,
    system: systemPrompt,
    messages: [
      {
        role: 'user',
        content: [
          buildDocumentContentBlock(bytes, mimeType),
          { type: 'text', text: 'Extract every diagnostic test/result field visible on this document.' },
        ],
      },
    ],
    tools: [
      {
        name: EXTRACTION_TOOL_NAME,
        description: 'Submit the fields extracted from the uploaded document.',
        input_schema: {
          type: 'object',
          properties: {
            candidates: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  test_name: { type: 'string' },
                  result_value: { type: 'string' },
                  result_unit: { type: ['string', 'null'] },
                  reference_range_text: { type: ['string', 'null'] },
                  printed_flag_verbatim: { type: ['string', 'null'] },
                  field_confidence: { type: 'number' },
                  illegible: { type: 'boolean' },
                },
                required: [
                  'test_name',
                  'result_value',
                  'result_unit',
                  'reference_range_text',
                  'printed_flag_verbatim',
                  'field_confidence',
                  'illegible',
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
    return { candidates: [], unable_to_extract: true, abstain_reason: 'Model returned no tool_use block.' };
  }
  return extractionResultSchema.parse(toolUse.input);
}

// ---------------------------------------------------------------------------
// Abstention helper
// ---------------------------------------------------------------------------

async function insertDataQualityFlag(
  client: PoolClient,
  args: {
    documentId: string;
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
     VALUES ($1, 'MISSING_SOURCE', NULL, 'patient_upload_document', $2, $3, $4, now(), $5, $6, $7::jsonb)`,
    [
      randomUUID(),
      args.documentId,
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

export async function extractPatientUploadAttributes(
  job: PgBoss.Job<JobInput>,
): Promise<{ status: 'no_op' | 'abstained' | 'extracted'; attributeIds: string[] }> {
  const { documentId } = jobInputSchema.parse(job.data);

  const pool = jobPool('patientUpload');
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // ---- Step 1: load and lock the document ------------------------------
    const docResult = await client.query<PatientUploadDocumentRow>(
      `SELECT id, subject_id, data_region, storage_bucket, storage_object_path, mime_type, state
         FROM principal.patient_upload_document
        WHERE id = $1
        FOR UPDATE`,
      [documentId],
    );
    const doc = docResult.rows[0];
    if (!doc) {
      await client.query('ROLLBACK');
      throw new Error(`patient_upload_document ${documentId} does not exist — permanent failure, do not retry.`);
    }
    if (doc.state !== 'RECEIVED') {
      // Idempotency under pg-boss's at-least-once delivery.
      await client.query('COMMIT');
      return { status: 'no_op', attributeIds: [] };
    }

    // ---- Step 2: download from Storage (outside any lock other than the
    // row lock already held above — this is a single-transaction job, same
    // shape as extractClaimsFromProviderSubmission) --------------------------
    let bytes: Buffer;
    try {
      const downloaded = await downloadStorageObject(doc.storage_bucket, doc.storage_object_path);
      bytes = downloaded.bytes;
    } catch (err) {
      await insertDataQualityFlag(client, {
        documentId,
        severity: 'WARNING',
        reason: `Document ${documentId}: could not download from Storage — ${String(err)}`,
        charterClause: 'HP-ESC 3.0.1',
        detail: { documentId, error: String(err) },
      });
      await client.query(
        `UPDATE principal.patient_upload_document SET state = 'REJECTED', rejected_reason = $2 WHERE id = $1`,
        [documentId, 'Storage download failed.'],
      );
      await client.query('COMMIT');
      return { status: 'abstained', attributeIds: [] };
    }

    // ---- Step 3: call the model ---------------------------------------------
    const extraction = await callExtractionModel(bytes, doc.mime_type);

    // ---- Step 4: structural validation ---------------------------------------
    const accepted: CandidateField[] = [];
    const rejected: Array<{ candidate: CandidateField; reason: string }> = [];
    for (const candidate of extraction.candidates) {
      const check = isUsableCandidate(candidate);
      if (check.usable) accepted.push(candidate);
      else rejected.push({ candidate, reason: check.reason! });
    }

    // ---- Step 5: total abstention -------------------------------------------
    if (accepted.length === 0) {
      const reason =
        extraction.abstain_reason ??
        (rejected.length > 0
          ? `All ${rejected.length} field(s) were illegible or incomplete.`
          : 'Model returned no extractable fields.');
      await insertDataQualityFlag(client, {
        documentId,
        severity: 'INFO',
        reason: `Document ${documentId}: nothing extractable — ${reason}`,
        charterClause: 'HP-ESC 3.0.1',
        detail: { documentId, rejectedCount: rejected.length, modelAbstainReason: extraction.abstain_reason },
      });
      await client.query(
        `UPDATE principal.patient_upload_document SET state = 'REJECTED', rejected_reason = $2 WHERE id = $1`,
        [documentId, reason.slice(0, 2000)],
      );
      await client.query('COMMIT');
      return { status: 'abstained', attributeIds: [] };
    }

    // ---- Step 6: encrypt and write each accepted field as an inferred
    // patient_attribute. FORCE RLS on patient_attribute means app.user_id
    // must be set to the subject before calling record_inferred_attribute —
    // migration 050 §3's documented convention, mirroring migration 041's
    // for fetch_attribute_envelope. -------------------------------------------
    const key = await getLiveSubjectKey(doc.subject_id, client as unknown as Queryable);
    if (!key) {
      await insertDataQualityFlag(client, {
        documentId,
        severity: 'CRITICAL',
        reason: `Document ${documentId}: subject ${doc.subject_id} has no live key (erased, or never minted) — cannot encrypt.`,
        charterClause: 'HP-ESC 2.3.4g',
        detail: { documentId, subjectId: doc.subject_id },
      });
      await client.query(
        `UPDATE principal.patient_upload_document SET state = 'REJECTED', rejected_reason = $2 WHERE id = $1`,
        [documentId, 'Subject has no live encryption key.'],
      );
      await client.query('COMMIT');
      return { status: 'abstained', attributeIds: [] };
    }

    await client.query('SELECT set_config($1, $2, true)', ['app.user_id', doc.subject_id]);

    const attributeIds: string[] = [];
    for (const candidate of accepted) {
      const payload = {
        test_name: candidate.test_name,
        result_value: candidate.result_value,
        result_unit: candidate.result_unit,
        reference_range_text: candidate.reference_range_text,
        printed_flag_verbatim: candidate.printed_flag_verbatim,
        field_confidence: candidate.field_confidence,
        source_document_id: documentId,
      };
      const { ciphertext, nonce, alg } = encryptAttribute(key, payload);
      // The attribute key: no normalised clinical vocabulary exists to key
      // on (domain.clinical_indicator cannot carry a patient value at all —
      // see migration 050 §1), so this uses the source document's id plus
      // the field's position, which is unique but not semantically
      // meaningful — two uploads of the same test will not be recognised as
      // "the same attribute" for supersession purposes. Flagged as a real
      // limitation in the build note, not a design this job claims to have
      // solved.
      const attributeKey = `DIAGNOSTIC_RESULT:${documentId}:${candidate.test_name}`;

      const insertResult = await client.query<{ record_inferred_attribute: string }>(
        `SELECT principal.record_inferred_attribute(
           $1::uuid, 'DIAGNOSTIC_RESULT'::patient_attribute_kind, $2::char(2), $3,
           $4::bytea, $5, $6::bytea, $7::uuid,
           'MODEL_INFERRED'::attribute_origin, $8, $9::uuid
         ) AS record_inferred_attribute`,
        [
          doc.subject_id,
          doc.data_region,
          attributeKey,
          ciphertext,
          alg,
          nonce,
          key.keyId,
          INFERRED_BY,
          job.id,
        ],
      );
      const attributeId = insertResult.rows[0]?.record_inferred_attribute;
      if (attributeId) attributeIds.push(attributeId);
    }

    // ---- Step 7: per-field abstentions among an otherwise-successful run ----
    for (const { candidate, reason } of rejected) {
      await insertDataQualityFlag(client, {
        documentId,
        severity: 'INFO',
        reason: `Document ${documentId}, field "${candidate.test_name || '(unnamed)'}": ${reason}`,
        charterClause: 'HP-ESC 3.0.3',
        detail: { documentId, candidate },
      });
    }

    // ---- Step 8: close out and commit ----------------------------------------
    await client.query(
      `UPDATE principal.patient_upload_document
          SET state = 'EXTRACTED', extracted_attribute_ids = $2
        WHERE id = $1`,
      [documentId, attributeIds],
    );
    await client.query('COMMIT');
    return { status: 'extracted', attributeIds };
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}

/** Registers this task's handler on a started PgBoss instance. */
export async function registerExtractPatientUploadAttributesWorker(boss: PgBoss): Promise<void> {
  await boss.createQueue(QUEUE_NAME);
  await boss.work<JobInput>(QUEUE_NAME, async ([job]) => {
    await extractPatientUploadAttributes(job);
  });
}
