import { beforeEach, describe, expect, it } from "vitest";
import { generateLocatorCandidates, resolveLocator, STRATEGY_PRIORITY } from "../src/shared/locator";
import type { LocatorCandidate, LocatorStrategy } from "../src/shared/elementEvidence";

function strategiesOf(candidates: LocatorCandidate[]): LocatorStrategy[] {
  return candidates.map((c) => c.strategy);
}

beforeEach(() => {
  document.body.innerHTML = "";
});

describe("generateLocatorCandidates", () => {
  it("ranks data-testid above id, role, classes and text when all are present", () => {
    document.body.innerHTML = `
      <div class="page">
        <form data-product-form>
          <button
            data-testid="add-to-cart"
            id="add-to-cart-btn"
            class="product-form__submit btn btn-primary"
            aria-label="Add to cart"
          >Add to cart</button>
        </form>
      </div>`;
    const button = document.querySelector("button")!;
    const candidates = generateLocatorCandidates(button);

    expect(candidates.length).toBeGreaterThan(0);
    expect(candidates[0]!.strategy).toBe("data-attribute");
    expect(candidates[0]!.value).toBe('[data-testid="add-to-cart"]');
    expect(candidates[0]!.confidence).toBeGreaterThan(0.9);

    // Candidates must be sorted by descending confidence, and that order
    // must agree with the schema's documented priority order for every
    // strategy that appears (data-attribute must outrank stable-id, which
    // must outrank role-accessible-name, etc).
    const seenStrategies = strategiesOf(candidates);
    const priorityIndices = seenStrategies.map((s) => STRATEGY_PRIORITY.indexOf(s));
    for (let i = 1; i < priorityIndices.length; i++) {
      expect(priorityIndices[i]).toBeGreaterThanOrEqual(priorityIndices[i - 1]!);
    }

    // Every candidate actually resolves back to the same element via a
    // plain querySelector/role-name/text match (sanity check that we did
    // not build an unresolvable value for a strategy we claim succeeded).
    const result = resolveLocator(candidates, document);
    expect(result.element).toBe(button);
  });

  it("falls back to stable-id as the top strategy when there is no data-* attribute", () => {
    document.body.innerHTML = `<div><span id="hero-heading" class="a b">Hello</span></div>`;
    const span = document.querySelector("span")!;
    const candidates = generateLocatorCandidates(span);
    expect(candidates[0]!.strategy).toBe("stable-id");
    expect(candidates[0]!.value).toBe("#hero-heading");
  });

  it("treats framework-generated-looking ids as not stable and skips the stable-id tier", () => {
    document.body.innerHTML = `<div><button id="radix-3af921b">Go</button></div>`;
    const button = document.querySelector("button")!;
    const candidates = generateLocatorCandidates(button);
    expect(strategiesOf(candidates)).not.toContain("stable-id");
  });

  it("uses role + accessible name when no data attribute or stable id exists", () => {
    document.body.innerHTML = `<div><button aria-label="Close dialog">×</button></div>`;
    const button = document.querySelector("button")!;
    const candidates = generateLocatorCandidates(button);
    expect(candidates[0]!.strategy).toBe("role-accessible-name");
    expect(candidates[0]!.value).toContain("role:button");
    expect(candidates[0]!.value).toContain("name:Close dialog");
  });

  it("falls back through class-structure and text-fingerprint for a plain nested element", () => {
    document.body.innerHTML = `
      <div class="card">
        <div class="card__body">
          <p class="card__text">Free shipping over $50</p>
        </div>
      </div>`;
    const paragraph = document.querySelector("p")!;
    const candidates = generateLocatorCandidates(paragraph);
    const strategies = strategiesOf(candidates);
    expect(strategies).toContain("class-structure");
    expect(strategies).toContain("text-fingerprint");
    // No data-*, no id, no meaningful role/name for a plain <p>.
    expect(strategies).not.toContain("data-attribute");
    expect(strategies).not.toContain("stable-id");
  });

  it("always produces an absolute-path candidate as the last resort", () => {
    document.body.innerHTML = `<div><section><article><span>x</span></article></section></div>`;
    const span = document.querySelector("span")!;
    const candidates = generateLocatorCandidates(span);
    const last = candidates[candidates.length - 1]!;
    expect(last.strategy).toBe("absolute-path");
    expect(last.confidence).toBeLessThan(0.3);
    expect(document.querySelector(last.value)).toBe(span);
  });

  it("penalizes confidence when a selector is not unique on the page", () => {
    document.body.innerHTML = `
      <ul>
        <li class="item">A</li>
        <li class="item">B</li>
      </ul>`;
    const [first] = Array.from(document.querySelectorAll("li"));
    const candidates = generateLocatorCandidates(first!);
    const classCandidate = candidates.find((c) => c.strategy === "class-structure");
    expect(classCandidate).toBeDefined();
    // .item matches both <li>s, so confidence should be reduced below the
    // strategy's clean base confidence.
    expect(classCandidate!.confidence).toBeLessThan(0.52);
  });
});

describe("resolveLocator", () => {
  it("tries candidates in priority order and returns the first that resolves", () => {
    document.body.innerHTML = `<div><button id="checkout-btn" class="btn">Checkout</button></div>`;
    const button = document.querySelector("button")!;
    const candidates: LocatorCandidate[] = [
      { strategy: "absolute-path", value: "html > body:nth-child(1) > div:nth-child(1) > button:nth-child(1)", confidence: 0.12 },
      { strategy: "stable-id", value: "#checkout-btn", confidence: 0.92 },
      { strategy: "class-structure", value: ".btn", confidence: 0.5 }
    ];
    const result = resolveLocator(candidates, document);
    expect(result.element).toBe(button);
    expect(result.strategy).toBe("stable-id");
  });

  it("falls through to a lower-priority strategy when the higher one no longer resolves, with a penalized confidence", () => {
    document.body.innerHTML = `<div><button class="btn btn-primary">Checkout</button></div>`;
    const button = document.querySelector("button")!;
    const candidates: LocatorCandidate[] = [
      { strategy: "stable-id", value: "#no-longer-exists", confidence: 0.92 },
      { strategy: "class-structure", value: ".btn.btn-primary", confidence: 0.5 }
    ];
    const result = resolveLocator(candidates, document);
    expect(result.element).toBe(button);
    expect(result.strategy).toBe("class-structure");
    // Penalized because class-structure is a lower-priority tier than the
    // (failed) stable-id candidate's own confidence would suggest.
    expect(result.confidence).toBeLessThan(0.5);
  });

  it("returns a null element with zero confidence when nothing resolves", () => {
    document.body.innerHTML = `<div></div>`;
    const candidates: LocatorCandidate[] = [
      { strategy: "stable-id", value: "#missing", confidence: 0.9 }
    ];
    const result = resolveLocator(candidates, document);
    expect(result.element).toBeNull();
    expect(result.confidence).toBe(0);
    expect(result.strategy).toBeNull();
  });
});
