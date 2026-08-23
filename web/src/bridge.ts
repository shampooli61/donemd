// Bridge client. Mirrors the Swift WebViewBridge envelope shape:
//   { version: 1, type: string, payload: any }

export interface BridgeEnvelope {
  version: number;
  type: string;
  payload: unknown;
}

const ENVELOPE_VERSION = 1;
const handlers: Record<string, (payload: unknown) => void> = {};

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        donemd?: { postMessage: (msg: string) => void };
      };
    };
    donemdBridge: {
      receive: (envelope: BridgeEnvelope) => void;
    };
  }
}

/** Register a handler for inbound (Swift → JS) messages of the given type. */
export function on(type: string, handler: (payload: unknown) => void): void {
  handlers[type] = handler;
}

/** Send a message from JS to Swift. No-op (with a warning) when running in a
 *  plain browser (e.g. `npm run dev`) — useful for previewing the editor. */
export function send(type: string, payload: unknown = null): void {
  const envelope: BridgeEnvelope = { version: ENVELOPE_VERSION, type, payload };
  const handler = window.webkit?.messageHandlers?.donemd;
  if (handler) {
    handler.postMessage(JSON.stringify(envelope));
  } else {
    console.info('[bridge] not in WKWebView; dropped:', envelope);
  }
}

// Expose the inbound receive() function on `window` so Swift can call it via
// evaluateJavaScript("window.donemdBridge.receive({...})").
// Request/response support for messages where JS needs to wait for Swift's
// answer (e.g. "import these image bytes and tell me the asset URL").
type Pending = (payload: unknown) => void;
const pending = new Map<string, Pending>();
let nextRequestId = 1;

/** Send `type` with `payload` and resolve when Swift sends a reply of
 *  `replyType` carrying the same `requestId`. */
export function request(
  type: string,
  payload: Record<string, unknown>,
  replyType: string,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const requestId = `req-${nextRequestId++}`;
    pending.set(requestId, (p) => resolve(p as Record<string, unknown>));
    // Make sure the reply handler is wired exactly once.
    if (!handlers[replyType]) {
      on(replyType, (replyPayload) => {
        const obj = replyPayload as Record<string, unknown>;
        const id = obj?.requestId as string | undefined;
        if (id && pending.has(id)) {
          const resolver = pending.get(id)!;
          pending.delete(id);
          resolver(obj);
        }
      });
    }
    try {
      send(type, { ...payload, requestId });
    } catch (e) {
      pending.delete(requestId);
      reject(e);
    }
  });
}

window.donemdBridge = {
  receive(envelope: BridgeEnvelope): void {
    if (envelope.version !== ENVELOPE_VERSION) {
      console.warn('[bridge] unsupported envelope version:', envelope.version);
      return;
    }
    const handler = handlers[envelope.type];
    if (handler) {
      handler(envelope.payload);
    } else {
      console.warn('[bridge] no handler for type:', envelope.type);
    }
  },
};
