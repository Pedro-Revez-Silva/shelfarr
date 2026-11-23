import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { AccountSettings, CopyDetails, Profile, RequestCopy, RequestDetail, RequestList, RequestSummary } from "../src/contract";
import { placeOf } from "../src/components/Navigation";
import { ACCOUNT, FakeServer, page, renderApp, session, summary } from "./helpers";

afterEach(cleanup);

function request(overrides: Partial<RequestSummary> = {}): RequestSummary {
  return {
    id: "7",
    status: "searching",
    attention_needed: false,
    title: "The Dispossessed",
    author: "Ursula K. Le Guin",
    book_type: "ebook",
    cover: { url: null, style: "moss" },
    download_percent: null,
    created_at: "2026-11-20T08:00:00.000Z",
    updated_at: "2026-11-20T08:00:00.000Z",
    completed_at: null,
    next_retry_at: null,
    library: null,
    book_page: { source: "openlibrary", id: "OL5004W" },
    ...overrides,
  };
}

function copyDetails(overrides: Partial<CopyDetails> = {}): CopyDetails {
  return {
    choice: "select",
    indexer: null,
    seeders: null,
    leechers: null,
    score: null,
    high_confidence: false,
    language_matches: true,
    structure: null,
    bitrate_kbps: null,
    preference_adjustment: 0,
    size_limit: null,
    manual_review: false,
    blocklist_reason: null,
    info_url: null,
    ...overrides,
  };
}

function copy(id: string, overrides: Partial<RequestCopy> = {}, details: Partial<CopyDetails> = {}): RequestCopy {
  return { id, title: `Copy ${id}.epub`, format: "EPUB", size_bytes: 1000, language: "English", source: "Prowlarr", state: "pending", skipped: false, downloadable: true, details: copyDetails(details), ...overrides };
}

const memberActions = { cancel: true, remove: null, withdraw: null, retry: false, search_again: false, manual_download: false, replaces_library_file: false, upload_url: null, download_url: null } as const;

function detail(overrides: Partial<RequestDetail> = {}): RequestDetail {
  return { ...request(), attention_reason: null, downloads: [], choice_needed: false, notes: null, collection_title: null, retry_count: 0, actions: memberActions, store_offers: [], ...overrides };
}

function list(items: RequestSummary[], overrides: Partial<RequestList> = {}): RequestList {
  return { account: ACCOUNT, scope: "own", filter: { status: null, attention: false, q: null }, counts: { attention: 0, active: items.length }, page: 1, per_page: 25, total: items.length, total_pages: 1, items, ...overrides };
}

function railsServer(found: RequestDetail = detail(), admin = false): FakeServer {
  return new FakeServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(admin ? { admin: { url: "/sub/admin" }, notifications: { url: "/sub/notifications", unread: 3 } } : { notifications: { url: "/sub/notifications", unread: 0 } }) }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", /\/api\/v1\/requests(\?|$)/, () => ({ body: list([request(), request({ id: "8", title: "Middlemarch", status: "completed" })], admin ? { scope: "all" } : {}) }))
    .on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found } }));
}

const settings: AccountSettings = {
  admin: false,
  member_since: "2026-01-02T10:00:00.000Z",
  requests: { total: 4, completed: 2, pending: 1 },
  two_factor: { enabled: false },
  oidc: { configured: true, provider: "Pocket ID", linked: false, link_page: "/sub/profile", password_required: true },
  api_tokens: [
    { id: "5", name: "Pixel 9", prefix: "shf_abc12345", scopes: ["library:read"], app: true, state: "active", created_at: "2026-11-01T10:00:00.000Z", last_used_at: null, expires_at: null },
    { id: "6", name: "Backup script", prefix: "shf_def67890", scopes: ["requests:read"], app: false, state: "revoked", created_at: "2026-10-01T10:00:00.000Z", last_used_at: "2026-10-02T10:00:00.000Z", expires_at: null },
  ],
  token_scopes: [
    { scope: "search:read", label: "Search" },
    { scope: "requests:read", label: "Read requests" },
  ],
  links: { kobo_readers: "/sub/kobo_devices", kobo_accounts: "/sub/kobo_accounts", hardcover: "/sub/profile#hardcover", sign_out: "/sub/session", phone_app: "/sub/consumer/connect", reading_library: "/sub/read", android_app: "/sub/apps/android" },
  server: { release: "Shelfarr 1.0 beta", beta: true, series: "1.0" },
};

function profile(overrides: Partial<AccountSettings> = {}): Profile {
  return { id: ACCOUNT, username: "rae", name: "Rae Reader", settings: { ...settings, ...overrides } };
}

function accountServer(answer: Profile = profile()): FakeServer {
  return railsServer().on("GET", /\/api\/v1\/account$/, () => ({ body: { account: ACCOUNT, profile: answer } }));
}

describe("the Rails preview shell", () => {
  test("Find is current for Find, Book pages and every request address", () => {
    expect(["/find", "/discover", "/books/openlibrary/OL1W", "/requests", "/requests/7", "/library", "/account/security", "/admin/settings", "/"].map((path) => placeOf(path, "/sub/preview"))).toEqual([
      "find",
      "find",
      "find",
      "find",
      "find",
      "library",
      "account",
      "server",
      null,
    ]);
  });

  test("an administrator gets Server and a bell that names the unread count", async () => {
    renderApp({ server: railsServer(detail(), true) });
    const bell = await screen.findByRole("link", { name: "Notifications, 3 unread" });
    expect(bell.getAttribute("href")).toBe("/sub/preview/notifications");
    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(within(nav).getAllByRole("link").map((link) => link.textContent)).toEqual(["Library", "Find", "Account", "Server"]);
  });

  test("the empty Find page lists the member's open requests and links to every request", async () => {
    renderApp({ server: railsServer(), url: "/sub/preview/find" });
    const section = await screen.findByRole("region", { name: "Your requests" });
    expect(within(section).getAllByRole("link").map((link) => [link.textContent, link.getAttribute("href")])).toEqual([
      ["All requests", "/sub/preview/requests"],
      ["The Dispossessed", "/sub/preview/requests/7"],
    ]);
    const tabs = screen.getByRole("navigation", { name: "Find" });
    expect(within(tabs).getByRole("link", { name: "Search books" }).getAttribute("aria-current")).toBe("page");
    expect(within(tabs).getByRole("link", { name: "Requests" }).getAttribute("aria-current")).toBeNull();
  });

  test("an old Discover address opens Find with the same search", async () => {
    const server = railsServer().on("GET", /\/api\/v1\/discover\?/, () => ({ body: { account: ACCOUNT, query: "dune", providers: ["Open Library"], unavailable: [], items: [] } }));
    const { router } = renderApp({ server, url: "/sub/preview/discover?q=dune" });
    await waitFor(() => expect(router.state.location.pathname).toBe("/find"));
    expect(router.state.location.search).toEqual({ q: "dune" });
    expect(await screen.findByRole("heading", { name: "Find", level: 1 })).toBeTruthy();
  });
});

describe("one request in the Rails preview", () => {
  test("a member sees the plain stage, the steps, the Book page and a confirmed cancel", async () => {
    const server = railsServer(detail({ attention_needed: true, choice_needed: true })).on("POST", /\/requests\/7\/cancel$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "failed" } } }));
    renderApp({ server, url: "/sub/preview/requests/7" });
    expect(await screen.findByText("Copies were found, but none was picked automatically. An administrator can choose one; this page updates when the ebook is in the library.")).toBeTruthy();
    expect(screen.getByText("Step 3 of 5 · Choose a copy")).toBeTruthy();
    expect(screen.queryByText("Attention Required")).toBeNull();
    expect(screen.getByRole("link", { name: "Open the Book page for The Dispossessed" }).getAttribute("href")).toBe("/sub/preview/books/openlibrary/OL5004W");
    expect(screen.queryByRole("region", { name: "Administrator tools" })).toBeNull();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Cancel request" }));
    expect(server.called("POST", /cancel$/)).toHaveLength(0);
    expect(screen.getByRole("group", { name: "Cancel this request? If a download is running, it is stopped and its files are deleted from the download client." })).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Yes, cancel it" }));
    await waitFor(() => expect(server.called("POST", /\/requests\/7\/cancel$/)).toHaveLength(1));
    expect(server.called("POST", /cancel$/)[0]?.headers["x-csrf-token"]).toBe("token-123");
  });

  test("a waiting purchase shows each store offer with its seller and the upload after buying", async () => {
    const offer = { id: "4", title: "The Dispossessed", author: null, provider: "Kobo", drm: "DRM-free", price: "EUR 9.99", formats: ["EPUB"], language: "English", quoted_at: null, url: "https://store.example/en-us/book/abc" };
    renderApp({ server: railsServer(detail({ status: "awaiting_purchase", store_offers: [offer], actions: { ...memberActions, upload_url: "/sub/uploads/new?request_id=7" } })), url: "/sub/preview/requests/7" });
    const offers = await screen.findByRole("region", { name: "Buy it DRM-free" });
    expect(within(offers).getByRole("link", { name: "View and buy at Kobo (opens in a new tab)" }).getAttribute("href")).toBe(offer.url);
    expect(within(offers).getByRole("link", { name: "Upload after buying" }).getAttribute("href")).toBe("/sub/preview/library/uploads?request=7");
    expect(screen.getByText("Waiting for a purchase.")).toBeTruthy();
  });

  test("an administrator chooses a copy, adds a magnet link and sees the model's refusal", async () => {
    const copies = { selectable: true, revision: "/", looking_for: "English", search_blocked: null, candidates: [copy("31", { title: "Dispossessed.epub", source: "Project Gutenberg" })] };
    const adminActions = { ...memberActions, cancel: false, remove: "admin_remove" as const, retry: true, search_again: true, manual_download: true };
    const server = railsServer(detail({ requested_by: { name: "Rae Reader", self: false }, attention_reason: "No copies after 3 searches", actions: adminActions, copies, events: [{ title: "Dispatch Failed", message: "Client down", level: "error", at: "2026-11-20T09:00:00.000Z" }] }), true)
      .on("POST", /\/requests\/7\/selection$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "downloading" } } }))
      .on("POST", /\/requests\/7\/manual$/, () => ({ status: 422, body: { error: "manual_rejected", message: "Enter a valid magnet link" } }));
    renderApp({ server, url: "/sub/preview/requests/7" });
    const tools = await screen.findByRole("region", { name: "Administrator tools" });
    const user = userEvent.setup();
    await user.click(within(tools).getByLabelText("Dispossessed.epub"));
    await user.click(within(tools).getByRole("button", { name: "Download this copy" }));
    await waitFor(() => expect(server.called("POST", /selection$/)[0]?.body).toEqual({ result_id: "31", expected_revision: "/", replace_library_file: false }));
    await user.click(within(tools).getByText("Add a link or file"));
    await user.type(within(tools).getByLabelText("Magnet link", { exact: true }), "http://nope");
    await user.click(within(tools).getByRole("button", { name: "Add magnet link" }));
    expect(await within(tools).findByText("Enter a valid magnet link")).toBeTruthy();
    expect(server.called("POST", /manual$/)[0]?.body).toEqual({ kind: "magnet", magnet_url: "http://nope", replace_library_file: false });
    expect(within(tools).getByText("No copies after 3 searches")).toBeTruthy();
    expect(within(tools).getByText("Client down")).toBeTruthy();
  });

  test("a member can upload without store offers", async () => {
    renderApp({ server: railsServer(detail({ actions: { ...memberActions, upload_url: "/sub/uploads/new?request_id=7" } })), url: "/sub/preview/requests/7" });
    expect((await screen.findByRole("link", { name: "Upload a file for this request" })).getAttribute("href")).toBe("/sub/preview/library/uploads?request=7");
  });

  test("a completed request opens its Book page and keeps a link to its details", async () => {
    renderApp({ server: railsServer(), url: "/sub/preview/requests" });
    expect((await screen.findByRole("link", { name: "Request details for Middlemarch" })).getAttribute("href")).toBe("/sub/preview/requests/8");
  });

  test("a confirmed change of role locks the page instead of keeping another account's requests on screen", async () => {
    let admin = true;
    const server = railsServer(detail({ requested_by: { name: "Someone", self: false }, notes: "private note" }), true).on("GET", /\/api\/v1\/session$/, () => ({ body: session(admin ? { admin: { url: "/sub/admin" } } : {}) }));
    const { services } = renderApp({ server, url: "/sub/preview/requests/7" });
    expect(await screen.findByText("private note")).toBeTruthy();
    admin = false;
    await act(async () => services.revalidate());
    await waitFor(() => expect(screen.queryByText("private note")).toBeNull());
    expect(services.guard.getState().status).toBe("access_changed");
  }, 15000);

  test("removing a request asks first and returns to the list", async () => {
    const server = railsServer(detail({ status: "completed", actions: { ...memberActions, cancel: false, remove: "delete_history" } })).on("POST", /\/requests\/7\/remove$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "removed" } } }));
    const { router } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Delete request history" }));
    await user.click(screen.getByRole("button", { name: "Yes, delete it" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/requests"));
    expect(server.called("POST", /remove$/)).toHaveLength(1);
  });
});

describe("a requester cancels and removes an unfinished request in the Rails preview", () => {
  const first = "a".repeat(32);
  const second = "b".repeat(32);

  function offering(clientJobs: number, revision = first, starting = false): RequestDetail {
    return detail({ status: "downloading", actions: { ...memberActions, withdraw: { revision, client_jobs: clientJobs, starting } } });
  }

  function removed() {
    return { body: { account: ACCOUNT, request: { id: "7", status: "removed" } } };
  }

  test("one Cancel request names exactly what happens, the client choice can be changed or dropped before confirming, and confirming sends that choice", async () => {
    const server = railsServer(offering(1)).on("POST", /\/requests\/7\/withdraw$/, removed);
    const { router } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    expect((await screen.findAllByRole("button", { name: "Cancel request" })).length).toBe(1);
    await user.click(screen.getByRole("button", { name: "Cancel request" }));
    const question = screen.getByRole("group", { name: "Cancel this request?" });
    expect(question.textContent).toBe(
      "Cancel this request?It is removed from your requests and Shelfarr stops working on it. Files already in the library stay.Also remove its download from the download clientThe download client keeps it and the files already downloaded.Yes, cancel itKeep it",
    );
    expect(document.activeElement?.textContent).toBe("Keep it");
    const choice = within(question).getByRole("checkbox", { name: "Also remove its download from the download client" }) as HTMLInputElement;
    expect(choice.checked).toBe(false);
    await user.click(choice);
    expect(within(question).getByText("Shelfarr asks the download client to remove it. Files already downloaded stay on disk. If the client can't be reached, the request is still removed and the client keeps it.")).toBeTruthy();
    expect(within(question).getByRole("button", { name: "Yes, cancel it and remove the download" })).toBeTruthy();
    await user.click(choice);
    expect(within(question).getByText("The download client keeps it and the files already downloaded.")).toBeTruthy();
    await user.click(within(question).getByRole("button", { name: "Keep it" }));
    expect(screen.queryByRole("group", { name: "Cancel this request?" })).toBeNull();
    expect(document.activeElement?.textContent).toBe("Cancel request");
    expect(server.called("POST", /\/requests\/7\/(withdraw|cancel)$/)).toHaveLength(0);

    await user.click(screen.getByRole("button", { name: "Cancel request" }));
    const reopened = screen.getByRole("checkbox", { name: "Also remove its download from the download client" }) as HTMLInputElement;
    expect(reopened.checked).toBe(false);
    await user.click(reopened);
    await user.click(screen.getByRole("button", { name: "Yes, cancel it and remove the download" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/requests"));
    const sent = server.called("POST", /\/requests\/7\/withdraw$/);
    expect(sent.map((call) => call.body)).toEqual([{ expected_revision: first, remove_client_jobs: true }]);
    expect(sent[0]?.headers["x-csrf-token"]).toBe("token-123");
    expect(server.called("POST", /cancel$/)).toHaveLength(0);
  }, 15000);

  test("a request with no client job says no client is contacted and never sends the client choice", async () => {
    const server = railsServer(offering(0)).on("POST", /\/requests\/7\/withdraw$/, removed);
    renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    const question = screen.getByRole("group", { name: "Cancel this request?" });
    expect(within(question).getByText("No download client is contacted.")).toBeTruthy();
    expect(within(question).queryByRole("checkbox")).toBeNull();
    await user.click(within(question).getByRole("button", { name: "Yes, cancel it" }));
    await waitFor(() => expect(server.called("POST", /withdraw$/).map((call) => call.body)).toEqual([{ expected_revision: first, remove_client_jobs: false }]));
  });

  test("a download that is starting is named with what a client does to it, and several jobs are counted", async () => {
    renderApp({ server: railsServer(offering(2, first, true)), url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    const question = screen.getByRole("group", { name: "Cancel this request?" });
    expect(within(question).getByText("A download is starting right now. Shelfarr stops it, and if it was going to a download client, the client removes it together with anything it already downloaded.")).toBeTruthy();
    expect(within(question).queryByText("No download client is contacted.")).toBeNull();
    await user.click(within(question).getByRole("checkbox", { name: "Also remove its 2 downloads from the download client" }));
    expect(within(question).getByRole("button", { name: "Yes, cancel it and remove the 2 downloads" })).toBeTruthy();
  });

  test("while the answer is pending the question can't be closed, changed or sent again, and the answer still returns to the list", async () => {
    let answer: () => void = () => undefined;
    const server = railsServer(offering(1)).on("POST", /\/requests\/7\/withdraw$/, () => new Promise((resolve) => (answer = () => resolve(removed()))));
    const { router } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    await user.click(screen.getByRole("button", { name: "Yes, cancel it" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Cancelling…" })).toBeTruthy());
    await user.click(screen.getByRole("button", { name: "Keep it" }));
    await user.click(screen.getByRole("button", { name: "Cancelling…" }));
    expect(screen.getByRole("group", { name: "Cancel this request?" })).toBeTruthy();
    expect((screen.getByRole("checkbox") as HTMLInputElement).disabled).toBe(true);
    expect(server.called("POST", /withdraw$/)).toHaveLength(1);
    await act(async () => answer());
    await waitFor(() => expect(router.state.location.pathname).toBe("/requests"));
  }, 15000);

  test("a refresh that finds the request already gone while the answer is pending still returns to the list", async () => {
    let answer: () => void = () => undefined;
    let gone = false;
    const server = railsServer(offering(1))
      .on("GET", /\/api\/v1\/requests\/7$/, () => (gone ? { status: 404, body: { error: "not_found" } } : { body: { account: ACCOUNT, request: offering(1) } }))
      .on("POST", /\/requests\/7\/withdraw$/, () => new Promise((resolve) => (answer = () => resolve(removed()))));
    const { router, services } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    await user.click(screen.getByRole("button", { name: "Yes, cancel it" }));
    gone = true;
    await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
    await waitFor(() => expect(screen.queryByRole("group", { name: "Cancel this request?" })).toBeNull());
    await act(async () => answer());
    await waitFor(() => expect(router.state.location.pathname).toBe("/requests"));
  }, 15000);

  test("a request page opened with a trailing slash still returns to the list", async () => {
    const server = railsServer(offering(0)).on("POST", /\/requests\/7\/withdraw$/, removed);
    const { router } = renderApp({ server, url: "/sub/preview/requests/7/" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    await user.click(screen.getByRole("button", { name: "Yes, cancel it" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/requests"));
  });

  test("an answer that arrives after the person moved to another page leaves them there", async () => {
    let answer: () => void = () => undefined;
    const server = railsServer(offering(1)).on("POST", /\/requests\/7\/withdraw$/, () => new Promise((resolve) => (answer = () => resolve(removed()))));
    const { router } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    await user.click(screen.getByRole("button", { name: "Yes, cancel it" }));
    await act(async () => void router.navigate({ to: "/find" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/find"));
    await act(async () => answer());
    await waitFor(() => expect(server.called("POST", /withdraw$/)).toHaveLength(1));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 50)));
    expect(router.state.location.pathname).toBe("/find");
  }, 15000);

  test("a question left open while the request changes is withdrawn and forgotten, so it never returns by itself", async () => {
    let found = offering(1);
    const server = railsServer(found)
      .on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found } }))
      .on("POST", /\/requests\/7\/withdraw$/, removed);
    const { services } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    await user.click(screen.getByRole("checkbox", { name: "Also remove its download from the download client" }));
    found = offering(0, second);
    await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
    await waitFor(() => expect(screen.queryByRole("group", { name: "Cancel this request?" })).toBeNull());
    expect(screen.getByText("This request changed while you were deciding. Check what cancelling it does now and ask again.").getAttribute("role")).toBe("status");
    expect(document.activeElement?.textContent).toBe("Cancel request");
    found = offering(1, first);
    await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
    await waitFor(() => expect(server.called("GET", /\/requests\/7$/).length).toBeGreaterThan(2));
    expect(screen.queryByRole("group", { name: "Cancel this request?" })).toBeNull();
    await user.click(screen.getByRole("button", { name: "Cancel request" }));
    expect(screen.queryByText(/changed while you were deciding/)).toBeNull();
    expect((screen.getByRole("checkbox", { name: "Also remove its download from the download client" }) as HTMLInputElement).checked).toBe(false);
    await user.click(screen.getByRole("button", { name: "Yes, cancel it" }));
    await waitFor(() => expect(server.called("POST", /withdraw$/).map((call) => call.body)).toEqual([{ expected_revision: first, remove_client_jobs: false }]));
  }, 30000);

  test("a cancellation the server refuses because the request changed says so, reads the request again and stays on the page", async () => {
    let found = offering(1);
    const message = "This request changed since the page was read. The page now shows it as it is; check what cancelling it does and choose again.";
    const server = railsServer(found)
      .on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found } }))
      .on("POST", /\/requests\/7\/withdraw$/, () => {
        found = offering(0, second);
        return { status: 409, body: { error: "request_changed", message } };
      });
    const { router } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    await user.click(screen.getByRole("button", { name: "Yes, cancel it" }));
    expect((await screen.findByRole("alert")).textContent).toBe(message);
    await waitFor(() => expect(screen.queryByRole("group", { name: "Cancel this request?" })).toBeNull());
    expect(screen.queryByText(/changed while you were deciding/)).toBeNull();
    expect(document.activeElement?.textContent).toBe("Cancel request");
    expect(router.state.location.pathname).toBe("/requests/7");
  }, 15000);

  test("a refusal that also takes the cancellation away keeps the server's reason on screen", async () => {
    let found = offering(1);
    const message = "This request has an upload or Audible backup in progress. Wait for it to finish, or retry its recovery, before cancelling the request.";
    const server = railsServer(found)
      .on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found } }))
      .on("POST", /\/requests\/7\/withdraw$/, () => {
        found = detail({ status: "downloading", actions: { ...memberActions, cancel: false } });
        return { status: 409, body: { error: "cannot_remove", message } };
      });
    renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    await user.click(screen.getByRole("button", { name: "Yes, cancel it" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Cancel request" })).toBeNull());
    expect(screen.getByRole("alert").textContent).toBe(message);
  });

  test("an older server without the offer keeps the existing cancel, which keeps the request", async () => {
    const { withdraw: _withdraw, ...olderActions } = memberActions;
    const older = { ...detail(), actions: olderActions } as unknown as RequestDetail;
    renderApp({ server: railsServer(older), url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Cancel request" }));
    expect(screen.getByRole("group", { name: "Cancel this request? If a download is running, it is stopped and its files are deleted from the download client." })).toBeTruthy();
  });

  test("an administrator's own request keeps the existing cancel and the single removal in the inspector, even if an offer is present", async () => {
    const adminActions = { ...memberActions, remove: "admin_remove" as const, withdraw: { revision: first, client_jobs: 1, starting: false } };
    renderApp({ server: railsServer(detail({ requested_by: { name: "Rae", self: true }, actions: adminActions }), true), url: "/sub/preview/requests/7" });
    const tools = await screen.findByRole("region", { name: "Administrator tools" });
    expect(screen.getAllByRole("button", { name: "Remove request" })).toEqual([within(tools).getByRole("button", { name: "Remove request" })]);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Cancel request" }));
    expect(screen.getByRole("group", { name: "Cancel this request? If a download is running, it is stopped and its files are deleted from the download client." })).toBeTruthy();
    expect(screen.queryByRole("group", { name: "Cancel this request?" })).toBeNull();
  });
});

describe("a request's copies for an administrator", () => {
  const adminActions = { ...memberActions, cancel: false, remove: "admin_remove" as const, retry: false, search_again: true, manual_download: true };

  function copiesServer(found: RequestDetail): FakeServer {
    return railsServer({ requested_by: { name: "Rae", self: false }, ...found }, true);
  }

  test("an old Manage Results link opens the Copies section with every fact the classic screen showed, and choosing another copy names the one it replaces", async () => {
    const candidates = [
      copy("40", { title: "Dispossessed.Retail.epub", state: "selected" }, { choice: "selected", score: 96, high_confidence: true, seeders: 40, leechers: 2 }),
      copy(
        "41",
        { title: "Dispossessed.de.epub", state: "rejected", language: "German", source: "Jackett" },
        { choice: "select_instead", indexer: "TorrentLeech", score: 71, seeders: 12, leechers: 3, language_matches: false, preference_adjustment: -5, size_limit: { label: "Size -20 (too large)", explanation: "Larger than the configured maximum file size" }, manual_review: true, info_url: "https://tracker.example/t/41" },
      ),
      copy("42", { title: "Dispossessed.m4b", state: "rejected", format: "M4B", skipped: true }, { choice: "retry_anyway", structure: "single_file", bitrate_kbps: 128, blocklist_reason: "Import failed: not a book" }),
      copy("43", { title: "Dispossessed.nolink", state: "rejected", downloadable: false }, { choice: "skipped" }),
    ];
    const found = detail({ status: "downloading", requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: false, revision: "40/9", looking_for: "English", search_blocked: "Cannot refresh search while an acquisition or library import is active or awaiting recovery.", candidates } });
    const server = copiesServer({ ...found, actions: { ...adminActions, search_again: false } }).on("POST", /\/requests\/7\/selection$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "downloading" } } }));
    renderApp({ server, url: "/sub/preview/requests/7#copies" });
    const section = (await screen.findByText("Copies (4)")).closest("details");
    if (!section) throw new Error("Copies section missing");
    await waitFor(() => expect(section.open).toBe(true));
    expect(document.activeElement?.textContent).toBe("Copies (4)");
    const view = within(section);
    expect(view.getByText("Looking for English · 4 copies found, best first")).toBeTruthy();
    expect(view.getByText("Cannot refresh search while an acquisition or library import is active or awaiting recovery.")).toBeTruthy();
    expect(view.queryByRole("button", { name: "Search again" })).toBeNull();
    const rows = view.getAllByRole("row").slice(1);
    expect(rows.map((row) => row.querySelector("th")?.textContent)).toEqual([
      "Dispossessed.Retail.epub · chosen",
      "Dispossessed.de.epubTorrentLeechPreference −5Size -20 (too large): Larger than the configured maximum file sizeManual reviewRelease page for Dispossessed.de.epub (opens in a new tab)",
      "Dispossessed.m4b · skipped beforeSingle file128 kbpsSkipped because: Import failed: not a book",
      "Dispossessed.nolink · skipped · no download link",
    ]);
    expect(rows.map((row) => [...row.querySelectorAll("td[data-label]")].map((cell) => cell.textContent))).toEqual([
      ["EPUB", "1000 B", "English", "Prowlarr", "96% (high)", "40 seeding, 2 leeching"],
      ["EPUB", "1000 B", "German · not English", "Jackett", "71%", "12 seeding, 3 leeching"],
      ["M4B", "1000 B", "English", "Prowlarr", "Unknown", "Not listed"],
      ["EPUB", "1000 B", "English", "Prowlarr", "Unknown", "Not listed"],
    ]);
    expect(view.getByRole("link", { name: "Release page for Dispossessed.de.epub (opens in a new tab)" }).getAttribute("href")).toBe("https://tracker.example/t/41");
    const radios = view.getAllByRole("radio") as HTMLInputElement[];
    expect(radios.map((radio) => [radio.disabled, radio.checked])).toEqual([
      [true, false],
      [false, false],
      [false, false],
      [true, false],
    ]);
    const user = userEvent.setup();
    await user.click(view.getByRole("button", { name: "Download this copy" }));
    expect(view.getByRole("alert").textContent).toContain("Choose one copy that can be downloaded first.");
    expect(server.called("POST", /selection$/)).toHaveLength(0);
    await user.click(view.getByLabelText("Dispossessed.m4b"));
    expect(view.getByRole("button", { name: "Try this copy again anyway" })).toBeTruthy();
    await user.click(view.getByLabelText("Dispossessed.de.epub"));
    await user.click(view.getByRole("button", { name: "Download this copy instead" }));
    await waitFor(() => expect(server.called("POST", /selection$/).map((call) => call.body)).toEqual([{ result_id: "41", expected_revision: "40/9", replace_library_file: false }]));
    expect(await view.findByText("Download queued. This page updates as it goes.")).toBeTruthy();
  });

  test("choosing a copy for a book already in the library asks before replacing its file", async () => {
    const found = detail({ status: "completed", actions: { ...adminActions, replaces_library_file: true }, copies: { selectable: false, revision: "50/3", looking_for: "English", search_blocked: "Cannot refresh search for a completed request.", candidates: [copy("50", { state: "selected" }, { choice: "selected" }), copy("51", { state: "rejected" }, { choice: "select_instead" })] } });
    const server = copiesServer(found).on("POST", /\/requests\/7\/selection$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "downloading" } } }));
    renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByText("Copies (2)"));
    await user.click(screen.getByLabelText("Copy 51.epub"));
    await user.click(screen.getByRole("button", { name: "Download this copy instead" }));
    const prompt = "Replace the existing library file? The current file stays until the new download imports successfully. A failed download leaves it unchanged.";
    const ask = screen.getByRole("group", { name: prompt });
    expect(document.activeElement?.textContent).toBe("Keep the current file");
    await user.click(within(ask).getByRole("button", { name: "Keep the current file" }));
    expect(screen.queryByRole("group", { name: prompt })).toBeNull();
    expect(server.called("POST", /selection$/)).toHaveLength(0);
    await user.click(screen.getByRole("button", { name: "Download this copy instead" }));
    await user.click(screen.getByRole("button", { name: "Yes, replace the file" }));
    await waitFor(() => expect(server.called("POST", /selection$/).map((call) => call.body)).toEqual([{ result_id: "51", expected_revision: "50/3", replace_library_file: true }]));
  });

  test("a choice the server refuses because the copies changed says so and reads the request again", async () => {
    const found = detail({ actions: adminActions, copies: { selectable: true, revision: "/", looking_for: "English", search_blocked: null, candidates: [copy("60"), copy("61")] } });
    const server = copiesServer(found).on("POST", /\/requests\/7\/selection$/, () => ({
      status: 409,
      body: { error: "copies_changed", message: "The chosen copy changed since this page was read. The page now shows the current copies; choose again if you still want this one." },
    }));
    renderApp({ server, url: "/sub/preview/requests/7" });
    const section = (await screen.findByText("Copies (2)")).closest("details");
    if (!section) throw new Error("Copies section missing");
    await waitFor(() => expect(section.open).toBe(true));
    expect((within(section).getByLabelText("Copy 60.epub") as HTMLInputElement).checked).toBe(false);
    const reads = server.called("GET", /\/requests\/7$/).length;
    const user = userEvent.setup();
    await user.click(within(section).getByLabelText("Copy 60.epub"));
    await user.click(within(section).getByRole("button", { name: "Download this copy" }));
    expect(await within(section).findByText("The chosen copy changed since this page was read. The page now shows the current copies; choose again if you still want this one.")).toBeTruthy();
    await waitFor(() => expect(server.called("GET", /\/requests\/7$/).length).toBeGreaterThan(reads));
    expect(server.called("POST", /selection$/).map((call) => call.body)).toEqual([{ result_id: "60", expected_revision: "/", replace_library_file: false }]);
  });

  test("a pick and its replacement question made before the copies changed are withdrawn, so the administrator decides again", async () => {
    let selected = "50";
    const found = () =>
      detail({
        status: "completed",
        requested_by: { name: "Rae", self: false },
        actions: { ...adminActions, replaces_library_file: true },
        copies: {
          selectable: false,
          revision: `${selected}/3`,
          looking_for: "English",
          search_blocked: null,
          candidates: ["50", "51", "52"].map((id) => copy(id, { state: id === selected ? "selected" : "rejected" }, { choice: id === selected ? "selected" : "select_instead" })),
        },
      });
    const server = railsServer(found(), true)
      .on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }))
      .on("POST", /\/requests\/7\/selection$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "downloading" } } }));
    const { services } = renderApp({ server, url: "/sub/preview/requests/7#copies" });
    const user = userEvent.setup();
    await user.click(await screen.findByLabelText("Copy 51.epub"));
    await user.click(screen.getByRole("button", { name: "Download this copy instead" }));
    expect(screen.getByRole("button", { name: "Yes, replace the file" })).toBeTruthy();
    selected = "52";
    await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
    await waitFor(() => expect([...document.querySelectorAll("#copies tbody th")].map((cell) => cell.textContent)).toEqual(["Copy 50.epub", "Copy 51.epub", "Copy 52.epub · chosen"]));
    expect(screen.queryByRole("button", { name: "Yes, replace the file" })).toBeNull();
    expect(document.activeElement?.textContent).toBe("Download this copy");
    expect((screen.getByLabelText("Copy 51.epub") as HTMLInputElement).checked).toBe(false);
    expect(server.called("POST", /selection$/)).toHaveLength(0);
    await user.click(screen.getByLabelText("Copy 51.epub"));
    await user.click(screen.getByRole("button", { name: "Download this copy instead" }));
    await user.click(screen.getByRole("button", { name: "Yes, replace the file" }));
    await waitFor(() => expect(server.called("POST", /selection$/).map((call) => call.body)).toEqual([{ result_id: "51", expected_revision: "52/3", replace_library_file: true }]));
  });

  test("copies from an older server or with an unreadable fact still show the request and fall back to the plain choice", async () => {
    const legacy = { selectable: true, candidates: [{ id: "70", title: "Old.epub", format: "EPUB", size_bytes: 10, language: "English", source: "Prowlarr", state: "pending", skipped: false, downloadable: true }] };
    const odd = { ...copy("71", { title: "Odd.epub" }), details: { ...copyDetails(), score: "ninety", seeders: -4, structure: 1 } };
    const body = { account: ACCOUNT, request: { ...detail({ requested_by: { name: "Rae", self: false }, actions: adminActions }), copies: { ...legacy, candidates: [...legacy.candidates, odd] } } };
    const server = railsServer(detail(), true)
      .on("GET", /\/api\/v1\/requests\/7$/, () => ({ body }))
      .on("POST", /\/requests\/7\/selection$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "downloading" } } }));
    renderApp({ server, url: "/sub/preview/requests/7" });
    const section = (await screen.findByText("Copies (2)")).closest("details");
    if (!section) throw new Error("Copies section missing");
    expect(within(section).getByText("2 copies found, best first")).toBeTruthy();
    expect([...within(section).getAllByRole("row")[2]!.querySelectorAll("td[data-label]")].map((cell) => cell.textContent)).toEqual(["EPUB", "1000 B", "English", "Prowlarr", "Unknown", "Not listed"]);
    const user = userEvent.setup();
    expect((within(section).getByLabelText("Old.epub") as HTMLInputElement).checked).toBe(false);
    await user.click(within(section).getByLabelText("Old.epub"));
    await user.click(within(section).getByRole("button", { name: "Download this copy" }));
    await waitFor(() => expect(server.called("POST", /selection$/).map((call) => call.body)).toEqual([{ result_id: "70" }]));
  });

  test("an older server's read-only copies and a copy whose choice can't be read are never offered for download", async () => {
    const legacy = { selectable: false, candidates: [{ id: "90", title: "Running.epub", format: "EPUB", size_bytes: 10, language: "English", source: "Prowlarr", state: "selected", skipped: false, downloadable: true }] };
    const server = railsServer(detail(), true).on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: { ...detail({ status: "downloading", requested_by: { name: "Rae", self: false }, actions: adminActions }), copies: legacy } } }));
    renderApp({ server, url: "/sub/preview/requests/7#copies" });
    const section = (await screen.findByText("Copies (1)")).closest("details");
    if (!section) throw new Error("Copies section missing");
    expect((within(section).getByLabelText("Running.epub") as HTMLInputElement).disabled).toBe(true);
    expect(within(section).queryByRole("button", { name: /Download this copy/ })).toBeNull();
    expect(within(section).getByText("None of these copies can be downloaded now.")).toBeTruthy();
    cleanup();

    const unreadable = { ...copy("91", { title: "Chosen.epub", state: "selected" }), details: { ...copyDetails(), choice: "picked" } };
    const skipped = { ...copy("93", { title: "Failed.epub", state: "rejected", skipped: true }), details: { ...copyDetails(), choice: "picked", score: 96, blocklist_reason: "Wrong book" } };
    const copies = { selectable: false, revision: "r1", looking_for: "English", search_blocked: null, candidates: [unreadable, copy("92", { state: "rejected" }, { choice: "select_instead", score: 70 }), skipped] };
    const next = railsServer(detail(), true).on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: { ...detail({ status: "downloading", requested_by: { name: "Rae", self: false }, actions: adminActions }), copies } } }));
    renderApp({ server: next, url: "/sub/preview/requests/7#copies" });
    const table = (await screen.findByText("Copies (3)")).closest("details");
    if (!table) throw new Error("Copies section missing");
    expect((within(table).getByLabelText("Chosen.epub") as HTMLInputElement).disabled).toBe(true);
    expect(within(table).getAllByRole("row").map((row) => row.children.length)).toEqual([8, 8, 8, 8]);
    expect([...within(table).getAllByRole("row")[1]!.querySelectorAll("td[data-label]")].map((cell) => cell.textContent)).toEqual(["EPUB", "1000 B", "English", "Prowlarr", "Unknown", "Not listed"]);
    expect(within(table).getAllByRole("row").slice(1).map((row) => row.querySelector("th")?.textContent)).toEqual(["Chosen.epub · chosen", "Copy 92.epub", "Failed.epub · skipped beforeSkipped because: Wrong book"]);
    expect([...within(table).getAllByRole("row")[3]!.querySelectorAll("td[data-label]")].map((cell) => cell.textContent)).toEqual(["EPUB", "1000 B", "English", "Prowlarr", "96%", "Not listed"]);
    await userEvent.setup().click(within(table).getByLabelText("Failed.epub"));
    expect(within(table).getByRole("button", { name: "Try this copy again anyway" })).toBeTruthy();
  });

  test("a copy rewritten by a new search is no longer the one picked, so the old pick can't carry over to it", async () => {
    let rewritten = false;
    const found = () => detail({ requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: false, revision: rewritten ? "r2" : "r1", looking_for: "English", search_blocked: null, candidates: [copy("95", { title: rewritten ? "Different.epub" : "Original.epub", state: "rejected", skipped: true }, { choice: "retry_anyway" })] } });
    const server = railsServer(found(), true).on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }));
    const { services } = renderApp({ server, url: "/sub/preview/requests/7#copies" });
    const user = userEvent.setup();
    await user.click(await screen.findByLabelText("Original.epub"));
    expect((screen.getByLabelText("Original.epub") as HTMLInputElement).checked).toBe(true);
    rewritten = true;
    await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
    const renamed = (await screen.findByLabelText("Different.epub")) as HTMLInputElement;
    expect(renamed.checked).toBe(false);
    await user.click(screen.getByRole("button", { name: "Download this copy" }));
    expect(screen.getByRole("alert").textContent).toContain("Choose one copy that can be downloaded first.");
    expect(server.called("POST", /selection$/)).toHaveLength(0);
  });

  test("a pick made before a change that leaves every row looking the same is withdrawn too", async () => {
    let revision = "r1";
    const found = () => detail({ requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: false, revision, looking_for: "English", search_blocked: null, candidates: [copy("96", { title: "Provider.epub", source: "Shelf Provider" })] } });
    const server = railsServer(found(), true).on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }));
    const { services } = renderApp({ server, url: "/sub/preview/requests/7#copies" });
    const user = userEvent.setup();
    await user.click(await screen.findByLabelText("Provider.epub"));
    revision = "r2";
    await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
    await waitFor(() => expect((screen.getByLabelText("Provider.epub") as HTMLInputElement).checked).toBe(false));
    await user.click(screen.getByRole("button", { name: "Download this copy" }));
    expect(server.called("POST", /selection$/)).toHaveLength(0);
  });

  test("when a refresh removes the focused copy while others remain, focus stays in the copies", async () => {
    let refreshed = false;
    const found = () => detail({ requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: false, revision: refreshed ? "r2" : "r1", looking_for: "English", search_blocked: null, candidates: refreshed ? [copy("98")] : [copy("97"), copy("98")] } });
    const server = railsServer(found(), true).on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }));
    const { services } = renderApp({ server, url: "/sub/preview/requests/7#copies" });
    (await screen.findByLabelText("Copy 97.epub")).focus();
    refreshed = true;
    await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
    await waitFor(() => expect([...document.querySelectorAll("#copies tbody th")].map((cell) => cell.textContent)).toEqual(["Copy 98.epub"]));
    await waitFor(() => expect(document.activeElement?.textContent).toBe("Download this copy"));
  });

  test("no copy is chosen for the administrator, and an explicit pick survives copies reordered under the same revision", async () => {
    let reversed = false;
    const found = () => detail({ requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: true, revision: "r1", looking_for: "English", search_blocked: null, candidates: reversed ? [copy("62"), copy("61")] : [copy("61"), copy("62")] } });
    const server = railsServer(found(), true)
      .on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }))
      .on("POST", /\/requests\/7\/selection$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "downloading" } } }));
    const { services } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    expect(((await screen.findByLabelText("Copy 61.epub")) as HTMLInputElement).checked).toBe(false);
    await user.click(screen.getByLabelText("Copy 61.epub"));
    reversed = true;
    await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
    await waitFor(() => expect([...document.querySelectorAll("#copies tbody th")].map((cell) => cell.textContent)).toEqual(["Copy 62.epub", "Copy 61.epub"]));
    expect((screen.getByLabelText("Copy 61.epub") as HTMLInputElement).checked).toBe(true);
    await user.click(screen.getByRole("button", { name: "Download this copy" }));
    await waitFor(() => expect(server.called("POST", /selection$/).map((call) => call.body)).toEqual([{ result_id: "61", expected_revision: "r1", replace_library_file: false }]));
  });

  test("an explicit pick lost to a search that briefly emptied the copies is not replaced by a new suggestion", async () => {
    let phase = 0;
    const lists = [[copy("63"), copy("64")], [], [copy("65")]];
    const found = () => detail({ requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: phase !== 1, revision: `r${phase}`, looking_for: "English", search_blocked: null, candidates: lists[phase]! } });
    const server = railsServer(found(), true).on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }));
    const { services } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByLabelText("Copy 64.epub"));
    for (const next of [1, 2]) {
      phase = next;
      await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
      await waitFor(() => expect(document.querySelectorAll("#copies tbody th").length).toBe(lists[next]!.length));
    }
    expect((screen.getByLabelText("Copy 65.epub") as HTMLInputElement).checked).toBe(false);
    await user.click(screen.getByRole("button", { name: "Download this copy" }));
    expect(server.called("POST", /selection$/)).toHaveLength(0);
  });

  test("a background refresh that empties the copies leaves focus alone after the administrator clicked elsewhere", async () => {
    let cleared = false;
    const found = () => detail({ requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: !cleared, revision: cleared ? "r2" : "r1", looking_for: "English", search_blocked: null, candidates: cleared ? [] : [copy("66")] } });
    const server = railsServer(found(), true).on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }));
    const { services } = renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByLabelText("Copy 66.epub"));
    await user.click(document.querySelector("#copies .copies-heading .request-meta") as HTMLElement);
    expect(document.activeElement?.tagName).toBe("BODY");
    cleared = true;
    await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
    await waitFor(() => expect(document.querySelector("#copies .copies .request-note[tabindex]")).not.toBeNull());
    expect(document.activeElement?.tagName).toBe("BODY");
  });

  test("a pick that lapsed when its copy changed does not come back when the copy changes back", async () => {
    let high = true;
    const found = () => detail({ requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: false, revision: "r1", looking_for: "English", search_blocked: null, candidates: [copy("67", {}, { score: 90, high_confidence: high })] } });
    const server = railsServer(found(), true).on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }));
    const { services } = renderApp({ server, url: "/sub/preview/requests/7#copies" });
    await userEvent.setup().click(await screen.findByLabelText("Copy 67.epub"));
    for (const next of [false, true]) {
      high = next;
      await act(async () => void services.queryClient.invalidateQueries({ queryKey: services.keys.request("7") }));
      await waitFor(() => expect(document.querySelector("#copies td[data-label=Score]")?.textContent).toBe(next ? "90% (high)" : "90%"));
    }
    expect((screen.getByLabelText("Copy 67.epub") as HTMLInputElement).checked).toBe(false);
  });

  test("when a new search clears the copies under an open choice, focus and the refusal stay on screen", async () => {
    let cleared = false;
    const found = () => detail({ requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: !cleared, revision: cleared ? "r2" : "r1", looking_for: "English", search_blocked: null, candidates: cleared ? [] : [copy("85")] } });
    const server = railsServer(found(), true)
      .on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }))
      .on("POST", /\/requests\/7\/selection$/, () => {
        cleared = true;
        return { status: 404, body: { error: "not_found" } };
      });
    renderApp({ server, url: "/sub/preview/requests/7" });
    await userEvent.setup().click(await screen.findByLabelText("Copy 85.epub"));
    const button = screen.getByRole("button", { name: "Download this copy" });
    button.focus();
    await userEvent.setup().keyboard("{Enter}");
    const note = await screen.findByText("No copies found yet. The search may still be running.");
    await waitFor(() => expect(document.activeElement === note).toBe(true));
    expect(screen.getByRole("alert").textContent).toBe("The choice could not be sent. Nothing was changed.");
  });

  test("when the last copy that could be chosen becomes the chosen one, focus stays in the copies", async () => {
    let chosen = false;
    const found = () => detail({ requested_by: { name: "Rae", self: false }, actions: adminActions, copies: { selectable: !chosen, revision: chosen ? "80/1" : "/", looking_for: "English", search_blocked: null, candidates: [copy("80", { state: chosen ? "selected" : "pending" }, { choice: chosen ? "selected" : "select" })] } });
    const server = railsServer(found(), true)
      .on("GET", /\/api\/v1\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: found() } }))
      .on("POST", /\/requests\/7\/selection$/, () => {
        chosen = true;
        return { body: { account: ACCOUNT, request: { id: "7", status: "downloading" } } };
      });
    renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByLabelText("Copy 80.epub"));
    const button = screen.getByRole("button", { name: "Download this copy" });
    button.focus();
    await user.keyboard("{Enter}");
    await waitFor(() => expect(screen.queryByRole("button", { name: "Download this copy" })).toBeNull());
    await waitFor(() => expect(document.activeElement?.getAttribute("role")).toBe("region"));
    expect(screen.getByText("None of these copies can be downloaded now.")).toBeTruthy();
  });

  test("Search again sits in the Copies section, which explains an empty search", async () => {
    const found = detail({ status: "not_found", actions: adminActions, copies: { selectable: false, revision: "/", looking_for: "Portuguese", search_blocked: null, candidates: [] } });
    const server = copiesServer(found).on("POST", /\/requests\/7\/search$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "pending" } } }));
    renderApp({ server, url: "/sub/preview/requests/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByText("Copies (0)"));
    const section = screen.getByText("Copies (0)").closest("details");
    if (!section) throw new Error("Copies section missing");
    expect(within(section).getByText("No copies found yet. The search may still be running.")).toBeTruthy();
    expect(within(section).getByText("Looking for Portuguese · 0 copies found, best first")).toBeTruthy();
    expect(screen.getAllByRole("button", { name: "Search again" })).toHaveLength(1);
    await user.click(within(section).getByRole("button", { name: "Search again" }));
    await waitFor(() => expect(server.called("POST", /\/requests\/7\/search$/)).toHaveLength(1));
  });
});

describe("your account in the Rails preview", () => {
  beforeEach(() => {
    const meta = document.createElement("meta");
    meta.name = "csrf-token";
    meta.content = "page-token";
    document.head.append(meta);
  });
  afterEach(() => document.querySelectorAll('meta[name="csrf-token"]').forEach((meta) => meta.remove()));

  test("Profile shows only personal things, with a rail to the other sections and a sign-out form", async () => {
    renderApp({ server: accountServer(), url: "/sub/preview/account" });
    expect(await screen.findByText("Member")).toBeTruthy();
    expect(screen.getByText("Only you see and change these.")).toBeTruthy();
    const rail = screen.getByRole("navigation", { name: "Account" });
    expect(within(rail).getAllByRole("link").map((link) => [link.textContent, link.getAttribute("href"), link.getAttribute("aria-current")])).toEqual([
      ["Profile", "/sub/preview/account", "page"],
      ["Sign-in and security", "/sub/preview/account/security", null],
      ["Devices", "/sub/preview/account/devices", null],
      ["Connections", "/sub/preview/account/connections", null],
      ["About", "/sub/preview/account/about", null],
    ]);
    const form = screen.getByRole("button", { name: "Sign out" }).closest("form")!;
    expect(form.getAttribute("action")).toBe("/sub/session");
    expect((form.querySelector("input[name=_method]") as HTMLInputElement).value).toBe("delete");
    expect((form.querySelector("input[name=authenticity_token]") as HTMLInputElement).value).toBe("page-token");
    expect(screen.queryByText(/Server settings|Release, updates and backups/)).toBeNull();
  });

  test("security lists connected apps apart from API tokens, and creating a token shows its secret once", async () => {
    const created = { account: ACCOUNT, token: { ...settings.api_tokens[1]!, id: "9", name: "Bot", state: "active" as const }, secret: "shf_once" };
    const server = accountServer().on("POST", /\/account\/api_tokens$/, () => ({ status: 201, body: created }));
    renderApp({ server, url: "/sub/preview/account/security" });
    const apps = await screen.findByRole("region", { name: "Connected apps" });
    expect(within(apps).getByText("Pixel 9", { selector: ".token-name" })).toBeTruthy();
    expect(within(apps).getByRole("button", { name: "Disconnect Pixel 9" })).toBeTruthy();
    const user = userEvent.setup();
    await user.click(screen.getByText("Advanced: API tokens for scripts and tools"));
    expect(screen.queryByRole("button", { name: /Revoke Backup script/ })).toBeNull();
    await user.type(screen.getByLabelText("Token name"), "Bot");
    await user.click(screen.getByRole("checkbox", { name: "Read requests" }));
    await user.click(screen.getByRole("button", { name: "Create token" }));
    expect(await screen.findByText("shf_once")).toBeTruthy();
    expect(server.called("POST", /api_tokens$/)[0]?.body).toEqual({ name: "Bot", scopes: ["search:read"] });
    await user.click(screen.getByRole("button", { name: "Done" }));
    expect(screen.queryByText("shf_once")).toBeNull();
  });

  test("two-factor sign-in is turned on with a code and its backup codes are shown", async () => {
    const server = accountServer()
      .on("POST", /two_factor\/setup$/, () => ({ body: { account: ACCOUNT, setup: { secret: "ABCDEF", uri: "otpauth://totp/Shelfarr:rae?secret=ABCDEF", qr_svg: "<svg xmlns='http://www.w3.org/2000/svg'/>" } } }))
      .on("POST", /two_factor\/enable$/, (recorded) => ((recorded.body as { otp_code: string }).otp_code === "123456" ? { body: { account: ACCOUNT, backup_codes: ["AAAA1111", "BBBB2222"] } } : { status: 422, body: { error: "invalid_code" } }));
    renderApp({ server, url: "/sub/preview/account/security" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Turn on two-factor sign-in" }));
    const code = await screen.findByLabelText("Code from the app");
    expect(code.getAttribute("autocomplete")).toBe("one-time-code");
    expect(screen.getByRole("img", { name: "Code to scan with your authenticator app" }).getAttribute("src")).toStartWith("data:image/svg+xml");
    await user.type(code, "000000");
    await user.click(screen.getByRole("button", { name: "Turn on" }));
    expect(await screen.findByText("That code was not accepted. Check the time on your phone and try the newest code.")).toBeTruthy();
    await user.clear(code);
    await user.type(code, "123456");
    await user.click(screen.getByRole("button", { name: "Turn on" }));
    expect(await screen.findByText("AAAA1111")).toBeTruthy();
    expect(screen.getByText("BBBB2222")).toBeTruthy();
  });

  test("single sign-on linking hands off to the classic account page, which owns the provider redirect", async () => {
    renderApp({ server: accountServer(), url: "/sub/preview/account/security" });
    expect((await screen.findByRole("link", { name: "Link Pocket ID on the classic account page" })).getAttribute("href")).toBe("/sub/profile");
  });

  test("About links administrators to the server", async () => {
    renderApp({ server: accountServer(profile({ admin: true, links: { ...settings.links, admin: "/sub/admin" } })), url: "/sub/preview/account/about" });
    expect((await screen.findByRole("link", { name: "Release, updates and backups" })).getAttribute("href")).toBe("/sub/preview/server");
    expect(screen.getByText(/Shelfarr 1.0 beta/)).toBeTruthy();
  });
});
