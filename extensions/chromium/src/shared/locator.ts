/**
 * Robust locator-candidate generation and resolution.
 *
 * Implements the 8-tier priority order from the spec (Part I §8, digest
 * section "8. Robust Locator Strategy") and docs/IPC_PROTOCOL.md's
 * `ElementEvidence.locator` description:
 *
 *   1. data-* attributes (stable test/component identifiers)
 *   2. stable unique id
 *   3. role + accessible name
 *   4. semantic attributes (name/type/aria-label/...)
 *   5. class + structure combination
 *   6. text-content fingerprint
 *   7. DOM-ancestry fingerprint
 *   8. absolute DOM path (last resort)
 *
 * `generateLocatorCandidates` is a pure function of one element's current
 * DOM state (it reads the DOM to build/verify selectors, but never mutates
 * it). `resolveLocator` re-resolves a saved candidate list against a
 * (possibly different) document, in priority order, penalizing confidence
 * when only a low-priority strategy matches.
 */

import type { LocatorCandidate, LocatorStrategy } from "./elementEvidence";

/** Priority order, highest first — matches the schema's documented order
 * and the array index used for confidence penalties. */
export const STRATEGY_PRIORITY: LocatorStrategy[] = [
  "data-attribute",
  "stable-id",
  "role-accessible-name",
  "semantic-attribute",
  "class-structure",
  "text-fingerprint",
  "ancestry-fingerprint",
  "absolute-path"
];

const BASE_CONFIDENCE: Record<LocatorStrategy, number> = {
  "data-attribute": 0.97,
  "stable-id": 0.92,
  "role-accessible-name": 0.8,
  "semantic-attribute": 0.68,
  "class-structure": 0.52,
  "text-fingerprint": 0.4,
  "ancestry-fingerprint": 0.28,
  "absolute-path": 0.12
};

const PREFERRED_DATA_ATTRS = [
  "data-testid",
  "data-test-id",
  "data-test",
  "data-qa",
  "data-cy",
  "data-component",
  "data-component-id",
  "data-id"
];

/** IDs that look framework-generated rather than authored/stable. */
const LIKELY_GENERATED_ID = /^(?:[a-z]+-)?[0-9a-f]{6,}$|^:r[0-9a-z]+:$|^radix-|^:[0-9a-z]+:$|^\d+$/i;

const IMPLICIT_ROLE_BY_TAG: Record<string, string> = {
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

const INPUT_TYPE_ROLE: Record<string, string> = {
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

function cssEscape(value: string): string {
  const g = globalThis as { CSS?: { escape?: (v: string) => string } };
  if (g.CSS?.escape) return g.CSS.escape(value);
  // Minimal fallback: escape characters that are unsafe inside a quoted
  // attribute-selector value.
  return value.replace(/["\\]/g, "\\$&");
}

function safeQueryAll(root: ParentNode, selector: string): Element[] {
  try {
    return Array.from(root.querySelectorAll(selector));
  } catch {
    return [];
  }
}

function safeQueryOne(root: ParentNode, selector: string): Element | null {
  try {
    return root.querySelector(selector);
  } catch {
    return null;
  }
}

/** Computes an implicit or explicit ARIA role. Best-effort, not a full
 * implementation of the ARIA-in-HTML mapping spec. */
export function getRole(element: Element): string | null {
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

/** Best-effort accessible name computation (a simplified subset of the
 * AccName algorithm): aria-label, aria-labelledby, associated <label>,
 * alt/title, then visible text content for interactive/heading elements. */
export function getAccessibleName(element: Element): string | null {
  const ariaLabel = element.getAttribute("aria-label");
  if (ariaLabel?.trim()) return ariaLabel.trim();

  const labelledBy = element.getAttribute("aria-labelledby");
  if (labelledBy) {
    const doc = element.ownerDocument;
    const text = labelledBy
      .split(/\s+/)
      .map((id) => doc.getElementById(id)?.textContent?.trim() ?? "")
      .filter(Boolean)
      .join(" ");
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

  const isNamedByContent =
    ["button", "a", "summary"].includes(tag) || /^h[1-6]$/.test(tag) || getRole(element) === "button";
  if (isNamedByContent) {
    const text = element.textContent?.trim().replace(/\s+/g, " ");
    if (text) return text.slice(0, 200);
  }

  return null;
}

function elementSignature(element: Element, maxClasses = 2): string {
  const tag = element.tagName.toLowerCase();
  const classes = Array.from(element.classList).slice(0, maxClasses);
  return classes.length ? `${tag}.${classes.map(cssEscape).join(".")}` : tag;
}

function nthOfTypeSelector(element: Element): string {
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

function nthChildSelector(element: Element): string {
  const parent = element.parentElement;
  if (!parent) return element.tagName.toLowerCase();
  const index = Array.from(parent.children).indexOf(element) + 1;
  return `${element.tagName.toLowerCase()}:nth-child(${index})`;
}

/** Builds the full absolute-path selector chain from <html> to `element`. */
function buildAbsolutePath(element: Element): string {
  const parts: string[] = [];
  let current: Element | null = element;
  while (current) {
    parts.unshift(nthChildSelector(current));
    current = current.parentElement;
  }
  return parts.join(" > ");
}

/** Builds the ancestry fingerprint chain (root -> element), each segment a
 * compact tag+class signature. Returned both as the array the schema wants
 * on `locator.ancestryFingerprint` and as a joined CSS descendant selector
 * for the candidate value. */
export function buildAncestryChain(element: Element, maxDepth = 6): string[] {
  const chain: string[] = [];
  let current: Element | null = element;
  while (current && chain.length < maxDepth) {
    chain.unshift(elementSignature(current));
    current = current.parentElement;
  }
  return chain;
}

function uniquenessPenalty(root: ParentNode, selector: string): number {
  const matches = safeQueryAll(root, selector);
  if (matches.length === 1) return 1;
  if (matches.length === 0) return 0.5; // selector didn't even match itself; be cautious
  return 0.6; // matches, but not unique
}

/**
 * Generates ranked locator candidates for `element`, one per applicable
 * tier (tiers that don't apply — e.g. no data-* attributes — are skipped).
 * The array is sorted by descending confidence, which for this generator
 * also matches priority-tier order.
 */
export function generateLocatorCandidates(element: Element): LocatorCandidate[] {
  const doc = element.ownerDocument;
  const candidates: LocatorCandidate[] = [];

  // 1. data-* attributes
  const dataAttr = findDataAttribute(element);
  if (dataAttr) {
    const selector = `[${dataAttr.name}="${cssEscape(dataAttr.value)}"]`;
    candidates.push({
      strategy: "data-attribute",
      value: selector,
      confidence: BASE_CONFIDENCE["data-attribute"] * uniquenessPenalty(doc, selector)
    });
  }

  // 2. stable unique id
  const id = element.getAttribute("id");
  if (id && !LIKELY_GENERATED_ID.test(id)) {
    const selector = `#${cssEscape(id)}`;
    candidates.push({
      strategy: "stable-id",
      value: selector,
      confidence: BASE_CONFIDENCE["stable-id"] * uniquenessPenalty(doc, selector)
    });
  }

  // 3. role + accessible name
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

  // 4. semantic attributes
  const semanticSelector = buildSemanticSelector(element);
  if (semanticSelector) {
    candidates.push({
      strategy: "semantic-attribute",
      value: semanticSelector,
      confidence: BASE_CONFIDENCE["semantic-attribute"] * uniquenessPenalty(doc, semanticSelector)
    });
  }

  // 5. class + structure
  if (element.classList.length > 0) {
    const classes = Array.from(element.classList).slice(0, 3).map(cssEscape);
    const selector = `${element.tagName.toLowerCase()}.${classes.join(".")}:is(${nthOfTypeSelector(element)})`;
    // :is() with a single nth-of-type compound is just belt-and-braces;
    // fall back to a simpler, always-valid form.
    const simpleSelector = `.${classes.join(".")}`;
    const chosen = safeQueryAll(doc, simpleSelector).length >= 1 ? simpleSelector : selector;
    candidates.push({
      strategy: "class-structure",
      value: chosen,
      confidence: BASE_CONFIDENCE["class-structure"] * uniquenessPenalty(doc, chosen)
    });
  }

  // 6. text fingerprint
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

  // 7. ancestry fingerprint
  const ancestryChain = buildAncestryChain(element);
  if (ancestryChain.length > 0) {
    const selector = ancestryChain.join(" > ");
    candidates.push({
      strategy: "ancestry-fingerprint",
      value: selector,
      confidence: BASE_CONFIDENCE["ancestry-fingerprint"] * uniquenessPenalty(doc, selector)
    });
  }

  // 8. absolute DOM path (always available — last resort)
  candidates.push({
    strategy: "absolute-path",
    value: buildAbsolutePath(element),
    confidence: BASE_CONFIDENCE["absolute-path"]
  });

  candidates.sort((a, b) => b.confidence - a.confidence);
  return candidates;
}

function findDataAttribute(element: Element): { name: string; value: string } | null {
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

function buildSemanticSelector(element: Element): string | null {
  const tag = element.tagName.toLowerCase();
  const parts: string[] = [tag];
  const name = element.getAttribute("name");
  const type = element.getAttribute("type");
  const ariaLabel = element.getAttribute("aria-label");
  const htmlFor = element.getAttribute("for");
  if (name) parts.push(`[name="${cssEscape(name)}"]`);
  if (type) parts.push(`[type="${cssEscape(type)}"]`);
  if (!name && ariaLabel) parts.push(`[aria-label="${cssEscape(ariaLabel)}"]`);
  if (htmlFor) parts.push(`[for="${cssEscape(htmlFor)}"]`);
  if (parts.length === 1) return null; // no semantic attributes beyond the tag itself
  return parts.join("");
}

function normalizeText(text: string | null): string {
  return (text ?? "").trim().replace(/\s+/g, " ");
}

function encodeRoleName(role: string, name: string): string {
  return `role:${role};name:${name}`;
}

function decodeRoleName(value: string): { role: string; name: string } | null {
  const match = value.match(/^role:([^;]*);name:(.*)$/s);
  if (!match) return null;
  return { role: match[1] ?? "", name: match[2] ?? "" };
}

function encodeTextFingerprint(tag: string, text: string): string {
  return `tag:${tag};text:${text}`;
}

function decodeTextFingerprint(value: string): { tag: string; text: string } | null {
  const match = value.match(/^tag:([^;]*);text:(.*)$/s);
  if (!match) return null;
  return { tag: match[1] ?? "", text: match[2] ?? "" };
}

function countRoleNameMatches(doc: ParentNode, role: string, name: string): number {
  let count = 0;
  for (const el of Array.from(doc.querySelectorAll("*"))) {
    if (getRole(el) === role && getAccessibleName(el) === name) count++;
    if (count > 1) break;
  }
  return count;
}

function findByRoleName(doc: ParentNode, role: string, name: string): Element | null {
  for (const el of Array.from(doc.querySelectorAll("*"))) {
    if (getRole(el) === role && getAccessibleName(el) === name) return el;
  }
  return null;
}

function countTextFingerprintMatches(doc: ParentNode, tag: string, text: string): number {
  let count = 0;
  for (const el of Array.from(doc.querySelectorAll(tag))) {
    if (normalizeText(el.textContent) === text) count++;
    if (count > 1) break;
  }
  return count;
}

function findByTextFingerprint(doc: ParentNode, tag: string, text: string): Element | null {
  for (const el of Array.from(doc.querySelectorAll(tag))) {
    if (normalizeText(el.textContent) === text) return el;
  }
  return null;
}

export interface ResolveResult {
  element: Element | null;
  confidence: number;
  strategy: LocatorStrategy | null;
}

/**
 * Attempts to resolve `candidates` against `doc`, trying strategies in
 * priority-tier order (not necessarily the order the candidates array is
 * in). Returns the first element found, with confidence penalized the
 * further down the priority list the successful strategy was — reflecting
 * that a low-priority match is less trustworthy even when it succeeds.
 */
export function resolveLocator(candidates: LocatorCandidate[], doc: Document): ResolveResult {
  const byStrategy = new Map<LocatorStrategy, LocatorCandidate>();
  for (const candidate of candidates) {
    // If the same strategy appears twice, keep the highest-confidence one.
    const existing = byStrategy.get(candidate.strategy);
    if (!existing || candidate.confidence > existing.confidence) {
      byStrategy.set(candidate.strategy, candidate);
    }
  }

  for (let tierIndex = 0; tierIndex < STRATEGY_PRIORITY.length; tierIndex++) {
    const strategy = STRATEGY_PRIORITY[tierIndex]!;
    const candidate = byStrategy.get(strategy);
    if (!candidate) continue;

    const element = resolveOne(candidate, doc);
    if (element) {
      const penalty = 1 - tierIndex * 0.08; // lower-priority tier -> bigger penalty
      const confidence = Math.max(0.05, candidate.confidence * Math.max(0.3, penalty));
      return { element, confidence, strategy };
    }
  }

  return { element: null, confidence: 0, strategy: null };
}

function resolveOne(candidate: LocatorCandidate, doc: Document): Element | null {
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
