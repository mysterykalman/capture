# Schemas

JSON Schema (draft-07) contracts shared between the Swift app, the Native
Messaging host, and the Chromium extension. These are the source of truth
— when Swift/TypeScript types and a schema disagree, the schema is right
and the code has a bug.

- `ipc/envelope.schema.json` — the request/response/error envelope every
  message on the content-script → service-worker → native-host → Unix-socket
  → app chain uses. See `docs/IPC_PROTOCOL.md`.
- `ipc/messages.schema.json` — payload shape per `envelope.type`.
- `project/element-evidence.schema.json` — the `ElementEvidence` model
  (Part I's flagship DOM-anchored-evidence object).
- `project/annotation.schema.json` — the `Annotation` model used in a
  `.capture` package's `annotations.json`/`redactions.json`.
- `project/capture-project-manifest.schema.json` — a `.capture` package's
  `manifest.json`. See `docs/PROJECT_FORMAT.md`.
- `findings/audit-finding.schema.json` — the `AuditFinding` evidence
  object (not persisted inside a `.capture` package — see
  `docs/PROJECT_FORMAT.md`'s "Relationship to ElementEvidence and
  AuditFinding" section).

## Mirrored implementations

| Schema | Swift | TypeScript |
|---|---|---|
| `ipc/envelope.schema.json`, `ipc/messages.schema.json` | `mac/Sources/CaptureCore/Models/IPCMessage.swift` (+ `mac/Sources/CaptureBrowserBridge/Dispatch/`'s per-type payload structs) | `extensions/chromium/src/shared/ipc.ts` |
| `project/element-evidence.schema.json` | `mac/Sources/CaptureCore/Models/ElementEvidence.swift` | `extensions/chromium/src/shared/elementEvidence.ts` |
| `project/annotation.schema.json` | `mac/Sources/CaptureCore/Models/Annotation.swift` | — (not needed browser-side) |
| `project/capture-project-manifest.schema.json` | `mac/Sources/CaptureCore/Models/ProjectManifest.swift` | — |
| `findings/audit-finding.schema.json` | `mac/Sources/CaptureCore/Models/AuditFinding.swift` | — |

There is no automated schema-vs-code drift check in this build (that would
need a JSON Schema validator library on both sides, which was deliberately
avoided to keep dependencies minimal per Part I §37 — see the hand-written
`Decodable` structs in `CaptureBrowserBridge`'s message dispatcher instead).
Keeping this in sync by hand is a real, disclosed risk — see
`docs/IMPLEMENTATION_STATUS.md`.
