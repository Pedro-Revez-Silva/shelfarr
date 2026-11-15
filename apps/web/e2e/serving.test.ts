import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Browser } from "playwright-core";
import { artifacts, launchBrowser, loadFixture, newContext, NativeClient, startServer, type RunningServer } from "./harness";

const fixture = loadFixture();
const manifest = JSON.parse(readFileSync(join(artifacts.assets(), "manifest.json"), "utf8")) as { entry: { script: string; style: string }; files: Record<string, { sha256: string; size: number }> };
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

const get = (path: string, init: RequestInit = {}) => fetch(`${server.origin}${path}`, { redirect: "manual", ...init });

describe("the packaged production serving of the static web build", () => {
  test("every listed asset is served byte for byte with its digest, type, cache and sniffing policy", async () => {
    const types: Record<string, string> = { js: "text/javascript; charset=utf-8", css: "text/css; charset=utf-8", ttf: "font/ttf" };
    for (const [name, entry] of Object.entries(manifest.files)) {
      const response = await get(`/preview/assets/${name}`);
      const body = new Uint8Array(await response.arrayBuffer());
      expect(response.status).toBe(200);
      expect(createHash("sha256").update(body).digest("hex")).toBe(entry.sha256);
      expect(body.byteLength).toBe(entry.size);
      expect(response.headers.get("content-type")).toBe(types[name.split(".").pop() ?? ""] ?? null);
      expect(response.headers.get("cache-control")).toBe("public, max-age=31536000, immutable");
      expect(response.headers.get("x-content-type-options")).toBe("nosniff");
      expect(response.headers.get("etag")).toBe(`"${entry.sha256}"`);
      expect(response.headers.get("set-cookie")).toBeNull();
      const revalidated = await get(`/preview/assets/${name}`, { headers: { "if-none-match": `"${entry.sha256}"` } });
      expect(revalidated.status).toBe(304);
      const head = await get(`/preview/assets/${name}`, { method: "HEAD" });
      expect(head.status).toBe(200);
      expect((await head.arrayBuffer()).byteLength).toBe(0);
    }
  });

  test("no account state, credential or secret is baked into any public file", async () => {
    const secret = readFileSync(fixture.secretFile, "utf8").trim();
    for (const [name] of Object.entries(manifest.files)) {
      const text = Buffer.from(await (await get(`/preview/assets/${name}`)).arrayBuffer()).toString("latin1");
      for (const needle of [secret, ...Object.values(fixture.passwords), "session_id=", "csrf_token\":\""]) expect(text.includes(needle)).toBe(false);
      expect(text).not.toContain("sourceMappingURL");
    }
  });

  test("only the manifest's files exist: no listing, no maps, no manifest, no traversal", async () => {
    for (const path of ["/preview/assets/", "/preview/assets", "/preview/assets/manifest.json", `/preview/assets/${manifest.entry.script}.map`, "/preview/assets/..%2fmanifest.json", "/preview/assets/%2e%2e/%2e%2e/etc/passwd", "/preview/assets/a/b", "/preview/assets/preview.0000000000000000.js"]) {
      const response = await get(path);
      expect(response.status).toBe(404);
      expect(response.headers.get("content-type")).toContain("application/json");
      expect(await response.json()).toEqual({ error: "not_found" });
    }
  });

  test("screens answer HTML with a strict policy and never the single-page shell for API, admin or unknown paths", async () => {
    const shell = await get("/preview/library");
    const policy = shell.headers.get("content-security-policy") ?? "";
    expect(shell.status).toBe(200);
    expect(shell.headers.get("cache-control")).toBe("private, no-store");
    expect(shell.headers.get("content-type")).toBe("text/html; charset=utf-8");
    const directives = Object.fromEntries(policy.split(";").map((part) => part.trim().split(/\s+/)).map(([name, ...values]) => [name, values.join(" ")]));
    expect(directives).toEqual({
      "default-src": "'none'", "script-src": "'self'", "style-src": "'self'", "font-src": "'self'", "img-src": "'self' https:", "connect-src": "'self'",
      "manifest-src": "'none'", "form-action": "'none'", "base-uri": "'none'", "frame-ancestors": "'self'", "object-src": "'none'",
    });
    expect(policy).not.toMatch(/unsafe|data:|\*/);
    for (const path of ["/admin", "/read/1", "/preview/api/v1/unknown", "/preview/api/v1/", "/api/consumer/v1/nope", "/preview/nope", "/login"]) {
      const response = await get(path);
      expect(response.status).toBe(404);
      expect(response.headers.get("content-type")).toContain("application/json");
    }
    expect((await get("/preview")).status).toBe(303);
    expect((await get("/preview")).headers.get("location")).toBe("/preview/library");
    const wrong = await get("/consumer/connect", { method: "POST", body: "{}" });
    expect(wrong.status).toBe(405);
    expect(wrong.headers.get("allow")).toBe("GET, HEAD");
  });

  test("the preserved native verification path is the page the app opens", async () => {
    const native = new NativeClient(server.origin);
    const grant = await native.requestGrant("Serving check");
    expect(new URL(grant.verification_uri).pathname).toBe("/consumer/connect");
    expect(new URL(grant.verification_uri_complete).searchParams.get("user_code")).toBe(grant.user_code);
    const page = await get(new URL(grant.verification_uri_complete).pathname + new URL(grant.verification_uri_complete).search);
    expect(page.status).toBe(200);
    expect(page.headers.get("referrer-policy")).toBe("no-referrer");
  });

  test("without JavaScript the screens say so plainly, render no form and send nothing", async () => {
    const context = await browser.newContext({ javaScriptEnabled: false });
    const page = await context.newPage();
    const seen: string[] = [];
    page.on("request", (request) => seen.push(`${request.method()} ${new URL(request.url()).pathname}`));
    await page.goto(`${server.origin}/preview/library`);
    expect(await page.locator("body").innerText()).toContain("need JavaScript");
    expect(await page.locator("form, input, button").count()).toBe(0);
    expect(seen.filter((entry) => entry.startsWith("POST"))).toEqual([]);
    await context.close();
  });

  test("a script that fails to run leaves a readable message and sends no credential", async () => {
    const context = await newContext(browser);
    await context.route(/preview\.[0-9a-f]+\.js$/, (route) => route.fulfill({ status: 200, contentType: "text/javascript", body: "throw new Error('boom')" }));
    const page = await context.newPage();
    const requests: string[] = [];
    page.on("request", (request) => requests.push(`${request.method()} ${request.url()}`));
    await page.goto(`${server.origin}/preview/library`);
    expect(await page.locator("body").innerText()).toContain("Loading Shelfarr");
    expect(requests.filter((line) => !line.startsWith("GET"))).toEqual([]);
    await context.close();
  });
});

describe("the UI stays off unless explicitly configured, and failures do not touch the native service", () => {
  test("without the assets option every screen path is a JSON 404 and the native service works", async () => {
    const plain = await startServer({ fixture, withAssets: false });
    try {
      for (const path of ["/preview", "/preview/library", "/preview/library/1", "/consumer/connect", `/preview/assets/${manifest.entry.script}`]) {
        for (const method of ["GET", "HEAD", "POST"]) {
          const response = await fetch(`${plain.origin}${path}`, { method, redirect: "manual", ...(method === "POST" ? { body: "{}" } : {}) });
          expect(response.status).toBe(404);
          expect(response.headers.get("allow")).toBeNull();
        }
      }
      expect((await fetch(`${plain.origin}/api/consumer/v1/server.json`)).status).toBe(200);
      expect((await fetch(`${plain.origin}/preview/api/v1/auth/bootstrap`)).status).toBe(200);
      const grant = await new NativeClient(plain.origin).requestGrant("UI off");
      expect(grant.verification_uri).toBe(`${plain.origin}/consumer/connect`);
    } finally {
      await plain.stop();
    }
  });

  test("a missing or malformed allowlist keeps every screen a 404 even with assets and no session", async () => {
    for (const users of ["", "abc", "1,,2", "0"]) {
      const closed = await startServer({ fixture, users, extraArguments: [] }).catch((error: Error) => error);
      if (closed instanceof Error) {
        expect(users).toBe("");
        continue;
      }
      try {
        for (const path of ["/preview/library", "/consumer/connect", `/preview/assets/${manifest.entry.script}`]) expect((await fetch(`${closed.origin}${path}`)).status).toBe(404);
      } finally {
        await closed.stop();
      }
    }
  });

  test("a bad assets folder is refused at start and nothing listens", async () => {
    const directory = mkdtempSync(join(process.env["TMPDIR"] ?? "", "bad-assets-"));
    try {
      writeFileSync(join(directory, "manifest.json"), "{}");
      for (const folder of [directory, join(directory, "missing"), "relative/path", "."]) {
        const result = Bun.spawnSync([artifacts.binary(), "-experimental", "-database", fixture.database, "-lock-file", join(directory, "lock"), "-library-root", fixture.libraryRoots[0] ?? "", "-listen", "127.0.0.1:0", "-browser-origin", "http://127.0.0.1:1", "-preview-user-ids", "1", "-web-assets-dir", folder], {
          env: { PATH: process.env["PATH"] ?? "", SECRET_KEY_BASE_FILE: fixture.secretFile },
        });
        expect(result.exitCode).toBe(2);
        expect(result.stderr.toString()).toMatch(/^refused: (web-assets|config)\n/);
        expect(result.stderr.toString()).not.toContain(folder.length > 1 ? folder : "\u0000");
      }
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  test("a symlinked asset is refused at start", async () => {
    const directory = mkdtempSync(join(process.env["TMPDIR"] ?? "", "link-assets-"));
    try {
      Bun.spawnSync(["cp", "-r", `${artifacts.assets()}/.`, directory]);
      const target = join(directory, manifest.entry.script);
      rmSync(target);
      Bun.spawnSync(["ln", "-s", join(artifacts.assets(), manifest.entry.script), target]);
      chmodSync(directory, 0o700);
      const result = Bun.spawnSync([artifacts.binary(), "-experimental", "-database", fixture.database, "-lock-file", join(directory, "lock"), "-library-root", fixture.libraryRoots[0] ?? "", "-listen", "127.0.0.1:0", "-browser-origin", "http://127.0.0.1:1", "-preview-user-ids", "1", "-web-assets-dir", directory], {
        env: { PATH: process.env["PATH"] ?? "", SECRET_KEY_BASE_FILE: fixture.secretFile },
      });
      expect(result.exitCode).toBe(2);
      expect(result.stderr.toString()).toBe("refused: web-assets\n");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
