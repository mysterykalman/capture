# 0002 — `Capture*` module names instead of the spec's `Aspect*`

**Status:** decided
**Context:** Part I §3's suggested repository layout names the feature
modules `AspectApp`, `AspectCore`, `AspectCapture`, `AspectEditor`,
`AspectRecording`, `AspectHistory`, `AspectBrowserBridge`, `AspectPDF`,
`AspectInspection`, while the product itself is named `Capture` everywhere
else in the document. The spec's own digest of this section flags the
mismatch explicitly and defers to "confirm with stakeholders" — no
stakeholder is reachable mid-build, and the spec's operating instructions
say to pick the simplest choice consistent with the document and record the
decision here rather than stall.

**Decision:** use `Capture*`-prefixed module names (`CaptureApp`,
`CaptureCore`, `CaptureCapture`, `CaptureEditor`, `CaptureRecording`,
`CaptureHistory`, `CaptureBrowserBridge`, `CapturePDF`, `CaptureInspection`,
`CaptureUI`). `Aspect` does not appear anywhere else in the ~19,000-line
spec (product name, tagline, bundle identifiers, file format extension, URL
scheme, and every UI-copy example all say "Capture"), which is strong
evidence it is a leftover codename artifact rather than an intentional
distinct namespace. `CaptureCapture` reads a little redundantly as a name;
it was kept anyway for consistency with the rest of the `Capture*` module
family and because the alternative (reintroducing `Aspect` for one module
only) would be more confusing, not less. This is a cosmetic, low-risk,
easily-renamed-later decision.
