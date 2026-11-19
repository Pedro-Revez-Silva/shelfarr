import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import axe from "axe-core";
import type { Browser, Page } from "playwright-core";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, newContext, policyViolations, signIn, startServer, unexpectedConsole, watch, type RailsRequestPage, type RunningServer } from "./harness";

const fixture = loadFixture();
const cases = fixture.requests;
const ids = cases.ids;
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

async function signInAt(page: Page, origin: string, persona: "browser_member" | "browser_admin", path = "/preview/requests") {
  await page.goto(`${origin}${path}`);
  await page.getByText("Sign in to see your requests. You will come straight back to them.").waitFor();
  await signIn(page, persona, fixture.passwords[persona] ?? "");
}

const writes = (server: RunningServer) =>
  ["requests", "downloads", "books", "users", "request_events", "consumer_progresses", "consumer_reading_states"]
    .map((table) => `${table}:${JSON.stringify(server.query(`SELECT * FROM "${table}" ORDER BY rowid`))}`)
    .join("\n");

function addressOf(query: Record<string, string>) {
  const search = new URLSearchParams(query).toString();
  return `/preview/requests${search ? `?${search}` : ""}`;
}

async function shown(page: Page) {
  return page.evaluate(() =>
    [...document.querySelectorAll(".request-card")].map((card) => ({
      title: card.querySelector("h3")?.textContent ?? "",
      id: Number(card.querySelector<HTMLAnchorElement>("h3 a")?.pathname.split("/").at(-1)),
      labels: [...card.querySelectorAll(".request-badges li")].map((badge) => (badge.textContent ?? "").replace("⚠", "").trim()),
      requested_by: [...card.querySelectorAll(".request-meta span")].map((span) => span.textContent ?? "").find((text) => text.startsWith("Requested by ")) ?? null,
    })),
  );
}

async function filters(page: Page) {
  return page.evaluate(() => [...document.querySelectorAll("nav[aria-label='Request filters'] a")].map((link) => ({ label: (link.textContent ?? "").replace(/\s+/g, " ").trim(), current: link.getAttribute("aria-current") === "page" })));
}

async function compareWithRails(page: Page, origin: string, rails: RailsRequestPage, scope: "own" | "all") {
  const answered = page.waitForResponse((response) => new URL(response.url()).pathname === "/preview/api/v1/requests");
  await page.goto(`${origin}${addressOf(rails.query)}`);
  const response = await answered;
  expect(response.status()).toBe(200);
  expect(response.headers()["cache-control"]).toBe("private, no-store");
  const text = await response.text();
  const body = JSON.parse(text);
  expect(body.scope).toBe(scope);
  for (const secret of ["hunter2", "10.1.2.3", "RELEASE", "client-hash", "/downloads", fixture.libraryRoots[0] ?? "/never", "Failed to connect", "password"]) expect(text.includes(secret), `${secret} in ${JSON.stringify(rails.query)}`).toBe(false);
  if (scope === "own") expect(text.includes("requested_by")).toBe(false);
  await page.locator(".request-list, .state--empty").first().waitFor();
  expect(await shown(page), JSON.stringify(rails.query)).toEqual(rails.cards.map((card) => ({ ...card, requested_by: card.requested_by })));
  expect(await filters(page), JSON.stringify(rails.query)).toEqual(rails.filters);
  if (rails.pagination) expect(await page.locator(".pagination p").textContent()).toBe(rails.pagination);
  else expect(await page.locator(".pagination").count()).toBe(0);
}

describe("Requests in the Go preview, against Rails-created requests", () => {
  test("a member sees exactly the requests and tabs Rails shows them for every filter, search and page, and nothing of other accounts", async () => {
    const server = await serve();
    const { context, page, seen, outside } = await open(server);
    await signInAt(page, server.origin, "browser_member");
    await page.getByRole("heading", { name: "My Requests", level: 1 }).waitFor();
    const before = writes(server);
    for (const rails of cases.rails_pages.browser_member) await compareWithRails(page, server.origin, rails, "own");
    for (const [key, status] of Object.entries(cases.rails_show_status.browser_member)) {
      const response = await page.request.get(`${server.origin}/preview/api/v1/requests/${ids[key]}`, { headers: { "X-Shelfarr-Account": String(fixture.users["browser_member"]) } });
      expect([key, response.status()]).toEqual([key, status]);
      if (status === 404) expect(await response.text()).toBe('{"error":"not_found"}');
    }
    await page.goto(`${server.origin}/preview/requests/${ids["other_owner"]}`);
    await page.getByRole("heading", { name: "This request is not available", level: 1 }).waitFor();
    expect(await page.getByText("Request Other Owner Secret").count()).toBe(0);
    expect(writes(server)).toBe(before);
    expect(outside.filter((url) => url !== "https://covers.example.test/harbor.jpg")).toEqual([]);
    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("an admin sees every request with who asked, Rails' counts and both pages", async () => {
    const server = await serve();
    const { context, page, seen } = await open(server);
    await signInAt(page, server.origin, "browser_admin");
    await page.getByRole("heading", { name: "All Requests", level: 1 }).waitFor();
    const before = writes(server);
    for (const rails of cases.rails_pages.browser_admin) await compareWithRails(page, server.origin, rails, "all");
    for (const [key, status] of Object.entries(cases.rails_show_status.browser_admin)) {
      const response = await page.request.get(`${server.origin}/preview/api/v1/requests/${ids[key]}`, { headers: { "X-Shelfarr-Account": String(fixture.users["browser_admin"]) } });
      expect([key, response.status()]).toEqual([key, status]);
    }
    await page.goto(`${server.origin}/preview/requests/${ids["other_owner"]}`);
    await page.getByRole("heading", { name: "Request Other Owner Secret", level: 1 }).waitFor();
    expect(await page.getByText("Requested by").locator("xpath=following-sibling::dd").textContent()).toBe("Alice Reader");
    expect(writes(server)).toBe(before);
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("statuses, progress and attention match what Rails knows, and only a copy the Library opens is linked and opens", async () => {
    const server = await serve();
    const { context, page, seen } = await open(server);
    await signInAt(page, server.origin, "browser_member", `/preview/requests/${ids["downloading"]}`);
    const native = Object.fromEntries(cases.rails_native_view.map((view) => [view.id, view]));
    expect(native[String(ids["downloading"])]?.download_percent).toBe(37);
    await page.getByText("Downloading: 37% so far.").waitFor();
    expect(await page.getByRole("progressbar", { name: "Download progress" }).getAttribute("value")).toBe("37");
    expect(await page.locator(".request-downloads li").allTextContents()).toEqual(["Failed", "Downloading37%"]);

    await page.goto(`${server.origin}/preview/requests/${ids["searching_attention"]}`);
    await page.getByRole("heading", { name: "Attention Required", level: 2 }).waitFor();
    await page.getByText(cases.issues.listed).waitFor();

    await page.goto(`${server.origin}/preview/requests/${ids["not_found_attention"]}`);
    await page.getByText("This request needs your attention.").waitFor();
    expect(await page.getByText(/hunter2|10\.1\.2\.3|Failed to connect/).count()).toBe(0);
    await page.getByText(/^Nothing suitable was found yet\. Shelfarr will search again in /).waitFor();
    await page.getByText("Next retry").waitFor();

    await page.goto(`${server.origin}/preview/requests/${ids["completed_missing"]}`);
    await page.getByText("Completed. Shelfarr has its files, but the Library here cannot open them right now.").waitFor();
    expect(await page.getByRole("link", { name: "Open in Library" }).count()).toBe(0);
    expect(native[String(ids["completed_missing"])]?.stage).toBe("available");

    await page.goto(`${server.origin}/preview/requests/${ids["completed"]}`);
    expect(native[String(ids["completed"])]?.publication_id).toBe(String(fixture.readerBooks.audio));
    await page.getByText("Completed and in the library.").waitFor();
    await page.getByRole("link", { name: "Open in Library" }).click();
    await page.getByRole("heading", { name: "Reader Spoken Sampler", level: 1 }).waitFor();
    expect(new URL(page.url()).pathname).toBe(`/preview/library/${fixture.readerBooks.audio}`);
    await page.getByRole("link", { name: /^Start listening/ }).waitFor();
    expect(unexpectedConsole(seen)).toEqual([]);
    await context.close();
    await server.stop();
  });

  test("the address keeps the tab, search and page through direct loads, reloads, Back and Forward", async () => {
    const server = await serve();
    const { context, page } = await open(server);
    await signInAt(page, server.origin, "browser_admin", "/preview/requests?status=active&q=harbor");
    await page.getByRole("heading", { name: "Request Harbor Download", level: 3 }).waitFor();
    expect(await page.getByRole("searchbox", { name: "Search requests by title or author" }).inputValue()).toBe("harbor");
    await page.reload();
    await page.getByRole("heading", { name: "Request Harbor Download", level: 3 }).waitFor();
    await page.getByRole("button", { name: "Clear" }).click();
    await page.getByRole("status").filter({ hasText: "28 requests · Page 1 of 2" }).waitFor();
    expect(new URL(page.url()).search).toBe("?status=active");
    await page.getByRole("link", { name: "Next page" }).click();
    await page.getByRole("status").filter({ hasText: "28 requests · Page 2 of 2" }).waitFor();
    expect(new URL(page.url()).search).toBe("?status=active&page=2");
    await page.getByRole("link", { name: "Queue Filler 21" }).click();
    await page.getByRole("heading", { name: "Queue Filler 21", level: 1 }).waitFor();
    await page.getByRole("button", { name: "Back to Requests" }).click();
    await page.getByRole("status").filter({ hasText: "28 requests · Page 2 of 2" }).waitFor();
    expect(new URL(page.url()).search).toBe("?status=active&page=2");
    await page.goBack();
    await page.getByRole("status").filter({ hasText: "28 requests · Page 1 of 2" }).waitFor();
    await page.goBack();
    await page.getByRole("heading", { name: "Request Harbor Download", level: 3 }).waitFor();
    expect(new URL(page.url()).search).toBe("?status=active&q=harbor");
    await page.goForward();
    await page.getByRole("status").filter({ hasText: "28 requests · Page 1 of 2" }).waitFor();
    await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Library" }).click();
    await page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Requests" }).click();
    await page.getByRole("heading", { name: "All Requests", level: 1 }).waitFor();
    expect(new URL(page.url()).search).toBe("");
    await context.close();
    await server.stop();
  });

  test("another tab switching account locks the open requests", async () => {
    const server = await serve();
    const { context, page } = await open(server);
    await signInAt(page, server.origin, "browser_admin");
    await page.getByRole("heading", { name: "Request Other Owner Secret", level: 3 }).waitFor();
    const other = await context.newPage();
    await other.goto(`${server.origin}/preview/library`);
    await other.getByRole("button", { name: "Sign out" }).click();
    await signIn(other, "browser_member", fixture.passwords["browser_member"] ?? "");
    await other.getByRole("heading", { name: "Library", level: 1 }).waitFor();
    await page.bringToFront();
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await page.getByRole("heading", { name: "The signed-in account changed" }).waitFor();
    expect(await page.getByText("Request Other Owner Secret").count()).toBe(0);
    await context.close();
    await server.stop();
  });

  test("the keyboard reaches the tabs, the search, each request and its library link in reading order", async () => {
    const server = await serve();
    const { context, page } = await open(server);
    await signInAt(page, server.origin, "browser_member", "/preview/requests?status=completed");
    await page.getByRole("heading", { name: "Reader Spoken Sampler", level: 3 }).waitFor();
    await page.getByRole("link", { name: "All", exact: true }).focus();
    const order: string[] = [];
    for (let step = 0; step < 11; step += 1) {
      order.push(await page.evaluate(() => `${document.activeElement?.tagName}:${document.activeElement?.textContent?.replace(/\s+/g, " ").trim()}`));
      await page.keyboard.press("Tab");
    }
    expect(order).toEqual([
      "A:All",
      "A:Need Attention 2",
      "A:Active 4",
      "A:Store Offers",
      "A:Completed",
      "A:Not Found",
      "A:Cancelled",
      "INPUT:",
      "BUTTON:Search",
      "A:Reader Spoken Sampler",
      "A:Open in Library for Reader Spoken Sampler",
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
  await page.screenshot({ path: join(artifacts.out(), `requests-${label}.png`), fullPage: true });
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

describe("the Requests pages render accessibly", () => {
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
          await page.getByRole("heading", { name: "Request Harbor Download", level: 3 }).waitFor();
          await audit(page, `${viewport}-${scheme}-${zoom}-list`, zoom);
          await page.goto(`${server.origin}/preview/requests/${ids["downloading"]}`);
          await page.getByText("Downloading: 37% so far.").waitFor();
          await audit(page, `${viewport}-${scheme}-${zoom}-downloading`, zoom);
          await page.goto(`${server.origin}/preview/requests/${ids["not_found_attention"]}`);
          await page.getByRole("heading", { name: "Attention Required", level: 2 }).waitFor();
          await audit(page, `${viewport}-${scheme}-${zoom}-attention`, zoom);
          await page.goto(`${server.origin}/preview/requests?q=nothing+like+this`);
          await page.getByRole("heading", { name: "No matching requests", level: 2 }).waitFor();
          await audit(page, `${viewport}-${scheme}-${zoom}-empty`, zoom);
          expect(await policyViolations(page)).toEqual([]);
          expect(unexpectedConsole(seen)).toEqual([]);
          await context.close();
        });
      }
    }
  }
});
