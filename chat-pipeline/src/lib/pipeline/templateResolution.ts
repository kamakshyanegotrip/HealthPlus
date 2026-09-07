import { db } from '../db';
import { SEVERITY_ORDER, type RedFlagSeverity } from '../types';

/**
 * R2 — Charter §4.3 template resolution.
 *
 * Until now a template was carried on the rule row (`red_flag_rule.template_id`)
 * and loaded by id. The committed schema has no such column: a template is
 * identified by `UNIQUE (severity, jurisdiction, language, version)` and found
 * by climbing §4.3.3/§4.3.4's fallback ladder. HP-RECON-001 §3 records the
 * divergence; this file closes it.
 *
 * The ladder, in order, for each severity from the triggered one UPWARD:
 *
 *   1. exact severity + jurisdiction + language
 *   2. exact severity + jurisdiction + approved English      (§4.3.4)
 *   3. GLOBAL jurisdiction + language, then English          (§4.3.3)
 *   4. the NEXT HIGHER severity, same four attempts          (§4.3.3, §4.0.9)
 *
 * Step 4 climbs and never descends. A missing URGENT template resolves to the
 * CRITICAL one, never to the WARNING one: §4.0.9 says a missing template
 * escalates to the highest applicable severity, and the entire point of a
 * fail-safe is that it errs toward more urgency rather than less.
 *
 * Machine-translated rows are skipped at every rung even when they are the only
 * match (§4.3.4, and `c_no_mt_safety_text` says the same thing in the schema).
 * An untranslated template falls back to approved English plus the local
 * emergency number — never to machine translation of safety-critical text.
 */

export interface SafetyTemplateRow {
  id: string;
  version: number;
  severity: RedFlagSeverity;
  jurisdiction: string;
  language: string;
  body: string;
  slots: unknown;
  is_fallback: boolean;
  machine_translated: boolean;
}

export interface TemplateSelection {
  template: SafetyTemplateRow;
  /** True when any rung below the exact match was used. */
  isFallback: boolean;
  fallbackReason: string | null;
  /** The severity actually resolved — may be higher than the one requested. */
  resolvedSeverity: RedFlagSeverity;
  /**
   * RF4. The body with its §4.3.2 slots filled, when a `prepare` hook was
   * supplied. Null when no hook was given, in which case the caller uses
   * `template.body` unchanged — which is every caller that has no slots to
   * fill.
   */
  renderedText: string | null;
  /** RF4. What each declared slot resolved to, for TEMPLATE_RENDERED. */
  renderedDetail: unknown;
  /** Rungs skipped because they could not be rendered. Empty is the norm. */
  unrenderableRungs: string[];
}

/**
 * RF4. Called at each rung before the row is accepted.
 *
 * A template whose slots cannot be filled is, for the ladder's purposes, not
 * available — the same status a machine-translated row has. Returning `ok:
 * false` makes the ladder climb past it, which is §4.0.9's direction: toward
 * a higher severity, never toward generative output and never toward showing
 * a person a placeholder.
 *
 * Single-pass on purpose: the hook returns the rendered text, so an accepted
 * rung is not rendered a second time.
 */
export type PrepareTemplate = (
  row: SafetyTemplateRow,
) => Promise<{ ok: true; text: string; detail?: unknown } | { ok: false; reason: string }>;

const SEVERITIES: RedFlagSeverity[] = ['NORMAL', 'MONITOR', 'WARNING', 'URGENT', 'CRITICAL', 'EMERGENCY'];

/**
 * The ladder as a pure function of what the repository returns, so it can be
 * tested without a database — the same reason `clampSeverity` and
 * `applySessionFloor` are split out in redFlagEngine.ts.
 *
 * `lookup` is called with each (severity, jurisdiction, language) triple in
 * order and returns the matching row or null.
 */
export async function selectTemplate(
  requested: RedFlagSeverity,
  jurisdiction: string,
  language: string,
  lookup: (a: { severity: RedFlagSeverity; jurisdiction: string; language: string }) => Promise<SafetyTemplateRow | null>,
  prepare?: PrepareTemplate,
): Promise<TemplateSelection | null> {
  const start = SEVERITY_ORDER[requested];
  const unrenderableRungs: string[] = [];

  for (let i = start; i < SEVERITIES.length; i++) {
    const level = SEVERITIES[i]!;
    const escalated = i > start;

    const rungs = [
      { jurisdiction, language, reason: 'exact match' },
      { jurisdiction, language: 'en', reason: '§4.3.4 approved English fallback' },
      { jurisdiction: 'GLOBAL', language, reason: '§4.3.3 generic jurisdiction' },
      { jurisdiction: 'GLOBAL', language: 'en', reason: '§4.3.3 generic English' },
    ];

    for (const rung of rungs) {
      const found = await lookup({ severity: level, jurisdiction: rung.jurisdiction, language: rung.language });
      if (!found) continue;
      // §4.3.4 is absolute — skip, do not render, even if it is the only row.
      if (found.machine_translated) continue;

      // RF4: and skip it just as absolutely if its slots cannot be filled.
      let renderedText: string | null = null;
      let renderedDetail: unknown = null;
      if (prepare) {
        const p = await prepare(found);
        if (!p.ok) {
          unrenderableRungs.push(`${level}/${rung.jurisdiction}/${rung.language}: ${p.reason}`);
          continue;
        }
        renderedText = p.text;
        renderedDetail = p.detail ?? null;
      }

      const isFallback = escalated || rung.reason !== 'exact match' || found.is_fallback;
      return {
        template: found,
        isFallback,
        resolvedSeverity: level,
        fallbackReason: isFallback
          ? escalated
            ? `§4.0.9: no ${requested} template; escalated to ${level} (${rung.reason})`
            : rung.reason
          : null,
        renderedText,
        renderedDetail,
        unrenderableRungs,
      };
    }
  }
  // Nothing at this level or any level above it. §4.0.9 forbids falling through
  // to generative output, so the caller must fail closed rather than continue.
  return null;
}

/**
 * The database-backed lookup. One row per (severity, jurisdiction, language).
 *
 * NOTE, and it is the whole lesson of HP-RECON-001 §2: this query deliberately
 * filters on NOTHING but the three key columns. An earlier draft added
 * `AND clinically_adopted = true`, which is a stub-only column — the real
 * safety_template has no such column, and that predicate would have raised
 * against the shipping schema exactly as `AND active = true` did before it.
 * Caught by running this query against both schemas rather than by review.
 *
 * Approval is not lost by dropping it: the real table's `approved_by` and
 * `approved_at` are NOT NULL, so a row that exists is a row a clinician
 * approved. The §0.6 / AMB-17 adoption gate lives on the RULE — nothing
 * reaches template resolution at all until an adopted rule fires.
 */
export async function lookupTemplate(a: {
  severity: RedFlagSeverity;
  jurisdiction: string;
  language: string;
}): Promise<SafetyTemplateRow | null> {
  const { rows } = await db().query<SafetyTemplateRow>(
    `SELECT id, version, severity, jurisdiction, language, body, slots,
            is_fallback, machine_translated
       FROM safety.safety_template
      WHERE severity = $1 AND jurisdiction = $2 AND language = $3
      ORDER BY version DESC
      LIMIT 1`,
    [a.severity, a.jurisdiction, a.language],
  );
  return rows[0] ?? null;
}

/**
 * §4.3.1: every level at or above WARNING renders from a versioned,
 * clinician-approved template. Below WARNING there is nothing to resolve.
 *
 * Returns null when no template is needed, and throws when one is needed and
 * the whole ladder came up empty — the caller turns that into FAIL_CLOSED
 * rather than generating, per §4.0.9.
 */
export async function resolveTemplateForSeverity(
  severity: RedFlagSeverity,
  jurisdiction: string,
  language: string,
  lookup = lookupTemplate,
  prepare?: PrepareTemplate,
): Promise<TemplateSelection | null> {
  if (SEVERITY_ORDER[severity] < SEVERITY_ORDER['WARNING']) return null;
  const selection = await selectTemplate(severity, jurisdiction, language, lookup, prepare);
  if (!selection) {
    throw new NoApprovedTemplateError(
      `no approved safety template at or above ${severity} for ${jurisdiction}/${language}`,
    );
  }
  return selection;
}

export class NoApprovedTemplateError extends Error {
  readonly clause = 'HP-ESC §4.0.9';
  constructor(message: string) {
    super(message);
    this.name = 'NoApprovedTemplateError';
  }
}
