// HealthPlus — cross-compatibility check between
// chat-pipeline/src/lib/subjectKey.ts and this worker's
// src/lib/subjectAttributeCrypto.ts, specifically the four functions/values
// subjectAttributeCrypto.ts's own header says "MUST STAY BYTE-IDENTICAL" to
// chat-pipeline's. Verifies that invariant by actually encrypting with one
// and decrypting with the other, rather than reading both files and trusting
// the comment — this project's own standing rule ("execute against the real
// schema rather than reading it") applied to application code instead of SQL.
//
// Run from the repo root: `npx tsx scripts/verify_crypto_compat.mjs` (plain
// `node` cannot resolve subjectKey.ts's own extensionless relative import of
// `./db`, a TS/ESM resolution detail unrelated to what this checks — tsx is
// already a dependency of both this repo's package.json and chat-pipeline's).
// No database, no network, no real secret needed — it generates its own
// random wrapping key and DEK for the duration of the check.
//
// Recorded in DEPLOY.md §4 as the concrete next step if/when the two files
// are ever consolidated into one shared package both apps import: re-point
// the two dynamic imports below at the package's exports and re-run this
// same round-trip, which is the actual test that a refactor did not silently
// change the wire format two live applications depend on agreeing about.
import { randomBytes, createDecipheriv } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, '..');

process.env.SUBJECT_KEY_WRAPPING_KEY = 'base64:' + randomBytes(32).toString('base64');

const cp = await import(join(repoRoot, 'chat-pipeline/src/lib/subjectKey.ts'));
const worker = await import(join(repoRoot, 'src/lib/subjectAttributeCrypto.ts'));

const dek = randomBytes(32);
const key = { keyId: 'test-key-id', dek };
const payload = { test: 'HbA1c', value: '6.1', unit: '%' };
const results = [];

// 1. chat-pipeline encrypts, decrypt manually with worker's exact algorithm
//    (worker only exports encryptAttribute, so decrypt inline using the same
//    constants this check is verifying).
{
  const encByCp = cp.encryptAttribute(key, payload);
  const TAG_BYTES = 16;
  const body = encByCp.ciphertext.subarray(0, encByCp.ciphertext.length - TAG_BYTES);
  const tag = encByCp.ciphertext.subarray(encByCp.ciphertext.length - TAG_BYTES);
  const d = createDecipheriv('aes-256-gcm', dek, encByCp.nonce);
  d.setAuthTag(tag);
  const plaintext = JSON.parse(Buffer.concat([d.update(body), d.final()]).toString('utf8'));
  results.push(['cp-encrypt -> manual-worker-shape-decrypt', JSON.stringify(plaintext) === JSON.stringify(payload)]);
}

// 2. worker encrypts, chat-pipeline decrypts (the real cross-check, using
//    chat-pipeline's actual decryptAttribute export).
{
  const encByWorker = worker.encryptAttribute(key, payload);
  const decByCp = cp.decryptAttribute(key, encByWorker.ciphertext, encByWorker.nonce, encByWorker.alg);
  results.push(['worker-encrypt -> cp-decryptAttribute', JSON.stringify(decByCp) === JSON.stringify(payload)]);
}

// 3. alg string identity
results.push(['ATTRIBUTE_CIPHER_ALG identical', cp.ATTRIBUTE_CIPHER_ALG === worker.ATTRIBUTE_CIPHER_ALG]);

// 4. wrapped-DEK (subject_key.wrapped_dek) format identity: chat-pipeline's
//    wrap() is not exported, so mint via getOrMintSubjectKey's internal shape
//    is not directly testable without a DB — instead verify unwrap() layout
//    compatibility by hand-building a wrapped blob the way chat-pipeline's
//    wrap() does (nonce|tag|ciphertext) and confirming worker's unwrap (via
//    getLiveSubjectKey's internal unwrap, exercised through a fake Queryable)
//    reads it back correctly.
{
  const { createCipheriv } = await import('node:crypto');
  const wrappingKey = Buffer.from(process.env.SUBJECT_KEY_WRAPPING_KEY.slice('base64:'.length), 'base64');
  const nonce = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', wrappingKey, nonce);
  const ct = Buffer.concat([c.update(dek), c.final()]);
  const wrapped = Buffer.concat([nonce, c.getAuthTag(), ct]); // chat-pipeline's wrap() layout

  const fakeExec = {
    query: async () => ({ rows: [{ key_id: 'k1', salt: randomBytes(16), wrapped_dek: wrapped }] }),
  };
  const got = await worker.getLiveSubjectKey('subject-1', fakeExec);
  results.push(['cp-wrap-layout -> worker-unwrap', Boolean(got) && Buffer.compare(got.dek, dek) === 0]);
}

let failed = 0;
for (const [label, ok] of results) {
  console.log(`  ${ok ? 'ok' : 'FAIL'}  ${label}`);
  if (!ok) failed += 1;
}

if (failed > 0) {
  console.error(`\nverify_crypto_compat: ${failed}/${results.length} check(s) FAILED — the two ` +
    'files have drifted. Do not deploy either app until this passes again.');
  process.exit(1);
}
console.log(`\nverify_crypto_compat: ${results.length}/${results.length} checks passed — ` +
  'chat-pipeline/src/lib/subjectKey.ts and src/lib/subjectAttributeCrypto.ts still agree byte-for-byte.');
