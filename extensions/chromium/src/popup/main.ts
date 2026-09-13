/**
 * Popup UI: native-host connection status + an "Inspect this page" button.
 * Talks only to the background service worker (never directly to the
 * native host or to a content script) via chrome.runtime.sendMessage.
 */

interface StatusResponse {
  connectionState: "disconnected" | "connecting" | "connected";
  lastConnectionError: string | null;
  inspectingTabId: number | null;
}

const STATUS_LABEL: Record<StatusResponse["connectionState"], string> = {
  connected: "Connected to Capture",
  connecting: "Connecting to Capture…",
  disconnected: "Not connected to Capture"
};

async function refreshStatus(): Promise<void> {
  const dot = document.getElementById("status-dot");
  const text = document.getElementById("status-text");
  const detail = document.getElementById("status-detail");
  if (!dot || !text || !detail) return;

  try {
    const status = (await chrome.runtime.sendMessage({ type: "internal.getStatus" })) as StatusResponse;
    dot.className = `dot ${status.connectionState}`;
    text.textContent = STATUS_LABEL[status.connectionState];
    detail.textContent =
      status.connectionState === "disconnected" && status.lastConnectionError
        ? status.lastConnectionError
        : "";
  } catch {
    dot.className = "dot disconnected";
    text.textContent = "Extension background not reachable";
  }
}

function wireInspectButton(): void {
  const button = document.getElementById("inspect-btn") as HTMLButtonElement | null;
  if (!button) return;
  button.addEventListener("click", async () => {
    button.disabled = true;
    try {
      await chrome.runtime.sendMessage({ type: "internal.inspectActiveTab" });
      window.close();
    } catch {
      button.disabled = false;
    }
  });
}

void refreshStatus();
wireInspectButton();
