/**
 * Charter-clause-named tests for extractClaimsFromProviderSubmission.
 *
 * Per Annex A.8, every application-layer emission gate needs a unit test
 * named for the clause it enforces. This suite is named for HP-ESC §3.3.1
 * ("MUST NOT output any price, package cost, fee, deposit, or total not
 * drawn from a persisted, sourced, in-date price record") because COST is
 * this job's sharpest fabrication risk: a hospital's own submission is the
 * kind of self-interested Tier 4 input §1.4.2 exists to describe, and a
 * price is exactly the figure §3.3 exists to keep un-fabricated.
 *
 * Both required cases live in this one suite:
 *   - happy path: a COST candidate that genuinely anchors to a payload field
 *     is published, sourced, Tier-4-confidence-scored by code (never by the
 *     model), and its follow-on embed job is enqueued in the same DB
 *     transaction as the claim insert.
 *   - abstention: a COST candidate whose stated value cannot be verified
 *     against the payload is rejected, no claim or evidence_source is
 *     written, a data_quality_flag records why, and the submission is
 *     marked REJECTED rather than silently dropped or guessed at.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

// ---- mock the Postgres pool -------------------------------------------------
type QueryHandler = (values: unknown[]) => { rows: unknown[] };

class FakeClient {
  public calls: Array<{ text: string; values: unknown[] }> = [];
  constructor(private readonly handlers: Array<[string, QueryHandler]>) {}

  async query(text: string, values: unknown[] = []) {
    this.calls.push({ text, values });
    const match = this.handlers.find(([needle]) => text.includes(needle));
    return match ? match[1](values) : { rows: [] };
  }

  release() {
    /* no-op */
  }

  textsContaining(needle: string) {
    return this.calls.filter((c) => c.text.includes(needle));
  }
}

const mockPgPool = { connect: vi.fn() };
vi.mock('../db/pool', () => ({ pgPool: mockPgPool }));

// ---- mock the Anthropic client ---------------------------------------------
const mockMessagesCreate = vi.fn();
vi.mock('../lib/anthropicClient', () => ({
  anthropic: { messages: { create: (...args: unknown[]) => mockMessagesCreate(...args) } },
  ANTHROPIC_MODEL_CLAIM_EXTRACTION: 'claude-opus-4-5-test',
}));

// Imported AFTER the mocks above so the module under test picks them up.
const { extractClaimsFromProviderSubmission } = await import('./extractClaimsFromProviderSubmission');

// ---------------------------------------------------------------------------

const SUBMISSION_ID = '11111111-1111-1111-1111-111111111111';
const PROVIDER_ORG_ID = '22222222-2222-2222-2222-222222222222';

function providerSubmissionHandler(payload: unknown): [string, QueryHandler] {
  return [
    'FOR UPDATE',
    () => ({
      rows: [
        {
          id: SUBMISSION_ID,
          provider_org_id: PROVIDER_ORG_ID,
          submitted_by: 'user-1',
          submitted_at: new Date('2026-08-01T00:00:00Z'),
          payload,
          content_hash: 'hash-abc123',
          state: 'PARSED',
          data_region: 'IN',
        },
      ],
    }),
  ];
}

const providerOrgHandler: [string, QueryHandler] = [
  'FROM principal.provider_org',
  // `legal_name`, not `name` — the real principal.provider_org DDL is
  // (id, legal_name, country, status). This fake previously returned `name`,
  // matching the bug in the code rather than the schema, which is how a
  // passing test coexisted with a query that could never run.
  () => ({ rows: [{ id: PROVIDER_ORG_ID, legal_name: 'Apollo Test Hospital', country: 'IN' }] }),
];

const costDecayHandler: [string, QueryHandler] = [
  'FROM evidence.claim_kind_decay',
  () => ({ rows: [{ half_life_days: 90, hard_expiry_days: 180 }] }),
];

function toolUseResponse(input: unknown) {
  return { content: [{ type: 'tool_use', name: 'submit_candidate_claims', id: 'tool_1', input }] };
}

let mockBoss: { send: ReturnType<typeof vi.fn> };

beforeEach(() => {
  vi.clearAllMocks();
  mockBoss = { send: vi.fn().mockResolvedValue('job-id') };
});

describe('test_hp_esc_3_3_1_no_unsourced_cost_output', () => {
  it('happy path: a COST claim that anchors to the payload is published, Tier-4-scored by code, and its embed job is enqueued transactionally', async () => {
    const payload = {
      packages: [{ name: 'Cardiac Bypass Package', price_inr: 450000, currency: 'INR' }],
    };
    const fakeClient = new FakeClient([
      providerSubmissionHandler(payload),
      providerOrgHandler,
      costDecayHandler,
    ]);
    mockPgPool.connect.mockResolvedValue(fakeClient);

    mockMessagesCreate.mockResolvedValue(
      toolUseResponse({
        candidates: [
          {
            kind: 'COST',
            statement: 'Cardiac Bypass Package costs 450000 INR.',
            source_field_path: 'packages[0].price_inr',
            population: null,
            effective_at: null,
            currency: 'INR',
            is_accreditation_assertion: false,
          },
        ],
        unable_to_extract: false,
        abstain_reason: null,
      }),
    );

    const job = { id: 'job-1', data: { submissionId: SUBMISSION_ID } } as any;
    const result = await extractClaimsFromProviderSubmission(job, mockBoss as any);

    expect(result.status).toBe('claims_created');
    expect(result.claimIds).toHaveLength(1);

    // A real, resolvable source was written — Tier 4 fixed by construction,
    // never inferred from the model's output.
    const sourceInserts = fakeClient.textsContaining('INSERT INTO evidence.evidence_source');
    expect(sourceInserts).toHaveLength(1);
    expect(sourceInserts[0].text).toContain("'TIER_4'");

    // Confidence for the claim_source row came from code (claimKindPolicy),
    // not the model: HP-ESC §1.0.5's conf_not_llm guarantee, checked here at
    // the call-site rather than only trusting the DB CHECK constraint.
    const claimSourceInserts = fakeClient.textsContaining('INSERT INTO evidence.claim_source');
    expect(claimSourceInserts).toHaveLength(1);
    const [, , confidence, computedBy] = claimSourceInserts[0].values;
    expect(confidence).toBe(0.55); // TIER_4_DEFAULT_CONFIDENCE — COST is not a clinical-cap kind
    expect(computedBy).not.toBe('MODEL');
    expect(String(computedBy)).toContain('TIER4_INLINE_POLICY_V1:COST');

    // The submission was closed out correctly.
    const stateUpdates = fakeClient.textsContaining('UPDATE domain.provider_submission');
    expect(stateUpdates).toHaveLength(1);
    expect(stateUpdates[0].text).toContain('CLAIMS_CREATED');

    // The follow-on embed job was enqueued through the SAME transaction
    // client (pg-boss's `db` adapter), not a bare boss.send() outside it —
    // this is the transactional-enqueue guarantee under test.
    expect(mockBoss.send).toHaveBeenCalledTimes(1);
    const [queueName, sendPayload, opts] = mockBoss.send.mock.calls[0];
    expect(queueName).toBe('embed-claim');
    expect(sendPayload).toMatchObject({ claimId: result.claimIds[0] });
    expect(opts.db).toBeDefined();
    expect(typeof opts.db.executeSql).toBe('function');

    // No abstention flag was written on the happy path.
    expect(fakeClient.textsContaining('INSERT INTO obs.data_quality_flag')).toHaveLength(0);
  });

  it('abstains without inserting a claim when the cost value cannot be verified against the payload', async () => {
    const payload = {
      packages: [{ name: 'Cardiac Bypass Package', price_inr: 450000 }],
    };
    const fakeClient = new FakeClient([providerSubmissionHandler(payload), providerOrgHandler, costDecayHandler]);
    mockPgPool.connect.mockResolvedValue(fakeClient);

    // The model cites a real field but asserts a different number than the
    // payload actually contains — exactly the class of error §3.0.2 names
    // ("rounding a stale figure", "plausible-sounding placeholder").
    mockMessagesCreate.mockResolvedValue(
      toolUseResponse({
        candidates: [
          {
            kind: 'COST',
            statement: 'Cardiac Bypass Package costs 500000 INR.',
            source_field_path: 'packages[0].price_inr',
            population: null,
            effective_at: null,
            currency: 'INR',
            is_accreditation_assertion: false,
          },
        ],
        unable_to_extract: false,
        abstain_reason: null,
      }),
    );

    const job = { id: 'job-2', data: { submissionId: SUBMISSION_ID } } as any;
    const result = await extractClaimsFromProviderSubmission(job, mockBoss as any);

    expect(result.status).toBe('abstained');
    expect(result.claimIds).toHaveLength(0);

    // §3.0.1/§3.0.3: no evidence_source, no claim, no claim_source — an
    // unverifiable figure is never coerced into a "close enough" record.
    expect(fakeClient.textsContaining('INSERT INTO evidence.evidence_source')).toHaveLength(0);
    expect(fakeClient.textsContaining('INSERT INTO evidence.claim_source')).toHaveLength(0);
    expect(fakeClient.textsContaining("INSERT INTO evidence.claim ")).toHaveLength(0);

    // The abstention is recorded, not silent.
    const flagInserts = fakeClient.textsContaining('INSERT INTO obs.data_quality_flag');
    expect(flagInserts).toHaveLength(1);
    expect(flagInserts[0].text).toContain('MISSING_SOURCE');
    // charter_clause is the 7th bound parameter in insertDataQualityFlag's INSERT.
    expect(flagInserts[0].values).toContain('HP-ESC 3.0.1');

    const stateUpdates = fakeClient.textsContaining('UPDATE domain.provider_submission');
    expect(stateUpdates).toHaveLength(1);
    expect(stateUpdates[0].text).toContain('REJECTED');

    // Never guess: no follow-on job is scheduled for content that was never
    // sourced in the first place.
    expect(mockBoss.send).not.toHaveBeenCalled();
  });

  it('no-ops idempotently if the submission has already moved past PARSED (pg-boss at-least-once redelivery)', async () => {
    const fakeClient = new FakeClient([
      [
        'FOR UPDATE',
        () => ({
          rows: [
            {
              id: SUBMISSION_ID,
              provider_org_id: PROVIDER_ORG_ID,
              submitted_by: 'user-1',
              submitted_at: new Date('2026-08-01T00:00:00Z'),
              payload: {},
              content_hash: 'hash-abc123',
              state: 'CLAIMS_CREATED',
              data_region: 'IN',
            },
          ],
        }),
      ],
    ]);
    mockPgPool.connect.mockResolvedValue(fakeClient);

    const job = { id: 'job-3', data: { submissionId: SUBMISSION_ID } } as any;
    const result = await extractClaimsFromProviderSubmission(job, mockBoss as any);

    expect(result.status).toBe('no_op');
    expect(mockMessagesCreate).not.toHaveBeenCalled();
    expect(mockBoss.send).not.toHaveBeenCalled();
  });
});
