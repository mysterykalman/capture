# 0003 — Distribute outside the Mac App Store (Developer ID / ad-hoc), not sandboxed

**Status:** decided
**Context:** Capture needs: `ScreenCaptureKit` full-screen/window/area
capture (works inside the sandbox, but combined with everything below tips
the balance), `AXUIElement` accessibility inspection of arbitrary other
apps' windows for the bookmarks-bar privacy detector (not permitted in the
App Sandbox at all — Accessibility API access requires the unsandboxed
Accessibility permission model), a Unix domain socket at a fixed path under
`~/Library/Application Support/Capture/` for the browser bridge (workable
under the sandbox with a security-scoped exception but adds real
complexity), and the ability to launch/communicate with a separate Native
Messaging helper process that Chrome spawns outside the app's sandbox
container.

**Decision:** build and document Capture as a Developer ID–signed (or, for
this unverified build, ad-hoc-signed) app distributed outside the Mac App
Store, with `com.apple.security.app-sandbox` set to `false` in
`Capture.entitlements`. This is a real, deliberate scope decision, not an
oversight — Shottr, CleanShot X, and Snagit's Mac Screen Recorder feature
are all also **not** sandboxed App Store apps for exactly the ScreenCaptureKit/
AXUIElement/Accessibility reasons above.

**Consequences:**
- No Mac App Store distribution without a follow-up sandboxing effort
  (dropping or reworking the AXUIElement-based bookmarks-bar detector to
  rely solely on Tier 2/3 detection, and re-architecting the browser-bridge
  IPC to use an XPC service instead of a raw Unix socket).
- Users install via a downloaded, notarized `.dmg`/`.app`, not
  `mas://`. `docs/BUILD_AND_RUN.md` documents ad-hoc codesigning for local
  development builds; real distribution needs a paid Apple Developer ID
  certificate, which this sandbox obviously cannot provide or verify.
- Screen Recording and Accessibility permissions are still requested
  progressively (Part I §30) — sandboxing status and progressive permission
  requesting are orthogonal; this decision does not relax
  `docs/PERMISSIONS.md`.
