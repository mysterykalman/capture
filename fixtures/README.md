# Test fixture sites

Static HTML pages used for manually or automatically exercising the
Chromium extension's inspector/locator/accessibility/ecommerce-detection
logic against real DOM (as opposed to the extension's vitest unit tests,
which construct DOM fixtures in-memory with jsdom). Per Part I §31's
testing-strategy requirement, these do not make any network requests and
use only inline/data-URI assets — they can be opened directly via
`file://` or served with any static file server.

- `inspector-test-site/` — nested DOM, an open shadow root, flex/grid
  layout, `::before`/`::after` pseudo-elements, CSS custom properties, an
  intentionally-unreachable cross-origin stylesheet `<link>` (to exercise
  the "source unavailable" fallback), a self-hosted-style `@font-face`,
  hover/focus states, a container query, and responsive breakpoints.
- `accessibility-test-site/` — landmarks, a deliberately-skipped heading
  level and a duplicate `<h1>`, low-contrast text next to high-contrast
  text, a below-guideline tap target, vague/empty links, missing `alt`,
  an unlabeled input, `tabindex`-scrambled focus order, and a couple of
  custom ARIA widgets (toggle button, tablist). Every "bad" example sits
  next to a "good" one so a detector's true/false-positive behaviour is
  checkable.
- `responsive-test-site/` — CSS breakpoints at the spec's own example
  widths (390/768/1024/1440px), a `prefers-color-scheme` block, and a
  `prefers-reduced-motion` block, with content that visibly rearranges at
  each breakpoint.
- `shopify-like-test-site/` — a fictitious PDP shaped like a typical
  Shopify theme: `Product`/`Offer` JSON-LD, a `data-product-form`,
  price + compare-at, a variant/size swatch fieldset (including a
  disabled/sold-out option), a reviews summary, and a recommendations
  module with a deliberate duplicate product (for dedupe-detection
  testing). Not modeled on, and does not reference, any real store,
  brand, or theme.

None of these are wired into the extension's `npm test` run automatically
(that suite uses jsdom fixtures) — they're for manual `chrome://extensions`
testing and future Playwright-based integration tests (Part I §31), which
are not implemented in this build (see `docs/IMPLEMENTATION_STATUS.md`).
