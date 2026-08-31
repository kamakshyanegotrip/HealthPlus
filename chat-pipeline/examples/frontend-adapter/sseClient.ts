/**
 * Framework-agnostic client for /api/chat's SSE stream.
 *
 * NOT the browser `EventSource` API — deliberately. EventSource only issues
 * GET requests and cannot set an Authorization header, and this route needs
 * both (a POST body carrying sessionId/message, and a Bearer JWT per
 * HP-SEC-001). This instead does a `fetch()` with a streamed body and a
 * small hand-rolled SSE frame parser — the wire format is still standard
 * SSE (`event: <name>\ndata: <json>\n\n`), just consumed manually instead of
 * through the browser's built-in client.
 *
 * This is the piece explicitly missing from the original delivery: a
 * client adapter for the Phase 4.2 frontend to actually consume the stream
 * route.ts produces. Event names match route.ts's `send(event, data)`
 * calls exactly — keep the two in sync if either changes.
 */

export interface ChatStreamEvents {
  intent: { intent: string; complexity: 'LOW' | 'MEDIUM' | 'HIGH' };
  category: { category: 'INFORMATIONAL' | 'DECISION_SUPPORT' | 'CLINICAL_DECISION' };
  severity: { severity: 'NORMAL' | 'MONITOR' | 'WARNING' | 'URGENT' | 'CRITICAL' | 'EMERGENCY' };
  sources: { count: number; domains: string[] };
  sentence: { text: string; citedClaimIds: string[] };
  notice: { message: string };
  error: { message: string };
  done: { auditId: string };
}

export type ChatStreamHandlers = {
  [K in keyof ChatStreamEvents]?: (data: ChatStreamEvents[K]) => void;
};

export interface SendChatMessageOptions {
  sessionId: string;
  message: string;
  authToken: string; // Bearer JWT, HP-SEC-001
  apiBaseUrl?: string; // defaults to same-origin '/api/chat'
  signal?: AbortSignal; // wire to an AbortController for a "stop generating" button
}

/**
 * Opens the stream and dispatches each SSE frame to the matching handler in
 * `handlers`. Resolves once the stream closes (after `done` fires or on a
 * network-level end); does not throw on a mid-stream `error` event — that's
 * delivered to `handlers.error` like any other event, since a pipeline
 * error after partial output is a normal, handleable case here, not an
 * exceptional one.
 */
export async function sendChatMessage(opts: SendChatMessageOptions, handlers: ChatStreamHandlers): Promise<void> {
  const url = `${opts.apiBaseUrl ?? ''}/api/chat`;
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${opts.authToken}`,
    },
    body: JSON.stringify({ sessionId: opts.sessionId, message: opts.message }),
    signal: opts.signal,
  });

  if (!res.ok || !res.body) {
    const body = await res.text().catch(() => '');
    throw new Error(`chat request failed: ${res.status} ${body}`);
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    // SSE frames are separated by a blank line.
    let frameEnd: number;
    while ((frameEnd = buffer.indexOf('\n\n')) !== -1) {
      const frame = buffer.slice(0, frameEnd);
      buffer = buffer.slice(frameEnd + 2);
      dispatchFrame(frame, handlers);
    }
  }
  // Flush any trailing frame that arrived without a final blank line.
  if (buffer.trim()) dispatchFrame(buffer, handlers);
}

function dispatchFrame(frame: string, handlers: ChatStreamHandlers) {
  let event: string | null = null;
  let dataLines: string[] = [];
  for (const line of frame.split('\n')) {
    if (line.startsWith('event: ')) event = line.slice('event: '.length).trim();
    else if (line.startsWith('data: ')) dataLines.push(line.slice('data: '.length));
  }
  if (!event || dataLines.length === 0) return;

  let parsed: unknown;
  try {
    parsed = JSON.parse(dataLines.join('\n'));
  } catch {
    return; // malformed frame — drop rather than crash the whole stream
  }

  const handler = (handlers as Record<string, (data: unknown) => void>)[event];
  handler?.(parsed);
}
