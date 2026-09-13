/**
 * WCAG 2.x contrast math. Pure functions, no DOM dependency, so they can be
 * unit tested directly and reused from the inspector content script against
 * real `getComputedStyle` colour strings.
 */

export interface RGBA {
  r: number; // 0-255
  g: number; // 0-255
  b: number; // 0-255
  a: number; // 0-1
}

const NAMED_COLORS: Record<string, RGBA> = {
  transparent: { r: 0, g: 0, b: 0, a: 0 },
  black: { r: 0, g: 0, b: 0, a: 1 },
  white: { r: 255, g: 255, b: 255, a: 1 }
};

/**
 * Parses a CSS colour string as produced by `getComputedStyle` — primarily
 * `rgb(r, g, b)` / `rgba(r, g, b, a)`, also `#rgb`/`#rrggbb`/`#rrggbbaa` and
 * a small set of named colours used in tests/fixtures. Returns null if the
 * string cannot be parsed (never fabricate a value).
 */
export function parseColor(input: string | null | undefined): RGBA | null {
  if (!input) return null;
  const value = input.trim().toLowerCase();

  if (value in NAMED_COLORS) return { ...NAMED_COLORS[value]! };

  const rgbMatch = value.match(
    /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/
  );
  if (rgbMatch) {
    return {
      r: clamp255(Number(rgbMatch[1])),
      g: clamp255(Number(rgbMatch[2])),
      b: clamp255(Number(rgbMatch[3])),
      a: rgbMatch[4] !== undefined ? clamp01(Number(rgbMatch[4])) : 1
    };
  }

  const hexMatch = value.match(/^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/);
  if (hexMatch) {
    const hex = hexMatch[1]!;
    if (hex.length === 3 || hex.length === 4) {
      const r = parseInt(hex[0]! + hex[0], 16);
      const g = parseInt(hex[1]! + hex[1], 16);
      const b = parseInt(hex[2]! + hex[2], 16);
      const a = hex.length === 4 ? parseInt(hex[3]! + hex[3], 16) / 255 : 1;
      return { r, g, b, a };
    }
    const r = parseInt(hex.slice(0, 2), 16);
    const g = parseInt(hex.slice(2, 4), 16);
    const b = parseInt(hex.slice(4, 6), 16);
    const a = hex.length === 8 ? parseInt(hex.slice(6, 8), 16) / 255 : 1;
    return { r, g, b, a };
  }

  return null;
}

function clamp255(n: number): number {
  return Math.min(255, Math.max(0, Number.isFinite(n) ? n : 0));
}
function clamp01(n: number): number {
  return Math.min(1, Math.max(0, Number.isFinite(n) ? n : 0));
}

/** WCAG relative luminance, 0 (black) .. 1 (white). */
export function relativeLuminance(color: RGBA): number {
  const srgb = [color.r, color.g, color.b].map((channel) => channel / 255);
  const linear = srgb.map((c) => (c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)));
  const [r, g, b] = linear as [number, number, number];
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/**
 * WCAG contrast ratio between two colours, 1..21. `background` is composited
 * against opaque white first if it carries alpha < 1 (an approximation —
 * true compositing would need the actual backdrop stack, which is out of
 * scope here).
 */
export function contrastRatio(foreground: RGBA, background: RGBA): number {
  const bg = background.a < 1 ? compositeOverWhite(background) : background;
  const fg = foreground.a < 1 ? compositeOver(foreground, bg) : foreground;
  const l1 = relativeLuminance(fg);
  const l2 = relativeLuminance(bg);
  const lighter = Math.max(l1, l2);
  const darker = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

function compositeOverWhite(color: RGBA): RGBA {
  return compositeOver(color, { r: 255, g: 255, b: 255, a: 1 });
}

function compositeOver(top: RGBA, bottom: RGBA): RGBA {
  const a = top.a + bottom.a * (1 - top.a);
  if (a === 0) return { r: 255, g: 255, b: 255, a: 0 };
  const mix = (chTop: number, chBottom: number) =>
    (chTop * top.a + chBottom * bottom.a * (1 - top.a)) / a;
  return { r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b), a };
}

/** Convenience: parse two colour strings and compute their contrast ratio.
 * Returns null (never fabricated) if either colour can't be parsed. */
export function contrastRatioFromStrings(fg: string | null | undefined, bg: string | null | undefined): number | null {
  const fgColor = parseColor(fg);
  const bgColor = parseColor(bg);
  if (!fgColor || !bgColor) return null;
  return contrastRatio(fgColor, bgColor);
}

export function formatContrastRatio(ratio: number): string {
  return `${ratio.toFixed(1)}:1`;
}
