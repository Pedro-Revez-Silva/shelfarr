import { afterEach, beforeAll, afterAll, beforeEach, describe, expect, test } from "bun:test";
import type { Browser, Page, Request, Route } from "playwright-core";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, openAs, policyViolations, signIn, startServer, unexpectedConsole, type RunningServer } from "./harness";

const fixture = loadFixture();
const books = fixture.readerBooks;
const member = fixture.users["browser_member"] ?? 0;
const admin = fixture.users["browser_admin"] ?? 0;
const desktop = { width: 1280, height: 900 };
const phone = { width: 390, height: 844 };
const COVER = [15, 95, 85];
const PAGE_COLORS = [[220, 80, 70], [70, 160, 90], [60, 110, 200], [230, 190, 60], [150, 80, 180], [60, 180, 190], [240, 140, 40], [120, 120, 120], [200, 90, 150], [100, 170, 60]];
const pageColor = (position: number) => PAGE_COLORS[(position - 1) % PAGE_COLORS.length] as number[];

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

function rows(book: number, user = member): Row[] {
  return server.query<Row>("SELECT version, asset_id, client_mutation_id, observed_at, locator, position_seconds, updated_at FROM consumer_progresses WHERE user_id = ? AND book_id = ?", user, book);
}

function only(book: number, user = member): Row {
  const found = rows(book, user);
  expect(found).toHaveLength(1);
  return found[0] as Row;
}

type SavedLocator = { href: string; type: string; locations: { cfi?: string; progression?: number; totalProgression?: number } };

function locatorOf(row: Row): SavedLocator {
  return JSON.parse(row.locator ?? "null");
}

function railsTime(value: string | null): number {
  return value === null ? Number.NaN : Date.parse(`${value.replace(" ", "T")}Z`);
}

function railsStamp(milliseconds: number): string {
  return new Date(milliseconds).toISOString().replace("T", " ").replace("Z", "000");
}

async function waitForRow(book: number, predicate: (row: Row) => boolean, user = member): Promise<Row> {
  const deadline = Date.now() + 20_000;
  for (;;) {
    const row = rows(book, user)[0];
    if (row && predicate(row)) return row;
    if (Date.now() > deadline) throw new Error(`no progress row matched for book ${book}: ${JSON.stringify(rows(book, user))}`);
    await Bun.sleep(100);
  }
}

async function stays(book: number, expected: Row[], milliseconds = 2500, user = member) {
  await Bun.sleep(milliseconds);
  expect(rows(book, user)).toEqual(expected);
}

function offOrigin(page: Page): { fetched: string[]; blocked: string[] } {
  const seen = { fetched: [] as string[], blocked: [] as string[] };
  const outside = (request: Request) => {
    const url = new URL(request.url());
    return !["blob:", "data:", "about:"].includes(url.protocol) && url.origin !== server.origin;
  };
  page.on("requestfinished", (request: Request) => {
    if (outside(request)) seen.fetched.push(request.url());
  });
  page.on("requestfailed", (request: Request) => {
    if (!outside(request)) return;
    if (request.failure()?.errorText === "csp") seen.blocked.push(request.url());
    else seen.fetched.push(`${request.url()} (${request.failure()?.errorText})`);
  });
  return seen;
}

async function signedIn(options: { viewport?: { width: number; height: number }; colorScheme?: "light" | "dark" } = {}, username = "browser_member") {
  const opened = await openAs(browser, server, { viewport: desktop, ...options });
  await opened.page.goto(`${server.origin}/preview/library`);
  await signIn(opened.page, username, fixture.passwords[username] ?? "");
  await opened.page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
  return opened;
}

async function location(page: Page): Promise<string> {
  return (await page.locator(".epub-location").innerText()).trim();
}

async function openReader(page: Page, book: number) {
  await page.goto(`${server.origin}/preview/library/${book}/read`);
  await settled(page);
}

async function settled(page: Page) {
  await page.locator(".epub-location").filter({ hasText: /^Page \d+ of \d+ · Chapter \d+$/ }).waitFor({ timeout: 30_000 });
  await Bun.sleep(300);
}

async function changed(page: Page, before: string): Promise<string> {
  await page.waitForFunction((previous) => {
    const text = document.querySelector(".epub-location")?.textContent?.trim() ?? "";
    return text !== previous && /^Page \d+ of \d+ · Chapter \d+$/.test(text);
  }, before);
  await Bun.sleep(250);
  return location(page);
}

async function blur(page: Page) {
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
}

async function readerAsset(page: Page, book: number): Promise<{ id: string; url: string }[]> {
  return page.evaluate(
    async ({ book, account }) => {
      const response = await fetch(`/preview/api/v1/library/${book}/reader`, { headers: { Accept: "application/json", "X-Shelfarr-Account": String(account) } });
      const body = await response.json();
      return body.publication.assets.map((asset: { id: string; url: string }) => ({ id: asset.id, url: asset.url }));
    },
    { book, account: member },
  );
}

function seedPlace(book: number, asset: string, locator: unknown, options: { version?: number; observedAt?: number | null; mutation?: string; user?: number } = {}) {
  const now = railsStamp(Date.now() - 120_000);
  const observed = options.observedAt === null ? null : railsStamp(options.observedAt ?? Date.now() - 60_000);
  server.execute(
    "INSERT INTO consumer_progresses (user_id, book_id, asset_id, locator, position_seconds, version, client_mutation_id, observed_at, created_at, updated_at) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)",
    options.user ?? member, book, asset, JSON.stringify(locator), options.version ?? 1, options.mutation ?? crypto.randomUUID(), observed, now, now,
  );
}

function otherDevice(book: number, change: { version: number; locator?: unknown; observedAt: number | null; asset?: string }) {
  const observed = change.observedAt === null ? null : railsStamp(change.observedAt);
  server.execute(
    "UPDATE consumer_progresses SET version = ?, locator = COALESCE(?, locator), asset_id = COALESCE(?, asset_id), client_mutation_id = ?, observed_at = ?, updated_at = ? WHERE user_id = ? AND book_id = ?",
    change.version, change.locator === undefined ? null : JSON.stringify(change.locator), change.asset ?? null, crypto.randomUUID(), observed, railsStamp(Date.now()), member, book,
  );
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

async function shownPicture(page: Page): Promise<{ label: string; x: number; y: number } | null> {
  const frame = page.frameLocator(".epub-viewport iframe");
  const box = await page.locator(".epub-viewport").boundingBox();
  const frameBox = await page.locator(".epub-viewport iframe").first().boundingBox();
  if (!box || !frameBox) return null;
  const pictures = await frame.locator("img, image").evaluateAll((nodes) =>
    nodes.map((node) => {
      const rect = node.getBoundingClientRect();
      return { label: node.getAttribute("alt") ?? "cover", left: rect.left, top: rect.top, width: rect.width, height: rect.height };
    }),
  );
  const visible = pictures
    .map((picture) => ({ ...picture, x: frameBox.x + picture.left, y: frameBox.y + picture.top }))
    .filter((picture) => picture.width * picture.height > 400 && picture.x + picture.width > box.x + 2 && picture.x < box.x + box.width - 2);
  if (visible.length !== 1) return null;
  const picture = visible[0];
  if (!picture) return null;
  return { label: picture.label, x: Math.max(box.x, picture.x) + Math.min(picture.width, box.width) * 0.18, y: picture.y + picture.height * 0.5 };
}

async function expectPicture(page: Page, label: string, color: number[]) {
  const deadline = Date.now() + 10_000;
  let last: unknown = null;
  for (;;) {
    const picture = await shownPicture(page);
    if (picture && picture.label === label) {
      const pixel = await screenPixel(page, picture.x, picture.y);
      last = { picture, pixel };
      if (pixel.every((value, index) => Math.abs(value - (color[index] ?? 0)) <= 12)) return;
    } else last = picture;
    if (Date.now() > deadline) throw new Error(`${label} is not painted: ${JSON.stringify(last)}`);
    await Bun.sleep(200);
  }
}

async function clean(page: Page, seen: { policy: string[]; console: string[]; page: string[] }) {
  expect(await policyViolations(page)).toEqual([]);
  expect(unexpectedConsole(seen)).toEqual([]);
  expect(seen.page).toEqual([]);
}

describe("the Go online EPUB reader", () => {
  test("Details opens a real multi-chapter EPUB without writing, inside a scoped policy that runs no book script", async () => {
    const { context, page, seen } = await signedIn();
    const outside = offOrigin(page);
    await page.goto(`${server.origin}/preview/library/${books.text}`);
    const start = page.getByRole("link", { name: /^Start reading Reader Text Sampler/ });
    expect(await start.getAttribute("href")).toBe(`/preview/library/${books.text}/read`);
    await start.click();
    await page.waitForURL(`**/preview/library/${books.text}/read`);
    await page.locator(".epub-location").filter({ hasText: /^Page 1 of \d+ · Chapter 1$/ }).waitFor({ timeout: 30_000 });
    expect(await page.title()).toBe("Reader Text Sampler · Shelfarr");
    expect(await page.locator("main").count()).toBe(1);
    expect(await page.locator(".epub-viewport iframe").getAttribute("title")).toBe("Book text");
    const frame = page.frameLocator(".epub-viewport iframe");
    await frame.getByRole("heading", { name: "The Lantern Ledger" }).waitFor();
    expect(await page.getByLabel("Chapter").locator("option").allInnerTexts()).toEqual(["The Lantern Ledger", "Harbor Copper", "Willow Summit", "The ending"]);
    await stays(books.text, [], 2000);
    await page.getByLabel("Chapter").selectOption({ label: "Harbor Copper" });
    await frame.getByText("An outside address must not open from the book").waitFor();
    await waitForRow(books.text, (row) => row.version === 1);
    expect(await frame.locator("script, iframe, form, input, [onclick], [onerror]").count()).toBe(0);
    expect(await frame.locator('a[href^="https:"], a[href^="javascript:"]').count()).toBe(0);
    await frame.getByText("A paragraph with a click handler.").click();
    await frame.getByRole("link", { name: "Jump to the ending" }).click();
    await page.locator(".epub-location").filter({ hasText: /^Page ([2-9]|\d\d+) of \d+ · Chapter 3$/ }).waitFor();
    await frame.getByText("The ending of the sampler.").waitFor();
    const jumped = await waitForRow(books.text, (row) => row.version === 2);
    expect(locatorOf(jumped).href).toBe("OEBPS/three.xhtml");
    expect(await page.evaluate(() => (window as unknown as { __bookScriptRan?: unknown }).__bookScriptRan ?? null)).toBeNull();
    expect(page.url()).toBe(`${server.origin}/preview/library/${books.text}/read`);
    expect(outside).toEqual({ fetched: [], blocked: ["https://evil.test/track.png"] });
    await page.screenshot({ path: join(artifacts.out(), "reader-text-hostile-chapter.png") });
    const refused = await policyViolations(page);
    expect(refused.length).toBeGreaterThan(0);
    expect(new Set(refused)).toEqual(new Set(["script-src-attr inline"]));
    const blockedHostileContent = [
      /^error: Executing inline event handler violates the following Content Security Policy directive 'script-src 'self''\..*The action has been blocked\.$/,
      /^error: Loading the image 'https:\/\/evil\.test\/track\.png' violates the following Content Security Policy directive: "img-src data: blob:"\. The action has been blocked\.$/,
      /^error: Blocked script execution in 'about:srcdoc' because the document's frame is sandboxed and the 'allow-scripts' permission is not set\.$/,
    ];
    const reported = unexpectedConsole(seen);
    expect(reported.filter((line) => !blockedHostileContent.some((pattern) => pattern.test(line)))).toEqual([]);
    expect(reported.some((line) => blockedHostileContent[1]?.test(line))).toBe(true);
    expect(seen.page).toEqual([]);
    await context.close();
  });

  test("turns by button, key and chapter save the place at the time of the action; reopening, resizing and text size write nothing", async () => {
    const { context, page, seen } = await signedIn();
    await openReader(page, books.text);
    const first = await location(page);
    expect(first).toMatch(/^Page 1 of \d+ · Chapter 1$/);
    const clicked = Date.now();
    await page.getByRole("button", { name: "Next page" }).click();
    const second = await changed(page, first);
    expect(second).toMatch(/^Page 2 of \d+ · Chapter 1$/);
    const saved = await waitForRow(books.text, (row) => row.version === 1);
    const written = Date.now();
    const placed = locatorOf(saved);
    expect(placed.href).toBe("OEBPS/one.xhtml");
    expect(placed.type).toBe("application/xhtml+xml");
    expect(placed.locations.cfi).toMatch(/^epubcfi\(\/6\/2!/);
    expect(placed.locations.progression).toBeGreaterThan(0);
    expect(railsTime(saved.observed_at)).toBeGreaterThanOrEqual(clicked - 50);
    expect(railsTime(saved.observed_at)).toBeLessThanOrEqual(written);
    expect(railsTime(saved.updated_at) - railsTime(saved.observed_at)).toBeGreaterThanOrEqual(1000);

    await blur(page);
    await page.keyboard.press("ArrowRight");
    const third = await changed(page, second);
    expect(third).toMatch(/^Page 3 of \d+ · Chapter 1$/);
    const keyed = await waitForRow(books.text, (row) => row.version === 2);
    expect(locatorOf(keyed).locations.cfi).not.toBe(placed.locations.cfi);
    await page.frameLocator(".epub-viewport iframe").locator("body").press("ArrowLeft");
    expect(await changed(page, third)).toBe(second);
    const back = await waitForRow(books.text, (row) => row.version === 3);
    await page.getByRole("button", { name: "Previous page" }).focus();
    await page.keyboard.press("Enter");
    expect(await changed(page, second)).toBe(first);
    const fourth = await waitForRow(books.text, (row) => row.version === 4);
    expect(locatorOf(fourth).locations.progression).toBe(0);
    expect(fourth.client_mutation_id).not.toBe(back.client_mutation_id);
    await stays(books.text, [fourth], 2500);

    await page.getByRole("button", { name: "Next page" }).focus();
    await page.keyboard.press(" ");
    await changed(page, first);
    const reading = await waitForRow(books.text, (row) => row.version === 5);
    const place = await location(page);
    await page.reload();
    await settled(page);
    expect(await location(page)).toBe(place);
    await page.setViewportSize({ width: 900, height: 760 });
    await Bun.sleep(1200);
    await page.setViewportSize(desktop);
    await Bun.sleep(1200);
    expect(await location(page)).toBe(place);
    await page.getByRole("button", { name: "Larger", exact: true }).click();
    await page.getByText("115%").waitFor();
    await page.getByRole("button", { name: "Smaller", exact: true }).click();
    await page.getByText("105%").waitFor();
    await page.getByLabel("Chapter").focus();
    await stays(books.text, [reading], 2500);

    await page.getByLabel("Chapter").selectOption({ label: "Willow Summit" });
    await page.frameLocator(".epub-viewport iframe").getByRole("heading", { name: "Willow Summit" }).waitFor();
    const chapter = await waitForRow(books.text, (row) => row.version === 6);
    expect(locatorOf(chapter).href).toBe("OEBPS/three.xhtml");
    expect(await location(page)).toMatch(/^Page 1 of \d+ · Chapter 3$/);
    await page.getByLabel("Chapter").selectOption({ label: "The ending" });
    await page.locator(".epub-location").filter({ hasText: /^Page ([2-9]|\d\d+) of \d+ · Chapter 3$/ }).waitFor();
    const ending = page.frameLocator(".epub-viewport iframe").getByText("The ending of the sampler.");
    const shown = await ending.boundingBox();
    const stage = await page.locator(".epub-viewport").boundingBox();
    expect(shown !== null && stage !== null && shown.x >= stage.x && shown.x + shown.width <= stage.x + stage.width + 1).toBe(true);
    await waitForRow(books.text, (row) => row.version === 7);
    await clean(page, seen);
    await context.close();
  });

  test("Back returns to the details and the Library with its filters and scroll position", async () => {
    const { context, page } = await signedIn({ viewport: phone });
    await page.goto(`${server.origin}/preview/library?q=Reader&type=ebook&sort=title`);
    await page.locator(".book-card").nth(2).waitFor();
    await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    await Bun.sleep(300);
    const scrolled = await page.evaluate(() => window.scrollY);
    expect(scrolled).toBeGreaterThan(200);
    await page.getByRole("link", { name: "Reader Text Sampler", exact: true }).click();
    await page.getByRole("heading", { level: 1, name: "Reader Text Sampler" }).waitFor();
    await page.getByRole("link", { name: /^Start reading Reader Text Sampler/ }).click();
    await settled(page);
    await page.getByRole("link", { name: "Back to the book" }).click();
    await page.waitForURL(`**/preview/library/${books.text}`);
    await page.getByRole("heading", { level: 1, name: "Reader Text Sampler" }).waitFor();
    await page.goBack();
    await page.waitForURL(/q=Reader/);
    expect(new URL(page.url()).search).toBe("?q=Reader&type=ebook&sort=title");
    await page.locator(".book-card").nth(2).waitFor();
    await page.waitForFunction((target) => Math.abs(window.scrollY - target) <= 4, scrolled);
    expect(await page.getByRole("searchbox", { name: "Search your library" }).inputValue()).toBe("Reader");
    await page.goForward();
    await page.getByRole("heading", { level: 1, name: "Reader Text Sampler" }).waitFor();
    await page.goForward();
    await settled(page);
    expect(page.url()).toBe(`${server.origin}/preview/library/${books.text}/read`);
    expect(rows(books.text)).toEqual([]);
    await context.close();
  });

  test("an image-only manga EPUB paints its pictures, saves a distinct place per page, restores another app's chapter fraction and reopens on the same picture", async () => {
    const { context, page, seen } = await signedIn();
    await page.goto(`${server.origin}/preview/library`);
    const [asset] = await readerAsset(page, books.manga);
    const native = { href: "index.html", type: "application/xhtml+xml", locations: { progression: 0.5, position: 3, totalProgression: 0.75 } };
    seedPlace(books.manga, asset?.id ?? "", native, { version: 1 });
    const seeded = only(books.manga);
    for (const viewport of [desktop, phone]) {
      await page.setViewportSize(viewport);
      await openReader(page, books.manga);
      expect(await location(page)).toMatch(/^Page 7 of 12 · Chapter 2$/);
      await expectPicture(page, "Image 7", pageColor(7));
    }
    expect(rows(books.manga)).toEqual([seeded]);

    await page.setViewportSize(desktop);
    await page.getByLabel("Chapter").selectOption({ label: "Start" });
    await page.locator(".epub-location").filter({ hasText: /^Page 1 of 1 · Chapter 1$/ }).waitFor();
    await expectPicture(page, "cover", COVER);
    const cover = await waitForRow(books.manga, (row) => row.version === 2);
    expect(locatorOf(cover).href).toBe("titlepage.xhtml");
    await blur(page);
    const cfis = new Set<string>();
    for (let number = 1; number <= 5; number += 1) {
      const before = await location(page);
      await page.keyboard.press("ArrowRight");
      expect(await changed(page, before)).toBe(`Page ${number} of 12 · Chapter 2`);
      await expectPicture(page, `Image ${number}`, pageColor(number));
      const saved = await waitForRow(books.manga, (row) => row.version === 2 + number);
      expect(locatorOf(saved).href).toBe("index.html");
      expect(locatorOf(saved).locations.progression).toBeCloseTo((number - 1) / 12, 6);
      cfis.add(locatorOf(saved).locations.cfi ?? "");
    }
    expect(cfis.size).toBe(5);
    await page.keyboard.press("ArrowLeft");
    await page.locator(".epub-location").filter({ hasText: /^Page 4 of 12 · Chapter 2$/ }).waitFor();
    await expectPicture(page, "Image 4", pageColor(4));
    const saved = await waitForRow(books.manga, (row) => row.version === 8);
    expect(locatorOf(saved).locations.progression).toBe(3 / 12);
    await page.screenshot({ path: join(artifacts.out(), "reader-manga-page-desktop.png") });
    await page.setViewportSize(phone);
    await Bun.sleep(1500);
    await expectPicture(page, "Image 4", pageColor(4));
    for (const viewport of [desktop, phone]) {
      await page.setViewportSize(viewport);
      await openReader(page, books.manga);
      expect(await location(page)).toBe("Page 4 of 12 · Chapter 2");
      await expectPicture(page, "Image 4", pageColor(4));
    }
    await page.screenshot({ path: join(artifacts.out(), "reader-manga-reopened-phone.png") });
    await stays(books.manga, [saved], 1500);
    await clean(page, seen);
    await context.close();
  });

  test("a page of text beside a picture keeps a text place through saving, reopening and resizing", async () => {
    const { context, page, seen } = await signedIn();
    await openReader(page, books.mixed);
    await page.getByLabel("Chapter").selectOption({ label: "Words and a picture" });
    await page.frameLocator(".epub-viewport iframe").getByRole("heading", { name: "Words and a picture" }).waitFor();
    let picture = await shownPicture(page);
    for (let turn = 0; turn < 30 && !picture; turn += 1) {
      const before = await location(page);
      await page.getByRole("button", { name: "Next page" }).click();
      await changed(page, before);
      picture = await shownPicture(page);
    }
    expect(picture?.label).toBe("A generated picture");
    await expectPicture(page, "A generated picture", [60, 110, 200]);
    const place = await location(page);
    await Bun.sleep(2500);
    const settledRow = only(books.mixed);
    expect(locatorOf(settledRow).href).toBe("OEBPS/picture.xhtml");
    expect(locatorOf(settledRow).locations.cfi).toMatch(/:\d+\)$/);
    await openReader(page, books.mixed);
    expect(await location(page)).toBe(place);
    expect((await shownPicture(page))?.label).toBe("A generated picture");
    await page.setViewportSize({ width: 1100, height: 900 });
    await Bun.sleep(1500);
    expect(rows(books.mixed)).toEqual([settledRow]);
    await page.screenshot({ path: join(artifacts.out(), "reader-mixed-picture-page.png") });
    await clean(page, seen);
    await context.close();
  });

  test("Back from a reader opened by Keep going returns to the filtered, scrolled Library", async () => {
    const { context, page } = await signedIn({ viewport: phone });
    await page.goto(`${server.origin}/preview/library`);
    const [asset] = await readerAsset(page, books.text);
    seedPlace(books.text, asset?.id ?? "", { href: "OEBPS/two.xhtml", type: "application/xhtml+xml", locations: { progression: 0.2, totalProgression: 0.4 } }, { version: 1 });
    await page.goto(`${server.origin}/preview/library?type=ebook&sort=title`);
    const resume = page.locator(`a.resume-link[href="/preview/library/${books.text}/read"]`);
    await resume.waitFor();
    await page.locator(".book-card").nth(4).scrollIntoViewIfNeeded();
    await Bun.sleep(300);
    const scrolled = await page.evaluate(() => window.scrollY);
    expect(scrolled).toBeGreaterThan(200);
    await resume.click();
    await settled(page);
    await page.getByRole("link", { name: "Back to the library" }).click();
    await page.waitForURL(/\/preview\/library\?/);
    expect(new URL(page.url()).search).toBe("?type=ebook&sort=title");
    await page.waitForFunction((target) => Math.abs(window.scrollY - target) <= 4, scrolled);
    await context.close();
  });

  test("an older place from a file that is gone opens the EPUB at its beginning, says so and is replaced only by a turn", async () => {
    const { context, page } = await signedIn();
    seedPlace(books.text, "f".repeat(64), { href: "OEBPS/three.xhtml", type: "application/xhtml+xml", locations: { progression: 0.5, totalProgression: 0.9 } }, { version: 3 });
    const stale = only(books.text);
    await openReader(page, books.text);
    expect(await location(page)).toMatch(/^Page 1 of \d+ · Chapter 1$/);
    await page.getByText("Your saved place is in another file or an earlier edition of this book").waitFor();
    await stays(books.text, [stale], 2000);
    await page.getByRole("button", { name: "Next page" }).click();
    const replaced = await waitForRow(books.text, (row) => row.version === 4);
    expect(replaced.asset_id).not.toBe("f".repeat(64));
    await context.close();
  });

  test("manual reading status stays independent of saved places", async () => {
    const { context, page } = await signedIn();
    await page.goto(`${server.origin}/preview/library/${books.text}`);
    await page.getByLabel("Reading status").selectOption("finished");
    await page.getByRole("button", { name: "Save status" }).click();
    await page.getByText(/Saved\./).waitFor();
    const status = server.query("SELECT status, updated_at FROM consumer_reading_states WHERE user_id = ? AND book_id = ?", member, books.text);
    expect(status).toHaveLength(1);
    await page.getByRole("link", { name: /^Read again Reader Text Sampler/ }).click();
    await settled(page);
    await page.getByRole("button", { name: "Next page" }).click();
    await waitForRow(books.text, (row) => row.version === 1);
    expect(server.query("SELECT status, updated_at FROM consumer_reading_states WHERE user_id = ? AND book_id = ?", member, books.text)).toEqual(status);
    await page.getByRole("link", { name: "Back to the book" }).click();
    await page.getByRole("heading", { level: 1, name: "Reader Text Sampler" }).waitFor();
    expect(await page.getByLabel("Reading status").inputValue()).toBe("finished");
    await context.close();
  });
});

describe("saving a place when the network, the token or another device disagree", () => {
  test("a refused security token is shown, nothing is resent by itself, and Retry sends the same mutation and time", async () => {
    const { context, page } = await signedIn();
    await openReader(page, books.text);
    const sent: Record<string, unknown>[] = [];
    let forged = true;
    await page.route("**/preview/api/v1/library/*/progress", async (route: Route) => {
      const request = route.request();
      sent.push(JSON.parse(request.postData() ?? "{}"));
      if (forged) {
        forged = false;
        await route.continue({ headers: { ...request.headers(), "x-csrf-token": "v1.s.forged" } });
      } else await route.continue();
    });
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByText("security check expired").waitFor();
    await stays(books.text, [], 3000);
    expect(sent).toHaveLength(1);
    await page.getByRole("button", { name: "Retry saving" }).click();
    const saved = await waitForRow(books.text, (row) => row.version === 1);
    expect(sent).toHaveLength(2);
    expect(sent[1]).toEqual(sent[0]);
    expect(saved.client_mutation_id).toBe(String(sent[0]?.["client_mutation_id"]));
    expect(railsTime(saved.observed_at)).toBe(Date.parse(String(sent[0]?.["observed_at"])));
    await page.getByText("Your place is saved to your account.").waitFor();
    await context.close();
  });

  test("Back after two quick turns waits for the slow first save and stores the newest place; reloading while unsaved warns first", async () => {
    const { context, page } = await signedIn();
    await page.goto(`${server.origin}/preview/library/${books.text}`);
    await page.getByRole("link", { name: /^Start reading Reader Text Sampler/ }).click();
    await settled(page);
    let delayed = 0;
    await page.route("**/preview/api/v1/library/*/progress", async (route: Route) => {
      if (delayed++ === 0) await Bun.sleep(2500);
      await route.continue();
    });
    const first = await location(page);
    await page.getByRole("button", { name: "Next page" }).click();
    const second = await changed(page, first);
    await Bun.sleep(1800);
    await page.getByRole("button", { name: "Next page" }).click();
    const third = await changed(page, second);
    const dialogs: string[] = [];
    page.on("dialog", (dialog) => {
      dialogs.push(dialog.type());
      void dialog.dismiss();
    });
    await page.reload().catch(() => undefined);
    expect(dialogs).toEqual(["beforeunload"]);
    expect(await location(page)).toBe(third);
    await page.getByRole("link", { name: "Back to the book" }).click();
    await page.waitForURL(`**/preview/library/${books.text}`);
    const saved = only(books.text);
    expect(saved.version).toBe(2);
    expect(third).toMatch(/^Page 3 of/);
    expect(locatorOf(saved).locations.progression).toBeCloseTo(2 / Number((third.match(/of (\d+)/) ?? [])[1] ?? 1), 6);
    await context.close();
  });

  test("an answer lost after the server committed is retried only on request and does not save twice", async () => {
    const { context, page } = await signedIn();
    await openReader(page, books.text);
    const sent: string[] = [];
    let mode: "drop-before" | "drop-after" | "pass" = "drop-before";
    await page.route("**/preview/api/v1/library/*/progress", async (route: Route) => {
      sent.push(route.request().postData() ?? "");
      if (mode === "drop-before") await route.abort("failed");
      else if (mode === "drop-after") {
        await route.fetch();
        await route.abort("failed");
      } else await route.continue();
    });
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByText("Couldn't confirm that your place was saved").waitFor();
    await stays(books.text, [], 3000);
    expect(sent).toHaveLength(1);
    mode = "drop-after";
    await page.getByRole("button", { name: "Retry saving" }).click();
    const committed = await waitForRow(books.text, (row) => row.version === 1);
    await page.getByText("Couldn't confirm that your place was saved").waitFor();
    expect(sent).toEqual([sent[0] ?? "", sent[0] ?? ""]);
    mode = "pass";
    await page.getByRole("button", { name: "Retry saving" }).click();
    await page.getByText("Your place is saved to your account.").waitFor();
    expect(sent).toEqual([sent[0] ?? "", sent[0] ?? "", sent[0] ?? ""]);
    expect(rows(books.text)).toEqual([committed]);
    await context.close();
  });

  test("a later place from another device is offered, not overwritten; an earlier one is rebased; an undated one waits for a choice", async () => {
    const { context, page } = await signedIn();
    await page.goto(`${server.origin}/preview/library`);
    const [asset] = await readerAsset(page, books.text);
    const opening = { href: "OEBPS/one.xhtml", type: "application/xhtml+xml", locations: { progression: 0, totalProgression: 0, cfi: "epubcfi(/6/4!/4/2/1:0)" } };
    seedPlace(books.text, asset?.id ?? "", opening, { version: 1, observedAt: Date.now() - 600_000 });
    await openReader(page, books.text);
    const later = { href: "OEBPS/three.xhtml", type: "application/xhtml+xml", locations: { progression: 0.6, totalProgression: 0.67, cfi: null } };
    otherDevice(books.text, { version: 2, locator: later, observedAt: Date.now() + 90_000 });
    const remote = only(books.text);
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByText("A later place was saved on another device (67% through).").waitFor();
    expect(rows(books.text)).toEqual([remote]);
    await page.getByRole("button", { name: "Go to that place" }).click();
    await page.locator(".epub-location").filter({ hasText: /^Page ([2-9]|\d\d+) of \d+ · Chapter 3$/ }).waitFor();
    await stays(books.text, [remote], 2500);

    otherDevice(books.text, { version: 3, observedAt: Date.now() - 1000 });
    await page.getByRole("button", { name: "Previous page" }).click();
    const rebased = await waitForRow(books.text, (row) => row.version === 4);
    expect(locatorOf(rebased).href).toBe("OEBPS/three.xhtml");
    expect(locatorOf(rebased).locations.progression ?? 1).toBeLessThan(0.6);

    otherDevice(books.text, { version: 5, locator: opening, observedAt: null });
    const undated = only(books.text);
    await page.getByRole("button", { name: "Previous page" }).click();
    await page.getByText(/Another device saved a different place \(0% through; this device: \d+% through\)/).waitFor();
    await stays(books.text, [undated], 2000);
    const chosen = Date.now();
    await page.getByRole("button", { name: "Keep this device's place" }).click();
    const kept = await waitForRow(books.text, (row) => row.version === 6);
    expect(locatorOf(kept).href).toBe("OEBPS/three.xhtml");
    expect(railsTime(kept.observed_at)).toBeGreaterThanOrEqual(chosen - 50);
    await context.close();
  });
});

describe("account and session changes", () => {
  test("a reader left open after another tab switches account stops, saves nothing for either account and cannot fetch the old media", async () => {
    const { context, page } = await signedIn();
    await openReader(page, books.text);
    const [asset] = await readerAsset(page, books.text);
    const other = await context.newPage();
    await other.goto(`${server.origin}/preview/library`);
    await other.getByRole("button", { name: "Sign out" }).click();
    await signIn(other, "browser_admin", fixture.passwords["browser_admin"] ?? "");
    await other.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    const media = await other.evaluate(async (url) => {
      const response = await fetch(url);
      return { status: response.status, redirected: response.redirected, body: await response.text() };
    }, asset?.url ?? "");
    expect(media).toEqual({ status: 401, redirected: false, body: '{"error":"account_changed"}' });
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByRole("heading", { name: "The signed-in account changed" }).waitFor();
    await Bun.sleep(2500);
    expect(rows(books.text, member)).toEqual([]);
    expect(rows(books.text, admin)).toEqual([]);
    expect(await page.locator(".epub-viewport").count()).toBe(0);
    await context.close();
  });

  test("an ended session stops the reader instead of saving", async () => {
    const { context, page } = await signedIn();
    await openReader(page, books.text);
    server.execute("DELETE FROM sessions WHERE user_id = ?", member);
    await page.getByRole("button", { name: "Next page" }).click();
    await page.getByRole("heading", { name: "Your session ended" }).waitFor();
    await Bun.sleep(2000);
    expect(rows(books.text)).toEqual([]);
    await context.close();
  });
});

async function audio(page: Page): Promise<{ time: number; paused: boolean; src: string; rate: number }> {
  return page.evaluate(() => {
    const element = document.querySelector("audio");
    return { time: element?.currentTime ?? -1, paused: element?.paused ?? true, src: element?.currentSrc ?? "", rate: element?.playbackRate ?? 0 };
  });
}

async function playedUntil(page: Page, seconds: number) {
  await page.waitForFunction((target) => (document.querySelector("audio")?.currentTime ?? 0) >= target, seconds, { timeout: 40_000 });
}

describe("the Go online audiobook player", () => {
  test("decodes the server's tracks, saves pause and seek at the action, rewinds once on resume and never re-dates the replayed span", async () => {
    const { context, page, seen } = await signedIn();
    await page.goto(`${server.origin}/preview/library/${books.audio}`);
    await page.getByRole("link", { name: /^Start listening Reader Spoken Sampler/ }).click();
    await page.waitForURL(`**/preview/library/${books.audio}/read`);
    await page.getByText("Track 1 of 3: Part 1.wav").waitFor();
    await page.getByText("Paused").waitFor({ timeout: 20_000 });
    expect(await page.getByLabel("Position in this track").getAttribute("aria-valuetext")).toBe("0:00 of 0:24");
    await stays(books.audio, [], 1500);
    const tracks = await readerAsset(page, books.audio);

    await page.getByRole("button", { name: "Play" }).click();
    await page.getByRole("button", { name: "Pause" }).waitFor();
    await playedUntil(page, 6.2);
    const paused = Date.now();
    await page.getByRole("button", { name: "Pause" }).click();
    const first = await waitForRow(books.audio, (row) => Math.abs((row.position_seconds ?? 0) - 6.2) < 1.2 && railsTime(row.observed_at) >= paused - 200);
    expect(first.asset_id).toBe(tracks[0]?.id ?? "");
    expect(first.locator).toBeNull();
    const held = (await audio(page)).time;
    expect(Math.abs((first.position_seconds ?? 0) - held)).toBeLessThan(0.6);

    await page.reload();
    await page.getByText("Paused").waitFor({ timeout: 20_000 });
    expect(Math.abs((await audio(page)).time - held)).toBeLessThan(0.6);
    await stays(books.audio, [first], 1500);

    await page.getByRole("button", { name: "Play" }).click();
    await page.getByRole("button", { name: "Pause" }).waitFor();
    const rewound = (await audio(page)).time;
    expect(rewound).toBeGreaterThanOrEqual(held - 5.6);
    expect(rewound).toBeLessThan(held - 4);
    await Bun.sleep(3000);
    expect(rows(books.audio)).toEqual([first]);
    await page.getByRole("button", { name: "Pause" }).click();
    await Bun.sleep(1500);
    expect(rows(books.audio)).toEqual([first]);
    await page.getByRole("button", { name: "Play" }).click();
    expect(Math.abs((await audio(page)).time - (rewound + 3))).toBeLessThan(1.2);
    await playedUntil(page, held + 2);
    await page.getByRole("button", { name: "Pause" }).click();
    const past = await waitForRow(books.audio, (row) => row.version > first.version);
    expect(past.position_seconds ?? 0).toBeGreaterThan(held + 1.5);

    await page.getByLabel("Position in this track").focus();
    const seekAt = Date.now();
    await page.keyboard.press("ArrowRight");
    const sought = await waitForRow(books.audio, (row) => row.version > past.version);
    expect(Math.abs((sought.position_seconds ?? 0) - ((past.position_seconds ?? 0) + 1))).toBeLessThan(1.01);
    expect(railsTime(sought.observed_at)).toBeGreaterThanOrEqual(seekAt - 50);

    await page.getByLabel("Speed").selectOption("1.5");
    expect((await audio(page)).rate).toBe(1.5);
    await page.getByRole("button", { name: "Next track" }).click();
    await page.getByText("Track 2 of 3: Part 2.wav").waitFor();
    const second = await waitForRow(books.audio, (row) => row.asset_id === (tracks[1]?.id ?? ""));
    expect(second.position_seconds).toBe(0);
    await page.getByText("Paused").waitFor();
    expect((await audio(page)).paused).toBe(true);
    expect((await audio(page)).rate).toBe(1.5);
    await stays(books.audio, [second], 1500);

    await page.getByLabel("Position in this track").focus();
    await page.keyboard.press("End");
    await page.keyboard.press("ArrowLeft");
    await page.keyboard.press("ArrowLeft");
    await waitForRow(books.audio, (row) => row.asset_id === (tracks[1]?.id ?? "") && (row.position_seconds ?? 0) >= 15);
    await page.getByRole("button", { name: "Play" }).click();
    await page.getByText("Track 3 of 3: Part 3.wav").waitFor({ timeout: 20_000 });
    const continued = await waitForRow(books.audio, (row) => row.asset_id === (tracks[2]?.id ?? ""));
    expect(continued.position_seconds ?? 0).toBeLessThan(2);
    await page.getByRole("button", { name: "Pause" }).waitFor();
    expect((await audio(page)).paused).toBe(false);
    expect((await audio(page)).src).toContain(`/preview/api/v1/accounts/${member}/library/${books.audio}/assets/${tracks[2]?.id ?? ""}`);
    await page.getByRole("button", { name: "Pause" }).click();
    await page.screenshot({ path: join(artifacts.out(), "reader-audio-desktop.png") });
    await clean(page, seen);
    await context.close();
  });

  test("leaving the player keeps the place; an ended session stops it without saving", async () => {
    const { context, page } = await signedIn();
    await page.goto(`${server.origin}/preview/library/${books.audio}/read`);
    await page.getByText("Paused").waitFor({ timeout: 20_000 });
    await page.getByRole("button", { name: "Play" }).click();
    await playedUntil(page, 2.5);
    await page.getByRole("link", { name: "Back to the book" }).click();
    await page.waitForURL(`**/preview/library/${books.audio}`);
    const left = await waitForRow(books.audio, (row) => (row.position_seconds ?? 0) >= 2);
    await page.goto(`${server.origin}/preview/library/${books.audio}/read`);
    await page.getByText("Paused").waitFor({ timeout: 20_000 });
    await page.getByRole("button", { name: "Play" }).click();
    await page.getByRole("button", { name: "Pause" }).waitFor();
    server.execute("DELETE FROM sessions WHERE user_id = ?", member);
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await page.getByRole("heading", { name: "Your session ended" }).waitFor();
    expect(await page.locator("audio").count()).toBe(0);
    await Bun.sleep(6500);
    expect(rows(books.audio)).toEqual([left]);
    await context.close();
  });
});

describe("Rails continues what Go wrote", () => {
  test("leaves Go-written reading and listening rows with their activity times for the real Rails verifier", async () => {
    const { context, page } = await signedIn();
    await openReader(page, books.text);
    await page.getByRole("button", { name: "Next page" }).click();
    const reading = await waitForRow(books.text, (row) => row.version === 1);
    await page.goto(`${server.origin}/preview/library/${books.audio}/read`);
    await page.getByText("Paused").waitFor({ timeout: 20_000 });
    await page.getByLabel("Position in this track").focus();
    await page.keyboard.press("ArrowRight");
    const listening = await waitForRow(books.audio, (row) => row.version === 1);
    await context.close();
    const directory = artifacts.out();
    const snapshot = join(directory, "reader-rows.sqlite3");
    rmSync(snapshot, { force: true });
    server.execute("VACUUM INTO ?", snapshot);
    writeFileSync(join(directory, "reader-rows.json"), JSON.stringify({ user_id: member, rows: { [books.text]: reading, [books.audio]: listening } }, null, 2));
  });
});
