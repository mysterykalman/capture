/**
 * Options page: link to chrome://extensions/shortcuts (extensions cannot
 * rebind their own commands programmatically — Chrome owns that surface)
 * and a bookmarks-bar-privacy on/off toggle persisted via chrome.storage.local.
 */

const STORAGE_KEY = "bookmarksBarPrivacyEnabled";
const DEFAULT_ENABLED = true; // matches the spec's default: "Always hide browser bookmarks bar: ON"

function wireShortcutsLink(): void {
  const button = document.getElementById("shortcuts-link");
  button?.addEventListener("click", () => {
    chrome.tabs.create({ url: "chrome://extensions/shortcuts" });
  });
}

async function loadToggleState(): Promise<void> {
  const checkbox = document.getElementById("bookmarks-bar-toggle") as HTMLInputElement | null;
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

function describeState(enabled: boolean): string {
  return enabled
    ? "On — the bookmarks bar will be automatically obscured in captures."
    : "Off — captures will show the bookmarks bar as-is for this device.";
}

wireShortcutsLink();
void loadToggleState();
