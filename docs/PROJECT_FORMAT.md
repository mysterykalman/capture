# Capture — `.capture` Project Format

Implements Part I §9. A `.capture` document is a **directory-style package**
(macOS `UTType` conforming to `com.apple.package`, presented as a single
double-clickable file in Finder) so annotations, redactions, measurements,
and DOM evidence stay non-destructively editable — nothing is flattened
until an explicit export or "Flatten" command (Part I §2.4, §12, anti-feature
#12).

```text
Example.capture/
├── manifest.json          Schema: schemas/project/capture-project-manifest.schema.json
├── source/
│   ├── original.png       Original captured pixels — never rewritten in place
│   └── recording.mov       (recordings only)
├── annotations.json       Array<Annotation> — schemas/project/annotation.schema.json
├── measurements.json      Array of measurement objects (live or stamped)
├── redactions.json        Array<Annotation> with type: "redact"
├── browser/
│   ├── elements.json       Array<ElementEvidence> referenced by annotations[].anchor
│   └── page.json           Capture-time page/browser metadata
├── recording/               (recordings only — Phase 5, not implemented)
│   ├── cursor-events.json
│   ├── clicks.json
│   ├── keystrokes.json
│   └── timeline.json
└── thumbnails/
    └── 256.png
```

## Rules

- **Relative paths only.** Every path referenced from `manifest.json` is
  relative to the package root, never absolute — the package must remain
  valid if the whole directory is moved or copied to another Mac.
- **Content hashes.** `manifest.json.source.contentHash` is `sha256:<hex>`
  of `source/original.png` (or `recording.mov`), so history dedupe and
  integrity checks don't require reading the whole file when only
  metadata changed.
- **Schema version + migrations.** `manifest.json.schemaVersion` is an
  integer. A reader that encounters a lower version than it understands
  must run the migration chain in
  `mac/Sources/CaptureCore/ProjectFormat/Migrations/`; it must never fail
  to open an older project outright.
- **Missing optional files are valid.** `measurements.json`,
  `redactions.json`, and everything under `browser/` may be absent — a
  reader must treat that as "none", not as corruption.
- **Source media is never rewritten** solely because an annotation
  changed. Only `annotations.json`, `measurements.json`, `redactions.json`,
  and `manifest.json.updatedAt` change on a normal edit.
- **Atomic writes.** Every write to this package goes through
  write-to-temp-then-rename inside the package directory, per Part I §35
  (crash safety) — see `CaptureCore.AtomicFileWriter`.

## Why a directory package and not a single binary blob

A package format lets Finder Quick Look and `Bundle`/`FileWrapper` APIs
work for free, lets large media stay out of a giant JSON string, and keeps
every sidecar independently diffable/inspectable — useful for a tool whose
entire purpose is producing evidence artifacts. The cost (many small files
instead of one) is judged acceptable per Part I's own document-package
guidance ("Use macOS document-package APIs or a robust directory-package
implementation").

## Relationship to `ElementEvidence` and `AuditFinding`

`annotations.json[].anchor.elementEvidenceId` references an object in
`browser/elements.json` by `id`. `AuditFinding` objects (when the project
belongs to an audit) are **not** stored inside the `.capture` package —
they live in the local history SQLite database and reference captures/
projects by id, per Part III §17/§24 ("not a Jira replacement", evidence
objects are indexed separately from the editable documents they cite).
