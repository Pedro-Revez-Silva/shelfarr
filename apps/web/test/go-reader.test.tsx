import { describe, expect, test } from "bun:test";
import { render, screen, waitFor, within } from "@testing-library/react";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { resetFirstPage } from "../src/components/PageHeading";
import { GoApp } from "../src/go/GoApp";
import { goBoot, libraryServer, renderGo, signedIn } from "./go-helpers";
import { ACCOUNT, page, summary } from "./helpers";

const tracks = [
  { id: "a".repeat(64), filename: "Part 1.wav", format: "wav", media_type: "audio/wav", size_bytes: 10, position: 0, url: `/preview/api/v1/accounts/${ACCOUNT}/library/8/assets/${"a".repeat(64)}` },
  { id: "b".repeat(64), filename: "Part 2.wav", format: "wav", media_type: "audio/wav", size_bytes: 10, position: 1, url: `/preview/api/v1/accounts/${ACCOUNT}/library/8/assets/${"b".repeat(64)}` },
];

describe("the Go reader view", () => {
  test("loads the account-bound reader description after sign-in and shows the player without saving anything", async () => {
    const server = libraryServer(() => signedIn()).on("GET", /\/api\/v1\/library\/8\/reader$/, () => ({
      body: { account: ACCOUNT, publication: { id: "8", title: "Spoken Sampler", author: "S. Voice", book_type: "audiobook", content_kind: "book", reading_status: "unread", assets: tracks, other_formats: [], progress: null } },
    }));
    resetFirstPage();
    window.history.replaceState(null, "", "/preview/library/8/read");
    render(<GoApp boot={{ ...goBoot("reader"), reader_engine: "/preview/assets/reader-engine.0123456789abcdef.js" }} fetcher={server.fetcher} />);
    await screen.findByRole("heading", { level: 1, name: "Spoken Sampler" });
    expect(screen.getByText(/Track 1 of 2:/).textContent).toBe("Track 1 of 2: Part 1.wav");
    expect(screen.getByRole("link", { name: "Back to the book" }).getAttribute("href")).toBe("/preview/library/8");
    expect(document.title).toBe("Spoken Sampler · Shelfarr");
    const [request] = server.called("GET", /\/library\/8\/reader$/);
    expect(request?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(server.called("PUT", /progress$/)).toHaveLength(0);
    expect(document.querySelector("audio")?.getAttribute("src")).toBe(tracks[0]?.url ?? "");
  });

  test("a PDF-only book says it cannot be opened here instead of showing a reader", async () => {
    const server = libraryServer(() => signedIn()).on("GET", /\/api\/v1\/library\/9\/reader$/, () => ({
      body: { account: ACCOUNT, publication: { id: "9", title: "Paper Only", author: null, book_type: "ebook", content_kind: "book", reading_status: "unread", assets: [], other_formats: ["pdf"], progress: null } },
    }));
    resetFirstPage();
    window.history.replaceState(null, "", "/preview/library/9/read");
    render(<GoApp boot={{ ...goBoot("reader"), reader_engine: "/preview/assets/reader-engine.0123456789abcdef.js" }} fetcher={server.fetcher} />);
    await screen.findByRole("heading", { level: 2, name: "This book can't be opened in this browser yet" });
    expect(screen.getByRole("note").textContent).toContain("Its PDF file is kept on the server");
  });
});

describe("Go Library links", () => {
  test("Keep going opens EPUBs and audiobooks in the Go reader and leaves PDFs as a label", async () => {
    const items = [
      summary({ id: "7", title: "Text Book", progress_label: "12% read", reading_status: "in_progress" }),
      summary({ id: "8", title: "Spoken Book", action: "listen", book_type: "audiobook", format_label: "Audiobook", progress_label: "Resume at 0:17", reading_status: "in_progress" }),
      summary({ id: "9", title: "Paper Book", format_label: "PDF", progress_label: "Page 3", reading_status: "in_progress" }),
    ];
    const server = libraryServer(() => signedIn())
      .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items } }))
      .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }));
    renderGo({ server, view: "library", url: "/preview/library" });
    const shelf = await screen.findByRole("region", { name: "Keep going" }).catch(() => screen.findByLabelText("Keep going"));
    await waitFor(() => expect(within(shelf).getAllByRole("heading", { level: 3 })).toHaveLength(3));
    const links = [...shelf.querySelectorAll("a.resume-link")].map((link) => link.getAttribute("href"));
    expect(links).toEqual(["/preview/library/7/read", "/preview/library/8/read"]);
    expect(within(shelf).getByText("Page 3").tagName).toBe("P");
    expect(screen.getByRole("note").textContent).toBe(
      "This experimental server lets you browse your library, read EPUBs and listen to audiobooks while online, and set reading status. PDFs, comics, downloads and offline reading are not available here yet.",
    );
  });
});

describe("the Go asset build", () => {
  test("ships the vendored EPUB engine byte for byte as the manifest's reader engine", () => {
    const directory = resolve(import.meta.dir, "..");
    const out = mkdtempSync(join(process.env["TMPDIR"] ?? directory, "build-go-"));
    try {
      const target = join(out, "assets");
      const build = Bun.spawnSync(["bun", "run", "build-go.ts", "--out", target], { cwd: directory, stdout: "pipe", stderr: "pipe" });
      expect(build.exitCode).toBe(0);
      const manifest = JSON.parse(readFileSync(join(target, "manifest.json"), "utf8"));
      const engine = manifest.entry.reader_engine as string;
      expect(engine).toMatch(/^reader-engine\.[0-9a-f]{16}\.js$/);
      expect(Buffer.compare(readFileSync(join(target, engine)), readFileSync(resolve(directory, "../../vendor/javascript/consumer_reader_engine.js")))).toBe(0);
      expect(manifest.files[engine].size).toBe(readFileSync(join(target, engine)).byteLength);
      expect(readFileSync(join(target, manifest.entry.script as string), "utf8")).not.toContain("epubjs");
    } finally {
      rmSync(out, { recursive: true, force: true });
    }
  });
});
