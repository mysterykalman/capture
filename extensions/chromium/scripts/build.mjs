import * as esbuild from "esbuild";
import { existsSync, mkdirSync, cpSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const outdir = path.join(root, "dist");
const watch = process.argv.includes("--watch");

if (!existsSync(outdir)) mkdirSync(outdir, { recursive: true });

// The background service worker (declared `"type": "module"` in the
// manifest) and the popup/options pages (loaded via `<script type="module">`)
// can be ES modules. Content scripts CANNOT: chrome.scripting.executeScript's
// `files`-based injection (used for the on-gesture inspector/bookmarks-bar/
// scroll-capture injection — see docs/PERMISSIONS.md, no static
// content_scripts manifest entry) runs the file as a classic script, which
// throws a SyntaxError on a top-level `import`/`export`. So content scripts
// are built separately as self-contained IIFEs.
const esmEntryPoints = {
  background: path.join(root, "src/background/index.ts"),
  "popup/popup": path.join(root, "src/popup/main.ts"),
  "options/options": path.join(root, "src/options/main.ts")
};

const iifeEntryPoints = {
  "content/inspector": path.join(root, "src/content/inspector.ts"),
  "content/bookmarks-bar": path.join(root, "src/content/bookmarksBar.ts"),
  "content/scroll-capture": path.join(root, "src/content/scrollCapture.ts")
};

const sharedOptions = {
  bundle: true,
  outdir,
  target: "chrome120",
  sourcemap: true,
  logLevel: "info"
};

const esmBuildOptions = { ...sharedOptions, entryPoints: esmEntryPoints, format: "esm" };
// IIFE format can't emit named exports; content scripts don't need any
// (they wire themselves up via chrome.runtime.onMessage listeners), so
// nothing is lost here even for the inspector module, which also exports
// a few functions purely for direct unit-testing under Vitest/Node.
const iifeBuildOptions = { ...sharedOptions, entryPoints: iifeEntryPoints, format: "iife" };

function copyStatic() {
  cpSync(path.join(root, "public"), outdir, { recursive: true });
  const srcStatic = [
    ["src/popup/popup.html", "popup/popup.html"],
    ["src/options/options.html", "options/options.html"]
  ];
  for (const [from, to] of srcStatic) {
    const src = path.join(root, from);
    if (existsSync(src)) {
      const dest = path.join(outdir, to);
      mkdirSync(path.dirname(dest), { recursive: true });
      cpSync(src, dest);
    }
  }
}

if (watch) {
  const esmCtx = await esbuild.context(esmBuildOptions);
  const iifeCtx = await esbuild.context(iifeBuildOptions);
  await Promise.all([esmCtx.watch(), iifeCtx.watch()]);
  copyStatic();
  console.log("Watching for changes...");
} else {
  await Promise.all([esbuild.build(esmBuildOptions), esbuild.build(iifeBuildOptions)]);
  copyStatic();
  console.log("Build complete:", outdir);
  console.log("Entry files:", readdirSync(outdir));
}
