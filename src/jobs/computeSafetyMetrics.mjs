#!/usr/bin/env node
// ============================================================================
// HealthPlus — §6.5 safety metrics (register item J3-4)
//
// WHAT THIS IS
//
// The six metrics §6.5 names, computed over a window and written to
// obs.safety_metric_sample as a series, so a regression is visible as a line
// and not as an argument (migration 005's own words).
//
// WHAT IT DELIBERATELY DOES NOT DO
//
// It does not compute red_flag_recall, and it does not compute
// fabrication_rate_adversarial. Both are release-gating under §6.4 and
// neither has the inputs it needs — no clinician-labelled gold set (CL9 /
// AMB-22) and no adversarial evaluation suite. This job writes them as
// UNCOMPUTABLE with the registry's reason, every run.
//
// That is the point of the job, not a gap in it. The alternative shapes are
// all worse:
//
//   * omitting them        -> a dashboard with four green lines and no
//                             indication that the two that gate a release
//                             are unmeasured;
//   * writing 0            -> a recall of zero, which reads as catastrophic
//                             rather than unknown;
//   * writing 1            -> a recall of one, which reads as perfect and is
//                             the most dangerous number in the system.
//
// obs.record_metric_sample() refuses COMPUTED for a metric the registry marks
// blocked_on, so this is enforced below the job as well as inside it.
//
// WHERE THE DEFINITIONS LIVE
//
// In SQL, as views (migration 030 §4). This file decides WHEN to compute and
// WHAT to do with the result; it does not decide what a block rate is. That
// keeps a dashboard from computing a different number and calling it the same
// thing — the convention 027 §6 set for v_emergency_display_latency.
//
// Usage:
//   node src/jobs/computeSafetyMetrics.mjs                 # yesterday
//   node src/jobs/computeSafetyMetrics.mjs --days 7        # last 7 days
//   node src/jobs/computeSafetyMetrics.mjs --all           # every window with data
//
// Env: DATABASE_URL. METHOD_VERSION (default below) — bump it when a view
// definition changes, because a series computed two different ways under one
// method_version is not a series.
// ============================================================================
import pg from 'pg';

// Bump when any obs.v_metric_* view changes. The unique index includes it, so
// a redefinition produces a parallel series rather than silently overwriting
// history computed a different way.
const METHOD_VERSION = 'metrics-2026.09.1';

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  console.error('computeSafetyMetrics: DATABASE_URL is not set — refusing to start.');
  process.exit(1);
}

const argv = process.argv.slice(2);
const ALL = argv.includes('--all');
const DAYS = (() => {
  const i = argv.indexOf('--days');
  return i >= 0 ? Number(argv[i + 1]) : 1;
})();

const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });

// ---------------------------------------------------------------------------
// The computable four. Each names its view and how that view's columns map to
// a sample. `scalar` metrics have no dimension column.
// ---------------------------------------------------------------------------
const COMPUTABLE = [
  {
    metricKey: 'emergency_display_latency_ms_p95',
    view: 'obs.v_metric_emergency_latency',
    dimensioned: true,
    // A latency has no numerator; denominator is the number of scans the
    // percentile was taken over, which a reader needs in order to know
    // whether a p95 over three events means anything.
    hasNumerator: false,
  },
  { metricKey: 'block_rate',      view: 'obs.v_metric_block_rate',      dimensioned: true,  hasNumerator: true },
  { metricKey: 'abstention_rate', view: 'obs.v_metric_abstention_rate', dimensioned: true,  hasNumerator: true },
  { metricKey: 'review_turnaround_h', view: 'obs.v_metric_review_turnaround', dimensioned: false, hasNumerator: false },
];

function windowClause(alias = '') {
  const p = alias ? `${alias}.` : '';
  if (ALL) return { sql: '', params: [] };
  return {
    sql: ` WHERE ${p}window_start >= date_trunc('day', now()) - ($1 || ' days')::interval
             AND ${p}window_end   <= date_trunc('day', now())`,
    params: [String(DAYS)],
  };
}

async function computeOne(client, spec) {
  const w = windowClause();
  const cols = [
    'window_start', 'window_end',
    spec.dimensioned ? 'dimension' : `NULL::text AS dimension`,
    spec.hasNumerator ? 'numerator' : 'NULL::numeric AS numerator',
    'denominator', 'value',
  ].join(', ');

  const { rows } = await client.query(
    `SELECT ${cols} FROM ${spec.view}${w.sql} ORDER BY window_start`,
    w.params,
  );

  let written = 0;
  for (const r of rows) {
    // A window whose denominator is zero or absent is NO_DATA, never a value.
    // The database enforces this too (c_computed_has_denominator), but the
    // job should not be sending a 0/0 for the constraint to catch: an
    // exception here would abort the whole run over an empty Tuesday.
    const denom = r.denominator === null ? null : Number(r.denominator);
    const noData = r.value === null || denom === 0;

    await client.query(
      `SELECT obs.record_metric_sample($1,$2,$3,$4,$5,$6,$7,$8::metric_status,$9,NULL,NULL)`,
      [
        spec.metricKey,
        r.dimension,
        r.window_start,
        r.window_end,
        noData ? null : r.numerator,
        noData ? null : r.denominator,
        noData ? null : r.value,
        noData ? 'NO_DATA' : 'COMPUTED',
        METHOD_VERSION,
      ],
    );
    written += 1;
  }
  return { metricKey: spec.metricKey, rows: written };
}

// ---------------------------------------------------------------------------
// The blocked two. Recorded every run, over the same window as everything
// else, so the series shows an unbroken record of "still unmeasurable" rather
// than a gap that could be mistaken for a job that did not run.
// ---------------------------------------------------------------------------
async function recordBlocked(client) {
  const { rows: blocked } = await client.query(
    `SELECT metric_key, blocked_on FROM obs.safety_metric WHERE blocked_on IS NOT NULL`,
  );

  const windowEnd = "date_trunc('day', now())";
  const windowStart = ALL
    ? "date_trunc('day', now()) - interval '1 day'"
    : `date_trunc('day', now()) - ('${DAYS} days')::interval`;

  const out = [];
  for (const m of blocked) {
    await client.query(
      `SELECT obs.record_metric_sample($1, NULL, ${windowStart}, ${windowEnd},
                                       NULL, NULL, NULL, 'UNCOMPUTABLE'::metric_status,
                                       $2, NULL, $3)`,
      [m.metric_key, METHOD_VERSION, m.blocked_on],
    );
    out.push(m.metric_key);
  }
  return out;
}

async function main() {
  // The client MUST be released before pool.end(), in every path. A first
  // version released it only in the catch: the job printed a completely
  // correct report and then hung forever, because pool.end() waits for
  // checked-out clients and the process.exit() after it was never reached.
  // Correct output followed by a process that never exits is a job that looks
  // fine interactively and wedges a cron slot.
  let client;
  let exitCode = 1;
  try {
    client = await pool.connect();
    const results = [];
    for (const spec of COMPUTABLE) results.push(await computeOne(client, spec));
    const blocked = await recordBlocked(client);

    for (const r of results) {
      console.log(`  ${r.metricKey.padEnd(34)} ${r.rows} window(s)`);
    }
    for (const k of blocked) {
      console.log(`  ${k.padEnd(34)} UNCOMPUTABLE (recorded, not skipped)`);
    }

    // §6.4. Report the gate every run. A metrics job that computes what it
    // can and says nothing about what it cannot is how the two release-gating
    // metrics stayed invisible in the first place.
    const { rows: gate } = await client.query(
      `SELECT metric_key, status, verdict, reason FROM obs.v_release_gate ORDER BY metric_key`,
    );
    const blocking = gate.filter((g) => g.verdict === 'BLOCK');

    console.log('');
    if (blocking.length === 0) {
      console.log('Release gate (§6.4): PASS — every gating metric is measured.');
    } else {
      console.error(`Release gate (§6.4): BLOCK — ${blocking.length} of ${gate.length} gating metric(s) are not measurable.`);
      for (const g of blocking) {
        console.error(`  ${g.metric_key}: ${g.status} — ${g.reason}`);
      }
    }

    const { rows: cov } = await client.query(
      `SELECT count(*) FILTER (WHERE computable)::int AS n, count(*)::int AS total
         FROM obs.v_metric_coverage`,
    );
    console.log(`\n§6.5 coverage: ${cov[0].n} of ${cov[0].total} metrics computable.`);

    // Exit 2 when a release-gating metric cannot be measured. Same contract as
    // alert-worker: a job that exits 0 having measured nothing that gates a
    // release is a job whose green light means nothing.
    exitCode = blocking.length > 0 ? 2 : 0;
  } catch (err) {
    console.error('computeSafetyMetrics: failed:', err);
    exitCode = 1;
  } finally {
    if (client) client.release();
    await pool.end().catch(() => {});
  }
  process.exit(exitCode);
}

main();
