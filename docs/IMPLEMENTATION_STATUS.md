# Capture — Implementation Status

Last updated: 2026-09-13 (initial build pass). This document is the
authoritative, honest record of what is implemented, partially
implemented, stubbed, blocked, or not started. Nothing here is aspirational
— see `docs/ARCHITECTURE.md` for why the scope was cut the way it was.

## Environment constraint (read first)

This repository was built in a Linux sandbox with **no Xcode and no Swift
toolchain**, and no network path to install one. **Every file under `mac/`
and `native-host/` has been written but never compiled, run, or tested.**
It is source code, reviewed for correctness by hand, not verified by a
compiler. It must be opened/built on a real Mac (Xcode 16+, macOS 15+)
before any of it can be trusted to work. The Chromium extension under
`extensions/chromium/` has actually been built and unit-tested in this
sandbox with Node.js — its status below reflects real `npm run build` /
`npm test` results, not aspiration.

## Status legend

- ✅ **Implemented** — real logic, not a stub; for Swift, "implemented"
  means written and reviewed, not compiler-verified (see above).
- 🟡 **Partial** — some real logic exists but the feature is incomplete.
- 🧱 **Scaffolded** — module/types exist to hold the feature; no working
  behaviour yet.
- ⛔ **Not started**.

(This document is filled in as each module is built — see the end of this
session's work for the final state.)
