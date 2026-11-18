import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";

const FONT_DIRECTORY = resolve(import.meta.dir, "../design/assets/fonts");
const FONTS = ["Newsreader-Regular", "Newsreader-SemiBold"];
const VENDOR = resolve(import.meta.dir, "../../vendor/javascript");
const READER_ENGINE = join(VENDOR, "consumer_reader_engine.js");
const PDF_ENGINE = join(VENDOR, "consumer_pdf_engine.js");
const PDF_WORKER = join(VENDOR, "pdfjs/pdf.worker.js");
const PDF_RESOURCES = [
  { folder: "cmaps", kind: "cMapUrl", stem: "cmap" },
  { folder: "standard_fonts", kind: "standardFontDataUrl", stem: "font" },
  { folder: "wasm", kind: "wasmUrl", stem: "wasm" },
] as const;
const PDF_RESOURCE_NAME = /^([A-Za-z0-9][A-Za-z0-9-]*)(\.(?:bcmap|pfb|ttf|wasm))$/;

function option(name: string): string {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value) {
    console.error(`usage: bun run build-go.ts --out ABSOLUTE_DIRECTORY`);
    process.exit(2);
  }
  return value;
}

function addressed(stem: string, body: Uint8Array, extension: string): { name: string; sha256: string } {
  const sha256 = createHash("sha256").update(body).digest("hex");
  return { name: `${stem}.${sha256.slice(0, 16)}${extension}`, sha256 };
}

const outdir = option("--out");
if (!isAbsolute(outdir) || outdir === "/") {
  console.error("--out must be an absolute directory");
  process.exit(2);
}

const staging = `${outdir}.staging`;
await rm(staging, { recursive: true, force: true });
await mkdir(staging, { recursive: true });

const result = await Bun.build({
  entrypoints: [resolve(import.meta.dir, "src/preview.tsx")],
  outdir: staging,
  target: "browser",
  format: "esm",
  splitting: false,
  minify: true,
  sourcemap: "none",
  naming: "[name].[ext]",
  external: ["*.ttf", "consumer_pdf_engine"],
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
});
if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

const files: Record<string, { sha256: string; size: number }> = {};
const bodies = new Map<string, Uint8Array>();

let style = await readFile(join(staging, "preview.css"), "utf8");
for (const stem of FONTS) {
  const body = new Uint8Array(await readFile(join(FONT_DIRECTORY, `${stem}.ttf`)));
  const { name, sha256 } = addressed(stem, body, ".ttf");
  const reference = `../${stem}.ttf`;
  if (!style.includes(reference)) throw new Error(`the stylesheet no longer references ${reference}`);
  style = style.replaceAll(reference, name);
  bodies.set(name, body);
  files[name] = { sha256, size: body.byteLength };
}
if (/url\(["']?\.\.\//.test(style)) throw new Error("the stylesheet still has a parent-relative url");

const script = new Uint8Array(await readFile(join(staging, "preview.js")));
const styleBytes = new TextEncoder().encode(style);
const scriptName = addressed("preview", script, ".js");
const styleName = addressed("preview", styleBytes, ".css");
bodies.set(scriptName.name, script);
bodies.set(styleName.name, styleBytes);
files[scriptName.name] = { sha256: scriptName.sha256, size: script.byteLength };
files[styleName.name] = { sha256: styleName.sha256, size: styleBytes.byteLength };
const engine = new Uint8Array(await readFile(READER_ENGINE));
const engineName = addressed("reader-engine", engine, ".js");
bodies.set(engineName.name, engine);
files[engineName.name] = { sha256: engineName.sha256, size: engine.byteLength };

const pageFiles: Record<string, { sha256: string; size: number }> = {};
async function addPageFile(stem: string, path: string, extension: string): Promise<string> {
  const body = new Uint8Array(await readFile(path));
  const { name, sha256 } = addressed(stem, body, extension);
  bodies.set(name, body);
  pageFiles[name] = { sha256, size: body.byteLength };
  return name;
}
const pageEngine = await addPageFile("pdf-engine", PDF_ENGINE, ".js");
const pageWorker = await addPageFile("pdf-worker", PDF_WORKER, ".js");
const pageResources: Record<string, Record<string, string>> = {};
for (const { folder, kind, stem } of PDF_RESOURCES) {
  const names: Record<string, string> = {};
  for (const logical of (await readdir(join(VENDOR, "pdfjs", folder))).sort()) {
    const parts = PDF_RESOURCE_NAME.exec(logical);
    if (!parts) {
      if (logical.startsWith("LICENSE")) continue;
      throw new Error(`unexpected PDF resource ${folder}/${logical}`);
    }
    names[logical] = await addPageFile(`${stem}-${parts[1]}`, join(VENDOR, "pdfjs", folder, logical), parts[2] ?? "");
  }
  pageResources[kind] = names;
}

await rm(outdir, { recursive: true, force: true });
await mkdir(outdir, { recursive: true });
for (const [name, body] of bodies) await writeFile(join(outdir, name), body);
const sorted = Object.fromEntries(Object.entries(files).sort(([a], [b]) => (a < b ? -1 : 1)));
await writeFile(join(outdir, "manifest.json"), `${JSON.stringify({ version: 1, entry: { script: scriptName.name, style: styleName.name, reader_engine: engineName.name }, files: sorted }, null, 2)}\n`);
const sortedPages = Object.fromEntries(Object.entries(pageFiles).sort(([a], [b]) => (a < b ? -1 : 1)));
await writeFile(join(outdir, "page-engine.json"), `${JSON.stringify({ version: 1, script: scriptName.name, engine: pageEngine, worker: pageWorker, resources: pageResources, files: sortedPages }, null, 2)}\n`);
await rm(staging, { recursive: true, force: true });

for (const name of (await readdir(outdir)).sort()) console.log(name);
