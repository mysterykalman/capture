import { describe, expect, it } from "vitest";
import { contrastRatio, contrastRatioFromStrings, parseColor, relativeLuminance } from "../src/shared/contrast";

describe("parseColor", () => {
  it("parses rgb()", () => {
    expect(parseColor("rgb(17, 17, 17)")).toEqual({ r: 17, g: 17, b: 17, a: 1 });
  });

  it("parses rgba()", () => {
    expect(parseColor("rgba(255, 255, 255, 0.5)")).toEqual({ r: 255, g: 255, b: 255, a: 0.5 });
  });

  it("parses 6-digit hex", () => {
    expect(parseColor("#111111")).toEqual({ r: 17, g: 17, b: 17, a: 1 });
  });

  it("parses 3-digit hex", () => {
    expect(parseColor("#fff")).toEqual({ r: 255, g: 255, b: 255, a: 1 });
  });

  it("returns null for unparseable input", () => {
    expect(parseColor("not-a-color")).toBeNull();
    expect(parseColor(null)).toBeNull();
    expect(parseColor(undefined)).toBeNull();
  });
});

describe("relativeLuminance", () => {
  it("is 0 for black and 1 for white", () => {
    expect(relativeLuminance({ r: 0, g: 0, b: 0, a: 1 })).toBeCloseTo(0, 5);
    expect(relativeLuminance({ r: 255, g: 255, b: 255, a: 1 })).toBeCloseTo(1, 5);
  });
});

describe("contrastRatio", () => {
  it("is exactly 21:1 for black on white (the WCAG maximum)", () => {
    const ratio = contrastRatio({ r: 0, g: 0, b: 0, a: 1 }, { r: 255, g: 255, b: 255, a: 1 });
    expect(ratio).toBeCloseTo(21, 1);
  });

  it("is 1:1 for identical colours", () => {
    const ratio = contrastRatio({ r: 128, g: 64, b: 200, a: 1 }, { r: 128, g: 64, b: 200, a: 1 });
    expect(ratio).toBeCloseTo(1, 5);
  });

  it("matches the well-known #767676-on-white AA-boundary example (~4.5:1)", () => {
    const ratio = contrastRatio({ r: 0x76, g: 0x76, b: 0x76, a: 1 }, { r: 255, g: 255, b: 255, a: 1 });
    expect(ratio).toBeGreaterThan(4.4);
    expect(ratio).toBeLessThan(4.6);
  });

  it("is symmetric regardless of which colour is foreground/background", () => {
    const a = { r: 20, g: 120, b: 200, a: 1 };
    const b = { r: 240, g: 240, b: 240, a: 1 };
    expect(contrastRatio(a, b)).toBeCloseTo(contrastRatio(b, a), 10);
  });
});

describe("contrastRatioFromStrings", () => {
  it("computes the spec hover-card example (#FFFFFF text on #111111 background)", () => {
    const ratio = contrastRatioFromStrings("#FFFFFF", "#111111");
    expect(ratio).not.toBeNull();
    expect(ratio!).toBeGreaterThan(18);
    expect(ratio!).toBeLessThan(19);
  });

  it("returns null (never fabricates) when a colour can't be parsed", () => {
    expect(contrastRatioFromStrings("currentColor", "#111111")).toBeNull();
  });
});
