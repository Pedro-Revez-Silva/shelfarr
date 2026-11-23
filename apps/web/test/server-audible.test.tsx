import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { audibleSchema, catalogueSchema, type Audible, type Catalogue, type CatalogueItem } from "../src/server/audible/contract";
import type { ServerSettings } from "../src/server/contract";
import { ACCOUNT, deferred, FakeServer, renderApp, session, standardServer } from "./helpers";

afterEach(cleanup);

const ADMIN = { admin: { url: "/sub/admin" }, capabilities: { administrator: true, can_upload: true, single_sign_on: false, hardcover_personal_access: false } };
const LOGIN = "https://www.amazon.com/ap/signin?openid.return_to=callback";
const TOKEN = "a".repeat(64);

function state(overrides: Partial<Audible> = {}): Audible {
  return {
    account: ACCOUNT,
    connection: {
      saved: true,
      url: "http://shelfarr-libation:8080",
      default_url: "http://shelfarr-libation:8080",
      bridge_token_saved: true,
      token_file_managed: false,
      enabled: true,
      allow_private_network: true,
      timeout_seconds: 30,
      companion_version: "1.4.0",
      provider_version: "14.2.1",
      status: "ready",
      problem: null,
      locked: false,
    },
    sign_in: { state: "connected", accounts: [{ label: "Reader", marketplace: "United States", authenticated: true }], accounts_paused: false, locked: false, reregister_default: true },
    sync: { state: "succeeded", recoverable: false, job_recorded: false, refreshing: true, started_at: null, last_synced_at: "2026-11-23T09:00:00Z", error: null, action: "Sync library", available: true },
    library: { total: 3, purchased: 2, subscription: 1 },
    active_backups: { total: 0, counts: [] },
    existing_backup: { available: true, prompt: false, total: 0, remaining: 0, processed: 0, counts: [] },
    automation: {
      scheduled_sync_enabled: false,
      interval_minutes: 1440,
      intervals: [
        { minutes: 60, label: "Every hour" },
        { minutes: 1440, label: "Every 24 hours" },
      ],
      next_sync_at: null,
      automatic_backup_enabled: false,
      owner: null,
      owner_ready: false,
      baseline_ready: false,
      first_sync_done: true,
    },
    marketplaces: [
      { value: "us", label: "United States" },
      { value: "uk", label: "United Kingdom" },
    ],
    working: false,
    revision: "0000000000000000",
    ...overrides,
  };
}

function item(overrides: Partial<CatalogueItem> = {}): CatalogueItem {
  return { id: "5", title: "Dune", author: "Frank Herbert", ownership: "purchased", book_id: null, origin: null, state: "not_backed_up", detail: null, action: { label: "Back up", separate_edition: false, available: true }, ...overrides };
}

function catalogue(overrides: Partial<Catalogue> = {}): Catalogue {
  return {
    account: ACCOUNT,
    query: "",
    page: 1,
    pages: 2,
    total: 3,
    synced: true,
    items: [
      item(),
      item({ id: "6", title: "Dune Local", state: "possible_match", action: { label: "Back up separately", separate_edition: true, available: true } }),
      item({ id: "7", title: "Dune Shelved", state: "in_shelfarr", book_id: "41", action: null }),
      item({ id: "8", title: "Dune Messiah", ownership: "subscription", state: "not_eligible", action: null }),
      item({ id: "9", title: "Dune Failed", state: "failed", origin: "existing", detail: "Libation said no", action: { label: "Retry backup", separate_edition: false, available: true } }),
    ],
    ...overrides,
  };
}

function settingsFixture(): ServerSettings {
  const empty = (id: ServerSettings["categories"][number]["id"], title: string) => ({ id, title, summary: `${title}.`, groups: [] });
  return {
    account: ACCOUNT,
    categories: [empty("policy", "Request policy"), empty("sources", "Catalogues and sources"), empty("downloads", "Downloads"), empty("library", "Library and files"), empty("notifications", "Notifications"), empty("people", "People and access"), empty("system", "System")],
    notes: { path_variables: "", hardcover_app: { create_url: "https://hardcover.app/x", scopes: "read", redirect_uri: "https://shelf.test/cb", redirect_uri_acceptable: true } },
    roles: [],
  };
}

let current: Audible = state();

function answer(next: Audible, message: string, tone: "success" | "error" = "success") {
  current = next;
  return { body: { ...next, outcome: { tone, message } } };
}

function adminServer(initial: Audible = state(), list: (path: string) => Catalogue = () => catalogue()): FakeServer {
  current = initial;
  return standardServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(ADMIN) }))
    .on("GET", /\/api\/v1\/admin\/settings$/, () => ({ body: settingsFixture() }))
    .on("GET", /\/api\/v1\/admin\/audible$/, () => ({ body: current }))
    .on("GET", /\/api\/v1\/admin\/audible\/revision$/, () => ({ body: { account: ACCOUNT, revision: current.revision } }))
    .on("GET", /\/api\/v1\/admin\/audible\/catalogue/, (request) => ({ body: list(request.path) }));
}

function section(id: string): HTMLElement {
  return document.getElementById(id)!;
}

async function openLibrary(server: FakeServer, suffix = "") {
  const rendered = renderApp({ server, url: `/sub/preview/server/library${suffix}` });
  await screen.findByRole("heading", { name: "Libation companion", level: 4 });
  return rendered;
}

describe("Audible backup contract", () => {
  test("the fixtures match the contract, and a sign-in link that is not HTTPS is refused", () => {
    expect(audibleSchema.safeParse(state()).success).toBe(true);
    expect(catalogueSchema.safeParse(catalogue()).success).toBe(true);
    const pending = { ...state().sign_in, state: "pending" as const, login_url: LOGIN, sign_in_token: TOKEN, expires_at: "2026-11-23T10:00:00Z" };
    expect(audibleSchema.safeParse(state({ sign_in: pending })).success).toBe(true);
    expect(audibleSchema.safeParse(state({ sign_in: { ...pending, login_url: "javascript:alert(1)" } })).success).toBe(false);
    expect(audibleSchema.safeParse(state({ sign_in: { ...pending, login_url: "http://www.amazon.com/ap/signin" } })).success).toBe(false);
    expect(audibleSchema.safeParse(state({ sign_in: { ...pending, sign_in_token: "short" } })).success).toBe(false);
  });
});

describe("Server ▸ Library and files ▸ Audible backup in the Rails preview", () => {
  test("a member sees the administrators-only page and nothing about Audible is asked for", async () => {
    const server = standardServer();
    renderApp({ server, url: "/sub/preview/server/library" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(server.requests.filter((request) => request.path.includes("/admin/audible"))).toEqual([]);
  });

  test("the card sits in the card index before Uploads and shows status, the token only as Saved and the shared-library warning", async () => {
    await openLibrary(adminServer());
    const index = screen.getByRole("navigation", { name: "Library and files cards" });
    expect(within(index).getAllByRole("link").map((link) => link.getAttribute("href"))).toEqual(["#audible", "#uploads"]);
    const card = section("audible");
    expect(within(card).getByRole("heading", { name: "Audible backup", level: 3 })).toBeTruthy();
    expect(card.textContent).toContain("Imported backups join this server's shared library");
    expect(card.textContent).toContain("Companion 1.4.0 · Libation 14.2.1");
    expect(card.textContent).toContain("3 titles 2 purchased · 1 subscription");
    const connection = section("audible-connection");
    expect(within(connection).getByText("Saved")).toBeTruthy();
    expect(within(connection).queryByLabelText("Bridge token")).toBeNull();
    expect(within(connection).getByRole("button", { name: "Replace" })).toBeTruthy();
    expect((within(connection).getByLabelText("Companion address") as HTMLInputElement).value).toBe("http://shelfarr-libation:8080");
  });

  test("Save sends the whole companion form with a blank token, then Test answers inside the card", async () => {
    const user = userEvent.setup();
    const server = adminServer()
      .on("PUT", /\/admin\/audible\/companion$/, () => answer(state({ connection: { ...state().connection, timeout_seconds: 45 }, revision: "2222222222222222" }), "Audible backup connection saved."))
      .on("POST", /\/admin\/audible\/test$/, () => answer(current, "Connected to the Libation companion (1.4.0 / Libation 14.2.1); status: ok."));
    await openLibrary(server);
    const connection = section("audible-connection");
    const timeout = within(connection).getByLabelText("Request timeout");
    await user.clear(timeout);
    await user.type(timeout, "45");
    expect(within(connection).getByText("Unsaved changes")).toBeTruthy();
    await user.click(within(connection).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(server.called("PUT", /companion$/)).toHaveLength(1));
    expect(server.called("PUT", /companion$/)[0]!.body).toEqual({ companion: { url: "http://shelfarr-libation:8080", bridge_token: "", enabled: true, allow_private_network: true, timeout_seconds: "45" } });
    expect(await within(connection).findByText("Audible backup connection saved.")).toBeTruthy();
    await waitFor(() => expect(within(connection).queryByText("Unsaved changes")).toBeNull());
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(server.called("GET", /admin\/audible$/)).toHaveLength(1);

    await user.click(within(connection).getByRole("button", { name: "Test" }));
    expect(await within(connection).findByText(/Connected to the Libation companion \(1\.4\.0 \/ Libation 14\.2\.1\); status: ok\./)).toBeTruthy();
    expect(connection.textContent).not.toContain("Audible backup connection saved.");
  });

  test("a rejected save marks the field, says why and focuses it, and keeps the draft", async () => {
    const user = userEvent.setup();
    const server = adminServer().on("PUT", /\/admin\/audible\/companion$/, () => ({
      status: 422,
      body: { account: ACCOUNT, error: "invalid_record", errors: [{ field: "url", message: "Companion address must use HTTPS unless private network access is enabled" }] },
    }));
    await openLibrary(server);
    const connection = section("audible-connection");
    const address = within(connection).getByLabelText("Companion address") as HTMLInputElement;
    await user.clear(address);
    await user.type(address, "http://libation.example");
    await user.click(within(connection).getByRole("button", { name: "Save" }));
    expect(await within(connection).findByText("Companion address must use HTTPS unless private network access is enabled")).toBeTruthy();
    expect(address.getAttribute("aria-invalid")).toBe("true");
    await waitFor(() => expect(document.activeElement === address).toBe(true));
    expect(address.value).toBe("http://libation.example");
    expect(screen.getByText("Nothing was saved. Correct the highlighted fields and save again.")).toBeTruthy();
  });

  test("while Libation works the connection cannot be saved or tested, and a token file is shown as managed", async () => {
    await openLibrary(adminServer(state({ connection: { ...state().connection, locked: true, token_file_managed: true, status: "busy" } })));
    const connection = section("audible-connection");
    expect((within(connection).getByRole("button", { name: "Save" }) as HTMLButtonElement).disabled).toBe(true);
    expect((within(connection).getByRole("button", { name: "Test" }) as HTMLButtonElement).disabled).toBe(true);
    expect(connection.textContent).toContain("Wait for the current Libation work or Audible sign-in to finish");
    expect(connection.textContent).toContain("Set by SHELFARR_LIBATION_TOKEN_FILE on the server");
    expect(section("audible").textContent).toContain("Ready · Busy");
  });

  test("sign-in starts with the typed account and opens only the checked link in a new tab without a referrer, then completes with the bound token", async () => {
    const user = userEvent.setup();
    const pending = state({ sign_in: { ...state().sign_in, state: "pending", login_url: LOGIN, sign_in_token: TOKEN, expires_at: "2099-01-01T00:00:00Z" } });
    const server = adminServer(state({ sign_in: { ...state().sign_in, state: "needs_sign_in", accounts: [], reregister_default: false } }))
      .on("POST", /\/admin\/audible\/sign_in$/, () => answer(pending, "Open the Audible sign-in, then paste the address it ends on."))
      .on("POST", /\/admin\/audible\/sign_in\/complete$/, () => answer(state(), "Audible account connected through Libation."));
    await openLibrary(server);
    const account = section("audible-account");
    await user.type(within(account).getByLabelText("Audible account email"), "reader@example.com");
    await user.selectOptions(within(account).getByLabelText("Marketplace"), "uk");
    await user.click(within(account).getByRole("button", { name: "Start sign-in" }));
    await waitFor(() => expect(server.called("POST", /sign_in$/)).toHaveLength(1));
    expect(server.called("POST", /sign_in$/)[0]!.body).toEqual({ account: "reader@example.com", locale: "uk", reregister: false });

    const link = await within(account).findByRole("link", { name: "Open Audible sign-in (opens in a new tab)" });
    expect([link.getAttribute("href"), link.getAttribute("target"), link.getAttribute("rel"), link.getAttribute("referrerpolicy")]).toEqual([LOGIN, "_blank", "noopener noreferrer", "no-referrer"]);
    await waitFor(() => expect(document.activeElement === link).toBe(true));
    await user.type(within(account).getByLabelText("Address the Audible tab ends on"), "https://www.amazon.com/ap/maplanding?code=x");
    await user.click(within(account).getByRole("button", { name: "Complete sign-in" }));
    await waitFor(() => expect(server.called("POST", /sign_in\/complete$/)).toHaveLength(1));
    expect(server.called("POST", /sign_in\/complete$/)[0]!.body).toEqual({ sign_in_token: TOKEN, response_url: "https://www.amazon.com/ap/maplanding?code=x" });
    expect(await screen.findByText("Audible account connected through Libation.")).toBeTruthy();
  });

  test("a pending sign-in whose link Shelfarr does not trust shows a warning and no link", async () => {
    await openLibrary(adminServer(state({ sign_in: { ...state().sign_in, state: "pending", login_url: null, sign_in_token: TOKEN, expires_at: null } })));
    const account = section("audible-account");
    expect(within(account).queryByRole("link")).toBeNull();
    expect(account.textContent).toContain("Libation returned a sign-in address Shelfarr does not trust");
  });

  test("sync shows its state and progress, and asks for a sync only when it is available", async () => {
    const user = userEvent.setup();
    const syncing = state({ sync: { ...state().sync, state: "syncing", started_at: "2026-11-23T09:30:00Z", action: "Syncing…", available: false }, working: true });
    const server = adminServer().on("POST", /\/admin\/audible\/sync$/, () => answer(syncing, "Audible library sync queued."));
    await openLibrary(server);
    const sync = section("audible-sync");
    expect(sync.querySelector(".audible-sync-status")!.textContent).toContain("Library ready · 3 active titles.");
    await user.click(within(sync).getByRole("button", { name: "Sync library" }));
    expect(await within(sync).findByText("Audible library sync queued.")).toBeTruthy();
    expect((within(sync).getByRole("button", { name: "Syncing…" }) as HTMLButtonElement).disabled).toBe(true);
    expect(within(sync).getByRole("progressbar", { name: "Library sync in progress" })).toBeTruthy();
    expect(sync.querySelector(".audible-sync-status")!.textContent).toContain("Refreshing your Audible library");
  });

  test("the first-sync prompt queues the existing library only after the box is ticked, and Not now puts it off", async () => {
    const user = userEvent.setup();
    const prompted = state({ existing_backup: { ...state().existing_backup, prompt: true } });
    const running = state({ existing_backup: { available: true, prompt: false, total: 4, remaining: 3, processed: 1, counts: [{ status: "pending", count: 3 }, { status: "completed", count: 1 }] }, working: true });
    const server = adminServer(prompted)
      .on("POST", /\/admin\/audible\/existing_backup$/, () => answer(running, "4 existing Audible purchases added to the background backup queue. Libation processes one title at a time."))
      .on("POST", /\/admin\/audible\/existing_backup\/dismiss$/, () => answer(state(), "Existing-library backup skipped for now. You can start it later under Automation."));
    await openLibrary(server);
    const sync = section("audible-sync");
    expect(within(sync).getByRole("heading", { name: "Back up your existing Audible library?" })).toBeTruthy();
    await user.click(within(sync).getByRole("button", { name: "Queue eligible backups" }));
    expect(server.called("POST", /existing_backup$/)).toHaveLength(0);
    await user.click(within(sync).getByLabelText(/I understand this queues every eligible personal backup/));
    await user.click(within(sync).getByRole("button", { name: "Queue eligible backups" }));
    await waitFor(() => expect(server.called("POST", /existing_backup$/)).toHaveLength(1));
    expect(server.called("POST", /existing_backup$/)[0]!.body).toEqual({ confirm: true });
    const automation = section("audible-automation");
    expect(await within(automation).findByRole("progressbar", { name: "Existing-library backup progress" })).toBeTruthy();
    expect(automation.textContent).toContain("Existing-library batch running · 1 of 4 processed");
    expect(automation.textContent).toContain("3 pending · 1 completed");

    current = prompted;
    cleanup();
    const again = adminServer(prompted).on("POST", /\/admin\/audible\/existing_backup\/dismiss$/, () => answer(state(), "Existing-library backup skipped for now. You can start it later under Automation."));
    await openLibrary(again);
    await user.click(within(section("audible-sync")).getByRole("button", { name: "Not now" }));
    expect(await screen.findByText("Existing-library backup skipped for now. You can start it later under Automation.")).toBeTruthy();
    expect(within(section("audible-sync")).queryByRole("heading", { name: "Back up your existing Audible library?" })).toBeNull();
  });

  test("automation saves scheduled sync, its interval and new-purchase backups as one form", async () => {
    const user = userEvent.setup();
    const saved = state({ automation: { ...state().automation, scheduled_sync_enabled: true, interval_minutes: 60, automatic_backup_enabled: true, owner: "Ada Reader", owner_ready: true, baseline_ready: true } });
    const server = adminServer().on("PUT", /\/admin\/audible\/automation$/, () => answer(saved, "Audible automation saved."));
    await openLibrary(server);
    const automation = section("audible-automation");
    await user.click(within(automation).getByLabelText("Sync the Audible library automatically"));
    await user.selectOptions(within(automation).getByLabelText("Sync interval"), "60");
    await user.click(within(automation).getByLabelText("Automatically back up new purchases"));
    await user.click(within(automation).getByRole("button", { name: "Save automation" }));
    await waitFor(() => expect(server.called("PUT", /automation$/)).toHaveLength(1));
    expect(server.called("PUT", /automation$/)[0]!.body).toEqual({ automation: { scheduled_sync_enabled: true, scheduled_sync_interval_minutes: 60, automatic_backup_enabled: true } });
    expect(await within(automation).findByText("Audible automation saved.")).toBeTruthy();
    expect(automation.textContent).toContain("New backups are credited to Ada Reader.");
  });

  test("the catalogue filters through the address, pages, links titles already here and backs up a title, separately when it may match", async () => {
    const user = userEvent.setup();
    const server = adminServer(state(), (path) => catalogue({ query: new URLSearchParams(path.split("?")[1] ?? "").get("q") ?? "", page: Number(new URLSearchParams(path.split("?")[1] ?? "").get("page") ?? "1") }))
      .on("POST", /\/admin\/audible\/items\/\d+\/backup$/, () => answer(current, "Backup of “Dune Local” queued through Libation."));
    const { router } = await openLibrary(server, "?audible_q=Dune#audible-catalogue");
    const list = section("audible-catalogue");
    await within(list).findByRole("table");
    expect(server.called("GET", /audible\/catalogue/).map((request) => request.path)).toContain("/sub/preview/api/v1/admin/audible/catalogue?q=Dune");
    await waitFor(() => expect(document.activeElement === list).toBe(true));
    const rows = within(list).getAllByRole("row").slice(1);
    expect(rows.map((row) => row.querySelector("th .audible-title")?.textContent)).toEqual(["Dune", "Dune Local", "Dune Shelved", "Dune Messiah", "Dune Failed"]);
    expect(within(rows[2]!).getByRole("link", { name: "Open in Library" }).getAttribute("href")).toBe("/sub/preview/library/41");
    expect(rows[3]!.textContent).toContain("Not eligible");
    expect(rows[4]!.textContent).toContain("Existing-library backup: backup failed");
    expect(rows[4]!.textContent).toContain("Libation said no");

    await user.click(within(rows[1]!).getByRole("button", { name: "Back up separately Dune Local" }));
    await waitFor(() => expect(server.called("POST", /items\/6\/backup$/)).toHaveLength(1));
    expect(server.called("POST", /items\/6\/backup$/)[0]!.body).toEqual({ separate_edition: true });
    expect(await within(list).findByText("Backup of “Dune Local” queued through Libation.")).toBeTruthy();

    await user.click(within(list).getByRole("button", { name: "Next page" }));
    await waitFor(() => expect(router.state.location.search).toEqual({ audible_q: "Dune", audible_page: "2" }));
    const filter = within(list).getByLabelText("Title or author");
    await user.clear(filter);
    await user.type(filter, "Herbert");
    await user.click(within(list).getByRole("button", { name: "Filter" }));
    await waitFor(() => expect(router.state.location.search).toEqual({ audible_q: "Herbert" }));
    expect(server.called("GET", /audible\/catalogue/).map((request) => request.path)).toContain("/sub/preview/api/v1/admin/audible/catalogue?q=Herbert");
    await user.click(within(list).getByRole("button", { name: "Clear filter" }));
    await waitFor(() => expect(router.state.location.search).toEqual({}));
    expect(document.activeElement === within(list).getByRole("button", { name: "Filter" })).toBe(true);
  });

  test("an answer for another account locks the page instead of showing it", async () => {
    const { services } = renderApp({ server: adminServer(state({ account: "99" })), url: "/sub/preview/server/library" });
    expect(await screen.findByRole("heading", { name: "The signed-in account changed" })).toBeTruthy();
    expect(services.guard.getState().status).toBe("account_changed");
  });

  test("a read that was already on its way cannot undo the state an action just returned", async () => {
    const user = userEvent.setup();
    const late = deferred<{ body: Audible }>();
    const syncing = state({ sync: { ...state().sync, state: "syncing", started_at: "2026-11-23T09:30:00Z", action: "Syncing…", available: false }, working: true });
    let reads = 0;
    let posts = 0;
    const server = adminServer()
      .on("GET", /\/api\/v1\/admin\/audible$/, () => {
        reads += 1;
        return reads === 1 ? { body: state() } : late.promise;
      })
      .on("POST", /\/admin\/audible\/sync$/, () => {
        posts += 1;
        return posts === 1 ? { status: 500, body: { error: "server_error" } } : answer(syncing, "Audible library sync queued.");
      });
    await openLibrary(server);
    const sync = section("audible-sync");
    await user.click(within(sync).getByRole("button", { name: "Sync library" }));
    await waitFor(() => expect(reads).toBe(2));
    await user.click(within(sync).getByRole("button", { name: "Sync library" }));
    expect(await within(sync).findByText("Audible library sync queued.")).toBeTruthy();
    late.resolve({ body: state() });
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect((within(sync).getByRole("button", { name: "Syncing…" }) as HTMLButtonElement).disabled).toBe(true);
    expect(within(sync).getByRole("progressbar", { name: "Library sync in progress" })).toBeTruthy();
  });

  test("edits typed while a save is on its way are kept and still marked unsaved", async () => {
    const user = userEvent.setup();
    const reply = deferred<{ body: unknown }>();
    const server = adminServer().on("PUT", /\/admin\/audible\/companion$/, () => reply.promise);
    await openLibrary(server);
    const connection = section("audible-connection");
    const timeout = within(connection).getByLabelText("Request timeout") as HTMLInputElement;
    await user.clear(timeout);
    await user.type(timeout, "45");
    await user.click(within(connection).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(server.called("PUT", /companion$/)).toHaveLength(1));
    await user.clear(timeout);
    await user.type(timeout, "90");
    reply.resolve(answer(state({ connection: { ...state().connection, timeout_seconds: 45 } }), "Audible backup connection saved."));
    expect(await within(connection).findByText("Audible backup connection saved.")).toBeTruthy();
    expect(timeout.value).toBe("90");
    expect(within(connection).getByText("Unsaved changes")).toBeTruthy();
  });

  test("filtering keeps the address fragment and focus on Filter without scrolling back to the card", async () => {
    const user = userEvent.setup();
    const { router } = await openLibrary(adminServer(), "#audible");
    const list = section("audible-catalogue");
    await within(list).findByRole("table");
    await user.type(within(list).getByLabelText("Title or author"), "Herbert");
    const filter = within(list).getByRole("button", { name: "Filter" });
    const scrolled: string[] = [];
    const original = Element.prototype.scrollIntoView;
    Element.prototype.scrollIntoView = function (this: Element) {
      scrolled.push(this.id);
    };
    await user.click(filter);
    await waitFor(() => expect(router.state.location.search).toEqual({ audible_q: "Herbert" }));
    await new Promise((resolve) => setTimeout(resolve, 50));
    Element.prototype.scrollIntoView = original;
    expect(router.state.location.hash).toBe("audible");
    expect(scrolled).toEqual([]);
    expect(document.activeElement === filter).toBe(true);
  });

  test("a token saved while other edits were made is not kept in the form or sent again", async () => {
    const user = userEvent.setup();
    const reply = deferred<{ body: unknown }>();
    let puts = 0;
    const server = adminServer().on("PUT", /\/admin\/audible\/companion$/, () => {
      puts += 1;
      return puts === 1 ? reply.promise : answer(current, "Audible backup connection saved.");
    });
    await openLibrary(server);
    const connection = section("audible-connection");
    await user.click(within(connection).getByRole("button", { name: "Replace" }));
    await user.type(connection.querySelector<HTMLInputElement>('input[name="bridge_token"]')!, "new-token-5521");
    await user.click(within(connection).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(puts).toBe(1));
    const timeout = within(connection).getByLabelText("Request timeout") as HTMLInputElement;
    await user.clear(timeout);
    await user.type(timeout, "90");
    reply.resolve(answer(state(), "Audible backup connection saved."));
    expect(await within(connection).findByText("Audible backup connection saved.")).toBeTruthy();
    expect(connection.querySelector<HTMLInputElement>('input[name="bridge_token"]')?.value ?? "").toBe("");
    expect(timeout.value).toBe("90");
    await user.click(within(connection).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(puts).toBe(2));
    expect(server.called("PUT", /companion$/)[1]!.body).toEqual({ companion: { url: "http://shelfarr-libation:8080", bridge_token: "", enabled: true, allow_private_network: true, timeout_seconds: "90" } });
  });

  test("a rejected save does not cancel the read that reconciles an earlier failed action", async () => {
    const user = userEvent.setup();
    const late = deferred<{ body: Audible }>();
    const syncing = state({ sync: { ...state().sync, state: "syncing", started_at: "2026-11-23T09:30:00Z", action: "Syncing…", available: false }, working: true });
    let reads = 0;
    const server = adminServer()
      .on("GET", /\/api\/v1\/admin\/audible$/, () => {
        reads += 1;
        return reads === 1 ? { body: state() } : reads === 2 ? late.promise : { body: syncing };
      })
      .on("POST", /\/admin\/audible\/sync$/, () => ({ status: 500, body: { error: "server_error" } }))
      .on("PUT", /\/admin\/audible\/companion$/, () => ({ status: 422, body: { account: ACCOUNT, error: "invalid_record", errors: [{ field: "timeout_seconds", message: "Request timeout must be less than or equal to 120" }] } }));
    await openLibrary(server);
    const sync = section("audible-sync");
    await user.click(within(sync).getByRole("button", { name: "Sync library" }));
    await waitFor(() => expect(reads).toBe(2));
    const connection = section("audible-connection");
    const timeout = within(connection).getByLabelText("Request timeout");
    await user.clear(timeout);
    await user.type(timeout, "500");
    await user.click(within(connection).getByRole("button", { name: "Save" }));
    expect(await within(connection).findByText("Request timeout must be less than or equal to 120")).toBeTruthy();
    late.resolve({ body: syncing });
    expect(await within(sync).findByRole("button", { name: "Syncing…" })).toBeTruthy();
    expect(within(sync).getByRole("progressbar", { name: "Library sync in progress" })).toBeTruthy();
  });

  test("an earlier outcome is not shown in the next action's section while that action runs", async () => {
    const user = userEvent.setup();
    const reply = deferred<{ body: unknown }>();
    const server = adminServer()
      .on("POST", /\/admin\/audible\/test$/, () => answer(current, "Connected to the Libation companion."))
      .on("POST", /\/admin\/audible\/sync$/, () => reply.promise);
    await openLibrary(server);
    await user.click(within(section("audible-connection")).getByRole("button", { name: "Test" }));
    expect(await within(section("audible-connection")).findByText(/Connected to the Libation companion\./)).toBeTruthy();
    await user.click(within(section("audible-sync")).getByRole("button", { name: "Sync library" }));
    await waitFor(() => expect(server.called("POST", /sync$/)).toHaveLength(1));
    expect(section("audible-sync").textContent).not.toContain("Connected to the Libation companion");
    reply.resolve(answer(current, "Audible library sync queued."));
    expect(await within(section("audible-sync")).findByText("Audible library sync queued.")).toBeTruthy();
  });
  test("an idle card notices work started elsewhere, such as a scheduled sync, and reads its state again", async () => {
    const syncing = state({ sync: { ...state().sync, state: "syncing", started_at: "2026-11-23T09:30:00Z", action: "Syncing…", available: false }, working: true, revision: "1111111111111111" });
    const server = adminServer().on("GET", /\/api\/v1\/admin\/audible\/revision$/, () => {
      current = syncing;
      return { body: { account: ACCOUNT, revision: syncing.revision } };
    });
    await openLibrary(server);
    const sync = section("audible-sync");
    expect(await within(sync).findByRole("progressbar", { name: "Library sync in progress" })).toBeTruthy();
    expect(server.called("GET", /admin\/audible\/revision$/).length).toBeGreaterThan(0);
  });
});
