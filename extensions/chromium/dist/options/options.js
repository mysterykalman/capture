// src/options/main.ts
var STORAGE_KEY = "bookmarksBarPrivacyEnabled";
var DEFAULT_ENABLED = true;
function wireShortcutsLink() {
  const button = document.getElementById("shortcuts-link");
  button?.addEventListener("click", () => {
    chrome.tabs.create({ url: "chrome://extensions/shortcuts" });
  });
}
async function loadToggleState() {
  const checkbox = document.getElementById("bookmarks-bar-toggle");
  const status = document.getElementById("toggle-status");
  if (!checkbox) return;
  const stored = await chrome.storage.local.get(STORAGE_KEY);
  const enabled = typeof stored[STORAGE_KEY] === "boolean" ? stored[STORAGE_KEY] : DEFAULT_ENABLED;
  checkbox.checked = enabled;
  if (status) status.textContent = describeState(enabled);
  checkbox.addEventListener("change", async () => {
    await chrome.storage.local.set({ [STORAGE_KEY]: checkbox.checked });
    if (status) status.textContent = describeState(checkbox.checked);
  });
}
function describeState(enabled) {
  return enabled ? "On \u2014 the bookmarks bar will be automatically obscured in captures." : "Off \u2014 captures will show the bookmarks bar as-is for this device.";
}
wireShortcutsLink();
void loadToggleState();
//# sourceMappingURL=options.js.map
