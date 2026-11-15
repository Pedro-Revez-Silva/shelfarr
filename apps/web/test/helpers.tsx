import { createMemoryHistory } from "@tanstack/react-router";
import { render } from "@testing-library/react";
import { App } from "../src/App";
import type { Boot, LibraryPage, PublicationDetail, PublicationSummary, Session } from "../src/contract";
import { resetFirstPage } from "../src/components/PageHeading";
import { createAppRouter } from "../src/router";
import { createServices, type Services } from "../src/services";

export const ACCOUNT = "12";
export const MOUNT = "/sub/preview";

export const boot: Boot = { version: 1, account: ACCOUNT, mount: MOUNT, api: `${MOUNT}/api/v1`, classic_library: "/sub/read" };

export function summary(overrides: Partial<PublicationSummary> = {}): PublicationSummary {
  return {
    id: "7",
    title: "The Quiet Library",
    author: "A. Reader",
    book_type: "ebook",
    content_kind: "book",
    format_label: "Ebook",
    availability: "available",
    action: "read",
    cover: { url: null, style: "clay" },
    reading_status: "unread",
    progress: null,
    progress_label: "Start reading",
    reader_url: "/sub/read/7",
    ...overrides,
  };
}

export function detail(overrides: Partial<PublicationDetail> = {}): PublicationDetail {
  return {
    ...summary(),
    description: "A quiet place to begin.",
    files: [{ id: "a".repeat(64), filename: "A Book.epub", format: "epub", media_type: "application/epub+zip", size_bytes: 2048, position: 0, page_count: null }],
    ...overrides,
  };
}

export function session(overrides: Partial<Session> = {}): Session {
  return {
    account: { id: ACCOUNT, name: "Ada Reader" },
    server: { name: "shelf.test", version: "1.0.0" },
    links: { legacy_library: "/sub/read", discover: "/sub/search", requests: "/sub/requests", account: "/sub/profile" },
    ...overrides,
  };
}

export function page(items: PublicationSummary[], next: string | null = null): LibraryPage {
  return { account: ACCOUNT, items, next_cursor: next };
}

export type RecordedRequest = { method: string; path: string; headers: Record<string, string>; body: unknown; signal: AbortSignal | undefined };
export type Handler = (request: RecordedRequest) => { status?: number; body?: unknown; headers?: Record<string, string> } | Promise<{ status?: number; body?: unknown; headers?: Record<string, string> }>;

export class FakeServer {
  readonly requests: RecordedRequest[] = [];
  private readonly handlers: { method: string; pattern: RegExp; handler: Handler }[] = [];

  on(method: string, pattern: RegExp, handler: Handler): this {
    this.handlers.unshift({ method, pattern, handler });
    return this;
  }

  get fetcher(): typeof fetch {
    return (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), "http://shelf.test");
      const headers: Record<string, string> = {};
      for (const [key, value] of Object.entries((init?.headers ?? {}) as Record<string, string>)) headers[key.toLowerCase()] = value;
      const request: RecordedRequest = {
        method: init?.method ?? "GET",
        path: `${url.pathname}${url.search}`,
        headers,
        body: typeof init?.body === "string" ? JSON.parse(init.body) : undefined,
        signal: init?.signal ?? undefined,
      };
      this.requests.push(request);
      const match = this.handlers.find((entry) => entry.method === request.method && entry.pattern.test(request.path));
      if (!match) return new Response(JSON.stringify({ error: "not_found" }), { status: 404, headers: { "content-type": "application/json" } });
      const result = await match.handler(request);
      if (request.signal?.aborted) throw new DOMException("Aborted", "AbortError");
      return new Response(result.body === undefined ? null : JSON.stringify(result.body), {
        status: result.status ?? 200,
        headers: { "content-type": "application/json; charset=utf-8", ...(result.headers ?? {}) },
      });
    }) as typeof fetch;
  }

  called(method: string, pattern: RegExp): RecordedRequest[] {
    return this.requests.filter((request) => request.method === method && pattern.test(request.path));
  }
}

export function standardServer(): FakeServer {
  return new FakeServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session() }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }));
}

export function renderApp(options: { server: FakeServer; url?: string; csrf?: string | null; mount?: string }): { services: Services; router: ReturnType<typeof createAppRouter>; view: ReturnType<typeof render> } {
  resetFirstPage();
  const services = createServices({ boot, csrfToken: () => (options.csrf === undefined ? "token-123" : options.csrf), fetcher: options.server.fetcher });
  const history = createMemoryHistory({ initialEntries: [options.url ?? `${MOUNT}/library`] });
  const router = createAppRouter({ basepath: options.mount ?? MOUNT, history });
  const view = render(<App services={services} router={router} />);
  return { services, router, view };
}

export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}
