/**
 * HealthPlus (worker) — minimal Supabase Storage download.
 *
 * Deliberately not the @supabase/supabase-js SDK: this worker needs exactly
 * one operation (download an object as bytes, service-role-authenticated),
 * which is a single documented REST call
 * (GET /storage/v1/object/{bucket}/{path}, Authorization: Bearer
 * <service-role-key>). Pulling in the full SDK for one GET is a dependency
 * this job does not need; if a second Storage operation is ever needed here,
 * reconsider.
 *
 * ⚠ VERIFY BEFORE DEPLOYING, same caveat this codebase states elsewhere for
 * anything outside its own control (e.g. anthropicClient.ts's model-string
 * note): confirm this path and header against Supabase's current Storage
 * REST documentation before shipping. It has been stable for a long time but
 * this file was written without live access to Supabase's docs from this
 * environment.
 */

export interface DownloadedObject {
  bytes: Buffer;
  contentType: string;
}

export async function downloadStorageObject(bucket: string, objectPath: string): Promise<DownloadedObject> {
  const baseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!baseUrl || !serviceRoleKey) {
    throw new Error(
      'downloadStorageObject: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are both required. ' +
        'The service-role key is required (not the anon key) because this download happens ' +
        'outside any user session, on behalf of a background job.',
    );
  }

  const url = `${baseUrl.replace(/\/$/, '')}/storage/v1/object/${bucket}/${objectPath}`;
  const resp = await fetch(url, {
    headers: {
      Authorization: `Bearer ${serviceRoleKey}`,
      apikey: serviceRoleKey,
    },
  });

  if (!resp.ok) {
    throw new Error(
      `downloadStorageObject: GET ${url} returned ${resp.status} ${resp.statusText}. ` +
        'Permanent failure if 404 (object was deleted before the job ran) or 403 ' +
        '(service-role key misconfigured) — do not retry blindly on either.',
    );
  }

  const contentType = resp.headers.get('content-type') ?? 'application/octet-stream';
  const bytes = Buffer.from(await resp.arrayBuffer());
  return { bytes, contentType };
}

/** Charter §3.1.6/§3.1.7 and this job's system prompt only cover images and
 * PDF pages sent as vision input. Anything else is a permanent rejection,
 * not a job to retry. */
export const SUPPORTED_MIME_TYPES = new Set([
  'application/pdf',
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/heic',
]);

/**
 * Delete one object from Supabase Storage. Added for migration 051's
 * storage_erasure_queue drain (src/jobs/drainStorageErasure.ts) — the
 * counterpart to downloadStorageObject above, and re-verified the same way:
 * `DELETE /storage/v1/object/{bucket}/{path}`, Bearer service-role key, no
 * request body, against a live fetch of Supabase's own reference docs
 * (supabase.com/docs/reference/self-hosting-storage/delete-an-object) on
 * 2026-09-10 — not assumed from the GET shape above.
 *
 * A 404 is treated as success, not an error: the object being already gone
 * (a retry after a previous run's DELETE succeeded but this worker crashed
 * before marking the queue row complete, or an operator having removed it
 * some other way) means the erasure this function exists to perform has, in
 * fact, already happened. Anything else non-2xx is a real failure the
 * caller should record via principal.mark_storage_erasure_failed and retry.
 */
export async function deleteStorageObject(bucket: string, objectPath: string): Promise<void> {
  const baseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!baseUrl || !serviceRoleKey) {
    throw new Error(
      'deleteStorageObject: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are both required.',
    );
  }

  const url = `${baseUrl.replace(/\/$/, '')}/storage/v1/object/${bucket}/${objectPath}`;
  const resp = await fetch(url, {
    method: 'DELETE',
    headers: {
      Authorization: `Bearer ${serviceRoleKey}`,
      apikey: serviceRoleKey,
    },
  });

  if (resp.ok || resp.status === 404) {
    return;
  }

  throw new Error(`deleteStorageObject: DELETE ${url} returned ${resp.status} ${resp.statusText}.`);
}
