import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import axe from "axe-core";
import type { Browser, BrowserContext, Page } from "playwright-core";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, newContext, policyViolations, signIn, startServer, unexpectedConsole, watch, type RunningServer } from "./harness";

const fixture = loadFixture();
const cases = fixture.discover;
const FIELDS = "key,title,author_name,first_publish_year,cover_i,edition_count";
const COVER = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAFklEQVR4nGNgYGBg+M/AwMDAwMDAAAAN/gEB0XhtxgAAAABJRU5ErkJggg==", "base64");
let browser: Browser;

type JournalEntry = { kind: string; target?: string; path?: string; query?: Record<string, string[]>; headers?: Record<string, string[]>; cancelled?: boolean };

class FakeOpenLibrary {
  readonly proxy: string;
  readonly ca: string;
  private readonly journalPath: string;
  private readonly directory: string;
  private readonly child: Bun.Subprocess;

  private constructor(directory: string, child: Bun.Subprocess, ready: { proxy: string; ca: string; journal: string }) {
    this.directory = directory;
    this.child = child;
    this.proxy = ready.proxy;
    this.ca = ready.ca;
    this.journalPath = ready.journal;
  }

  static async start(): Promise<FakeOpenLibrary> {
    const directory = mkdtempSync(join(process.env["TMPDIR"] ?? "", "fake-ol-"));
    const response = join(directory, "search.json");
    writeFileSync(response, cases.response);
    const child = Bun.spawn([artifacts.fakeOpenLibrary(), "-dir", directory, "-response", response], { stdout: "pipe", stderr: "inherit", env: { PATH: process.env["PATH"] ?? "" } });
    const reader = child.stdout.getReader();
    const { value } = await reader.read();
    reader.releaseLock();
    const ready = JSON.parse(new TextDecoder().decode(value).split("\n")[0] ?? "{}");
    return new FakeOpenLibrary(directory, child, ready);
  }

  journal(): JournalEntry[] {
    const text = readFileSync(this.journalPath, "utf8");
    return text.split("\n").filter(Boolean).map((line) => JSON.parse(line) as JournalEntry);
  }

  searches(): JournalEntry[] {
    return this.journal().filter((entry) => entry.kind === "request");
  }

  environment(): Record<string, string> {
    return { HTTPS_PROXY: this.proxy, SSL_CERT_FILE: this.ca };
  }

  async stop() {
    this.child.kill("SIGTERM");
    await this.child.exited;
    rmSync(this.directory, { recursive: true, force: true });
  }
}

let fake: FakeOpenLibrary;

beforeAll(async () => {
  browser = await launchBrowser();
  fake = await FakeOpenLibrary.start();
});

afterAll(async () => {
  await browser.close();
  await fake.stop();
});

async function serve(enabled = true): Promise<RunningServer> {
  return startServer({ fixture, extraArguments: ["-login-attempts", "1000", ...(enabled ? ["-open-library-search"] : [])], environment: fake.environment() });
}

type Opened = { context: BrowserContext; page: Page; seen: Awaited<ReturnType<typeof watch>>; outside: string[]; covers: string[] };

async function open(server: RunningServer, options: { colorScheme?: "light" | "dark"; viewport?: { width: number; height: number } } = {}): Promise<Opened> {
  const context = await newContext(browser, options);
  const outside: string[] = [];
  const covers: string[] = [];
  await context.route("https://covers.openlibrary.org/**", async (route) => {
    covers.push(`${route.request().url()} referer=${route.request().headers()["referer"] ?? ""}`);
    await route.fulfill({ status: 200, contentType: "image/png", body: COVER });
  });
  context.on("request", (request) => {
    const url = new URL(request.url());
    if (url.origin !== server.origin && url.origin !== "https://covers.openlibrary.org") outside.push(request.url());
  });
  const page = await context.newPage();
  const seen = await watch(page);
  return { context, page, seen, outside, covers };
}

const READER = "browser_account";

async function coversLoaded(page: Page) {
  for (const image of await page.locator("article img").all()) await image.scrollIntoViewIfNeeded();
  await page.waitForFunction(() => [...document.querySelectorAll("article img")].every((image) => (image as HTMLImageElement).complete));
  await page.evaluate(() => window.scrollTo(0, 0));
}

async function openDiscover(page: Page, origin: string, path = "/preview/discover") {
  await page.goto(`${origin}${path}`);
  await page.getByText("Sign in to find books. You will come straight back to your search.").waitFor();
  await signIn(page, READER, fixture.passwords[READER] ?? "");
  await page.getByRole("heading", { name: "Find", level: 1 }).waitFor();
}

async function search(page: Page, text: string) {
  const box = page.getByRole("searchbox", { name: "Title or author" });
  await box.fill(text);
  await box.press("Enter");
}

const tables = (server: RunningServer) =>
  server
    .query<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    .map(({ name }) => `${name}:${JSON.stringify(server.query(`SELECT * FROM "${name}" ORDER BY rowid`))}`)
    .join("\n");

function expectedItems() {
  const library = (id: string) => {
    const verdict = cases.rails_library[id];
    if (!verdict) return [];
    return (["ebook", "audiobook", "comicbook"] as const).flatMap((type) => {
      const rails = verdict[type];
      if (rails?.acquired) return [{ book_type: type, publication_id: String(rails.book_id) }];
      if (type === "ebook" && id === "OL900001W") return [{ book_type: type, publication_id: String(cases.books.text) }];
      return [];
    });
  };
  const seen = new Set<string>();
  return cases.rails_results.flatMap((result) => {
    if (!/^OL[1-9]\d*W$/.test(result.work_id) || seen.has(result.work_id)) return [];
    seen.add(result.work_id);
    const cover = typeof result.cover_id === "number" && result.cover_id > 0 ? result.cover_url : null;
    return [
      {
        id: result.work_id,
        title: result.title.replace(/\s+/g, " ").trim(),
        author: result.author,
        first_publish_year: typeof result.first_publish_year === "number" ? result.first_publish_year : null,
        edition_count: result.edition_count,
        cover_url: cover,
        source_url: `https://openlibrary.org/works/${result.work_id}`,
        library: library(result.work_id),
      },
    ];
  });
}

describe("Discover in the Go preview", () => {
  test("stays off until the operator switches it on, and then never contacts Open Library", async () => {
    const server = await serve(false);
    const before = fake.journal().length;
    const { context, page, seen, outside } = await open(server);
    const status = page.waitForResponse((response) => response.url().endsWith("/preview/api/v1/discover?q=reader+sampler"));
    await openDiscover(page, server.origin, "/preview/discover?q=reader+sampler");
    expect((await (await status).json()).search).toBe("server_off");
    await page.getByRole("heading", { name: "Search is switched off on this server", level: 2 }).waitFor();
    expect(await page.getByRole("searchbox").count()).toBe(0);
    expect(await page.title()).toBe("Find: reader sampler · Shelfarr");
    expect(fake.journal().length).toBe(before);
    expect(outside).toEqual([]);
    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("searches only on submit, attributes Open Library, links the acquired copies of the same work and writes nothing", async () => {
    const server = await serve();
    const before = fake.searches().length;
    const { context, page, seen, outside, covers } = await open(server);
    await openDiscover(page, server.origin);
    await page.getByText("What you type is sent to Open Library when you press Search.").waitFor();
    await page.waitForTimeout(400);
    expect(fake.searches().length).toBe(before);
    const rows = tables(server);
    const box = page.getByRole("searchbox", { name: "Title or author" });
    await box.pressSequentially("reader sampler", { delay: 15 });
    await page.waitForTimeout(300);
    expect(fake.searches().length).toBe(before);
    const answered = page.waitForResponse((response) => response.url().includes("/preview/api/v1/discover?q="));
    await box.press("Enter");
    const response = await answered;
    expect(response.status()).toBe(200);
    expect(response.headers()["cache-control"]).toBe("private, no-store");
    const body = await response.json();
    expect(body).toEqual({ account: String(fixture.users[READER]), provider: { name: "Open Library", url: "https://openlibrary.org" }, search: "available", query: "reader sampler", items: expectedItems() });
    await page.getByRole("status").filter({ hasText: "5 results from Open Library for “reader sampler”." }).waitFor();
    expect(page.url()).toBe(`${server.origin}/preview/discover?q=reader+sampler`);

    const sent = fake.searches().slice(before);
    expect(sent.length).toBe(1);
    expect(sent[0]?.path).toBe("/search.json");
    expect(sent[0]?.query).toEqual({ q: ["reader sampler"], limit: ["20"], fields: [FIELDS] });
    expect(Object.keys(sent[0]?.headers ?? {}).sort()).toEqual(["Accept", "Accept-Encoding", "Connection", "User-Agent"]);
    expect(sent[0]?.headers?.["Connection"]).toEqual(["close"]);
    expect(sent[0]?.headers?.["User-Agent"]).toEqual([`Shelfarr/${fixture.serverVersion}`]);
    expect(cases.rails_request).toEqual({ q: "reader sampler", limit: "20", fields: `${FIELDS},subject` });

    const results = page.getByRole("region", { name: "Results from Open Library" });
    const articles = results.getByRole("article");
    expect(await articles.count()).toBe(5);
    const text = articles.filter({ has: page.getByRole("heading", { name: "Reader Text Sampler", level: 3 }) });
    expect(await text.getByText("First published 2021 · 3 editions").count()).toBe(1);
    const copies = text.getByRole("list", { name: "In your library" }).getByRole("link");
    expect(await copies.evaluateAll((links) => links.map((link) => [link.textContent, link.getAttribute("href")]))).toEqual([
      ["Open the ebook of Reader Text Sampler in your library", `/preview/library/${cases.books.text}`],
      ["Open the audiobook of Reader Text Sampler in your library", `/preview/library/${cases.books.audio}`],
    ]);
    const harbor = articles.filter({ has: page.getByRole("heading", { name: "Reader Harbor Panels", level: 3 }) });
    expect(await harbor.getByRole("link", { name: /Open the comic/ }).getAttribute("href")).toBe(`/preview/library/${cases.books.comic}`);
    expect(await harbor.locator("img").count()).toBe(0);
    const waiting = articles.filter({ has: page.getByRole("heading", { name: "Reader Waiting List", level: 3 }) });
    expect(await waiting.getByText("No copy to open in your library").count()).toBe(1);
    expect(await waiting.getByText("Author not listed").count()).toBe(1);
    const source = text.getByRole("link", { name: "View on Open Library for Reader Text Sampler (opens in a new tab)" });
    expect([await source.getAttribute("href"), await source.getAttribute("target"), await source.getAttribute("rel")]).toEqual(["https://openlibrary.org/works/OL900001W", "_blank", "noopener noreferrer"]);
    expect(await page.getByRole("heading", { name: "Café 📚 <b>&amp;</b> \"quoted\"", level: 3 }).count()).toBe(1);
    expect(await page.locator("article b").count()).toBe(0);
    await coversLoaded(page);
    expect(covers.sort()).toEqual(["9000001", "9000004", "9000006"].map((id) => `https://covers.openlibrary.org/b/id/${id}-M.jpg referer=`));
    const body_text = await page.locator("main").innerText();
    expect(body_text).not.toMatch(/requested by|Requested\b|browser member/i);
    expect(await page.getByRole("button", { name: /request/i }).count()).toBe(0);

    await copies.first().click();
    await page.getByRole("heading", { name: "Reader Text Sampler", level: 1 }).waitFor();
    expect(page.url()).toBe(`${server.origin}/preview/library/${cases.books.text}`);
    await page.goBack();
    await page.getByRole("status").filter({ hasText: "5 results from Open Library for “reader sampler”." }).waitFor();
    expect(await page.getByRole("searchbox", { name: "Title or author" }).inputValue()).toBe("reader sampler");
    expect(fake.searches().length).toBe(before + 1);

    await page.waitForTimeout(1100);
    await page.reload();
    await page.getByRole("status").filter({ hasText: "5 results from Open Library for “reader sampler”." }).waitFor();
    expect(fake.searches().length).toBe(before + 2);

    expect(tables(server)).toBe(rows);
    for (const line of server.logs) expect(line).not.toMatch(/reader sampler|reader\+sampler|Sampler|9000001/);
    expect(outside).toEqual([]);
    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("names every failure Open Library can cause, never retries by itself and follows no redirect", async () => {
    const server = await serve();
    const { context, page, seen } = await open(server);
    await openDiscover(page, server.origin);
    const cases: [string, string, string][] = [
      ["empty shelf", "Nothing found for “empty shelf”", "No results from Open Library for “empty shelf”."],
      ["broken answer", "Open Library's answer could not be used", "The search for “broken answer” did not finish."],
      ["garbage answer", "Open Library's answer could not be used", "The search for “garbage answer” did not finish."],
      ["redirect away", "Open Library's answer could not be used", "The search for “redirect away” did not finish."],
      ["huge answer", "Open Library's answer could not be used", "The search for “huge answer” did not finish."],
    ];
    for (const [query, heading, status] of cases) {
      const before = fake.searches().length;
      await page.waitForTimeout(1100);
      await search(page, query);
      await page.getByRole("heading", { name: heading, level: 2 }).waitFor();
      await page.getByRole("status").filter({ hasText: status }).waitFor();
      await page.waitForTimeout(300);
      expect(fake.searches().length).toBe(before + 1);
    }
    expect(fake.journal().filter((entry) => entry.kind === "refused")).toEqual([]);
    expect(await page.locator("main").innerText()).not.toContain("Internal Server Error");

    await page.waitForTimeout(1100);
    await search(page, "slow reading");
    await page.getByRole("status").filter({ hasText: "Searching Open Library for “slow reading”…" }).waitFor();
    await page.getByRole("status").filter({ hasText: "5 results from Open Library for “slow reading”." }).waitFor({ timeout: 10_000 });

    const before = fake.searches().length;
    await page.waitForTimeout(1100);
    await search(page, "limit reached");
    await page.getByRole("heading", { name: "Too many searches right now", level: 2 }).waitFor();
    await page.getByText(/Try again in about 30 seconds\./).waitFor();
    await page.getByRole("button", { name: "Try again" }).click();
    await page.getByRole("heading", { name: "Too many searches right now", level: 2 }).waitFor();
    await search(page, "after the limit");
    await page.getByRole("heading", { name: "Too many searches right now", level: 2 }).waitFor();
    await page.waitForTimeout(300);
    expect(fake.searches().length).toBe(before + 1);
    for (const line of server.logs) expect(line).not.toMatch(/empty shelf|broken|garbage|redirect away|huge answer|slow reading|limit reached|127\.0\.0\.1:9/);
    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen).filter((line) => !/status of (502|429)/.test(line))).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("leaving a running search, or replacing it, cancels the request to Open Library and a late answer never shows", async () => {
    const server = await serve();
    const { context, page } = await open(server);
    await openDiscover(page, server.origin);
    const before = fake.searches().length;
    await search(page, "hang forever");
    await page.getByRole("status").filter({ hasText: "Searching Open Library for “hang forever”…" }).waitFor();
    await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Library" }).click();
    await page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline && !fake.searches().slice(before).some((entry) => entry.cancelled)) await Bun.sleep(100);
    expect(fake.searches().slice(before).map((entry) => [entry.query?.["q"]?.[0], entry.cancelled ?? false])).toEqual([["hang forever", true]]);

    await page.goBack();
    await page.getByRole("heading", { name: "Find", level: 1 }).waitFor();
    await page.waitForTimeout(1100);
    const middle = fake.searches().length;
    await search(page, "slow one");
    await page.getByRole("status").filter({ hasText: "Searching Open Library for “slow one”…" }).waitFor();
    await page.waitForTimeout(1100);
    await search(page, "reader sampler");
    await page.getByRole("status").filter({ hasText: "5 results from Open Library for “reader sampler”." }).waitFor();
    await page.waitForTimeout(2500);
    expect(await page.getByRole("status").innerText()).toBe("5 results from Open Library for “reader sampler”.");
    const journal = fake.searches().slice(middle).map((entry) => [entry.query?.["q"]?.[0], entry.cancelled ?? false]);
    expect(journal).toContainEqual(["slow one", true]);
    expect(journal).toContainEqual(["reader sampler", false]);
    await context.close();
    await server.stop();
  });

  test("follows the Shelfarr metadata settings and the Rails backoff without contacting Open Library or changing them", async () => {
    const server = await serve();
    const { context, page } = await open(server);
    await openDiscover(page, server.origin);
    const before = fake.searches().length;
    const states: [string, string, string][] = [
      ["INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at) VALUES ('open_library_enabled', 'false', 'boolean', 'open_library', '', '2026-11-18', '2026-11-18')", "Open Library is turned off in Shelfarr's settings", "DELETE FROM settings WHERE key = 'open_library_enabled'"],
      ["INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at) VALUES ('metadata_source', 'hardcover', 'string', 'hardcover', '', '2026-11-18', '2026-11-18')", "Shelfarr is set to search a different source", "DELETE FROM settings WHERE key = 'metadata_source'"],
      ["INSERT INTO metadata_provider_statuses (provider, status, rate_limited_until, failure_count, created_at, updated_at) VALUES ('openlibrary', 'rate_limited', '2099-01-01 00:00:00', 1, '2026-11-18', '2026-11-18')", "Open Library is paused for now", "DELETE FROM metadata_provider_statuses WHERE provider = 'openlibrary'"],
    ];
    for (const [setup, heading, undo] of states) {
      server.execute(setup);
      const rows = tables(server);
      await page.goto(`${server.origin}/preview/discover?q=reader+sampler`);
      await page.getByRole("heading", { name: heading, level: 2 }).waitFor();
      expect(await page.getByRole("searchbox").count()).toBe(0);
      expect(tables(server)).toBe(rows);
      server.execute(undo);
    }
    expect(fake.searches().length).toBe(before);
    await context.close();
    await server.stop();
  });

  test("an over-long query in the address is explained and never sent, and a repeated one is rewritten to the one searched", async () => {
    const server = await serve();
    const { context, page } = await open(server);
    const before = fake.searches().length;
    await openDiscover(page, server.origin, `/preview/discover?q=${"a".repeat(201)}`);
    await page.getByText("Use 200 characters or fewer.").waitFor();
    expect(await page.getByRole("searchbox", { name: "Title or author" }).getAttribute("aria-invalid")).toBe("true");
    await page.waitForTimeout(300);
    expect(fake.searches().length).toBe(before);
    await page.goto(`${server.origin}/preview/discover?q=dune&q=reader+sampler`);
    await page.getByRole("status").filter({ hasText: "5 results from Open Library for “reader sampler”." }).waitFor();
    expect(page.url()).toBe(`${server.origin}/preview/discover?q=reader+sampler`);
    expect(fake.searches().slice(before).map((entry) => entry.query?.["q"])).toEqual([["reader sampler"]]);
    await context.close();
    await server.stop();
  });

  test("another tab switching account locks the open results", async () => {
    const server = await serve();
    const { context, page } = await open(server);
    await openDiscover(page, server.origin);
    await search(page, "reader sampler");
    await page.getByRole("heading", { name: "Reader Text Sampler", level: 3 }).waitFor();
    const other = await context.newPage();
    await other.goto(`${server.origin}/preview/library`);
    await other.getByRole("button", { name: "Sign out" }).click();
    await signIn(other, "browser_member", fixture.passwords["browser_member"] ?? "");
    await other.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    await page.bringToFront();
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await page.getByRole("heading", { name: "The signed-in account changed" }).waitFor();
    expect(await page.getByRole("heading", { name: "Reader Text Sampler", level: 3 }).count()).toBe(0);
    await context.close();
    await server.stop();
  });

  test("the keyboard reaches the field, the button and each result's links in reading order", async () => {
    const server = await serve();
    const { context, page } = await open(server);
    await openDiscover(page, server.origin);
    const box = page.getByRole("searchbox", { name: "Title or author" });
    await box.focus();
    await page.keyboard.type("reader sampler");
    await page.keyboard.press("Enter");
    await page.getByRole("heading", { name: "Reader Text Sampler", level: 3 }).waitFor();
    expect(await box.evaluate((element) => element === document.activeElement)).toBe(true);
    const order: string[] = [];
    for (let step = 0; step < 5; step += 1) {
      await page.keyboard.press("Tab");
      order.push(await page.evaluate(() => `${document.activeElement?.tagName}:${document.activeElement?.textContent?.trim()}`));
    }
    expect(order).toEqual([
      "BUTTON:Search",
      "A:Open the ebook of Reader Text Sampler in your library",
      "A:Open the audiobook of Reader Text Sampler in your library",
      "A:View on Open Library for Reader Text Sampler (opens in a new tab)",
      "A:Open the comic of Reader Harbor Panels in your library",
    ]);
    const ring = await page.evaluate(() => {
      const style = getComputedStyle(document.activeElement as Element);
      return { style: style.outlineStyle, width: parseFloat(style.outlineWidth) };
    });
    expect(ring.style).not.toBe("none");
    expect(ring.width).toBeGreaterThanOrEqual(2);
    await context.close();
    await server.stop();
  });
});

const viewports = { desktop: { width: 1280, height: 900 }, phone: { width: 390, height: 844 }, narrow: { width: 320, height: 640 } } as const;

async function audit(page: Page, label: string, zoom: number) {
  if (zoom !== 100) {
    await page.evaluate((percent) => {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(`html { font-size: ${percent}% !important; }`);
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    }, zoom);
  }
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(artifacts.out(), `discover-${label}.png`), fullPage: true });
  await page.evaluate(axe.source);
  const violations = await page.evaluate(async () => {
    const found = await (window as unknown as { axe: { run: (context?: unknown, options?: unknown) => Promise<{ violations: { id: string; impact: string; nodes: { target: string[] }[] }[] }> } }).axe.run(document, { resultTypes: ["violations"] });
    return found.violations.map((violation) => `${violation.id} (${violation.impact}): ${violation.nodes.map((node) => node.target.join(" ")).join(", ")}`);
  });
  expect(violations, label).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), `${label} overflow`).toBeLessThanOrEqual(0);
  const small = await page.evaluate(() =>
    [...document.querySelectorAll<HTMLElement>("main button, main input:not([type=hidden]), main a")]
      .filter((element) => element.offsetParent !== null && !element.closest(".lede"))
      .map((element) => ({ label: element.textContent?.trim() || element.getAttribute("name") || element.tagName, height: element.getBoundingClientRect().height, size: parseFloat(getComputedStyle(element).fontSize), input: element.tagName === "INPUT" }))
      .filter((entry) => entry.height < 44 || (entry.input && entry.size < 16)),
  );
  expect(small, `${label} targets`).toEqual([]);
}

describe("the Discover page renders accessibly", () => {
  let server: RunningServer;
  let off: RunningServer;
  beforeAll(async () => {
    server = await serve();
    off = await serve(false);
  });
  afterAll(async () => {
    await server.stop();
    await off.stop();
  });
  for (const viewport of Object.keys(viewports) as (keyof typeof viewports)[]) {
    for (const scheme of ["light", "dark"] as const) {
      for (const zoom of [100, 200]) {
        if (viewport === "narrow" && zoom === 100) continue;
        test(`${viewport} ${scheme} ${zoom}%`, async () => {
          const { context, page, seen } = await open(server, { colorScheme: scheme, viewport: viewports[viewport] });
          await openDiscover(page, server.origin);
          await audit(page, `${viewport}-${scheme}-${zoom}-empty`, zoom);
          await page.waitForTimeout(1100);
          await search(page, "reader sampler");
          await page.getByRole("heading", { name: "Reader Text Sampler", level: 3 }).waitFor();
          await coversLoaded(page);
          await audit(page, `${viewport}-${scheme}-${zoom}-results`, 100);
          await page.waitForTimeout(1100);
          await search(page, "empty shelf");
          await page.getByRole("heading", { name: "Nothing found for “empty shelf”", level: 2 }).waitFor();
          await audit(page, `${viewport}-${scheme}-${zoom}-nothing`, 100);
          expect(await policyViolations(page)).toEqual([]);
          expect(unexpectedConsole(seen)).toEqual([]);
          await context.close();
          const closed = await open(off, { colorScheme: scheme, viewport: viewports[viewport] });
          await openDiscover(closed.page, off.origin);
          await closed.page.getByRole("heading", { name: "Search is switched off on this server", level: 2 }).waitFor();
          await audit(closed.page, `${viewport}-${scheme}-${zoom}-off`, zoom);
          await closed.context.close();
        });
      }
    }
  }
});
