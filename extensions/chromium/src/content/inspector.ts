/**
 * Inspect Mode overlay content script.
 *
 * Lifecycle (docs/IPC_PROTOCOL.md "Content-script lifecycle", spec digest
 * §5.3): injected only while inspecting, torn down completely — every
 * listener and observer removed via an explicit `teardown()` — on
 * `inspect.deactivate` or navigation. There is no persistently-injected
 * inspection layer.
 *
 * All overlay DOM lives inside a single closed-mode shadow root so the
 * host page's CSS can never leak in or clobber the overlay's own styles
 * (and, symmetrically, the overlay's styles never leak into the page).
 */

import { generateUuid } from "../shared/ipc";
import type {
  Accessibility,
  Appearance,
  AuthoredSource,
  BoxModel,
  ElementEvidence,
  Layout,
  Locator,
  PageState,
  Typography
} from "../shared/elementEvidence";
import { buildAncestryChain, generateLocatorCandidates, getAccessibleName, getRole, resolveLocator } from "../shared/locator";
import { contrastRatioFromStrings, formatContrastRatio } from "../shared/contrast";

const HOST_ID = "capture-inspector-root";
const HOVER_THROTTLE_MS = 40;

// ---------------------------------------------------------------------------
// Module state — all reset to these values by teardown().
// ---------------------------------------------------------------------------
let active = false;
let shadowHost: HTMLDivElement | null = null;
let shadowRoot: ShadowRoot | null = null;
let highlightEl: HTMLDivElement | null = null;
let hoverCardEl: HTMLDivElement | null = null;
let hoveredElement: Element | null = null;
let pinnedElement: Element | null = null;
const selectedElements = new Set<Element>();

let rafPending = false;
let lastMouseX = 0;
let lastMouseY = 0;
let lastMoveTimestamp = 0;

// Bound listener references so removeEventListener actually matches.
const onMouseMove = (event: MouseEvent) => scheduleHoverUpdate(event.clientX, event.clientY);
const onClick = (event: MouseEvent) => handleClick(event);
const onKeyDown = (event: KeyboardEvent) => handleKeyDown(event);
const onScrollOrResize = () => {
  if (pinnedElement) positionOverlayFor(pinnedElement);
  else if (hoveredElement) positionOverlayFor(hoveredElement);
};

// ---------------------------------------------------------------------------
// Activation / teardown
// ---------------------------------------------------------------------------

export function activate(): void {
  if (active) return;
  active = true;
  buildOverlayHost();
  document.addEventListener("mousemove", onMouseMove, true);
  document.addEventListener("click", onClick, true);
  document.addEventListener("keydown", onKeyDown, true);
  window.addEventListener("scroll", onScrollOrResize, true);
  window.addEventListener("resize", onScrollOrResize, true);
}

/** Fully removes every listener and DOM node this script added. Explicit,
 * not left to garbage collection, per the content-script lifecycle rule. */
export function teardown(): void {
  document.removeEventListener("mousemove", onMouseMove, true);
  document.removeEventListener("click", onClick, true);
  document.removeEventListener("keydown", onKeyDown, true);
  window.removeEventListener("scroll", onScrollOrResize, true);
  window.removeEventListener("resize", onScrollOrResize, true);

  shadowHost?.remove();
  shadowHost = null;
  shadowRoot = null;
  highlightEl = null;
  hoverCardEl = null;
  hoveredElement = null;
  pinnedElement = null;
  selectedElements.clear();
  rafPending = false;
  active = false;
}

export function isActive(): boolean {
  return active;
}

function buildOverlayHost(): void {
  const host = document.createElement("div");
  host.id = HOST_ID;
  host.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647;";
  const root = host.attachShadow({ mode: "closed" });

  const style = document.createElement("style");
  style.textContent = `
    .highlight {
      position: fixed;
      pointer-events: none;
      outline: 2px solid #2f6fed;
      outline-offset: -1px;
      background: rgba(47, 111, 237, 0.12);
      box-sizing: border-box;
      transition: none;
      display: none;
    }
    .highlight.pinned { outline-color: #ed6f2f; background: rgba(237, 111, 47, 0.12); }
    .card {
      position: fixed;
      pointer-events: none;
      max-width: 260px;
      background: #111318;
      color: #f2f4f8;
      font: 12px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      border-radius: 8px;
      padding: 10px 12px;
      box-shadow: 0 8px 24px rgba(0,0,0,0.35);
      white-space: pre-wrap;
      display: none;
    }
    .card .title { font-weight: 600; color: #ffffff; }
    .card .sep { opacity: 0.35; margin: 4px 0; }
  `;
  root.appendChild(style);

  highlightEl = document.createElement("div");
  highlightEl.className = "highlight";
  root.appendChild(highlightEl);

  hoverCardEl = document.createElement("div");
  hoverCardEl.className = "card";
  root.appendChild(hoverCardEl);

  document.documentElement.appendChild(host);
  shadowHost = host;
  shadowRoot = root;
}

// ---------------------------------------------------------------------------
// Hover handling
// ---------------------------------------------------------------------------

function scheduleHoverUpdate(x: number, y: number): void {
  lastMouseX = x;
  lastMouseY = y;
  const now = performance.now();
  if (rafPending) return;
  if (now - lastMoveTimestamp < HOVER_THROTTLE_MS) return;
  rafPending = true;
  requestAnimationFrame(() => {
    rafPending = false;
    lastMoveTimestamp = performance.now();
    updateHoverAt(lastMouseX, lastMouseY);
  });
}

function updateHoverAt(x: number, y: number): void {
  if (pinnedElement) return; // pinned inspection takes over navigation
  const stack = document.elementsFromPoint(x, y);
  const candidate = stack.find((el) => el !== shadowHost && !shadowHost?.contains(el));
  if (!candidate || candidate === hoveredElement) return;
  hoveredElement = candidate;
  positionOverlayFor(candidate);
  renderHoverCard(candidate);
}

function positionOverlayFor(element: Element): void {
  if (!highlightEl) return;
  const rect = element.getBoundingClientRect();
  highlightEl.style.display = "block";
  highlightEl.style.left = `${rect.left}px`;
  highlightEl.style.top = `${rect.top}px`;
  highlightEl.style.width = `${rect.width}px`;
  highlightEl.style.height = `${rect.height}px`;
  highlightEl.classList.toggle("pinned", element === pinnedElement);

  if (hoverCardEl) {
    hoverCardEl.style.display = "block";
    const cardTop = rect.bottom + 8;
    const fitsBelow = cardTop + 160 < window.innerHeight;
    hoverCardEl.style.top = fitsBelow ? `${cardTop}px` : `${Math.max(8, rect.top - 168)}px`;
    hoverCardEl.style.left = `${Math.min(Math.max(8, rect.left), window.innerWidth - 268)}px`;
  }
}

/** Builds the compact hover-card text matching the spec's example format:
 * tag+classes / dimensions / font family / size-weight+line-height /
 * text+background colour+contrast / padding/radius/display/gap. */
function buildHoverCardText(element: Element): string {
  const computed = window.getComputedStyle(element);
  const rect = element.getBoundingClientRect();
  const tagLine = element.tagName.toLowerCase() + classSuffix(element);
  const dims = `${Math.round(rect.width)} × ${Math.round(rect.height)} px`;

  const fontFamily = firstFont(computed.fontFamily);
  const fontSize = Math.round(parseFloat(computed.fontSize) || 0);
  const fontWeight = computed.fontWeight;
  const lineHeight = describeLineHeight(computed.lineHeight);

  const textColor = computed.color;
  const backgroundColor = getEffectiveBackgroundColor(element);
  const ratio = contrastRatioFromStrings(textColor, backgroundColor);

  const padding = shorthandEdges(computed, "padding");
  const radius = computed.borderRadius;
  const display = computed.display;
  const gap = computed.gap && computed.gap !== "normal" ? computed.gap : null;

  const lines = [
    tagLine,
    dims,
    "",
    fontFamily,
    `${fontSize} px / ${fontWeight}`,
    `line-height ${lineHeight}`,
    "",
    `Text ${toHex(textColor) ?? textColor}`,
    `Background ${toHex(backgroundColor) ?? backgroundColor}`,
    ratio !== null ? `Contrast ${formatContrastRatio(ratio)}` : "Contrast unavailable",
    "",
    `Padding ${padding}`,
    `Radius ${radius}`,
    `Display ${display}`
  ];
  if (gap) lines.push(`Gap ${gap}`);
  return lines.join("\n");
}

function renderHoverCard(element: Element): void {
  if (!hoverCardEl) return;
  hoverCardEl.textContent = buildHoverCardText(element);
}

function classSuffix(element: Element): string {
  const classes = Array.from(element.classList).slice(0, 3);
  return classes.length ? `.${classes.join(".")}` : "";
}

function firstFont(fontFamily: string): string {
  return (fontFamily.split(",")[0] ?? "").trim().replace(/^["']|["']$/g, "");
}

function describeLineHeight(lineHeight: string): string {
  if (lineHeight === "normal") return "normal";
  const px = parseFloat(lineHeight);
  return Number.isFinite(px) ? `${Math.round(px)} px` : lineHeight;
}

function shorthandEdges(computed: CSSStyleDeclaration, prefix: "padding" | "margin" | "border"): string {
  const top = parseFloat(computed.getPropertyValue(`${prefix}-top`)) || 0;
  const right = parseFloat(computed.getPropertyValue(`${prefix}-right`)) || 0;
  const bottom = parseFloat(computed.getPropertyValue(`${prefix}-bottom`)) || 0;
  const left = parseFloat(computed.getPropertyValue(`${prefix}-left`)) || 0;
  if (top === bottom && left === right) {
    return top === left ? `${round(top)}px` : `${round(top)}px ${round(left)}px`;
  }
  return `${round(top)}px ${round(right)}px ${round(bottom)}px ${round(left)}px`;
}

function round(n: number): number {
  return Math.round(n * 10) / 10;
}

/** Walks up the ancestor chain to find the first non-transparent background,
 * since most elements have `background-color: transparent` and inherit
 * their visual background from an ancestor. Falls back to white (the
 * default page canvas) if nothing is found. */
function getEffectiveBackgroundColor(element: Element): string {
  let current: Element | null = element;
  while (current) {
    const bg = window.getComputedStyle(current).backgroundColor;
    if (bg && bg !== "transparent" && bg !== "rgba(0, 0, 0, 0)") return bg;
    current = current.parentElement;
  }
  return "rgb(255, 255, 255)";
}

function toHex(color: string): string | null {
  const match = color.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/);
  if (!match) return null;
  const [, r, g, b] = match;
  const hex = [r, g, b]
    .map((v) => Math.round(Number(v)).toString(16).padStart(2, "0"))
    .join("");
  return `#${hex.toUpperCase()}`;
}

// ---------------------------------------------------------------------------
// Pin / click
// ---------------------------------------------------------------------------

function handleClick(event: MouseEvent): void {
  if (!hoveredElement && !pinnedElement) return;
  event.preventDefault();
  event.stopPropagation();

  const target = hoveredElement ?? pinnedElement;
  if (!target) return;
  pinElement(target, event.shiftKey);
}

function pinElement(element: Element, additive: boolean): void {
  pinnedElement = element;
  if (additive) selectedElements.add(element);
  else {
    selectedElements.clear();
    selectedElements.add(element);
  }
  positionOverlayFor(element);
  renderHoverCard(element);

  const evidence = buildElementEvidence(element);
  void chrome.runtime
    .sendMessage({ type: "element.pin", payload: { evidence } })
    .catch(() => {
      // Background/native unreachable — the overlay still reflects the pin
      // locally; the user can retry once connectivity is restored.
    });
}

// ---------------------------------------------------------------------------
// Keyboard DOM navigation (arrow keys walk parent/sibling/child; Shift adds
// to a multi-select set rather than replacing the pin).
// ---------------------------------------------------------------------------

function handleKeyDown(event: KeyboardEvent): void {
  if (!pinnedElement) return;
  if (event.key === "Escape") {
    pinnedElement = null;
    selectedElements.clear();
    if (hoveredElement) {
      positionOverlayFor(hoveredElement);
      renderHoverCard(hoveredElement);
    } else if (highlightEl) {
      highlightEl.style.display = "none";
      if (hoverCardEl) hoverCardEl.style.display = "none";
    }
    return;
  }

  let next: Element | null = null;
  switch (event.key) {
    case "ArrowUp":
      next = pinnedElement.parentElement;
      break;
    case "ArrowDown":
      next = pinnedElement.firstElementChild;
      break;
    case "ArrowLeft":
      next = pinnedElement.previousElementSibling;
      break;
    case "ArrowRight":
      next = pinnedElement.nextElementSibling;
      break;
    default:
      return;
  }
  if (!next) return;
  event.preventDefault();
  pinElement(next, event.shiftKey);
}

// ---------------------------------------------------------------------------
// ElementEvidence construction
// ---------------------------------------------------------------------------

const IMPORTANT_PROPERTIES = ["color", "background-color", "font-size", "font-family", "padding", "border-radius", "box-shadow", "display", "gap"] as const;

function buildElementEvidence(element: Element): ElementEvidence {
  const computed = window.getComputedStyle(element);
  const rect = element.getBoundingClientRect();

  return {
    id: generateUuid(),
    capturedAt: new Date().toISOString(),
    url: location.href,
    title: document.title,
    viewport: {
      width: window.innerWidth,
      height: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio,
      scrollX: window.scrollX,
      scrollY: window.scrollY
    },
    locator: buildLocator(element),
    rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
    boxModel: buildBoxModel(computed, element),
    typography: buildTypography(computed),
    appearance: buildAppearance(computed),
    layout: buildLayout(computed),
    accessibility: buildAccessibility(element, computed),
    cssVariables: extractCssVariables(element, computed),
    authoredSources: buildAuthoredSources(element, computed),
    pageState: buildPageState()
  };
}

function buildLocator(element: Element): Locator {
  const candidates = generateLocatorCandidates(element);
  return {
    primary: candidates[0]?.value ?? "",
    candidates,
    role: getRole(element),
    accessibleName: getAccessibleName(element),
    textFingerprint: (element.textContent ?? "").trim().replace(/\s+/g, " ").slice(0, 120) || null,
    ancestryFingerprint: buildAncestryChain(element)
  };
}

function buildBoxModel(computed: CSSStyleDeclaration, element: Element): BoxModel {
  return {
    padding: edgesFor(computed, "padding"),
    border: edgesFor(computed, "border", "-width"),
    margin: edgesFor(computed, "margin"),
    contentBox: {
      width: element.clientWidth - (parseFloat(computed.paddingLeft) || 0) - (parseFloat(computed.paddingRight) || 0),
      height: element.clientHeight - (parseFloat(computed.paddingTop) || 0) - (parseFloat(computed.paddingBottom) || 0)
    },
    gap: computed.gap && computed.gap !== "normal" ? computed.gap : null,
    display: computed.display || null,
    position: computed.position || null
  };
}

function edgesFor(computed: CSSStyleDeclaration, prefix: string, suffix = "") {
  return {
    top: parseFloat(computed.getPropertyValue(`${prefix}-top${suffix}`)) || 0,
    right: parseFloat(computed.getPropertyValue(`${prefix}-right${suffix}`)) || 0,
    bottom: parseFloat(computed.getPropertyValue(`${prefix}-bottom${suffix}`)) || 0,
    left: parseFloat(computed.getPropertyValue(`${prefix}-left${suffix}`)) || 0
  };
}

function buildTypography(computed: CSSStyleDeclaration): Typography {
  const lineHeight = parseFloat(computed.lineHeight);
  return {
    fontFamilyAuthored: computed.fontFamily || null,
    fontFamilyRendered: firstFont(computed.fontFamily) || null,
    fontSizePx: parseFloat(computed.fontSize) || null,
    fontWeight: computed.fontWeight || null,
    fontStyle: computed.fontStyle || null,
    lineHeightPx: Number.isFinite(lineHeight) ? lineHeight : null,
    letterSpacing: computed.letterSpacing || null,
    textAlign: computed.textAlign || null,
    textColor: computed.color || null,
    // Actual rendered-face and @font-face source URL mapping is deferred —
    // see the "deferred" note in the final report. Never fabricate.
    sourceURL: null,
    sourceFormat: null
  };
}

function buildAppearance(computed: CSSStyleDeclaration): Appearance {
  return {
    backgroundColor: computed.backgroundColor || null,
    backgroundImage: computed.backgroundImage && computed.backgroundImage !== "none" ? computed.backgroundImage : null,
    borderRadius: computed.borderRadius || null,
    boxShadow: computed.boxShadow && computed.boxShadow !== "none" ? computed.boxShadow : null,
    opacity: Number.isFinite(parseFloat(computed.opacity)) ? parseFloat(computed.opacity) : null
  };
}

function buildLayout(computed: CSSStyleDeclaration): Layout {
  return {
    display: computed.display || null,
    flexDirection: computed.display.includes("flex") ? computed.flexDirection || null : null,
    zIndex: computed.zIndex && computed.zIndex !== "auto" ? computed.zIndex : null,
    overflow: computed.overflow || null
  };
}

function buildAccessibility(element: Element, computed: CSSStyleDeclaration): Accessibility {
  const ariaAttributes: Record<string, string> = {};
  for (const attr of Array.from(element.attributes)) {
    if (attr.name.startsWith("aria-")) ariaAttributes[attr.name] = attr.value;
  }
  const tabIndexAttr = element.getAttribute("tabindex");
  const tabIndex = tabIndexAttr !== null ? Number(tabIndexAttr) : (element as HTMLElement).tabIndex ?? null;
  const focusable = tabIndex !== null && tabIndex >= 0;
  const backgroundColor = getEffectiveBackgroundColor(element);
  const ratio = contrastRatioFromStrings(computed.color, backgroundColor);

  return {
    role: getRole(element),
    accessibleName: getAccessibleName(element),
    focusable,
    tabIndex,
    ariaAttributes,
    contrastRatio: ratio
  };
}

/** Extracts only the CSS custom properties this element's authored rules
 * actually reference via var(--x) — not every custom property defined
 * anywhere on the page. */
function extractCssVariables(element: Element, computed: CSSStyleDeclaration): Record<string, string> {
  const referenced = new Set<string>();
  const varPattern = /var\(\s*(--[a-zA-Z0-9-_]+)/g;

  const scanText = (text: string | null) => {
    if (!text) return;
    for (const match of text.matchAll(varPattern)) {
      const name = match[1];
      if (name) referenced.add(name);
    }
  };

  scanText(element.getAttribute("style"));
  forEachMatchingRule(element, (rule) => scanText(rule.style.cssText));

  const result: Record<string, string> = {};
  for (const name of referenced) {
    const value = computed.getPropertyValue(name).trim();
    if (value) result[name] = value;
  }
  return result;
}

/** Best-effort CSS provenance for a fixed set of "important" properties
 * (spec digest §17). Iterates document.styleSheets; a cross-origin sheet
 * throws a SecurityError on `.cssRules` access, which is caught per-sheet
 * and reported as `sourceUnavailable: true` rather than fabricated. */
function buildAuthoredSources(element: Element, computed: CSSStyleDeclaration): AuthoredSource[] {
  const sources: AuthoredSource[] = [];
  let anySheetUnavailable = false;

  for (const property of IMPORTANT_PROPERTIES) {
    const computedValue = computed.getPropertyValue(property);
    const inline = (element as HTMLElement).style?.getPropertyValue(property);
    if (inline) {
      sources.push({
        property,
        computedValue,
        authoredDeclaration: `${property}: ${inline}`,
        selector: "(inline style)",
        stylesheetURL: null,
        sourceUnavailable: false
      });
      continue;
    }

    let found: AuthoredSource | null = null;
    let hadInaccessibleSheet = false;
    for (const sheet of Array.from(document.styleSheets)) {
      let rules: CSSRuleList;
      try {
        rules = sheet.cssRules;
      } catch {
        hadInaccessibleSheet = true;
        continue;
      }
      for (const rule of Array.from(rules)) {
        if (!(rule instanceof CSSStyleRule)) continue;
        let matches = false;
        try {
          matches = element.matches(rule.selectorText);
        } catch {
          continue;
        }
        if (!matches) continue;
        const value = rule.style.getPropertyValue(property);
        if (!value) continue;
        found = {
          property,
          computedValue,
          authoredDeclaration: `${property}: ${value}`,
          selector: rule.selectorText,
          stylesheetURL: sheet.href ?? null,
          sourceUnavailable: false
        };
      }
    }

    if (found) {
      sources.push(found);
    } else if (hadInaccessibleSheet) {
      anySheetUnavailable = true;
      sources.push({
        property,
        computedValue,
        authoredDeclaration: null,
        selector: null,
        stylesheetURL: null,
        sourceUnavailable: true
      });
    }
  }

  if (anySheetUnavailable) {
    // Already reflected per-property above; nothing further to do — this
    // branch exists so the intent (never silently drop the signal) is
    // visible at a glance when reading the function.
  }
  return sources;
}

function forEachMatchingRule(element: Element, callback: (rule: CSSStyleRule) => void): void {
  for (const sheet of Array.from(document.styleSheets)) {
    let rules: CSSRuleList;
    try {
      rules = sheet.cssRules;
    } catch {
      continue;
    }
    for (const rule of Array.from(rules)) {
      if (!(rule instanceof CSSStyleRule)) continue;
      try {
        if (element.matches(rule.selectorText)) callback(rule);
      } catch {
        continue;
      }
    }
  }
}

function buildPageState(): PageState {
  const nav = navigator as Navigator & { userAgentData?: { platform?: string } };
  return {
    colourScheme: window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light",
    locale: document.documentElement.lang || navigator.language || null,
    browser: detectBrowserFamilyForPageState(),
    os: nav.userAgentData?.platform ?? navigator.platform ?? null
  };
}

function detectBrowserFamilyForPageState(): string {
  const nav = navigator as Navigator & { brave?: unknown };
  if (nav.brave) return "brave";
  if (/Edg\//.test(navigator.userAgent)) return "edge";
  if (/Chrome\//.test(navigator.userAgent)) return navigator.vendor === "Google Inc." ? "chrome" : "chromium";
  return "unknown";
}

// ---------------------------------------------------------------------------
// element.captureRequest / element.resolveAnchor handling (app-initiated)
// ---------------------------------------------------------------------------

interface InboundEnvelope {
  version: 1;
  id: string;
  type: string;
  payload: Record<string, unknown>;
}

function handleRuntimeMessage(
  message: InboundEnvelope,
  _sender: chrome.runtime.MessageSender,
  sendResponse: (response: unknown) => void
): boolean | undefined {
  if (!message || typeof message !== "object") return undefined;

  switch (message.type) {
    case "inspect.activate":
      activate();
      sendResponse({ version: 1, id: message.id, ok: true, payload: {} });
      return undefined;

    case "inspect.deactivate":
      teardown();
      sendResponse({ version: 1, id: message.id, ok: true, payload: {} });
      return undefined;

    case "element.captureRequest": {
      const locator = message.payload?.locator as string | undefined;
      if (!locator) {
        sendResponse({ version: 1, id: message.id, ok: false, error: { code: "INVALID_MESSAGE", message: "Missing locator" } });
        return undefined;
      }
      const result = resolveLocator([{ strategy: "absolute-path", value: locator, confidence: 0.5 }], document);
      if (!result.element) {
        sendResponse({ version: 1, id: message.id, ok: false, error: { code: "ELEMENT_NOT_FOUND", message: "Anchor not found" } });
        return undefined;
      }
      sendResponse({ version: 1, id: message.id, ok: true, payload: { evidence: buildElementEvidence(result.element) } });
      return undefined;
    }

    case "element.resolveAnchor": {
      const locator = message.payload?.locator as Locator | undefined;
      if (!locator) {
        sendResponse({ version: 1, id: message.id, ok: false, error: { code: "INVALID_MESSAGE", message: "Missing locator" } });
        return undefined;
      }
      const result = resolveLocator(locator.candidates ?? [], document);
      const rect = result.element ? result.element.getBoundingClientRect() : null;
      sendResponse({
        version: 1,
        id: message.id,
        ok: true,
        payload: {
          resolved: Boolean(result.element),
          confidence: result.confidence,
          rect: rect ? { x: rect.x, y: rect.y, width: rect.width, height: rect.height } : undefined
        }
      });
      return undefined;
    }

    default:
      return undefined;
  }
}

if (typeof chrome !== "undefined" && chrome.runtime) {
  chrome.runtime.onMessage.addListener(handleRuntimeMessage);
}
