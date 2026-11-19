import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import axe from "axe-core";
import type { Browser, Page } from "playwright-core";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, newContext, policyViolations, signIn, startServer, unexpectedConsole, watch, type RunningServer } from "./harness";

const fixture = loadFixture();
const cases = fixture.adminOverview;
const OVERVIEW = "/preview/api/v1/admin/overview";
let browser: Browser;

beforeAll(async () => {
  browser = await launchBrowser();
});

afterAll(async () => {
  await browser.close();
});

const serve = () => startServer({ fixture, extraArguments: ["-login-attempts", "1000"] });

async function open(server: RunningServer, options: { colorScheme?: "light" | "dark"; viewport?: { width: number; height: number } } = {}) {
  const context = await newContext(browser, options);
  const outside: string[] = [];
  context.on("request", (request) => {
    if (new URL(request.url()).origin !== server.origin) outside.push(request.url());
  });
  const page = await context.newPage();
  const seen = await watch(page);
  return { context, page, seen, outside };
}

async function signInAt(page: Page, origin: string, persona: "browser_member" | "browser_admin") {
  await page.goto(`${origin}/preview/admin`);
  await page.getByText("Sign in to see the server overview. You will come straight back to it.").waitFor();
  await signIn(page, persona, fixture.passwords[persona] ?? "");
}

const unchanged = (server: RunningServer) =>
  ["system_healths", "users", "books", "requests", "downloads", "settings", "sessions"].map((table) => `${table}:${JSON.stringify(server.query(`SELECT * FROM "${table}" ORDER BY rowid`))}`).join("\n");

const RAILS_TILE_LABELS: Record<string, string> = { Users: "Users", Books: "Books", "Pending requests": "Requests in progress", "Need attention": "Need attention" };

async function shown(page: Page) {
  return page.evaluate(() => ({
    tiles: [...document.querySelectorAll(".overview-counts > div")].map((tile) => [tile.querySelector("dt")?.textContent ?? "", (tile.querySelector("dd")?.textContent ?? "").replaceAll(",", "")]),
    health: [...document.querySelectorAll(".health-row")].map((row) => ({
      label: row.querySelector(".health-name")?.textContent ?? "",
      status: (row.querySelector(".badge")?.textContent ?? "").replace("⚠", "").trim(),
      checked: row.querySelector(".health-checked")?.textContent ?? "",
    })),
    attention: [...document.querySelectorAll(".attention-list li")].map((item) => (item.textContent ?? "").replace("⚠", "").replace("Review requests", "").trim()),
    build: document.querySelector(".overview-build dd")?.textContent ?? null,
  }));
}

describe("the Go server overview, against the real Rails admin page", () => {
  test("an admin sees Rails' counts and saved health with no stored message, and reaches the attention filter and back", async () => {
    const server = await serve();
    const { context, page, seen, outside } = await open(server);
    const answered = page.waitForResponse((response) => new URL(response.url()).pathname === OVERVIEW);
    await signInAt(page, server.origin, "browser_admin");
    const response = await answered;
    await page.getByRole("heading", { name: "Needs attention", level: 2 }).waitFor();
    const before = unchanged(server);
    expect(response.status()).toBe(200);
    expect(response.headers()["cache-control"]).toBe("private, no-store");
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({ account: String(fixture.users["browser_admin"]), counts: cases.counts, services: cases.services });
    for (const secret of [cases.secret, "hunter2", "10.9.8.7", "overview-secret", "qBittorrent", "writable", "legacy alias", "prowlarr", "message"]) expect(text.includes(secret), secret).toBe(false);
    expect(await page.getByText(cases.secret).count()).toBe(0);

    const view = await shown(page);
    expect(view.build).toBe(fixture.serverVersion);
    expect(view.tiles).toEqual(cases.rails_page.tiles.map(([label, value]) => [RAILS_TILE_LABELS[label ?? ""] ?? `unmapped ${label}`, value ?? ""]));
    expect(view.health.map((row) => row.label)).toEqual(cases.rails_page.health.map((row) => row.label));
    expect(view.health.map((row) => row.status)).toEqual(cases.rails_page.health.map((row) => (row.status === "Not checked" ? "Never checked" : row.status)));
    expect(view.health.map((row) => (row.checked.startsWith("Checked ") ? "Checked" : row.checked))).toEqual(
      cases.rails_page.health.map((row) => (row.status === "Not checked" ? "" : row.checked.startsWith("Checked ") ? "Checked" : row.checked)),
    );
    expect(view.attention).toEqual(cases.rails_page.attention);
    const primary = page.getByRole("navigation", { name: "Primary" });
    expect(await primary.getByRole("link").allTextContents()).toEqual(["Library", "Discover", "Requests", "Account", "Admin"]);
    expect(await primary.getByRole("link", { name: "Admin" }).getAttribute("aria-current")).toBe("page");

    await page.reload();
    await page.getByRole("heading", { name: "Needs attention", level: 2 }).waitFor();
    expect(await shown(page)).toEqual(view);

    const review = page.getByRole("link", { name: "Review requests" });
    await review.focus();
    await page.keyboard.press("Enter");
    await page.waitForURL(`${server.origin}/preview/requests?attention=true`);
    await page.getByRole("heading", { name: "All Requests", level: 1 }).waitFor();
    expect(await page.getByRole("link", { name: /Need Attention/ }).getAttribute("aria-current")).toBe("page");
    await page.goBack();
    await page.getByRole("heading", { name: "Server overview", level: 1 }).waitFor();
    await page.getByRole("heading", { name: "Needs attention", level: 2 }).waitFor();
    expect(unchanged(server)).toBe(before);
    expect(outside).toEqual([]);
    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("a member, an anonymous caller and a wrong account receive no overview, as Rails refuses a member", async () => {
    expect(cases.rails_member_status).toBe(302);
    const server = await serve();
    const anonymous = await fetch(`${server.origin}${OVERVIEW}`, { headers: { "X-Shelfarr-Account": String(fixture.users["browser_admin"]) } });
    expect([anonymous.status, await anonymous.text(), anonymous.headers.get("cache-control")]).toEqual([401, '{"error":"signed_out"}', "private, no-store"]);
    const { context, page, seen } = await open(server);
    const asked: string[] = [];
    page.on("request", (request) => {
      if (new URL(request.url()).pathname === OVERVIEW) asked.push(request.url());
    });
    await signInAt(page, server.origin, "browser_member");
    await page.getByRole("heading", { name: "Only administrators can see this page", level: 2 }).waitFor();
    expect(await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Admin" }).count()).toBe(0);
    expect(asked).toEqual([]);
    const member = String(fixture.users["browser_member"]);
    const direct = await page.request.get(`${server.origin}${OVERVIEW}`, { headers: { "X-Shelfarr-Account": member } });
    expect([direct.status(), await direct.text(), direct.headers()["cache-control"]]).toEqual([404, '{"error":"not_found"}', "private, no-store"]);
    const wrong = await page.request.get(`${server.origin}${OVERVIEW}`, { headers: { "X-Shelfarr-Account": String(fixture.users["browser_admin"]) } });
    expect([wrong.status(), await wrong.text()]).toEqual([401, '{"error":"account_changed"}']);
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("an admin demoted while the overview is open is locked out on focus and the counts are gone", async () => {
    const server = await serve();
    const { context, page, seen } = await open(server);
    await signInAt(page, server.origin, "browser_admin");
    await page.getByRole("heading", { name: "Needs attention", level: 2 }).waitFor();
    const admin = fixture.users["browser_admin"] ?? 0;
    server.execute("UPDATE users SET role = 0 WHERE id = ?", admin);
    const direct = await page.request.get(`${server.origin}${OVERVIEW}`, { headers: { "X-Shelfarr-Account": String(admin) } });
    expect([direct.status(), await direct.text()]).toEqual([404, '{"error":"not_found"}']);
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await page.getByRole("heading", { name: "This account's access changed", level: 1 }).waitFor();
    expect(await page.locator(".overview-counts, .health-list").count()).toBe(0);
    await page.getByRole("button", { name: "Continue as the current account" }).click();
    await page.getByRole("heading", { name: "Only administrators can see this page", level: 2 }).waitFor();
    expect(await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Admin" }).count()).toBe(0);
    expect(unexpectedConsole(seen)).toEqual([]);
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
  await page.screenshot({ path: join(artifacts.out(), `admin-${label}.png`), fullPage: true });
  await page.evaluate(axe.source);
  const violations = await page.evaluate(async () => {
    const found = await (window as unknown as { axe: { run: (context?: unknown, options?: unknown) => Promise<{ violations: { id: string; impact: string; nodes: { target: string[] }[] }[] }> } }).axe.run(document, { resultTypes: ["violations"] });
    return found.violations.map((violation) => `${violation.id} (${violation.impact}): ${violation.nodes.map((node) => node.target.join(" ")).join(", ")}`);
  });
  expect(violations, label).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), `${label} overflow`).toBeLessThanOrEqual(0);
  const small = await page.evaluate(() =>
    [...document.querySelectorAll<HTMLElement>("main button, main a")]
      .filter((element) => element.offsetParent !== null)
      .map((element) => ({ label: element.textContent?.trim() || element.tagName, height: element.getBoundingClientRect().height }))
      .filter((entry) => entry.height < 44),
  );
  expect(small, `${label} targets`).toEqual([]);
}

describe("the server overview renders accessibly", () => {
  let server: RunningServer;
  beforeAll(async () => {
    server = await serve();
  });
  afterAll(async () => {
    await server.stop();
  });
  for (const viewport of Object.keys(viewports) as (keyof typeof viewports)[]) {
    for (const scheme of ["light", "dark"] as const) {
      for (const zoom of [100, 200]) {
        if (viewport === "narrow" && zoom === 100) continue;
        test(`${viewport} ${scheme} ${zoom}%`, async () => {
          const { context, page, seen } = await open(server, { colorScheme: scheme, viewport: viewports[viewport] });
          await signInAt(page, server.origin, "browser_admin");
          await page.getByRole("heading", { name: "Needs attention", level: 2 }).waitFor();
          await audit(page, `${viewport}-${scheme}-${zoom}`, zoom);
          expect(await policyViolations(page)).toEqual([]);
          expect(unexpectedConsole(seen)).toEqual([]);
          await context.close();
        });
      }
    }
  }
});
