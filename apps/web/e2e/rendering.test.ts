import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import axe from "axe-core";
import type { Browser, Page } from "playwright-core";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, NativeClient, newContext, signIn, startServer, watch, policyViolations, unexpectedConsole, type RunningServer } from "./harness";

const fixture = loadFixture();
let browser: Browser;
let server: RunningServer;

beforeAll(async () => {
  browser = await launchBrowser();
  server = await startServer({ fixture, extraArguments: ["-login-attempts", "1000"] });
});

afterAll(async () => {
  await browser.close();
  await server.stop();
});

const viewports = { desktop: { width: 1280, height: 900 }, phone: { width: 390, height: 844 } } as const;
const schemes = ["light", "dark"] as const;
const zooms = [100, 200] as const;

type Variant = { viewport: keyof typeof viewports; scheme: (typeof schemes)[number]; zoom: (typeof zooms)[number] };
const variants: Variant[] = [];
for (const viewport of Object.keys(viewports) as (keyof typeof viewports)[]) for (const scheme of schemes) for (const zoom of zooms) variants.push({ viewport, scheme, zoom });

async function enlarge(page: Page, zoom: number) {
  if (zoom === 100) return;
  await page.evaluate((percent) => {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(`html { font-size: ${percent}% !important; }`);
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  }, zoom);
}

async function audit(page: Page, label: string, variant: Variant) {
  await enlarge(page, variant.zoom);
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(artifacts.out(), `render-${label}-${variant.viewport}-${variant.scheme}-${variant.zoom}.png`), fullPage: true });
  await page.evaluate(axe.source);
  const results = await page.evaluate(async () => {
    const found = await (window as unknown as { axe: { run: (context?: unknown, options?: unknown) => Promise<{ violations: { id: string; impact: string; nodes: { target: string[] }[] }[] }> } }).axe.run(document, { resultTypes: ["violations"] });
    return found.violations.map((violation) => `${violation.id} (${violation.impact}): ${violation.nodes.map((node) => node.target.join(" ")).join(", ")}`);
  });
  expect(results, `${label} ${JSON.stringify(variant)}`).toEqual([]);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow, `${label} ${JSON.stringify(variant)} horizontal overflow`).toBeLessThanOrEqual(0);
  const small = await page.evaluate(() =>
    [...document.querySelectorAll<HTMLElement>("button, input:not([type=hidden]), select")]
      .filter((element) => element.offsetParent !== null)
      .map((element) => ({ label: element.textContent?.trim() || element.getAttribute("name") || element.tagName, height: element.getBoundingClientRect().height, size: parseFloat(getComputedStyle(element).fontSize), type: element.tagName === "INPUT" || element.tagName === "SELECT" }))
      .filter((entry) => entry.height < 44 || (entry.type && entry.size < 16)),
  );
  expect(small, `${label} ${JSON.stringify(variant)} targets and control text`).toEqual([]);
}

async function page(variant: Variant) {
  const context = await newContext(browser, { colorScheme: variant.scheme, viewport: viewports[variant.viewport] });
  const opened = await context.newPage();
  const seen = await watch(opened);
  return { context, page: opened, seen };
}

describe("rendered pages in light and dark, on desktop and phone, at 100% and 200% text, with axe", () => {
  for (const variant of variants) {
    test(`sign-in, its failure state, Library and details: ${JSON.stringify(variant)}`, async () => {
      const { context, page: view, seen } = await page(variant);
      await view.goto(`${server.origin}/preview/library`);
      await view.getByLabel("Username").waitFor();
      await audit(view, "signin", variant);
      await signIn(view, "browser_member", "wrong-password-for-render");
      await view.getByRole("alert").waitFor();
      await audit(view, "signin-error", variant);
      await view.getByLabel("Password", { exact: true }).fill(fixture.passwords["browser_member"] ?? "");
      await view.getByRole("button", { name: "Sign in" }).click();
      await view.locator(".book-card").first().waitFor();
      await audit(view, "library", variant);
      await view.locator(".book-card h3 a").first().click();
      await view.getByRole("heading", { level: 1 }).first().waitFor();
      await view.locator(".details").waitFor();
      await audit(view, "details", variant);
      expect(await policyViolations(view)).toEqual([]);
      expect(unexpectedConsole(seen)).toEqual([]);
      await context.close();
    });

    test(`the EPUB reader and the audiobook player: ${JSON.stringify(variant)}`, async () => {
      const { context, page: view, seen } = await page(variant);
      await view.goto(`${server.origin}/preview/library/${fixture.readerBooks.manga}/read`);
      await signIn(view, "browser_member", fixture.passwords["browser_member"] ?? "");
      await view.locator(".epub-location").filter({ hasText: /^Page \d+ of \d+ · Chapter \d+$/ }).waitFor({ timeout: 30_000 });
      await audit(view, "reader", variant);
      await view.goto(`${server.origin}/preview/library/${fixture.readerBooks.audio}/read`);
      await view.getByText("Paused").waitFor({ timeout: 20_000 });
      await audit(view, "player", variant);
      expect(await policyViolations(view)).toEqual([]);
      expect(unexpectedConsole(seen)).toEqual([]);
      await context.close();
    });

    test(`every consent state: ${JSON.stringify(variant)}`, async () => {
      const own = await startServer({ fixture, extraArguments: ["-login-attempts", "1000"] });
      const native = new NativeClient(own.origin);
      const { context, page: view } = await page(variant);
      const base = await native.requestGrant("Synthetic Pixel (render)");
      await view.goto(base.verification_uri_complete);
      await view.getByLabel("Username").waitFor();
      await signIn(view, "browser_member", fixture.passwords["browser_member"] ?? "");
      await view.getByRole("button", { name: "Connect app" }).waitFor();
      await audit(view, "consent-base", variant);
      const bundle = await native.requestGrant("Synthetic Tablet with a deliberately long application name to wrap", "library:read progress:write search:read requests:read requests:write");
      await view.goto(bundle.verification_uri_complete);
      await view.getByRole("button", { name: "Connect and allow requesting" }).waitFor();
      await audit(view, "consent-requesting", variant);
      await view.goto(`${own.origin}/consumer/connect`);
      await view.getByLabel("Connection code").waitFor();
      await audit(view, "consent-entry", variant);
      await view.getByLabel("Connection code").fill("zzzz-zzzz");
      await view.getByRole("button", { name: "Check code" }).click();
      await view.getByRole("heading", { name: "This code cannot be used" }).waitFor();
      await audit(view, "consent-invalid", variant);
      await view.goto(base.verification_uri_complete);
      await view.getByRole("button", { name: "Connect app" }).click();
      await view.getByRole("heading", { name: "App connected" }).waitFor();
      await audit(view, "consent-done", variant);
      await context.close();
      await own.stop();
    });
  }
});

describe("keyboard use", () => {
  test("Tab and Shift+Tab walk the sign-in form in reading order with a visible focus ring, Space toggles the password, Enter submits", async () => {
    const { context, page: view } = await page({ viewport: "desktop", scheme: "light", zoom: 100 });
    await view.goto(`${server.origin}/preview/library`);
    await view.getByLabel("Username").waitFor();
    const order: string[] = [];
    const record = async () => order.push(await view.evaluate(() => `${document.activeElement?.tagName}:${document.activeElement?.getAttribute("name") ?? document.activeElement?.getAttribute("aria-label") ?? document.activeElement?.textContent}`));
    await view.keyboard.press("Tab");
    await record();
    expect(order[0]).toMatch(/^A:|^INPUT:username/);
    await view.getByLabel("Username").focus();
    for (let step = 0; step < 3; step += 1) {
      await view.keyboard.press("Tab");
      await record();
    }
    expect(order.slice(-3)).toEqual(["INPUT:password", "BUTTON:Show password", "BUTTON:Sign in"]);
    const ring = await view.evaluate(() => {
      const style = getComputedStyle(document.activeElement as Element);
      return { style: style.outlineStyle, width: parseFloat(style.outlineWidth) };
    });
    expect(ring.style).not.toBe("none");
    expect(ring.width).toBeGreaterThanOrEqual(2);
    await view.keyboard.press("Shift+Tab");
    await view.keyboard.press("Space");
    expect(await view.getByLabel("Password", { exact: true }).getAttribute("type")).toBe("text");
    expect(await view.getByRole("button", { name: "Show password" }).getAttribute("aria-pressed")).toBe("true");
    await view.getByLabel("Username").fill("browser_member");
    await view.getByLabel("Password", { exact: true }).fill(fixture.passwords["browser_member"] ?? "");
    await view.keyboard.press("Enter");
    await view.locator(".book-card").first().waitFor();
    await context.close();
  });

  test("the reader's controls are reached by Tab in reading order and operated by Enter, Space and arrows", async () => {
    const { context, page: view } = await page({ viewport: "desktop", scheme: "light", zoom: 100 });
    await view.goto(`${server.origin}/preview/library/${fixture.readerBooks.text}/read`);
    await signIn(view, "browser_member", fixture.passwords["browser_member"] ?? "");
    await view.locator(".epub-location").filter({ hasText: /^Page 1 of \d+ · Chapter 1$/ }).waitFor({ timeout: 30_000 });
    const stops: string[] = [];
    const active = () => view.evaluate(() => {
      const element = document.activeElement;
      if (!element || element === document.body) return "BODY";
      const label = element.getAttribute("aria-label") ?? (element.id ? document.querySelector(`label[for="${element.id}"]`)?.textContent : null) ?? element.closest("label")?.querySelector("span")?.textContent ?? element.textContent;
      return `${element.tagName}:${(label ?? "").replace(/\s+/g, " ").trim()}`;
    });
    await view.keyboard.press("Tab");
    stops.push(await active());
    for (let step = 0; step < 6; step += 1) {
      await view.keyboard.press("Tab");
      stops.push(await active());
    }
    expect(stops).toEqual(["A:←Back to the book", "SELECT:Chapter", "BUTTON:Smaller", "BUTTON:Larger", "IFRAME:", "BUTTON:← Previous page", "BUTTON:Next page →"]);
    const ring = await view.evaluate(() => getComputedStyle(document.activeElement as Element).outlineStyle);
    expect(ring).not.toBe("none");
    await view.keyboard.press("Enter");
    await view.locator(".epub-location").filter({ hasText: /^Page 2 of \d+ · Chapter 1$/ }).waitFor();
    await view.keyboard.press("Space");
    await view.locator(".epub-location").filter({ hasText: /^Page 3 of \d+ · Chapter 1$/ }).waitFor();
    await view.keyboard.press("Shift+Tab");
    expect(await active()).toBe("BUTTON:← Previous page");
    await view.keyboard.press("ArrowLeft");
    await view.locator(".epub-location").filter({ hasText: /^Page 2 of \d+ · Chapter 1$/ }).waitFor();
    await context.close();
  });

  test("the consent buttons are reachable and operable by keyboard only", async () => {
    const native = new NativeClient(server.origin);
    const grant = await native.requestGrant("Keyboard check");
    const { context, page: view } = await page({ viewport: "desktop", scheme: "light", zoom: 100 });
    await view.goto(grant.verification_uri_complete);
    await view.getByLabel("Username").fill("browser_member");
    await view.getByLabel("Password", { exact: true }).fill(fixture.passwords["browser_member"] ?? "");
    await view.keyboard.press("Enter");
    await view.getByRole("button", { name: "Connect app" }).waitFor();
    expect(await view.evaluate(() => document.activeElement?.tagName)).toBe("H1");
    await view.keyboard.press("Tab");
    expect(await view.evaluate(() => document.activeElement?.textContent)).toBe("Connect app");
    await view.keyboard.press("Tab");
    expect(await view.evaluate(() => document.activeElement?.textContent)).toBe("Deny");
    await view.keyboard.press("Shift+Tab");
    await view.keyboard.press("Space");
    await view.getByRole("heading", { name: "App connected" }).waitFor();
    expect(await view.evaluate(() => document.activeElement?.tagName)).toBe("H1");
    await context.close();
  });
});
