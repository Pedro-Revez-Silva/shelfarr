import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import type { Browser, Page } from "playwright-core";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, openAs, policyViolations, signIn, startServer, unexpectedConsole, writeText, type RunningServer } from "./harness";

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

const member = () => fixture.passwords["browser_member"] ?? "";
const admin = () => fixture.passwords["browser_admin"] ?? "";
const memberId = fixture.users["browser_member"] ?? 0;

async function libraryReady(page: Page) {
  await page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
  await page.getByRole("list").first().waitFor();
}

describe("signing in through the browser against the real binary and SQLite", () => {
  test("a signed-out visitor gets the sign-in screen at a direct Library URL, signs in with the keyboard and lands on the same screen", async () => {
    const { context, page, seen } = await openAs(browser, server);
    const requests: string[] = [];
    page.on("request", (request) => requests.push(`${request.method()} ${request.url()} ${request.postData() ?? ""}`));
    await page.goto(`${server.origin}/preview/library`);
    await page.getByLabel("Username").waitFor();
    expect(await page.title()).toBe("Sign in · Shelfarr");
    expect(await page.locator("main").innerText()).not.toContain("Showing");
    await page.keyboard.press("Tab");
    expect(await page.evaluate(() => document.activeElement?.id !== "")).toBe(true);
    await page.getByLabel("Username").focus();
    await page.keyboard.type("browser_member");
    await page.keyboard.press("Tab");
    await page.keyboard.type(member());
    await page.keyboard.press("Enter");
    await libraryReady(page);
    expect(page.url()).toBe(`${server.origin}/preview/library`);
    expect(await page.title()).toBe("Library · Shelfarr");
    const rows = server.query<{ user_id: number }>("SELECT user_id FROM sessions WHERE user_id = ?", memberId);
    expect(rows.length).toBeGreaterThanOrEqual(1);
    const cookies = await context.cookies();
    const session = cookies.find((cookie) => cookie.name === "session_id");
    expect(session?.httpOnly).toBe(true);
    expect(session?.sameSite).toBe("Lax");
    expect(cookies.find((cookie) => cookie.name === "shelfarr_login")).toBeUndefined();
    expect(requests.filter((line) => line.includes(member()) && !line.startsWith("POST") ).length).toBe(0);
    expect(requests.every((line) => !line.split(" ")[1]?.includes("browser_member"))).toBe(true);
    expect(await page.evaluate(() => `${localStorage.length}${sessionStorage.length}`)).toBe("00");
    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen)).toEqual([]);
    expect(seen.page).toEqual([]);
    await context.close();
  });

  test("rejected credentials are explained, focus moves to the error, nothing is created and the failure is counted", async () => {
    const { context, page, seen } = await openAs(browser, server);
    const before = server.query<{ failed_login_count: number }>("SELECT failed_login_count FROM users WHERE username = 'browser_member'")[0]?.failed_login_count ?? 0;
    const sessionsBefore = server.query("SELECT id FROM sessions").length;
    await page.goto(`${server.origin}/preview/library`);
    await signIn(page, "browser_member", "not-the-password");
    const alert = page.getByRole("alert");
    await alert.waitFor();
    expect(await alert.innerText()).toContain("were not accepted");
    expect(await page.evaluate(() => document.activeElement?.getAttribute("role"))).toBe("alert");
    expect(await page.getByLabel("Username").getAttribute("aria-invalid")).toBe("true");
    expect(await page.getByLabel("Password", { exact: true }).inputValue()).toBe("not-the-password");
    expect(server.query<{ failed_login_count: number }>("SELECT failed_login_count FROM users WHERE username = 'browser_member'")[0]?.failed_login_count).toBe(before + 1);
    expect(server.query("SELECT id FROM sessions").length).toBe(sessionsBefore);
    expect(await page.locator("body").innerText()).not.toContain("Showing");
    await page.getByLabel("Password", { exact: true }).fill(member());
    await page.getByRole("button", { name: "Sign in" }).click();
    await libraryReady(page);
    expect(server.query<{ failed_login_count: number }>("SELECT failed_login_count FROM users WHERE username = 'browser_member'")[0]?.failed_login_count).toBe(0);
    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
  });

  test("an account that needs a second factor or single sign-on is told so honestly, with no bypass and no session", async () => {
    const { context, page } = await openAs(browser, server);
    const sessionsBefore = server.query("SELECT id FROM sessions").length;
    await page.goto(`${server.origin}/preview/library`);
    await signIn(page, "alice", fixture.passwords["alice"] ?? "");
    await page.getByRole("alert").waitFor();
    expect(await page.getByRole("alert").innerText()).toContain("two-step verification");
    expect(await page.getByRole("link").count()).toBe(0);
    expect(server.query("SELECT id FROM sessions").length).toBe(sessionsBefore);
    await context.close();
  });

  test("a user outside the allowlist cannot sign in and learns nothing beyond a rejected sign-in", async () => {
    const { context, page } = await openAs(browser, server);
    await page.goto(`${server.origin}/preview/library`);
    await signIn(page, "browser_outsider", fixture.passwords["browser_outsider"] ?? "");
    const alert = page.getByRole("alert");
    await alert.waitFor();
    expect(await alert.innerText()).toContain("were not accepted");
    await context.close();
  });

  test("signing out revokes the session row, clears the cookie and a Back navigation cannot reveal the library", async () => {
    const { context, page } = await openAs(browser, server);
    await page.goto(`${server.origin}/preview/library`);
    await signIn(page, "browser_member", member());
    await libraryReady(page);
    const first = page.locator(".book-card a").first();
    const title = (await first.innerText()).trim();
    await first.click();
    await page.getByRole("heading", { level: 1, name: title }).waitFor();
    const sessionsWith = server.query("SELECT id FROM sessions WHERE user_id = ?", memberId).length;
    await page.getByRole("button", { name: "Sign out" }).click();
    await page.getByLabel("Username").waitFor();
    expect(server.query("SELECT id FROM sessions WHERE user_id = ?", memberId).length).toBe(sessionsWith - 1);
    expect((await context.cookies()).find((cookie) => cookie.name === "session_id")).toBeUndefined();
    await page.goBack();
    await page.getByLabel("Username").waitFor();
    expect(await page.locator("body").innerText()).not.toContain(title);
    await page.reload();
    await page.getByLabel("Username").waitFor();
    expect(await page.locator("body").innerText()).not.toContain(title);
    await context.close();
  });

  test("a session revoked on the server stops the page at the next focus and offers a fresh sign-in", async () => {
    const { context, page } = await openAs(browser, server);
    await page.goto(`${server.origin}/preview/library`);
    await signIn(page, "browser_member", member());
    await libraryReady(page);
    server.execute("DELETE FROM sessions WHERE user_id = ?", memberId);
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await page.getByRole("heading", { name: "Your session ended" }).waitFor();
    expect(await page.locator("body").innerText()).not.toContain("Showing");
    await page.getByRole("button", { name: "Sign in again" }).click();
    await page.getByLabel("Username").waitFor();
    expect(await page.getByRole("status").innerText()).toContain("session ended");
    await context.close();
  });

  test("another tab that signs in as someone else stops this tab, and recovery rebuilds it for the new account only", async () => {
    const { context, page: first } = await openAs(browser, server);
    await first.goto(`${server.origin}/preview/library`);
    await signIn(first, "browser_member", member());
    await libraryReady(first);
    const memberHeader = new Set<string>();
    first.on("request", (request) => {
      const header = request.headers()["x-shelfarr-account"];
      if (header) memberHeader.add(header);
    });
    const second = await context.newPage();
    await second.goto(`${server.origin}/preview/library`);
    await libraryReady(second);
    await second.getByRole("button", { name: "Sign out" }).click();
    await second.getByLabel("Username").waitFor();
    await signIn(second, "browser_admin", admin());
    await libraryReady(second);
    await first.evaluate(() => window.dispatchEvent(new Event("focus")));
    await first.getByRole("heading", { name: "The signed-in account changed" }).waitFor();
    await first.getByRole("button", { name: "Continue as the current account" }).click();
    await libraryReady(first);
    const adminId = String(fixture.users["browser_admin"]);
    expect([...memberHeader].filter((value) => value === adminId).length).toBeGreaterThan(0);
    await context.close();
  });

  test("a rejected or missing CSRF token on the status write changes nothing and is explained", async () => {
    const { context, page } = await openAs(browser, server);
    await page.goto(`${server.origin}/preview/library`);
    await signIn(page, "browser_member", member());
    await libraryReady(page);
    await page.locator(".book-card a").first().click();
    await page.getByRole("heading", { level: 1 }).first().waitFor();
    const book = Number(new URL(page.url()).pathname.split("/").pop());
    const rowsBefore = server.query("SELECT id FROM consumer_reading_states WHERE book_id = ? AND user_id = ?", book, memberId).length;
    let attempts = 0;
    await page.route("**/reading_status", async (route) => {
      attempts += 1;
      const headers = { ...route.request().headers() };
      if (attempts === 1) delete headers["x-csrf-token"];
      else headers["x-csrf-token"] = "forged";
      await route.continue({ headers });
    });
    await page.getByLabel("Reading status").selectOption("finished");
    await page.getByRole("button", { name: "Save status" }).click();
    await page.getByText(/out of date/).waitFor();
    expect(server.query("SELECT id FROM consumer_reading_states WHERE book_id = ? AND user_id = ?", book, memberId).length).toBe(rowsBefore);
    await page.getByRole("button", { name: "Save status" }).click();
    await page.waitForFunction(() => document.querySelector(".status-error") !== null);
    expect(attempts).toBe(2);
    expect(server.query("SELECT id FROM consumer_reading_states WHERE book_id = ? AND user_id = ?", book, memberId).length).toBe(rowsBefore);
    await page.unroute("**/reading_status");
    await page.getByRole("button", { name: "Save status" }).click();
    await page.getByText("Saved. Your saved place is kept.").waitFor();
    const stored = server.query<{ status: number }>("SELECT status FROM consumer_reading_states WHERE book_id = ? AND user_id = ?", book, memberId);
    expect(stored).toHaveLength(1);
    await context.close();
  });

  test("records what the sign-in page looked like for the report", async () => {
    const { context, page } = await openAs(browser, server);
    await page.goto(`${server.origin}/consumer/connect?user_code=ABCD-EFGH`);
    await page.getByLabel("Username").waitFor();
    expect(await page.title()).toBe("Sign in · Shelfarr");
    expect(page.url()).toBe(`${server.origin}/consumer/connect?user_code=ABCD-EFGH`);
    await page.screenshot({ path: join(artifacts.out(), "signin-for-connect.png") });
    writeText(join(artifacts.out(), "signin-for-connect.txt"), await page.locator("main").innerText());
    await context.close();
  });
});
