"use strict";
(() => {
  // src/shared/ipc.ts
  function generateUuid() {
    const g = globalThis;
    if (g.crypto?.randomUUID) return g.crypto.randomUUID();
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === "x" ? r : r & 3 | 8;
      return v.toString(16);
    });
  }

  // src/shared/locator.ts
  var STRATEGY_PRIORITY = [
    "data-attribute",
    "stable-id",
    "role-accessible-name",
    "semantic-attribute",
    "class-structure",
    "text-fingerprint",
    "ancestry-fingerprint",
    "absolute-path"
  ];
  var BASE_CONFIDENCE = {
    "data-attribute": 0.97,
    "stable-id": 0.92,
    "role-accessible-name": 0.8,
    "semantic-attribute": 0.68,
    "class-structure": 0.52,
    "text-fingerprint": 0.4,
    "ancestry-fingerprint": 0.28,
    "absolute-path": 0.12
  };
  var PREFERRED_DATA_ATTRS = [
    "data-testid",
    "data-test-id",
    "data-test",
    "data-qa",
    "data-cy",
    "data-component",
    "data-component-id",
    "data-id"
  ];
  var LIKELY_GENERATED_ID = /^(?:[a-z]+-)?[0-9a-f]{6,}$|^:r[0-9a-z]+:$|^radix-|^:[0-9a-z]+:$|^\d+$/i;
  var IMPLICIT_ROLE_BY_TAG = {
    a: "link",
    button: "button",
    nav: "navigation",
    main: "main",
    header: "banner",
    footer: "contentinfo",
    ul: "list",
    ol: "list",
    li: "listitem",
    table: "table",
    img: "img",
    h1: "heading",
    h2: "heading",
    h3: "heading",
    h4: "heading",
    h5: "heading",
    h6: "heading",
    textarea: "textbox",
    select: "combobox",
    form: "form",
    section: "region",
    article: "article",
    dialog: "dialog",
    progress: "progressbar",
    output: "status"
  };
  var INPUT_TYPE_ROLE = {
    text: "textbox",
    email: "textbox",
    search: "searchbox",
    tel: "textbox",
    url: "textbox",
    number: "spinbutton",
    checkbox: "checkbox",
    radio: "radio",
    range: "slider",
    button: "button",
    submit: "button",
    reset: "button",
    image: "button"
  };
  function cssEscape(value) {
    const g = globalThis;
    if (g.CSS?.escape) return g.CSS.escape(value);
    return value.replace(/["\\]/g, "\\$&");
  }
  function safeQueryAll(root, selector) {
    try {
      return Array.from(root.querySelectorAll(selector));
    } catch {
      return [];
    }
  }
  function safeQueryOne(root, selector) {
    try {
      return root.querySelector(selector);
    } catch {
      return null;
    }
  }
  function getRole(element) {
    const explicit = element.getAttribute("role");
    if (explicit) return explicit.split(/\s+/)[0] ?? null;
    const tag = element.tagName.toLowerCase();
    if (tag === "a" && !element.hasAttribute("href")) return null;
    if (tag === "input") {
      const type = (element.getAttribute("type") || "text").toLowerCase();
      return INPUT_TYPE_ROLE[type] ?? "textbox";
    }
    return IMPLICIT_ROLE_BY_TAG[tag] ?? null;
  }
  function getAccessibleName(element) {
    const ariaLabel = element.getAttribute("aria-label");
    if (ariaLabel?.trim()) return ariaLabel.trim();
    const labelledBy = element.getAttribute("aria-labelledby");
    if (labelledBy) {
      const doc = element.ownerDocument;
      const text = labelledBy.split(/\s+/).map((id) => doc.getElementById(id)?.textContent?.trim() ?? "").filter(Boolean).join(" ");
      if (text) return text;
    }
    const tag = element.tagName.toLowerCase();
    if (tag === "input" || tag === "textarea" || tag === "select") {
      const id = element.getAttribute("id");
      if (id) {
        const label = safeQueryOne(element.ownerDocument, `label[for="${cssEscape(id)}"]`);
        if (label?.textContent?.trim()) return label.textContent.trim();
      }
      const closestLabel = element.closest("label");
      if (closestLabel?.textContent?.trim()) return closestLabel.textContent.trim();
      const placeholder = element.getAttribute("placeholder");
      if (placeholder?.trim()) return placeholder.trim();
    }
    if (tag === "img") {
      const alt = element.getAttribute("alt");
      if (alt?.trim()) return alt.trim();
    }
    const title = element.getAttribute("title");
    if (title?.trim()) return title.trim();
    const isNamedByContent = ["button", "a", "summary"].includes(tag) || /^h[1-6]$/.test(tag) || getRole(element) === "button";
    if (isNamedByContent) {
      const text = element.textContent?.trim().replace(/\s+/g, " ");
      if (text) return text.slice(0, 200);
    }
    return null;
  }
  function elementSignature(element, maxClasses = 2) {
    const tag = element.tagName.toLowerCase();
    const classes = Array.from(element.classList).slice(0, maxClasses);
    return classes.length ? `${tag}.${classes.map(cssEscape).join(".")}` : tag;
  }
  function nthOfTypeSelector(element) {
    const tag = element.tagName.toLowerCase();
    const parent = element.parentElement;
    if (!parent) return tag;
    const sameTagSiblings = Array.from(parent.children).filter(
      (child) => child.tagName === element.tagName
    );
    if (sameTagSiblings.length <= 1) return tag;
    const index = sameTagSiblings.indexOf(element) + 1;
    return `${tag}:nth-of-type(${index})`;
  }
  function nthChildSelector(element) {
    const parent = element.parentElement;
    if (!parent) return element.tagName.toLowerCase();
    const index = Array.from(parent.children).indexOf(element) + 1;
    return `${element.tagName.toLowerCase()}:nth-child(${index})`;
  }
  function buildAbsolutePath(element) {
    const parts = [];
    let current = element;
    while (current) {
      parts.unshift(nthChildSelector(current));
      current = current.parentElement;
    }
    return parts.join(" > ");
  }
  function buildAncestryChain(element, maxDepth = 6) {
    const chain = [];
    let current = element;
    while (current && chain.length < maxDepth) {
      chain.unshift(elementSignature(current));
      current = current.parentElement;
    }
    return chain;
  }
  function uniquenessPenalty(root, selector) {
    const matches = safeQueryAll(root, selector);
    if (matches.length === 1) return 1;
    if (matches.length === 0) return 0.5;
    return 0.6;
  }
  function generateLocatorCandidates(element) {
    const doc = element.ownerDocument;
    const candidates = [];
    const dataAttr = findDataAttribute(element);
    if (dataAttr) {
      const selector = `[${dataAttr.name}="${cssEscape(dataAttr.value)}"]`;
      candidates.push({
        strategy: "data-attribute",
        value: selector,
        confidence: BASE_CONFIDENCE["data-attribute"] * uniquenessPenalty(doc, selector)
      });
    }
    const id = element.getAttribute("id");
    if (id && !LIKELY_GENERATED_ID.test(id)) {
      const selector = `#${cssEscape(id)}`;
      candidates.push({
        strategy: "stable-id",
        value: selector,
        confidence: BASE_CONFIDENCE["stable-id"] * uniquenessPenalty(doc, selector)
      });
    }
    const role = getRole(element);
    const accessibleName = getAccessibleName(element);
    if (role && accessibleName) {
      const value = encodeRoleName(role, accessibleName);
      const matchCount = countRoleNameMatches(doc, role, accessibleName);
      candidates.push({
        strategy: "role-accessible-name",
        value,
        confidence: BASE_CONFIDENCE["role-accessible-name"] * (matchCount === 1 ? 1 : 0.6)
      });
    }
    const semanticSelector = buildSemanticSelector(element);
    if (semanticSelector) {
      candidates.push({
        strategy: "semantic-attribute",
        value: semanticSelector,
        confidence: BASE_CONFIDENCE["semantic-attribute"] * uniquenessPenalty(doc, semanticSelector)
      });
    }
    if (element.classList.length > 0) {
      const classes = Array.from(element.classList).slice(0, 3).map(cssEscape);
      const selector = `${element.tagName.toLowerCase()}.${classes.join(".")}:is(${nthOfTypeSelector(element)})`;
      const simpleSelector = `.${classes.join(".")}`;
      const chosen = safeQueryAll(doc, simpleSelector).length >= 1 ? simpleSelector : selector;
      candidates.push({
        strategy: "class-structure",
        value: chosen,
        confidence: BASE_CONFIDENCE["class-structure"] * uniquenessPenalty(doc, chosen)
      });
    }
    const text = normalizeText(element.textContent);
    if (text && text.length > 0 && text.length <= 120) {
      const value = encodeTextFingerprint(element.tagName.toLowerCase(), text);
      const matchCount = countTextFingerprintMatches(doc, element.tagName.toLowerCase(), text);
      candidates.push({
        strategy: "text-fingerprint",
        value,
        confidence: BASE_CONFIDENCE["text-fingerprint"] * (matchCount === 1 ? 1 : 0.5)
      });
    }
    const ancestryChain = buildAncestryChain(element);
    if (ancestryChain.length > 0) {
      const selector = ancestryChain.join(" > ");
      candidates.push({
        strategy: "ancestry-fingerprint",
        value: selector,
        confidence: BASE_CONFIDENCE["ancestry-fingerprint"] * uniquenessPenalty(doc, selector)
      });
    }
    candidates.push({
      strategy: "absolute-path",
      value: buildAbsolutePath(element),
      confidence: BASE_CONFIDENCE["absolute-path"]
    });
    candidates.sort((a, b) => b.confidence - a.confidence);
    return candidates;
  }
  function findDataAttribute(element) {
    for (const name of PREFERRED_DATA_ATTRS) {
      const value = element.getAttribute(name);
      if (value) return { name, value };
    }
    for (const attr of Array.from(element.attributes)) {
      if (attr.name.startsWith("data-") && attr.value) {
        return { name: attr.name, value: attr.value };
      }
    }
    return null;
  }
  function buildSemanticSelector(element) {
    const tag = element.tagName.toLowerCase();
    const parts = [tag];
    const name = element.getAttribute("name");
    const type = element.getAttribute("type");
    const ariaLabel = element.getAttribute("aria-label");
    const htmlFor = element.getAttribute("for");
    if (name) parts.push(`[name="${cssEscape(name)}"]`);
    if (type) parts.push(`[type="${cssEscape(type)}"]`);
    if (!name && ariaLabel) parts.push(`[aria-label="${cssEscape(ariaLabel)}"]`);
    if (htmlFor) parts.push(`[for="${cssEscape(htmlFor)}"]`);
    if (parts.length === 1) return null;
    return parts.join("");
  }
  function normalizeText(text) {
    return (text ?? "").trim().replace(/\s+/g, " ");
  }
  function encodeRoleName(role, name) {
    return `role:${role};name:${name}`;
  }
  function decodeRoleName(value) {
    const match = value.match(/^role:([^;]*);name:(.*)$/s);
    if (!match) return null;
    return { role: match[1] ?? "", name: match[2] ?? "" };
  }
  function encodeTextFingerprint(tag, text) {
    return `tag:${tag};text:${text}`;
  }
  function decodeTextFingerprint(value) {
    const match = value.match(/^tag:([^;]*);text:(.*)$/s);
    if (!match) return null;
    return { tag: match[1] ?? "", text: match[2] ?? "" };
  }
  function countRoleNameMatches(doc, role, name) {
    let count = 0;
    for (const el of Array.from(doc.querySelectorAll("*"))) {
      if (getRole(el) === role && getAccessibleName(el) === name) count++;
      if (count > 1) break;
    }
    return count;
  }
  function findByRoleName(doc, role, name) {
    for (const el of Array.from(doc.querySelectorAll("*"))) {
      if (getRole(el) === role && getAccessibleName(el) === name) return el;
    }
    return null;
  }
  function countTextFingerprintMatches(doc, tag, text) {
    let count = 0;
    for (const el of Array.from(doc.querySelectorAll(tag))) {
      if (normalizeText(el.textContent) === text) count++;
      if (count > 1) break;
    }
    return count;
  }
  function findByTextFingerprint(doc, tag, text) {
    for (const el of Array.from(doc.querySelectorAll(tag))) {
      if (normalizeText(el.textContent) === text) return el;
    }
    return null;
  }
  function resolveLocator(candidates, doc) {
    const byStrategy = /* @__PURE__ */ new Map();
    for (const candidate of candidates) {
      const existing = byStrategy.get(candidate.strategy);
      if (!existing || candidate.confidence > existing.confidence) {
        byStrategy.set(candidate.strategy, candidate);
      }
    }
    for (let tierIndex = 0; tierIndex < STRATEGY_PRIORITY.length; tierIndex++) {
      const strategy = STRATEGY_PRIORITY[tierIndex];
      const candidate = byStrategy.get(strategy);
      if (!candidate) continue;
      const element = resolveOne(candidate, doc);
      if (element) {
        const penalty = 1 - tierIndex * 0.08;
        const confidence = Math.max(0.05, candidate.confidence * Math.max(0.3, penalty));
        return { element, confidence, strategy };
      }
    }
    return { element: null, confidence: 0, strategy: null };
  }
  function resolveOne(candidate, doc) {
    switch (candidate.strategy) {
      case "role-accessible-name": {
        const decoded = decodeRoleName(candidate.value);
        return decoded ? findByRoleName(doc, decoded.role, decoded.name) : null;
      }
      case "text-fingerprint": {
        const decoded = decodeTextFingerprint(candidate.value);
        return decoded ? findByTextFingerprint(doc, decoded.tag, decoded.text) : null;
      }
      case "data-attribute":
      case "stable-id":
      case "semantic-attribute":
      case "class-structure":
      case "ancestry-fingerprint":
      case "absolute-path":
      default:
        return safeQueryOne(doc, candidate.value);
    }
  }

  // src/shared/contrast.ts
  var NAMED_COLORS = {
    transparent: { r: 0, g: 0, b: 0, a: 0 },
    black: { r: 0, g: 0, b: 0, a: 1 },
    white: { r: 255, g: 255, b: 255, a: 1 }
  };
  function parseColor(input) {
    if (!input) return null;
    const value = input.trim().toLowerCase();
    if (value in NAMED_COLORS) return { ...NAMED_COLORS[value] };
    const rgbMatch = value.match(
      /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/
    );
    if (rgbMatch) {
      return {
        r: clamp255(Number(rgbMatch[1])),
        g: clamp255(Number(rgbMatch[2])),
        b: clamp255(Number(rgbMatch[3])),
        a: rgbMatch[4] !== void 0 ? clamp01(Number(rgbMatch[4])) : 1
      };
    }
    const hexMatch = value.match(/^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/);
    if (hexMatch) {
      const hex = hexMatch[1];
      if (hex.length === 3 || hex.length === 4) {
        const r2 = parseInt(hex[0] + hex[0], 16);
        const g2 = parseInt(hex[1] + hex[1], 16);
        const b2 = parseInt(hex[2] + hex[2], 16);
        const a2 = hex.length === 4 ? parseInt(hex[3] + hex[3], 16) / 255 : 1;
        return { r: r2, g: g2, b: b2, a: a2 };
      }
      const r = parseInt(hex.slice(0, 2), 16);
      const g = parseInt(hex.slice(2, 4), 16);
      const b = parseInt(hex.slice(4, 6), 16);
      const a = hex.length === 8 ? parseInt(hex.slice(6, 8), 16) / 255 : 1;
      return { r, g, b, a };
    }
    return null;
  }
  function clamp255(n) {
    return Math.min(255, Math.max(0, Number.isFinite(n) ? n : 0));
  }
  function clamp01(n) {
    return Math.min(1, Math.max(0, Number.isFinite(n) ? n : 0));
  }
  function relativeLuminance(color) {
    const srgb = [color.r, color.g, color.b].map((channel) => channel / 255);
    const linear = srgb.map((c) => c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
    const [r, g, b] = linear;
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }
  function contrastRatio(foreground, background) {
    const bg = background.a < 1 ? compositeOverWhite(background) : background;
    const fg = foreground.a < 1 ? compositeOver(foreground, bg) : foreground;
    const l1 = relativeLuminance(fg);
    const l2 = relativeLuminance(bg);
    const lighter = Math.max(l1, l2);
    const darker = Math.min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
  }
  function compositeOverWhite(color) {
    return compositeOver(color, { r: 255, g: 255, b: 255, a: 1 });
  }
  function compositeOver(top, bottom) {
    const a = top.a + bottom.a * (1 - top.a);
    if (a === 0) return { r: 255, g: 255, b: 255, a: 0 };
    const mix = (chTop, chBottom) => (chTop * top.a + chBottom * bottom.a * (1 - top.a)) / a;
    return { r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b), a };
  }
  function contrastRatioFromStrings(fg, bg) {
    const fgColor = parseColor(fg);
    const bgColor = parseColor(bg);
    if (!fgColor || !bgColor) return null;
    return contrastRatio(fgColor, bgColor);
  }
  function formatContrastRatio(ratio) {
    return `${ratio.toFixed(1)}:1`;
  }

  // src/content/inspector.ts
  var HOST_ID = "capture-inspector-root";
  var HOVER_THROTTLE_MS = 40;
  var active = false;
  var shadowHost = null;
  var shadowRoot = null;
  var highlightEl = null;
  var hoverCardEl = null;
  var hoveredElement = null;
  var pinnedElement = null;
  var selectedElements = /* @__PURE__ */ new Set();
  var rafPending = false;
  var lastMouseX = 0;
  var lastMouseY = 0;
  var lastMoveTimestamp = 0;
  var onMouseMove = (event) => scheduleHoverUpdate(event.clientX, event.clientY);
  var onClick = (event) => handleClick(event);
  var onKeyDown = (event) => handleKeyDown(event);
  var onScrollOrResize = () => {
    if (pinnedElement) positionOverlayFor(pinnedElement);
    else if (hoveredElement) positionOverlayFor(hoveredElement);
  };
  function activate() {
    if (active) return;
    active = true;
    buildOverlayHost();
    document.addEventListener("mousemove", onMouseMove, true);
    document.addEventListener("click", onClick, true);
    document.addEventListener("keydown", onKeyDown, true);
    window.addEventListener("scroll", onScrollOrResize, true);
    window.addEventListener("resize", onScrollOrResize, true);
  }
  function teardown() {
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
  function isActive() {
    return active;
  }
  function buildOverlayHost() {
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
  function scheduleHoverUpdate(x, y) {
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
  function updateHoverAt(x, y) {
    if (pinnedElement) return;
    const stack = document.elementsFromPoint(x, y);
    const candidate = stack.find((el) => el !== shadowHost && !shadowHost?.contains(el));
    if (!candidate || candidate === hoveredElement) return;
    hoveredElement = candidate;
    positionOverlayFor(candidate);
    renderHoverCard(candidate);
  }
  function positionOverlayFor(element) {
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
  function buildHoverCardText(element) {
    const computed = window.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    const tagLine = element.tagName.toLowerCase() + classSuffix(element);
    const dims = `${Math.round(rect.width)} \xD7 ${Math.round(rect.height)} px`;
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
  function renderHoverCard(element) {
    if (!hoverCardEl) return;
    hoverCardEl.textContent = buildHoverCardText(element);
  }
  function classSuffix(element) {
    const classes = Array.from(element.classList).slice(0, 3);
    return classes.length ? `.${classes.join(".")}` : "";
  }
  function firstFont(fontFamily) {
    return (fontFamily.split(",")[0] ?? "").trim().replace(/^["']|["']$/g, "");
  }
  function describeLineHeight(lineHeight) {
    if (lineHeight === "normal") return "normal";
    const px = parseFloat(lineHeight);
    return Number.isFinite(px) ? `${Math.round(px)} px` : lineHeight;
  }
  function shorthandEdges(computed, prefix) {
    const top = parseFloat(computed.getPropertyValue(`${prefix}-top`)) || 0;
    const right = parseFloat(computed.getPropertyValue(`${prefix}-right`)) || 0;
    const bottom = parseFloat(computed.getPropertyValue(`${prefix}-bottom`)) || 0;
    const left = parseFloat(computed.getPropertyValue(`${prefix}-left`)) || 0;
    if (top === bottom && left === right) {
      return top === left ? `${round(top)}px` : `${round(top)}px ${round(left)}px`;
    }
    return `${round(top)}px ${round(right)}px ${round(bottom)}px ${round(left)}px`;
  }
  function round(n) {
    return Math.round(n * 10) / 10;
  }
  function getEffectiveBackgroundColor(element) {
    let current = element;
    while (current) {
      const bg = window.getComputedStyle(current).backgroundColor;
      if (bg && bg !== "transparent" && bg !== "rgba(0, 0, 0, 0)") return bg;
      current = current.parentElement;
    }
    return "rgb(255, 255, 255)";
  }
  function toHex(color) {
    const match = color.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/);
    if (!match) return null;
    const [, r, g, b] = match;
    const hex = [r, g, b].map((v) => Math.round(Number(v)).toString(16).padStart(2, "0")).join("");
    return `#${hex.toUpperCase()}`;
  }
  function handleClick(event) {
    if (!hoveredElement && !pinnedElement) return;
    event.preventDefault();
    event.stopPropagation();
    const target = hoveredElement ?? pinnedElement;
    if (!target) return;
    pinElement(target, event.shiftKey);
  }
  function pinElement(element, additive) {
    pinnedElement = element;
    if (additive) selectedElements.add(element);
    else {
      selectedElements.clear();
      selectedElements.add(element);
    }
    positionOverlayFor(element);
    renderHoverCard(element);
    const evidence = buildElementEvidence(element);
    void chrome.runtime.sendMessage({ type: "element.pin", payload: { evidence } }).catch(() => {
    });
  }
  function handleKeyDown(event) {
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
    let next = null;
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
  var IMPORTANT_PROPERTIES = ["color", "background-color", "font-size", "font-family", "padding", "border-radius", "box-shadow", "display", "gap"];
  function buildElementEvidence(element) {
    const computed = window.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return {
      id: generateUuid(),
      capturedAt: (/* @__PURE__ */ new Date()).toISOString(),
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
  function buildLocator(element) {
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
  function buildBoxModel(computed, element) {
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
  function edgesFor(computed, prefix, suffix = "") {
    return {
      top: parseFloat(computed.getPropertyValue(`${prefix}-top${suffix}`)) || 0,
      right: parseFloat(computed.getPropertyValue(`${prefix}-right${suffix}`)) || 0,
      bottom: parseFloat(computed.getPropertyValue(`${prefix}-bottom${suffix}`)) || 0,
      left: parseFloat(computed.getPropertyValue(`${prefix}-left${suffix}`)) || 0
    };
  }
  function buildTypography(computed) {
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
  function buildAppearance(computed) {
    return {
      backgroundColor: computed.backgroundColor || null,
      backgroundImage: computed.backgroundImage && computed.backgroundImage !== "none" ? computed.backgroundImage : null,
      borderRadius: computed.borderRadius || null,
      boxShadow: computed.boxShadow && computed.boxShadow !== "none" ? computed.boxShadow : null,
      opacity: Number.isFinite(parseFloat(computed.opacity)) ? parseFloat(computed.opacity) : null
    };
  }
  function buildLayout(computed) {
    return {
      display: computed.display || null,
      flexDirection: computed.display.includes("flex") ? computed.flexDirection || null : null,
      zIndex: computed.zIndex && computed.zIndex !== "auto" ? computed.zIndex : null,
      overflow: computed.overflow || null
    };
  }
  function buildAccessibility(element, computed) {
    const ariaAttributes = {};
    for (const attr of Array.from(element.attributes)) {
      if (attr.name.startsWith("aria-")) ariaAttributes[attr.name] = attr.value;
    }
    const tabIndexAttr = element.getAttribute("tabindex");
    const tabIndex = tabIndexAttr !== null ? Number(tabIndexAttr) : element.tabIndex ?? null;
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
  function extractCssVariables(element, computed) {
    const referenced = /* @__PURE__ */ new Set();
    const varPattern = /var\(\s*(--[a-zA-Z0-9-_]+)/g;
    const scanText = (text) => {
      if (!text) return;
      for (const match of text.matchAll(varPattern)) {
        const name = match[1];
        if (name) referenced.add(name);
      }
    };
    scanText(element.getAttribute("style"));
    forEachMatchingRule(element, (rule) => scanText(rule.style.cssText));
    const result = {};
    for (const name of referenced) {
      const value = computed.getPropertyValue(name).trim();
      if (value) result[name] = value;
    }
    return result;
  }
  function buildAuthoredSources(element, computed) {
    const sources = [];
    let anySheetUnavailable = false;
    for (const property of IMPORTANT_PROPERTIES) {
      const computedValue = computed.getPropertyValue(property);
      const inline = element.style?.getPropertyValue(property);
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
      let found = null;
      let hadInaccessibleSheet = false;
      for (const sheet of Array.from(document.styleSheets)) {
        let rules;
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
    }
    return sources;
  }
  function forEachMatchingRule(element, callback) {
    for (const sheet of Array.from(document.styleSheets)) {
      let rules;
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
  function buildPageState() {
    const nav = navigator;
    return {
      colourScheme: window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light",
      locale: document.documentElement.lang || navigator.language || null,
      browser: detectBrowserFamilyForPageState(),
      os: nav.userAgentData?.platform ?? navigator.platform ?? null
    };
  }
  function detectBrowserFamilyForPageState() {
    const nav = navigator;
    if (nav.brave) return "brave";
    if (/Edg\//.test(navigator.userAgent)) return "edge";
    if (/Chrome\//.test(navigator.userAgent)) return navigator.vendor === "Google Inc." ? "chrome" : "chromium";
    return "unknown";
  }
  function handleRuntimeMessage(message, _sender, sendResponse) {
    if (!message || typeof message !== "object") return void 0;
    switch (message.type) {
      case "inspect.activate":
        activate();
        sendResponse({ version: 1, id: message.id, ok: true, payload: {} });
        return void 0;
      case "inspect.deactivate":
        teardown();
        sendResponse({ version: 1, id: message.id, ok: true, payload: {} });
        return void 0;
      case "element.captureRequest": {
        const locator = message.payload?.locator;
        if (!locator) {
          sendResponse({ version: 1, id: message.id, ok: false, error: { code: "INVALID_MESSAGE", message: "Missing locator" } });
          return void 0;
        }
        const result = resolveLocator([{ strategy: "absolute-path", value: locator, confidence: 0.5 }], document);
        if (!result.element) {
          sendResponse({ version: 1, id: message.id, ok: false, error: { code: "ELEMENT_NOT_FOUND", message: "Anchor not found" } });
          return void 0;
        }
        sendResponse({ version: 1, id: message.id, ok: true, payload: { evidence: buildElementEvidence(result.element) } });
        return void 0;
      }
      case "element.resolveAnchor": {
        const locator = message.payload?.locator;
        if (!locator) {
          sendResponse({ version: 1, id: message.id, ok: false, error: { code: "INVALID_MESSAGE", message: "Missing locator" } });
          return void 0;
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
            rect: rect ? { x: rect.x, y: rect.y, width: rect.width, height: rect.height } : void 0
          }
        });
        return void 0;
      }
      default:
        return void 0;
    }
  }
  if (typeof chrome !== "undefined" && chrome.runtime) {
    chrome.runtime.onMessage.addListener(handleRuntimeMessage);
  }
})();
//# sourceMappingURL=inspector.js.map
