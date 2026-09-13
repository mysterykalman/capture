/**
 * TypeScript mirror of schemas/ipc/envelope.schema.json and
 * schemas/ipc/messages.schema.json.
 *
 * Keep this file in sync with those schemas field-for-field. See
 * docs/IPC_PROTOCOL.md for the transport chain and trust boundary this
 * type layer is enforcing.
 */

import type { ElementEvidence } from "./elementEvidence";

/** Closed set of envelope.type values (schemas/ipc/envelope.schema.json). */
export type IPCMessageType =
  | "session.start"
  | "session.end"
  | "session.ping"
  | "inspect.activate"
  | "inspect.deactivate"
  | "element.pin"
  | "element.captureRequest"
  | "element.evidence"
  | "element.resolveAnchor"
  | "tab.info"
  | "bookmarksBar.geometry"
  | "bookmarksBar.calibrate";

/** Closed set of error.code values (schemas/ipc/envelope.schema.json). */
export type IPCErrorCode =
  | "ELEMENT_NOT_FOUND"
  | "INVALID_MESSAGE"
  | "UNSUPPORTED_TYPE"
  | "TAB_SESSION_EXPIRED"
  | "PAYLOAD_TOO_LARGE"
  | "PERMISSION_DENIED"
  | "INTERNAL_ERROR";

/** Generic request envelope: {version, id, type, tabSessionId?, payload}. */
export interface IPCRequest<TPayload extends Record<string, unknown> = Record<string, unknown>> {
  version: 1;
  id: string;
  type: IPCMessageType;
  tabSessionId?: string;
  payload: TPayload;
}

/** Successful response envelope: {version, id, ok: true, payload}. */
export interface IPCSuccessResponse<TPayload extends Record<string, unknown> = Record<string, unknown>> {
  version: 1;
  id: string;
  ok: true;
  payload: TPayload;
}

/** Error response envelope: {version, id, ok: false, error: {code, message}}. */
export interface IPCErrorResponse {
  version: 1;
  id: string;
  ok: false;
  error: {
    code: IPCErrorCode;
    message: string;
  };
}

/** Discriminated union on `ok` — mirrors envelope.schema.json's oneOf. */
export type IPCResponse<TPayload extends Record<string, unknown> = Record<string, unknown>> =
  | IPCSuccessResponse<TPayload>
  | IPCErrorResponse;

// ---------------------------------------------------------------------------
// Per-message payload shapes (schemas/ipc/messages.schema.json)
// ---------------------------------------------------------------------------

export interface SessionStartRequestPayload {
  tabUrl: string;
  tabTitle?: string;
}
export interface SessionStartResponsePayload extends Record<string, unknown> {
  tabSessionId: string;
}

export type SessionEndRequestPayload = Record<string, never>;
export type SessionPingRequestPayload = Record<string, never>;
export interface SessionPingResponsePayload extends Record<string, unknown> {
  appVersion: string;
}

export interface InspectActivateRequestPayload {
  mode?: "hover" | "pinned";
}
export type InspectDeactivateRequestPayload = Record<string, never>;

export interface ElementPinRequestPayload extends Record<string, unknown> {
  evidence: ElementEvidence;
}

export interface ElementCaptureRequestPayload {
  locator: string;
  includeContextPaddingPx?: number;
}

export interface ElementEvidenceRequestPayload extends Record<string, unknown> {
  evidence: ElementEvidence;
}

export interface ElementResolveAnchorRequestPayload {
  locator: ElementEvidence["locator"];
}
export interface ElementResolveAnchorResponsePayload extends Record<string, unknown> {
  resolved: boolean;
  confidence?: number;
  rect?: ElementEvidence["rect"];
}

export interface TabInfoRequestPayload extends Record<string, unknown> {
  url: string;
  title: string;
  viewport: ElementEvidence["viewport"];
}

export type BrowserFamily = "chrome" | "chromium" | "edge" | "brave" | "arc" | "unknown";

export interface BookmarksBarGeometryRequestPayload extends Record<string, unknown> {
  innerWidth: number;
  innerHeight: number;
  outerWidth: number;
  outerHeight: number;
  screenX: number;
  screenY: number;
  devicePixelRatio: number;
  browser?: BrowserFamily;
}

export interface BookmarksBarCalibrateRequestPayload {
  browser: string;
  displayScale?: number;
  normalizedRect: { x: number; y: number; width: number; height: number };
}

/** Builds a well-formed request envelope with a fresh random id. */
export function createRequest<TPayload extends Record<string, unknown>>(
  type: IPCMessageType,
  payload: TPayload,
  tabSessionId?: string
): IPCRequest<TPayload> {
  const request: IPCRequest<TPayload> = {
    version: 1,
    id: generateUuid(),
    type,
    payload
  };
  if (tabSessionId) request.tabSessionId = tabSessionId;
  return request;
}

export function createSuccessResponse<TPayload extends Record<string, unknown>>(
  id: string,
  payload: TPayload
): IPCSuccessResponse<TPayload> {
  return { version: 1, id, ok: true, payload };
}

export function createErrorResponse(id: string, code: IPCErrorCode, message: string): IPCErrorResponse {
  return { version: 1, id, ok: false, error: { code, message: message.slice(0, 2000) } };
}

/** RFC4122 v4 UUID. Uses crypto.randomUUID when available (service worker,
 * modern browsers, Node 19+); falls back to a Math.random-based generator
 * for older test environments. Not used for anything security-sensitive. */
export function generateUuid(): string {
  const g = globalThis as { crypto?: { randomUUID?: () => string } };
  if (g.crypto?.randomUUID) return g.crypto.randomUUID();
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}
