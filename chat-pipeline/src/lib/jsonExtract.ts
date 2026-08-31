/**
 * FOUND BY LIVE MODEL EXECUTION, NOT REVIEW — the same lesson this whole
 * repo keeps re-learning by running code instead of reading it (see
 * HP-SEC-001 §5, and this repo's own README "What changed" sections for two
 * earlier examples). The very first real call ever made to
 * CATEGORY_CLASSIFIER (via `npm run smoke:live`, a real Haiku call, not a
 * mock) returned:
 *
 *   ```json
 *   { "category": "INFORMATIONAL", "confidence": 0.95, "ambiguousBetween": [] }
 *   ```
 *   **Reasoning:**
 *   This is a straightforward request for general, population-level ...
 *
 * — even though the prompt says "Output strict JSON only." A bare
 * `JSON.parse(rawText)` throws on the leading backtick, and every call site
 * that did that (categoryClassifier.ts, redFlagEngine.ts,
 * intentComplexity.ts) silently fell back to its fail-closed/fail-safe
 * default. For the category classifier specifically, that default is
 * CLINICAL_DECISION — meaning, before this fix, a real production request
 * would have been refused via the §2.3.6 static template on essentially
 * every call, regardless of what the model actually said, because the
 * model's real judgment never survived parsing. Every previous test of
 * these three parsers used hand-written, already-clean JSON fixtures (see
 * test/*.test.ts, eval/gold/*.json) — none of them could have caught this;
 * only a real model call could, and did.
 *
 * This function widens what counts as "the JSON" a caller will accept. It
 * does NOT change what happens when nothing parseable is found — every call
 * site's existing try/catch and fail-closed/fail-safe default is unchanged
 * and remains the real safety net. This is a defensive extraction layer,
 * not a trust upgrade: still exactly one JSON.parse, just given better input.
 */
export function extractJsonObject(rawText: string): string {
  const trimmed = rawText.trim();

  // Fast path: already-clean JSON — also what every existing mocked test
  // fixture provides, so this keeps every prior test's fixture behavior
  // byte-for-byte unchanged.
  if (isParseable(trimmed)) return trimmed;

  // A markdown code fence, with or without a `json` language tag — the
  // real-world shape confirmed above.
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced?.[1] !== undefined) {
    const inner = fenced[1].trim();
    if (isParseable(inner)) return inner;
    const spanned = firstBraceSpan(inner);
    if (spanned) return spanned;
  }

  // No fence (or the fenced content still wasn't clean JSON) — fall back to
  // the first top-level {...} span anywhere in the raw text, which also
  // handles leading/trailing prose with no code fence at all.
  const spanned = firstBraceSpan(trimmed);
  if (spanned) return spanned;

  // Nothing extractable — return the original text unchanged, so
  // JSON.parse throws exactly the way it always did, and the caller's
  // existing fail-closed/fail-safe default still applies.
  return rawText;
}

function isParseable(text: string): boolean {
  try {
    JSON.parse(text);
    return true;
  } catch {
    return false;
  }
}

function firstBraceSpan(text: string): string | null {
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end <= start) return null;
  const candidate = text.slice(start, end + 1);
  return isParseable(candidate) ? candidate : null;
}
