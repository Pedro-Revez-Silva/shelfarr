import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { AccountSettings, Profile, RequestDetail, RequestList, RequestSummary } from "../src/contract";
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

const memberActions = { cancel: true, remove: null, retry: false, search_again: false, manual_download: false, replaces_library_file: false, upload_url: null, download_url: null } as const;

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
  oidc: { configured: true, provider: "Pocket ID", linked: false, linkable: true, password_required: true },
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
    expect(bell.getAttribute("href")).toBe("/sub/notifications");
    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(within(nav).getAllByRole("link").map((link) => link.textContent)).toEqual(["Library", "Find", "Account", "Server (opens the classic Shelfarr app)"]);
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
    await user.click(screen.getByRole("button", { name: "Yes, cancel it" }));
    await waitFor(() => expect(server.called("POST", /\/requests\/7\/cancel$/)).toHaveLength(1));
    expect(server.called("POST", /cancel$/)[0]?.headers["x-csrf-token"]).toBe("token-123");
  });

  test("a waiting purchase shows each store offer with its seller and the upload after buying", async () => {
    const offer = { id: "4", title: "The Dispossessed", author: null, provider: "Kobo", drm: "DRM-free", price: "EUR 9.99", formats: ["EPUB"], language: "English", quoted_at: null, url: "https://store.example/en-us/book/abc" };
    renderApp({ server: railsServer(detail({ status: "awaiting_purchase", store_offers: [offer], actions: { ...memberActions, upload_url: "/sub/uploads/new?request_id=7" } })), url: "/sub/preview/requests/7" });
    const offers = await screen.findByRole("region", { name: "Buy it DRM-free" });
    expect(within(offers).getByRole("link", { name: "View and buy at Kobo (opens in a new tab)" }).getAttribute("href")).toBe(offer.url);
    expect(within(offers).getByRole("link", { name: "Upload after buying" }).getAttribute("href")).toBe("/sub/uploads/new?request_id=7");
    expect(screen.getByText("Waiting for a purchase.")).toBeTruthy();
  });

  test("an administrator chooses a copy, adds a magnet link and sees the model's refusal", async () => {
    const copies = { selectable: true, candidates: [{ id: "31", title: "Dispossessed.epub", format: "EPUB", size_bytes: 1000, language: "English", source: "Project Gutenberg", state: "pending" as const, skipped: false, downloadable: true }] };
    const adminActions = { ...memberActions, cancel: false, remove: "admin_remove" as const, retry: true, search_again: true, manual_download: true };
    const server = railsServer(detail({ requested_by: { name: "Rae Reader", self: false }, attention_reason: "No copies after 3 searches", actions: adminActions, copies, events: [{ title: "Dispatch Failed", message: "Client down", level: "error", at: "2026-11-20T09:00:00.000Z" }] }), true)
      .on("POST", /\/requests\/7\/selection$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "downloading" } } }))
      .on("POST", /\/requests\/7\/manual$/, () => ({ status: 422, body: { error: "manual_rejected", message: "Enter a valid magnet link" } }));
    renderApp({ server, url: "/sub/preview/requests/7" });
    const tools = await screen.findByRole("region", { name: "Administrator tools" });
    const user = userEvent.setup();
    await user.click(within(tools).getByRole("button", { name: "Download this copy" }));
    await waitFor(() => expect(server.called("POST", /selection$/)[0]?.body).toEqual({ result_id: "31" }));
    await user.click(within(tools).getByText("Add a link or file"));
    await user.type(within(tools).getByLabelText("Magnet link", { exact: true }), "http://nope");
    await user.click(within(tools).getByRole("button", { name: "Add magnet link" }));
    expect(await within(tools).findByText("Enter a valid magnet link")).toBeTruthy();
    expect(server.called("POST", /manual$/)[0]?.body).toEqual({ kind: "magnet", magnet_url: "http://nope", replace_library_file: false });
    expect(within(tools).getByText("No copies after 3 searches")).toBeTruthy();
    expect(within(tools).getByText("Client down")).toBeTruthy();
  });

  test("a member can upload without store offers and delete a cancelled request", async () => {
    const server = railsServer(detail({ status: "failed", actions: { ...memberActions, cancel: false, remove: "delete_request", upload_url: "/sub/uploads/new?request_id=7" } })).on("POST", /\/requests\/7\/remove$/, () => ({ body: { account: ACCOUNT, request: { id: "7", status: "removed" } } }));
    renderApp({ server, url: "/sub/preview/requests/7" });
    expect((await screen.findByRole("link", { name: "Upload a file for this request" })).getAttribute("href")).toBe("/sub/uploads/new?request_id=7");
    expect(screen.queryByRole("button", { name: "Cancel request" })).toBeNull();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Delete request" }));
    await user.click(screen.getByRole("button", { name: "Yes, remove it" }));
    await waitFor(() => expect(server.called("POST", /remove$/)).toHaveLength(1));
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
  });

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

  test("single sign-on starts through an account-bound request, then posts to the provider with the page token", async () => {
    const submitted: string[] = [];
    const original = HTMLFormElement.prototype.submit;
    HTMLFormElement.prototype.submit = function (this: HTMLFormElement) {
      submitted.push(`${this.getAttribute("action")} ${(this.querySelector("input[name=authenticity_token]") as HTMLInputElement | null)?.value}`);
    };
    try {
      const server = accountServer().on("POST", /\/account\/oidc\/link$/, () => ({ body: { account: ACCOUNT, start: { url: "/sub/auth/oidc" } } }));
      renderApp({ server, url: "/sub/preview/account/security" });
      await userEvent.setup().click(await screen.findByRole("button", { name: "Link Pocket ID" }));
      await waitFor(() => expect(submitted).toEqual(["/sub/auth/oidc page-token"]));
      expect(server.called("POST", /oidc\/link$/)[0]?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    } finally {
      HTMLFormElement.prototype.submit = original;
    }
  });

  test("About links administrators to the server", async () => {
    renderApp({ server: accountServer(profile({ admin: true, links: { ...settings.links, admin: "/sub/admin" } })), url: "/sub/preview/account/about" });
    expect((await screen.findByRole("link", { name: "Release, updates and backups" })).getAttribute("href")).toBe("/sub/admin");
    expect(screen.getByText(/Shelfarr 1.0 beta/)).toBeTruthy();
  });
});
