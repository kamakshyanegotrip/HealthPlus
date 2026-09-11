/**
 * Charter-clause-named tests for extractPatientUploadAttributes.
 *
 * Modelled on extractClaimsFromProviderSubmission.test.ts's shape (a fake
 * `pg` client keyed on SQL substring, a mocked Anthropic client), but this
 * suite is narrower than that one's coverage on purpose — it is honest about
 * what it does and does not check, per the accompanying build note.
 *
 * Named for HP-ESC §3.8.1/§3.8.2: "a model- or rule-derived attribute can
 * never be born stated" and "an inferred value must never silently promote."
 * This job's single sharpest fabrication risk is NOT confidence (patient_
 * attribute has no confidence column to get wrong) — it is provenance: every
 * row this job writes must land as provenance='inferred', origin=
 * 'MODEL_INFERRED', unconfirmed, and never touch evidence.claim.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

type QueryHandler = (values: unknown[]) => { rows: unknown[]; rowCount?: number };

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

const mockPool = { connect: vi.fn() };
vi.mock('../db/pool', () => ({ jobPool: () => mockPool }));

const mockMessagesCreate = vi.fn();
vi.mock('../lib/anthropicClient', () => ({
  anthropic: { messages: { create: (...args: unknown[]) => mockMessagesCreate(...args) } },
  ANTHROPIC_MODEL_PATIENT_UPLOAD_EXTRACTION: 'claude-sonnet-4-5-test',
}));

const mockDownloadStorageObject = vi.fn();
vi.mock('../lib/supabaseStorage', () => ({
  downloadStorageObject: (...args: unknown[]) => mockDownloadStorageObject(...args),
  SUPPORTED_MIME_TYPES: new Set(['application/pdf', 'image/jpeg', 'image/png']),
}));

const mockGetLiveSubjectKey = vi.fn();
const mockEncryptAttribute = vi.fn();
vi.mock('../lib/subjectAttributeCrypto', () => ({
  getLiveSubjectKey: (...args: unknown[]) => mockGetLiveSubjectKey(...args),
  encryptAttribute: (...args: unknown[]) => mockEncryptAttribute(...args),
}));

const { extractPatientUploadAttributes } = await import('./extractPatientUploadAttributes');

// ---------------------------------------------------------------------------

const DOCUMENT_ID = '33333333-3333-3333-3333-333333333333';
const SUBJECT_ID = '44444444-4444-4444-4444-444444444444';

function documentHandler(state: string): [string, QueryHandler] {
  return [
    'FOR UPDATE',
    () => ({
      rows: [
        {
          id: DOCUMENT_ID,
          subject_id: SUBJECT_ID,
          data_region: 'IN',
          storage_bucket: 'patient-uploads',
          storage_object_path: `${SUBJECT_ID}/report.pdf`,
          mime_type: 'application/pdf',
          state,
        },
      ],
    }),
  ];
}

function toolUseResponse(input: unknown) {
  return { content: [{ type: 'tool_use', name: 'submit_extracted_fields', id: 'tool_1', input }] };
}

beforeEach(() => {
  vi.clearAllMocks();
  mockDownloadStorageObject.mockResolvedValue({ bytes: Buffer.from('fake-pdf-bytes'), contentType: 'application/pdf' });
  mockGetLiveSubjectKey.mockResolvedValue({ keyId: 'key-1', dek: Buffer.alloc(32) });
  mockEncryptAttribute.mockReturnValue({
    ciphertext: Buffer.from('ciphertext'),
    nonce: Buffer.from('nonce123456'),
    alg: 'AES-256-GCM',
  });
});

describe('test_hp_esc_3_8_2_inferred_never_born_stated', () => {
  it('happy path: a legible field is written via record_inferred_attribute with inferred/MODEL_INFERRED, and the document closes EXTRACTED', async () => {
    const fakeClient = new FakeClient([
      documentHandler('RECEIVED'),
      [
        'record_inferred_attribute',
        () => ({ rows: [{ record_inferred_attribute: 'attr-1' }] }),
      ],
    ]);
    mockPool.connect.mockResolvedValue(fakeClient);

    mockMessagesCreate.mockResolvedValue(
      toolUseResponse({
        candidates: [
          {
            test_name: 'Hemoglobin',
            result_value: '13.2',
            result_unit: 'g/dL',
            reference_range_text: '12.0 - 15.5',
            printed_flag_verbatim: null,
            field_confidence: 0.95,
            illegible: false,
          },
        ],
        unable_to_extract: false,
        abstain_reason: null,
      }),
    );

    const job = { id: 'job-1', data: { documentId: DOCUMENT_ID } } as any;
    const result = await extractPatientUploadAttributes(job);

    expect(result.status).toBe('extracted');
    expect(result.attributeIds).toEqual(['attr-1']);

    // Provenance is fixed at the call site, not left to the model: every
    // record_inferred_attribute call is 'MODEL_INFERRED'. The database
    // (c_inferred_origin_matches) additionally refuses anything else, but
    // this asserts the application never even tries.
    //
    // Origin and kind are inlined SQL literals ('MODEL_INFERRED'::
    // attribute_origin, 'DIAGNOSTIC_RESULT'::patient_attribute_kind) rather
    // than bound $N parameters, so they live in the call's SQL text, not its
    // values array — asserting against `.values` here was a real bug in this
    // test, caught only by actually running it against the real query shape
    // rather than an assumption about how the job binds its parameters.
    const recordCalls = fakeClient.textsContaining('record_inferred_attribute');
    expect(recordCalls).toHaveLength(1);
    expect(recordCalls[0].text).toContain("'MODEL_INFERRED'::attribute_origin");
    expect(recordCalls[0].text).toContain("'DIAGNOSTIC_RESULT'::patient_attribute_kind");
    // The attribute key IS a bound parameter, and carries DIAGNOSTIC_RESULT
    // as a prefix (migration 050 §1's build note: no normalised vocabulary
    // exists yet, so the key is documentId + test name, not a bare kind).
    expect(recordCalls[0].values.some((v) => typeof v === 'string' && v.startsWith('DIAGNOSTIC_RESULT:'))).toBe(true);

    // app.user_id was set, transaction-scoped, before the write — the
    // convention migration 050 §3 requires because patient_attribute is
    // FORCE ROW LEVEL SECURITY.
    const setConfigCalls = fakeClient.textsContaining('set_config');
    expect(setConfigCalls.some((c) => c.values.includes('app.user_id') && c.values.includes(SUBJECT_ID))).toBe(true);

    // No claim/evidence_source of any kind, and no confidence anywhere in
    // what got written — HP-SCHEMA-001 §17.2's rule, checked at the call
    // site rather than only trusted from the schema.
    expect(fakeClient.textsContaining('evidence.claim')).toHaveLength(0);
    expect(fakeClient.textsContaining('evidence_source')).toHaveLength(0);

    const stateUpdates = fakeClient.textsContaining("SET state = 'EXTRACTED'");
    expect(stateUpdates).toHaveLength(1);
  });

  it('abstains without writing an attribute when the model flags the only field illegible', async () => {
    const fakeClient = new FakeClient([documentHandler('RECEIVED')]);
    mockPool.connect.mockResolvedValue(fakeClient);

    mockMessagesCreate.mockResolvedValue(
      toolUseResponse({
        candidates: [
          {
            test_name: 'Creatinine',
            result_value: '1.?',
            result_unit: null,
            reference_range_text: null,
            printed_flag_verbatim: null,
            field_confidence: 0.2,
            illegible: true,
          },
        ],
        unable_to_extract: false,
        abstain_reason: null,
      }),
    );

    const job = { id: 'job-2', data: { documentId: DOCUMENT_ID } } as any;
    const result = await extractPatientUploadAttributes(job);

    expect(result.status).toBe('abstained');
    expect(result.attributeIds).toHaveLength(0);
    expect(fakeClient.textsContaining('record_inferred_attribute')).toHaveLength(0);

    const flagInserts = fakeClient.textsContaining('INSERT INTO obs.data_quality_flag');
    expect(flagInserts).toHaveLength(1);
    expect(flagInserts[0].values).toContain('HP-ESC 3.0.1');

    const stateUpdates = fakeClient.textsContaining("SET state = 'REJECTED'");
    expect(stateUpdates).toHaveLength(1);

    // An illegible field must never reach the model's own certainty into a
    // written row — it should never have called the encryption/record path.
    expect(mockEncryptAttribute).not.toHaveBeenCalled();
  });

  it('no-ops idempotently if the document has already moved past RECEIVED (pg-boss at-least-once redelivery)', async () => {
    const fakeClient = new FakeClient([documentHandler('EXTRACTED')]);
    mockPool.connect.mockResolvedValue(fakeClient);

    const job = { id: 'job-3', data: { documentId: DOCUMENT_ID } } as any;
    const result = await extractPatientUploadAttributes(job);

    expect(result.status).toBe('no_op');
    expect(mockMessagesCreate).not.toHaveBeenCalled();
    expect(mockDownloadStorageObject).not.toHaveBeenCalled();
  });

  it('rejects the document if the subject has no live key, without ever calling the model result into a write', async () => {
    const fakeClient = new FakeClient([documentHandler('RECEIVED')]);
    mockPool.connect.mockResolvedValue(fakeClient);
    mockGetLiveSubjectKey.mockResolvedValue(null);

    mockMessagesCreate.mockResolvedValue(
      toolUseResponse({
        candidates: [
          {
            test_name: 'Hemoglobin',
            result_value: '13.2',
            result_unit: 'g/dL',
            reference_range_text: '12.0 - 15.5',
            printed_flag_verbatim: null,
            field_confidence: 0.95,
            illegible: false,
          },
        ],
        unable_to_extract: false,
        abstain_reason: null,
      }),
    );

    const job = { id: 'job-4', data: { documentId: DOCUMENT_ID } } as any;
    const result = await extractPatientUploadAttributes(job);

    expect(result.status).toBe('abstained');
    expect(fakeClient.textsContaining('record_inferred_attribute')).toHaveLength(0);
    const flagInserts = fakeClient.textsContaining('INSERT INTO obs.data_quality_flag');
    expect(flagInserts[0].values).toContain('HP-ESC 2.3.4g');
  });
});
