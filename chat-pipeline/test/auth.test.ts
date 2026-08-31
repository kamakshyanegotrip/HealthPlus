import { describe, it, expect, beforeAll } from 'vitest';
import { SignJWT } from 'jose';
import { requireAuth, AuthError } from '../src/lib/auth';

const SECRET = 'test-only-secret-do-not-use-in-real-deployments';

async function sign(payload: Record<string, unknown>, opts: { expired?: boolean } = {}) {
  const key = new TextEncoder().encode(SECRET);
  return new SignJWT(payload)
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime(opts.expired ? '-1h' : '1h')
    .sign(key);
}

function reqWith(token?: string) {
  const headers = new Headers();
  if (token) headers.set('authorization', `Bearer ${token}`);
  return new Request('https://example.test/api/chat', { headers });
}

describe('auth.requireAuth', () => {
  beforeAll(() => {
    process.env.SUPABASE_JWT_SECRET = SECRET;
  });

  it('test_hp_sec_001_valid_patient_token_is_accepted', async () => {
    const token = await sign({ sub: 'user-123', app_metadata: { user_role: 'patient', hospital_id: null, data_region: 'IN' } });
    const ctx = await requireAuth(reqWith(token));
    expect(ctx.userId).toBe('user-123');
    expect(ctx.userRole).toBe('patient');
    expect(ctx.dataRegion).toBe('IN');
  });

  it('test_hp_sec_001_missing_header_rejected', async () => {
    await expect(requireAuth(reqWith())).rejects.toBeInstanceOf(AuthError);
  });

  it('test_hp_sec_001_expired_token_rejected', async () => {
    const token = await sign({ sub: 'user-123', app_metadata: { user_role: 'patient' } }, { expired: true });
    await expect(requireAuth(reqWith(token))).rejects.toBeInstanceOf(AuthError);
  });

  it('test_hp_sec_001_wrong_signature_rejected', async () => {
    const wrongKey = new TextEncoder().encode('a-different-secret-entirely');
    const token = await new SignJWT({ sub: 'user-123', app_metadata: { user_role: 'patient' } })
      .setProtectedHeader({ alg: 'HS256' })
      .setIssuedAt()
      .setExpirationTime('1h')
      .sign(wrongKey);
    await expect(requireAuth(reqWith(token))).rejects.toBeInstanceOf(AuthError);
  });

  it('test_hp_sec_001_unrecognized_role_rejected_not_defaulted', async () => {
    const token = await sign({ sub: 'user-123', app_metadata: { user_role: 'super_admin_typo' } });
    await expect(requireAuth(reqWith(token))).rejects.toMatchObject({ status: 403 });
  });

  it('test_hp_sec_001_missing_app_metadata_rejected', async () => {
    const token = await sign({ sub: 'user-123' });
    await expect(requireAuth(reqWith(token))).rejects.toBeInstanceOf(AuthError);
  });

  it('test_hp_sec_001_admin_scopes_and_hospital_id_pass_through', async () => {
    const token = await sign({
      sub: 'admin-1',
      app_metadata: { user_role: 'platform_admin', admin_scopes: ['CONFIDENCE_ADMIN'], hospital_id: null },
    });
    const ctx = await requireAuth(reqWith(token));
    expect(ctx.adminScopes).toEqual(['CONFIDENCE_ADMIN']);
  });
});
