"use strict";
(() => {
  // src/content/bookmarksBar.ts
  function detectBrowserFamily() {
    const ua = navigator.userAgent;
    const nav = navigator;
    if (nav.brave) return "brave";
    if (/Edg\//.test(ua)) return "edge";
    if (/Arc\//.test(ua)) return "arc";
    if (/Chrome\//.test(ua)) {
      return navigator.vendor === "Google Inc." ? "chrome" : "chromium";
    }
    return "unknown";
  }
  function collectBookmarksBarGeometry() {
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
  function report() {
    const payload = collectBookmarksBarGeometry();
    chrome.runtime.sendMessage({ type: "bookmarksBar.geometry", payload }).catch(() => {
    });
  }
  if (typeof chrome !== "undefined" && chrome.runtime) {
    report();
  }
})();
//# sourceMappingURL=bookmarks-bar.js.map
