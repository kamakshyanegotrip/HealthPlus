import { db } from '../db';

/**
 * RF4 — §4.3.2 declared template slots, and the nearest-ED half of §3.12.1.
 *
 * ── WHAT WAS MISSING ────────────────────────────────────────────────────────
 *
 * Two halves of one gap.
 *
 * 1. `safety.emergency_facility_reference` has existed since migration 027 and
 *    nothing has ever read it. §4.1's CRITICAL and EMERGENCY rows both name a
 *    nearest emergency department; §3.12.1 forbids the model producing one.
 *    So the only lawful source of that sentence had no reader.
 *
 * 2. There is no slot renderer at all. route.ts does
 *    `templateText = loadedTemplate.body` and sends it. `safety_template.slots`
 *    is selected by templateResolution.ts, carried through, and never used by
 *    anything. A template body containing a placeholder would have reached a
 *    user in an emergency with the placeholder still in it.
 *
 * ── §4.3.2, WHICH IS NARROWER THAN IT LOOKS ─────────────────────────────────
 *
 * "The model MAY select a template ID and fill declared, typed slots (user's
 * name, city, emergency number from the reference table). It MUST NOT rewrite,
 * summarise, soften, or extend template body text."
 *
 * Three constraints fall out, and this module is built around them:
 *
 *   * Only DECLARED slots are filled. A token in the body that the template
 *     does not declare is not a slot — it is a defect, and it is handled as
 *     one below rather than guessed at.
 *   * Values come from reference tables, never from the model and never from
 *     an account record. The renderer takes no free text.
 *   * Nothing else about the body changes. This module substitutes and, where
 *     the template's own author declared it, removes a line. It never rewords.
 *
 * ── THE HARD CASE: A SLOT THAT CANNOT BE RESOLVED ───────────────────────────
 *
 * Today `emergency_facility_reference` is empty — Job 18 populates it — so the
 * nearest-ED slot resolves to nothing on every request. Three ways to handle
 * that, two of them wrong:
 *
 *   leave the token   -> a person in an emergency reads "{{nearest_ed}}".
 *                        Not acceptable under any reading of §4.0.5.
 *   strip it silently -> the system edits clinician-approved emergency text,
 *                        which is the exact thing §4.3.2 forbids.
 *   fail closed       -> withholds an emergency instruction. §4.0.5 says the
 *                        safety instruction is never gated.
 *
 * So the template's author decides, per slot, in the slot declaration:
 *
 *   OMIT_LINE  the line containing the token is dropped. This is a clinician
 *              authoring the behaviour ("if you don't know the nearest ED,
 *              don't print that line"), not the system editing their text.
 *              Migration 027 §2 already anticipated exactly this: "until Job 18
 *              runs, slot resolution returns UNRESOLVED and the template
 *              renders with the emergency number alone."
 *   REQUIRED   the template is not renderable. The caller escalates up the
 *              §4.3.3 ladder to the next template — fail-safe UPWARD, never
 *              down, and never to generative output (§4.0.9).
 *
 * An UNDECLARED token is treated as REQUIRED-and-unresolvable. A malformed
 * template is not a template we can reason about, and guessing what the author
 * meant is worse than climbing to the next one.
 *
 * ── PROVENANCE ──────────────────────────────────────────────────────────────
 *
 * Every resolved value carries the table and row id it came from, so
 * TEMPLATE_RENDERED records which maintained row produced the routing a person
 * was told to act on. §3.12.1 forbids generating that sentence; an audit trail
 * that cannot say where it came from cannot demonstrate that we did not.
 */

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

/**
 * The kinds a slot may have. Closed on purpose: a template cannot declare a
 * slot this module does not know how to source, because "source" means a
 * specific maintained table and nothing else.
 */
export type SlotKind =
  | 'EMERGENCY_NUMBER' // safety.emergency_contact_reference
  | 'NEAREST_ED' // safety.emergency_facility_reference
  | 'NEAREST_ED_PHONE' // ditto, the facility's own number
  | 'CITY'; // the patient's STATED location, never an account address

export type OnUnresolved = 'OMIT_LINE' | 'REQUIRED';

export interface DeclaredSlot {
  kind: SlotKind;
  on_unresolved: OnUnresolved;
}

export interface SlotResolution {
  name: string;
  kind: SlotKind;
  value: string | null;
  sourceTable: string | null;
  sourceRowId: string | null;
}

export interface RenderedTemplate {
  /** Ready to send. No placeholders survive here, ever. */
  text: string;
  /** What each declared slot resolved to. Goes to TEMPLATE_RENDERED. */
  resolutions: SlotResolution[];
  /** Lines dropped because an OMIT_LINE slot did not resolve. */
  omittedLines: number;
  /**
   * Set when the body could not be rendered at all — a REQUIRED slot did not
   * resolve, or the body carries a token the template does not declare. The
   * caller must climb the ladder rather than send anything.
   */
  unrenderable: string | null;
}

/** `{{slot_name}}`. Deliberately not a general expression language. */
const TOKEN = /\{\{\s*([a-z0-9_]+)\s*\}\}/gi;

// ---------------------------------------------------------------------------
// Parsing the declaration
// ---------------------------------------------------------------------------

const KINDS: SlotKind[] = ['EMERGENCY_NUMBER', 'NEAREST_ED', 'NEAREST_ED_PHONE', 'CITY'];
const UNRESOLVED: OnUnresolved[] = ['OMIT_LINE', 'REQUIRED'];

/**
 * `safety_template.slots` is jsonb, so anything at all can be in it. A
 * declaration this module cannot understand is dropped rather than guessed,
 * which turns its token into an undeclared one and makes the template
 * unrenderable — the safe direction.
 */
export function parseSlotDeclarations(slots: unknown): Record<string, DeclaredSlot> {
  if (!slots || typeof slots !== 'object' || Array.isArray(slots)) return {};
  const out: Record<string, DeclaredSlot> = {};
  for (const [name, raw] of Object.entries(slots as Record<string, unknown>)) {
    if (!raw || typeof raw !== 'object') continue;
    const kind = (raw as Record<string, unknown>).kind;
    const onUnresolved = (raw as Record<string, unknown>).on_unresolved;
    if (typeof kind !== 'string' || !KINDS.includes(kind as SlotKind)) continue;
    // A declaration that omits on_unresolved gets the strict reading. An
    // author who wants a line dropped has to say so; silence must not mean
    // "quietly remove part of an emergency instruction".
    const mode: OnUnresolved =
      typeof onUnresolved === 'string' && UNRESOLVED.includes(onUnresolved as OnUnresolved)
        ? (onUnresolved as OnUnresolved)
        : 'REQUIRED';
    out[name] = { kind: kind as SlotKind, on_unresolved: mode };
  }
  return out;
}

// ---------------------------------------------------------------------------
// Sourcing — reference tables only
// ---------------------------------------------------------------------------

export interface NearestFacility {
  id: string;
  facilityName: string;
  addressLine: string;
  phoneE164: string | null;
}

/**
 * §3.12.1's facility half, mirroring resolveEmergencyNumber's contract in
 * unavailability.ts: keyed on the patient's STATED location, never throws,
 * returns null rather than a guess.
 *
 * Only facilities that actually have an emergency department and are active.
 * `open_24h` is preferred but not required — a hospital that is shut at 3am is
 * still the right answer at 3pm, and refusing to name one at all because we
 * cannot guarantee the hour would be a worse failure than naming one with its
 * hours attached.
 *
 * A row whose city or subdivision is NULL is a country- or region-level entry
 * and is eligible everywhere in that scope. A row naming a DIFFERENT city is
 * not eligible at all: naming an emergency department 1,400 km away is worse
 * than naming none, because the actionable instruction is the emergency number
 * beside it and a wrong address competes with it for attention.
 *
 * Among the eligible, narrowest wins: city match, then subdivision match, then
 * open_24h, then most recently verified.
 */
export async function resolveNearestFacility(
  statedCountry: string | null,
  statedSubdivision: string | null,
  statedCity: string | null,
  language = 'en',
): Promise<NearestFacility | null> {
  if (!statedCountry) return null;
  try {
    const { rows } = await db().query<{
      id: string;
      facility_name: string;
      address_line: string;
      phone_e164: string | null;
    }>(
      `SELECT id, facility_name, address_line, phone_e164
         FROM safety.emergency_facility_reference
        WHERE country = $1
          AND active
          AND has_emergency_department
          AND language = $4
          AND (subdivision IS NULL OR subdivision = $2::text)
          AND (city IS NULL OR city = $3::text)
        ORDER BY (city IS NOT NULL AND city = $3::text) DESC,
                 (subdivision IS NOT NULL AND subdivision = $2::text) DESC,
                 open_24h DESC,
                 last_verified_at DESC
        LIMIT 1`,
      [statedCountry, statedSubdivision, statedCity, language],
    );
    const row = rows[0];
    if (!row) return null;
    return {
      id: row.id,
      facilityName: row.facility_name,
      addressLine: row.address_line,
      phoneE164: row.phone_e164,
    };
  } catch {
    // Same reasoning as resolveEmergencyNumber: this runs on the emergency
    // path. A second failure degrades to "we do not name a facility", not to
    // an exception that takes the whole instruction down.
    return null;
  }
}

export interface SlotSources {
  emergencyNumber?: { numberE164: string; sourceTable: string; sourceRowId: string } | null;
  facility?: NearestFacility | null;
  statedCity?: string | null;
}

/** Maps a declared kind onto the already-fetched sources. Pure. */
export function valueForKind(kind: SlotKind, s: SlotSources): Omit<SlotResolution, 'name' | 'kind'> {
  switch (kind) {
    case 'EMERGENCY_NUMBER':
      return s.emergencyNumber
        ? {
            value: s.emergencyNumber.numberE164,
            sourceTable: s.emergencyNumber.sourceTable,
            sourceRowId: s.emergencyNumber.sourceRowId,
          }
        : { value: null, sourceTable: null, sourceRowId: null };
    case 'NEAREST_ED':
      return s.facility
        ? {
            value: `${s.facility.facilityName}, ${s.facility.addressLine}`,
            sourceTable: 'safety.emergency_facility_reference',
            sourceRowId: s.facility.id,
          }
        : { value: null, sourceTable: null, sourceRowId: null };
    case 'NEAREST_ED_PHONE':
      return s.facility?.phoneE164
        ? {
            value: s.facility.phoneE164,
            sourceTable: 'safety.emergency_facility_reference',
            sourceRowId: s.facility.id,
          }
        : { value: null, sourceTable: null, sourceRowId: null };
    case 'CITY':
      // The STATED city. Not an account address — §4.5.1(b) and the same rule
      // resolveEmergencyNumber follows.
      return s.statedCity
        ? { value: s.statedCity, sourceTable: 'stated', sourceRowId: null }
        : { value: null, sourceTable: null, sourceRowId: null };
  }
}

// ---------------------------------------------------------------------------
// Rendering — pure, so it is testable without a database
// ---------------------------------------------------------------------------

export function renderTemplate(
  body: string,
  declarations: Record<string, DeclaredSlot>,
  sources: SlotSources,
): RenderedTemplate {
  const resolutions: SlotResolution[] = [];
  const values = new Map<string, string | null>();

  for (const [name, decl] of Object.entries(declarations)) {
    const r = valueForKind(decl.kind, sources);
    values.set(name, r.value);
    resolutions.push({ name, kind: decl.kind, value: r.value, sourceTable: r.sourceTable, sourceRowId: r.sourceRowId });
  }

  // An undeclared token means the body and its declaration disagree. We cannot
  // know what the author intended, and a template we cannot reason about is
  // one to climb past rather than to improvise on.
  const undeclared = [...body.matchAll(TOKEN)]
    .map((m) => m[1]!.toLowerCase())
    .filter((n) => !(n in declarations));
  if (undeclared.length) {
    return {
      text: '',
      resolutions,
      omittedLines: 0,
      unrenderable: `template body carries undeclared slot(s): ${[...new Set(undeclared)].join(', ')}`,
    };
  }

  const missingRequired = Object.entries(declarations)
    .filter(([name, d]) => d.on_unresolved === 'REQUIRED' && !values.get(name))
    .map(([name]) => name);
  if (missingRequired.length) {
    return {
      text: '',
      resolutions,
      omittedLines: 0,
      unrenderable: `required slot(s) did not resolve: ${missingRequired.join(', ')}`,
    };
  }

  // Line-wise, because OMIT_LINE is defined on lines. Everything else is a
  // straight substitution.
  let omittedLines = 0;
  const kept: string[] = [];
  for (const line of body.split('\n')) {
    const names = [...line.matchAll(TOKEN)].map((m) => m[1]!.toLowerCase());
    const dropped = names.some((n) => declarations[n]?.on_unresolved === 'OMIT_LINE' && !values.get(n));
    if (dropped) {
      omittedLines += 1;
      continue;
    }
    kept.push(line.replace(TOKEN, (_full, raw: string) => values.get(raw.toLowerCase()) ?? ''));
  }

  return { text: kept.join('\n'), resolutions, omittedLines, unrenderable: null };
}

/**
 * The database-backed entry point. Fetches only the sources the template
 * actually declares — a template with no slots costs no queries, which is the
 * case for every template that exists today.
 */
export async function renderSafetyTemplate(
  body: string,
  slots: unknown,
  ctx: {
    statedCountry: string | null;
    statedSubdivision?: string | null;
    statedCity?: string | null;
    language?: string;
  },
  deps: {
    resolveEmergencyNumber: (
      country: string | null,
      language?: string,
    ) => Promise<{ numberE164: string; sourceTable: string; sourceRowId: string } | null>;
    resolveNearestFacility?: typeof resolveNearestFacility;
  },
): Promise<RenderedTemplate> {
  const declarations = parseSlotDeclarations(slots);
  const kinds = new Set(Object.values(declarations).map((d) => d.kind));
  const language = ctx.language ?? 'en';

  const sources: SlotSources = { statedCity: ctx.statedCity ?? null };

  if (kinds.has('EMERGENCY_NUMBER')) {
    sources.emergencyNumber = await deps.resolveEmergencyNumber(ctx.statedCountry, language);
  }
  if (kinds.has('NEAREST_ED') || kinds.has('NEAREST_ED_PHONE')) {
    const find = deps.resolveNearestFacility ?? resolveNearestFacility;
    sources.facility = await find(
      ctx.statedCountry,
      ctx.statedSubdivision ?? null,
      ctx.statedCity ?? null,
      language,
    );
  }

  return renderTemplate(body, declarations, sources);
}

/**
 * Adapter: turns this module into templateResolution.ts's `PrepareTemplate`
 * hook, so the §4.3.3 ladder skips a template whose slots cannot be filled.
 *
 * `resolveEmergencyNumber` is injected rather than imported to keep the
 * dependency pointing one way — unavailability.ts already owns the emergency
 * number, and importing it here would make these two modules mutually
 * dependent for no gain.
 */
export function makePrepareTemplate(
  ctx: { statedCountry?: string | null; statedSubdivision?: string | null; statedCity?: string | null },
  language: string,
  resolveEmergencyNumber: (
    country: string | null,
    language?: string,
  ) => Promise<{ numberE164: string; sourceTable: string; sourceRowId: string } | null>,
) {
  return async (row: { body: string; slots: unknown }) => {
    const out = await renderSafetyTemplate(
      row.body,
      row.slots,
      {
        statedCountry: ctx.statedCountry ?? null,
        statedSubdivision: ctx.statedSubdivision ?? null,
        statedCity: ctx.statedCity ?? null,
        language,
      },
      { resolveEmergencyNumber },
    );
    if (out.unrenderable) return { ok: false as const, reason: out.unrenderable };
    return {
      ok: true as const,
      text: out.text,
      detail: { resolutions: out.resolutions, omittedLines: out.omittedLines },
    };
  };
}
