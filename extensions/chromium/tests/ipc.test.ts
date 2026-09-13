import { describe, expect, it } from "vitest";
import {
  createErrorResponse,
  createRequest,
  createSuccessResponse,
  generateUuid,
  type IPCErrorResponse,
  type IPCRequest,
  type IPCSuccessResponse
} from "../src/shared/ipc";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

describe("generateUuid", () => {
  it("produces distinct RFC4122 v4-shaped ids", () => {
    const a = generateUuid();
    const b = generateUuid();
    expect(a).toMatch(UUID_RE);
    expect(b).toMatch(UUID_RE);
    expect(a).not.toBe(b);
  });
});

describe("createRequest", () => {
  it("builds an envelope matching schemas/ipc/envelope.schema.json's request shape", () => {
    const request: IPCRequest = createRequest("session.start", { tabUrl: "https://example.com/" });
    expect(request.version).toBe(1);
    expect(request.id).toMatch(UUID_RE);
    expect(request.type).toBe("session.start");
    expect(request.payload).toEqual({ tabUrl: "https://example.com/" });
    expect(request.tabSessionId).toBeUndefined();
    // additionalProperties: false in the schema — assert no stray keys.
    expect(Object.keys(request).sort()).toEqual(["id", "payload", "type", "version"]);
  });

  it("includes tabSessionId only when provided", () => {
    const request = createRequest("element.pin", { evidence: {} }, "session-123");
    expect(request.tabSessionId).toBe("session-123");
    expect(Object.keys(request).sort()).toEqual(["id", "payload", "tabSessionId", "type", "version"]);
  });
});

describe("createSuccessResponse", () => {
  it("builds an envelope matching the response shape (ok: true)", () => {
    const response: IPCSuccessResponse = createSuccessResponse("req-1", { tabSessionId: "abc" });
    expect(response).toEqual({ version: 1, id: "req-1", ok: true, payload: { tabSessionId: "abc" } });
  });
});

describe("createErrorResponse", () => {
  it("builds an envelope matching the errorResponse shape (ok: false)", () => {
    const response: IPCErrorResponse = createErrorResponse("req-2", "ELEMENT_NOT_FOUND", "gone");
    expect(response).toEqual({
      version: 1,
      id: "req-2",
      ok: false,
      error: { code: "ELEMENT_NOT_FOUND", message: "gone" }
    });
  });

  it("truncates an overlong message to the schema's 2000-char maxLength", () => {
    const response = createErrorResponse("req-3", "INTERNAL_ERROR", "x".repeat(3000));
    expect(response.error.message.length).toBe(2000);
  });
});
