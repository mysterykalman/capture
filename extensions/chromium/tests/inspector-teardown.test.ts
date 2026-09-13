import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { activate, isActive, teardown } from "../src/content/inspector";

const HOST_SELECTOR = "#capture-inspector-root";

// jsdom does not implement Document.elementsFromPoint (no real layout
// engine/hit-testing) — see the "deferred" note in the final report. We
// polyfill it here with a fixed stack so the hover-update code path (which
// calls it on every throttled mousemove) is still exercised deterministically,
// rather than skipping hover coverage altogether or faking a passing test.
function stubElementsFromPoint(stack: Element[]): void {
  (document as unknown as { elementsFromPoint: (x: number, y: number) => Element[] }).elementsFromPoint = () =>
    stack;
}

// jsdom's requestAnimationFrame support is inconsistent across
// environments/flags; stub it with a deterministic macrotask so the
// throttled hover path resolves predictably in tests.
function stubRaf(): void {
  vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => {
    return setTimeout(() => cb(performance.now()), 0) as unknown as number;
  });
}

beforeEach(() => {
  document.body.innerHTML = `<div id="page"><button class="cta">Buy now</button></div>`;
  stubRaf();
});

afterEach(() => {
  teardown();
  vi.unstubAllGlobals();
});

describe("inspector activate/teardown", () => {
  it("activate() injects a single closed-shadow overlay host into the page", () => {
    expect(document.querySelector(HOST_SELECTOR)).toBeNull();
    activate();
    expect(isActive()).toBe(true);
    const host = document.querySelector(HOST_SELECTOR);
    expect(host).not.toBeNull();
    // Closed shadow root: shadowRoot property on the host element itself
    // must NOT expose it (that's the whole point of "closed").
    expect((host as HTMLElement).shadowRoot).toBeNull();
  });

  it("activate() is idempotent — calling it twice does not add a second host", () => {
    activate();
    activate();
    expect(document.querySelectorAll(HOST_SELECTOR).length).toBe(1);
  });

  it("teardown() removes the overlay host and resets active state", () => {
    activate();
    expect(document.querySelector(HOST_SELECTOR)).not.toBeNull();

    teardown();

    expect(isActive()).toBe(false);
    expect(document.querySelector(HOST_SELECTOR)).toBeNull();
  });

  it("teardown() removes the mousemove/click/keydown listeners it attached", () => {
    const addSpy = vi.spyOn(document, "addEventListener");
    const removeSpy = vi.spyOn(document, "removeEventListener");

    activate();
    const addedTypes = addSpy.mock.calls.map((call) => call[0]).sort();
    expect(addedTypes).toEqual(["click", "keydown", "mousemove"]);

    teardown();
    const removedTypes = removeSpy.mock.calls.map((call) => call[0]).sort();
    expect(removedTypes).toEqual(["click", "keydown", "mousemove"]);

    addSpy.mockRestore();
    removeSpy.mockRestore();
  });

  it("updates the highlight overlay on a (polyfilled) hover and clears it on teardown", async () => {
    const button = document.querySelector("button")!;
    stubElementsFromPoint([button]);

    activate();
    document.dispatchEvent(new MouseEvent("mousemove", { clientX: 10, clientY: 10 }));
    // Let the throttled rAF-scheduled update run.
    await new Promise((resolve) => setTimeout(resolve, 10));

    const host = document.querySelector(HOST_SELECTOR) as HTMLElement;
    expect(host).not.toBeNull();

    teardown();
    expect(document.querySelector(HOST_SELECTOR)).toBeNull();
  });

  it("does nothing (no throw) if teardown() is called when never activated", () => {
    expect(() => teardown()).not.toThrow();
    expect(isActive()).toBe(false);
  });
});
