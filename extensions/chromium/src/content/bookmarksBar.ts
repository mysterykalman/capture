/**
 * Tier-2 bookmarks-bar-privacy geometry reporter (spec digest "Browser
 * Bookmarks Bar Privacy Rule", detection tier 2; docs/IPC_PROTOCOL.md
 * `bookmarksBar.geometry`).
 *
 * HARD REQUIREMENT: the bookmarks bar is browser chrome, not page content.
 * This file does NOT search the page DOM for it — it reports only the
 * directly-available `window.*` geometry properties the native app needs
 * to reason about where the browser chrome sits relative to the page
 * content, combined natively with the OS-level window frame.
 *
 * Injected on demand (via chrome.scripting.executeScript, same as the
 * inspector) when the background worker needs a fresh reading for an
 * upcoming capture — not a persistent, continuously-polling script. It
 * reports once and has nothing left to tear down.
 */

import type { BookmarksBarGeometryRequestPayload, BrowserFamily } from "../shared/ipc";

function detectBrowserFamily(): BrowserFamily {
  const ua = navigator.userAgent;
  const nav = navigator as Navigator & { brave?: unknown };

  if (nav.brave) return "brave";
  if (/Edg\//.test(ua)) return "edge";
  if (/Arc\//.test(ua)) return "arc";
  if (/Chrome\//.test(ua)) {
    return navigator.vendor === "Google Inc." ? "chrome" : "chromium";
  }
  return "unknown";
}

export function collectBookmarksBarGeometry(): BookmarksBarGeometryRequestPayload {
  return {
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    outerWidth: window.outerWidth,
    outerHeight: window.outerHeight,
    screenX: window.screenX,
    screenY: window.screenY,
    devicePixelRatio: window.devicePixelRatio,
    browser: detectBrowserFamily()
  };
}

function report(): void {
  const payload = collectBookmarksBarGeometry();
  chrome.runtime.sendMessage({ type: "bookmarksBar.geometry", payload }).catch(() => {
    // Background worker may not be listening (e.g. extension reloading);
    // nothing to retry — the next capture will inject and ask again.
  });
}

// Guarded so this module can be imported under a plain DOM test environment
// (no chrome.* APIs) purely to unit-test collectBookmarksBarGeometry.
if (typeof chrome !== "undefined" && chrome.runtime) {
  report();
}
