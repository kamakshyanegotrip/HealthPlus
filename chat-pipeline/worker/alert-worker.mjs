#!/usr/bin/env node
// ============================================================================
// HealthPlus — clinician alert worker (register item RF6)
//
// WHAT THIS REPLACES
//
// handleEmergencyConcurrentNotify() in side-effect-worker.mjs, whose whole
// body was:
//
//     console.log('[EMERGENCY_CONCURRENT_NOTIFY] would page on-call for audit', ...)
//
// after which the job was marked DONE. "Would page" recorded as success is the
// failure this worker exists to end.
//
// WHY IT DOES NOT READ side_effect_job
//
// Two reasons, and the second is the one that mattered.
//
//   1. `side_effect_job` does not exist in the real schema. It is one of the
//      stub-vs-real divergences catalogued in HP-RECON-002 — four of the nine
//      entries in query_contract_baseline.json are queries against it. A new
//      safety control must not be built on a table the production database
//      does not have.
//
//   2. HP-RECON-002's own finding about that table was that the stub had
//      "replaced a safety control with a generic queue". A row of
//      `payload jsonb` with a status column cannot express a notification
//      deadline, an acknowledgement, who was reached, or the difference
//      between "not sent yet" and "cannot be sent to anyone". safety.
//      clinician_alert can, and its constraints make the last of those
//      impossible to mis-record.
//
// So the alert table IS the queue. Migration 029's AFTER INSERT trigger raises
// the row inside the event's own transaction, which means an alert cannot be
// lost by this worker being down, by a fire-and-forget HTTP call failing, or
// by a request handler returning early.
//
// §4.0.5 — THE THING THIS WORKER MUST NEVER DO
//
// Nothing here is in the request path, and nothing in the request path waits
// for it. At CRITICAL and EMERGENCY the safety template has already reached
// the user before this process sees the row. Human involvement is concurrent
// and post-display; any change that makes a response wait on this worker is a
// safety defect, not a latency regression.
//
// WHAT HAPPENS TODAY, HONESTLY
//
// safety.on_call_roster is empty and no delivering channel is configured, so
// every alert this worker processes ends UNDELIVERABLE with reason
// NO_ROSTER_ENTRY, and safety.v_alerts_reaching_nobody is non-empty. That is
// correct behaviour for a platform with no clinical lead appointed. It is also
// the point: the state is now a row, a count and a log line at error level,
// instead of an unexamined `console.log` and a job marked DONE.
//
// Usage:
//   node worker/alert-worker.mjs            # continuous poll
//   node worker/alert-worker.mjs --once     # drain, report, exit (CI)
//
// Env: DATABASE_URL (connects as alert_role's login user — see migration 029
// §10; this role deliberately cannot write red_flag_event's notification
// columns except through safety.mark_alert_delivered).
//   ALERT_POLL_INTERVAL_MS  default 5000
//   ALERT_BATCH_SIZE        default 20
// ============================================================================
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  console.error('alert-worker: DATABASE_URL is not set — refusing to start.');
  process.exit(1);
}

const POLL_INTERVAL_MS = Number(process.env.ALERT_POLL_INTERVAL_MS ?? 5000);
const BATCH_SIZE = Number(process.env.ALERT_BATCH_SIZE ?? 20);
const RUN_ONCE = process.argv.includes('--once');

const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });

let shuttingDown = false;
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`alert-worker: ${sig} received, finishing current batch then exiting.`);
    shuttingDown = true;
  });
}

// ---------------------------------------------------------------------------
// Channels.
//
// A channel's `send` either resolves (delivered, and it can say so truthfully)
// or throws. There is deliberately no third outcome and no boolean return: a
// function that can return false is a function whose caller can forget to look.
//
// A channel whose database row says delivers = false will still fail at
// safety.mark_alert_delivered(), by design — the database is the authority on
// what counts as reaching a person, not this map.
//
// Adapters live outside this file and are loaded by module path, so a provider
// integration (and its SDK, its secrets handling and its own tests) is not
// welded into the queue loop. ALERT_CHANNEL_MODULE points at a module whose
// default export is { CHANNEL_CODE: async ({ address, alert }) => void }.
// Nothing is registered by default: until a provider is chosen (register item
// RF6-channel), every alert is UNDELIVERABLE and says so.
//
// This is also what lets the delivery branch below be tested end to end
// against a real database, which matters: the branch that fires when someone
// IS on call is the branch that has never run in production, and an untested
// success path is how "delivered" ends up meaning nothing again.
const CHANNELS = {};

async function loadChannels() {
  const modulePath = process.env.ALERT_CHANNEL_MODULE;
  if (!modulePath) return;
  const mod = await import(modulePath);
  const adapters = mod.default ?? mod;
  for (const [code, fn] of Object.entries(adapters)) {
    if (typeof fn !== 'function') {
      throw new Error(`alert-worker: channel adapter "${code}" is not a function`);
    }
    CHANNELS[code] = fn;
  }
}

async function claimBatch(client) {
  // FOR UPDATE SKIP LOCKED so multiple worker instances never process the same
  // alert — the same pattern side-effect-worker uses, and the reason
  // HP-ADR-001 §3.2 chose Postgres-backed queueing.
  const { rows } = await client.query(
    `SELECT id, event_id, severity, data_region, raised_at, notify_deadline, ack_deadline
       FROM safety.clinician_alert
      WHERE state = 'PENDING'
      ORDER BY severity DESC, raised_at ASC
      LIMIT $1
        FOR UPDATE SKIP LOCKED`,
    [BATCH_SIZE],
  );
  return rows;
}

async function processAlert(client, alert) {
  const { rows: oncall } = await client.query(
    `SELECT clinician_id, channel, address
       FROM safety.resolve_on_call($1, $2, now())`,
    [alert.data_region, alert.severity],
  );

  if (oncall.length === 0) {
    // The honest outcome, and today the only one. Logged at error level
    // because a platform that classified something EMERGENCY and reached
    // nobody should not be discoverable only by querying a view.
    console.error(
      `alert-worker: NO ONE ON CALL for ${alert.severity} alert ${alert.id} ` +
      `(event ${alert.event_id}, region ${alert.data_region}). ` +
      `safety.on_call_roster has no entry on a delivering channel. ` +
      `Recording UNDELIVERABLE — this is not a retry-able condition.`,
    );
    await client.query('SELECT safety.mark_alert_undeliverable($1, $2)',
      [alert.id, 'NO_ROSTER_ENTRY']);
    return 'UNDELIVERABLE';
  }

  const errors = [];
  for (const target of oncall) {
    const send = CHANNELS[target.channel];
    if (!send) {
      errors.push(`${target.channel}: no adapter registered in this worker`);
      continue;
    }
    try {
      await send({ address: target.address, alert });
    } catch (err) {
      errors.push(`${target.channel}: ${err instanceof Error ? err.message : String(err)}`);
      continue;
    }
    // Only reached when a channel resolved without throwing. The database
    // re-checks that this channel actually delivers, so a bug here cannot
    // manufacture a notification record.
    await client.query('SELECT safety.mark_alert_delivered($1, $2, $3)',
      [alert.id, target.channel, target.clinician_id]);
    console.log(
      `alert-worker: ${alert.severity} alert ${alert.id} delivered via ${target.channel} ` +
      `to clinician ${target.clinician_id}.`,
    );
    return 'DELIVERED';
  }

  console.error(
    `alert-worker: every configured channel FAILED for ${alert.severity} alert ` +
    `${alert.id}: ${errors.join('; ')}`,
  );
  await client.query('SELECT safety.mark_alert_undeliverable($1, $2)',
    [alert.id, `ALL_CHANNELS_FAILED: ${errors.join('; ')}`.slice(0, 500)]);
  return 'UNDELIVERABLE';
}

// ---------------------------------------------------------------------------
// Breach reporting.
//
// This does not "escalate" anywhere yet, because there is nowhere to escalate
// to. It reports, loudly and every cycle, rather than reporting once and going
// quiet — an SLA breach that scrolls out of a log is not a breach anyone will
// answer for. When an escalation path exists it hangs off this function.
// ---------------------------------------------------------------------------
async function reportBreaches(client) {
  const { rows } = await client.query(
    `SELECT id, event_id, severity, breach_kind, raised_at
       FROM safety.v_alert_sla_breach
      ORDER BY severity DESC, raised_at ASC`,
  );
  for (const b of rows) {
    console.error(
      `alert-worker: SLA BREACH ${b.breach_kind} — ${b.severity} alert ${b.id} ` +
      `(event ${b.event_id}) raised ${b.raised_at.toISOString()}. ` +
      `Deadlines are CGP-001 §8.2 proposals and are NOT clinically adopted.`,
    );
  }
  return rows.length;
}

async function runBatch() {
  const client = await pool.connect();
  const tally = { DELIVERED: 0, UNDELIVERABLE: 0 };
  try {
    // One transaction per batch: the row locks taken by claimBatch must be
    // held until the state transitions are committed, or a second worker
    // could pick up an alert this one is mid-way through.
    await client.query('BEGIN');
    const alerts = await claimBatch(client);
    for (const alert of alerts) {
      const outcome = await processAlert(client, alert);
      tally[outcome] += 1;
    }

    // Progress is measured by asking the database what actually changed, not
    // by trusting what processAlert said it did. Believing a handler's own
    // report of success is precisely the bug RF6 exists to close; a stall
    // detector built on the same assumption would inherit it, and did — a
    // first version of this counted the handler's return values and still
    // looped forever when a handler claimed DELIVERED without writing anything.
    const claimed = alerts.map((a) => a.id);
    let stillPending = 0;
    if (claimed.length > 0) {
      const { rows } = await client.query(
        `SELECT count(*)::int AS n FROM safety.clinician_alert
          WHERE id = ANY($1::uuid[]) AND state = 'PENDING'`,
        [claimed],
      );
      stillPending = rows[0].n;
    }

    await client.query('COMMIT');
    return { count: alerts.length, progressed: alerts.length - stillPending, tally };
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    // Do NOT swallow. An alert left PENDING is retried next cycle and shows up
    // in v_alert_sla_breach once its deadline passes; an alert silently marked
    // anything else would not.
    console.error('alert-worker: batch failed, rolling back and retrying next cycle:', err);
    return { count: 0, progressed: 0, tally };
  } finally {
    client.release();
  }
}

let stalled = false;

async function main() {
  await loadChannels();
  console.log(
    `alert-worker: starting (${RUN_ONCE ? 'drain-and-exit' : `poll every ${POLL_INTERVAL_MS}ms`}, ` +
    `batch ${BATCH_SIZE}). Registered delivering channels: ` +
    `${Object.keys(CHANNELS).length === 0 ? 'NONE — every alert will be UNDELIVERABLE' : Object.keys(CHANNELS).join(', ')}.`,
  );

  // Terminate on lack of PROGRESS, not on an empty claim.
  //
  // Found by a negative control, not by reading this: a handler that returns
  // without moving an alert out of PENDING makes claimBatch hand back the same
  // rows forever. `--once` never exits and the poll loop never reaches its
  // sleep, so the worker pins a core and stops reporting — the loudest
  // possible failure rendered completely silent. Counting claimed rows cannot
  // see that; counting state transitions can.
  const drain = async () => {
    let total = 0;
    const tally = { DELIVERED: 0, UNDELIVERABLE: 0 };
    for (;;) {
      const { count, progressed, tally: t } = await runBatch();
      total += count;
      tally.DELIVERED += t.DELIVERED;
      tally.UNDELIVERABLE += t.UNDELIVERABLE;
      if (count === 0) break;
      if (progressed === 0) {
        console.error(
          `alert-worker: claimed ${count} alert(s) and none changed state. Stopping this ` +
          `drain rather than re-claiming them forever. They stay PENDING and will appear ` +
          `in safety.v_alert_sla_breach once their deadlines pass.`,
        );
        stalled = true;
        break;
      }
    }
    return { total, tally };
  };

  if (RUN_ONCE) {
    const { total, tally } = await drain();
    const breaches = await (async () => {
      const c = await pool.connect();
      try { return await reportBreaches(c); } finally { c.release(); }
    })();
    console.log(
      `alert-worker: drained ${total} alert(s) — ${tally.DELIVERED} delivered, ` +
      `${tally.UNDELIVERABLE} undeliverable; ${breaches} SLA breach(es) open.`,
    );
    await pool.end();
    // Exit non-zero when something was classified URGENT+ and reached no one.
    // This is what makes a CI smoke run, or a health check, able to see the
    // condition — a worker that exits 0 having paged nobody is the original
    // bug in a new shape.
    process.exit(tally.UNDELIVERABLE > 0 || breaches > 0 || stalled ? 2 : 0);
  }

  while (!shuttingDown) {
    await drain();
    const c = await pool.connect();
    try { await reportBreaches(c); } finally { c.release(); }
    if (shuttingDown) break;
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
  await pool.end();
  console.log('alert-worker: stopped.');
}

main().catch((err) => {
  console.error('alert-worker: fatal:', err);
  process.exit(1);
});
