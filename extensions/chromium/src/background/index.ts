/**
 * Background service worker — the ONLY holder of the Native Messaging port.
 * Content scripts never call chrome.runtime.connectNative themselves; they
 * message this worker via chrome.runtime.sendMessage, and this worker
 * relays to/from `com.capture.bridge` (docs/IPC_PROTOCOL.md, spec digest
 * §5.4-5.6). Every inbound content-script message is treated as untrusted
 * input: it is re-wrapped into a fresh, well-formed IPCRequest envelope
 * here rather than forwarded verbatim.
 */

import {
  createErrorResponse,
  createRequest,
  generateUuid,
  type IPCMessageType,
  type IPCRequest,
  type IPCResponse,
  type SessionStartResponsePayload
} from "../shared/ipc";

const NATIVE_HOST_ID = "com.capture.bridge";
const INSPECT_COMMAND = "inspect-page";
const MAX_RECONNECT_DELAY_MS = 30_000;

type ConnectionState = "disconnected" | "connecting" | "connected";

let nativePort: chrome.runtime.Port | null = null;
let connectionState: ConnectionState = "disconnected";
let lastConnectionError: string | null = null;
let reconnectAttempt = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

/** Requests currently awaiting a matching-id response from the native host. */
const pendingNativeRequests = new Map<
  string,
  { resolve: (response: IPCResponse) => void; tabId?: number }
>();

/** tabId -> tabSessionId, and the reverse, for routing app-initiated
 * messages (inspect.activate, element.captureRequest, ...) back to a tab. */
const tabSessions = new Map<number, string>();
const sessionToTab = new Map<string, number>();

/** Tabs the Inspect overlay is currently active in (toggle bookkeeping for
 * the keyboard command). */
const inspectingTabs = new Set<number>();

function setConnectionState(state: ConnectionState, error: string | null = null): void {
  connectionState = state;
  lastConnectionError = error;
}

function connectNative(): chrome.runtime.Port {
  if (nativePort) return nativePort;
  setConnectionState("connecting");
  const port = chrome.runtime.connectNative(NATIVE_HOST_ID);
  nativePort = port;
  port.onMessage.addListener(handleNativeMessage);
  port.onDisconnect.addListener(handleNativeDisconnect);
  setConnectionState("connected");
  reconnectAttempt = 0;
  return port;
}

function handleNativeDisconnect(): void {
  const error = chrome.runtime.lastError?.message ?? "Native host disconnected";
  nativePort = null;
  setConnectionState("disconnected", error);

  // Fail every in-flight request rather than leaving a content script
  // waiting forever.
  for (const [id, pending] of pendingNativeRequests) {
    pending.resolve(createErrorResponse(id, "INTERNAL_ERROR", `Native host disconnected: ${error}`));
  }
  pendingNativeRequests.clear();

  scheduleReconnect();
}

function scheduleReconnect(): void {
  if (reconnectTimer) return;
  const delay = Math.min(1000 * 2 ** reconnectAttempt, MAX_RECONNECT_DELAY_MS);
  reconnectAttempt++;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    try {
      connectNative();
    } catch (err) {
      setConnectionState("disconnected", err instanceof Error ? err.message : String(err));
      scheduleReconnect();
    }
  }, delay);
}

function ensureNativeConnection(): chrome.runtime.Port | null {
  if (nativePort) return nativePort;
  try {
    return connectNative();
  } catch (err) {
    setConnectionState("disconnected", err instanceof Error ? err.message : String(err));
    scheduleReconnect();
    return null;
  }
}

/** Sends a request to the native host and resolves when the matching-id
 * response arrives (or immediately with a synthetic error if there is no
 * connection). */
function sendToNative<T extends Record<string, unknown>>(
  type: IPCMessageType,
  payload: T,
  tabId?: number
): Promise<IPCResponse> {
  const tabSessionId = tabId !== undefined ? tabSessions.get(tabId) : undefined;
  const request = createRequest(type, payload, tabSessionId);

  const port = ensureNativeConnection();
  if (!port) {
    return Promise.resolve(
      createErrorResponse(request.id, "INTERNAL_ERROR", "Not connected to the Capture app")
    );
  }

  return new Promise((resolve) => {
    pendingNativeRequests.set(request.id, { resolve, tabId });
    try {
      port.postMessage(request);
    } catch (err) {
      pendingNativeRequests.delete(request.id);
      resolve(
        createErrorResponse(
          request.id,
          "INTERNAL_ERROR",
          `Failed to send to native host: ${err instanceof Error ? err.message : String(err)}`
        )
      );
    }
  });
}

/** Messages arriving from the native host are either responses to a
 * request we sent (matched by id, has `ok`) or app-initiated requests
 * (has `type`) that must be relayed down to the right tab's content
 * script. */
function handleNativeMessage(message: unknown): void {
  if (!message || typeof message !== "object") return;
  const msg = message as Record<string, unknown>;

  if ("ok" in msg && typeof msg.id === "string") {
    const pending = pendingNativeRequests.get(msg.id);
    if (pending) {
      pendingNativeRequests.delete(msg.id);
      pending.resolve(msg as unknown as IPCResponse);
    }
    return;
  }

  if (typeof msg.type === "string" && typeof msg.id === "string") {
    void relayNativeRequestToTab(msg as unknown as IPCRequest);
  }
}

async function relayNativeRequestToTab(request: IPCRequest): Promise<void> {
  const tabId = request.tabSessionId ? sessionToTab.get(request.tabSessionId) : undefined;
  const targetTabId = tabId ?? (await getActiveTabId());
  if (targetTabId === undefined) return;

  try {
    if (request.type === "inspect.activate") {
      await activateInspectorOnTab(targetTabId, request.payload as { mode?: "hover" | "pinned" });
    } else if (request.type === "inspect.deactivate") {
      await deactivateInspectorOnTab(targetTabId);
    } else {
      // element.captureRequest / element.resolveAnchor — forward as-is to
      // whatever listener the content script has registered, then relay
      // its reply back up to the native host with the same request id so
      // the app can match it.
      const response = (await chrome.tabs.sendMessage(targetTabId, request)) as IPCResponse | undefined;
      if (response && nativePort) {
        try {
          nativePort.postMessage(response);
        } catch {
          // Port died between the await and here — the reconnect loop
          // will pick it back up; this one reply is simply lost.
        }
      }
    }
  } catch {
    // Content script may not be injected (tab navigated, closed, etc). Best
    // effort only — the native host will simply not get a reply for this
    // one-way relay.
  }
}

async function getActiveTabId(): Promise<number | undefined> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}

async function ensureTabSession(tabId: number, tabUrl: string, tabTitle?: string): Promise<string | undefined> {
  const existing = tabSessions.get(tabId);
  if (existing) return existing;

  const response = await sendToNative("session.start", { tabUrl, tabTitle }, tabId);
  if (response.ok) {
    const payload = response.payload as SessionStartResponsePayload;
    if (payload.tabSessionId) {
      tabSessions.set(tabId, payload.tabSessionId);
      sessionToTab.set(payload.tabSessionId, tabId);
      return payload.tabSessionId;
    }
  }
  return undefined;
}

function endTabSession(tabId: number): void {
  const sessionId = tabSessions.get(tabId);
  if (!sessionId) return;
  void sendToNative("session.end", {}, tabId);
  tabSessions.delete(tabId);
  sessionToTab.delete(sessionId);
}

async function injectInspector(tabId: number): Promise<void> {
  await chrome.scripting.executeScript({
    target: { tabId },
    files: ["content/inspector.js"]
  });
}

async function activateInspectorOnTab(tabId: number, options?: { mode?: "hover" | "pinned" }): Promise<void> {
  const tab = await chrome.tabs.get(tabId).catch(() => undefined);
  if (tab?.url) {
    await ensureTabSession(tabId, tab.url, tab.title);
  }
  await injectInspector(tabId);
  inspectingTabs.add(tabId);
  await chrome.tabs.sendMessage(tabId, {
    version: 1,
    id: generateUuid(),
    type: "inspect.activate",
    payload: { mode: options?.mode ?? "hover" }
  });
}

async function deactivateInspectorOnTab(tabId: number): Promise<void> {
  inspectingTabs.delete(tabId);
  try {
    await chrome.tabs.sendMessage(tabId, {
      version: 1,
      id: generateUuid(),
      type: "inspect.deactivate",
      payload: {}
    });
  } catch {
    // Content script already gone (navigation) — nothing to tear down.
  }
}

chrome.commands.onCommand.addListener((command) => {
  if (command !== INSPECT_COMMAND) return;
  void (async () => {
    const tabId = await getActiveTabId();
    if (tabId === undefined) return;
    if (inspectingTabs.has(tabId)) {
      await deactivateInspectorOnTab(tabId);
    } else {
      await activateInspectorOnTab(tabId);
    }
  })();
});

chrome.tabs.onRemoved.addListener((tabId) => {
  inspectingTabs.delete(tabId);
  endTabSession(tabId);
});

// A full-page navigation invalidates the injected inspector per the
// content-script lifecycle rule (docs/IPC_PROTOCOL.md) — there is no
// persistently-injected inspection layer to keep in sync. Listening to
// chrome.tabs.onUpdated needs no extra permission beyond the manifest's
// baseline (no URL is read here, only tabId/status).
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status !== "loading") return;
  if (inspectingTabs.has(tabId)) {
    inspectingTabs.delete(tabId);
  }
  endTabSession(tabId);
});

interface InternalStatusRequest {
  type: "internal.getStatus";
}
interface InternalInspectRequest {
  type: "internal.inspectActiveTab";
}

type ContentToBackgroundMessage =
  | { type: "element.pin"; payload: Record<string, unknown> }
  | { type: "tab.info"; payload: Record<string, unknown> }
  | { type: "bookmarksBar.geometry"; payload: Record<string, unknown> }
  | { type: "element.evidence"; payload: Record<string, unknown> }
  | InternalStatusRequest
  | InternalInspectRequest;

const RELAYED_TYPES: ReadonlySet<string> = new Set([
  "element.pin",
  "tab.info",
  "bookmarksBar.geometry",
  "element.evidence"
]);

chrome.runtime.onMessage.addListener((message: ContentToBackgroundMessage, sender, sendResponse) => {
  if (!message || typeof message !== "object" || !("type" in message)) return undefined;

  if (message.type === "internal.getStatus") {
    sendResponse({ connectionState, lastConnectionError, inspectingTabId: [...inspectingTabs][0] ?? null });
    return undefined;
  }

  if (message.type === "internal.inspectActiveTab") {
    void (async () => {
      const tabId = await getActiveTabId();
      if (tabId === undefined) {
        sendResponse({ ok: false, error: "No active tab" });
        return;
      }
      if (inspectingTabs.has(tabId)) {
        await deactivateInspectorOnTab(tabId);
      } else {
        await activateInspectorOnTab(tabId);
      }
      sendResponse({ ok: true });
    })();
    return true;
  }

  if (RELAYED_TYPES.has(message.type)) {
    const tabId = sender.tab?.id;
    void sendToNative(message.type, message.payload, tabId).then(sendResponse);
    return true; // keep the message channel open for the async response
  }

  return undefined;
});

// Lazily connect on worker startup so status is meaningful as soon as the
// popup asks, without waiting for the first inspect action.
ensureNativeConnection();
