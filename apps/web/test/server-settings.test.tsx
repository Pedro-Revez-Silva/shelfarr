import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ServerSettings, SettingField, SettingGroup } from "../src/server/contract";
import { serverSettingsSchema } from "../src/server/contract";
import { changedKeys, initialDrafts, isVisible, submission } from "../src/server/draft";
import { sentences } from "../src/server/primitives";
import { ACCOUNT, FakeServer, renderApp, session, standardServer } from "./helpers";

afterEach(cleanup);

const ADMIN = { admin: { url: "/sub/admin" }, capabilities: { administrator: true, can_upload: true, single_sign_on: false, hardcover_personal_access: false } };

function field(key: string, overrides: Partial<SettingField> = {}): SettingField {
  return { key, label: key, description: `About ${key}.`, input: "text", value: "", ...overrides };
}

function group(id: string, overrides: Partial<SettingGroup> = {}): SettingGroup {
  return { id, title: id, summary: `${id} summary`, fields: [], advanced: [], probes: [], extras: [], notes: [], ...overrides };
}

function settingsFixture(): ServerSettings {
  return {
    account: ACCOUNT,
    categories: [
      {
        id: "policy",
        title: "Request policy",
        summary: "What happens when someone asks for a book.",
        groups: [
          group("new_requests", {
            title: "New requests",
            fields: [
              field("auto_approve_requests", { label: "Start everyone's requests automatically", input: "toggle", value: false }),
              field("default_request_format", {
                label: "Format chosen on the request form",
                input: "choice",
                value: "ask",
                options: [
                  { value: "ask", label: "Ask each time" },
                  { value: "ebook", label: "Ebook" },
                ],
              }),
            ],
            advanced: [field("queue_batch_size", { label: "Requests per queue run", input: "number", value: 5, default: 5 })],
          }),
          group("formats", {
            title: "Formats and sizes",
            fields: [field("ebook_preferred_formats", { label: "Preferred ebook formats", input: "list", value: ["epub", "pdf"] })],
          }),
        ],
      },
      {
        id: "sources",
        title: "Catalogues and sources",
        summary: "Where Shelfarr looks up books and where it finds copies.",
        groups: [
          group("hardcover", {
            heading: "Catalogues",
            title: "Hardcover",
            toggle: "hardcover_enabled",
            fields: [field("hardcover_enabled", { label: "Use Hardcover", input: "toggle", value: true }), field("hardcover_api_token", { label: "API token", input: "secret", value: null, configured: true })],
            probes: [{ id: "hardcover", label: "Test", uses: "saved", changes: false }],
            health: { service: "hardcover", status: "down", message: "Token rejected", checked_at: "2026-11-22T10:00:00Z" },
          }),
          group("indexer", {
            heading: "File sources",
            title: "Indexer",
            fields: [
              field("indexer_provider", { label: "Indexer", input: "choice", value: "prowlarr", options: [{ value: "none", label: "None" }, { value: "prowlarr", label: "Prowlarr" }, { value: "jackett", label: "Jackett" }] }),
              field("prowlarr_url", { label: "Prowlarr address", input: "url", value: "http://prowlarr.test", visible_when: { key: "indexer_provider", in: ["prowlarr"] } }),
              field("jackett_url", { label: "Jackett address", input: "url", value: "", visible_when: { key: "indexer_provider", in: ["jackett"] } }),
            ],
            probes: [{ id: "indexer", label: "Test", uses: "draft", changes: false }],
          }),
        ],
      },
      {
        id: "downloads",
        title: "Downloads",
        summary: "Which releases Shelfarr prefers.",
        groups: [
          group("release_types", {
            title: "Release types",
            fields: [
              field("preferred_download_types", {
                label: "Preferred release types",
                input: "order",
                value: ["torrent", "usenet", "direct"],
                options: [
                  { value: "torrent", label: "Torrent" },
                  { value: "usenet", label: "Usenet" },
                  { value: "direct", label: "Direct" },
                ],
              }),
            ],
          }),
        ],
      },
      { id: "library", title: "Library and files", summary: "Files.", groups: [] },
      {
        id: "notifications",
        title: "Notifications",
        summary: "Tell other apps.",
        groups: [
          group("webhook", {
            title: "Webhook",
            toggle: "webhook_enabled",
            fields: [
              field("webhook_enabled", { label: "Send webhooks", input: "toggle", value: true }),
              field("webhook_url", { label: "Webhook address", input: "url", value: "https://env.example/hook", managed_by: "SHELFARR_SETTING_WEBHOOK_URL" }),
              field("webhook_events", { label: "Send these updates", input: "events", value: ["request_created"], options: [{ value: "request_created", label: "Request created" }, { value: "request_failed", label: "Request failed" }] }),
            ],
          }),
          group("telegram", { title: "Telegram", extras: ["telegram_chats"] }),
        ],
      },
      { id: "people", title: "People and access", summary: "Who can sign in.", groups: [group("member_permissions", { title: "What members can do", extras: ["roles"] })] },
      { id: "system", title: "System", summary: "Health checks.", groups: [] },
    ],
    notes: { path_variables: "Use {title}.", hardcover_app: { create_url: "https://hardcover.app/account/developer-apps/new", scopes: "read:me", redirect_uri: "https://shelf.test/hardcover/connection/callback", redirect_uri_acceptable: true } },
    roles: [{ action: "Upload a book file", member: "No", administrator: "Yes", setting: { category: "people", group: "member_permissions", key: "allow_user_uploads" } }],
  };
}

function overviewFixture() {
  return {
    account: ACCOUNT,
    counts: { users: 3, books: 1234, active_requests: 2, attention_requests: 1 },
    services: ["indexer", "download_client", "download_paths", "output_paths", "audiobookshelf", "hardcover"].map((service) => ({
      service,
      status: service === "indexer" ? "down" : null,
      checked_at: service === "indexer" ? "2026-11-22T10:00:00Z" : null,
      ...(service === "indexer" ? { message: "Connection refused", fix: { category: "sources", group: "indexer", label: "Indexer settings" } } : {}),
    })),
    release: {
      build: "1.0.0",
      channel: "Shelfarr 1.0",
      beta: false,
      series: "1.0",
      image: "ghcr.io/example/shelfarr:1",
      image_tag: "1",
      guide_url: "https://github.com/example/shelfarr/blob/main/docs/releases.md",
      latest: { state: "current", version: "1.0.0" },
    },
  };
}

function adminServer(settings: ServerSettings = settingsFixture()): FakeServer {
  return standardServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(ADMIN) }))
    .on("GET", /\/api\/v1\/admin\/settings$/, () => ({ body: settings }))
    .on("GET", /\/api\/v1\/admin\/overview$/, () => ({ body: overviewFixture() }))
    .on("GET", /\/api\/v1\/admin\/settings\/telegram_chats$/, () => ({ body: { account: ACCOUNT, chats: [] } }))
    .on("GET", /\/api\/v1\/admin\/settings\/library$/, () => ({
      body: { account: ACCOUNT, platform: "Audiobookshelf", configured: false, libraries: [], inventory: { count: 0, available: 0, missing: 0, last_synced_at: null, recent: [] } },
    }));
}

function card(name: string): HTMLElement {
  return screen.getByRole("heading", { name, level: 3 }).closest("section")!;
}

describe("Server settings drafts", () => {
  test("only changed values are sent, each in the form the classic page sent", () => {
    const sample = settingsFixture();
    const release = sample.categories[2]!.groups[0]!;
    const drafts = { ...initialDrafts(release), preferred_download_types: ["usenet", "torrent", "direct"] };
    expect(changedKeys(release, drafts)).toEqual(["preferred_download_types"]);
    expect(submission(release, drafts, ["preferred_download_types"])).toEqual({ preferred_download_types: '["usenet","torrent","direct"]' });

    const webhook = sample.categories[4]!.groups[0]!;
    const webhookDrafts = { ...initialDrafts(webhook), webhook_url: "https://changed.example", webhook_events: ["request_created", "request_failed"], webhook_enabled: false };
    expect(changedKeys(webhook, webhookDrafts)).toEqual(["webhook_enabled", "webhook_events"]);
    expect(submission(webhook, webhookDrafts, changedKeys(webhook, webhookDrafts))).toEqual({ webhook_enabled: "false", webhook_events: "request_created,request_failed" });

    const hardcover = sample.categories[1]!.groups[0]!;
    expect(changedKeys(hardcover, initialDrafts(hardcover))).toEqual([]);
    expect(changedKeys(hardcover, { ...initialDrafts(hardcover), hardcover_api_token: "new" })).toEqual(["hardcover_api_token"]);
  });

  test("conditional and switched-off fields follow the values being edited", () => {
    const sample = settingsFixture();
    const indexer = sample.categories[1]!.groups[1]!;
    const [, prowlarr, jackett] = indexer.fields;
    const drafts = initialDrafts(indexer);
    expect([isVisible(prowlarr!, indexer, drafts), isVisible(jackett!, indexer, drafts)]).toEqual([true, false]);
    expect([isVisible(prowlarr!, indexer, { ...drafts, indexer_provider: "jackett" }), isVisible(jackett!, indexer, { ...drafts, indexer_provider: "jackett" })]).toEqual([false, true]);
    const hardcover = sample.categories[1]!.groups[0]!;
    expect(isVisible(hardcover.fields[1]!, hardcover, { ...initialDrafts(hardcover), hardcover_enabled: false })).toBe(false);
  });

  test("server descriptions read as sentences when joined with the page's own hints", () => {
    expect(sentences("Telegram webhook secret checked against X-Telegram-Bot-Api-Secret-Token", "Nothing is saved yet.", null, " ")).toBe("Telegram webhook secret checked against X-Telegram-Bot-Api-Secret-Token. Nothing is saved yet.");
    expect(sentences("Base URL (for example, http://prowlarr:9696)", "60 to 100.")).toBe("Base URL (for example, http://prowlarr:9696) 60 to 100.");
  });

  test("the fixture matches the settings contract", () => {
    expect(serverSettingsSchema.safeParse(settingsFixture()).success).toBe(true);
  });
});

describe("Server in the Rails preview", () => {
  test("a member sees no Server link and the page refuses without asking the server", async () => {
    const server = standardServer();
    renderApp({ server, url: "/sub/preview/server/policy" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(within(nav).queryByRole("link", { name: "Server" })).toBeNull();
    expect(server.requests.filter((request) => request.path.includes("/admin/"))).toEqual([]);
  });

  test("an administrator opens Server from the navigation, sees health beside its fix and runs a health check", async () => {
    const server = adminServer().on("POST", /\/admin\/overview\/health_check$/, () => ({ body: { ...overviewFixture(), outcome: { tone: "success", message: "Health check started. Results will appear shortly." } } }));
    const { router } = renderApp({ server });
    const nav = await screen.findByRole("navigation", { name: "Primary" });
    const link = await within(nav).findByRole("link", { name: "Server" });
    expect(link.getAttribute("href")).toBe("/sub/preview/server");
    await userEvent.click(link);
    expect(await screen.findByRole("heading", { name: "Server overview", level: 1 })).toBeTruthy();
    const attention = (await screen.findByRole("heading", { name: "Needs attention", level: 2 })).closest("section")!;
    expect(within(attention).getByText("Connection refused")).toBeTruthy();
    expect(within(attention).getByRole("link", { name: "Open indexer settings" }).getAttribute("href")).toBe("/sub/preview/server/sources#indexer");
    expect(screen.getByText("You're up to date")).toBeTruthy();
    const rail = screen.getByRole("navigation", { name: "Server" });
    expect(within(rail).getAllByRole("link").map((entry) => entry.textContent)).toEqual(["Overview", "Request policy", "Catalogues and sources", "Downloads", "Library and files", "Notifications", "People and access", "System"]);
    expect(within(rail).getByRole("link", { name: "Overview" }).getAttribute("aria-current")).toBe("page");

    await userEvent.click(screen.getByRole("button", { name: "Run health check" }));
    expect(await screen.findByText("Health check started. Results will appear shortly.")).toBeTruthy();
    expect(server.called("POST", /health_check$/)[0]!.headers["x-csrf-token"]).toBe("token-123");
    expect(router.state.location.pathname).toBe("/server");
  });

  test("a card shows normal settings first, keeps the rest under Advanced and saves only what changed", async () => {
    const saved = settingsFixture().categories[0]!.groups[0]!;
    const server = adminServer().on("PUT", /\/admin\/settings\/groups\/new_requests$/, (request) => ({
      body: {
        account: ACCOUNT,
        outcome: { tone: "success", message: "Settings saved." },
        changed: Object.keys(request.body as { values: object }),
        group: { ...saved, fields: saved.fields.map((entry) => (entry.key === "auto_approve_requests" ? { ...entry, value: true } : entry)), advanced: saved.advanced.map((entry) => ({ ...entry, value: 9 })) },
      },
    }));
    renderApp({ server, url: "/sub/preview/server/policy" });
    const requests = await waitFor(() => card("New requests"));
    expect(within(requests).getByRole("checkbox", { name: "Start everyone's requests automatically" })).toBeTruthy();
    const advanced = within(requests).getByText("Advanced").closest("details")!;
    expect(advanced.open).toBe(false);
    await userEvent.click(within(requests).getByRole("checkbox", { name: "Start everyone's requests automatically" }));
    expect(within(requests).getByText("Unsaved changes")).toBeTruthy();
    await userEvent.click(within(advanced).getByText("Advanced"));
    const batch = within(requests).getByRole("textbox", { name: "Requests per queue run" });
    await userEvent.clear(batch);
    await userEvent.type(batch, "9");
    expect(within(advanced).getByText("· 1 changed")).toBeTruthy();
    await userEvent.click(within(requests).getByRole("button", { name: "Save" }));
    expect(await within(requests).findByText("Settings saved.")).toBeTruthy();
    expect(server.called("PUT", /new_requests$/).map((request) => request.body)).toEqual([{ values: { auto_approve_requests: "true", queue_batch_size: "9" } }]);
    expect(within(requests).queryByText("Unsaved changes")).toBeNull();
    expect(card("Formats and sizes")).toBeTruthy();
    expect(server.called("PUT", /formats$/)).toEqual([]);
  });

  test("a refused save marks the field, opens Advanced for it and keeps the typed value", async () => {
    const server = adminServer().on("PUT", /new_requests$/, () => ({
      status: 422,
      body: { account: ACCOUNT, error: "invalid_settings", errors: [{ key: "queue_batch_size", message: "Queue Batch Size: must be an integer" }] },
    }));
    renderApp({ server, url: "/sub/preview/server/policy" });
    const requests = await waitFor(() => card("New requests"));
    await userEvent.click(within(requests).getByText("Advanced"));
    const batch = within(requests).getByRole("textbox", { name: "Requests per queue run" }) as HTMLInputElement;
    await userEvent.clear(batch);
    await userEvent.type(batch, "lots");
    await userEvent.click(within(requests).getByText("Advanced"));
    await userEvent.click(within(requests).getByRole("button", { name: "Save" }));
    expect(await within(requests).findByText("Nothing was saved. Check the marked fields.")).toBeTruthy();
    const marked = within(requests).getByRole("textbox", { name: "Requests per queue run" }) as HTMLInputElement;
    expect(marked.getAttribute("aria-invalid")).toBe("true");
    expect(marked.value).toBe("lots");
    expect(within(requests).getByText("Queue Batch Size: must be an integer")).toBeTruthy();
    expect((within(requests).getByText("Advanced").closest("details") as HTMLDetailsElement).open).toBe(true);
    await waitFor(() => expect(document.activeElement).toBe(marked));
  });

  test("secrets are write-only, health sits on the card and a saved-settings test says what it tested", async () => {
    const server = adminServer().on("POST", /\/admin\/settings\/probes\/hardcover$/, () => ({ body: { account: ACCOUNT, outcome: { tone: "error", message: "Hardcover connection failed." } } }));
    renderApp({ server, url: "/sub/preview/server/sources" });
    const hardcover = await waitFor(() => card("Hardcover"));
    expect(within(hardcover).getByText("Down")).toBeTruthy();
    expect(within(hardcover).getByText("Token rejected")).toBeTruthy();
    expect(within(hardcover).getByText("Saved")).toBeTruthy();
    expect(within(hardcover).queryByLabelText("API token")).toBeNull();
    await userEvent.click(within(hardcover).getByRole("button", { name: "Replace" }));
    const token = within(hardcover).getByLabelText("API token") as HTMLInputElement;
    expect(token.type).toBe("password");
    expect(token.value).toBe("");
    await userEvent.type(token, "new-token");
    await userEvent.click(within(hardcover).getByRole("button", { name: "Test" }));
    expect(await within(hardcover).findByText(/Hardcover connection failed\./)).toBeTruthy();
    expect(within(hardcover).getByText("This tested the saved settings, not your unsaved changes.")).toBeTruthy();
    expect(server.called("POST", /probes\/hardcover$/)[0]!.body).toEqual({ values: {} });
    await userEvent.click(within(hardcover).getByRole("button", { name: "Keep saved" }));
    expect(within(hardcover).queryByText("Unsaved changes")).toBeNull();
  });

  test("a draft test sends the typed connection, and switching provider shows its own fields", async () => {
    const server = adminServer().on("POST", /probes\/indexer$/, () => ({ body: { account: ACCOUNT, outcome: { tone: "success", message: "Jackett connection successful!" } } }));
    renderApp({ server, url: "/sub/preview/server/sources" });
    const indexer = await waitFor(() => card("Indexer"));
    expect(within(indexer).getByRole("textbox", { name: "Prowlarr address" })).toBeTruthy();
    expect(within(indexer).queryByRole("textbox", { name: "Jackett address" })).toBeNull();
    await userEvent.click(within(indexer).getByRole("radio", { name: "Jackett" }));
    await userEvent.type(within(indexer).getByRole("textbox", { name: "Jackett address" }), "http://jackett.test");
    await userEvent.click(within(indexer).getByRole("button", { name: "Test" }));
    expect(await within(indexer).findByText(/Jackett connection successful!/)).toBeTruthy();
    expect(server.called("POST", /probes\/indexer$/)[0]!.body).toEqual({ values: { indexer_provider: "jackett", prowlarr_url: "http://prowlarr.test", jackett_url: "http://jackett.test" } });
  });

  test("environment-managed settings are read-only and are never sent", async () => {
    const server = adminServer().on("PUT", /webhook$/, () => ({ body: { account: ACCOUNT, outcome: { tone: "success", message: "Settings saved." }, changed: [], group: settingsFixture().categories[4]!.groups[0]! } }));
    renderApp({ server, url: "/sub/preview/server/notifications" });
    const webhook = await waitFor(() => card("Webhook"));
    expect(within(webhook).getByText("https://env.example/hook")).toBeTruthy();
    expect(within(webhook).getByText("SHELFARR_SETTING_WEBHOOK_URL")).toBeTruthy();
    expect(within(webhook).queryByRole("textbox", { name: "Webhook address" })).toBeNull();
    await userEvent.click(within(webhook).getByRole("checkbox", { name: "Request failed" }));
    await userEvent.click(within(webhook).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(server.called("PUT", /webhook$/).length).toBe(1));
    expect(server.called("PUT", /webhook$/)[0]!.body).toEqual({ values: { webhook_events: "request_created,request_failed" } });
  });

  test("release types reorder with buttons that keep focus and announce the new place", async () => {
    renderApp({ server: adminServer(), url: "/sub/preview/server/downloads" });
    const release = await waitFor(() => card("Release types"));
    await userEvent.click(within(release).getByRole("button", { name: "Move Usenet up" }));
    expect(within(release).getAllByRole("listitem").map((item) => item.querySelector(".order-name")?.textContent)).toEqual(["Usenet", "Torrent", "Direct"]);
    expect(within(release).getByText("Usenet moved to position 1 of 3.")).toBeTruthy();
    await waitFor(() => expect(document.activeElement?.getAttribute("aria-label")).toBe("Move Usenet down"));
    expect((within(release).getByRole("button", { name: "Move Usenet up" }) as HTMLButtonElement).disabled).toBe(true);
  });

  test("leaving a category with unsaved changes asks first", async () => {
    const { router } = renderApp({ server: adminServer(), url: "/sub/preview/server/policy" });
    const requests = await waitFor(() => card("New requests"));
    await userEvent.click(within(requests).getByRole("radio", { name: "Ebook" }));
    await userEvent.click(within(screen.getByRole("navigation", { name: "Server" })).getByRole("link", { name: "Downloads" }));
    expect(await screen.findByRole("heading", { name: "Leave without saving?" })).toBeTruthy();
    await userEvent.click(screen.getByRole("button", { name: "Stay and keep editing" }));
    expect(router.state.location.pathname).toBe("/server/policy");
    expect((within(card("New requests")).getByRole("radio", { name: "Ebook" }) as HTMLInputElement).checked).toBe(true);
    await userEvent.click(within(screen.getByRole("navigation", { name: "Server" })).getByRole("link", { name: "Downloads" }));
    await userEvent.click(await screen.findByRole("button", { name: "Leave and discard" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/server/downloads"));
  });

  test("Telegram groups are approved and removed only after a second confirmation", async () => {
    let chats = [{ id: "4", label: "Book club", chat_id: "-100555", state: "authorized" }];
    const server = adminServer()
      .on("GET", /telegram_chats$/, () => ({ body: { account: ACCOUNT, chats } }))
      .on("POST", /telegram_chats$/, () => ({ body: { account: ACCOUNT, outcome: { tone: "error", message: "Telegram group code is invalid or expired." }, chats } }))
      .on("DELETE", /telegram_chats\/4$/, () => {
        chats = [];
        return { body: { account: ACCOUNT, outcome: { tone: "success", message: "Telegram group removed: Book club" }, chats } };
      });
    renderApp({ server, url: "/sub/preview/server/notifications" });
    const telegram = await waitFor(() => card("Telegram"));
    await within(telegram).findByText("-100555");
    await userEvent.type(within(telegram).getByRole("textbox", { name: "Approval code" }), "12ab3456");
    expect((within(telegram).getByRole("textbox", { name: "Approval code" }) as HTMLInputElement).value).toBe("123456");
    await userEvent.click(within(telegram).getByRole("button", { name: "Approve group" }));
    expect(await within(telegram).findByText("Telegram group code is invalid or expired.")).toBeTruthy();
    expect(server.called("POST", /telegram_chats$/)[0]!.body).toEqual({ code: "123456" });
    await userEvent.click(within(telegram).getByRole("button", { name: "Remove Book club" }));
    expect(server.called("DELETE", /telegram_chats/)).toEqual([]);
    await userEvent.click(within(telegram).getByRole("button", { name: "Remove group" }));
    expect(await within(telegram).findByText("Telegram group removed: Book club")).toBeTruthy();
    expect(within(telegram).getByText("No groups have been approved yet.")).toBeTruthy();
  });

  test("the roles readout links each permission to the card that changes it", async () => {
    renderApp({ server: adminServer(), url: "/sub/preview/server/people" });
    const members = await waitFor(() => card("What members can do"));
    const row = within(members).getByRole("row", { name: /Upload a book file/ });
    expect(within(row).getByRole("link", { name: /Change/ }).getAttribute("href")).toBe("/sub/preview/server/people#member_permissions");
  });

  test("an old settings address lands on the category that replaced its tab", async () => {
    const { router } = renderApp({ server: adminServer(), url: "/sub/preview/admin/settings#security" });
    await waitFor(() => expect(router.state.location.pathname).toBe("/server/people"));
    const second = renderApp({ server: adminServer(), url: "/sub/preview/admin" });
    await waitFor(() => expect(second.router.state.location.pathname).toBe("/server"));
    await act(async () => undefined);
  });
});
