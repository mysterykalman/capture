// src/popup/main.ts
var STATUS_LABEL = {
  connected: "Connected to Capture",
  connecting: "Connecting to Capture\u2026",
  disconnected: "Not connected to Capture"
};
async function refreshStatus() {
  const dot = document.getElementById("status-dot");
  const text = document.getElementById("status-text");
  const detail = document.getElementById("status-detail");
  if (!dot || !text || !detail) return;
  try {
    const status = await chrome.runtime.sendMessage({ type: "internal.getStatus" });
    dot.className = `dot ${status.connectionState}`;
    text.textContent = STATUS_LABEL[status.connectionState];
    detail.textContent = status.connectionState === "disconnected" && status.lastConnectionError ? status.lastConnectionError : "";
  } catch {
    dot.className = "dot disconnected";
    text.textContent = "Extension background not reachable";
  }
}
function wireInspectButton() {
  const button = document.getElementById("inspect-btn");
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
//# sourceMappingURL=popup.js.map
