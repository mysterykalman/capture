import * as esbuild from "esbuild";
import { existsSync, mkdirSync, cpSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const outdir = path.join(root, "dist");
const watch = process.argv.includes("--watch");

if (!existsSync(outdir)) mkdirSync(outdir, { recursive: true });

const entryPoints = {
  background: path.join(root, "src/background/index.ts"),
  "content/inspector": path.join(root, "src/content/inspector.ts"),
  "content/bookmarks-bar": path.join(root, "src/content/bookmarksBar.ts"),
  "content/scroll-capture": path.join(root, "src/content/scrollCapture.ts"),
  "popup/popup": path.join(root, "src/popup/main.ts"),
  "options/options": path.join(root, "src/options/main.ts")
};

const buildOptions = {
  entryPoints,
  bundle: true,
  outdir,
  format: "esm",
  target: "chrome120",
  sourcemap: true,
  logLevel: "info"
};

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
  const ctx = await esbuild.context(buildOptions);
  await ctx.watch();
  copyStatic();
  console.log("Watching for changes...");
} else {
  await esbuild.build(buildOptions);
  copyStatic();
  console.log("Build complete:", outdir);
  console.log("Entry files:", readdirSync(outdir));
}
