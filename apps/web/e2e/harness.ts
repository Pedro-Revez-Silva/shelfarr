import { Database } from "bun:sqlite";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright-core";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export type Fixture = {
  dir: string;
  database: string;
  secretFile: string;
  libraryRoots: string[];
  serverVersion: string;
  previewUsers: string;
  users: Record<string, number>;
  readerBooks: Record<"text" | "manga" | "mixed" | "audio" | "pdf" | "comic" | "damaged" | "broken_pdf", number>;
  passwords: Record<string, string>;
  personas: Record<string, { cookie: string; user_id: number; session_id: number | null }>;
  discover: DiscoverCases;
  requests: RequestCases;
};

export type RailsRequestCard = { title: string; id: number; labels: string[]; requested_by: string | null };
export type RailsRequestPage = { query: Record<string, string>; cards: RailsRequestCard[]; filters: { label: string; current: boolean }[]; pagination: string | null };
export type RequestCases = {
  ids: Record<string, number>;
  issues: { listed: string; free_text: string };
  rails_pages: Record<"browser_member" | "browser_admin", RailsRequestPage[]>;
  rails_show_status: Record<"browser_member" | "browser_admin", Record<string, number>>;
  rails_native_view: { id: string; status: string; stage: string; download_percent: number | null; publication_id: string | null; title: string }[];
};

export type RailsSearchResult = { work_id: string; title: string; author: string | null; first_publish_year: number | string | null; cover_id: number | null; cover_url: string | null; edition_count: number | null };
export type RailsLibraryVerdict = Record<string, Record<"ebook" | "audiobook" | "comicbook", { book_id: number; acquired: boolean } | null>>;
export type DiscoverCases = {
  query: string;
  response: string;
  rails_request: Record<string, string>;
  rails_results: RailsSearchResult[];
  rails_library: RailsLibraryVerdict;
  books: Record<"text" | "audio" | "comic" | "newer_request" | "waiting", number>;
};

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

export function loadFixture(): Fixture {
  const dir = required("SHELFARR_E2E_FIXTURE");
  const cases = JSON.parse(readFileSync(join(dir, "cases.json"), "utf8"));
  const secrets = JSON.parse(readFileSync(join(dir, "secrets", "personas.json"), "utf8"));
  return {
    dir,
    database: join(dir, cases.database),
    secretFile: join(dir, "secrets", "secret_key_base"),
    libraryRoots: [cases.bundle_media_root, cases.extra_media_root],
    serverVersion: cases.server_version,
    previewUsers: cases.preview_user_ids,
    users: cases.users,
    readerBooks: cases.reader_books,
    passwords: secrets.passwords,
    personas: secrets.personas,
    discover: cases.discover,
    requests: cases.requests,
  };
}

export const artifacts = {
  fakeOpenLibrary: () => required("SHELFARR_E2E_FAKE_OPENLIBRARY"),
  binary: () => required("SHELFARR_E2E_BINARY"),
  seamBinary: () => required("SHELFARR_E2E_SEAM_BINARY"),
  assets: () => required("SHELFARR_E2E_ASSETS"),
  out: () => {
    const dir = process.env["SHELFARR_E2E_OUT"] ?? join(required("TMPDIR"), "e2e-out");
    mkdirSync(dir, { recursive: true });
    return dir;
  },
};

const IMAGE_ASSETS = "/usr/local/share/shelfarr/web";

export type ServerOptions = {
  fixture: Fixture;
  users?: string;
  withAssets?: boolean;
  extraArguments?: string[];
  seamBinary?: string;
  clock?: string;
  environment?: Record<string, string>;
};

export class RunningServer {
  readonly origin: string;
  readonly directory: string;
  readonly database: string;
  readonly logs: string[] = [];
  private readonly process: Bun.Subprocess;
  private readonly container: string | null;

  constructor(origin: string, directory: string, database: string, child: Bun.Subprocess, container: string | null = null) {
    this.container = container;
    this.origin = origin;
    this.directory = directory;
    this.database = database;
    this.process = child;
  }

  query<T = Record<string, unknown>>(sql: string, ...parameters: (string | number | null)[]): T[] {
    const handle = new Database(this.database, { readonly: true });
    try {
      return handle.query(sql).all(...parameters) as T[];
    } finally {
      handle.close();
    }
  }

  execute(sql: string, ...parameters: (string | number | null)[]): void {
    const handle = new Database(this.database);
    try {
      handle.exec("PRAGMA busy_timeout = 5000");
      handle.query(sql).run(...parameters);
    } finally {
      handle.close();
    }
  }

  async stop(): Promise<void> {
    if (this.container) Bun.spawnSync(["docker", "kill", this.container]);
    else this.process.kill("SIGTERM");
    await this.process.exited;
    rmSync(this.directory, { recursive: true, force: true });
  }
}

async function freePort(): Promise<number> {
  const probe = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } });
  const port = probe.port;
  probe.stop(true);
  return port;
}

export async function startServer(options: ServerOptions): Promise<RunningServer> {
  const { fixture } = options;
  const directory = mkdtempSync(join(required("TMPDIR"), "srv-"));
  const database = join(directory, "primary.sqlite3");
  const image = process.env["SHELFARR_E2E_IMAGE"];
  copyFileSync(fixture.database, database);
  const handle = new Database(database);
  handle.exec("PRAGMA journal_mode=WAL");
  handle.close();
  const port = await freePort();
  const origin = `http://127.0.0.1:${port}`;
  const argumentsList = [
    "-experimental",
    "-database", database,
    "-lock-file", join(directory, "domain.lock"),
    "-listen", `127.0.0.1:${port}`,
    "-server-version", fixture.serverVersion,
    "-browser-origin", origin,
    "-preview-user-ids", options.users ?? fixture.previewUsers,
    ...fixture.libraryRoots.flatMap((root) => ["-library-root", root]),
    ...(options.withAssets === false ? [] : ["-web-assets-dir", image ? IMAGE_ASSETS : artifacts.assets()]),
    ...(options.extraArguments ?? []),
  ];
  const environment: Record<string, string> = { PATH: process.env["PATH"] ?? "", SECRET_KEY_BASE_FILE: fixture.secretFile };
  if (options.clock) environment["SHELFARR_E2E_CLOCK_FILE"] = options.clock;
  Object.assign(environment, options.environment ?? {});
  if (image && options.environment) throw new Error("the image mode cannot reach the test's loopback services; run these tests against the binary");
  const container = image ? `shelfarr-go-web-${process.pid}-${port}` : null;
  const command = image
    ? [
        "docker", "run", "--rm", "--name", container ?? "", "--network", "host", "-u", `${process.getuid?.() ?? 1000}:${process.getgid?.() ?? 1000}`,
        "-v", `${directory}:${directory}`, "-v", `${fixture.secretFile}:${fixture.secretFile}:ro`, ...fixture.libraryRoots.flatMap((root) => ["-v", `${root}:${root}:ro`]),
        "-e", `SECRET_KEY_BASE_FILE=${fixture.secretFile}`, image, "/usr/local/bin/shelfarr-http", ...argumentsList,
      ]
    : [options.seamBinary ?? artifacts.binary(), ...argumentsList];
  const child = Bun.spawn(command, { env: image ? { PATH: process.env["PATH"] ?? "", HOME: process.env["HOME"] ?? "" } : environment, stdout: "ignore", stderr: "pipe" });
  const server = new RunningServer(origin, directory, database, child, container);
  const reader = child.stderr.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const listening = new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`the server did not start: ${server.logs.join("\n")}`)), 20_000);
    void (async () => {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let newline = buffer.indexOf("\n");
        while (newline >= 0) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          server.logs.push(line);
          if (line.includes('"msg":"listening"')) {
            clearTimeout(timer);
            resolve();
          }
          newline = buffer.indexOf("\n");
        }
      }
    })();
  });
  await listening;
  return server;
}



export async function launchBrowser(): Promise<Browser> {
  const sink = process.env["PULSE_SINK"];
  if (!sink) throw new Error("PULSE_SINK must name the owned null sink before any test browser starts");
  return chromium.launch({
    ...(process.env["SHELFARR_E2E_CHROMIUM"] ? { executablePath: process.env["SHELFARR_E2E_CHROMIUM"] } : {}),
    headless: true,
    args: ["--mute-audio", "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--disable-sync", "--disable-background-networking", "--disable-gpu", "--use-fake-ui-for-media-stream", "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"],
    env: { PATH: process.env["PATH"] ?? "", HOME: process.env["HOME"] ?? "", TMPDIR: required("TMPDIR"), PULSE_SINK: sink, XDG_RUNTIME_DIR: process.env["XDG_RUNTIME_DIR"] ?? "", LANG: "C.UTF-8" },
  });
}

export type Violations = { policy: string[]; console: string[]; page: string[] };

export async function watch(page: Page): Promise<Violations> {
  const seen: Violations = { policy: [], console: [], page: [] };
  await page.addInitScript(() => {
    (window as unknown as { __violations: string[] }).__violations = [];
    document.addEventListener("securitypolicyviolation", (event) => {
      (window as unknown as { __violations: string[] }).__violations.push(`${event.violatedDirective} ${event.blockedURI}`);
    });
  });
  page.on("console", (message) => {
    if (message.type() === "error" || message.type() === "warning") seen.console.push(`${message.type()}: ${message.text()}`);
  });
  page.on("pageerror", (error) => seen.page.push(error.message));
  return seen;
}

export async function policyViolations(page: Page): Promise<string[]> {
  return page.evaluate(() => (window as unknown as { __violations?: string[] }).__violations ?? []);
}

export async function newContext(browser: Browser, options: { colorScheme?: "light" | "dark"; viewport?: { width: number; height: number }; recordVideo?: string; cookies?: { name: string; value: string; url: string }[] } = {}): Promise<BrowserContext> {
  const context = await browser.newContext({
    colorScheme: options.colorScheme ?? "light",
    viewport: options.viewport ?? { width: 1280, height: 900 },
    ...(options.recordVideo ? { recordVideo: { dir: options.recordVideo, size: options.viewport ?? { width: 1280, height: 900 } } } : {}),
  });
  if (options.cookies) await context.addCookies(options.cookies);
  return context;
}

export function exists(path: string): boolean {
  return existsSync(path);
}

export function writeText(path: string, text: string) {
  writeFileSync(path, text);
}

export async function signIn(page: Page, username: string, password: string) {
  await page.getByLabel("Username").fill(username);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in" }).click();
}

const EXPECTED_NOISE = [/favicon\.ico/, /net::ERR_NAME_NOT_RESOLVED/, /Failed to load resource: the server responded with a status of (401|404|409|422|429|501|503)/];

export function unexpectedConsole(seen: Violations): string[] {
  return seen.console.filter((line) => !EXPECTED_NOISE.some((pattern) => pattern.test(line)));
}

export type Tokens = { access_token: string; token_type: string; scope: string; expires_in: number };

export class NativeClient {
  private readonly origin: string;
  constructor(origin: string) {
    this.origin = origin;
  }

  async post(path: string, body: unknown, token?: string): Promise<{ status: number; body: Record<string, unknown> }> {
    const response = await fetch(`${this.origin}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(body),
    });
    return { status: response.status, body: (await response.json().catch(() => ({}))) as Record<string, unknown> };
  }

  async request(path: string, init: { method?: string; token: string; body?: unknown }): Promise<{ status: number; body: Record<string, unknown> }> {
    const response = await fetch(`${this.origin}${path}`, {
      method: init.method ?? "GET",
      headers: { authorization: `Bearer ${init.token}`, ...(init.body === undefined ? {} : { "content-type": "application/json" }) },
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
    });
    return { status: response.status, body: (await response.json().catch(() => ({}))) as Record<string, unknown> };
  }

  async requestGrant(clientName: string, scope?: string, token?: string) {
    const answer = await this.post("/api/consumer/v1/auth/device", { client_name: clientName, ...(scope ? { scope } : {}) }, token);
    return answer.body as { device_code: string; user_code: string; verification_uri: string; verification_uri_complete: string; expires_in: number; interval: number };
  }

  poll(deviceCode: string) {
    return this.post("/api/consumer/v1/auth/token", { device_code: deviceCode });
  }
}

export async function openAs(browser: Browser, server: RunningServer, options: { colorScheme?: "light" | "dark"; viewport?: { width: number; height: number }; recordVideo?: string } = {}) {
  const context = await newContext(browser, options);
  const page = await context.newPage();
  const seen = await watch(page);
  return { context, page, seen, origin: server.origin };
}
