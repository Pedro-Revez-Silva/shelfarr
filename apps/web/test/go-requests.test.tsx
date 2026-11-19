import { describe, expect, test } from "bun:test";
import { createMemoryHistory } from "@tanstack/react-router";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { App } from "../src/App";
import { resetFirstPage } from "../src/components/PageHeading";
import { trimQuery } from "../src/components/RequestsPage";
import { requestEnvelopeSchema, requestListSchema, type RequestDetail, type RequestList, type RequestSummary } from "../src/contract";
import { createAppRouter } from "../src/router";
import { createServices } from "../src/services";
import { ACCOUNT, deferred, FakeServer, page, renderApp, session, summary, type RecordedRequest } from "./helpers";
import { error } from "./go-helpers";

function request(overrides: Partial<RequestSummary> = {}): RequestSummary {
  return {
    id: "3",
    status: "downloading",
    attention_needed: false,
    title: "Harbor Lights",
    author: "H. Keeper",
    book_type: "ebook",
    cover: { url: null, style: "moss" },
    download_percent: 42,
    created_at: "2026-11-13T08:00:00.000Z",
    updated_at: "2026-11-13T08:00:00.000Z",
    completed_at: null,
    next_retry_at: null,
    library: null,
    ...overrides,
  };
}

const completed = request({ id: "1", status: "completed", title: "Quiet Shelf", author: null, download_percent: null, completed_at: "2026-11-11T09:30:00.000Z", library: { state: "available", publication_id: "10" } });
const unavailable = request({ id: "2", status: "completed", title: "Missing Files", book_type: "audiobook", download_percent: null, completed_at: "2026-11-12T10:00:00.000Z", library: { state: "unavailable" } });

function list(items: RequestSummary[], overrides: Partial<RequestList> = {}): RequestList {
  return {
    account: ACCOUNT,
    scope: "own",
    filter: { status: null, attention: false, q: null },
    counts: { attention: 0, active: 1 },
    page: 1,
    per_page: 25,
    total: items.length,
    total_pages: 1,
    items,
    ...overrides,
  };
}

function detail(overrides: Partial<RequestDetail> = {}): RequestDetail {
  return { ...request(), attention_reason: null, downloads: [{ status: "downloading", progress: 42 }, { status: "failed", progress: null }], ...overrides };
}

function params(recorded: RecordedRequest): Record<string, string> {
  return Object.fromEntries(new URL(recorded.path, "http://shelf.test").searchParams);
}

function requestsServer(respond: (recorded: RecordedRequest) => ReturnType<Parameters<FakeServer["on"]>[2]> = () => ({ body: list([request(), unavailable, completed]) })): FakeServer {
  return new FakeServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session() }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", /\/api\/v1\/library\/10$/, () => ({ body: { account: ACCOUNT, publication: { ...summary({ id: "10", title: "Quiet Shelf" }), description: "", files: [] } } }))
    .on("GET", /\/api\/v1\/requests\/3$/, () => ({ body: { account: ACCOUNT, request: detail() } }))
    .on("GET", /\/api\/v1\/requests(\?|$)/, respond);
}

function lists(server: FakeServer) {
  return server.called("GET", /\/api\/v1\/requests(\?|$)/);
}

function renderRequests(server: FakeServer, url = "/preview/requests") {
  resetFirstPage();
  const services = createServices({
    boot: { version: 1, account: ACCOUNT, mount: "/preview", api: "/preview/api/v1", classic_library: null, runtime: "go" },
    csrfToken: () => "session-token",
    fetcher: server.fetcher,
  });
  const history = createMemoryHistory({ initialEntries: [url] });
  const router = createAppRouter({ basepath: "/preview", history });
  const view = render(<App services={services} router={router} />);
  return { services, router, view, history };
}

const location = (history: ReturnType<typeof createMemoryHistory>) => `${history.location.pathname}${history.location.search}`;

describe("the requests contract", () => {
  test("accepts Rails statuses, unknown ones and library states, and refuses requester names in a member's list", () => {
    expect(requestListSchema.safeParse(list([request(), completed, unavailable, request({ id: "4", status: "unknown", book_type: "unknown" })])).success).toBe(true);
    expect(requestListSchema.safeParse(list([request({ requested_by: { name: "Bob", self: false } })])).success).toBe(false);
    expect(requestListSchema.safeParse(list([request({ requested_by: { name: "Bob", self: false } })], { scope: "all" })).success).toBe(true);
    expect(requestListSchema.safeParse(list([request({ download_percent: 101 })])).success).toBe(false);
    expect(requestListSchema.safeParse(list([request({ cover: { url: "http://covers.test/a.jpg", style: "moss" } })])).success).toBe(false);
    expect(requestListSchema.safeParse(list([{ ...request(), library: { state: "available" } } as unknown as RequestSummary])).success).toBe(false);
    expect(requestEnvelopeSchema.safeParse({ account: ACCOUNT, request: detail({ downloads: [{ status: "seeding" as "queued", progress: null }] }) }).success).toBe(false);
  });

  test("a search is trimmed of Ruby white space and kept to two hundred characters", () => {
    expect(trimQuery("  \t dune \n")).toBe("dune");
    expect(trimQuery("  x  ")).toBe(" x ");
    expect(trimQuery("   ")).toBeUndefined();
    expect(trimQuery("é".repeat(205))).toBe("é".repeat(200));
    expect(trimQuery("😀".repeat(201))).toBe("😀".repeat(200));
  });
});

describe("the Requests page", () => {
  test("shows a member's requests with Rails labels, progress and a library link only for a copy the Library opens", async () => {
    const server = requestsServer();
    renderRequests(server);
    expect(await screen.findByRole("heading", { name: "My Requests", level: 1 })).toBeTruthy();
    expect(screen.getByRole("status").textContent).toBe("3 requests");
    const cards = screen.getAllByRole("article");
    expect(cards.map((card) => within(card).getByRole("heading", { level: 3 }).textContent)).toEqual(["Harbor Lights", "Missing Files", "Quiet Shelf"]);
    expect(within(cards[0]!).getByRole("list", { name: "Request state" }).textContent).toBe("EbookDownloading");
    expect(within(cards[0]!).getByRole("progressbar", { name: "Download progress for Harbor Lights" }).getAttribute("value")).toBe("42");
    expect(within(cards[1]!).getByRole("list", { name: "Request state" }).textContent).toBe("AudiobookCompleted");
    expect(within(cards[1]!).queryByRole("link", { name: /Open in Library/ })).toBeNull();
    expect(within(cards[2]!).getByRole("link", { name: "Open in Library for Quiet Shelf" }).getAttribute("href")).toBe("/preview/library/10");
    expect(within(cards[0]!).getByRole("link", { name: "Harbor Lights" }).getAttribute("href")).toBe("/preview/requests/3");
    expect(screen.queryByText(/Requested by/)).toBeNull();
    expect(screen.queryByRole("button", { name: /cancel|retry|request/i })).toBeNull();
    expect(params(lists(server)[0]!)).toEqual({});
  });

  test("an admin sees every request with who asked, except their own", async () => {
    const server = requestsServer(() => ({ body: list([request({ requested_by: { name: "Bob", self: false } }), completed && { ...completed, requested_by: { name: "Ada Reader", self: true } }], { scope: "all" }) }));
    renderRequests(server);
    expect(await screen.findByRole("heading", { name: "All Requests", level: 1 })).toBeTruthy();
    const cards = screen.getAllByRole("article");
    expect(within(cards[0]!).getByText("Requested by Bob")).toBeTruthy();
    expect(within(cards[1]!).queryByText(/Requested by/)).toBeNull();
  });

  test("the filters are Rails' tabs, keep the search, show the counts and mark the current one", async () => {
    const server = requestsServer((recorded) => ({ body: list([request()], { counts: { attention: 2, active: 1 }, filter: { status: null, attention: false, q: params(recorded)["q"] ?? null } }) }));
    const { history } = renderRequests(server, "/preview/requests?q=harbor&page=2");
    const nav = await screen.findByRole("navigation", { name: "Request filters" });
    await waitFor(() => expect(within(nav).getByRole("link", { name: "Need Attention 2" })).toBeTruthy());
    expect(within(nav).getAllByRole("link").map((link) => [link.textContent, link.getAttribute("href"), link.getAttribute("aria-current")])).toEqual([
      ["All", "/preview/requests?q=harbor", "page"],
      ["Need Attention 2", "/preview/requests?q=harbor&attention=true", null],
      ["Active 1", "/preview/requests?q=harbor&status=active", null],
      ["Store Offers", "/preview/requests?q=harbor&status=awaiting_purchase", null],
      ["Completed", "/preview/requests?q=harbor&status=completed", null],
      ["Not Found", "/preview/requests?q=harbor&status=not_found", null],
      ["Cancelled", "/preview/requests?q=harbor&status=failed", null],
    ]);
    expect(params(lists(server)[0]!)).toEqual({ q: "harbor", page: "2" });
    await userEvent.click(within(nav).getByRole("link", { name: "Active 1" }));
    await waitFor(() => expect(location(history)).toBe("/preview/requests?q=harbor&status=active"));
    await waitFor(() => expect(params(lists(server).at(-1)!)).toEqual({ q: "harbor", status: "active" }));
    expect(within(nav).getByRole("link", { name: "Active 1" }).getAttribute("aria-current")).toBe("page");
    expect(within(nav).getByRole("link", { name: "All" }).getAttribute("aria-current")).toBeNull();
  });

  test("a search keeps the current tab, starts again at the first page and Clear removes only the search", async () => {
    const server = requestsServer();
    const { history } = renderRequests(server, "/preview/requests?status=completed&attention=true&page=3");
    const box = await screen.findByRole("searchbox", { name: "Search requests by title or author" });
    await userEvent.type(box, "  quiet  {Enter}");
    await waitFor(() => expect(location(history)).toBe("/preview/requests?status=completed&attention=true&q=quiet"));
    await waitFor(() => expect(params(lists(server).at(-1)!)).toEqual({ status: "completed", attention: "true", q: "quiet" }));
    await userEvent.click(screen.getByRole("button", { name: "Clear" }));
    await waitFor(() => expect(location(history)).toBe("/preview/requests?status=completed&attention=true"));
    expect((screen.getByRole("searchbox", { name: "Search requests by title or author" }) as HTMLInputElement).value).toBe("");
  });

  test("pages are links that keep the filters, and an unknown filter in the address is ignored", async () => {
    const server = requestsServer((recorded) => {
      const at = Number(params(recorded)["page"] ?? "1");
      return { body: list([request({ id: String(at + 100), title: `Page ${at}` })], { page: at, total: 60, total_pages: 3 }) };
    });
    const { history } = renderRequests(server, "/preview/requests?status=bogus&attention=yes&q=a&page=0");
    expect(await screen.findByRole("heading", { name: "Page 1", level: 3 })).toBeTruthy();
    expect(params(lists(server)[0]!)).toEqual({ q: "a" });
    const pages = screen.getByRole("navigation", { name: "Request pages" });
    expect(within(pages).queryByRole("link", { name: "Previous page" })).toBeNull();
    expect(screen.getByRole("status").textContent).toBe("60 requests · Page 1 of 3");
    await userEvent.click(within(pages).getByRole("link", { name: "Next page" }));
    expect(await screen.findByRole("heading", { name: "Page 2", level: 3 })).toBeTruthy();
    expect(location(history)).toBe("/preview/requests?q=a&page=2");
    await userEvent.click(within(screen.getByRole("navigation", { name: "Request pages" })).getByRole("link", { name: "Previous page" }));
    expect(await screen.findByRole("heading", { name: "Page 1", level: 3 })).toBeTruthy();
    expect(location(history)).toBe("/preview/requests?q=a");
  });

  test("a late answer for an earlier filter never replaces the current one", async () => {
    const slow = deferred<{ body: unknown }>();
    const server = requestsServer((recorded) => (params(recorded)["status"] === "completed" ? { body: list([completed]) } : slow.promise));
    renderRequests(server);
    const nav = await screen.findByRole("navigation", { name: "Request filters" });
    await userEvent.click(within(nav).getByRole("link", { name: "Completed" }));
    expect(await screen.findByRole("heading", { name: "Quiet Shelf", level: 3 })).toBeTruthy();
    await act(async () => slow.resolve({ body: list([request({ title: "Stale Answer" })]) }));
    expect(screen.queryByText("Stale Answer")).toBeNull();
    expect(screen.getByRole("heading", { name: "Quiet Shelf", level: 3 })).toBeTruthy();
  });

  test("empty answers say what Rails says for no requests, no attention and no match", async () => {
    const answers: Record<string, string> = {};
    const server = requestsServer(() => ({ body: list([], { counts: { attention: 0, active: 0 } }) }));
    for (const [url, title, body] of [
      ["/preview/requests", "No requests yet", "Discover books"],
      ["/preview/requests?attention=true", "No requests need attention", "All requests are processing normally."],
      ["/preview/requests?q=zola", "No matching requests", "No requests match “zola”."],
      ["/preview/requests?status=failed", "No matching requests", "No requests match your current filter."],
    ] as const) {
      const { view } = renderRequests(server, url);
      expect(await screen.findByRole("heading", { name: title, level: 2 })).toBeTruthy();
      answers[url] = screen.getByText(body).textContent ?? "";
      view.unmount();
    }
    expect(Object.keys(answers).length).toBe(4);
  });

  test("a failed list explains itself and Try again asks once more", async () => {
    let calls = 0;
    const server = requestsServer(() => (++calls === 1 ? error(422, "invalid_query") : { body: list([request()]) }));
    renderRequests(server);
    expect(await screen.findByRole("heading", { name: "That request was not accepted" })).toBeTruthy();
    expect(screen.getByRole("status").textContent).toBe("The requests could not be loaded.");
    await userEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByRole("heading", { name: "Harbor Lights", level: 3 })).toBeTruthy();
  });

  test("an answer for another account locks the page and shows none of its requests", async () => {
    const server = requestsServer(() => ({ body: list([request()], { account: "99" }) }));
    renderRequests(server);
    expect(await screen.findByRole("heading", { name: /account changed/i })).toBeTruthy();
    expect(screen.queryByText("Harbor Lights")).toBeNull();
  });

  test("the classic preview does not offer the page", async () => {
    renderApp({ server: requestsServer(), url: "/sub/preview/requests" });
    expect(await screen.findByRole("heading", { name: "That page is not part of this preview" })).toBeTruthy();
  });
});

describe("one request", () => {
  test("shows its stage, progress, attention fallback, dates and attempts, and goes back to the list it came from", async () => {
    const server = requestsServer();
    const { history } = renderRequests(server, "/preview/requests?status=active");
    await userEvent.click(await screen.findByRole("link", { name: "Harbor Lights" }));
    expect(await screen.findByRole("heading", { name: "Harbor Lights", level: 1 })).toBeTruthy();
    expect(screen.getByText("Downloading: 42% so far.")).toBeTruthy();
    expect(screen.getByRole("progressbar", { name: "Download progress" }).getAttribute("value")).toBe("42");
    expect(screen.getByRole("heading", { name: "Downloads", level: 2 })).toBeTruthy();
    expect(within(screen.getByRole("region", { name: "Downloads" })).getAllByRole("listitem").map((item) => item.textContent)).toEqual(["Downloading42%", "Failed"]);
    expect(screen.queryByRole("link", { name: "Open in Library" })).toBeNull();
    expect(screen.getByText("Requested").nextElementSibling?.querySelector("time")?.getAttribute("datetime")).toBe("2026-11-13T08:00:00.000Z");
    await userEvent.click(screen.getByRole("button", { name: "Back to Requests" }));
    await waitFor(() => expect(location(history)).toBe("/preview/requests?status=active"));
  });

  test("names the attention reason, or Rails' fallback when none is safe to show, and links an openable copy", async () => {
    const server = requestsServer().on("GET", /\/api\/v1\/requests\/5$/, () => ({
      body: { account: ACCOUNT, request: detail({ id: "5", status: "completed", attention_needed: true, download_percent: null, downloads: [], library: { state: "available", publication_id: "10" }, requested_by: { name: "Bob", self: false } }) },
    }));
    renderRequests(server, "/preview/requests/5");
    expect(await screen.findByRole("heading", { name: "Attention Required", level: 2 })).toBeTruthy();
    expect(screen.getByText("This request needs your attention.")).toBeTruthy();
    expect(screen.getByText("Completed and in the library.")).toBeTruthy();
    expect(screen.getByRole("link", { name: "Open in Library" }).getAttribute("href")).toBe("/preview/library/10");
    expect(screen.getByText("Requested by").nextElementSibling?.textContent).toBe("Bob");
    expect(screen.getByRole("link", { name: "Back to Requests" }).getAttribute("href")).toBe("/preview/requests");
  });

  test("another account's request and a missing one are the same not found", async () => {
    const server = requestsServer().on("GET", /\/api\/v1\/requests\/(4|999)$/, () => error(404, "not_found"));
    for (const id of ["4", "999"]) {
      const { view } = renderRequests(server, `/preview/requests/${id}`);
      expect(await screen.findByRole("heading", { name: "This request is not available", level: 1 })).toBeTruthy();
      expect(screen.getByRole("link", { name: "View All Requests" }).getAttribute("href")).toBe("/preview/requests");
      view.unmount();
    }
    expect(server.called("GET", /\/api\/v1\/requests\/(4|999)$/).length).toBe(2);
  });

  test("a known copy the Library cannot open is said honestly and not linked", async () => {
    const server = requestsServer().on("GET", /\/api\/v1\/requests\/2$/, () => ({ body: { account: ACCOUNT, request: { ...unavailable, attention_reason: null, downloads: [{ status: "completed", progress: null }] } } }));
    renderRequests(server, "/preview/requests/2");
    expect(await screen.findByText("Completed. Shelfarr has its files, but the Library here cannot open them right now.")).toBeTruthy();
    expect(screen.queryByRole("link", { name: "Open in Library" })).toBeNull();
  });
});
