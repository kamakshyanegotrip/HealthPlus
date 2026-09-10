import type { ResponseCategory } from '../types';

/**
 * Charter-mandated disclosure strings, rendered as UI chrome.
 *
 * ---------------------------------------------------------------------------
 * THIS CLOSES A GAP, IT DOES NOT REFACTOR ONE
 *
 * §2.1.5 and §2.2.4 are both marked mandatory, and §2.1.5 additionally says
 * "rendered as UI chrome, not model output". Before this file, a search across
 * the whole repository for either string returned nothing: no module rendered
 * them, no test asserted them, and the SSE stream carried no event that could
 * have delivered them. Every response this pipeline has ever produced shipped
 * without its mandatory disclaimer.
 *
 * That is not a cosmetic omission. §2.2.4's long form is the clause that tells
 * the reader the costs are not quotations and that only an assessing clinician
 * can say whether an option suits them — which is precisely the load-bearing
 * sentence when the composer has just spent nine paragraphs comparing hospitals
 * for someone's knee.
 *
 * ---------------------------------------------------------------------------
 * WHY THESE ARE FROZEN CONSTANTS AND NOT PROMPT TEXT
 *
 * The Charter says "rendered as UI chrome, not model output" for §2.1.5 and
 * gives §2.2.4 as a quoted block. A disclaimer the composer writes is a
 * disclaimer the composer can soften, shorten, or contextualise away — the same
 * argument §4.3.2 makes about safety templates ("MUST NOT rewrite, summarise,
 * soften, or extend template body text"), applied one clause earlier. So these
 * never enter the model's context as something to reproduce; they are emitted
 * by the pipeline alongside the stream, on their own SSE event.
 *
 * `test/disclosure.test.ts` pins each string by SHA-256. A well-meaning edit to
 * "improve the wording" fails CI with the clause number in the message. If the
 * wording genuinely should change, that is a §6.3 Charter amendment and the
 * hash moves with it, deliberately.
 */

/** §2.1.5 — Category A short form, verbatim. */
export const DISCLAIMER_INFORMATIONAL =
  'General information only. This is not medical advice and is not specific to your ' +
  'situation. Talk to a qualified healthcare professional about your own care.';

/** §2.2.4 — Category B long form, verbatim. */
export const DISCLAIMER_DECISION_SUPPORT =
  'This comparison is decision support, not medical advice. It is based on the sources ' +
  'cited and may be incomplete or out of date. Costs shown are indicative estimates, not ' +
  'quotations. Whether any of these options is appropriate for you can only be determined ' +
  'by a qualified clinician who has assessed you. Confirm all clinical, cost, legal and ' +
  'visa details directly with the provider and the relevant authorities before making ' +
  'arrangements.';

/**
 * §3.3.9 — the mandatory cost string. `[source]` and `[date]` are the Charter's
 * own slot markers; `costString()` fills them from the persisted claim record,
 * never from model text (§1.9.5).
 */
export const COST_STRING_TEMPLATE =
  'Indicative estimate only, based on [source] as of [date]. Not a quotation. Final cost ' +
  'is set by the provider after assessment and may differ.';

export function costString(sourceLabel: string, asOfDate: string): string {
  return COST_STRING_TEMPLATE.replace('[source]', sourceLabel).replace('[date]', asOfDate);
}

/**
 * §2.0.5 — the ICMR autonomy principle's human-contact route. "The offer is
 * presented at first contact and remains available in every session", so it
 * rides with every disclosure block rather than being a first-turn special
 * case the client has to remember to keep showing.
 */
export const HUMAN_CONTACT_OFFER =
  'You can decline AI-generated content at any point and ask to be put in touch with a ' +
  'person instead.';

/**
 * §3.11.4 — "MUST NOT adopt a persona that obscures its nature as an automated
 * system, and MUST identify itself as such on request AND AT FIRST CONTACT in
 * every session." Emitted with the disclosure block on the session's first
 * turn; `firstContact` is the caller's to determine.
 */
export const AUTOMATED_SYSTEM_NOTICE =
  'You are talking to an automated system, not a clinician.';

export interface DisclosureBlock {
  /** The clause this block's disclaimer text comes from, for the audit record. */
  clause: '2.1.5' | '2.2.4';
  disclaimer: string;
  humanContactOffer: string;
  /** Non-null only on the session's first turn (§3.11.4). */
  automatedSystemNotice: string | null;
}

/**
 * The one construction site, so no surface invents its own pairing of category
 * to clause. CLINICAL_DECISION is deliberately not a branch: §2.3.7's disclaimer
 * belongs to a category that cannot be published in v1 (§2.3.2,
 * c_category_c_disabled_v1), and a response that DEFERS its Category C
 * components under §2.3.6 is not a Category C response — it publishes under the
 * category its answerable content earns, and carries that category's disclaimer.
 * See coveragePlan.ts for why that is the correct reading of §2.0.2 rather than
 * a convenient one.
 */
export function disclosureFor(
  category: Exclude<ResponseCategory, 'CLINICAL_DECISION'>,
  opts: { firstContact: boolean },
): DisclosureBlock {
  return {
    clause: category === 'DECISION_SUPPORT' ? '2.2.4' : '2.1.5',
    disclaimer: category === 'DECISION_SUPPORT' ? DISCLAIMER_DECISION_SUPPORT : DISCLAIMER_INFORMATIONAL,
    humanContactOffer: HUMAN_CONTACT_OFFER,
    automatedSystemNotice: opts.firstContact ? AUTOMATED_SYSTEM_NOTICE : null,
  };
}
