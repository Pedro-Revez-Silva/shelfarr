import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import type { Browser, Page } from "playwright-core";
import { launchBrowser, loadFixture, openAs, policyViolations, signIn, startServer, unexpectedConsole, type RunningServer } from "./harness";

const fixture = loadFixture();
let browser: Browser;
let server: RunningServer;

beforeAll(async () => {
  browser = await launchBrowser();
  server = await startServer({ fixture });
});

afterAll(async () => {
  await browser.close();
  await server.stop();
});

const memberId = fixture.users["browser_member"] ?? 0;
const adminId = fixture.users["browser_admin"] ?? 0;

async function signedIn(username: string) {
  const opened = await openAs(browser, server);
  await opened.page.goto(`${server.origin}/preview/library`);
  await signIn(opened.page, username, fixture.passwords[username] ?? "");
  await opened.page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
  await opened.page.locator(".book-card").first().waitFor();
  return opened;
}

async function openBook(page: Page, title: string) {
  await page.getByRole("link", { name: title, exact: true }).first().click();
  await page.getByRole("heading", { level: 1, name: title }).waitFor();
}

describe("the existing Library and details screens served by Go", () => {
  test("lists the account's books, filters, pages and keeps the URL as the state", async () => {
    const { context, page, seen } = await signedIn("browser_member");
    const first = await page.locator(".book-card").count();
    expect(first).toBeGreaterThan(5);
    await page.getByRole("radio", { name: "Audiobooks" }).check();
    await page.waitForURL(/type=audiobook/);
    await page.waitForFunction(() => document.querySelectorAll(".book-card").length > 0 && [...document.querySelectorAll(".book-format")].every((node) => node.textContent === "Audiobook"));
    await page.getByRole("radio", { name: "Everything" }).check();
    await page.getByLabel("Sort by").selectOption("title");
    await page.waitForURL(/sort=title/);
    await page.getByRole("searchbox", { name: "Search your library" }).fill("alpha");
    await page.getByRole("button", { name: "Search" }).click();
    await page.waitForURL(/q=alpha/);
    await page.waitForFunction(() => document.querySelectorAll(".book-card").length >= 1);
    await page.reload();
    expect(page.url()).toContain("q=alpha");
    await page.locator(".book-card").first().waitFor();
    expect(await page.getByRole("searchbox", { name: "Search your library" }).inputValue()).toBe("alpha");
    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
  });

  test("a book opens at its own address, reloads there and Back/Forward return to the list", async () => {
    const { context, page } = await signedIn("browser_member");
    const title = (await page.locator(".book-card h3 a").first().innerText()).trim();
    await openBook(page, title);
    const detailsUrl = page.url();
    expect(detailsUrl).toMatch(/\/preview\/library\/\d+$/);
    expect(await page.title()).toBe(`${title} · Shelfarr`);
    await page.reload();
    await page.getByRole("heading", { level: 1, name: title }).waitFor();
    await page.goBack();
    await page.getByRole("heading", { level: 1, name: "Library" }).waitFor();
    await page.goForward();
    await page.getByRole("heading", { level: 1, name: title }).waitFor();
    expect(page.url()).toBe(detailsUrl);
    await page.goto(`${server.origin}/preview/library/999999`);
    await page.getByText("This book is no longer in your library").waitFor();
    await context.close();
  });

  test("changing the reading status round-trips through SQLite, survives reload and Back, and is invisible to another account", async () => {
    const member = await signedIn("browser_member");
    const title = (await member.page.locator(".book-card h3 a").first().innerText()).trim();
    await openBook(member.page, title);
    const book = Number(new URL(member.page.url()).pathname.split("/").pop());
    await member.page.getByLabel("Reading status").selectOption("finished");
    await member.page.getByRole("button", { name: "Save status" }).click();
    await member.page.getByText("Saved. Your saved place is kept.").waitFor();
    const rows = server.query<{ user_id: number; book_id: number; status: number }>("SELECT user_id, book_id, status FROM consumer_reading_states WHERE book_id = ? AND user_id = ?", book, memberId);
    expect(rows).toEqual([{ user_id: memberId, book_id: book, status: 2 }]);
    await member.page.reload();
    expect(await member.page.getByLabel("Reading status").inputValue()).toBe("finished");
    await member.page.goBack();
    await member.page.getByRole("heading", { level: 1, name: "Library" }).waitFor();
    await member.page.getByRole("radio", { name: "Everything" }).waitFor();
    await member.page.getByLabel("Reading status").selectOption("finished");
    await member.page.waitForFunction((name) => [...document.querySelectorAll(".book-card h3 a")].some((node) => node.textContent === name), title);

    const admin = await signedIn("browser_admin");
    await openBook(admin.page, title);
    expect(await admin.page.getByLabel("Reading status").inputValue()).toBe("unread");
    expect(server.query("SELECT id FROM consumer_reading_states WHERE book_id = ? AND user_id = ?", book, adminId)).toHaveLength(0);
    await member.context.close();
    await admin.context.close();
  });

  test("markup in a description is shown as plain text and no script from it ever runs", async () => {
    const payload = `<p>First <b>bold</b> line &amp; entity</p><script>window.__pwned = 1</script><img src=x onerror="window.__pwned = 2"><p>Second line</p>&lt;script&gt;window.__pwned = 3&lt;/script&gt;`;
    server.execute("UPDATE books SET description = ? WHERE id = (SELECT id FROM books WHERE title = 'alpha' AND file_path IS NOT NULL LIMIT 1)", payload);
    const { context, page, seen } = await signedIn("browser_member");
    const book = server.query<{ id: number }>("SELECT id FROM books WHERE title = 'alpha' AND file_path IS NOT NULL LIMIT 1")[0]?.id;
    await page.goto(`${server.origin}/preview/library/${book}`);
    await page.getByRole("heading", { level: 1, name: "alpha" }).waitFor();
    const description = page.locator(".description");
    await description.waitFor();
    expect(await description.innerText()).toBe("First bold line & entity\n\nSecond line\n<script>window.__pwned = 3</script>");
    expect(await description.locator("*").count()).toBe(0);
    expect(await page.evaluate(() => (window as unknown as { __pwned?: number }).__pwned)).toBeUndefined();
    expect(await policyViolations(page)).toEqual([]);
    expect(seen.page).toEqual([]);
    await context.close();
  });

  test("titles that look like markup are text, not elements", async () => {
    const { context, page } = await signedIn("browser_member");
    await page.getByRole("searchbox", { name: "Search your library" }).fill("Café");
    await page.getByRole("button", { name: "Search" }).click();
    const link = page.getByRole("link", { name: /Café 📚 <b>&amp;<\/b>/ });
    await link.waitFor();
    expect(await page.locator(".book-card h3 a b").count()).toBe(0);
    await context.close();
  });

  test("a response that arrives late after navigation or sign-out is never shown", async () => {
    const { context, page } = await signedIn("browser_member");
    const title = (await page.locator(".book-card h3 a").first().innerText()).trim();
    await page.route(/\/preview\/api\/v1\/library\/\d+$/, async (route) => {
      await Bun.sleep(1500);
      await route.continue();
    });
    await page.getByRole("link", { name: title, exact: true }).first().click();
    await page.goBack();
    await page.getByRole("heading", { level: 1, name: "Library" }).waitFor();
    await Bun.sleep(2000);
    expect(await page.getByRole("heading", { level: 1 }).allInnerTexts()).toEqual(["Library"]);
    await page.getByRole("link", { name: title, exact: true }).first().click();
    await page.getByRole("button", { name: "Sign out" }).click();
    await page.getByLabel("Username").waitFor();
    await Bun.sleep(2000);
    expect(await page.locator("body").innerText()).not.toContain(title);
    await context.close();
  });

  test("Go mode shows no dead links or buttons for reading, listening, discovery or administration", async () => {
    const { context, page } = await signedIn("browser_admin");
    const hrefs = () => page.locator("a[href]").evaluateAll((nodes) => nodes.map((node) => node.getAttribute("href") ?? "").filter((href) => !href.startsWith("#")));
    for (const href of await hrefs()) expect(href.startsWith("/preview/")).toBe(true);
    const book = server.query<{ id: number }>("SELECT id FROM books WHERE title = 'alpha' AND file_path IS NOT NULL LIMIT 1")[0]?.id;
    await page.goto(`${server.origin}/preview/library/${book}`);
    await page.getByRole("heading", { level: 1, name: "alpha" }).waitFor();
    for (const href of await hrefs()) expect(href.startsWith("/preview/")).toBe(true);
    expect(await page.getByText("not available on this experimental server yet").count()).toBeGreaterThan(0);
    await context.close();
  });
});
