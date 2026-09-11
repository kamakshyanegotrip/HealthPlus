/**
 * HealthPlus (worker) — pg-boss <-> raw `pg` transaction adapter.
 *
 * Identical in substance to the private `fromPgClient` helper already in
 * src/jobs/extractClaimsFromProviderSubmission.ts (that file's own comment
 * explains why it exists: pg-boss's `db` option for send()/insert() needs an
 * `executeSql(text, values)` shape, and this project uses raw `pg` rather
 * than an ORM pg-boss already has an adapter for). Pulled out here, rather
 * than imported from that job file, so the webhook receiver in
 * webhookServer.ts does not depend on a job module for an unrelated utility.
 * Worth consolidating into one export if a third caller ever needs it.
 */
import type { PoolClient } from 'pg';

export function fromPgClient(client: PoolClient) {
  return {
    async executeSql(text: string, values: unknown[]) {
      const result = await client.query(text, values);
      return { rows: result.rows };
    },
  };
}
