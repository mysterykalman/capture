"use strict";
(() => {
  // src/content/scrollCapture.ts
  var active = false;
  async function runScrollCapture(stepOverlapPx = 0) {
    if (active) return;
    active = true;
    const originalX = window.scrollX;
    const originalY = window.scrollY;
    const viewportHeight = window.innerHeight;
    const viewportWidth = window.innerWidth;
    const stepSize = Math.max(1, viewportHeight - stepOverlapPx);
    try {
      window.scrollTo(0, 0);
      let stepIndex = 0;
      while (true) {
        const totalHeight = document.documentElement.scrollHeight;
        const isLast = window.scrollY + viewportHeight >= totalHeight;
        await sendStepReport({
          type: "scrollCapture.step",
          payload: {
            stepIndex,
            scrollX: window.scrollX,
            scrollY: window.scrollY,
            viewportWidth,
            viewportHeight,
            totalHeight,
            isLast
          }
        });
        if (isLast) break;
        window.scrollTo(0, window.scrollY + stepSize);
        stepIndex++;
        await waitForNextFrame();
      }
    } finally {
      window.scrollTo(originalX, originalY);
      active = false;
    }
  }
  function sendStepReport(message) {
    return chrome.runtime.sendMessage(message).catch(() => void 0);
  }
  function waitForNextFrame() {
    return new Promise((resolve) => requestAnimationFrame(() => resolve()));
  }
  function handleMessage(message) {
    if (message?.type === "scrollCapture.start") {
      void runScrollCapture(message.payload?.stepOverlapPx ?? 0);
    }
  }
  if (typeof chrome !== "undefined" && chrome.runtime) {
    chrome.runtime.onMessage.addListener(handleMessage);
  }
})();
//# sourceMappingURL=scroll-capture.js.map
