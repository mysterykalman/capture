// src/shared/ipc.ts
function createRequest(type, payload, tabSessionId) {
  const request = {
    version: 1,
    id: generateUuid(),
    type,
    payload
  };
  if (tabSessionId) request.tabSessionId = tabSessionId;
  return request;
}
function createErrorResponse(id, code, message) {
  return { version: 1, id, ok: false, error: { code, message: message.slice(0, 2e3) } };
}
function generateUuid() {
  const g = globalThis;
  if (g.crypto?.randomUUID) return g.crypto.randomUUID();
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === "x" ? r : r & 3 | 8;
    return v.toString(16);
  });
}

// src/background/index.ts
var NATIVE_HOST_ID = "com.capture.bridge";
var INSPECT_COMMAND = "inspect-page";
var MAX_RECONNECT_DELAY_MS = 3e4;
var nativePort = null;
var connectionState = "disconnected";
var lastConnectionError = null;
var reconnectAttempt = 0;
var reconnectTimer = null;
var pendingNativeRequests = /* @__PURE__ */ new Map();
var tabSessions = /* @__PURE__ */ new Map();
var sessionToTab = /* @__PURE__ */ new Map();
var inspectingTabs = /* @__PURE__ */ new Set();
function setConnectionState(state, error = null) {
  connectionState = state;
  lastConnectionError = error;
}
function connectNative() {
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
function handleNativeDisconnect() {
  const error = chrome.runtime.lastError?.message ?? "Native host disconnected";
  nativePort = null;
  setConnectionState("disconnected", error);
  for (const [id, pending] of pendingNativeRequests) {
    pending.resolve(createErrorResponse(id, "INTERNAL_ERROR", `Native host disconnected: ${error}`));
  }
  pendingNativeRequests.clear();
  scheduleReconnect();
}
function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = Math.min(1e3 * 2 ** reconnectAttempt, MAX_RECONNECT_DELAY_MS);
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
function ensureNativeConnection() {
  if (nativePort) return nativePort;
  try {
    return connectNative();
  } catch (err) {
    setConnectionState("disconnected", err instanceof Error ? err.message : String(err));
    scheduleReconnect();
    return null;
  }
}
function sendToNative(type, payload, tabId) {
  const tabSessionId = tabId !== void 0 ? tabSessions.get(tabId) : void 0;
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
function handleNativeMessage(message) {
  if (!message || typeof message !== "object") return;
  const msg = message;
  if ("ok" in msg && typeof msg.id === "string") {
    const pending = pendingNativeRequests.get(msg.id);
    if (pending) {
      pendingNativeRequests.delete(msg.id);
      pending.resolve(msg);
    }
    return;
  }
  if (typeof msg.type === "string" && typeof msg.id === "string") {
    void relayNativeRequestToTab(msg);
  }
}
async function relayNativeRequestToTab(request) {
  const tabId = request.tabSessionId ? sessionToTab.get(request.tabSessionId) : void 0;
  const targetTabId = tabId ?? await getActiveTabId();
  if (targetTabId === void 0) return;
  try {
    if (request.type === "inspect.activate") {
      await activateInspectorOnTab(targetTabId, request.payload);
    } else if (request.type === "inspect.deactivate") {
      await deactivateInspectorOnTab(targetTabId);
    } else {
      const response = await chrome.tabs.sendMessage(targetTabId, request);
      if (response && nativePort) {
        try {
          nativePort.postMessage(response);
        } catch {
        }
      }
    }
  } catch {
  }
}
async function getActiveTabId() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}
async function ensureTabSession(tabId, tabUrl, tabTitle) {
  const existing = tabSessions.get(tabId);
  if (existing) return existing;
  const response = await sendToNative("session.start", { tabUrl, tabTitle }, tabId);
  if (response.ok) {
    const payload = response.payload;
    if (payload.tabSessionId) {
      tabSessions.set(tabId, payload.tabSessionId);
      sessionToTab.set(payload.tabSessionId, tabId);
      return payload.tabSessionId;
    }
  }
  return void 0;
}
function endTabSession(tabId) {
  const sessionId = tabSessions.get(tabId);
  if (!sessionId) return;
  void sendToNative("session.end", {}, tabId);
  tabSessions.delete(tabId);
  sessionToTab.delete(sessionId);
}
async function injectInspector(tabId) {
  await chrome.scripting.executeScript({
    target: { tabId },
    files: ["content/inspector.js"]
  });
}
async function activateInspectorOnTab(tabId, options) {
  const tab = await chrome.tabs.get(tabId).catch(() => void 0);
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
async function deactivateInspectorOnTab(tabId) {
  inspectingTabs.delete(tabId);
  try {
    await chrome.tabs.sendMessage(tabId, {
      version: 1,
      id: generateUuid(),
      type: "inspect.deactivate",
      payload: {}
    });
  } catch {
  }
}
chrome.commands.onCommand.addListener((command) => {
  if (command !== INSPECT_COMMAND) return;
  void (async () => {
    const tabId = await getActiveTabId();
    if (tabId === void 0) return;
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
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status !== "loading") return;
  if (inspectingTabs.has(tabId)) {
    inspectingTabs.delete(tabId);
  }
  endTabSession(tabId);
});
var RELAYED_TYPES = /* @__PURE__ */ new Set([
  "element.pin",
  "tab.info",
  "bookmarksBar.geometry",
  "element.evidence"
]);
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== "object" || !("type" in message)) return void 0;
  if (message.type === "internal.getStatus") {
    sendResponse({ connectionState, lastConnectionError, inspectingTabId: [...inspectingTabs][0] ?? null });
    return void 0;
  }
  if (message.type === "internal.inspectActiveTab") {
    void (async () => {
      const tabId = await getActiveTabId();
      if (tabId === void 0) {
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
    return true;
  }
  return void 0;
});
ensureNativeConnection();
//# sourceMappingURL=background.js.map
