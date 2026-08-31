import { createHmac, createHash } from 'node:crypto';

/**
 * ADR-003 §2.3 / HP-RB-001 §3: the immutable trace never carries a raw
 * subject_id. subject_pseudonym = HMAC(user_id, subject_key.salt). The key
 * lives in SUBJECT_HMAC_KEY here as a stand-in for the per-subject
 * `subject_key` table (HP-SCHEMA-001 §17.1) — swap this for a real per-key
 * lookup before this goes near production data.
 */
function hmacKey(): Buffer {
  const raw = process.env.SUBJECT_HMAC_KEY ?? '';
  if (raw.startsWith('base64:')) return Buffer.from(raw.slice('base64:'.length), 'base64');
  return Buffer.from(raw, 'utf8');
}

export function subjectPseudonym(userId: string): Buffer {
  return createHmac('sha256', hmacKey()).update(userId).digest();
}

export function sessionPseudonym(sessionId: string): Buffer {
  return createHmac('sha256', hmacKey()).update(sessionId).digest();
}

/**
 * §3.13.1 fabrication_block.query_hash / RB-001 payload_no_pii: hash the
 * user's message, never store or log the plaintext in an audit-adjacent
 * table.
 */
export function queryHash(message: string): Buffer {
  return createHash('sha256').update(message, 'utf8').digest();
}
