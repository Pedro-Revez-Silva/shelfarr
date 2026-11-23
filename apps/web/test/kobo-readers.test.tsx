import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { AccountSettings, Profile } from "../src/contract";
import { bookKoboSchema, koboReaderEnvelopeSchema, koboReadersSchema, koboSetupSchema, type KoboDelivery, type KoboReader, type KoboReaderRow } from "../src/devices/kobo/contract";
import { ACCOUNT, detail, renderApp, standardServer, type FakeServer } from "./helpers";

afterEach(cleanup);

const ENDPOINT = `https://shelf.test/sub/kobo/${"a".repeat(64)}`;
const STORE = "https://storeapi.kobo.com";

const settings: AccountSettings = {
  admin: false,
  member_since: "2026-01-02T10:00:00.000Z",
  requests: { total: 0, completed: 0, pending: 0 },
  two_factor: { enabled: false },
  oidc: { configured: false, provider: null, linked: false, link_page: null, password_required: true },
  api_tokens: [],
  token_scopes: [],
  links: { kobo_readers: "/sub/kobo_devices", kobo_accounts: "/sub/kobo_accounts", hardcover: "/sub/profile#hardcover", sign_out: "/sub/session", phone_app: "/sub/consumer/connect", reading_library: "/sub/read", kobo_shared: "/sub/kobo_shared" },
  server: { release: "Shelfarr 1.0 beta", beta: true, series: "1.0" },
};

const profile: Profile = { id: ACCOUNT, username: "rae", name: "Rae Reader", settings };

function row(overrides: Partial<KoboReaderRow> = {}): KoboReaderRow {
  return {
    id: "3",
    name: "Clara",
    mode: "shelfarr_only",
    mode_label: "Shelfarr books only",
    store_coexistence: false,
    share_progress: true,
    receive_progress: false,
    base_url: "https://shelf.test/sub",
    last_sync_at: null,
    version: "v1",
    ...overrides,
  };
}

function delivery(overrides: Partial<KoboDelivery> = {}): KoboDelivery {
  return {
    entitlement_id: "11111111-2222-3333-4444-555555555555",
    choice: "c1",
    title: "The Quiet Library",
    source: "library",
    link: { kind: "library", publication_id: "7" },
    status: "Queued · waiting for download",
    edition: "Kobo edition (KEPUB) prepared from the library EPUB · library file unchanged",
    place: { tone: "choice", text: "Kept a newer place from another device (80%). Kobo place: 35%.", choosable: true },
    outbound: null,
    send_again: { book_id: "7", confirmation: null },
    ...overrides,
  };
}

function reader(overrides: Partial<KoboReader> = {}): KoboReader {
  return { ...row(), store_status: null, placeholder_sign_in: null, store_endpoint: STORE, deliveries: [delivery()], ...overrides };
}

function koboServer(readers: KoboReaderRow[] = [row()], record: KoboReader | null = reader()): FakeServer {
  return standardServer()
    .on("GET", /\/api\/v1\/account$/, () => ({ body: { account: ACCOUNT, profile } }))
    .on("GET", /\/account\/kobo_readers$/, () => ({ body: { account: ACCOUNT, readers, new_reader: { base_url: "https://shelf.test/sub", store_coexistence: true, share_progress: true, receive_progress: false } } }))
    .on("GET", /\/account\/kobo_readers\/\d+$/, () => (record ? { body: { account: ACCOUNT, reader: record } } : { status: 404, body: { error: "reader_not_found" } }));
}

function cached(services: { queryClient: { getQueryCache: () => { getAll: () => { state: { data: unknown } }[] } } }): string {
  return JSON.stringify(services.queryClient.getQueryCache().getAll().map((query) => query.state.data));
}

describe("Kobo readers in Account ▸ Devices", () => {
  beforeEach(() => {
    window.scrollTo = () => undefined;
  });

  test("the fixtures match the Kobo readers contract", () => {
    expect(koboReadersSchema.safeParse({ account: ACCOUNT, readers: [row()], new_reader: { base_url: "https://a", store_coexistence: true, share_progress: true, receive_progress: false } }).success).toBe(true);
    expect(koboReaderEnvelopeSchema.safeParse({ account: ACCOUNT, reader: reader(), notice: "Saved." }).success).toBe(true);
    expect(koboSetupSchema.safeParse({ account: ACCOUNT, reader: row(), setup: { endpoint: ENDPOINT, store_endpoint: STORE } }).success).toBe(true);
    expect(bookKoboSchema.safeParse({ account: ACCOUNT, kobo: { readers: [{ id: "3", name: "Clara" }], refusal: null } }).success).toBe(true);
    expect(koboReaderEnvelopeSchema.safeParse({ account: ACCOUNT, reader: reader({ deliveries: [delivery({ link: { kind: "kobo_book", href: "//evil.example" } })] }) }).success).toBe(false);
  });

  test("Devices lists your readers, keeps Kobo accounts on their pages and connects a new reader with its address shown once", async () => {
    const server = koboServer().on("POST", /\/account\/kobo_readers$/, () => ({ status: 201, body: { account: ACCOUNT, reader: row({ id: "4", name: "Libra", store_coexistence: true, mode: "store_and_shelfarr", mode_label: "Kobo Store + Shelfarr" }), setup: { endpoint: ENDPOINT, store_endpoint: STORE } } }));
    const { services } = renderApp({ server, url: "/sub/preview/account/devices" });
    const card = (await screen.findByRole("heading", { name: "Kobo readers", level: 2 })).closest("section") as HTMLElement;
    expect(await within(card).findByRole("link", { name: "Clara" })).toBeTruthy();
    expect(within(card).getByRole("link", { name: "Clara" }).getAttribute("href")).toBe("/sub/preview/account/devices/kobo/3");
    expect(within(card).getByText("Waiting for first sync")).toBeTruthy();
    expect(screen.getByRole("link", { name: "Kobo accounts" }).getAttribute("href")).toBe("/sub/kobo_accounts");
    expect(screen.getByRole("link", { name: "Kobo books shared with you" }).getAttribute("href")).toBe("/sub/kobo_shared");
    expect(screen.queryByRole("link", { name: "Kobo readers" })).toBeNull();

    expect((within(card).getByRole("radio", { name: /Keep my Kobo Store library/ }) as HTMLInputElement).checked).toBe(true);
    expect((within(card).getByRole("checkbox", { name: "Share reading places with Shelfarr" }) as HTMLInputElement).checked).toBe(true);
    expect((within(card).getByRole("checkbox", { name: /Receive Shelfarr reading places/ }) as HTMLInputElement).checked).toBe(false);
    expect((within(card).getByLabelText("Shelfarr address reachable from this reader") as HTMLInputElement).value).toBe("https://shelf.test/sub");

    const user = userEvent.setup();
    await user.type(within(card).getByLabelText("Reader name"), "Libra");
    await user.click(within(card).getByRole("checkbox", { name: /Receive Shelfarr reading places/ }));
    await user.click(within(card).getByRole("button", { name: "Create connection" }));
    const setup = await within(card).findByTestId("kobo-setup");
    expect(within(setup).getByRole("heading", { name: "Connect Libra" })).toBeTruthy();
    expect(within(setup).getByTestId("kobo-endpoint").textContent).toBe(`api_endpoint=${ENDPOINT}`);
    expect(within(setup).getByTestId("kobo-store-endpoint").textContent).toBe(`api_endpoint=${STORE}`);
    expect(within(setup).getByText(/shown once.*and relay this reader's Store requests/)).toBeTruthy();
    expect(within(setup).getByRole("link", { name: "Done · manage reader" }).getAttribute("href")).toBe("/sub/preview/account/devices/kobo/4");
    const posted = server.called("POST", /\/account\/kobo_readers$/)[0]!;
    expect(posted.body).toEqual({ name: "Libra", base_url: "https://shelf.test/sub", store_coexistence: true, share_progress: true, receive_progress: true });
    expect([posted.headers["x-shelfarr-account"], posted.headers["x-csrf-token"]]).toEqual([ACCOUNT, "token-123"]);
    expect(cached(services)).not.toContain(ENDPOINT);
    expect(document.activeElement).toBe(within(setup).getByRole("heading", { name: "Connect Libra" }));

    await user.click(within(setup).getByRole("button", { name: "Hide the address" }));
    expect(screen.queryByText(`api_endpoint=${ENDPOINT}`)).toBeNull();
    expect(document.activeElement).toBe(card);
    expect(within(card).getByRole("button", { name: "Create connection" })).toBeTruthy();
    await waitFor(() => expect(server.called("GET", /\/account\/kobo_readers$/).length).toBeGreaterThan(1));
  });

  test("a refused reader marks its field with the server's reason and keeps what was typed", async () => {
    const server = koboServer([]).on("POST", /\/account\/kobo_readers$/, () => ({
      status: 422,
      body: { account: ACCOUNT, error: "invalid_reader", errors: { base_url: ["must use HTTPS to keep the Kobo Store on this reader"] }, messages: ["Base url must use HTTPS to keep the Kobo Store on this reader"] },
    }));
    renderApp({ server, url: "/sub/preview/account/devices" });
    expect(await screen.findByText("No Kobo reader is connected to your account.")).toBeTruthy();
    const user = userEvent.setup();
    const address = screen.getByLabelText("Shelfarr address reachable from this reader") as HTMLInputElement;
    await user.clear(address);
    await user.type(address, "http://shelf.local");
    await user.type(screen.getByLabelText("Reader name"), "Clara");
    await user.click(screen.getByRole("button", { name: "Create connection" }));
    expect(await screen.findByText("Shelfarr address must use HTTPS to keep the Kobo Store on this reader.")).toBeTruthy();
    expect(screen.getByText("The reader was not connected. Check the marked fields.")).toBeTruthy();
    expect(address.getAttribute("aria-invalid")).toBe("true");
    expect(document.activeElement).toBe(address);
    expect(address.value).toBe("http://shelf.local");
    expect(screen.queryByTestId("kobo-endpoint")).toBeNull();
  });

  test("the old Kobo readers address lands on this card with focus", async () => {
    renderApp({ server: koboServer(), url: "/sub/preview/account/devices#kobo-readers" });
    expect(await screen.findByRole("link", { name: "Clara" })).toBeTruthy();
    await waitFor(() => expect(document.activeElement?.id).toBe("kobo-readers"));
  });

  test("an empty name is refused before anything is sent", async () => {
    const server = koboServer([]);
    renderApp({ server, url: "/sub/preview/account/devices" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Create connection" }));
    expect(screen.getByText("Enter a name for this reader.")).toBeTruthy();
    expect(server.called("POST", /kobo_readers/)).toEqual([]);
  });
});

describe("a Kobo reader's page", () => {
  test("shows the reader's books with their states and chooses a Kobo place only after confirming", async () => {
    const server = koboServer([row()], reader({ store_coexistence: true, store_status: { tone: "warning", text: "Kobo Store couldn't be reached 1 minute ago.", choosable: false } })).on("POST", /\/places\/kobo$/, () => ({
      status: 409,
      body: { account: ACCOUNT, error: "place_refused", message: "Another device saved a place just now. Review the places and choose again.", reader: reader({ deliveries: [delivery({ place: { tone: "warning", text: "Another device saved a place.", choosable: false } })] }) },
    }));
    renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    expect(await screen.findByRole("heading", { name: "Clara", level: 1 })).toBeTruthy();
    expect(screen.getByTestId("kobo-store-status").textContent).toBe("Kobo Store couldn't be reached 1 minute ago.");
    const books = screen.getByRole("heading", { name: "Selected books" }).closest("section") as HTMLElement;
    expect(within(books).getByRole("link", { name: "The Quiet Library" }).getAttribute("href")).toBe("/sub/preview/library/7");
    expect(within(books).getByTestId("kobo-edition").textContent).toContain("Kobo edition (KEPUB)");
    expect(within(books).getByTestId("kobo-place").className).toContain("kobo-tone--choice");

    const user = userEvent.setup();
    await user.click(within(books).getByRole("button", { name: "Use Kobo place" }));
    const ask = within(books).getByRole("group", { name: "Resume The Quiet Library at the Kobo place in Shelfarr's web and mobile readers?" });
    expect(server.called("POST", /places/)).toEqual([]);
    await user.click(within(ask).getByRole("button", { name: "Use Kobo place" }));
    expect(await within(books).findByText("Another device saved a place just now. Review the places and choose again.")).toBeTruthy();
    expect(server.called("POST", /\/places\/kobo$/)[0]?.body).toEqual({ entitlement_id: "11111111-2222-3333-4444-555555555555", choice: "c1" });
    expect(document.activeElement).toBe(within(books).getByRole("group", { name: "The Quiet Library" }));
    await waitFor(() => expect(within(books).getByTestId("kobo-place").textContent).toBe("Another device saved a place."));
    expect(within(books).queryByRole("button", { name: "Use Kobo place" })).toBeNull();
  });

  test("Send again asks first when the server gives a reason, and sends the book to this reader", async () => {
    const server = koboServer([row()], reader({ deliveries: [delivery({ place: null, send_again: { book_id: "7", confirmation: "Send a Kobo edition (KEPUB) of The Quiet Library to Clara?" } })] })).on("POST", /\/kobo_readers\/3\/send$/, () => ({
      body: { account: ACCOUNT, reader: { id: "3", name: "Clara" }, notice: "Queued for Clara. Sync your Kobo over Wi-Fi to download it." },
    }));
    renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Send again The Quiet Library" }));
    const ask = screen.getByRole("group", { name: "Send a Kobo edition (KEPUB) of The Quiet Library to Clara?" });
    await user.click(within(ask).getByRole("button", { name: "Send again" }));
    expect(await screen.findByText("Queued for Clara. Sync your Kobo over Wi-Fi to download it.")).toBeTruthy();
    expect(server.called("POST", /\/send$/)[0]?.body).toEqual({ book_id: "7" });
  });

  test("settings are saved with the version they were edited from, and a change made elsewhere is shown instead", async () => {
    let saves = 0;
    const server = koboServer().on("PUT", /\/kobo_readers\/3$/, () => {
      saves += 1;
      return saves === 1
        ? { body: { account: ACCOUNT, reader: reader({ receive_progress: true, version: "v2" }), notice: "Clara receives Shelfarr reading places for books sent from your library at its next Wi-Fi sync." } }
        : { status: 409, body: { account: ACCOUNT, error: "reader_changed", reader: reader({ receive_progress: false, share_progress: false, version: "v3" }) } };
    });
    renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    const form = (await screen.findByRole("heading", { name: "Sync settings" })).closest("section") as HTMLElement;
    const user = userEvent.setup();
    await user.click(within(form).getByRole("checkbox", { name: /Receive Shelfarr reading places/ }));
    expect(within(form).getByText("Unsaved changes")).toBeTruthy();
    await user.click(within(form).getByRole("button", { name: "Save settings" }));
    expect(await within(form).findByText("Clara receives Shelfarr reading places for books sent from your library at its next Wi-Fi sync.")).toBeTruthy();
    expect(server.called("PUT", /kobo_readers\/3$/)[0]?.body).toEqual({ store_coexistence: false, share_progress: true, receive_progress: true, version: "v1" });
    expect(within(form).queryByText("Unsaved changes")).toBeNull();

    await user.click(within(form).getByRole("radio", { name: /Keep my Kobo Store library/ }));
    await user.click(within(form).getByRole("button", { name: "Save settings" }));
    expect(await within(form).findByText(/changed somewhere else while you were editing. Nothing was saved/)).toBeTruthy();
    expect(server.called("PUT", /kobo_readers\/3$/)[1]?.body).toEqual({ store_coexistence: true, share_progress: true, receive_progress: true, version: "v2" });
    expect((within(form).getByRole("radio", { name: /Shelfarr books only/ }) as HTMLInputElement).checked).toBe(true);
    expect((within(form).getByRole("checkbox", { name: "Share reading places with Shelfarr" }) as HTMLInputElement).checked).toBe(false);
    expect(within(form).queryByText("Unsaved changes")).toBeNull();
  });

  test("a new connection address is made only after confirming, shown once, and refused when the reader changed", async () => {
    let calls = 0;
    const server = koboServer().on("POST", /\/connection_address$/, () => {
      calls += 1;
      return calls === 1 ? { body: { account: ACCOUNT, reader: row({ version: "v2" }), setup: { endpoint: ENDPOINT, store_endpoint: STORE } } } : { status: 409, body: { account: ACCOUNT, error: "reader_changed", reader: reader({ version: "v9" }) } };
    });
    const { services } = renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    const connection = (await screen.findByRole("heading", { name: "Connection" })).closest("section") as HTMLElement;
    expect(within(connection).getByText("https://shelf.test/sub")).toBeTruthy();
    const user = userEvent.setup();
    await user.click(within(connection).getByRole("button", { name: "Make a new connection address" }));
    expect(server.called("POST", /connection_address/)).toEqual([]);
    await user.click(within(connection).getByRole("button", { name: "Make a new address" }));
    expect((await within(connection).findByTestId("kobo-endpoint")).textContent).toBe(`api_endpoint=${ENDPOINT}`);
    expect(server.called("POST", /connection_address$/)[0]?.body).toEqual({ version: "v1" });
    expect(cached(services)).not.toContain(ENDPOINT);
    await user.click(within(connection).getByRole("button", { name: "I updated the reader" }));
    expect(screen.queryByTestId("kobo-endpoint")).toBeNull();

    await user.click(within(connection).getByRole("button", { name: "Make a new connection address" }));
    await user.click(within(connection).getByRole("button", { name: "Make a new address" }));
    expect(await within(connection).findByText(/changed somewhere else, so no new address was made/)).toBeTruthy();
    expect(server.called("POST", /connection_address$/)[1]?.body).toEqual({ version: "v2" });
    expect(screen.queryByTestId("kobo-endpoint")).toBeNull();
  });

  test("revoking asks twice, then says books on the reader are kept", async () => {
    const server = koboServer().on("POST", /\/revoke$/, () => ({ body: { account: ACCOUNT, revoked: "3", notice: "Kobo connection revoked. Books already on the reader are kept." } }));
    renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Revoke connection" }));
    const ask = screen.getByRole("group", { name: "Revoke this Kobo connection? The reader will stop syncing with Shelfarr." });
    await user.click(within(ask).getByRole("button", { name: "Revoke connection" }));
    expect(await screen.findByText("Kobo connection revoked. Books already on the reader are kept.")).toBeTruthy();
    expect(screen.getByRole("heading", { name: "Kobo connection revoked", level: 1 })).toBeTruthy();
    expect(server.called("POST", /\/revoke$/).map((request) => request.body)).toEqual([{ version: "v1" }]);
  });

  test("an open confirmation closes when the reader or the place it was opened on changes, and sends only what was confirmed", async () => {
    const server = koboServer()
      .on("POST", /\/revoke$/, () => ({ body: { account: ACCOUNT, revoked: "3", notice: "Kobo connection revoked. Books already on the reader are kept." } }))
      .on("POST", /\/places\/kobo$/, () => ({ body: { account: ACCOUNT, reader: reader({ version: "v2", deliveries: [delivery({ choice: "c3", place: null })] }), notice: "Shelfarr now resumes The Quiet Library at the Kobo place." } }));
    const { services } = renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Use Kobo place" }));
    expect(screen.getByRole("group", { name: /Resume The Quiet Library/ })).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Revoke connection" }));
    expect(screen.getByRole("group", { name: /Revoke this Kobo connection/ })).toBeTruthy();
    await act(async () => {
      services.queryClient.setQueryData(["account", ACCOUNT, "kobo", "reader", "3"], reader({ name: "Clara two", version: "v2", deliveries: [delivery({ choice: "c2" })] }));
    });
    await act(() => new Promise((resolve) => setTimeout(resolve, 50)));
    expect(screen.getByRole("heading", { name: "Clara two", level: 1 })).toBeTruthy();
    expect(screen.queryByRole("group", { name: /Resume The Quiet Library/ })).toBeNull();
    expect(screen.queryByRole("group", { name: /Revoke this Kobo connection/ })).toBeNull();
    expect(server.called("POST", /places|revoke/)).toEqual([]);
    await act(async () => {
      services.queryClient.setQueryData(["account", ACCOUNT, "kobo", "reader", "3"], reader({ name: "Clara", version: "v1" }));
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(screen.queryByRole("group", { name: /Revoke this Kobo connection/ })).toBeNull();
    expect(screen.queryByRole("group", { name: /Resume The Quiet Library/ })).toBeNull();
    await act(async () => {
      services.queryClient.setQueryData(["account", ACCOUNT, "kobo", "reader", "3"], reader({ name: "Clara two", version: "v2", deliveries: [delivery({ choice: "c2" })] }));
      await new Promise((resolve) => setTimeout(resolve, 50));
    });

    await user.click(screen.getByRole("button", { name: "Use Kobo place" }));
    await user.click(within(screen.getByRole("group", { name: /Resume The Quiet Library/ })).getByRole("button", { name: "Use Kobo place" }));
    await screen.findByText("Shelfarr now resumes The Quiet Library at the Kobo place.");
    expect(server.called("POST", /places\/kobo$/)[0]?.body).toEqual({ entitlement_id: "11111111-2222-3333-4444-555555555555", choice: "c2" });
    await user.click(screen.getByRole("button", { name: "Revoke connection" }));
    await user.click(within(screen.getByRole("group", { name: /Revoke this Kobo connection/ })).getByRole("button", { name: "Revoke connection" }));
    await screen.findByRole("heading", { name: "Kobo connection revoked", level: 1 });
    expect(server.called("POST", /revoke$/)[0]?.body).toEqual({ version: "v2" });
  });

  test("a reader changed elsewhere is not revoked from an old page", async () => {
    const server = koboServer().on("POST", /\/revoke$/, () => ({ status: 409, body: { account: ACCOUNT, error: "reader_changed", reader: reader({ version: "v2", name: "Clara (renamed)" }) } }));
    renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Revoke connection" }));
    await user.click(within(screen.getByRole("group", { name: /Revoke this Kobo connection/ })).getByRole("button", { name: "Revoke connection" }));
    expect(await screen.findByText(/changed somewhere else, so it was not revoked/)).toBeTruthy();
    expect(await screen.findByRole("heading", { name: "Clara (renamed)", level: 1 })).toBeTruthy();
  });

  test("a new address is never shown under another reader after moving through history", async () => {
    const records: Record<string, KoboReader> = { "3": reader(), "4": reader({ id: "4", name: "Libra", version: "w1" }) };
    const server = koboServer([row(), row({ id: "4", name: "Libra" })])
      .on("GET", /\/account\/kobo_readers\/\d+$/, (request) => ({ body: { account: ACCOUNT, reader: records[request.path.split("/").pop()!] } }))
      .on("POST", /\/kobo_readers\/3\/connection_address$/, () => ({ body: { account: ACCOUNT, reader: row({ version: "v2" }), setup: { endpoint: ENDPOINT, store_endpoint: STORE } } }));
    const { router } = renderApp({ server, url: "/sub/preview/account/devices/kobo/4" });
    expect(await screen.findByRole("heading", { name: "Libra", level: 1 })).toBeTruthy();
    await act(() => router.navigate({ to: "/account/devices/kobo/$readerId", params: { readerId: "3" } }));
    expect(await screen.findByRole("heading", { name: "Clara", level: 1 })).toBeTruthy();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Make a new connection address" }));
    await user.click(screen.getByRole("button", { name: "Make a new address" }));
    expect(await screen.findByTestId("kobo-endpoint")).toBeTruthy();
    await act(() => router.history.back());
    expect(await screen.findByRole("heading", { name: "Libra", level: 1 })).toBeTruthy();
    expect(screen.queryByTestId("kobo-endpoint")).toBeNull();
    expect(screen.queryByText("Connect Clara")).toBeNull();
  });

  test("a reader revoked elsewhere replaces its cached page once the server says so", async () => {
    let gone = false;
    const server = koboServer().on("GET", /\/account\/kobo_readers\/3$/, () => (gone ? { status: 404, body: { error: "reader_not_found" } } : { body: { account: ACCOUNT, reader: reader() } }));
    const { router } = renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    expect(await screen.findByRole("heading", { name: "Clara", level: 1 })).toBeTruthy();
    await act(() => router.navigate({ to: "/account/$section", params: { section: "devices" } }));
    await screen.findByRole("heading", { name: "Devices", level: 1 });
    gone = true;
    await act(() => router.navigate({ to: "/account/devices/kobo/$readerId", params: { readerId: "3" } }));
    expect(await screen.findByRole("heading", { name: "This Kobo reader is not connected to your account" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Make a new connection address" })).toBeNull();
  });

  test("hiding a new address keeps keyboard focus in the Connection card", async () => {
    const server = koboServer().on("POST", /\/connection_address$/, () => ({ body: { account: ACCOUNT, reader: row({ version: "v2" }), setup: { endpoint: ENDPOINT, store_endpoint: STORE } } }));
    renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Make a new connection address" }));
    await user.click(screen.getByRole("button", { name: "Make a new address" }));
    await user.click(await screen.findByRole("button", { name: "I updated the reader" }));
    expect(document.activeElement).toBe(screen.getByRole("heading", { name: "Connection" }));
  });

  test("another person's reader, or one already revoked, is not shown", async () => {
    renderApp({ server: koboServer([], null), url: "/sub/preview/account/devices/kobo/99" });
    expect(await screen.findByRole("heading", { name: "This Kobo reader is not connected to your account" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Revoke connection" })).toBeNull();
  });

  test("an answer for another account locks the page and shows nothing from it", async () => {
    const server = koboServer().on("GET", /\/account\/kobo_readers\/\d+$/, () => ({ body: { account: "99", reader: reader({ name: "Someone else's Kobo" }) } }));
    renderApp({ server, url: "/sub/preview/account/devices/kobo/3" });
    await waitFor(() => expect(screen.queryByText("Someone else's Kobo")).toBeNull());
    expect(await screen.findByText(/signed-in account changed|different account|another account/i)).toBeTruthy();
  });
});

describe("Send to Kobo on a stored copy and the Book page", () => {
  function bookServer(kobo: { readers: { id: string; name: string }[]; refusal: string | null }): FakeServer {
    return standardServer()
      .on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail() } }))
      .on("GET", /\/api\/v1\/library\/7\/kobo$/, () => ({ body: { account: ACCOUNT, kobo } }));
  }

  test("each of your readers gets a send button, and the server's answer is announced", async () => {
    const server = bookServer({ readers: [{ id: "3", name: "Clara" }, { id: "4", name: "Libra" }], refusal: null }).on("POST", /\/kobo_readers\/4\/send$/, () => ({
      body: { account: ACCOUNT, reader: { id: "4", name: "Libra" }, notice: "Queued for Libra as a Kobo edition (KEPUB) prepared from this EPUB; the library file is unchanged. Sync your Kobo over Wi-Fi to download it." },
    }));
    renderApp({ server, url: "/sub/preview/library/7" });
    const panel = (await screen.findByRole("heading", { name: "Send to Kobo" })).closest("section") as HTMLElement;
    expect(await within(panel).findByRole("button", { name: "Send to Clara" })).toBeTruthy();
    const user = userEvent.setup();
    await user.click(within(panel).getByRole("button", { name: "Send to Libra" }));
    expect(await within(panel).findByText(/Queued for Libra as a Kobo edition/)).toBeTruthy();
    expect(server.called("POST", /\/send$/).map((request) => [request.path, request.body])).toEqual([["/sub/preview/api/v1/account/kobo_readers/4/send", { book_id: "7" }]]);
  });

  test("a refused send shows the server's reason", async () => {
    const server = bookServer({ readers: [{ id: "3", name: "Clara" }], refusal: null }).on("POST", /\/send$/, () => ({ status: 422, body: { error: "kobo_send_refused", message: "The ebook changed; try sending it again" } }));
    renderApp({ server, url: "/sub/preview/library/7" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Send to Clara" }));
    expect(await screen.findByText("The ebook changed; try sending it again")).toBeTruthy();
  });

  test("a file Kobo cannot take says why, and without readers the page offers to connect one", async () => {
    renderApp({ server: bookServer({ readers: [{ id: "3", name: "Clara" }], refusal: "Kobo sync supports EPUB files only" }), url: "/sub/preview/library/7" });
    expect((await screen.findByTestId("kobo-refusal")).textContent).toBe("Kobo sync supports EPUB files only.");
    expect(screen.queryByRole("button", { name: "Send to Clara" })).toBeNull();
    cleanup();
    renderApp({ server: bookServer({ readers: [], refusal: null }), url: "/sub/preview/library/7" });
    expect((await screen.findByRole("link", { name: "Connect a Kobo reader" })).getAttribute("href")).toBe("/sub/preview/account/devices#kobo-readers");
  });

  test("audiobooks, comics and unavailable copies do not ask about Kobo", async () => {
    for (const overrides of [{ book_type: "audiobook" as const, action: "listen" as const }, { content_kind: "graphic" as const }, { availability: "unavailable" as const }]) {
      const server = standardServer().on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail(overrides) } }));
      renderApp({ server, url: "/sub/preview/library/7" });
      expect(await screen.findByRole("heading", { name: "The Quiet Library" })).toBeTruthy();
      await act(() => new Promise((resolve) => setTimeout(resolve, 20)));
      expect(screen.queryByRole("heading", { name: "Send to Kobo" })).toBeNull();
      expect(server.called("GET", /\/kobo$/)).toEqual([]);
      cleanup();
    }
  });
});
