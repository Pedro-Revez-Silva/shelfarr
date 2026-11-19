import { describe, expect, test } from "bun:test";
import { createMemoryHistory } from "@tanstack/react-router";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { App } from "../src/App";
import { resetFirstPage } from "../src/components/PageHeading";
import { acquisitionSchema, requestCreationSchema, type Acquisition, type DiscoverAnswer, type DiscoverItem, type RequestDetail } from "../src/contract";
import { createAppRouter } from "../src/router";
import { createServices } from "../src/services";
import { ACCOUNT, deferred, FakeServer, page, session, summary, type Handler } from "./helpers";
import { error } from "./go-helpers";

const SELECTION_REASON = "Search results found. Please review and select a result to download.";

function item(overrides: Partial<DiscoverItem> = {}): DiscoverItem {
  return {
    id: "OL7001W",
    title: "Pride and Prejudice",
    author: "Jane Austen",
    first_publish_year: 1813,
    edition_count: 3,
    cover_url: null,
    source_url: "https://openlibrary.org/works/OL7001W",
    library: [],
    ...overrides,
  };
}

const owned = item({ id: "OL27448W", title: "The Lord of the Rings", source_url: "https://openlibrary.org/works/OL27448W", library: [{ book_type: "ebook", publication_id: "12" }] });
const heard = item({ id: "OL82563W", title: "Harbor Panels", source_url: "https://openlibrary.org/works/OL82563W", library: [{ book_type: "audiobook", publication_id: "11" }] });

function answer(query: string | null, requesting: boolean | undefined): DiscoverAnswer {
  const base: DiscoverAnswer = { account: ACCOUNT, provider: { name: "Open Library", url: "https://openlibrary.org" }, search: "available", query, items: query ? [item(), owned, heard] : [] };
  return requesting === undefined ? base : { ...base, requesting };
}

function render_(server: FakeServer, url: string) {
  resetFirstPage();
  const services = createServices({
    boot: { version: 1, account: ACCOUNT, mount: "/preview", api: "/preview/api/v1", classic_library: null, runtime: "go" },
    csrfToken: () => "session-token",
    fetcher: server.fetcher,
  });
  const history = createMemoryHistory({ initialEntries: [url] });
  const router = createAppRouter({ basepath: "/preview", history });
  render(<App services={services} router={router} />);
  return { history };
}

function discoverServer(requesting: boolean | undefined, create: Handler): FakeServer {
  return new FakeServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session() }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", /\/api\/v1\/discover(\?|$)/, (request) => ({ body: answer(new URL(request.path, "http://shelf.test").searchParams.get("q"), requesting) }))
    .on("POST", /\/api\/v1\/requests$/, create);
}

const created: Handler = () => ({ status: 201, body: { account: ACCOUNT, outcome: "created", request: { id: "41" }, warnings: [] } });

function card(title: string) {
  return screen.getByRole("article", { name: title });
}

describe("the request contract", () => {
  test("accepts each admission outcome only with the links it may carry", () => {
    expect(requestCreationSchema.safeParse({ account: ACCOUNT, outcome: "created", request: { id: "41" }, warnings: [] }).success).toBe(true);
    expect(requestCreationSchema.safeParse({ account: ACCOUNT, outcome: "already_requested" }).success).toBe(true);
    expect(requestCreationSchema.safeParse({ account: ACCOUNT, outcome: "already_in_library", library: null }).success).toBe(true);
    expect(requestCreationSchema.safeParse({ account: ACCOUNT, outcome: "existing", request: { id: "../41" } }).success).toBe(false);
    expect(requestCreationSchema.safeParse({ account: ACCOUNT, outcome: "queued", request: { id: "41" } }).success).toBe(false);
    expect(acquisitionSchema.safeParse({ account: ACCOUNT, request: { id: "41", status: "searching" }, candidates: [{ id: "9", title: "A" }], selection: { state: "seeding", result_id: "9", code: null }, search: null }).success).toBe(false);
  });
});

describe("requesting from Discover", () => {
  test("offers Request ebook only when the server allows requesting and only for works without an ebook in the library", async () => {
    const off = discoverServer(undefined, created);
    render_(off, "/preview/discover?q=pride");
    await screen.findByText("3 results from Open Library for “pride”.");
    expect(screen.queryByRole("button", { name: /Request ebook/ })).toBeNull();
    expect(screen.getByText(/Requesting books is not part of this preview yet\./)).toBeTruthy();
  });

  test("sends one request per press, shows the outcome with a link to track it, and never sends it twice", async () => {
    const pending = deferred<{ status: number; body: unknown }>();
    const server = discoverServer(true, () => pending.promise);
    render_(server, "/preview/discover?q=pride");
    await screen.findByText("3 results from Open Library for “pride”.");
    expect(screen.getByText(/This server is a test setup/)).toBeTruthy();
    expect(within(card("The Lord of the Rings")).queryByRole("button", { name: /Request ebook/ })).toBeNull();
    expect(within(card("Harbor Panels")).getByRole("button", { name: "Request ebook of Harbor Panels" })).toBeTruthy();
    const user = userEvent.setup();
    const button = within(card("Pride and Prejudice")).getByRole("button", { name: "Request ebook of Pride and Prejudice" });
    await user.click(button);
    await user.click(button);
    await user.keyboard("{Enter}");
    expect(button.getAttribute("aria-disabled")).toBe("true");
    expect(within(card("Pride and Prejudice")).getByRole("status").textContent).toBe("Sending the request for “Pride and Prejudice”…");
    const posts = server.called("POST", /\/api\/v1\/requests$/);
    expect(posts.length).toBe(1);
    expect(posts[0]?.body).toEqual({ work_id: "OL7001W", book_type: "ebook" });
    expect(posts[0]?.headers["x-csrf-token"]).toBe("session-token");
    await act(async () => pending.resolve({ status: 201, body: { account: ACCOUNT, outcome: "created", request: { id: "41" }, warnings: ["This title exists as an audiobook. You can still request the ebook."] } }));
    const status = within(card("Pride and Prejudice")).getByRole("status");
    await waitFor(() => expect(status.textContent).toContain("Requested. Shelfarr will look for the ebook"));
    expect(status.textContent).toContain("This title exists as an audiobook.");
    expect(document.activeElement).toBe(status);
    expect(within(status).getByRole("link", { name: "Track it in Requests for Pride and Prejudice" }).getAttribute("href")).toBe("/preview/requests/41");
    expect(within(card("Pride and Prejudice")).queryByRole("button")).toBeNull();
    expect(server.called("POST", /\/api\/v1\/requests$/).length).toBe(1);
  });

  test("explains an earlier request, someone else's request and a copy already in the library without leaking anyone's request", async () => {
    const outcomes: Record<string, unknown> = {
      OL7001W: { account: ACCOUNT, outcome: "existing", request: { id: "41" } },
      OL82563W: { account: ACCOUNT, outcome: "already_requested" },
    };
    const server = discoverServer(true, (request) => ({ body: outcomes[(request.body as { work_id: string }).work_id] }));
    render_(server, "/preview/discover?q=pride");
    await screen.findByText("3 results from Open Library for “pride”.");
    const user = userEvent.setup();
    await user.click(within(card("Pride and Prejudice")).getByRole("button", { name: /Request ebook/ }));
    await waitFor(() => expect(within(card("Pride and Prejudice")).getByRole("status").textContent).toContain("You have already requested this ebook. Nothing new was added."));
    expect(within(card("Pride and Prejudice")).getByRole("link", { name: /Track it in Requests/ }).getAttribute("href")).toBe("/preview/requests/41");
    await user.click(within(card("Harbor Panels")).getByRole("button", { name: /Request ebook/ }));
    await waitFor(() => expect(within(card("Harbor Panels")).getByRole("status").textContent).toBe("Someone else has already requested this ebook. Once it arrives it will be in the library for everyone here."));
    expect(within(within(card("Harbor Panels")).getByRole("status")).queryByRole("link")).toBeNull();
  });

  test("an unconfirmed request is not retried by itself and says how to check before asking again", async () => {
    const server = discoverServer(true, () => ({ status: 503, body: { error: "database_unavailable" } }));
    render_(server, "/preview/discover?q=pride");
    await screen.findByText("3 results from Open Library for “pride”.");
    const user = userEvent.setup();
    await user.click(within(card("Pride and Prejudice")).getByRole("button", { name: /Request ebook/ }));
    await waitFor(() => expect(within(card("Pride and Prejudice")).getByRole("status").textContent).toContain("The server did not confirm the request, so it may or may not have been received."));
    await act(async () => Bun.sleep(50));
    expect(server.called("POST", /\/api\/v1\/requests$/).length).toBe(1);
    expect(within(card("Pride and Prejudice")).getByRole("button", { name: "Try requesting again of Pride and Prejudice" })).toBeTruthy();
  });

  test("a result from an earlier search asks for a new search", async () => {
    const server = discoverServer(true, () => ({ status: 422, body: { error: "work_not_offered" } }));
    render_(server, "/preview/discover?q=pride");
    await screen.findByText("3 results from Open Library for “pride”.");
    await userEvent.setup().click(within(card("Pride and Prejudice")).getByRole("button", { name: /Request ebook/ }));
    await waitFor(() => expect(within(card("Pride and Prejudice")).getByRole("status").textContent).toBe("This result is from an earlier search. Search again, then request it."));
  });
});

function requestDetail(overrides: Partial<RequestDetail> = {}): RequestDetail {
  return {
    id: "41",
    status: "searching",
    attention_needed: true,
    title: "Pride and Prejudice",
    author: "Jane Austen",
    book_type: "ebook",
    cover: { url: null, style: "moss" },
    download_percent: null,
    created_at: "2026-11-19T08:00:00.000Z",
    updated_at: "2026-11-19T08:00:00.000Z",
    completed_at: null,
    next_retry_at: null,
    library: null,
    attention_reason: SELECTION_REASON,
    downloads: [],
    ...overrides,
  };
}

function acquisition(overrides: Partial<Acquisition> = {}): Acquisition {
  return {
    account: ACCOUNT,
    request: { id: "41", status: "searching" },
    candidates: [
      { id: "9", title: "Pride and Prejudice - Jane Austen [EPUB] [en]" },
      { id: "10", title: "Pride and Prejudice (illustrated) - Jane Austen [EPUB] [en]" },
    ],
    selection: null,
    search: null,
    ...overrides,
  };
}

function requestServer(admin: boolean, state: { detail: RequestDetail; acquisition: Acquisition }, select: Handler): FakeServer {
  return new FakeServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(admin ? { admin: { url: "/admin" } } : {}) }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", /\/api\/v1\/requests\/41$/, () => ({ body: { account: ACCOUNT, request: admin ? { ...state.detail, requested_by: { name: "Bob Listener", self: false } } : state.detail } }))
    .on("GET", /\/api\/v1\/requests\/41\/acquisition$/, () => (admin ? { body: state.acquisition } : { status: 404, body: { error: "not_found" } }))
    .on("POST", /\/api\/v1\/requests\/41\/selection$/, select);
}

describe("choosing a copy on a request", () => {
  test("a member is told an administrator chooses and is never asked for candidates", async () => {
    const state = { detail: requestDetail(), acquisition: acquisition() };
    const server = requestServer(false, state, () => ({ status: 404, body: { error: "not_found" } }));
    render_(server, "/preview/requests/41");
    await screen.findByRole("heading", { level: 1, name: "Pride and Prejudice" });
    expect(screen.getByText("An administrator chooses which copy to download.")).toBeTruthy();
    expect(screen.getByText("Copies were found and are waiting for a choice.")).toBeTruthy();
    expect(screen.queryByRole("heading", { name: "Choose a copy" })).toBeNull();
    expect(server.called("GET", /\/acquisition$/)).toEqual([]);
    expect(screen.queryByRole("radio")).toBeNull();
  });

  test("an admin chooses one copy with the keyboard, sees it queued and downloading, then the request completes without a second press", async () => {
    const state = { detail: requestDetail(), acquisition: acquisition() };
    const server = requestServer(true, state, (request) => {
      state.acquisition = acquisition({ selection: { state: "queued", result_id: (request.body as { result_id: string }).result_id, code: null } });
      return { status: 202, body: { account: ACCOUNT, selection: state.acquisition.selection } };
    });
    render_(server, "/preview/requests/41");
    const section = await screen.findByRole("region", { name: "Choose a copy" });
    expect(screen.queryByText("An administrator chooses which copy to download.")).toBeNull();
    const group = within(section).getByRole("group", { name: "Copies found in the Project Gutenberg catalogue" });
    const radios = within(group).getAllByRole("radio");
    expect(radios.map((radio) => radio.getAttribute("value"))).toEqual(["9", "10"]);
    expect(section.textContent).not.toContain("http");
    const user = userEvent.setup();
    await user.click(within(section).getByRole("button", { name: "Download this copy" }));
    expect(within(section).getByText("Choose one copy first.")).toBeTruthy();
    expect(server.called("POST", /\/selection$/)).toEqual([]);
    radios[0]?.focus();
    await user.keyboard("{ArrowDown}");
    expect((radios[1] as HTMLInputElement).checked).toBe(true);
    await user.keyboard("{ArrowUp}");
    expect((radios[0] as HTMLInputElement).checked).toBe(true);
    await user.click(within(section).getByRole("button", { name: "Download this copy" }));
    await waitFor(() => expect(within(section).getByRole("status").textContent).toBe("Download queued. It starts as soon as the server finishes its current search."));
    expect(server.called("POST", /\/selection$/).map((request) => request.body)).toEqual([{ result_id: "9" }]);
    expect(within(section).queryByRole("button", { name: "Download this copy" })).toBeNull();
    state.acquisition = acquisition({ selection: { state: "downloading", result_id: "9", code: null } });
    await waitFor(() => expect(within(section).getByRole("status").textContent).toBe("Downloading the chosen copy. This page updates by itself."), { timeout: 4000 });
    expect(within(section).getByRole("progressbar", { name: "Download in progress" })).toBeTruthy();
    const detailsBefore = server.called("GET", /\/requests\/41$/).length;
    state.detail = requestDetail({ status: "completed", attention_needed: false, attention_reason: null, completed_at: "2026-11-19T08:05:00.000Z", library: { state: "available", publication_id: "77" } });
    state.acquisition = acquisition({ request: { id: "41", status: "completed" }, candidates: [], selection: { state: "completed", result_id: "9", code: null } });
    await waitFor(() => expect(screen.getByRole("link", { name: "Open in Library" }).getAttribute("href")).toBe("/preview/library/77"), { timeout: 4000 });
    expect(screen.getByText("Completed and in the library.")).toBeTruthy();
    expect(screen.queryByRole("region", { name: "Choose a copy" })).toBeNull();
    expect(server.called("GET", /\/requests\/41$/).length).toBeGreaterThan(detailsBefore);
    expect(server.called("POST", /\/selection$/).length).toBe(1);
  }, 15000);

  test("a failed download says nothing was added and lets the admin choose again; a refused choice is explained", async () => {
    const state = { detail: requestDetail(), acquisition: acquisition({ selection: { state: "failed", result_id: "9", code: "provider-busy" } }) };
    const server = requestServer(true, state, () => ({ status: 409, body: { error: "acquisition_busy" } }));
    render_(server, "/preview/requests/41");
    const section = await screen.findByRole("region", { name: "Choose a copy" });
    expect(within(section).getByRole("status").textContent).toBe("The download did not finish. The catalogue was busy. Nothing was added to the library; you can choose a copy again.");
    const user = userEvent.setup();
    await user.click(within(section).getAllByRole("radio")[1] as HTMLElement);
    await user.click(within(section).getByRole("button", { name: "Download this copy" }));
    expect((await within(section).findByRole("alert")).textContent).toBe("Another download is running on this server. Try again when it has finished.");
    expect(server.called("POST", /\/selection$/).map((request) => request.body)).toEqual([{ result_id: "10" }]);
  });

  test("a server without the acquisition flow shows the request as before", async () => {
    const state = { detail: requestDetail(), acquisition: acquisition() };
    const server = requestServer(true, state, () => ({ status: 404, body: { error: "not_found" } })).on("GET", /\/api\/v1\/requests\/41\/acquisition$/, () => error(404, "not_found"));
    render_(server, "/preview/requests/41");
    await screen.findByRole("heading", { level: 1, name: "Pride and Prejudice" });
    await waitFor(() => expect(server.called("GET", /\/acquisition$/).length).toBe(1));
    expect(screen.queryByRole("region", { name: "Choose a copy" })).toBeNull();
    expect(screen.queryByRole("radio")).toBeNull();
  });
});
