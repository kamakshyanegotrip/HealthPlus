import { db } from '../db';
import type { RedFlagSeverity } from '../types';

/**
 * HP-JOB-004 RF1 — the FAIL_CLOSED surface contract.
 *
 * Charter §0.6 / AMB-17: "§4 remains unadopted until signed by the clinical
 * lead", and migration 012's own comment on `red_flag_rule.clinically_adopted`
 * is blunter: "a rule that has not been signed must not be able to fire."
 *
 * `matchDeterministicRules` already honours that — it filters on
 * `clinically_adopted = true`. The hole it leaves is what happens when the
 * filter matches nothing at all. Today that is every rule, because CL2 is
 * unsigned. A scanner that matches nothing returns NORMAL, and an unsigned
 * deployment then looks perfectly healthy while detecting exactly zero red
 * flags. That is the failure this module exists to prevent: the difference
 * between "we looked and found nothing" and "we never looked" is the whole
 * safety claim, and only one of them is true here.
 *
 * So: no adopted rules ⇒ refuse the generative path. NOT a triage outcome.
 * Nothing was assessed, so nothing is asserted about this person.
 *
 * ── RF8, DECIDED: this copy is NOT a `safety.safety_template` row ───────────
 * Asked and answered (CL5-ADD-001 Q4), recorded here so it is not re-litigated.
 *
 * Three reasons, in order of force:
 *
 *  1. `safety_template.severity` is `red_flag_severity NOT NULL`. This notice
 *     has no severity — nothing was assessed. Filing it as 'NORMAL' would
 *     assert, in the one table the Clinical Governance Board reads as the
 *     register of approved safety content, that it is a NORMAL-severity triage
 *     output. It is not a triage output at all, and the schema would be
 *     recording something untrue.
 *  2. One of the three FAIL_CLOSED triggers is the database being unreachable.
 *     A notice that requires a database read cannot be the notice for "the
 *     database did not answer." A code-resident string is mandatory whatever
 *     else is built, so a template row could only ever be an addition to this,
 *     never a replacement for it.
 *  3. Templates live in the §4.3.3 severity ladder — selectTemplate climbs it
 *     on a miss. This notice sits outside that ladder entirely; putting it in
 *     the same table invites a future escalation path to find it.
 *
 * What the template argument was right about — approval provenance, and
 * localisation — is real and unaddressed. The answer to it is a separate
 * `safety.service_notice` table with no severity column, carrying
 * approved_by / approved_at / language, with this string as the last-resort
 * fallback behind it. NOT BUILT YET, deliberately: until B2 (clinical lead)
 * closes there is nobody to approve a row, so the table would have zero rows
 * and the loader would be a guaranteed-dead code path. Trigger to build it:
 * CL5 sign-off.
 * ────────────────────────────────────────────────────────────────────────────
 */

/** Surfaces the module can speak about. Named, so callers cannot improvise. */
export type Surface =
  | 'GENERATIVE_HEALTH'
  | 'PROVIDER_RECOMMENDATION'
  | 'PRICING'
  | 'BOOKING'
  | 'PROMOTIONAL'
  | 'ACCOUNT'
  | 'EXISTING_ITINERARY'
  | 'NAVIGATION'
  | 'HUMAN_CONTACT';

/**
 * Bump on any wording change, so `red_flag_log.fail_safe_reason` can be
 * correlated with what the user actually read — the same discipline
 * `obs.ai_call.prompt_version` applies to model calls.
 */
export const UNAVAILABILITY_COPY_VERSION = 'hp-redflag-unavailable-v1.0.0';

export interface EmergencyRouting {
  numberE164: string;
  label: string;
  sourceTable: 'safety.emergency_contact_reference';
  sourceRowId: string;
}

export interface ServiceUnavailability {
  copyVersion: string;
  /** Engineering detail. Goes to the log; never rendered. */
  internalReason: string;
  suppressed: Surface[];
  permitted: Surface[];
  heading: string;
  body: string[];
  emergencyNumber: EmergencyRouting | null;
  humanContact: { label: string; action: 'OPEN_HUMAN_CONTACT' };
}

/**
 * Scope, decided rather than defaulted (HP-JOB-004 §2.2a): suppress generative
 * health AND commercial content; leave account, itinerary and navigation live.
 *
 * The message was never scanned, so we do not know whether it described
 * symptoms — and a price or booking flow sitting beside an unread symptom
 * description is exactly the adjacency §4.0.6 exists to prevent. In the other
 * direction, taking the whole product down because a rule set is unsigned is a
 * real harm with no safety return.
 */
const SUPPRESSED: Surface[] = [
  'GENERATIVE_HEALTH',
  'PROVIDER_RECOMMENDATION',
  'PRICING',
  'BOOKING',
  'PROMOTIONAL',
];

const PERMITTED: Surface[] = ['ACCOUNT', 'EXISTING_ITINERARY', 'NAVIGATION', 'HUMAN_CONTACT'];

const HEADING = 'We can’t answer health questions right now';

/**
 * Read the copy as a whole before changing a word.
 *
 * It says: the service cannot answer this kind of question, this is about the
 * service and not about you, here is where to go instead.
 *
 * It deliberately does not say: "we didn't find anything concerning" (a
 * clinical claim about an unread message), "you should be fine" (§3.10.3
 * reassurance), "our checks flagged this" (untrue — nothing was checked), or
 * any time-to-care window, which would be §4.4 language the clinical lead has
 * not signed.
 *
 * "We have not reviewed what you wrote" is load-bearing. Without it a refusal
 * reads as a judgement.
 */
function bodyWith(routing: EmergencyRouting | null): string[] {
  return [
    'This part of HealthPlus is unavailable at the moment. We have not reviewed what you wrote, so nothing here is a view about your situation either way.',
    'If you have a symptom or a health concern, please speak to a qualified healthcare professional rather than waiting for this to come back.',
    routing
      ? `If it is an emergency, call ${routing.label} on ${routing.numberE164} now.`
      : // §3.12.1's own prescribed fallback. Correct everywhere, which is why the
        // Charter names it rather than leaving the system to guess a number.
        'If it is an emergency, call your local emergency number now.',
    'Your account, your existing bookings and the rest of the site are still available.',
  ];
}

/**
 * §3.12.1 + §4.5.1(b): the number comes from the maintained reference table,
 * keyed on the patient's stated current location, or it does not come at all.
 * No account address, no model, no per-country default compiled into the app.
 *
 * Never throws. This already runs on a failure path; a second failure must
 * degrade to the generic line, not to a blank screen.
 */
export async function resolveEmergencyNumber(
  statedCountry: string | null,
  language = 'en',
): Promise<EmergencyRouting | null> {
  if (!statedCountry) return null;
  try {
    const { rows } = await db().query<{ id: string; number_e164: string; label: string }>(
      `SELECT id, number_e164, label
         FROM safety.emergency_contact_reference
        WHERE country = $1 AND contact_kind = 'EMERGENCY' AND language = $2 AND active = true
        LIMIT 1`,
      [statedCountry, language],
    );
    const row = rows[0];
    if (!row) return null;
    return {
      numberE164: row.number_e164,
      label: row.label,
      sourceTable: 'safety.emergency_contact_reference',
      sourceRowId: row.id,
    };
  } catch {
    return null;
  }
}

export async function buildUnavailability(
  internalReason: string,
  statedCountry: string | null,
  language = 'en',
): Promise<ServiceUnavailability> {
  const routing = await resolveEmergencyNumber(statedCountry, language);
  return {
    copyVersion: UNAVAILABILITY_COPY_VERSION,
    internalReason,
    suppressed: [...SUPPRESSED],
    permitted: [...PERMITTED],
    heading: HEADING,
    body: bodyWith(routing),
    emergencyNumber: routing,
    humanContact: { label: 'Talk to a person', action: 'OPEN_HUMAN_CONTACT' },
  };
}

/**
 * The phrases that turn a service notice into an unlicensed clinical opinion.
 * Exported so translations can be checked against the same list — the guard is
 * only worth anything if it survives localisation.
 */
export const PROHIBITED_UNAVAILABILITY_PHRASES = [
  'no red flag',
  'nothing concerning',
  'no cause for concern',
  'appears safe',
  'looks fine',
  'nothing urgent',
  "you'll be fine",
  'you will be fine',
  "don't worry",
  'do not worry',
  'nothing to worry about',
  'we have reviewed',
  'our clinicians have',
  'has been reviewed',
] as const;

export function assertNoProhibitedPhrases(text: string): void {
  const haystack = text.toLowerCase().replace(/[’]/g, "'");
  for (const phrase of PROHIBITED_UNAVAILABILITY_PHRASES) {
    if (haystack.includes(phrase)) {
      throw new Error(
        `unavailability copy contains a prohibited phrase (${phrase}) — §3.10.3 / §3.11.3`,
      );
    }
  }
}

/**
 * §4.0.6 suppression, asked rather than inferred. A caller that reads
 * `severity >= WARNING` and then decides for itself what "commercial" covers is
 * how a booking widget ends up still on screen beside a safety block.
 */
export function surfaceGate(args: {
  unavailability: ServiceUnavailability | null;
  severity: RedFlagSeverity;
  severityOrder: Record<RedFlagSeverity, number>;
}): { allows: (s: Surface) => boolean; suppressed: Surface[] } {
  const suppressed = new Set<Surface>();
  if (args.unavailability) {
    for (const s of args.unavailability.suppressed) suppressed.add(s);
  } else if (args.severityOrder[args.severity] >= args.severityOrder['WARNING']) {
    suppressed.add('PROVIDER_RECOMMENDATION');
    suppressed.add('PRICING');
    suppressed.add('BOOKING');
    suppressed.add('PROMOTIONAL');
    if (args.severityOrder[args.severity] >= args.severityOrder['URGENT']) {
      suppressed.add('GENERATIVE_HEALTH');
    }
  }
  return { allows: (s: Surface) => !suppressed.has(s), suppressed: [...suppressed] };
}
