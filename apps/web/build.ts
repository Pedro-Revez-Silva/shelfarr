import { rm } from "node:fs/promises";
import { resolve } from "node:path";

const outdir = resolve(import.meta.dir, "../../app/assets/builds/web");

await rm(outdir, { recursive: true, force: true });

const result = await Bun.build({
  entrypoints: [resolve(import.meta.dir, "src/preview.tsx")],
  outdir,
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

for (const output of result.outputs) {
  console.log(`${output.path.replace(`${outdir}/`, "")} ${output.size} bytes`);
}
