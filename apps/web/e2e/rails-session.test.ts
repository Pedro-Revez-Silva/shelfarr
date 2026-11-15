import { afterAll, beforeAll, expect, test } from "bun:test";
import type { Browser } from "playwright-core";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, launchBrowser, loadFixture, newContext, startServer, watch, policyViolations, unexpectedConsole, type RunningServer } from "./harness";

const fixture = loadFixture();
let browser: Browser;
let server: RunningServer;
let clockDirectory: string;

beforeAll(async () => {
  browser = await launchBrowser();
  clockDirectory = mkdtempSync(join(process.env["TMPDIR"] ?? "", "clock-"));
  const clock = join(clockDirectory, "now");
  writeFileSync(clock, "2026-11-15T12:00:30Z");
  server = await startServer({ fixture, seamBinary: artifacts.seamBinary(), clock });
});

afterAll(async () => {
  await browser.close();
  await server.stop();
  rmSync(clockDirectory, { recursive: true, force: true });
});

test("a session Rails issued with a real login opens the Go Library with no sign-in, and signing out from Go revokes the Rails row", async () => {
  const persona = fixture.personas["login-member"];
  expect(persona?.session_id).toBeTruthy();
  const context = await newContext(browser);
  await context.addCookies([{ name: "session_id", value: persona?.cookie ?? "", url: server.origin }]);
  const page = await context.newPage();
  const seen = await watch(page);
  await page.goto(`${server.origin}/preview/library`);
  await page.getByRole("heading", { name: "Library", level: 1 }).waitFor();
  await page.locator(".book-card").first().waitFor();
  expect(await page.getByLabel("Username").count()).toBe(0);
  expect(server.query("SELECT id FROM sessions WHERE id = ?", persona?.session_id ?? 0)).toHaveLength(1);
  await page.getByRole("button", { name: "Sign out" }).click();
  await page.getByLabel("Username").waitFor();
  expect(server.query("SELECT id FROM sessions WHERE id = ?", persona?.session_id ?? 0)).toHaveLength(0);
  expect(await policyViolations(page)).toEqual([]);
  expect(unexpectedConsole(seen)).toEqual([]);
  await context.close();
});

test("a tampered Rails cookie is a signed-out visitor, never a session", async () => {
  const persona = fixture.personas["login-admin"];
  const context = await newContext(browser);
  const tampered = `${persona?.cookie ?? ""}`.replace(/.$/, (character) => (character === "0" ? "1" : "0"));
  await context.addCookies([{ name: "session_id", value: tampered, url: server.origin }]);
  const page = await context.newPage();
  await page.goto(`${server.origin}/preview/library`);
  await page.getByLabel("Username").waitFor();
  await context.close();
});
