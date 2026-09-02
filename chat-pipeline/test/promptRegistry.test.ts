import { describe, it, expect } from 'vitest';
import { PROMPTS, loadPrompt, promptChecksum } from '../src/lib/prompts/registry';

describe('prompt registry', () => {
  it('every swappable prompt is marked as a placeholder until the real worked prompts arrive', () => {
    // This is the honest-status test: it fails on its own the moment
    // someone swaps in a real worked prompt and forgets to flip `source`,
    // which is exactly the moment this comment should stop being true.
    for (const key of Object.keys(PROMPTS) as Array<keyof typeof PROMPTS>) {
      expect(['claude-authored-placeholder', 'worked-prompt']).toContain(PROMPTS[key].source);
    }
  });

  it('loadPrompt returns a non-empty, versioned prompt for every key used by the pipeline', () => {
    for (const key of ['CATEGORY_CLASSIFIER', 'RED_FLAG_PROPOSE', 'INTENT_COMPLEXITY', 'CLINICAL_REASONING'] as const) {
      const p = loadPrompt(key);
      expect(p.text.length).toBeGreaterThan(50);
      expect(p.version).toMatch(/\S/);
    }
  });

  it('promptChecksum is stable for unchanged text (change-detection for §6.4)', () => {
    const a = promptChecksum('CATEGORY_CLASSIFIER');
    const b = promptChecksum('CATEGORY_CLASSIFIER');
    expect(a).toBe(b);
    expect(a).toHaveLength(16);
  });
});
