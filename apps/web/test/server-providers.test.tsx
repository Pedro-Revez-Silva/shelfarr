import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ServerSettings } from "../src/server/contract";
import { providersSchema, type AcquisitionProvider, type Providers } from "../src/server/providers/contract";
import { initialProviderDraft, providerSubmission } from "../src/server/providers/forms";
import { ACCOUNT, FakeServer, renderApp, session, standardServer } from "./helpers";

afterEach(cleanup);

const ADMIN = { admin: { url: "/sub/admin" }, capabilities: { administrator: true, can_upload: true, single_sign_on: false, hardcover_personal_access: false } };
const VERSION = "2026-11-23T10:00:00.000000Z";

function provider(overrides: Partial<AcquisitionProvider> = {}): AcquisitionProvider {
  return {
    id: "1",
    version: VERSION,
    name: "Local provider",
    url: "http://provider.test",
    url_hidden: false,
    api_key_saved: true,
    enabled: true,
    allow_private_network: false,
    supports_ebooks: true,
    supports_audiobooks: true,
    supports_comicbooks: false,
    timeout_seconds: 30,
    priority: 0,
    position: 1,
    ...overrides,
  };
}

const COMICS = provider({ id: "2", name: "Comic shelf", url: "http://comics.test/api", url_hidden: true, api_key_saved: false, enabled: false, allow_private_network: true, supports_ebooks: false, supports_audiobooks: false, supports_comicbooks: true, timeout_seconds: 90, priority: 1, position: 2 });

function providersFixture(overrides: Partial<Providers> = {}): Providers {
  return {
    account: ACCOUNT,
    providers: [provider(), COMICS],
    defaults: { enabled: true, allow_private_network: false, supports_ebooks: true, supports_audiobooks: true, supports_comicbooks: false, timeout_seconds: 30 },
    ...overrides,
  };
}

function settingsFixture(): ServerSettings {
  const empty = (id: ServerSettings["categories"][number]["id"], title: string) => ({ id, title, summary: `${title}.`, groups: [] });
  const group = (id: string, heading: string, title: string) => ({ id, heading, title, summary: `${title}.`, fields: [{ key: `${id}_enabled`, label: "Use it", description: "", input: "toggle" as const, value: true }], advanced: [], probes: [], extras: [], notes: [] });
  return {
    account: ACCOUNT,
    categories: [
      empty("policy", "Request policy"),
      { id: "sources", title: "Catalogues and sources", summary: "Where Shelfarr looks up books and where it finds copies.", groups: [group("open_library", "Catalogues", "Open Library"), group("gutenberg", "File sources", "Project Gutenberg")] },
      empty("downloads", "Downloads"),
      empty("library", "Library and files"),
      empty("notifications", "Notifications"),
      empty("people", "People and access"),
      empty("system", "System"),
    ],
    notes: { path_variables: "", hardcover_app: { create_url: "https://hardcover.app/x", scopes: "read", redirect_uri: "https://shelf.test/cb", redirect_uri_acceptable: true } },
    roles: [],
  };
}

let current: Providers = providersFixture();

function action(next: Providers, message: string, extra: Record<string, string> = {}, tone: "success" | "error" = "success") {
  current = next;
  return { body: { ...next, outcome: { tone, message }, ...extra } };
}

function adminServer(initial: Providers = providersFixture()): FakeServer {
  current = initial;
  return standardServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(ADMIN) }))
    .on("GET", /\/api\/v1\/admin\/settings$/, () => ({ body: settingsFixture() }))
    .on("GET", /\/api\/v1\/admin\/acquisition_providers$/, () => ({ body: current }));
}

function card(): HTMLElement {
  return screen.getByRole("heading", { name: "Custom providers", level: 3 }).closest("section")!;
}

function row(name: string): HTMLElement {
  return screen.getByRole("listitem", { name }) as HTMLElement;
}

async function openSources(server: FakeServer, hash = "") {
  const rendered = renderApp({ server, url: `/sub/preview/server/sources${hash}` });
  await screen.findByRole("heading", { name: "Local provider", level: 5 });
  return rendered;
}

describe("custom provider drafts", () => {
  const data = providersFixture();
  const local = data.providers[0]!;

  test("a new provider sends every field with the book types as three switches and no blank token", () => {
    const initial = initialProviderDraft(null, data.defaults);
    expect(initial.media).toEqual(["ebooks", "audiobooks"]);
    expect(providerSubmission(null, { ...initial, name: "Home", url: "http://home.test" }, initial)).toEqual({
      name: "Home",
      url: "http://home.test",
      allow_private_network: false,
      enabled: true,
      timeout_seconds: "30",
      supports_ebooks: true,
      supports_audiobooks: true,
      supports_comicbooks: false,
    });
    expect(providerSubmission(null, { ...initial, api_key: "typed-token" }, initial).api_key).toBe("typed-token");
  });

  test("an edit sends only what changed, never a blank token, and all three book types when they change", () => {
    const initial = initialProviderDraft(local, data.defaults);
    expect(providerSubmission(local, { ...initial, name: "Local", api_key: "   " }, initial)).toEqual({ name: "Local" });
    expect(providerSubmission(local, { ...initial, api_key: "new-token", media: ["comicbooks"] }, initial)).toEqual({ api_key: "new-token", supports_ebooks: false, supports_audiobooks: false, supports_comicbooks: true });
    expect(providerSubmission(local, { ...initial, timeout_seconds: "12", enabled: false }, initial)).toEqual({ enabled: false, timeout_seconds: "12" });
    expect(providerSubmission(local, initial, initial)).toEqual({});
  });

  test("the fixture matches the providers contract", () => {
    expect(providersSchema.safeParse(providersFixture()).success).toBe(true);
  });
});

describe("Server ▸ Catalogues and sources ▸ Custom providers in the Rails preview", () => {
  test("a member sees the administrators-only page and no provider data is asked for", async () => {
    const server = standardServer();
    renderApp({ server, url: "/sub/preview/server/sources" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(server.requests.filter((request) => request.path.includes("/admin/"))).toEqual([]);
  });

  test("providers are listed in priority order under File sources with their facts and the token only as Saved", async () => {
    await openSources(adminServer());
    const index = screen.getByRole("navigation", { name: "Catalogues and sources cards" });
    expect(within(index).getAllByRole("link").map((link) => link.getAttribute("href"))).toEqual(["#open_library", "#gutenberg", "#acquisition_providers"]);
    expect(within(screen.getByRole("group", { name: "File sources" })).getByRole("heading", { name: "Custom providers", level: 3 })).toBeTruthy();
    expect(within(card()).getAllByRole("heading", { level: 5 }).map((heading) => heading.textContent)).toEqual(["Local provider", "Comic shelf"]);
    const local = row("Local provider");
    expect([...local.querySelectorAll(".record-facts > *")].map((fact) => fact.textContent)).toEqual(["Ebooks", "Audiobooks", "Priority 1", "Timeout 30 s", "Bearer token saved"]);
    expect([...row("Comic shelf").querySelectorAll(".record-facts > *")].map((fact) => fact.textContent)).toEqual(["Comics & Manga", "Turned off", "Private network allowed", "Priority 2", "Timeout 90 s"]);
    expect(within(row("Comic shelf")).getByText("http://comics.test/api")).toBeTruthy();

    await userEvent.click(within(local).getByRole("button", { name: "Edit" }));
    const form = within(local).getByRole("form", { name: "Local provider" });
    expect(within(form).getByText("Saved")).toBeTruthy();
    expect(within(form).queryByLabelText("Bearer token")).toBeNull();
    expect(within(form).queryByRole("button", { name: "Remove" })).toBeNull();
    expect((within(form).getByLabelText("Ebooks") as HTMLInputElement).checked).toBe(true);
    expect((within(form).getByLabelText("Comics & Manga") as HTMLInputElement).checked).toBe(false);
    expect((within(form).getByLabelText("Address") as HTMLInputElement).value).toBe("http://provider.test");

    await userEvent.click(within(row("Comic shelf")).getByRole("button", { name: "Edit" }));
    expect(within(row("Comic shelf")).getByText("The saved address has parts that are not shown. Leave the address unchanged to keep them.")).toBeTruthy();
  });

  test("adding a provider sends the form, confirms and focuses the new row", async () => {
    const added = providersFixture({ providers: [provider(), COMICS, provider({ id: "9", name: "Home provider", url: "http://home.test:4567", api_key_saved: true, priority: 2, position: 3 })] });
    const server = adminServer().on("POST", /\/admin\/acquisition_providers$/, () => ({ status: 201, ...action(added, "Provider “Home provider” added.", { created: "9" }) }));
    await openSources(server);
    const user = userEvent.setup();
    await user.click(within(card()).getByRole("button", { name: "Add a provider" }));
    const form = within(card()).getByRole("form", { name: "New custom provider" });
    await user.type(within(form).getByLabelText("Name"), "Home provider");
    await user.type(within(form).getByLabelText("Address"), "http://home.test:4567");
    await user.type(within(form).getByLabelText("Bearer token"), "home-token-1");
    await user.click(within(form).getByLabelText("Audiobooks"));
    await user.click(within(form).getByLabelText("Comics & Manga"));
    await user.click(within(form).getByLabelText("Allow private network"));
    await user.click(within(form).getByRole("button", { name: "Add provider" }));
    expect(await within(card()).findByText("Provider “Home provider” added.")).toBeTruthy();
    const sent = server.called("POST", /acquisition_providers$/)[0]!;
    expect(sent.body).toEqual({
      provider: { name: "Home provider", url: "http://home.test:4567", api_key: "home-token-1", allow_private_network: true, enabled: true, timeout_seconds: "30", supports_ebooks: true, supports_audiobooks: false, supports_comicbooks: true },
    });
    expect(sent.headers["x-csrf-token"]).toBe("token-123");
    expect(sent.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    await waitFor(() => expect(document.activeElement?.textContent).toBe("Home provider"));
  });

  test("a refused provider marks its fields and shows the book type rule, keeping what was typed", async () => {
    const server = adminServer().on("POST", /acquisition_providers$/, () => ({
      status: 422,
      body: {
        account: ACCOUNT,
        error: "invalid_record",
        errors: [
          { field: "url", message: "Address points to a private network address. Enable \"Allow private network\" if this provider runs on your local network." },
          { field: "timeout_seconds", message: "Timeout must be less than or equal to 120" },
          { field: "base", message: "Provider must support ebooks, audiobooks, or Comics & Manga" },
        ],
      },
    }));
    await openSources(server);
    const user = userEvent.setup();
    await user.click(within(card()).getByRole("button", { name: "Add a provider" }));
    const form = within(card()).getByRole("form", { name: "New custom provider" });
    await user.type(within(form).getByLabelText("Name"), "Lan");
    const address = within(form).getByLabelText("Address");
    await user.type(address, "http://192.168.1.5");
    await user.click(within(form).getByRole("button", { name: "Add provider" }));
    expect(await within(form).findByText(/points to a private network address/)).toBeTruthy();
    expect(within(form).getByRole("alert").textContent).toContain("Provider must support ebooks, audiobooks, or Comics & Manga");
    expect(address.getAttribute("aria-invalid")).toBe("true");
    expect(within(form).getByText("Timeout must be less than or equal to 120")).toBeTruthy();
    expect(form.querySelector("details")?.open).toBe(true);
    await waitFor(() => expect(document.activeElement).toBe(address));
    expect((address as HTMLInputElement).value).toBe("http://192.168.1.5");
  });

  test("an edit sends only the changed fields with its version, and an out-of-date copy keeps the edits", async () => {
    let attempts = 0;
    const changed = providersFixture({ providers: [provider({ version: "v2", timeout_seconds: 45 }), COMICS] });
    const server = adminServer().on("PUT", /acquisition_providers\/1$/, () => {
      attempts += 1;
      current = changed;
      return attempts === 1 ? { status: 409, body: { ...changed, error: "provider_changed" } } : action(changed, "Provider “Local” saved.");
    });
    await openSources(server);
    const user = userEvent.setup();
    const local = row("Local provider");
    await user.click(within(local).getByRole("button", { name: "Edit" }));
    const name = within(local).getByLabelText("Name");
    await user.clear(name);
    await user.type(name, "Local");
    await user.click(within(local).getByLabelText("Use this provider"));
    expect(within(local).getByText("Unsaved changes")).toBeTruthy();
    await user.click(within(local).getByRole("button", { name: "Save" }));
    expect(await within(local).findByRole("alert")).toBeTruthy();
    expect(within(local).getByRole("alert").textContent).toContain("changed somewhere else");
    expect((within(local).getByLabelText("Name") as HTMLInputElement).value).toBe("Local");
    await user.click(within(local).getByRole("button", { name: "Save" }));
    await within(card()).findByText("Provider “Local” saved.");
    expect(server.called("PUT", /acquisition_providers\/1$/).map((request) => request.body)).toEqual([
      { version: VERSION, provider: { name: "Local", enabled: false } },
      { version: "v2", provider: { name: "Local", enabled: false } },
    ]);
  });

  test("Test answers inside the row with the time and says when it did not use unsaved changes", async () => {
    const server = adminServer().on("POST", /acquisition_providers\/1\/test$/, () => action(providersFixture(), "Connection to “Local provider” failed: Connection refused.", { tested: "1" }, "error"));
    await openSources(server);
    const user = userEvent.setup();
    const local = row("Local provider");
    await user.click(within(local).getByRole("button", { name: "Edit" }));
    await user.type(within(local).getByLabelText("Address"), "/v2");
    await user.click(within(local).getByRole("button", { name: "Test" }));
    expect(await within(local).findByText(/Connection to “Local provider” failed: Connection refused\./)).toBeTruthy();
    expect(within(local).getByText("This tested the saved settings, not your unsaved changes.")).toBeTruthy();
    expect(local.querySelector(".record-status time")).toBeTruthy();
    const sent = server.called("POST", /test$/)[0]!;
    expect(sent.body).toEqual({});
    expect(sent.headers["x-csrf-token"]).toBe("token-123");
  });

  test("removing a provider asks twice, names the consequence and sends the version", async () => {
    const server = adminServer().on("DELETE", /acquisition_providers\/2$/, () => action(providersFixture({ providers: [provider()] }), "Provider “Comic shelf” removed."));
    await openSources(server);
    const user = userEvent.setup();
    const comics = row("Comic shelf");
    await user.click(within(comics).getByRole("button", { name: "Edit" }));
    await user.click(within(comics).getByRole("button", { name: "Remove provider" }));
    expect(within(comics).getByRole("group", { name: "Remove Comic shelf? Copies it already found can no longer be downloaded." })).toBeTruthy();
    expect(server.called("DELETE", /acquisition_providers/)).toHaveLength(0);
    await user.click(within(comics).getByRole("button", { name: "Remove" }));
    expect(await within(card()).findByText("Provider “Comic shelf” removed.")).toBeTruthy();
    expect(server.called("DELETE", /acquisition_providers\/2$/)[0]!.body).toEqual({ version: VERSION });
    expect(screen.queryByRole("listitem", { name: "Comic shelf" })).toBeNull();
    await waitFor(() => expect(document.activeElement?.id).toBe("acquisition_providers"));
  });

  test("a removal of a provider changed since it was opened is refused and says so", async () => {
    const server = adminServer().on("DELETE", /acquisition_providers\/2$/, () => ({ status: 409, body: { ...providersFixture(), error: "provider_changed" } }));
    await openSources(server);
    const user = userEvent.setup();
    const comics = row("Comic shelf");
    await user.click(within(comics).getByRole("button", { name: "Edit" }));
    await user.click(within(comics).getByRole("button", { name: "Remove provider" }));
    await user.click(within(comics).getByRole("button", { name: "Remove" }));
    expect(await within(comics).findByText(/Nothing was removed: this was changed somewhere else/)).toBeTruthy();
    expect(row("Comic shelf")).toBeTruthy();
  });

  test("an old edit address opens that provider's form and an old new address opens the add form", async () => {
    await openSources(adminServer(), "#acquisition-provider-2-edit");
    expect(await within(row("Comic shelf")).findByRole("form", { name: "Comic shelf" })).toBeTruthy();
    expect(within(row("Local provider")).queryByRole("form")).toBeNull();
    cleanup();

    await openSources(adminServer(), "#acquisition_providers-new");
    expect(await within(card()).findByRole("form", { name: "New custom provider" })).toBeTruthy();
    cleanup();

    await openSources(adminServer(), "#acquisition-provider-1");
    await waitFor(() => expect(document.activeElement?.id).toBe("acquisition-provider-1"));
    expect(within(row("Local provider")).queryByRole("form")).toBeNull();
  });

  test("leaving with an unsaved provider edit asks first", async () => {
    const { router } = await openSources(adminServer());
    const user = userEvent.setup();
    await user.click(within(row("Local provider")).getByRole("button", { name: "Edit" }));
    await user.type(within(row("Local provider")).getByLabelText("Name"), " two");
    await user.click(within(screen.getByRole("navigation", { name: "Server" })).getByRole("link", { name: "System" }));
    expect(await screen.findByRole("heading", { name: "Leave without saving?" })).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Stay and keep editing" }));
    expect(router.state.location.pathname).toBe("/server/sources");
  });

  test("an administrator whose role is revoked while the page is open stops seeing provider data", async () => {
    const refused = () => ({ status: 404, body: { error: "not_found" } });
    const server = adminServer();
    await openSources(server);
    server.on("GET", /\/api\/v1\/admin\/acquisition_providers$/, refused).on("GET", /\/api\/v1\/admin\/settings$/, refused).on("POST", /acquisition_providers\/1\/test$/, refused);
    await userEvent.click(within(row("Local provider")).getByRole("button", { name: "Test" }));
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(screen.queryByText("Local provider")).toBeNull();
    expect(screen.queryByText("http://provider.test")).toBeNull();
  });

  test("a write that finds the account changed locks the page and shows nothing of the old account", async () => {
    const server = adminServer().on("POST", /acquisition_providers\/1\/test$/, () => ({ status: 401, body: { error: "account_changed" } }));
    await openSources(server);
    await userEvent.click(within(row("Local provider")).getByRole("button", { name: "Test" }));
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    expect(screen.queryByText("Local provider")).toBeNull();
  });
});
