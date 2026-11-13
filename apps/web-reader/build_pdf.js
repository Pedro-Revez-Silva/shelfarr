// Builds the self-hosted PDF.js engine, its worker and the binary resources it
// fetches (standard fonts, CMaps, WebAssembly decoders) into an output folder,
// by default the checked-in vendor/javascript. Usage: bun run build_pdf.js [outdir]
import { mkdir, readdir, copyFile, rm, writeFile } from "node:fs/promises"
import { join, resolve } from "node:path"

const root = import.meta.dir
const out = resolve(process.argv[2] || join(root, "../../vendor/javascript"))
const dist = join(root, "node_modules/pdfjs-dist")
// Resources PDF.js asks for by name through the reader's resource factory.
// Not shipped: the scripting sandbox (QuickJS; scripting is disabled), the
// colour-management module (PDF.js only loads it when its worker fetches
// resources itself) and the no-WebAssembly fallbacks (imported by URL).
const RESOURCES = {
  cmaps: name => name.endsWith(".bcmap") || name === "LICENSE",
  standard_fonts: name => /\.(pfb|ttf)$/.test(name) || name.startsWith("LICENSE"),
  wasm: name => ["openjpeg.wasm", "jbig2.wasm"].includes(name) || (name.startsWith("LICENSE") && !name.includes("QCMS"))
}

async function bundle(entrypoint, outfile) {
  const result = await Bun.build({ entrypoints: [entrypoint], target: "browser", format: "esm", minify: true })
  if (!result.success) throw new AggregateError(result.logs, `Couldn't build ${entrypoint}`)
  if (result.outputs.length !== 1) throw new Error(`Expected one output for ${entrypoint}`)
  await writeFile(outfile, await result.outputs[0].text())
}

await mkdir(join(out, "pdfjs"), { recursive: true })
await bundle(join(root, "pdf_engine.js"), join(out, "consumer_pdf_engine.js"))
await bundle(join(dist, "build/pdf.worker.mjs"), join(out, "pdfjs/pdf.worker.js"))
for (const [folder, keep] of Object.entries(RESOURCES)) {
  const target = join(out, "pdfjs", folder)
  await rm(target, { recursive: true, force: true })
  await mkdir(target, { recursive: true })
  for (const name of (await readdir(join(dist, folder))).filter(keep).sort()) await copyFile(join(dist, folder, name), join(target, name))
}
