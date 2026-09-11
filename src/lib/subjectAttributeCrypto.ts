/**
 * HealthPlus (worker) — subject-key crypto for principal.patient_attribute.
 *
 * DELIBERATE DUPLICATION, STATED RATHER THAN HIDDEN. This is a subset of
 * chat-pipeline/src/lib/subjectKey.ts, ported into this repo because the two
 * apps (Next.js on Vercel, this pg-boss worker on Fly.io) share no package
 * today. Only the pieces this worker needs are here: reading live key
 * material and the patient_attribute envelope format. Minting a new subject
 * key, response-content encryption, and pseudonym derivation stay in
 * chat-pipeline, which is the only thing that needs them.
 *
 * THE ENVELOPE FORMAT MUST STAY BYTE-IDENTICAL TO chat-pipeline's
 * encryptAttribute/decryptAttribute, because both write and read
 * principal.patient_attribute:
 *
 *   cipher_alg          the literal 'AES-256-GCM'
 *   cipher_nonce        the 12-byte GCM nonce, alone
 *   payload_ciphertext  ciphertext || 16-byte GCM tag
 *   plaintext           UTF-8 JSON
 *
 * If either copy drifts, the failure mode is silent corruption read back as
 * a GCM authentication error in the OTHER app, which is exactly the kind of
 * "wrong guess indistinguishable from corrupt data" chat-pipeline's version
 * of this file warns about. A shared `@healthplus/crypto` package that both
 * apps depend on would remove this risk structurally; recorded here as a
 * follow-up worth doing rather than done, since it touches both repos'
 * build config and is out of scope for landing this job.
 *
 * SUBJECT_KEY_WRAPPING_KEY must be the SAME 32 bytes in both apps' secrets —
 * it is what makes a DEK wrapped by chat-pipeline (or minted for a patient
 * before their first upload) unwrappable here. See DEPLOY.md.
 */
import { randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import { inspect } from 'node:util';

const CIPHER_ALG = 'aes-256-gcm';
const DEK_BYTES = 32; // AES-256
const NONCE_BYTES = 12; // GCM standard
const TAG_BYTES = 16;

export const ATTRIBUTE_CIPHER_ALG = 'AES-256-GCM';

function wrappingKey(): Buffer {
  const raw = process.env.SUBJECT_KEY_WRAPPING_KEY ?? '';
  if (!raw) {
    throw new Error(
      "SUBJECT_KEY_WRAPPING_KEY is not set. This worker cannot unwrap a subject's " +
        'DEK, and therefore cannot encrypt anything into principal.patient_attribute, ' +
        'without it. Must be the same 32 bytes chat-pipeline uses — see DEPLOY.md.',
    );
  }
  const key = raw.startsWith('base64:')
    ? Buffer.from(raw.slice('base64:'.length), 'base64')
    : raw.startsWith('hex:')
      ? Buffer.from(raw.slice('hex:'.length), 'hex')
      : Buffer.from(raw, 'utf8');
  if (key.length !== DEK_BYTES) {
    throw new Error(
      `SUBJECT_KEY_WRAPPING_KEY must be ${DEK_BYTES} bytes, got ${key.length}. ` +
        'Use base64: or hex: for binary material rather than a passphrase.',
    );
  }
  return key;
}

function unwrap(wrapped: Buffer): Buffer {
  if (wrapped.length < NONCE_BYTES + TAG_BYTES + DEK_BYTES) {
    throw new Error(`subjectAttributeCrypto: wrapped DEK is ${wrapped.length} bytes, too short to be valid`);
  }
  const nonce = wrapped.subarray(0, NONCE_BYTES);
  const tag = wrapped.subarray(NONCE_BYTES, NONCE_BYTES + TAG_BYTES);
  const ct = wrapped.subarray(NONCE_BYTES + TAG_BYTES);
  const d = createDecipheriv(CIPHER_ALG, wrappingKey(), nonce);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(ct), d.final()]);
}

export interface SubjectKey {
  keyId: string;
  dek: Buffer;
}

/**
 * Same self-redaction as chat-pipeline's SubjectKey: this rides inside job
 * payloads and log statements in this codebase too (structured console.log
 * is used throughout, e.g. lib/anthropic.ts's logAiCall), so the same two
 * paths — JSON.stringify and util.inspect — get the same guard.
 */
function makeSubjectKey(keyId: string, dek: Buffer): SubjectKey {
  const redacted = { keyId, dek: '[redacted]' };
  return Object.defineProperties({ keyId, dek } as SubjectKey, {
    toJSON: { value: () => redacted, enumerable: false },
    [inspect.custom]: { value: () => redacted, enumerable: false },
  });
}

export interface Queryable {
  query: <T = unknown>(text: string, values?: unknown[]) => Promise<{ rows: T[] }>;
}

interface MaterialRow {
  key_id: string;
  salt: Buffer;
  wrapped_dek: Buffer;
}

/**
 * Reads LIVE key material only — zero rows for an erased or never-existing
 * subject, same as principal.subject_key_material's own documented contract.
 * This worker never mints a key (principal.ensure_subject_key is not granted
 * to patient_upload_role, deliberately: a patient must already have a
 * profile — and therefore a key, per patient_profile.key_id NOT NULL —
 * before they can upload, so minting here would only paper over a product
 * flow bug rather than a real first-use case).
 */
export async function getLiveSubjectKey(subjectId: string, exec: Queryable): Promise<SubjectKey | null> {
  const { rows } = await exec.query<MaterialRow>(
    'SELECT key_id, salt, wrapped_dek FROM principal.subject_key_material($1)',
    [subjectId],
  );
  const row = rows[0];
  if (!row) return null;
  return makeSubjectKey(row.key_id, unwrap(Buffer.isBuffer(row.wrapped_dek) ? row.wrapped_dek : Buffer.from(row.wrapped_dek)));
}

/**
 * principal.patient_attribute's four-column envelope (payload_ciphertext,
 * cipher_alg, cipher_nonce, key_id) — see the module header. Ciphertext
 * carries the GCM tag appended, matching chat-pipeline's encryptAttribute.
 */
export function encryptAttribute(key: SubjectKey, payload: unknown): {
  ciphertext: Buffer;
  nonce: Buffer;
  alg: string;
} {
  const nonce = randomBytes(NONCE_BYTES);
  const c = createCipheriv(CIPHER_ALG, key.dek, nonce);
  const body = Buffer.concat([c.update(JSON.stringify(payload), 'utf8'), c.final()]);
  return { ciphertext: Buffer.concat([body, c.getAuthTag()]), nonce, alg: ATTRIBUTE_CIPHER_ALG };
}
