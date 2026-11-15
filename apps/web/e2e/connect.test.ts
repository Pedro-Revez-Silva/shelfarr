import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import type { Browser, Page } from "playwright-core";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, NativeClient, openAs, policyViolations, signIn, startServer, unexpectedConsole, type RunningServer } from "./harness";

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

const memberPassword = () => fixture.passwords["browser_member"] ?? "";
const adminPassword = () => fixture.passwords["browser_admin"] ?? "";
const memberId = fixture.users["browser_member"] ?? 0;
const wait = (seconds: number) => Bun.sleep(seconds * 1000 + 250);

function grants() {
  return server.query<{ id: number; user_id: number | null; approved_at: string | null; denied_at: string | null; consumed_at: string | null; scopes: string | null; replaces_api_token_id: number | null }>(
    "SELECT id, user_id, CAST(approved_at AS TEXT) AS approved_at, CAST(denied_at AS TEXT) AS denied_at, CAST(consumed_at AS TEXT) AS consumed_at, scopes, replaces_api_token_id FROM consumer_device_grants ORDER BY id",
  );
}

async function signInOnConnect(page: Page, username: string, password: string) {
  await page.getByLabel("Username").waitFor();
  await signIn(page, username, password);
}

async function firstEbook(token: string) {
  const native = new NativeClient(server.origin);
  const library = await native.request("/api/consumer/v1/library?type=ebook&limit=50", { token });
  const item = (library.body["items"] as { id: string; assets: { id: string }[] }[]).find((candidate) => candidate.assets.length > 0);
  return { id: item?.id ?? "", asset: item?.assets[0]?.id ?? "" };
}

describe("the native app connection flow through the real browser", () => {
  test("request a grant over HTTP, open its verification address, sign in, inspect, allow once, then the app polls, authenticates and saves a checkpoint", async () => {
    const native = new NativeClient(server.origin);
    const grant = await native.requestGrant("Synthetic Pixel (e2e)");
    expect(grant.verification_uri).toBe(`${server.origin}/consumer/connect`);
    expect(grant.verification_uri_complete).toBe(`${server.origin}/consumer/connect?user_code=${grant.user_code}`);
    expect((await native.poll(grant.device_code)).body).toEqual({ error: "authorization_pending" });

    const { context, page, seen } = await openAs(browser, server);
    const decisions: string[] = [];
    page.on("request", (request) => {
      if (request.method() === "POST" && request.url().endsWith("/preview/api/v1/connect")) decisions.push(request.postData() ?? "");
    });
    await page.goto(grant.verification_uri_complete);
    await signInOnConnect(page, "browser_member", memberPassword());
    await page.getByRole("heading", { name: "Connect your Shelfarr app", level: 1 }).waitFor();
    expect(await page.title()).toBe("Connect your Shelfarr app · Shelfarr");
    expect(page.url()).toBe(grant.verification_uri_complete);
    const text = await page.locator("main").innerText();
    expect(text).toContain("Synthetic Pixel (e2e)");
    expect(text).toContain(grant.user_code);
    expect(text).toContain("Browse and download your library.");
    expect(text).toContain("Save your reading and listening progress.");
    expect(text).not.toContain("request ebooks");
    await page.screenshot({ path: join(artifacts.out(), "consent-base.png") });

    await page.reload();
    await page.getByRole("button", { name: "Connect app" }).waitFor();
    expect(grants().filter((row) => row.approved_at !== null || row.denied_at !== null)).toHaveLength(0);
    await wait(grant.interval);
    expect((await native.poll(grant.device_code)).body).toEqual({ error: "authorization_pending" });

    const allow = page.getByRole("button", { name: "Connect app" });
    await allow.dblclick();
    await page.keyboard.press("Enter");
    await page.getByRole("heading", { name: "App connected", level: 1 }).waitFor();
    expect(decisions).toHaveLength(1);
    expect(JSON.parse(decisions[0] ?? "{}")).toEqual({ user_code: grant.user_code, decision: "allow" });
    expect(page.url()).toBe(`${server.origin}/consumer/connect`);
    await page.screenshot({ path: join(artifacts.out(), "consent-allowed.png") });
    const row = grants().find((candidate) => candidate.user_id === memberId && candidate.approved_at !== null);
    expect(row?.denied_at).toBeNull();

    await wait(grant.interval);
    const issued = await native.poll(grant.device_code);
    expect(issued.status).toBe(200);
    const token = String(issued.body["access_token"]);
    expect(String(issued.body["scope"]).split(" ").sort()).toEqual(["library:read", "progress:write"]);
    expect(token).toMatch(/^shf_/);
    expect(await page.content()).not.toContain(token);
    expect(JSON.stringify(seen)).not.toContain(token);
    expect(JSON.stringify(seen)).not.toContain(grant.device_code);

    const me = await native.request("/api/consumer/v1/me", { token });
    expect(me.status).toBe(200);
    expect(me.body["id"]).toBe(String(memberId));
    const { id, asset } = await firstEbook(token);
    const saved = await native.request(`/api/consumer/v1/library/${id}/progress`, {
      method: "PUT",
      token,
      body: { asset_id: asset, expected_version: 0, client_mutation_id: crypto.randomUUID(), locator: { href: "OEBPS/chapter.xhtml", locations: { progression: 0.4, totalProgression: 0.4, position: 3 } } },
    });
    expect(saved.status, JSON.stringify(saved.body)).toBe(200);
    const read = await native.request(`/api/consumer/v1/library/${id}/progress`, { token });
    expect((read.body["progress"] as { version: number }).version).toBe(1);
    expect(server.query("SELECT id FROM consumer_progresses WHERE user_id = ? AND book_id = ?", memberId, Number(id))).toHaveLength(1);

    expect(await policyViolations(page)).toEqual([]);
    expect(unexpectedConsole(seen)).toEqual([]);
    const reused = await native.poll(grant.device_code);
    expect(reused.body["error"]).toBe("expired_token");
    await context.close();
  });

  test("Not now is a real decision: the app is told it was denied and no token exists", async () => {
    const native = new NativeClient(server.origin);
    const grant = await native.requestGrant("Synthetic Tablet (e2e)");
    const { context, page } = await openAs(browser, server);
    await page.goto(grant.verification_uri_complete);
    await signInOnConnect(page, "browser_member", memberPassword());
    await page.getByRole("button", { name: "Deny" }).click();
    await page.getByRole("heading", { name: "Connection denied", level: 1 }).waitFor();
    await wait(grant.interval);
    expect((await native.poll(grant.device_code)).body).toEqual({ error: "access_denied" });
    await context.close();
  });

  test("an upgrade, a wrong account that learns nothing, a safe switch and Not now that keeps the old access", async () => {
    const native = new NativeClient(server.origin);
    const first = await native.requestGrant("Synthetic Phone (e2e)");
    const { context, page } = await openAs(browser, server);
    await page.goto(first.verification_uri_complete);
    await signInOnConnect(page, "browser_member", memberPassword());
    await page.getByRole("button", { name: "Connect app" }).click();
    await page.getByRole("heading", { name: "App connected" }).waitFor();
    await wait(first.interval);
    const base = await native.poll(first.device_code);
    const baseToken = String(base.body["access_token"]);

    const upgrade = await native.requestGrant("Synthetic Phone (e2e)", "library:read progress:write search:read requests:read requests:write", baseToken);
    const other = await openAs(browser, server);
    await other.page.goto(upgrade.verification_uri_complete);
    await signInOnConnect(other.page, "browser_admin", adminPassword());
    await other.page.getByRole("heading", { name: "Different account", level: 1 }).waitFor();
    const wrong = await other.page.locator("main").innerText();
    expect(wrong).not.toContain("Synthetic Phone");
    expect(wrong).not.toContain("requests:write");
    expect(await other.page.getByRole("button", { name: /Allow|Deny|Not now|Connect/ }).count()).toBe(0);
    const pending = grants().find((row) => row.replaces_api_token_id !== null);
    expect(pending?.approved_at).toBeNull();
    expect(pending?.denied_at).toBeNull();
    await other.page.screenshot({ path: join(artifacts.out(), "consent-wrong-account.png") });

    await other.page.getByRole("button", { name: "Sign out and switch account" }).click();
    await signInOnConnect(other.page, "browser_member", memberPassword());
    await other.page.getByRole("heading", { name: "Allow requesting from your app", level: 1 }).waitFor();
    const consent = await other.page.locator("main").innerText();
    expect(consent).toContain("already connected as");
    expect(consent).toContain("Request ebooks and audiobooks for you.");
    expect(consent).toContain("If you choose Not now, the app keeps its current read-and-listen access.");
    await other.page.screenshot({ path: join(artifacts.out(), "consent-upgrade.png") });
    await other.page.getByRole("button", { name: "Not now" }).click();
    await other.page.getByRole("heading", { name: "Requesting not allowed" }).waitFor();
    expect((await native.request("/api/consumer/v1/me", { token: baseToken })).status).toBe(200);
    await wait(upgrade.interval);
    expect((await native.poll(upgrade.device_code)).body).toEqual({ error: "access_denied" });

    const again = await native.requestGrant("Synthetic Phone (e2e)", "library:read progress:write search:read requests:read requests:write", baseToken);
    await other.page.goto(again.verification_uri_complete);
    await other.page.getByRole("button", { name: "Allow requesting" }).click();
    await other.page.getByRole("heading", { name: "Requesting allowed" }).waitFor();
    await wait(again.interval);
    const upgraded = await native.poll(again.device_code);
    expect(upgraded.status).toBe(200);
    expect(String(upgraded.body["scope"]).split(" ")).toContain("requests:write");
    expect((await native.request("/api/consumer/v1/me", { token: String(upgraded.body["access_token"]) })).status).toBe(200);
    expect((await native.request("/api/consumer/v1/me", { token: baseToken })).status).toBe(401);
    await other.context.close();
    await context.close();
  });

  test("a code that expired or was already used is a clear terminal state and nothing can be approved", async () => {
    const native = new NativeClient(server.origin);
    const grant = await native.requestGrant("Synthetic Watch (e2e)");
    server.execute("UPDATE consumer_device_grants SET expires_at = '2020-01-01 00:00:00' WHERE user_code_digest IN (SELECT user_code_digest FROM consumer_device_grants ORDER BY id DESC LIMIT 1)");
    const { context, page } = await openAs(browser, server);
    await page.goto(grant.verification_uri_complete);
    await signInOnConnect(page, "browser_member", memberPassword());
    await page.getByRole("heading", { name: "This code cannot be used", level: 1 }).waitFor();
    expect(await page.locator("main").innerText()).toContain("expired or has already been used");
    expect(await page.getByRole("button", { name: /Connect app|Deny/ }).count()).toBe(0);
    await page.getByLabel("Connection code").fill("zzzz-zzzz");
    await page.getByRole("button", { name: "Check code" }).click();
    await page.getByRole("heading", { name: "This code cannot be used" }).waitFor();
    await page.screenshot({ path: join(artifacts.out(), "consent-expired.png") });
    expect(grants().at(-1)?.approved_at).toBeNull();
    await context.close();
  });

  test("an uncertain answer to Allow is never resent; the account only re-checks the status", async () => {
    const native = new NativeClient(server.origin);
    const grant = await native.requestGrant("Synthetic Reader (e2e)");
    const { context, page } = await openAs(browser, server);
    await page.goto(grant.verification_uri_complete);
    await signInOnConnect(page, "browser_member", memberPassword());
    await page.getByRole("button", { name: "Connect app" }).waitFor();
    let posts = 0;
    await page.route("**/preview/api/v1/connect", async (route) => {
      if (route.request().method() !== "POST") return route.continue();
      posts += 1;
      return route.abort("connectionreset");
    });
    await page.getByRole("button", { name: "Connect app" }).click();
    await page.getByText(/could not confirm whether your choice reached the server/).waitFor();
    await Bun.sleep(300);
    expect(posts).toBe(1);
    expect(grants().at(-1)?.approved_at).toBeNull();
    await page.screenshot({ path: join(artifacts.out(), "consent-uncertain.png") });
    await page.unroute("**/preview/api/v1/connect");
    await page.getByRole("button", { name: "Check the code's status" }).click();
    await page.getByRole("button", { name: "Connect app" }).waitFor();
    expect(posts).toBe(1);
    await context.close();
  });

  test("the code entry page works without a code in the address", async () => {
    const native = new NativeClient(server.origin);
    const grant = await native.requestGrant("Synthetic Frame (e2e)");
    const { context, page } = await openAs(browser, server);
    await page.goto(`${server.origin}/consumer/connect`);
    await signInOnConnect(page, "browser_member", memberPassword());
    await page.getByLabel("Connection code").fill(grant.user_code.toLowerCase());
    await page.keyboard.press("Enter");
    await page.getByRole("button", { name: "Connect app" }).waitFor();
    expect(page.url()).toContain("user_code=");
    expect(await page.locator("main").innerText()).toContain(grant.user_code);
    await context.close();
  });
});
