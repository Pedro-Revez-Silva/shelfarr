import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import type { Browser, Page, Response as PlaywrightResponse, Route } from "playwright-core";
import { copyFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, openAs, policyViolations, signIn, startServer, unexpectedConsole, type RunningServer } from "./harness";

const fixture = loadFixture();
const books = fixture.readerBooks;
const member = fixture.users["browser_member"] ?? 0;
const admin = fixture.users["browser_admin"] ?? 0;
const desktop = { width: 1280, height: 900 };
const phone = { width: 390, height: 844 };
const PAGE_COLORS = [[220, 80, 70], [70, 160, 90], [60, 110, 200], [230, 190, 60], [150, 80, 180], [60, 180, 190], [240, 140, 40], [120, 120, 120], [200, 90, 150], [100, 170, 60]];
const pageColor = (position: number) => PAGE_COLORS[(position - 1) % PAGE_COLORS.length] as number[];
const COMIC_HREFS = ["p%C3%A1gina%201.png", "p%C3%A1gina%202.png", "p%C3%A1gina%203.png", "p%C3%A1gina%2010.png", "%E6%97%A5%E6%9C%AC/%E7%B5%82.png"];

let browser: Browser;
let server: RunningServer;

beforeAll(async () => {
  browser = await launchBrowser();
});

afterAll(async () => {
  await browser.close();
});

beforeEach(async () => {
  server = await startServer({ fixture });
});

afterEach(async () => {
  await server.stop();
});

type Row = { version: number; asset_id: string; client_mutation_id: string; observed_at: string | null; locator: string | null; position_seconds: number | null; updated_at: string };
type PagePlace = { href: string; type: string; locations: { position: number; totalProgression: number; fragments?: string[] } };

function rows(book: number, user = member): Row[] {
  return server.query<Row>("SELECT version, asset_id, client_mutation_id, observed_at, locator, position_seconds, updated_at FROM consumer_progresses WHERE user_id = ? AND book_id = ?", user, book);
}

function only(book: number): Row {
  const found = rows(book);
  expect(found).toHaveLength(1);
  return found[0] as Row;
}

const locatorOf = (row: Row): PagePlace => JSON.parse(row.locator ?? "null");
const railsTime = (value: string | null) => (value === null ? Number.NaN : Date.parse(`${value.replace(" ", "T")}Z`));
const railsStamp = (milliseconds: number) => new Date(milliseconds).toISOString().replace("T", " ").replace("Z", "000");
const pdfPlace = (position: number): PagePlace => ({ href: "document.pdf", type: "application/pdf", locations: { position, totalProgression: (position - 1) / 6, fragments: [`page=${position}`] } });
const comicPlace = (position: number): PagePlace => ({ href: COMIC_HREFS[position - 1] ?? "", type: "image/png", locations: { position, totalProgression: (position - 1) / 5 } });

async function waitForRow(book: number, predicate: (row: Row) => boolean, user = member): Promise<Row> {
  const deadline = Date.now() + 20_000;
  for (;;) {
    const row = rows(book, user)[0];
    if (row && predicate(row)) return row;
    if (Date.now() > deadline) throw new Error(`no progress row matched for book ${book}: ${JSON.stringify(rows(book, user))}`);
    await Bun.sleep(100);
  }
}

async function stays(book: number, expected: Row[], milliseconds = 2500) {
  await Bun.sleep(milliseconds);
  expect(rows(book)).toEqual(expected);
}

function seedPlace(book: number, asset: string, locator: unknown, options: { version?: number; observedAt?: number | null } = {}) {
  const now = railsStamp(Date.now() - 120_000);
  const observed = options.observedAt === null ? null : railsStamp(options.observedAt ?? Date.now() - 60_000);
  server.execute(
    "INSERT INTO consumer_progresses (user_id, book_id, asset_id, locator, position_seconds, version, client_mutation_id, observed_at, created_at, updated_at) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)",
    member, book, asset, JSON.stringify(locator), options.version ?? 1, crypto.randomUUID(), observed, now, now,
  );
}

function otherDevice(book: number, change: { version: number; locator?: unknown; observedAt: number | null }) {
  server.execute(
    "UPDATE consumer_progresses SET version = ?, locator = COALESCE(?, locator), client_mutation_id = ?, observed_at = ?, updated_at = ? WHERE user_id = ? AND book_id = ?",
    change.version, change.locator === undefined ? null : JSON.stringify(change.locator), crypto.randomUUID(), change.observedAt === null ? null : railsStamp(change.observedAt), railsStamp(Date.now()), member, book,
  );
}

async function signedIn(options: { viewport?: { width: number; height: number }; colorScheme?: "light" | "dark" } = {}, username = "browser_member") {
  const opened = await openAs(browser, server, { viewport: desktop, ...options });
  await opened.page.goto(`${server.origin}/preview/library`);
  await signIn(opened.page, username, fixture.passwords[username] ?? "");
  await opened.page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
  return opened;
}

async function readerAssets(page: Page, book: number): Promise<{ id: string; url: string; format: string; reading_order_url?: string }[]> {
  return page.evaluate(
    async ({ book, account }) => {
      const response = await fetch(`/preview/api/v1/library/${book}/reader`, { headers: { Accept: "application/json", "X-Shelfarr-Account": String(account) } });
      return (await response.json()).publication.assets;
    },
    { book, account: member },
  );
}

async function atPage(page: Page, position: number, count: number) {
  await page.locator(".epub-location").filter({ hasText: new RegExp(`^Page ${position} of ${count}$`) }).waitFor({ timeout: 30_000 });
  await page.locator(`.pages-view[data-page="${position}"]`).waitFor({ timeout: 30_000 });
}

async function openPages(page: Page, book: number, position: number, count: number) {
  await page.goto(`${server.origin}/preview/library/${book}/read`);
  await atPage(page, position, count);
  await Bun.sleep(300);
}

async function screenPixel(page: Page, x: number, y: number): Promise<number[]> {
  const shot = await page.screenshot({ clip: { x: Math.round(x) - 2, y: Math.round(y) - 2, width: 4, height: 4 } });
  const decoder = await page.context().newPage();
  try {
    return await decoder.evaluate(async (data) => {
      const image = new Image();
      image.src = `data:image/png;base64,${data}`;
      await image.decode();
      const canvas = document.createElement("canvas");
      canvas.width = image.width;
      canvas.height = image.height;
      const context = canvas.getContext("2d");
      if (!context) return [];
      context.drawImage(image, 0, 0);
      const pixels = context.getImageData(0, 0, image.width, image.height).data;
      const sum = [0, 0, 0];
      for (let index = 0; index < pixels.length; index += 4) for (let channel = 0; channel < 3; channel += 1) sum[channel] = (sum[channel] ?? 0) + (pixels[index + channel] ?? 0);
      return sum.map((value) => Math.round(value / (pixels.length / 4)));
    }, shot.toString("base64"));
  } finally {
    await decoder.close();
  }
}

async function expectPainted(page: Page, color: number[], at: { x: number; y: number }) {
  const deadline = Date.now() + 10_000;
  let last: unknown = null;
  for (;;) {
    const box = await page.locator(".pages-view .consumer-page :is(canvas, img)").first().boundingBox();
    if (box) {
      const pixel = await screenPixel(page, box.x + box.width * at.x, box.y + box.height * at.y);
      last = { box, pixel };
      if (pixel.every((value, index) => Math.abs(value - (color[index] ?? 0)) <= 10)) return;
    }
    if (Date.now() > deadline) throw new Error(`the page is not painted ${JSON.stringify(color)}: ${JSON.stringify(last)}`);
    await Bun.sleep(150);
  }
}

async function pageText(page: Page, name: string): Promise<string[]> {
  const { nodes } = await (await page.context().newCDPSession(page)).send("Accessibility.getFullAXTree");
  const byId = new Map(nodes.map((node) => [node.nodeId, node]));
  const group = nodes.find((node) => !node.ignored && node.role?.value === "group" && node.name?.value === name);
  const spoken: string[] = [];
  const visit = (id: string) => {
    const node = byId.get(id);
    if (!node) return;
    if (!node.ignored && node.role?.value === "StaticText" && typeof node.name?.value === "string") spoken.push(node.name.value);
    for (const child of node.childIds ?? []) visit(child);
  };
  for (const child of group?.childIds ?? []) visit(child);
  return spoken;
}

const PDF_SAMPLE = { x: 0.85, y: 0.55 };
const COMIC_SAMPLE = { x: 0.97, y: 0.5 };

async function blur(page: Page) {
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
}

function offOrigin(page: Page): string[] {
  const outside: string[] = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (!["blob:", "data:", "about:"].includes(url.protocol) && url.origin !== server.origin) outside.push(request.url());
  });
  return outside;
}

async function clean(page: Page, seen: { policy: string[]; console: string[]; page: string[] }) {
  expect(await policyViolations(page)).toEqual([]);
  expect(unexpectedConsole(seen)).toEqual([]);
  expect(seen.page).toEqual([]);
}

describe("the Go online PDF reader", () => {
  test("Details opens a real multipage PDF whose pages, text, buttons, keys and page box save page places dated by the action; reopening, resizing and zoom write nothing", async () => {
    const { context, page, seen } = await signedIn();
    const outside = offOrigin(page);
    await page.goto(`${server.origin}/preview/library/${books.pdf}`);
    const start = page.getByRole("link", { name: /^Start reading Reader Paged Document/ });
    expect(await start.getAttribute("href")).toBe(`/preview/library/${books.pdf}/read`);
    await start.click();
    await page.waitForURL(`**/preview/library/${books.pdf}/read`);
    await atPage(page, 1, 6);
    expect(await page.title()).toBe("Reader Paged Document · Shelfarr");
    await expectPainted(page, pageColor(1), PDF_SAMPLE);
    await page.locator(".pages-view .textLayer").getByText("Page 1 of 6").waitFor();
    expect(await page.getByRole("group", { name: "Page 1 of 6" }).count()).toBe(1);
    expect(await pageText(page, "Page 1 of 6")).toEqual(["Page 1 of 6"]);
    await stays(books.pdf, [], 2000);

    const clicked = Date.now();
    await page.getByRole("button", { name: "Next page" }).click();
    await atPage(page, 2, 6);
    await expectPainted(page, pageColor(2), PDF_SAMPLE);
    const first = await waitForRow(books.pdf, (row) => row.version === 1);
    expect(locatorOf(first)).toEqual(pdfPlace(2));
    expect(railsTime(first.observed_at)).toBeGreaterThanOrEqual(clicked - 50);
    expect(railsTime(first.observed_at)).toBeLessThanOrEqual(railsTime(first.updated_at) - 1000);

    await blur(page);
    await page.keyboard.press("ArrowRight");
    await atPage(page, 3, 6);
    await expectPainted(page, pageColor(3), PDF_SAMPLE);
    const third = await waitForRow(books.pdf, (row) => row.version === 2 && locatorOf(row).locations.position === 3);

    for (let step = 0; step < 4; step += 1) await page.getByRole("button", { name: "Zoom in" }).click();
    await page.locator(".zoom-value").filter({ hasText: "400%" }).waitFor();
    const zoomed = page.getByRole("region", { name: /^Zoomed page/ });
    await zoomed.focus();
    const left = await zoomed.evaluate((element) => element.scrollLeft);
    await page.keyboard.press("ArrowRight");
    await page.waitForFunction((start) => (document.querySelector(".consumer-pages__stage")?.scrollLeft ?? 0) > start, left);
    await atPage(page, 3, 6);
    await page.getByRole("button", { name: "Fit page" }).click();
    await page.locator(".zoom-value").filter({ hasText: "Fit" }).waitFor();
    await stays(books.pdf, [third], 1800);

    await page.getByLabel("Page", { exact: true }).fill("6");
    await page.getByLabel("Page", { exact: true }).press("ArrowLeft");
    await page.getByLabel("Page", { exact: true }).press("Enter");
    await atPage(page, 6, 6);
    await expectPainted(page, pageColor(6), PDF_SAMPLE);
    const last = await waitForRow(books.pdf, (row) => row.version === 3);
    expect(locatorOf(last)).toEqual(pdfPlace(6));
    expect(await page.getByRole("button", { name: "Next page" }).getAttribute("aria-disabled")).toBe("true");
    await page.getByRole("button", { name: "Next page" }).click({ force: true });
    await blur(page);
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("PageDown");

    await page.getByRole("button", { name: "Zoom in" }).click();
    await page.locator(".zoom-value").filter({ hasText: "150%" }).waitFor();
    const region = page.getByRole("region", { name: /^Zoomed page/ });
    await region.focus();
    await page.keyboard.press("ArrowRight");
    await page.getByRole("button", { name: "Zoom in" }).click();
    await page.locator(".zoom-value").filter({ hasText: "225%" }).waitFor();
    await page.getByRole("button", { name: "Fit page" }).click();
    await page.locator(".zoom-value").filter({ hasText: "Fit" }).waitFor();
    expect(await region.count()).toBe(0);
    await page.setViewportSize(phone);
    await Bun.sleep(800);
    await expectPainted(page, pageColor(6), PDF_SAMPLE);
    await page.screenshot({ path: join(artifacts.out(), "pages-pdf-phone.png") });
    await stays(books.pdf, [last], 1500);
    for (const viewport of [desktop, phone]) {
      await page.setViewportSize(viewport);
      await openPages(page, books.pdf, 6, 6);
      await expectPainted(page, pageColor(6), PDF_SAMPLE);
    }
    await page.setViewportSize(desktop);
    await page.screenshot({ path: join(artifacts.out(), "pages-pdf-desktop.png") });
    await stays(books.pdf, [last], 2000);
    expect(outside).toEqual([]);
    await clean(page, seen);
    await context.close();
  });

  test("a PDF the renderer cannot read says so and writes nothing", async () => {
    const { context, page } = await signedIn();
    await page.goto(`${server.origin}/preview/library/${books.broken_pdf}/read`);
    await page.getByRole("alert").filter({ hasText: "This PDF is damaged or isn't a PDF." }).waitFor({ timeout: 30_000 });
    expect(await page.getByRole("button", { name: "Next page" }).isDisabled()).toBe(true);
    await stays(books.broken_pdf, [], 1500);
    await context.close();
  });
});

describe("the Go online comic reader", () => {
  test("a compressed CBZ shows its pictures in natural Unicode order by range reads, saves the Nth page dated by its input, keeps the ends and reopens on the same page", async () => {
    const { context, page, seen } = await signedIn();
    const outside = offOrigin(page);
    const media: { status: number; range: string | null }[] = [];
    page.on("response", (response: PlaywrightResponse) => {
      if (response.url().includes(`/library/${books.comic}/assets/`) && !response.url().endsWith("/reading_order")) media.push({ status: response.status(), range: response.request().headers()["range"] ?? null });
    });
    await page.goto(`${server.origin}/preview/library/${books.comic}`);
    await page.getByRole("link", { name: /^Start reading Reader Harbor Panels/ }).click();
    await atPage(page, 1, 5);
    await expectPainted(page, pageColor(1), COMIC_SAMPLE);
    expect(await page.locator(".pages-view img").getAttribute("alt")).toBe("Page 1 of 5");
    expect(await page.getByRole("button", { name: "Previous page" }).getAttribute("aria-disabled")).toBe("true");
    await page.getByRole("button", { name: "Previous page" }).click({ force: true });
    await blur(page);
    await page.keyboard.press("ArrowLeft");
    await stays(books.comic, [], 2000);

    for (let position = 2; position <= 5; position += 1) {
      const pressed = Date.now();
      if (position % 2 === 0) await page.getByRole("button", { name: "Next page" }).click();
      else {
        await blur(page);
        await page.keyboard.press("ArrowRight");
      }
      await atPage(page, position, 5);
      await expectPainted(page, pageColor(position), COMIC_SAMPLE);
      const saved = await waitForRow(books.comic, (row) => row.version === position - 1);
      expect(locatorOf(saved)).toEqual(comicPlace(position));
      expect(railsTime(saved.observed_at)).toBeGreaterThanOrEqual(pressed - 50);
    }
    const end = only(books.comic);
    await page.getByRole("button", { name: "Next page" }).click({ force: true });
    await stays(books.comic, [end], 2000);
    expect(media.length).toBeGreaterThan(0);
    expect(media.every((entry) => entry.status === 206 && /^bytes=\d+-\d+$/.test(entry.range ?? ""))).toBe(true);

    await page.setViewportSize(phone);
    await openPages(page, books.comic, 5, 5);
    await expectPainted(page, pageColor(5), COMIC_SAMPLE);
    await page.screenshot({ path: join(artifacts.out(), "pages-comic-phone.png") });
    await page.setViewportSize(desktop);
    await openPages(page, books.comic, 5, 5);
    await page.screenshot({ path: join(artifacts.out(), "pages-comic-desktop.png") });
    await stays(books.comic, [end], 1500);
    expect(outside).toEqual([]);
    await clean(page, seen);
    await context.close();
  });

  test("rapid turns save only the page they reach, dated by the last turn", async () => {
    const { context, page } = await signedIn();
    await openPages(page, books.comic, 1, 5);
    await blur(page);
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("ArrowRight");
    const last = Date.now();
    await page.keyboard.press("ArrowRight");
    await atPage(page, 4, 5);
    await expectPainted(page, pageColor(4), COMIC_SAMPLE);
    const saved = await waitForRow(books.comic, (row) => row.version === 1);
    expect(locatorOf(saved)).toEqual(comicPlace(4));
    expect(railsTime(saved.observed_at)).toBeGreaterThanOrEqual(last - 50);
    await stays(books.comic, [saved], 2000);
    await context.close();
  });

  test("damaged and oversized pictures are refused with a message and never saved; a good page after them is", async () => {
    const { context, page } = await signedIn();
    await openPages(page, books.damaged, 1, 4);
    await expectPainted(page, pageColor(1), COMIC_SAMPLE);
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByRole("alert").filter({ hasText: "This page is damaged: its checksum doesn't match." }).waitFor();
    await page.getByText("Page 2 couldn't be shown.").waitFor();
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByRole("alert").filter({ hasText: "This page image is too large to show safely." }).waitFor();
    await stays(books.damaged, [], 2500);
    await page.getByRole("button", { name: "Next page" }).click();
    await atPage(page, 4, 4);
    await expectPainted(page, pageColor(4), COMIC_SAMPLE);
    expect(await page.getByRole("alert").count()).toBe(0);
    const saved = await waitForRow(books.damaged, (row) => row.version === 1);
    expect(locatorOf(saved).locations.position).toBe(4);
    await context.close();
  });

  test("a comic replaced on the server while it is open stops at the next page it reads and saves nothing for the old edition", async () => {
    const source = join(fixture.libraryRoots[1] ?? "", "reader", "Reader Harbor Panels.cbz");
    const copy = join(fixture.libraryRoots[1] ?? "", "reader", `Edition ${process.pid}.cbz`);
    copyFileSync(source, copy);
    try {
      server.execute("INSERT INTO books (title, book_type, file_path, created_at, updated_at) VALUES (?, 2, ?, datetime('now'), datetime('now'))", "Reader Edition Check", copy);
      const [{ id }] = server.query<{ id: number }>("SELECT id FROM books WHERE file_path = ?", copy) as [{ id: number }];
      const { context, page } = await signedIn();
      await openPages(page, id, 1, 5);
      writeFileSync(copy, new Uint8Array([...new Uint8Array(await Bun.file(source).arrayBuffer()), 0]));
      await page.getByLabel("Page", { exact: true }).fill("5");
      await page.getByRole("button", { name: "Go to page" }).click();
      await page.getByRole("alert").filter({ hasText: "This comic changed on the server. Refresh to open the new edition." }).waitFor();
      await stays(id, [], 2500);
      await context.close();
    } finally {
      rmSync(copy, { force: true });
    }
  });

  test("an earlier edition's place opens the first page, says so and is replaced only by a turn", async () => {
    const { context, page } = await signedIn();
    seedPlace(books.comic, "f".repeat(64), comicPlace(3), { version: 2 });
    const stale = only(books.comic);
    await openPages(page, books.comic, 1, 5);
    await page.getByText("Your saved place is in another file or an earlier edition of this book, so this comic opens at its first page.").waitFor();
    await stays(books.comic, [stale], 2000);
    await page.getByRole("button", { name: "Next page" }).click();
    const replaced = await waitForRow(books.comic, (row) => row.version === 3);
    expect(replaced.asset_id).not.toBe("f".repeat(64));
    expect(locatorOf(replaced)).toEqual(comicPlace(2));
    await context.close();
  });

  test("Back from a comic opened by Keep going returns to the filtered, scrolled Library", async () => {
    const { context, page } = await signedIn({ viewport: phone });
    const [asset] = await readerAssets(page, books.comic);
    seedPlace(books.comic, asset?.id ?? "", comicPlace(2), { version: 1 });
    await page.goto(`${server.origin}/preview/library?type=ebook&sort=title`);
    const resume = page.locator(`a.resume-link[href="/preview/library/${books.comic}/read"]`);
    await resume.waitFor();
    await page.locator(".book-card").nth(4).waitFor();
    const linkTop = await resume.evaluate((link) => link.getBoundingClientRect().top + window.scrollY);
    await page.evaluate((top) => window.scrollTo(0, Math.max(240, top - 320)), linkTop);
    await Bun.sleep(300);
    const scrolled = await page.evaluate(() => window.scrollY);
    expect(scrolled).toBeGreaterThan(200);
    expect(await resume.evaluate((link) => link.getBoundingClientRect().bottom <= window.innerHeight && link.getBoundingClientRect().top >= 0)).toBe(true);
    expect(await page.evaluate(() => window.history.state?.shelfarrLibrary?.scrollY ?? null)).toBe(scrolled);
    await resume.click();
    await atPage(page, 2, 5);
    await page.getByRole("link", { name: "Back to the library" }).click();
    await page.waitForURL(/\/preview\/library\?/);
    expect(new URL(page.url()).search).toBe("?type=ebook&sort=title");
    await page.waitForFunction((target) => Math.abs(window.scrollY - target) <= 4, scrolled);
    expect(rows(books.comic)).toHaveLength(1);
    await context.close();
  });
});

describe("saving a page when the network or another device disagree", () => {
  test("an uncertain save is retried only on request with the same mutation and time", async () => {
    const { context, page } = await signedIn();
    await openPages(page, books.pdf, 1, 6);
    const sent: string[] = [];
    let mode: "drop" | "pass" = "drop";
    await page.route("**/preview/api/v1/library/*/progress", async (route: Route) => {
      sent.push(route.request().postData() ?? "");
      if (mode === "drop") await route.abort("failed");
      else await route.continue();
    });
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByText("Couldn't confirm that your place was saved").waitFor();
    await stays(books.pdf, [], 2500);
    expect(sent).toHaveLength(1);
    mode = "pass";
    await page.getByRole("button", { name: "Retry saving" }).click();
    const saved = await waitForRow(books.pdf, (row) => row.version === 1);
    expect(sent).toEqual([sent[0] ?? "", sent[0] ?? ""]);
    expect(saved.client_mutation_id).toBe(JSON.parse(sent[0] ?? "{}").client_mutation_id);
    await context.close();
  });

  test("a later page from another device is offered and shown without saving; an undated one waits for a choice", async () => {
    const { context, page } = await signedIn();
    const [asset] = await readerAssets(page, books.pdf);
    seedPlace(books.pdf, asset?.id ?? "", pdfPlace(2), { version: 1, observedAt: Date.now() - 600_000 });
    await openPages(page, books.pdf, 2, 6);
    await stays(books.pdf, rows(books.pdf), 1500);
    otherDevice(books.pdf, { version: 2, locator: pdfPlace(5), observedAt: Date.now() + 90_000 });
    const remote = only(books.pdf);
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByText("A later place was saved on another device (page 5).").waitFor();
    expect(rows(books.pdf)).toEqual([remote]);
    await page.getByRole("button", { name: "Go to that place" }).click();
    await atPage(page, 5, 6);
    await expectPainted(page, pageColor(5), PDF_SAMPLE);
    await stays(books.pdf, [remote], 2500);

    otherDevice(books.pdf, { version: 3, locator: pdfPlace(1), observedAt: null });
    const undated = only(books.pdf);
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByText("Another device saved a different place (page 1; this device: page 6).").waitFor();
    await stays(books.pdf, [undated], 2000);
    await page.getByRole("button", { name: "Keep this device's place" }).click();
    const kept = await waitForRow(books.pdf, (row) => row.version === 4);
    expect(locatorOf(kept)).toEqual(pdfPlace(6));
    await context.close();
  });

  test("Back after quick turns waits for the slow first save and stores the newest page", async () => {
    const { context, page } = await signedIn();
    await page.goto(`${server.origin}/preview/library/${books.comic}`);
    await page.getByRole("link", { name: /^Start reading Reader Harbor Panels/ }).click();
    await atPage(page, 1, 5);
    let delayed = 0;
    await page.route("**/preview/api/v1/library/*/progress", async (route: Route) => {
      if (delayed++ === 0) await Bun.sleep(2500);
      await route.continue();
    });
    await page.getByRole("button", { name: "Next page" }).click();
    await atPage(page, 2, 5);
    await Bun.sleep(1800);
    await page.getByRole("button", { name: "Next page" }).click();
    await atPage(page, 3, 5);
    await page.getByRole("link", { name: "Back to the book" }).click();
    await page.waitForURL(`**/preview/library/${books.comic}`);
    const saved = only(books.comic);
    expect([saved.version, locatorOf(saved).locations.position]).toEqual([2, 3]);
    await context.close();
  });
});

describe("account and session changes while pages are open", () => {
  test("another tab switching account stops the comic, saves nothing for either account and refuses the old page bytes", async () => {
    const { context, page } = await signedIn();
    await openPages(page, books.comic, 1, 5);
    const [asset] = await readerAssets(page, books.comic);
    const other = await context.newPage();
    await other.goto(`${server.origin}/preview/library`);
    await other.getByRole("button", { name: "Sign out" }).click();
    await signIn(other, "browser_admin", fixture.passwords["browser_admin"] ?? "");
    await other.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    const refused = await other.evaluate(
      async ({ media, order }) => {
        const bytes = await fetch(media, { headers: { Range: "bytes=0-31" } });
        const list = await fetch(order, { headers: { Accept: "application/json", "X-Shelfarr-Account": "1" } });
        return [bytes.status, await bytes.text(), list.status];
      },
      { media: asset?.url ?? "", order: asset?.reading_order_url ?? "" },
    );
    expect(refused).toEqual([401, '{"error":"account_changed"}', 401]);
    await page.getByLabel("Page", { exact: true }).fill("5");
    await page.getByRole("button", { name: "Go to page" }).click();
    await page.getByRole("heading", { name: "The signed-in account changed" }).waitFor();
    await Bun.sleep(2500);
    expect(rows(books.comic, member)).toEqual([]);
    expect(rows(books.comic, admin)).toEqual([]);
    expect(await page.locator(".pages-view").count()).toBe(0);
    await context.close();
  });

  test("a session that ends while a PDF page is being read locks the page and saves nothing", async () => {
    const { context, page } = await signedIn();
    await page.route(`**/preview/api/v1/accounts/*/library/${books.pdf}/assets/*`, async (route: Route) => {
      server.execute("DELETE FROM sessions WHERE user_id = ?", member);
      await route.continue();
    });
    await page.goto(`${server.origin}/preview/library/${books.pdf}/read`);
    await page.getByRole("heading", { name: "Your session ended" }).waitFor({ timeout: 30_000 });
    await Bun.sleep(2000);
    expect(rows(books.pdf)).toEqual([]);
    await context.close();
  });

  test("an ended session stops the PDF instead of saving", async () => {
    const { context, page } = await signedIn();
    await openPages(page, books.pdf, 1, 6);
    server.execute("DELETE FROM sessions WHERE user_id = ?", member);
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByRole("heading", { name: "Your session ended" }).waitFor();
    await Bun.sleep(2000);
    expect(rows(books.pdf)).toEqual([]);
    await context.close();
  });
});

describe("Rails continues the pages Go wrote", () => {
  test("leaves Go-written PDF and comic page rows for the real Rails verifier", async () => {
    const { context, page } = await signedIn();
    await openPages(page, books.pdf, 1, 6);
    await page.getByRole("button", { name: "Next page" }).click();
    await atPage(page, 2, 6);
    const document = await waitForRow(books.pdf, (row) => row.version === 1);
    await openPages(page, books.comic, 1, 5);
    await page.getByRole("button", { name: "Next page" }).click();
    await atPage(page, 2, 5);
    await page.getByRole("button", { name: "Next page" }).click();
    const comic = await waitForRow(books.comic, (row) => row.version === 1 && locatorOf(row).locations.position === 3);
    await context.close();
    const directory = artifacts.out();
    const snapshot = join(directory, "page-rows.sqlite3");
    rmSync(snapshot, { force: true });
    server.execute("VACUUM INTO ?", snapshot);
    writeFileSync(join(directory, "page-rows.json"), JSON.stringify({ user_id: member, rows: { [books.pdf]: document, [books.comic]: comic } }, null, 2));
  });
});
