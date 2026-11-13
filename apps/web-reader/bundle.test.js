// The checked-in PDF engine, worker and resources must be exactly what the
// pinned packages build. CI also rebuilds and diffs the EPUB engine.
import { expect, test } from "bun:test"
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises"
import { join, relative } from "node:path"

const root = import.meta.dir
const vendor = join(root, "../../vendor/javascript")

async function files(directory) {
  const entries = await readdir(directory, { recursive: true, withFileTypes: true })
  return entries.filter(entry => entry.isFile()).map(entry => relative(directory, join(entry.parentPath, entry.name))).sort()
}

test("the vendored PDF engine matches a fresh build", async () => {
  const out = await mkdtemp(join(process.env.TMPDIR || root, "pdf-build-"))
  try {
    const build = Bun.spawnSync(["bun", "run", join(root, "build_pdf.js"), out], { cwd: root, stdout: "pipe", stderr: "pipe" })
    expect(build.exitCode).toBe(0)
    const built = await files(out)
    expect(built).toContain("consumer_pdf_engine.js")
    expect(built).toContain("pdfjs/pdf.worker.js")
    const vendored = (await files(vendor)).filter(path => path === "consumer_pdf_engine.js" || path.startsWith("pdfjs/"))
    expect(vendored).toEqual(built)
    for (const path of built) expect(Buffer.compare(await readFile(join(out, path)), await readFile(join(vendor, path)))).toBe(0)
  } finally {
    await rm(out, { recursive: true, force: true })
  }
}, 60_000)

test("the PDF engine has no remote or evaluated code paths", async () => {
  for (const path of ["consumer_pdf_engine.js", "pdfjs/pdf.worker.js"]) {
    const source = await readFile(join(vendor, path), "utf8")
    expect(source).not.toMatch(/new Function\(|\beval\(/)
    expect(source).not.toMatch(/https?:\/\/(?!www\.w3\.org|ns\.adobe\.com|www\.xfa\.org|foo\.bar|example\.com)[a-z]/i)
  }
})
