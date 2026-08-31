import { useCallback, useRef, useState } from 'react';
import { sendChatMessage } from './sseClient';

/**
 * Example React hook for Phase 4.2 — the minimum needed to render an
 * incrementally-arriving, sentence-by-sentence response with its category/
 * severity banners. Not a polished chat component; a starting point that
 * exercises every event route.ts actually emits.
 */

export interface HealthPlusChatState {
  sentences: string[];
  visibleText: string;
  category: 'INFORMATIONAL' | 'DECISION_SUPPORT' | 'CLINICAL_DECISION' | null;
  severity: string | null;
  citedClaimIds: string[];
  notices: string[];
  error: string | null;
  isStreaming: boolean;
}

const initialState: HealthPlusChatState = {
  sentences: [],
  visibleText: '',
  category: null,
  severity: null,
  citedClaimIds: [],
  notices: [],
  error: null,
  isStreaming: false,
};

export function useHealthPlusChat(opts: { sessionId: string; authToken: string; apiBaseUrl?: string }) {
  const [state, setState] = useState<HealthPlusChatState>(initialState);
  const abortRef = useRef<AbortController | null>(null);

  const send = useCallback(
    async (message: string) => {
      abortRef.current?.abort(); // cancel any in-flight turn first
      const controller = new AbortController();
      abortRef.current = controller;

      setState({ ...initialState, isStreaming: true });

      try {
        await sendChatMessage(
          { sessionId: opts.sessionId, message, authToken: opts.authToken, apiBaseUrl: opts.apiBaseUrl, signal: controller.signal },
          {
            category: (d) => setState((s) => ({ ...s, category: d.category })),
            severity: (d) => setState((s) => ({ ...s, severity: d.severity })),
            sentence: (d) =>
              setState((s) => ({
                ...s,
                sentences: [...s.sentences, d.text],
                visibleText: (s.visibleText ? s.visibleText + ' ' : '') + d.text,
                citedClaimIds: Array.from(new Set([...s.citedClaimIds, ...d.citedClaimIds])),
              })),
            notice: (d) => setState((s) => ({ ...s, notices: [...s.notices, d.message] })),
            error: (d) => setState((s) => ({ ...s, error: d.message })),
            done: () => setState((s) => ({ ...s, isStreaming: false })),
          },
        );
      } catch (err) {
        if ((err as Error).name === 'AbortError') return; // user cancelled — not an error state
        setState((s) => ({ ...s, isStreaming: false, error: err instanceof Error ? err.message : 'stream failed' }));
      }
    },
    [opts.sessionId, opts.authToken, opts.apiBaseUrl],
  );

  const stop = useCallback(() => abortRef.current?.abort(), []);

  return { ...state, send, stop };
}
