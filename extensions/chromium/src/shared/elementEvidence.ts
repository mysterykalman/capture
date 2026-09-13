/**
 * TypeScript mirror of schemas/project/element-evidence.schema.json.
 * Keep field-for-field in sync — same key names, same nesting, same enums.
 * Do NOT persist a full DOM dump by default (see schema description).
 */

export type LocatorStrategy =
  | "data-attribute"
  | "stable-id"
  | "role-accessible-name"
  | "semantic-attribute"
  | "class-structure"
  | "text-fingerprint"
  | "ancestry-fingerprint"
  | "absolute-path";

export interface LocatorCandidate {
  strategy: LocatorStrategy;
  value: string;
  confidence: number; // 0..1
}

export interface Locator {
  primary: string;
  candidates: LocatorCandidate[];
  role?: string | null;
  accessibleName?: string | null;
  textFingerprint?: string | null;
  ancestryFingerprint?: string[];
}

export interface Viewport {
  width: number;
  height: number;
  devicePixelRatio: number;
  scrollX: number;
  scrollY: number;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface Edges {
  top?: number;
  right?: number;
  bottom?: number;
  left?: number;
}

export interface RectSize {
  width?: number;
  height?: number;
}

export interface BoxModel {
  padding?: Edges;
  border?: Edges;
  margin?: Edges;
  contentBox?: RectSize;
  gap?: string | null;
  display?: string | null;
  position?: string | null;
}

export interface Typography {
  fontFamilyAuthored?: string | null;
  fontFamilyRendered?: string | null;
  fontSizePx?: number | null;
  fontWeight?: string | number | null;
  fontStyle?: string | null;
  lineHeightPx?: number | null;
  letterSpacing?: string | null;
  textAlign?: string | null;
  textColor?: string | null;
  sourceURL?: string | null;
  sourceFormat?: string | null;
}

export interface Appearance {
  backgroundColor?: string | null;
  backgroundImage?: string | null;
  borderRadius?: string | null;
  boxShadow?: string | null;
  opacity?: number | null;
}

export interface Layout {
  display?: string | null;
  flexDirection?: string | null;
  zIndex?: string | null;
  overflow?: string | null;
}

export interface Accessibility {
  role?: string | null;
  accessibleName?: string | null;
  focusable?: boolean | null;
  tabIndex?: number | null;
  ariaAttributes?: Record<string, string>;
  contrastRatio?: number | null;
}

export interface AuthoredSource {
  property: string;
  computedValue: string;
  authoredDeclaration?: string | null;
  selector?: string | null;
  stylesheetURL?: string | null;
  sourceUnavailable?: boolean;
}

export interface PageState {
  colourScheme?: string | null;
  locale?: string | null;
  browser?: string | null;
  os?: string | null;
}

export interface ElementEvidence {
  id: string;
  capturedAt: string; // ISO-8601 date-time
  url: string;
  title?: string;
  viewport: Viewport;
  locator: Locator;
  rect: Rect;
  boxModel?: BoxModel;
  typography?: Typography;
  appearance?: Appearance;
  layout?: Layout;
  accessibility?: Accessibility;
  cssVariables?: Record<string, string>;
  authoredSources?: AuthoredSource[];
  pageState?: PageState;
}
