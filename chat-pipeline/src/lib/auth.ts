import { jwtVerify } from 'jose';

/**
 * Real JWT verification against HP-SEC-001's Supabase Custom Access Token
 * Hook claims — replaces the header-reading placeholder that used to live
 * directly in route.ts. HP-SEC-001 §1 mints `app_metadata.user_role`,
 * `app_metadata.hospital_id`, and `app_metadata.admin_scopes`; this module
 * verifies the token's signature and expiry, then reads those claims rather
 * than trusting anything client-supplied.
 *
 * HS256, shared-secret verification — the standard Supabase JWT pattern.
 * If this project moves to Supabase's newer asymmetric (ES256) signing
 * keys, swap `jwtVerify(token, secretKey)` for `jwtVerify(token,
 * createRemoteJWKSet(new URL(jwksUrl)))` — the rest of this module (claim
 * extraction, error handling) does not need to change.
 */

export interface AuthContext {
  userId: string; // JWT `sub`
  userRole: 'patient' | 'clinician' | 'hospital_admin' | 'platform_admin';
  hospitalId: string | null;
  adminScopes: string[]; // CONFIDENCE_ADMIN / COMMERCIAL_ADMIN, HP-SEC-001 §3
  dataRegion: string | null;
}

const VALID_ROLES = new Set(['patient', 'clinician', 'hospital_admin', 'platform_admin']);

let cachedSecret: Uint8Array | null = null;
function secretKey(): Uint8Array {
  if (!cachedSecret) {
    const raw = process.env.SUPABASE_JWT_SECRET;
    if (!raw) throw new Error('SUPABASE_JWT_SECRET is not set — cannot verify any JWT');
    cachedSecret = new TextEncoder().encode(raw);
  }
  return cachedSecret;
}

export class AuthError extends Error {
  constructor(
    message: string,
    public status: 401 | 403 = 401,
  ) {
    super(message);
  }
}

/**
 * Verifies the Authorization header on `req` and returns the caller's
 * identity + role claims. Throws AuthError (never returns a falsy/partial
 * context) on a missing header, a bad signature, an expired token, or a
 * token whose `app_metadata.user_role` isn't one of the four platform
 * roles HP-SEC-001 §1 defines — an unrecognized role is treated as
 * unauthenticated, not as "authenticated with unknown permissions."
 */
export async function requireAuth(req: Request): Promise<AuthContext> {
  const header = req.headers.get('authorization') ?? '';
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) throw new AuthError('missing or malformed Authorization header');
  const token = match[1]!;

  let payload: Record<string, unknown>;
  try {
    const result = await jwtVerify(token, secretKey(), {
      // Supabase-issued tokens carry these; reject anything that doesn't
      // look like one rather than accepting a token meant for another
      // service that happens to share the secret.
      requiredClaims: ['sub', 'exp'],
    });
    payload = result.payload as Record<string, unknown>;
  } catch (err) {
    throw new AuthError(`token verification failed: ${err instanceof Error ? err.message : 'unknown error'}`);
  }

  const sub = payload.sub;
  if (typeof sub !== 'string' || sub.length === 0) throw new AuthError('token has no subject');

  const appMetadata = (payload.app_metadata ?? {}) as Record<string, unknown>;
  const userRole = appMetadata.user_role;
  if (typeof userRole !== 'string' || !VALID_ROLES.has(userRole)) {
    throw new AuthError('token has no recognized user_role claim', 403);
  }

  const hospitalId = typeof appMetadata.hospital_id === 'string' ? appMetadata.hospital_id : null;
  const adminScopes = Array.isArray(appMetadata.admin_scopes) ? appMetadata.admin_scopes.filter((s): s is string => typeof s === 'string') : [];
  const dataRegion = typeof appMetadata.data_region === 'string' ? appMetadata.data_region : null;

  return {
    userId: sub,
    userRole: userRole as AuthContext['userRole'],
    hospitalId,
    adminScopes,
    dataRegion,
  };
}
