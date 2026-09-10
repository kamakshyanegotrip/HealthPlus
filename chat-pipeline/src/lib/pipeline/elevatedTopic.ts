import { db } from '../db';
import { containsTerm } from './rulePattern';
import type { PipelineContext } from '../types';

/**
 * §2.2.5b TRIGGER 2 — the Elevated-Risk Topic List (§2.4.1).
 *
 * ===========================================================================
 * WHY THIS FILE EXISTS AND DID NOT FOR A YEAR
 *
 * HP-SR-001 §1: *"No implementation anywhere. No topic classifier, no list, no
 * lookup — grep for the list's own terms returns nothing in src/."* With
 * Category C disabled, §2.2.5b is the ENTIRE human-in-the-loop story (§2.2.5d),
 * and this is two of its five triggers' worth of it.
 *
 * The fourteen topics are not a marginal set. They include paediatrics,
 * pregnancy, mental health and anything touching self-harm, oncology,
 * transplant, assisted dying and gender-affirming care.
 *
 * ===========================================================================
 * THREE STATES, AND THE THIRD IS THE ONE THAT MATTERS
 *
 * A boolean cannot express this check honestly, because "no adopted list" is
 * not "no match":
 *
 *   CLEAR        a list is adopted, and none of its terms are in the message
 *   MATCHED      a list is adopted, and these topics matched
 *   UNEVALUABLE  no clinician has adopted a list, so the question cannot be
 *                answered — and §3.0.3 answers an unestablished fact CLOSED
 *
 * `requiresReview` therefore returns true for MATCHED *and* UNEVALUABLE. That
 * is the same shape `minorGateRequiresReview` has for an unestablished age, and
 * the same shape `resolveAdoptionGate` has for an unsigned rule set — where
 * migration 027's comment gives the reason in one line: "returning NORMAL from
 * an empty rule set would make an unsigned deployment look safe while detecting
 * nothing."
 *
 * TODAY THIS IS UNREACHABLE, AND THE DATE IT STOPS BEING SO IS KNOWABLE. §4 is
 * unadopted, so every turn ends in the unavailability notice before reaching
 * any of this. It goes live the day CL2–CL5 are signed — and the topic list is
 * NOT on CGP-001 §9's 90-day schedule, so "rule set signed, topic list not" is
 * the expected intermediate state rather than an unlikely one.
 *
 * ===========================================================================
 * ONE MATCHER, NOT TWO
 *
 * `containsTerm` is imported from rulePattern.ts rather than reimplemented.
 * Both are whole-word, case- and diacritic-insensitive, contiguous-phrase
 * matches, and they must stay identical: a clinician who writes a term on
 * sheet A of the review pack and the same term on sheet D should not get two
 * different behaviours. It also inherits rulePattern's deliberate refusal to
 * handle negation — "no chest pain" still matches — for the reason stated
 * there: a scanner that reasons about negation can talk itself out of a flag.
 *
 * HP-CGP-004 §2a is the evidence that this matters. Written as long phrases,
 * the draft red-flag rules missed thirty of forty gold-set cases; the same
 * failure would apply term-for-term to a topic list. The fix belongs in the
 * TERMS a clinician writes, and the review pack now shows them what the
 * matcher does with what they wrote.
 */

export type TopicCheck =
  | { state: 'UNEVALUABLE' }
  | { state: 'CLEAR' }
  | { state: 'MATCHED'; ordinals: number[]; terms: string[] };

interface TopicRow {
  ordinal: number;
  topic: string;
  terms: string[];
}

/**
 * Reads the adopted list on the REDFLAG pool.
 *
 * Not `db()`. hp_app holds USAGE on `safety` and not one table grant in it —
 * measured, and it is R13-conn's guarantee rather than an accident: the role
 * that takes untrusted user input can reach nothing in that schema. Migration
 * 048 §0.3 records the SELECT grant this file was one line away from asking
 * for, and §4 of it fails the migration if hp_app ever acquires one.
 */
export async function checkElevatedTopics(
  ctx: Pick<PipelineContext, 'message' | 'dataRegion' | 'statedCountry' | 'language'>,
): Promise<TopicCheck> {
  const jurisdiction = ctx.statedCountry ?? ctx.dataRegion;
  const language = ctx.language ?? 'en';

  const { rows } = await db('redflag').query<TopicRow>(
    `SELECT ordinal, topic, terms FROM safety.adopted_topic_list($1::char(2), $2::text)`,
    [jurisdiction, language],
  );

  if (rows.length === 0) return { state: 'UNEVALUABLE' };

  const ordinals: number[] = [];
  const matched: string[] = [];
  for (const row of rows) {
    const hit = row.terms.find((t) => containsTerm(ctx.message, t));
    if (hit !== undefined) {
      ordinals.push(Number(row.ordinal));
      matched.push(hit);
    }
  }
  return ordinals.length ? { state: 'MATCHED', ordinals, terms: matched } : { state: 'CLEAR' };
}

/** True unless a list was adopted AND nothing in it matched. */
export function topicGateRequiresReview(check: TopicCheck): boolean {
  return check.state !== 'CLEAR';
}

/**
 * The audit payload's account of this trigger. Distinguishing the two
 * review-forcing states is the whole reason the check is three-valued: an audit
 * trail that records only "review required" cannot later answer whether the
 * system was checking the topic list or merely had none.
 */
export function topicAuditTrigger(check: TopicCheck): string | null {
  switch (check.state) {
    case 'MATCHED': return 'ELEVATED_TOPIC';
    case 'UNEVALUABLE': return 'ELEVATED_TOPIC_UNEVALUABLE';
    case 'CLEAR': return null;
  }
}
