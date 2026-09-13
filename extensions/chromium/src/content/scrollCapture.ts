/**
 * Scroll-capture helper (lower priority per the task brief — the Inspect
 * overlay and bookmarks-bar reporter are the must-haves for the Phase 3
 * acceptance scenario). Injected on demand like the other content scripts;
 * walks the page in viewport-height steps so the native app can stitch a
 * full-page screenshot, then removes its own listener.
 *
 * This does not composite pixels itself — Capture.app captures each step
 * natively via ScreenCaptureKit (see docs/ARCHITECTURE.md's "Image
 * binaries never cross Native Messaging"); this script only reports the
 * scroll geometry for each step and waits for a signal before advancing so
 * the app has time to actually take the shot.
 */

interface ScrollStepMessage {
  type: "scrollCapture.start";
  payload?: { stepOverlapPx?: number };
}

interface ScrollStepReport {
  type: "scrollCapture.step";
  payload: {
    stepIndex: number;
    scrollX: number;
    scrollY: number;
    viewportWidth: number;
    viewportHeight: number;
    totalHeight: number;
    isLast: boolean;
  };
}

let active = false;

async function runScrollCapture(stepOverlapPx = 0): Promise<void> {
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
    // Re-read scrollHeight each step: dynamically-loaded content (infinite
    // scroll, lazy images) can change it as we go.
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

function sendStepReport(message: ScrollStepReport): Promise<unknown> {
  return chrome.runtime.sendMessage(message).catch(() => undefined);
}

function waitForNextFrame(): Promise<void> {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}

function handleMessage(message: ScrollStepMessage): void {
  if (message?.type === "scrollCapture.start") {
    void runScrollCapture(message.payload?.stepOverlapPx ?? 0);
  }
}

if (typeof chrome !== "undefined" && chrome.runtime) {
  chrome.runtime.onMessage.addListener(handleMessage);
}

export { runScrollCapture };
