import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ServerSettings } from "../src/server/contract";
import { downloadsSchema, type DownloadClient, type Downloads, type RoutingRule } from "../src/server/downloads/contract";
import { clientSubmission, initialClientDraft, ruleTypeChange, submission } from "../src/server/downloads/forms";
import { REMOVE_SAVED } from "../src/server/draft";
import { ACCOUNT, deferred, FakeServer, renderApp, session, standardServer } from "./helpers";

afterEach(cleanup);

const ADMIN = { admin: { url: "/sub/admin" }, capabilities: { administrator: true, can_upload: true, single_sign_on: false, hardcover_personal_access: false } };

function client(overrides: Partial<DownloadClient> = {}): DownloadClient {
  return {
    id: "1",
    version: "2026-11-22T10:00:00.000000Z",
    name: "Home qBittorrent",
    client_type: "qbittorrent",
    kind: "torrent",
    url: "http://qbit.test:8080",
    url_hidden: false,
    username: "admin",
    category: "",
    download_path: "",
    enabled: true,
    priority: 0,
    torrent_verification_max_attempts: 10,
    torrent_verification_wait_time: 2,
    password_saved: true,
    api_key_saved: true,
    rule_count: 0,
    rule_ids: [],
    ...overrides,
  };
}

function rule(overrides: Partial<RoutingRule> = {}): RoutingRule {
  return {
    id: "5",
    version: "2026-11-22T10:00:00.000000Z",
    provider: "prowlarr",
    provider_label: "Prowlarr",
    indexer_name: "MyAnonaMouse",
    download_type: "torrent",
    client_id: "2",
    client_name: "Seedbox qBittorrent",
    client_enabled: true,
    client_kind: "torrent",
    enabled: true,
    ...overrides,
  };
}

function downloadsFixture(overrides: Partial<Downloads> = {}): Downloads {
  return {
    account: ACCOUNT,
    clients: [client(), client({ id: "2", name: "Seedbox qBittorrent", url: "http://seedbox.test:8080", priority: 1, password_saved: false, api_key_saved: false, rule_count: 1, rule_ids: ["5"] }), client({ id: "3", name: "SABnzbd", client_type: "sabnzbd", kind: "usenet", url: "http://sab.test:8085", username: "", password_saved: false })],
    rules: [rule()],
    client_types: [
      { value: "qbittorrent", label: "qBittorrent", kind: "torrent", authentication: true, api_key: true, verification: true },
      { value: "decypharr", label: "Decypharr", kind: "torrent", authentication: true, api_key: false, verification: false },
      { value: "sabnzbd", label: "SABnzbd", kind: "usenet", authentication: false, api_key: true, verification: false },
      { value: "nzbget", label: "NZBGet", kind: "usenet", authentication: true, api_key: false, verification: false },
      { value: "deluge", label: "Deluge", kind: "torrent", authentication: true, api_key: false, verification: false },
      { value: "transmission", label: "Transmission", kind: "torrent", authentication: true, api_key: false, verification: false },
    ],
    providers: [
      { value: "prowlarr", label: "Prowlarr" },
      { value: "jackett", label: "Jackett" },
      { value: "newznab", label: "NZBHydra2 / Newznab" },
    ],
    download_types: [
      { value: "torrent", label: "Torrent" },
      { value: "usenet", label: "Usenet" },
    ],
    defaults: { client_type: "qbittorrent", enabled: true, torrent_verification_max_attempts: 10, torrent_verification_wait_time: 2 },
    health: { status: "degraded", message: "2/3 working. Failed: SABnzbd (Connection refused)", checked_at: "2026-11-22T10:00:00Z" },
    ...overrides,
  };
}

function settingsFixture(): ServerSettings {
  const empty = (id: ServerSettings["categories"][number]["id"], title: string) => ({ id, title, summary: `${title}.`, groups: [] });
  return {
    account: ACCOUNT,
    categories: [
      empty("policy", "Request policy"),
      empty("sources", "Catalogues and sources"),
      {
        id: "downloads",
        title: "Downloads",
        summary: "Which releases Shelfarr prefers and where download clients put their files.",
        groups: [{ id: "path_mapping", title: "Path mapping", summary: "Where Shelfarr finds the files.", fields: [{ key: "download_local_path", label: "Local path", description: "", input: "text", value: "/downloads" }], advanced: [], probes: [], extras: [], notes: [] }],
      },
      empty("library", "Library and files"),
      empty("notifications", "Notifications"),
      empty("people", "People and access"),
      empty("system", "System"),
    ],
    notes: { path_variables: "", hardcover_app: { create_url: "https://hardcover.app/x", scopes: "read", redirect_uri: "https://shelf.test/cb", redirect_uri_acceptable: true } },
    roles: [],
  };
}

let current: Downloads = downloadsFixture();

function action(downloads: Downloads, message: string, extra: Record<string, string | boolean> = {}, tone: "success" | "error" = "success") {
  current = downloads;
  return { body: { ...downloads, outcome: { tone, message }, ...extra } };
}

function adminServer(initial: Downloads = downloadsFixture()): FakeServer {
  current = initial;
  return standardServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(ADMIN) }))
    .on("GET", /\/api\/v1\/admin\/settings$/, () => ({ body: settingsFixture() }))
    .on("GET", /\/api\/v1\/admin\/downloads$/, () => ({ body: current }));
}

function clientsCard(): HTMLElement {
  return screen.getByRole("heading", { name: "Download clients", level: 3 }).closest("section")!;
}

function rulesCard(): HTMLElement {
  return screen.getByRole("heading", { name: "Routing rules", level: 3 }).closest("section")!;
}

function row(name: string): HTMLElement {
  return screen.getByRole("listitem", { name }) as HTMLElement;
}

async function openDownloads(server: FakeServer) {
  const rendered = renderApp({ server, url: "/sub/preview/server/downloads" });
  await screen.findByRole("heading", { name: "Home qBittorrent", level: 5 });
  return rendered;
}

describe("download client and rule drafts", () => {
  const data = downloadsFixture();
  const qbit = data.clients[0]!;
  const qbitType = data.client_types[0]!;

  test("an edit sends only what changed, keeps blank secrets and clears the API key only when asked", () => {
    const initial = initialClientDraft(qbit, data.defaults);
    expect(clientSubmission(qbitType, qbit, { ...initial, name: "Home", password: "  " }, initial)).toEqual({ name: "Home" });
    expect(clientSubmission(qbitType, qbit, { ...initial, password: "new-secret", api_key: REMOVE_SAVED }, initial)).toEqual({ password: "new-secret", api_key: "", clear_api_key: "1" });
    expect(clientSubmission(qbitType, qbit, { ...initial, enabled: false, torrent_verification_wait_time: "5" }, initial)).toEqual({ enabled: false, torrent_verification_wait_time: "5" });
  });

  test("switching type drops the fields that type does not have", () => {
    const initial = initialClientDraft(qbit, data.defaults);
    const sab = data.client_types[2]!;
    expect(clientSubmission(sab, qbit, { ...initial, client_type: "sabnzbd", username: "typed", torrent_verification_wait_time: "9" }, initial)).toEqual({ client_type: "sabnzbd" });
  });

  test("a new client sends every field its type shows, without blank secrets", () => {
    const initial = initialClientDraft(null, data.defaults);
    expect(clientSubmission(qbitType, null, { ...initial, name: "New", url: "http://new.test" }, initial)).toEqual({
      name: "New",
      client_type: "qbittorrent",
      url: "http://new.test",
      username: "",
      category: "",
      download_path: "",
      enabled: true,
      torrent_verification_max_attempts: "10",
      torrent_verification_wait_time: "2",
    });
    const deluge = data.client_types[4]!;
    expect(Object.keys(clientSubmission(deluge, null, { ...initial, client_type: "deluge", password: "pw" }, initial))).toEqual(["name", "client_type", "url", "username", "password", "category", "download_path", "enabled"]);
  });

  test("changing a rule's download type keeps the client only when it is of that kind", () => {
    const drafts = { provider: "prowlarr", download_type: "torrent", indexer_name: "X", download_client_id: "2", enabled: true };
    expect(ruleTypeChange(drafts, data, "usenet")).toEqual({ ...drafts, download_type: "usenet", download_client_id: "" });
    expect(ruleTypeChange({ ...drafts, download_client_id: "3" }, data, "usenet")).toEqual({ ...drafts, download_type: "usenet", download_client_id: "3" });
    expect(submission(["indexer_name", "enabled"], { ...drafts, enabled: false })).toEqual({ indexer_name: "X", enabled: false });
  });

  test("the fixture matches the downloads contract", () => {
    expect(downloadsSchema.safeParse(downloadsFixture()).success).toBe(true);
  });
});

describe("Server ▸ Downloads in the Rails preview", () => {
  test("a member sees the administrators-only page and no download data is asked for", async () => {
    const server = standardServer();
    renderApp({ server, url: "/sub/preview/server/downloads" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(server.requests.filter((request) => request.path.includes("/admin/"))).toEqual([]);
  });

  test("clients are grouped by kind with health on the card, and secrets appear only as Saved", async () => {
    await openDownloads(adminServer());
    const index = screen.getByRole("navigation", { name: "Downloads cards" });
    expect(within(index).getAllByRole("link").map((link) => link.getAttribute("href"))).toEqual(["#download_clients", "#routing_rules", "#path_mapping"]);
    const card = clientsCard();
    expect(within(card).getByText("Degraded")).toBeTruthy();
    expect(within(card).getByText("2/3 working. Failed: SABnzbd (Connection refused)")).toBeTruthy();
    expect(within(card).getAllByRole("heading", { level: 5 }).map((heading) => heading.textContent)).toEqual(["Home qBittorrent", "Seedbox qBittorrent", "SABnzbd"]);
    expect(within(row("SABnzbd")).getByText("Usenet")).toBeTruthy();
    const home = row("Home qBittorrent");
    expect(within(home).getByText("Priority 1")).toBeTruthy();
    expect((within(home).getByRole("button", { name: "Move Home qBittorrent up" }) as HTMLButtonElement).disabled).toBe(true);
    expect((within(home).getByRole("button", { name: "Move Home qBittorrent down" }) as HTMLButtonElement).disabled).toBe(false);
    expect((within(row("SABnzbd")).getByRole("button", { name: "Move SABnzbd up" }) as HTMLButtonElement).disabled).toBe(true);
    await userEvent.click(within(home).getByRole("button", { name: "Edit" }));
    const form = within(home).getByRole("form", { name: "Home qBittorrent" });
    expect(within(form).getAllByText("Saved")).toHaveLength(2);
    expect(within(form).queryByLabelText("Password")).toBeNull();
    expect(within(form).getByRole("button", { name: "Remove" })).toBeTruthy();
  });

  test("an edit saves only the changed fields with the version it was opened at and returns focus to Edit", async () => {
    const server = adminServer().on("PUT", /\/admin\/downloads\/clients\/1$/, () => action(downloadsFixture({ clients: [client({ name: "Home", version: "v2" }), ...downloadsFixture().clients.slice(1)] }), "Download client “Home” saved."));
    await openDownloads(server);
    const user = userEvent.setup();
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Edit" }));
    const name = within(row("Home qBittorrent")).getByLabelText("Name");
    await user.clear(name);
    await user.type(name, "Home");
    expect(within(row("Home qBittorrent")).getByText("Unsaved changes")).toBeTruthy();
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Save" }));
    expect(await within(clientsCard()).findByText("Download client “Home” saved.")).toBeTruthy();
    const sent = server.called("PUT", /clients\/1$/)[0]!;
    expect(sent.body).toEqual({ version: "2026-11-22T10:00:00.000000Z", client: { name: "Home" } });
    expect(sent.headers["x-csrf-token"]).toBe("token-123");
    await waitFor(() => expect(document.activeElement?.textContent).toBe("Edit"));
    expect(within(row("Home")).queryByRole("form")).toBeNull();
  });

  test("a refused save marks the field, moves focus to it and keeps the edit", async () => {
    const server = adminServer().on("PUT", /clients\/1$/, () => ({ status: 422, body: { account: ACCOUNT, error: "invalid_record", errors: [{ field: "url", message: "Url must be a valid HTTP or HTTPS URL" }] } }));
    await openDownloads(server);
    const user = userEvent.setup();
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Edit" }));
    const address = within(row("Home qBittorrent")).getByLabelText("Address");
    await user.clear(address);
    await user.type(address, "ftp://nope");
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Save" }));
    expect(await within(row("Home qBittorrent")).findByText("Url must be a valid HTTP or HTTPS URL")).toBeTruthy();
    await waitFor(() => expect(document.activeElement).toBe(address));
    expect(address.getAttribute("aria-invalid")).toBe("true");
    expect((address as HTMLInputElement).value).toBe("ftp://nope");
  });

  test("a save from an out-of-date copy says so, keeps the edits and sends the new version next time", async () => {
    let attempts = 0;
    const changed = downloadsFixture({ clients: [client({ version: "v2", category: "someone-else" }), ...downloadsFixture().clients.slice(1)] });
    const server = adminServer().on("PUT", /clients\/1$/, () => {
      attempts += 1;
      current = changed;
      return attempts === 1 ? { status: 409, body: { ...changed, error: "download_changed" } } : action(changed, "Download client “Home qBittorrent” saved.");
    });
    await openDownloads(server);
    const user = userEvent.setup();
    const home = row("Home qBittorrent");
    await user.click(within(home).getByRole("button", { name: "Edit" }));
    await user.type(within(home).getByLabelText("Download folder"), "/mine");
    await user.click(within(home).getByRole("button", { name: "Save" }));
    expect(await within(home).findByRole("alert")).toBeTruthy();
    expect(within(home).getByRole("alert").textContent).toContain("changed somewhere else");
    expect((within(home).getByLabelText("Download folder") as HTMLInputElement).value).toBe("/mine");
    expect((within(home).getByLabelText("Category") as HTMLInputElement).value).toBe("someone-else");
    await user.click(within(home).getByRole("button", { name: "Save" }));
    await within(clientsCard()).findByText("Download client “Home qBittorrent” saved.");
    expect(server.called("PUT", /clients\/1$/).map((request) => request.body)).toEqual([
      { version: "2026-11-22T10:00:00.000000Z", client: { download_path: "/mine" } },
      { version: "v2", client: { download_path: "/mine" } },
    ]);
  });

  test("Test answers inside the client's row with the time and refreshes health", async () => {
    const server = adminServer().on("POST", /clients\/3\/test$/, () =>
      action(downloadsFixture({ health: { status: "down", message: "All clients failed", checked_at: "2026-11-22T11:00:00Z" } }), "Connection to 'SABnzbd' failed: Connection refused", { tested: "3" }, "error"),
    );
    await openDownloads(server);
    await userEvent.click(within(row("SABnzbd")).getByRole("button", { name: "Test" }));
    expect(await within(row("SABnzbd")).findByText(/Connection to 'SABnzbd' failed: Connection refused/)).toBeTruthy();
    expect(row("SABnzbd").querySelector("time")).toBeTruthy();
    expect(await within(clientsCard()).findByText("All clients failed")).toBeTruthy();
    expect(server.called("POST", /test$/)[0]!.headers["x-csrf-token"]).toBe("token-123");
  });

  test("moving a client announces its new place once and keeps focus on a move button", async () => {
    const moved = downloadsFixture();
    moved.clients = [client({ priority: 1, version: "v3" }), client({ id: "2", name: "Seedbox qBittorrent", priority: 0, rule_count: 1, rule_ids: ["5"], password_saved: false, api_key_saved: false })].reverse().concat(moved.clients.slice(2));
    const server = adminServer().on("POST", /clients\/1\/move$/, () => action(moved, "“Home qBittorrent” moved down.", { moved: true }));
    await openDownloads(server);
    await userEvent.click(within(row("Home qBittorrent")).getByRole("button", { name: "Move Home qBittorrent down" }));
    expect(await within(clientsCard()).findByText("Home qBittorrent is now 2 of 2 qBittorrent clients.")).toBeTruthy();
    expect(server.called("POST", /move$/)[0]!.body).toEqual({ version: "2026-11-22T10:00:00.000000Z", neighbour: "2", direction: "down" });
    const names = within(clientsCard()).getAllByRole("heading", { level: 5 }).map((heading) => heading.textContent);
    expect(names).toEqual(["Seedbox qBittorrent", "Home qBittorrent", "SABnzbd"]);
    await waitFor(() => expect(document.activeElement?.getAttribute("aria-label")).toBe("Move Home qBittorrent up"));
  });

  test("removing a client asks twice, names its routing rules and sends the version", async () => {
    const after = downloadsFixture({ clients: [downloadsFixture().clients[0]!, downloadsFixture().clients[2]!], rules: [] });
    const server = adminServer().on("DELETE", /clients\/2$/, () => action(after, "Download client “Seedbox qBittorrent” removed with its routing rule."));
    await openDownloads(server);
    const user = userEvent.setup();
    const seedbox = row("Seedbox qBittorrent");
    await user.click(within(seedbox).getByRole("button", { name: "Edit" }));
    await user.click(within(seedbox).getByRole("button", { name: "Remove client" }));
    expect(within(seedbox).getByRole("group", { name: "Remove Seedbox qBittorrent? Its routing rule is removed too." })).toBeTruthy();
    expect(server.called("DELETE", /clients/)).toHaveLength(0);
    await user.click(within(seedbox).getByRole("button", { name: "Remove" }));
    expect(await within(clientsCard()).findByText("Download client “Seedbox qBittorrent” removed with its routing rule.")).toBeTruthy();
    expect(server.called("DELETE", /clients\/2$/)[0]!.body).toEqual({ version: "2026-11-22T10:00:00.000000Z", rules: ["5"] });
    expect(screen.queryByRole("listitem", { name: "Seedbox qBittorrent" })).toBeNull();
    expect(within(rulesCard()).getByText("No routing rules. Every download goes to the clients in priority order.")).toBeTruthy();
    await waitFor(() => expect(document.activeElement?.id).toBe("download_clients"));
  });

  test("adding a client shows the fields its type needs and focuses the new row", async () => {
    const added = downloadsFixture();
    added.clients = [...added.clients, client({ id: "9", name: "Living room", client_type: "deluge", url: "http://deluge.test:8112", priority: 0, password_saved: true, api_key_saved: false })];
    const server = adminServer().on("POST", /\/admin\/downloads\/clients$/, () => ({ status: 201, ...action(added, "Download client “Living room” added.", { created: "9" }) }));
    await openDownloads(server);
    const user = userEvent.setup();
    await user.click(within(clientsCard()).getByRole("button", { name: "Add a download client" }));
    const form = within(clientsCard()).getByRole("form", { name: "New download client" });
    expect(within(form).getByLabelText("API key")).toBeTruthy();
    await user.selectOptions(within(form).getByLabelText("Type"), "deluge");
    expect(within(form).queryByLabelText("API key")).toBeNull();
    expect(within(form).queryByText("Advanced")).toBeNull();
    await user.type(within(form).getByLabelText("Name"), "Living room");
    await user.type(within(form).getByLabelText("Address"), "http://deluge.test:8112");
    await user.type(within(form).getByLabelText("Password"), "deluge-pw");
    await user.click(within(form).getByRole("button", { name: "Add client" }));
    expect(await within(clientsCard()).findByText("Download client “Living room” added.")).toBeTruthy();
    expect(server.called("POST", /clients$/)[0]!.body).toEqual({
      client: { name: "Living room", client_type: "deluge", url: "http://deluge.test:8112", username: "", password: "deluge-pw", category: "", download_path: "", enabled: true },
    });
    await waitFor(() => expect(document.activeElement?.textContent).toBe("Living room"));
  });

  test("routing rules offer only clients of the chosen kind, warn when the client is off, and save", async () => {
    const offRule = downloadsFixture({ rules: [rule({ client_enabled: false })] });
    const created = downloadsFixture({ rules: [rule(), rule({ id: "6", provider: "newznab", provider_label: "NZBHydra2 / Newznab", indexer_name: "Hydra", download_type: "usenet", client_id: "3", client_name: "SABnzbd", client_kind: "usenet" })] });
    const server = adminServer(offRule).on("POST", /\/admin\/downloads\/rules$/, () => ({ status: 201, ...action(created, "Routing rule for “Hydra” added.", { created: "6" }) }));
    await openDownloads(server);
    expect(within(row("MyAnonaMouse")).getByText("That client is turned off, so this rule is skipped.")).toBeTruthy();
    const user = userEvent.setup();
    await user.click(within(rulesCard()).getByRole("button", { name: "Add a routing rule" }));
    const form = within(rulesCard()).getByRole("form", { name: "New routing rule" });
    const target = within(form).getByLabelText("Send to") as HTMLSelectElement;
    expect([...target.options].map((option) => option.textContent)).toEqual(["Choose a client", "Home qBittorrent", "Seedbox qBittorrent"]);
    await user.selectOptions(target, "2");
    await user.click(within(form).getByRole("radio", { name: "Usenet" }));
    expect([...target.options].map((option) => option.textContent)).toEqual(["Choose a client", "SABnzbd"]);
    expect(target.value).toBe("");
    await user.selectOptions(target, "3");
    await user.click(within(form).getByRole("radio", { name: "NZBHydra2 / Newznab" }));
    await user.type(within(form).getByLabelText("Indexer"), "Hydra");
    await user.click(within(form).getByRole("button", { name: "Add rule" }));
    expect(await within(rulesCard()).findByText("Routing rule for “Hydra” added.")).toBeTruthy();
    expect(server.called("POST", /rules$/)[0]!.body).toEqual({ rule: { provider: "newznab", download_type: "usenet", indexer_name: "Hydra", download_client_id: "3", enabled: true } });
  });

  test("editing and removing a rule send its version, and a refused rule names the field", async () => {
    const server = adminServer()
      .on("PUT", /rules\/5$/, () => ({ status: 422, body: { account: ACCOUNT, error: "invalid_record", errors: [{ field: "normalized_indexer_name", message: "Normalized indexer name has already been taken" }] } }))
      .on("DELETE", /rules\/5$/, () => action(downloadsFixture({ rules: [] }), "Routing rule for “MyAnonaMouse” removed."));
    await openDownloads(server);
    const user = userEvent.setup();
    const myAnon = row("MyAnonaMouse");
    await user.click(within(myAnon).getByRole("button", { name: "Edit" }));
    await user.click(within(myAnon).getByLabelText("Use this rule"));
    await user.click(within(myAnon).getByRole("button", { name: "Save" }));
    expect(await within(myAnon).findByText("Normalized indexer name has already been taken")).toBeTruthy();
    expect(server.called("PUT", /rules\/5$/)[0]!.body).toEqual({ version: "2026-11-22T10:00:00.000000Z", rule: { enabled: false } });
    await user.click(within(myAnon).getByRole("button", { name: "Remove rule" }));
    await user.click(within(myAnon).getByRole("button", { name: "Remove" }));
    expect(await within(rulesCard()).findByText("Routing rule for “MyAnonaMouse” removed.")).toBeTruthy();
    expect(server.called("DELETE", /rules\/5$/)[0]!.body).toEqual({ version: "2026-11-22T10:00:00.000000Z" });
    await waitFor(() => expect(document.activeElement?.id).toBe("routing_rules"));
  });

  test("leaving with an unsaved client edit asks first", async () => {
    const { router } = await openDownloads(adminServer());
    const user = userEvent.setup();
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Edit" }));
    await user.type(within(row("Home qBittorrent")).getByLabelText("Category"), "books");
    await user.click(within(screen.getByRole("navigation", { name: "Server" })).getByRole("link", { name: "System" }));
    expect(await screen.findByRole("heading", { name: "Leave without saving?" })).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Stay and keep editing" }));
    expect(router.state.location.pathname).toBe("/server/downloads");
    expect((within(row("Home qBittorrent")).getByLabelText("Category") as HTMLInputElement).value).toBe("books");
  });

  test("a write that finds the account changed locks the page and shows nothing of the old account", async () => {
    const server = adminServer().on("POST", /clients\/1\/test$/, () => ({ status: 401, body: { error: "account_changed" } }));
    await openDownloads(server);
    await userEvent.click(within(row("Home qBittorrent")).getByRole("button", { name: "Test" }));
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    expect(screen.queryByText("Home qBittorrent")).toBeNull();
  });

  test("an administrator who loses the role sees the administrators-only page and no client data", async () => {
    const refused = () => ({ status: 404, body: { error: "not_found" } });
    const server = adminServer().on("GET", /\/api\/v1\/admin\/downloads$/, refused).on("GET", /\/api\/v1\/admin\/settings$/, refused);
    renderApp({ server, url: "/sub/preview/server/downloads" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(screen.queryByText("Home qBittorrent")).toBeNull();
  });

  test("an administrator whose role is revoked while the page is open stops seeing client data", async () => {
    const refused = () => ({ status: 404, body: { error: "not_found" } });
    const server = adminServer();
    await openDownloads(server);
    server.on("GET", /\/api\/v1\/admin\/downloads$/, refused).on("GET", /\/api\/v1\/admin\/settings$/, refused).on("POST", /clients\/1\/test$/, refused);
    await userEvent.click(within(row("Home qBittorrent")).getByRole("button", { name: "Test" }));
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(screen.queryByText("Home qBittorrent")).toBeNull();
    expect(screen.queryByText("http://qbit.test:8080")).toBeNull();
  });

  test("a rule whose client now takes another kind of download says it is skipped", async () => {
    await openDownloads(adminServer(downloadsFixture({ rules: [rule({ client_id: "3", client_name: "SABnzbd", client_kind: "usenet" })] })));
    expect(within(row("MyAnonaMouse")).getByText("That client now takes usenet downloads, so this rule is skipped.")).toBeTruthy();
    await userEvent.click(within(row("MyAnonaMouse")).getByRole("button", { name: "Edit" }));
    expect((within(row("MyAnonaMouse")).getByLabelText("Send to") as HTMLSelectElement).selectedOptions[0]!.textContent).toBe("SABnzbd (takes usenet downloads)");
  });

  test("changing a client with rules to the other kind warns that its rules will be skipped", async () => {
    await openDownloads(adminServer());
    const user = userEvent.setup();
    const seedbox = row("Seedbox qBittorrent");
    await user.click(within(seedbox).getByRole("button", { name: "Edit" }));
    await user.selectOptions(within(seedbox).getByLabelText("Type"), "nzbget");
    expect(within(seedbox).getByText(/has a routing rule for torrent downloads, which is skipped once it is a usenet client/)).toBeTruthy();
  });

  test("an editor with unsaved changes is not closed by its Edit button", async () => {
    await openDownloads(adminServer());
    const user = userEvent.setup();
    const home = row("Home qBittorrent");
    await user.click(within(home).getByRole("button", { name: "Edit" }));
    await user.type(within(home).getByLabelText("Category"), "books");
    await user.click(within(home).getByRole("button", { name: "Edit" }));
    expect(within(clientsCard()).getByText("Save or discard the changes to Home qBittorrent before closing it.")).toBeTruthy();
    expect((within(home).getByLabelText("Category") as HTMLInputElement).value).toBe("books");
  });

  test("fields are locked while a save is on its way, so nothing typed meanwhile is lost", async () => {
    const gate = deferred<void>();
    const server = adminServer().on("PUT", /clients\/1$/, async () => {
      await gate.promise;
      return action(downloadsFixture({ clients: [client({ category: "books", version: "v2" }), ...downloadsFixture().clients.slice(1)] }), "Download client “Home qBittorrent” saved.");
    });
    await openDownloads(server);
    const user = userEvent.setup();
    const home = row("Home qBittorrent");
    await user.click(within(home).getByRole("button", { name: "Edit" }));
    await user.type(within(home).getByLabelText("Category"), "books");
    await user.click(within(home).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(within(home).getByLabelText("Category").closest("fieldset")!.disabled).toBe(true));
    await user.click(within(home).getByRole("button", { name: "Saving…" }));
    gate.resolve();
    expect(await within(clientsCard()).findByText("Download client “Home qBittorrent” saved.")).toBeTruthy();
    expect(server.called("PUT", /clients\/1$/)).toHaveLength(1);
  });

  test("a slow answer from an earlier action does not bring back a removed rule", async () => {
    const gate = deferred<void>();
    const before = downloadsFixture();
    const server = adminServer(before)
      .on("POST", /clients\/1\/test$/, async () => {
        await gate.promise;
        return { body: { ...before, outcome: { tone: "success", message: "Connection to 'Home qBittorrent' successful!" }, tested: "1" } };
      })
      .on("DELETE", /rules\/5$/, () => action(downloadsFixture({ rules: [] }), "Routing rule for “MyAnonaMouse” removed."));
    await openDownloads(server);
    const user = userEvent.setup();
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Test" }));
    const myAnon = row("MyAnonaMouse");
    await user.click(within(myAnon).getByRole("button", { name: "Edit" }));
    await user.click(within(myAnon).getByRole("button", { name: "Remove rule" }));
    await user.click(within(myAnon).getByRole("button", { name: "Remove" }));
    await within(rulesCard()).findByText("Routing rule for “MyAnonaMouse” removed.");
    gate.resolve();
    await within(row("Home qBittorrent")).findByText(/successful/);
    await waitFor(() => expect(screen.queryByRole("listitem", { name: "MyAnonaMouse" })).toBeNull());
  });

  test("a denied list read hides the cached health too and asks the server again who is signed in", async () => {
    const refused = () => ({ status: 404, body: { error: "not_found" } });
    const server = adminServer().on("POST", /clients\/1\/test$/, () => ({ body: { ...current, outcome: { tone: "success", message: "Connection to 'Home qBittorrent' successful!" }, tested: "1" } }));
    await openDownloads(server);
    expect(within(clientsCard()).getByText("Degraded")).toBeTruthy();
    const sessionReads = server.called("GET", /\/api\/v1\/session$/).length;
    server.on("GET", /\/api\/v1\/admin\/downloads$/, refused);
    await userEvent.click(within(row("Home qBittorrent")).getByRole("button", { name: "Test" }));
    await waitFor(() => expect(screen.queryByText("Degraded")).toBeNull());
    expect(screen.queryByText("Home qBittorrent")).toBeNull();
    await waitFor(() => expect(server.called("GET", /\/api\/v1\/session$/).length).toBeGreaterThan(sessionReads));
  });

  test("an open draft survives another administrator changing the client to the other kind", async () => {
    await openDownloads(adminServer());
    const user = userEvent.setup();
    const seedbox = row("Seedbox qBittorrent");
    await user.click(within(seedbox).getByRole("button", { name: "Edit" }));
    await user.type(within(seedbox).getByLabelText("Category"), "mine");
    const fixture = downloadsFixture();
    current = { ...fixture, clients: [fixture.clients[0]!, fixture.clients[2]!, { ...fixture.clients[1]!, client_type: "nzbget", kind: "usenet", version: "v9" }] };
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Test" }));
    await waitFor(() => expect(within(row("Seedbox qBittorrent")).getByText("Usenet")).toBeTruthy());
    expect((within(row("Seedbox qBittorrent")).getByLabelText("Category") as HTMLInputElement).value).toBe("mine");
  });

  test("a move refused because of a priority tie says so and moves nothing", async () => {
    const server = adminServer().on("POST", /clients\/1\/move$/, () =>
      action(current, "“Home qBittorrent” has the same priority as the client below it, so the order between them cannot be changed. Nothing was moved.", { moved: false }, "error"),
    );
    await openDownloads(server);
    await userEvent.click(within(row("Home qBittorrent")).getByRole("button", { name: "Move Home qBittorrent down" }));
    expect(await within(clientsCard()).findByText(/has the same priority as the client below it/)).toBeTruthy();
    expect(within(clientsCard()).getAllByRole("heading", { level: 5 }).map((heading) => heading.textContent)).toEqual(["Home qBittorrent", "Seedbox qBittorrent", "SABnzbd"]);
  });

  test("a denied list read also hides earlier announcements about clients", async () => {
    const refused = () => ({ status: 404, body: { error: "not_found" } });
    const server = adminServer().on("POST", /clients\/1\/test$/, () => action(current, "Connection to 'Home qBittorrent' successful!", { tested: "1" }));
    const moved = downloadsFixture();
    moved.clients = [moved.clients[1]!, moved.clients[0]!, moved.clients[2]!];
    server.on("POST", /clients\/2\/move$/, () => action(moved, "moved", { moved: true }));
    await openDownloads(server);
    await userEvent.click(within(row("Seedbox qBittorrent")).getByRole("button", { name: "Move Seedbox qBittorrent up" }));
    expect(await within(clientsCard()).findByText("Seedbox qBittorrent is now 1 of 2 qBittorrent clients.")).toBeTruthy();
    server.on("GET", /\/api\/v1\/admin\/downloads$/, refused);
    await userEvent.click(within(row("Home qBittorrent")).getByRole("button", { name: "Test" }));
    await waitFor(() => expect(screen.queryByText("Seedbox qBittorrent is now 1 of 2 qBittorrent clients.")).toBeNull());
    expect(screen.queryByText(/Seedbox qBittorrent/)).toBeNull();
  });

  test("removal sends the rules shown when the editor opened, even if the list changes before confirming", async () => {
    const server = adminServer().on("DELETE", /clients\/2$/, () => ({ status: 409, body: { ...current, error: "download_changed" } }));
    await openDownloads(server);
    const user = userEvent.setup();
    const seedbox = row("Seedbox qBittorrent");
    await user.click(within(seedbox).getByRole("button", { name: "Edit" }));
    const fixture = downloadsFixture();
    current = { ...fixture, clients: fixture.clients.map((entry) => (entry.id === "2" ? { ...entry, rule_ids: ["6"] } : entry)) };
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Test" }));
    await user.click(within(row("Seedbox qBittorrent")).getByRole("button", { name: "Remove client" }));
    await user.click(within(row("Seedbox qBittorrent")).getByRole("button", { name: "Remove" }));
    expect(await within(row("Seedbox qBittorrent")).findByText(/Nothing was removed/)).toBeTruthy();
    await user.click(within(row("Seedbox qBittorrent")).getByRole("button", { name: "Remove" }));
    await waitFor(() => expect(server.called("DELETE", /clients\/2$/)).toHaveLength(2));
    expect(server.called("DELETE", /clients\/2$/).map((request) => request.body)).toEqual([
      { version: "2026-11-22T10:00:00.000000Z", rules: ["5"] },
      { version: "2026-11-22T10:00:00.000000Z", rules: ["5"] },
    ]);
  });

  test("after a conflict whose refresh fails, the next save still carries the version the form shows", async () => {
    const changed = downloadsFixture({ clients: [client({ version: "v2", client_type: "sabnzbd", kind: "usenet" }), ...downloadsFixture().clients.slice(1)] });
    const server = adminServer().on("PUT", /clients\/1$/, () => ({ status: 409, body: { ...changed, error: "download_changed" } }));
    await openDownloads(server);
    server.on("GET", /\/api\/v1\/admin\/downloads$/, () => ({ status: 500, body: { error: "server" } }));
    const user = userEvent.setup();
    const home = row("Home qBittorrent");
    await user.click(within(home).getByRole("button", { name: "Edit" }));
    await user.type(within(home).getByLabelText("Category"), "x");
    await user.click(within(home).getByRole("button", { name: "Save" }));
    await within(home).findByText(/changed somewhere else/, {}, { timeout: 8000 });
    await user.click(within(home).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(server.called("PUT", /clients\/1$/)).toHaveLength(2));
    expect(server.called("PUT", /clients\/1$/).map((request) => (request.body as { version: string }).version)).toEqual(["2026-11-22T10:00:00.000000Z", "2026-11-22T10:00:00.000000Z"]);
  }, 20_000);

  test("edits a type change makes irrelevant stay unsaved and say so, and a removed client's draft is reported", async () => {
    await openDownloads(adminServer());
    const user = userEvent.setup();
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Edit" }));
    await user.type(within(row("Home qBittorrent")).getByLabelText("Username"), "2");
    await user.selectOptions(within(row("Home qBittorrent")).getByLabelText("Type"), "sabnzbd");
    expect(within(row("Home qBittorrent")).getByText(/Your changes to Username are not used by SABnzbd clients and will not be saved/)).toBeTruthy();
    expect(within(row("Home qBittorrent")).getByText("Unsaved changes")).toBeTruthy();

    await user.click(within(row("Seedbox qBittorrent")).getByRole("button", { name: "Edit" }));
    await user.type(within(row("Seedbox qBittorrent")).getByLabelText("Category"), "mine");
    const fixture = downloadsFixture();
    current = { ...fixture, clients: fixture.clients.filter((entry) => entry.id !== "2"), rules: [] };
    await user.click(within(row("SABnzbd")).getByRole("button", { name: "Test" }));
    expect(await within(clientsCard()).findByText("Seedbox qBittorrent was removed somewhere else, so your unsaved changes to it were discarded.")).toBeTruthy();
  });

  test("a refused removal keeps the draft, and Save with only edits the type does not use sends nothing", async () => {
    const server = adminServer().on("DELETE", /clients\/1$/, () => ({ status: 409, body: { ...current, error: "download_changed" } }));
    await openDownloads(server);
    const user = userEvent.setup();
    const home = row("Home qBittorrent");
    await user.click(within(home).getByRole("button", { name: "Edit" }));
    await user.type(within(home).getByLabelText("Category"), "kept");
    await user.click(within(home).getByRole("button", { name: "Remove client" }));
    await user.click(within(within(home).getByRole("group", { name: "Remove Home qBittorrent?" })).getByRole("button", { name: "Remove" }));
    expect(await within(home).findByText(/Nothing was removed/)).toBeTruthy();
    expect((within(home).getByLabelText("Category") as HTMLInputElement).value).toBe("kept");
    expect(within(clientsCard()).queryByText(/were discarded/)).toBeNull();

    await user.clear(within(home).getByLabelText("Category"));
    await user.type(within(home).getByLabelText("Username"), "2");
    await user.selectOptions(within(home).getByLabelText("Type"), "sabnzbd");
    await user.selectOptions(within(home).getByLabelText("Type"), "qbittorrent");
    await user.selectOptions(within(home).getByLabelText("Type"), "sabnzbd");
    const fixture = downloadsFixture();
    current = { ...fixture, clients: fixture.clients.map((entry) => (entry.id === "1" ? { ...entry, client_type: "sabnzbd", kind: "usenet" as const } : entry)) };
    await user.click(within(row("SABnzbd")).getByRole("button", { name: "Test" }));
    await waitFor(() => expect(within(row("Home qBittorrent")).getByText("Usenet")).toBeTruthy());
    await user.selectOptions(within(row("Home qBittorrent")).getByLabelText("Type"), "sabnzbd");
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Save" }));
    expect(await within(row("Home qBittorrent")).findByText("There is nothing to save: your changes are only to fields this type does not use.")).toBeTruthy();
    expect(server.called("PUT", /clients\/1$/)).toHaveLength(0);
  });

  test("a move from an out-of-date list is refused and says so", async () => {
    const server = adminServer().on("POST", /clients\/1\/move$/, () => ({ status: 409, body: { ...current, error: "download_changed" } }));
    await openDownloads(server);
    await userEvent.click(within(row("Home qBittorrent")).getByRole("button", { name: "Move Home qBittorrent down" }));
    expect(await within(clientsCard()).findByText("Home qBittorrent or the client next to it was changed somewhere else, so nothing was moved. Check the order shown, then move it again.")).toBeTruthy();
  });

  test("a very large stored verification value still shows the lists", async () => {
    const fixture = downloadsFixture();
    await openDownloads(adminServer({ ...fixture, clients: fixture.clients.map((entry) => (entry.id === "1" ? { ...entry, torrent_verification_wait_time: 9007199254740993 } : entry)) }));
    expect(within(rulesCard()).getByText("MyAnonaMouse")).toBeTruthy();
  });

  test("a refused rule removal keeps the version and rules it was confirmed with", async () => {
    let deletes = 0;
    const server = adminServer().on("DELETE", /rules\/5$/, () => {
      deletes += 1;
      return { status: 409, body: { ...current, error: "download_changed" } };
    });
    await openDownloads(server);
    const user = userEvent.setup();
    const myAnon = row("MyAnonaMouse");
    await user.click(within(myAnon).getByRole("button", { name: "Edit" }));
    const fixture = downloadsFixture();
    current = { ...fixture, rules: [rule({ version: "v7", client_id: "1", client_name: "Home qBittorrent" })] };
    await user.click(within(myAnon).getByRole("button", { name: "Remove rule" }));
    await user.click(within(myAnon).getByRole("button", { name: "Remove" }));
    expect(await within(row("MyAnonaMouse")).findByText(/Nothing was removed/)).toBeTruthy();
    await user.click(within(row("MyAnonaMouse")).getByRole("button", { name: "Remove" }));
    await waitFor(() => expect(deletes).toBe(2));
    expect(server.called("DELETE", /rules\/5$/).map((request) => request.body)).toEqual([{ version: "2026-11-22T10:00:00.000000Z" }, { version: "2026-11-22T10:00:00.000000Z" }]);
  });

  test("a removal keeps the version it was confirmed with, even after a refused save adopts a newer one", async () => {
    const changed = downloadsFixture({ clients: [client({ version: "v2", category: "elsewhere" }), ...downloadsFixture().clients.slice(1)] });
    const server = adminServer()
      .on("DELETE", /clients\/1$/, () => ({ status: 409, body: { ...current, error: "download_changed" } }))
      .on("PUT", /clients\/1$/, () => {
        current = changed;
        return { status: 409, body: { ...changed, error: "download_changed" } };
      });
    await openDownloads(server);
    const user = userEvent.setup();
    const home = row("Home qBittorrent");
    await user.click(within(home).getByRole("button", { name: "Edit" }));
    await user.click(within(home).getByRole("button", { name: "Remove client" }));
    const confirm = () => within(within(row("Home qBittorrent")).getByRole("group", { name: "Remove Home qBittorrent?" })).getByRole("button", { name: "Remove" });
    await user.click(confirm());
    await within(row("Home qBittorrent")).findByText(/Nothing was removed/);
    await user.type(within(row("Home qBittorrent")).getByLabelText("Download folder"), "/mine");
    await user.click(within(row("Home qBittorrent")).getByRole("button", { name: "Save" }));
    await waitFor(() => expect((within(row("Home qBittorrent")).getByLabelText("Category") as HTMLInputElement).value).toBe("elsewhere"));
    await user.click(confirm());
    await waitFor(() => expect(server.called("DELETE", /clients\/1$/)).toHaveLength(2));
    expect(server.called("DELETE", /clients\/1$/).map((request) => (request.body as { version: string }).version)).toEqual(["2026-11-22T10:00:00.000000Z", "2026-11-22T10:00:00.000000Z"]);
  });

  test("Test always uses the saved settings and says so while the editor has unsaved changes", async () => {
    const server = adminServer().on("POST", /clients\/1\/test$/, () => action(current, "Connection to 'Home qBittorrent' successful!", { tested: "1" }));
    await openDownloads(server);
    const user = userEvent.setup();
    const home = row("Home qBittorrent");
    await user.click(within(home).getByRole("button", { name: "Edit" }));
    await user.type(within(home).getByLabelText("Address"), "9");
    await user.click(within(home).getByRole("button", { name: "Test" }));
    expect(await within(home).findByText(/This tested the saved settings, not your unsaved changes\./)).toBeTruthy();
    expect(server.called("POST", /clients\/1\/test$/)[0]!.body).toEqual({});
  });
});
