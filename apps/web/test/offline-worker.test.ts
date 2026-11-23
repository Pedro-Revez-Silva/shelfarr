import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const SOURCE = readFileSync(resolve(import.meta.dir, "../../server/internal/gohttp/offline_worker.js"), "utf8");
const ORIGIN = "http://shelf.test";
const SCRIPT = new TextEncoder().encode("console.log('app');\n");
const STYLE = new TextEncoder().encode("body{}\n");

async function sha256(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

const SHELL_HEADERS = { "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": "default-src 'none'", "Cache-Control": "private, no-store" };

type Placement = { library?: string; downloads?: string; cache?: string; reads?: { prefix: string; suffix: string } };

async function config(version = "v2", library = "/preview/library", placement: Placement = {}) {
  return {
    version,
    library,
    downloads: `${library}/downloads`,
    ...placement,
    assets: [
      { path: "/preview/assets/preview.0000000000000001.js", sha256: await sha256(SCRIPT) },
      { path: "/preview/assets/preview.0000000000000002.css", sha256: await sha256(STYLE) },
    ],
    shells: { downloads: { body: "<p>downloads shell</p>", headers: SHELL_HEADERS }, reader: { body: "<p>reader shell</p>", headers: SHELL_HEADERS } },
  };
}

class FakeCaches {
  readonly stores = new Map<string, Map<string, Response>>();
  async open(name: string) {
    const store = this.stores.get(name) ?? new Map<string, Response>();
    this.stores.set(name, store);
    return { put: async (url: string, response: Response) => void store.set(url, response) };
  }
  async keys() {
    return [...this.stores.keys()];
  }
  async delete(name: string) {
    return this.stores.delete(name);
  }
  async match(url: string, options: { cacheName: string }) {
    return this.stores.get(options.cacheName)?.get(url)?.clone();
  }
}

type Listener = (event: { request?: Request; respondWith?: (response: Promise<Response>) => void; waitUntil?: (work: Promise<unknown>) => void }) => void;
type Network = (request: Request) => Promise<Response>;

async function worker(network: Network, version = "v2", library = "/preview/library", placement: Placement = {}) {
  const listeners = new Map<string, Listener>();
  const caches = new FakeCaches();
  const fetched: string[] = [];
  let claimed = false;
  let skipped = false;
  const self = {
    SHELFARR_GO_OFFLINE: await config(version, library, placement),
    location: new URL(`${ORIGIN}/preview/offline-worker.js`),
    addEventListener: (type: string, listener: Listener) => listeners.set(type, listener),
    skipWaiting: async () => void (skipped = true),
    clients: { claim: async () => void (claimed = true) },
  };
  const fetcher = async (input: Request | string) => {
    const request = typeof input === "string" ? new Request(input) : input;
    fetched.push(`${request.method} ${new URL(request.url).pathname} ${request.credentials}`);
    return network(request);
  };
  new Function("self", "caches", "fetch", SOURCE)(self, caches, fetcher);
  const lifecycle = async (type: "install" | "activate") => {
    let work: Promise<unknown> = Promise.resolve();
    listeners.get(type)?.({ waitUntil: (promise) => void (work = promise) });
    await work;
  };
  const dispatch = async (request: Request): Promise<Response | null> => {
    let answer: Promise<Response> | null = null;
    listeners.get("fetch")?.({ request, respondWith: (response) => void (answer = response) });
    return answer ? await answer : null;
  };
  return { caches, fetched, lifecycle, dispatch, state: () => ({ claimed, skipped }) };
}

const assetNetwork: Network = async (request) => {
  const path = new URL(request.url).pathname;
  if (path.endsWith(".js")) return new Response(SCRIPT, { headers: { "Content-Type": "text/javascript" } });
  if (path.endsWith(".css")) return new Response(STYLE, { headers: { "Content-Type": "text/css" } });
  return new Response("not found", { status: 404 });
};

const navigation = (path: string, method = "GET") => {
  const request = new Request(`${ORIGIN}${path}`, { method });
  Object.defineProperty(request, "mode", { value: "navigate" });
  return request;
};

describe("the offline worker", () => {
  test("installs only the listed assets, fetched without credentials and checked against their digests", async () => {
    const installed = await worker(assetNetwork);
    await installed.lifecycle("install");
    expect(installed.fetched).toEqual(["GET /preview/assets/preview.0000000000000001.js omit", "GET /preview/assets/preview.0000000000000002.css omit"]);
    expect([...(installed.caches.stores.get("shelfarr-go-preview-offline.v1|v2")?.keys() ?? [])]).toEqual([
      `${ORIGIN}/preview/assets/preview.0000000000000001.js`,
      `${ORIGIN}/preview/assets/preview.0000000000000002.css`,
    ]);
    expect(installed.state()).toEqual({ skipped: false, claimed: false });
  });

  test("refuses to install when an asset is not the listed file or does not answer 200, and keeps no partial cache", async () => {
    const secondFails = (failure: () => Response): Network => async (request) => (new URL(request.url).pathname.endsWith(".css") ? failure() : assetNetwork(request));
    for (const network of [async () => new Response("tampered"), async () => new Response("gone", { status: 404 }), secondFails(() => new Response("busy", { status: 503 })), secondFails(() => new Response("tampered"))] as Network[]) {
      const installed = await worker(network);
      await installed.caches.open("shelfarr-go-preview-offline.v1|v1");
      await expect(installed.lifecycle("install")).rejects.toThrow();
      expect(await installed.caches.keys()).toEqual(["shelfarr-go-preview-offline.v1|v1"]);
    }
  });

  test("activation removes only its own earlier versions and never takes over open pages", async () => {
    const installed = await worker(assetNetwork);
    for (const name of ["shelfarr-go-preview-offline.v1|v1", "shelfarr-go-preview-offline.v1|v2", "shelfarr-offline-shell.v1|http://shelf.test|abc", "shelfarr-offline-media.v1|http://shelf.test|5", "other-app"]) await installed.caches.open(name);
    await installed.lifecycle("activate");
    expect(await installed.caches.keys()).toEqual(["shelfarr-go-preview-offline.v1|v2", "shelfarr-offline-shell.v1|http://shelf.test|abc", "shelfarr-offline-media.v1|http://shelf.test|5", "other-app"]);
    expect(installed.state()).toEqual({ skipped: false, claimed: false });
  });

  test("the Rails preview's worker answers only its own subtree and keeps its caches apart from the Go runtime's", async () => {
    const rails = { cache: "shelfarr-rails-preview-offline.v1|", reads: { prefix: "/preview/read", suffix: "" }, downloads: "/preview/read/downloads" };
    const go = ["shelfarr-go-preview-offline.v1|v1", "shelfarr-go-preview-offline.v1@/shelf/preview/library|v1", "shelfarr-rails-preview-offline.v1@/shelf/preview|v1", "shelfarr-rails-preview-offline.v1|v1"];
    const installed = await worker(assetNetwork, "v2", "/preview/library", rails);
    for (const name of go) await installed.caches.open(name);
    await installed.lifecycle("install");
    await installed.lifecycle("activate");
    expect(await installed.caches.keys()).toEqual(["shelfarr-go-preview-offline.v1|v1", "shelfarr-go-preview-offline.v1@/shelf/preview/library|v1", "shelfarr-rails-preview-offline.v1@/shelf/preview|v1", "shelfarr-rails-preview-offline.v1|v2"]);
    const offline = await worker(async () => Promise.reject(new TypeError("offline")), "v2", "/preview/library", rails);
    expect(await (await offline.dispatch(navigation("/preview/read/12")))?.text()).toBe("<p>reader shell</p>");
    expect(await (await offline.dispatch(navigation("/preview/read/downloads")))?.text()).toBe("<p>downloads shell</p>");
    for (const path of ["/preview/library/12/read", "/preview/library/downloads", "/preview/read/12/read", "/preview/read/012", "/preview/read"]) expect(await offline.dispatch(navigation(path))).toBeNull();
  });

  test("a worker for another deployment mount keeps its own caches and never removes the default mount's or another mount's", async () => {
    const mounted = await worker(assetNetwork, "v2", "/shelf/preview/library");
    const others = ["shelfarr-go-preview-offline.v1|v1", "shelfarr-go-preview-offline.v1@/other/preview/library|v1", "shelfarr-go-preview-offline.v1@/shelf/preview/library|v1"];
    for (const name of others) await mounted.caches.open(name);
    await mounted.lifecycle("install");
    await mounted.lifecycle("activate");
    expect(await mounted.caches.keys()).toEqual(["shelfarr-go-preview-offline.v1|v1", "shelfarr-go-preview-offline.v1@/other/preview/library|v1", "shelfarr-go-preview-offline.v1@/shelf/preview/library|v2"]);
    const fallback = await (await worker(async () => Promise.reject(new TypeError("offline")), "v2", "/shelf/preview/library")).dispatch(navigation("/shelf/preview/library/12/read"));
    expect(await fallback?.text()).toBe("<p>reader shell</p>");
  });

  test("offers the static shell for Downloads and the reader only when the server cannot be reached", async () => {
    for (const [path, shell] of [["/preview/library/downloads", "downloads shell"], ["/preview/library/12/read", "reader shell"]] as const) {
      for (const network of [async () => Promise.reject(new TypeError("offline")), async () => new Response("bad gateway", { status: 502 }), async () => new Response("", { status: 503 }), async () => new Response("", { status: 504 })] as Network[]) {
        const answer = await (await worker(network)).dispatch(navigation(path));
        expect(await answer?.text()).toBe(`<p>${shell}</p>`);
        expect(answer?.headers.get("Content-Security-Policy")).toBe("default-src 'none'");
      }
      for (const status of [200, 401, 403, 404, 500]) {
        const answer = await (await worker(async () => new Response(`server ${status}`, { status }))).dispatch(navigation(path));
        expect(answer?.status).toBe(status);
        expect(await answer?.text()).toBe(`server ${status}`);
      }
    }
  });

  test("leaves every other request to the network untouched", async () => {
    const installed = await worker(async () => Promise.reject(new TypeError("offline")));
    const untouched = [
      navigation("/preview/library"),
      navigation("/preview/library/12"),
      navigation("/preview/library/12/read/extra"),
      navigation("/preview/library/0/read"),
      navigation("/read/12"),
      navigation("/preview/library/downloads", "POST"),
      new Request(`${ORIGIN}/preview/api/v1/library/12/reader`),
      new Request(`${ORIGIN}/preview/api/v1/accounts/5/library/12/assets/${"a".repeat(64)}`),
      new Request(`${ORIGIN}/preview/assets/preview.0000000000000001.js?x=1`),
      new Request("http://elsewhere.test/preview/assets/preview.0000000000000001.js"),
    ];
    for (const request of untouched) expect(await installed.dispatch(request)).toBeNull();
    expect(installed.fetched).toEqual([]);
  });

  test("answers a listed asset from its own cache, and from the network when the cache lost it", async () => {
    const installed = await worker(assetNetwork);
    await installed.lifecycle("install");
    installed.fetched.length = 0;
    const cached = await installed.dispatch(new Request(`${ORIGIN}/preview/assets/preview.0000000000000001.js`));
    expect(new Uint8Array(await cached!.arrayBuffer())).toEqual(SCRIPT);
    expect(installed.fetched).toEqual([]);
    installed.caches.stores.clear();
    const fetched = await installed.dispatch(new Request(`${ORIGIN}/preview/assets/preview.0000000000000002.css`));
    expect(await fetched?.text()).toBe("body{}\n");
    expect(installed.fetched).toHaveLength(1);
  });
});
