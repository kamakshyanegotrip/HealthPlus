/**
 * R3 — structured red-flag rule patterns.
 *
 * Charter §4.0.3 describes the rule set as "pattern, keyword and
 * structured-symptom rules", and the committed schema agrees:
 * `safety.red_flag_rule.pattern` is **jsonb** in
 * migrations/001_003_reconciled_baseline.sql.
 *
 * Until now this pipeline stored `pattern text` and evaluated it with
 * `new RegExp(pattern, 'i')`. That is a different rule-evaluation model, not a
 * different encoding of the same one, and the difference has teeth:
 *
 *   - A regex cannot express "temperature ≥ 38 °C" without also matching 38 °F,
 *     and §3.5.3 forbids converting between units without a sourced factor. A
 *     threshold rule needs the unit as data, not as a hope about the string.
 *   - A regex over the raw message cannot see structured symptom codes at all,
 *     so §4.5's medical-tourism triggers (post-op returned home, recent flight)
 *     had no way to fire.
 *   - A malformed regex silently matched nothing. A malformed structured
 *     pattern is a parse error the loader can reject.
 *
 * Everything here is pure: no I/O, no clock. That is what lets the §6.4 gold
 * set regress against it reproducibly.
 */

export type RulePattern =
  /** Every listed symptom code present. */
  | { kind: 'SYMPTOM_ALL'; codes: string[] }
  /** Any one of the listed symptom codes present. */
  | { kind: 'SYMPTOM_ANY'; codes: string[] }
  /** A hard threshold on a vital or lab value, with its unit. */
  | {
      kind: 'THRESHOLD';
      source: 'VITAL' | 'LAB';
      code: string;
      op: 'GT' | 'GTE' | 'LT' | 'LTE';
      value: number;
      unit: string;
    }
  /** Whole-word, case- and diacritic-insensitive keyword match on the message. */
  | { kind: 'KEYWORD_ANY'; terms: string[] }
  | { kind: 'KEYWORD_ALL'; terms: string[] }
  /** §4.5 medical-tourism context predicates. */
  | { kind: 'TRAVEL_CONTEXT'; predicate: TravelPredicate }
  /** Conjunction. Every child must match. */
  | { kind: 'ALL_OF'; children: RulePattern[] };

export type TravelPredicate =
  | 'POST_OP_RETURNED_HOME'
  | 'CURRENTLY_ABROAD'
  | 'PRE_TRAVEL'
  | 'RECENT_FLIGHT'
  | 'PROCEDURE_VIA_PLATFORM';

/**
 * What a pattern is evaluated against. Only `message` is populated by the
 * pipeline today; the structured fields arrive when patientProfile carries
 * symptoms and vitals. Structured patterns simply do not match until then,
 * which is the correct behaviour — a rule that cannot be evaluated must not
 * fire, and must not silently be treated as evaluated either.
 */
export interface PatternInput {
  message: string;
  symptoms?: Array<{ code: string; present: boolean }>;
  vitals?: Array<{ code: string; value: number; unit: string }>;
  labs?: Array<{ code: string; value: number; unit: string }>;
  travel?: {
    postOperative?: boolean;
    returnedHome?: boolean;
    currentlyAbroad?: boolean;
    preTravel?: boolean;
    recentFlightHours?: number;
    procedureBookedThroughPlatform?: boolean;
  };
}

export class MalformedRulePatternError extends Error {
  readonly clause = 'HP-ESC §4.0.3';
  constructor(message: string) {
    super(message);
    this.name = 'MalformedRulePatternError';
  }
}

const PREDICATES: TravelPredicate[] = [
  'POST_OP_RETURNED_HOME',
  'CURRENTLY_ABROAD',
  'PRE_TRAVEL',
  'RECENT_FLIGHT',
  'PROCEDURE_VIA_PLATFORM',
];

/**
 * Validate a jsonb value into a RulePattern.
 *
 * Strict by design. A rule row whose pattern does not parse is a rule nobody
 * can evaluate, and the caller treats that as a scanner fault rather than as a
 * non-match — §4.0.9 forbids failing open, and "the pattern was gibberish so
 * nothing matched" is failing open with extra steps.
 */
export function parseRulePattern(raw: unknown, ruleId = '<unknown>'): RulePattern {
  const bad = (why: string): never => {
    throw new MalformedRulePatternError(`rule ${ruleId}: ${why}`);
  };
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return bad('pattern must be a JSON object');
  }
  const p = raw as Record<string, unknown>;
  const strArray = (v: unknown, field: string): string[] => {
    if (!Array.isArray(v) || v.length === 0 || !v.every((x) => typeof x === 'string' && x.length > 0)) {
      return bad(`${field} must be a non-empty array of non-empty strings`);
    }
    return v as string[];
  };

  switch (p.kind) {
    case 'SYMPTOM_ALL':
      return { kind: 'SYMPTOM_ALL', codes: strArray(p.codes, 'codes') };
    case 'SYMPTOM_ANY':
      return { kind: 'SYMPTOM_ANY', codes: strArray(p.codes, 'codes') };
    case 'KEYWORD_ANY':
      return { kind: 'KEYWORD_ANY', terms: strArray(p.terms, 'terms') };
    case 'KEYWORD_ALL':
      return { kind: 'KEYWORD_ALL', terms: strArray(p.terms, 'terms') };
    case 'THRESHOLD': {
      if (p.source !== 'VITAL' && p.source !== 'LAB') return bad("source must be 'VITAL' or 'LAB'");
      if (typeof p.code !== 'string' || !p.code) return bad('code must be a non-empty string');
      if (!['GT', 'GTE', 'LT', 'LTE'].includes(p.op as string)) return bad('op must be GT|GTE|LT|LTE');
      if (typeof p.value !== 'number' || !Number.isFinite(p.value)) return bad('value must be a finite number');
      // The unit is mandatory. §3.5.3 forbids converting between units without
      // a sourced factor, so a threshold with no unit is not under-specified,
      // it is unsafe: 38 means one thing in °C and another in °F.
      if (typeof p.unit !== 'string' || !p.unit) return bad('unit is required on a THRESHOLD (§3.5.3)');
      return {
        kind: 'THRESHOLD',
        source: p.source,
        code: p.code,
        op: p.op as 'GT' | 'GTE' | 'LT' | 'LTE',
        value: p.value,
        unit: p.unit,
      };
    }
    case 'TRAVEL_CONTEXT': {
      if (!PREDICATES.includes(p.predicate as TravelPredicate)) {
        return bad(`predicate must be one of ${PREDICATES.join('|')}`);
      }
      return { kind: 'TRAVEL_CONTEXT', predicate: p.predicate as TravelPredicate };
    }
    case 'ALL_OF': {
      if (!Array.isArray(p.children) || p.children.length === 0) {
        return bad('ALL_OF needs a non-empty children array');
      }
      return { kind: 'ALL_OF', children: p.children.map((c, i) => parseRulePattern(c, `${ruleId}[${i}]`)) };
    }
    default:
      return bad(`unknown pattern kind ${JSON.stringify(p.kind)}`);
  }
}

/**
 * Evaluate. Returns the matched detail (for trigger_detail) or null.
 *
 * The detail records WHICH PATTERN matched, never what the user wrote:
 * safety.red_flag_log and red_flag_event are read by anyone measuring safety
 * and must not become a second store of personal health data (§4.0.7).
 */
export function matchPattern(pattern: RulePattern, input: PatternInput): Record<string, unknown> | null {
  switch (pattern.kind) {
    case 'SYMPTOM_ALL': {
      const all = pattern.codes.every((c) => symptomPresent(input, c));
      return all ? { kind: 'SYMPTOM_ALL', codes: pattern.codes } : null;
    }
    case 'SYMPTOM_ANY': {
      const hit = pattern.codes.find((c) => symptomPresent(input, c));
      return hit ? { kind: 'SYMPTOM_ANY', matched: hit } : null;
    }
    case 'THRESHOLD': {
      const pool = (pattern.source === 'VITAL' ? input.vitals : input.labs) ?? [];
      const obs = pool.find((o) => o.code === pattern.code);
      if (!obs) return null;
      // A unit mismatch is not a near-miss to be coerced. 38 °C and 38 °F are
      // different facts; §3.5.3 forbids converting without a sourced factor, so
      // the rule abstains and the message falls through to the model channel,
      // which may still raise it.
      if (obs.unit !== pattern.unit) return null;
      const ok =
        pattern.op === 'GT' ? obs.value > pattern.value
        : pattern.op === 'GTE' ? obs.value >= pattern.value
        : pattern.op === 'LT' ? obs.value < pattern.value
        : obs.value <= pattern.value;
      return ok
        ? { kind: 'THRESHOLD', code: pattern.code, op: pattern.op, threshold: pattern.value, unit: pattern.unit }
        : null;
    }
    case 'KEYWORD_ANY': {
      const hit = pattern.terms.find((t) => containsTerm(input.message, t));
      return hit ? { kind: 'KEYWORD_ANY', matched: hit } : null;
    }
    case 'KEYWORD_ALL': {
      const all = pattern.terms.every((t) => containsTerm(input.message, t));
      return all ? { kind: 'KEYWORD_ALL', terms: pattern.terms } : null;
    }
    case 'TRAVEL_CONTEXT': {
      return travelHolds(pattern.predicate, input)
        ? { kind: 'TRAVEL_CONTEXT', predicate: pattern.predicate }
        : null;
    }
    case 'ALL_OF': {
      const details: Record<string, unknown>[] = [];
      for (const child of pattern.children) {
        const d = matchPattern(child, input);
        if (!d) return null;
        details.push(d);
      }
      return { kind: 'ALL_OF', children: details };
    }
  }
}

function symptomPresent(input: PatternInput, code: string): boolean {
  return (input.symptoms ?? []).some((s) => s.code === code && s.present);
}

/**
 * Whole-word, case- and diacritic-insensitive.
 *
 * Substring matching is wrong in both directions: "chest painting" is a false
 * positive a naive `includes` produces, and a false positive at EMERGENCY takes
 * over the user's screen.
 *
 * Negation is deliberately NOT handled: "no chest pain" still matches, and the
 * message is assessed upward. §4.0.4 resolves ambiguity upward, and a scanner
 * that reasons about negation is a scanner that can talk itself out of a red
 * flag.
 */
export function containsTerm(text: string, term: string): boolean {
  const haystack = normalise(text);
  const needle = normalise(term);
  if (!needle) return false;
  const re = new RegExp(`(?:^|[^\\p{L}\\p{N}])${escapeRegExp(needle)}(?:$|[^\\p{L}\\p{N}])`, 'u');
  return re.test(haystack);
}

function normalise(s: string): string {
  return s.normalize('NFKD').replace(/\p{Diacritic}/gu, '').toLowerCase();
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function travelHolds(p: TravelPredicate, input: PatternInput): boolean {
  const t = input.travel ?? {};
  switch (p) {
    case 'POST_OP_RETURNED_HOME': return !!t.postOperative && !!t.returnedHome;
    case 'CURRENTLY_ABROAD':      return !!t.currentlyAbroad;
    case 'PRE_TRAVEL':            return !!t.preTravel;
    case 'RECENT_FLIGHT':         return typeof t.recentFlightHours === 'number' && t.recentFlightHours > 0;
    case 'PROCEDURE_VIA_PLATFORM':return !!t.procedureBookedThroughPlatform;
  }
}
