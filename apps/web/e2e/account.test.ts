import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import axe from "axe-core";
import type { Browser, Page } from "playwright-core";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, newContext, openAs, policyViolations, signIn, startServer, unexpectedConsole, watch, type RunningServer } from "./harness";

const fixture = loadFixture();
const accountId = fixture.users["browser_account"] ?? 0;
const original = () => fixture.passwords["browser_account"] ?? "";
let browser: Browser;

beforeAll(async () => {
  browser = await launchBrowser();
});

afterAll(async () => {
  await browser.close();
});

async function fresh(): Promise<RunningServer> {
  return startServer({ fixture, extraArguments: ["-login-attempts", "1000"] });
}

function stored(server: RunningServer) {
  const [row] = server.query<{ name: string; digest: string; updated: string }>("SELECT name, password_digest AS digest, CAST(updated_at AS TEXT) AS updated FROM users WHERE id = ?", accountId);
  return row ?? { name: "", digest: "", updated: "" };
}

function sessionsOf(server: RunningServer, userId: number): number {
  return server.query<{ total: number }>("SELECT COUNT(*) AS total FROM sessions WHERE user_id = ?", userId)[0]?.total ?? -1;
}

async function accountReady(page: Page) {
  await page.getByRole("heading", { name: "Account", level: 1 }).waitFor();
  await page.getByRole("region", { name: "Signed in as" }).waitFor();
}

async function openAccount(page: Page, origin: string, password = original()) {
  await page.goto(`${origin}/preview/account`);
  await page.getByText("Sign in to manage your account. You will come straight back to it.").waitFor();
  await signIn(page, "browser_account", password);
  await accountReady(page);
}

const nameField = (page: Page) => page.getByRole("textbox", { name: "Display name" });

describe("the Account page in the Go preview", () => {
  test("opens from a direct load after sign-in, survives reload and Back, and writes nothing by opening", async () => {
    const server = await fresh();
    const { context, page, seen } = await openAs(browser, server);
    const before = stored(server);
    await openAccount(page, server.origin);
    expect(await page.title()).toBe("Account · Shelfarr");
    const identity = page.getByRole("region", { name: "Signed in as" });
    expect(await identity.innerText()).toContain("Browser account");
    expect(await identity.innerText()).toContain("@browser_account");
    await page.reload();
    await accountReady(page);
    await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Library" }).click();
    await page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    await page.goBack();
    await accountReady(page);
    expect(page.url()).toBe(`${server.origin}/preview/account`);
    expect(await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Account" }).getAttribute("aria-current")).toBe("page");
    const after = stored(server);
    expect(after.updated).toBe(before.updated);
    expect(after.name).toBe(before.name);
    expect(await page.locator("a[href='/profile'], a[href*='two_factor'], a[href*='api_tokens'], a[href*='kobo']").count()).toBe(0);
    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("saving a Unicode display name stores it exactly and refreshes the header without touching the password form", async () => {
    const server = await fresh();
    const { context, page, seen } = await openAs(browser, server);
    await openAccount(page, server.origin);
    await page.getByLabel("Current password").fill("half-typed");
    await nameField(page).fill("Zoë 📚 ✨");
    await page.getByRole("button", { name: "Save name" }).click();
    await page.getByText("Display name saved.").waitFor();
    await page.locator(".account-bar strong", { hasText: "Zoë 📚 ✨" }).waitFor();
    expect(stored(server).name).toBe("Zoë 📚 ✨");
    expect(await page.getByLabel("Current password").inputValue()).toBe("half-typed");
    await nameField(page).fill("   ");
    await page.keyboard.press("Enter");
    await page.getByText("Enter a display name.").waitFor();
    expect(await page.evaluate(() => document.activeElement?.getAttribute("name"))).toBe("name");
    expect(stored(server).name).toBe("Zoë 📚 ✨");
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("refusals are explained on their fields and write nothing", async () => {
    const server = await fresh();
    const { context, page, seen } = await openAs(browser, server);
    await openAccount(page, server.origin);
    const digest = stored(server).digest;
    await page.getByLabel("Current password").fill("Wrong-Passw0rd-123");
    await page.getByLabel("New password", { exact: true }).fill("Browser-Changed-1x");
    await page.getByLabel("Confirm new password").fill("Browser-Changed-1x");
    await page.getByRole("button", { name: "Change password" }).click();
    await page.getByText("That is not your current password.").waitFor();
    expect(await page.evaluate(() => document.activeElement?.getAttribute("name"))).toBe("current_password");
    expect(await page.getByLabel("Current password").getAttribute("aria-invalid")).toBe("true");
    await page.getByLabel("Current password").fill(original());
    await page.getByLabel("New password", { exact: true }).fill("short");
    await page.getByLabel("Confirm new password").fill("short");
    await page.getByRole("button", { name: "Change password" }).click();
    await page.getByText("Use at least 12 characters. Include a lowercase letter (a–z), an uppercase letter (A–Z) and a number (0–9).").waitFor();
    expect(await page.evaluate(() => document.activeElement?.getAttribute("name"))).toBe("password");
    await page.getByLabel("Confirm new password").fill("shorter");
    await page.getByRole("button", { name: "Change password" }).click();
    await page.getByText("This does not match the new password.").waitFor();
    expect(stored(server).digest).toBe(digest);
    expect(sessionsOf(server, accountId)).toBe(3);
    await page.screenshot({ path: join(artifacts.out(), "account-refusals.png"), fullPage: true });
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("a password change keeps this browser signed in, signs out every other browser of the account and only that account", async () => {
    const server = await fresh();
    const elsewhere = await openAs(browser, server);
    await elsewhere.page.goto(`${server.origin}/preview/library`);
    await signIn(elsewhere.page, "browser_account", original());
    await elsewhere.page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    const bystander = await openAs(browser, server);
    await bystander.page.goto(`${server.origin}/preview/library`);
    await signIn(bystander.page, "browser_member", fixture.passwords["browser_member"] ?? "");
    await bystander.page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    const memberSessions = sessionsOf(server, fixture.users["browser_member"] ?? 0);
    const { context, page, seen } = await openAs(browser, server);
    const requests: string[] = [];
    page.on("request", (request) => requests.push(`${request.method()} ${request.url()}`));
    await openAccount(page, server.origin);
    const changed = "Browser-Changed-Passw0rd";
    await page.getByLabel("Current password").fill(original());
    await page.getByLabel("New password", { exact: true }).fill(changed);
    await page.getByLabel("Confirm new password").fill(changed);
    await page.getByRole("button", { name: "Change password" }).dblclick();
    await page.getByText(/Password changed\. You are still signed in here/).waitFor();
    expect(requests.filter((line) => line.startsWith("POST") && line.endsWith("/preview/api/v1/account/password"))).toHaveLength(1);
    for (const label of ["Current password", "New password", "Confirm new password"]) expect(await page.getByLabel(label, { exact: true }).inputValue()).toBe("");
    expect(stored(server).digest.startsWith("$2a$12$")).toBe(true);
    expect(sessionsOf(server, accountId)).toBe(1);
    expect(sessionsOf(server, fixture.users["browser_member"] ?? 0)).toBe(memberSessions);
    expect(requests.some((line) => line.includes(changed) || line.includes(original()))).toBe(false);
    expect(await page.evaluate(() => JSON.stringify({ ...localStorage, ...sessionStorage }) + window.location.href + history.length)).not.toContain(changed);
    await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Library" }).click();
    await page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    await elsewhere.page.reload();
    await elsewhere.page.getByLabel("Username").waitFor();
    await bystander.page.reload();
    await bystander.page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    const again = await openAs(browser, server);
    await again.page.goto(`${server.origin}/preview/library`);
    await signIn(again.page, "browser_account", original());
    await again.page.getByRole("alert").waitFor();
    await again.page.getByLabel("Password", { exact: true }).fill(changed);
    await again.page.getByRole("button", { name: "Sign in" }).click();
    await again.page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    expect(server.logs.join("\n")).not.toContain(changed);
    expect(unexpectedConsole(seen)).toEqual([]);
    for (const opened of [elsewhere, bystander, again]) await opened.context.close();
    await context.close();
    await server.stop();
  });

  test("another tab switching account stops the open Account page before it can save for the wrong account", async () => {
    const server = await fresh();
    const { context, page } = await openAs(browser, server);
    await openAccount(page, server.origin);
    await nameField(page).fill("Should Not Save");
    const other = await context.newPage();
    await other.goto(`${server.origin}/preview/library`);
    await other.getByRole("button", { name: "Sign out" }).click();
    await signIn(other, "browser_member", fixture.passwords["browser_member"] ?? "");
    await other.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    await page.bringToFront();
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await page.getByRole("heading", { name: "The signed-in account changed" }).waitFor();
    expect(stored(server).name).toBe("Browser account");
    const [member] = server.query<{ name: string }>("SELECT name FROM users WHERE id = ?", fixture.users["browser_member"] ?? 0);
    expect(member?.name).toBe("Browser member");
    await context.close();
    await server.stop();
  });

  test("a cookie for an account outside the preview, set by another tab, locks the open page and drops the typed password", async () => {
    const server = await fresh();
    const { context, page } = await openAs(browser, server);
    await openAccount(page, server.origin);
    await page.getByLabel("Current password").fill("typed-but-not-sent");
    const outsider = fixture.personas["outsider"];
    await context.addCookies([{ name: "session_id", value: outsider?.cookie ?? "", url: server.origin }]);
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await page.getByRole("heading", { name: "The signed-in account changed" }).waitFor();
    expect(await page.getByLabel("Current password").count()).toBe(0);
    expect(await page.content()).not.toContain("typed-but-not-sent");
    expect(stored(server).name).toBe("Browser account");
    await context.close();
    await server.stop();
  });

  test("Tab walks the identity, name and password controls in reading order and never reaches the hidden username", async () => {
    const server = await fresh();
    const { context, page } = await openAs(browser, server);
    await openAccount(page, server.origin);
    await nameField(page).focus();
    const order: string[] = [];
    for (let step = 0; step < 5; step += 1) {
      await page.keyboard.press("Tab");
      order.push(await page.evaluate(() => `${document.activeElement?.tagName}:${document.activeElement?.getAttribute("name") ?? document.activeElement?.textContent}`));
    }
    expect(order).toEqual(["BUTTON:Save name", "INPUT:current_password", "INPUT:password", "INPUT:password_confirmation", "BUTTON:Change password"]);
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
  await page.screenshot({ path: join(artifacts.out(), `account-${label}.png`), fullPage: true });
  await page.evaluate(axe.source);
  const violations = await page.evaluate(async () => {
    const found = await (window as unknown as { axe: { run: (context?: unknown, options?: unknown) => Promise<{ violations: { id: string; impact: string; nodes: { target: string[] }[] }[] }> } }).axe.run(document, { resultTypes: ["violations"] });
    return found.violations.map((violation) => `${violation.id} (${violation.impact}): ${violation.nodes.map((node) => node.target.join(" ")).join(", ")}`);
  });
  expect(violations, label).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), `${label} overflow`).toBeLessThanOrEqual(0);
  const small = await page.evaluate(() =>
    [...document.querySelectorAll<HTMLElement>("button, input:not([type=hidden]):not([hidden])")]
      .filter((element) => element.offsetParent !== null)
      .map((element) => ({ label: element.textContent?.trim() || element.getAttribute("name") || element.tagName, height: element.getBoundingClientRect().height, size: parseFloat(getComputedStyle(element).fontSize), input: element.tagName === "INPUT" }))
      .filter((entry) => entry.height < 44 || (entry.input && entry.size < 16)),
  );
  expect(small, `${label} targets`).toEqual([]);
}

describe("the Account page renders accessibly", () => {
  let server: RunningServer;
  beforeAll(async () => {
    server = await fresh();
  });
  afterAll(async () => {
    await server.stop();
  });
  for (const viewport of Object.keys(viewports) as (keyof typeof viewports)[]) {
    for (const scheme of ["light", "dark"] as const) {
      for (const zoom of [100, 200]) {
        if (viewport === "narrow" && zoom === 100) continue;
        test(`${viewport} ${scheme} ${zoom}%`, async () => {
          const context = await newContext(browser, { colorScheme: scheme, viewport: viewports[viewport] });
          const page = await context.newPage();
          const seen = await watch(page);
          await openAccount(page, server.origin);
          await audit(page, `${viewport}-${scheme}-${zoom}`, zoom);
          await page.getByLabel("Current password").fill("Wrong-Passw0rd-123");
          await page.getByLabel("New password", { exact: true }).fill("short");
          await page.getByLabel("Confirm new password").fill("other");
          await page.getByRole("button", { name: "Change password" }).click();
          await page.getByText("This does not match the new password.").waitFor();
          await nameField(page).fill(" ");
          await page.getByRole("button", { name: "Save name" }).click();
          await page.getByText("Enter a display name.").waitFor();
          await audit(page, `${viewport}-${scheme}-${zoom}-errors`, 100);
          expect(await policyViolations(page)).toEqual([]);
          expect(unexpectedConsole(seen)).toEqual([]);
          await context.close();
        });
      }
    }
  }
});
