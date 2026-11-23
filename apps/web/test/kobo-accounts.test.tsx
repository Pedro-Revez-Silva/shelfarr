import { afterEach, beforeEach, describe, expect, jest, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { AccountSettings, Profile } from "../src/contract";
import {
  koboAccountEnvelopeSchema,
  koboAccountsSchema,
  koboBookEnvelopeSchema,
  koboCatalogueSchema,
  type KoboAccount,
  type KoboBook,
  type KoboCatalogue,
} from "../src/devices/kobo-accounts/contract";
import { ACCOUNT, deferred, renderApp, standardServer, type FakeServer } from "./helpers";

afterEach(() => {
  jest.useRealTimers();
  cleanup();
});

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
const SOON = new Date(Date.now() + 9 * 60_000).toISOString();

function koboAccount(overrides: Partial<KoboAccount> = {}): KoboAccount {
  return {
    id: "5",
    name: "Family purchases",
    state: "connected",
    status_label: "Connected",
    shared_with: 1,
    version: "v1",
    error: null,
    activation: null,
    kobo_email: "rae@example.test",
    refreshing: false,
    can_refresh: true,
    last_synced_at: "2026-11-20T10:00:00.000Z",
    sharing: {
      people: [{ id: "8", name: "Sam Sharer", username: "sam", shared_at: "2026-11-01T10:00:00.000Z", inactive: false }],
      candidates: [{ id: "9", label: "Tess Tester (tess)" }],
    },
    ...overrides,
  };
}

function pending(): KoboAccount {
  return koboAccount({ state: "pending", status_label: "Sign-in pending", shared_with: 0, kobo_email: null, can_refresh: false, last_synced_at: null, sharing: null, activation: { code: "123456", page: "https://www.kobo.com/activate", expires_at: SOON } });
}

function catalogue(overrides: Partial<KoboCatalogue> = {}): KoboCatalogue {
  return {
    kobo_account: { id: "5", name: "Family purchases", owner: true, owner_name: "Rae Reader", connected: true, last_synced_at: "2026-11-20T10:00:00.000Z" },
    filter: "all",
    page: 1,
    more: true,
    count: 51,
    sendable_count: 1,
    books: [
      { id: "21", title: "A Shared Purchase", author: "An Author", eligibility: { tone: "ok", label: "DRM-free EPUB · can be sent" } },
      { id: "22", title: "A Protected Purchase", author: null, eligibility: { tone: "warning", label: "Protected by DRM · can't be sent" } },
    ],
    ...overrides,
  };
}

function book(overrides: Partial<KoboBook> = {}): KoboBook {
  return {
    id: "21",
    title: "A Shared Purchase",
    author: "An Author",
    from: "Rae Reader's Kobo account “Family purchases”",
    kobo_account: { id: "5", name: "Family purchases", owner: false, owner_name: "Rae Reader" },
    cover: null,
    eligibility: { tone: "ok", label: "DRM-free EPUB · can be sent", detail: "Kobo lists a DRM-free EPUB for this purchase." },
    deliverable: true,
    offered: "EPUB3 · 2 KB according to Kobo",
    copy: { version: null, preparing: false, failure: null, ready: null, unavailable: null, explanation: "Shelfarr first saves a private copy of the DRM-free EPUB on this server." },
    readers: [{ id: "3", name: "Clara", status: "Shelfarr books only", older_copy: false, sent: false }],
    ...overrides,
  };
}

function server(record: KoboAccount | null = koboAccount()): FakeServer {
  return standardServer()
    .on("GET", /\/api\/v1\/account$/, () => ({ body: { account: ACCOUNT, profile } }))
    .on("GET", /\/account\/kobo_readers$/, () => ({ body: { account: ACCOUNT, readers: [], new_reader: { base_url: "https://shelf.test/sub", store_coexistence: true, share_progress: true, receive_progress: false } } }))
    .on("GET", /\/account\/kobo_accounts$/, () => ({
      body: { account: ACCOUNT, kobo_accounts: [{ id: "5", name: "Family purchases", state: "connected", status_label: "Connected", shared_with: 1 }], received: [{ id: "6", name: "Sam's books", owner_name: "Sam Sharer", sendable_count: 1 }], new_account: { name: "My Kobo account" } },
    }))
    .on("GET", /\/account\/kobo_accounts\/\d+$/, () => (record ? { body: { account: ACCOUNT, kobo_account: record } } : { status: 404, body: { error: "kobo_account_not_found" } }))
    .on("GET", /\/kobo_catalogues\/\d+/, () => ({ body: { account: ACCOUNT, catalogue: catalogue() } }));
}

async function tick(ms = 0) {
  await act(async () => {
    jest.advanceTimersByTime(ms);
    for (let round = 0; round < 20; round += 1) await Promise.resolve();
  });
}

async function until(check: () => void) {
  for (let round = 0; ; round += 1) {
    try {
      check();
      return;
    } catch (error) {
      if (round >= 60) throw error;
      await tick();
    }
  }
}

describe("Kobo accounts in Account ▸ Devices", () => {
  beforeEach(() => {
    window.scrollTo = () => undefined;
  });

  test("the fixtures match the Kobo accounts contract and refuse foreign addresses", () => {
    expect(koboAccountsSchema.safeParse({ account: ACCOUNT, kobo_accounts: [], received: [], new_account: { name: "My Kobo account" } }).success).toBe(true);
    expect(koboAccountEnvelopeSchema.safeParse({ account: ACCOUNT, kobo_account: koboAccount() }).success).toBe(true);
    expect(koboAccountEnvelopeSchema.safeParse({ account: ACCOUNT, kobo_account: pending() }).success).toBe(true);
    expect(koboAccountEnvelopeSchema.safeParse({ account: ACCOUNT, kobo_account: { ...pending(), activation: { code: "123456", page: "https://evil.example/activate", expires_at: SOON } } }).success).toBe(false);
    expect(koboCatalogueSchema.safeParse({ account: ACCOUNT, catalogue: catalogue() }).success).toBe(true);
    expect(koboBookEnvelopeSchema.safeParse({ account: ACCOUNT, book: book() }).success).toBe(true);
    expect(koboBookEnvelopeSchema.safeParse({ account: ACCOUNT, book: book({ cover: "//evil.example/cover" }) }).success).toBe(false);
  });

  test("Devices lists your Kobo accounts and catalogues shared with you, and connecting opens the new account's approval", async () => {
    const created = pending();
    const api = server(created).on("POST", /\/account\/kobo_accounts$/, () => ({ status: 201, body: { account: ACCOUNT, kobo_account: created } }));
    const { router } = renderApp({ server: api, url: "/sub/preview/account/devices" });
    const card = (await screen.findByRole("heading", { name: "Kobo accounts", level: 2 })).closest("section") as HTMLElement;
    const link = await within(card).findByRole("link", { name: "Family purchases" });
    expect(link.getAttribute("href")).toBe("/sub/preview/account/devices/kobo-accounts/5");
    expect(within(card).getByText("shared with 1 person")).toBeTruthy();
    const shared = screen.getByRole("heading", { name: "Kobo books shared with you", level: 2 }).closest("section") as HTMLElement;
    expect(within(shared).getByRole("link", { name: "Sam's books" }).getAttribute("href")).toBe("/sub/preview/account/devices/kobo-shared/6");
    expect(within(shared).getByText("Shared by Sam Sharer")).toBeTruthy();
    expect(within(shared).getByText("1 book can be sent")).toBeTruthy();
    expect(document.querySelector('a[href="/sub/kobo_accounts"], a[href="/sub/kobo_shared"]')).toBeNull();

    const user = userEvent.setup();
    const name = within(card).getByLabelText("Connection name") as HTMLInputElement;
    expect(name.value).toBe("My Kobo account");
    await user.clear(name);
    await user.click(within(card).getByRole("button", { name: "Connect Kobo account" }));
    expect(within(card).getByText("Enter a name for this connection.")).toBeTruthy();
    expect(document.activeElement).toBe(name);
    expect(api.called("POST", /\/account\/kobo_accounts$/)).toHaveLength(0);
    await user.type(name, "Rae's books");
    await user.click(within(card).getByRole("button", { name: "Connect Kobo account" }));
    expect(await screen.findByTestId("kobo-activation-code")).toBeTruthy();
    expect(router.state.location.pathname).toBe("/account/devices/kobo-accounts/5");
    const posted = api.called("POST", /\/account\/kobo_accounts$/)[0]!;
    expect(posted.body).toEqual({ name: "Rae's books" });
    expect([posted.headers["x-shelfarr-account"], posted.headers["x-csrf-token"]]).toEqual([ACCOUNT, "token-123"]);
    const activation = screen.getByRole("link", { name: /Open Kobo activation/ });
    expect([activation.getAttribute("href"), activation.getAttribute("target"), activation.getAttribute("rel")]).toEqual(["https://www.kobo.com/activate", "_blank", "noopener noreferrer"]);
  });

  test("connecting says why Kobo refused and keeps the name", async () => {
    const api = server().on("POST", /\/account\/kobo_accounts$/, () => ({ status: 422, body: { error: "kobo_limit_reached", message: "Too many connections or recent sign-in attempts. Remove unused connections or wait a minute." } }));
    renderApp({ server: api, url: "/sub/preview/account/devices" });
    const card = (await screen.findByRole("heading", { name: "Kobo accounts", level: 2 })).closest("section") as HTMLElement;
    await within(card).findByRole("link", { name: "Family purchases" });
    await userEvent.setup().click(within(card).getByRole("button", { name: "Connect Kobo account" }));
    expect(await within(card).findByText("Too many connections or recent sign-in attempts. Remove unused connections or wait a minute.")).toBeTruthy();
    expect((within(card).getByLabelText("Connection name") as HTMLInputElement).value).toBe("My Kobo account");
  });

  test("a pending approval is checked one request at a time, every five seconds, and opens the connected account", async () => {
    jest.useFakeTimers();
    const answer = deferred<{ body: unknown }>();
    let polls = 0;
    const api = server(pending()).on("POST", /\/kobo_accounts\/5\/poll$/, () => {
      polls += 1;
      return polls === 1 ? { body: { account: ACCOUNT, kobo_account: pending() } } : answer.promise;
    });
    renderApp({ server: api, url: "/sub/preview/account/devices/kobo-accounts/5" });
    await until(() => expect(screen.getByTestId("kobo-activation-code").textContent).toBe("123456"));
    expect(screen.getByText("Waiting for approval…")).toBeTruthy();
    await tick(4900);
    expect(polls).toBe(0);
    await tick(100);
    await until(() => expect(polls).toBe(1));
    await tick(5000);
    await until(() => expect(polls).toBe(2));
    const check = screen.getByRole("button", { name: /Checking/ });
    await act(async () => {
      check.click();
    });
    await tick(20000);
    expect(polls).toBe(2);
    await act(async () => {
      answer.resolve({ body: { account: ACCOUNT, kobo_account: koboAccount({ refreshing: true, can_refresh: false, shared_with: 0 }) } });
    });
    await until(() => expect(screen.getByRole("heading", { name: "Connected to Kobo" })).toBeTruthy());
    expect(screen.getByText("Refreshing your catalogue… This page will update when it finishes.")).toBeTruthy();
    expect(screen.queryByTestId("kobo-activation-code")).toBeNull();
    await tick(20000);
    expect(polls).toBe(2);
    await tick();
    jest.useRealTimers();
  });

  test("the account page refreshes the catalogue, shares, stops sharing and disconnects with the version it showed", async () => {
    const shared = koboAccount();
    const api = server(shared)
      .on("POST", /\/kobo_accounts\/5\/refresh$/, () => ({ status: 409, body: { account: ACCOUNT, error: "refresh_refused", message: "A refresh is already running, or this account needs sign-in.", kobo_account: koboAccount({ refreshing: true, can_refresh: false }) } }))
      .on("POST", /\/kobo_accounts\/5\/shares$/, () => ({
        body: { account: ACCOUNT, notice: "Shared with Tess Tester. They can see this catalogue and send its DRM-free purchases to their own Kobo.", kobo_account: koboAccount({ shared_with: 2, sharing: { people: [...shared.sharing!.people, { id: "10", name: "Tess Tester", username: "tess", shared_at: "2026-11-22T10:00:00.000Z", inactive: false }], candidates: [] } }) },
      }))
      .on("POST", /\/kobo_accounts\/5\/shares\/8\/remove$/, () => ({ body: { account: ACCOUNT, notice: "Sam Sharer can no longer see this catalogue or receive its books.", kobo_account: koboAccount({ shared_with: 0, sharing: { people: [], candidates: [] } }) } }))
      .on("POST", /\/kobo_accounts\/5\/disconnect$/, (request) =>
        (request.body as { version: string }).version === "v1"
          ? { status: 409, body: { account: ACCOUNT, error: "kobo_account_changed", message: "This Kobo connection changed after the page was shown. Review it and choose again.", kobo_account: koboAccount({ version: "v2" }) } }
          : { body: { account: ACCOUNT, disconnected: "5", notice: "Kobo connection, its private catalogue, copies and shares removed from Shelfarr." } },
      );
    renderApp({ server: api, url: "/sub/preview/account/devices/kobo-accounts/5?filter=sendable&page=2" });
    expect(await screen.findByRole("heading", { name: "Family purchases", level: 1 })).toBeTruthy();
    expect(screen.getByText("Account: rae@example.test")).toBeTruthy();
    const list = await screen.findByRole("heading", { name: "Kobo catalogue · 51 titles" });
    expect(list).toBeTruthy();
    expect(api.called("GET", /\/kobo_catalogues\/5\?filter=sendable&page=2$/)).toHaveLength(1);
    expect(screen.getByRole("link", { name: "A Shared Purchase" }).getAttribute("href")).toBe("/sub/preview/account/devices/kobo-books/21");
    expect(screen.getByText("Unknown author")).toBeTruthy();
    expect(screen.getByRole("link", { name: "Next" }).getAttribute("href")).toBe("/sub/preview/account/devices/kobo-accounts/5?page=2");

    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Refresh catalogue" }));
    expect(await screen.findByText("A refresh is already running, or this account needs sign-in.")).toBeTruthy();
    expect(screen.getByText("Refreshing your catalogue… This page will update when it finishes.")).toBeTruthy();

    const sharing = screen.getByRole("heading", { name: "Household sharing" }).closest("section") as HTMLElement;
    await user.click(within(sharing).getByRole("button", { name: "Share catalogue" }));
    expect(within(sharing).getByText("Choose someone to share with.")).toBeTruthy();
    expect(api.called("POST", /\/shares$/)).toHaveLength(0);
    await user.selectOptions(within(sharing).getByLabelText("Share with"), "9");
    await user.click(within(sharing).getByRole("button", { name: "Share catalogue" }));
    expect(await within(sharing).findByText(/Shared with Tess Tester\./)).toBeTruthy();
    expect(api.called("POST", /\/shares$/)[0]!.body).toEqual({ recipient_id: "9" });
    expect(within(sharing).getByText("There are no other Shelfarr users to share with who don't already have access.")).toBeTruthy();

    await user.click(within(sharing).getByRole("button", { name: "Stop sharing with Sam Sharer" }));
    await user.click(within(sharing).getByRole("button", { name: "Stop sharing" }));
    expect(await within(sharing).findByText("Sam Sharer can no longer see this catalogue or receive its books.")).toBeTruthy();
    expect(within(sharing).getByText(/Only you can see this catalogue\./)).toBeTruthy();

    const remove = screen.getByRole("heading", { name: "Disconnect" }).closest("section") as HTMLElement;
    await user.click(within(remove).getByRole("button", { name: "Disconnect Kobo account" }));
    await user.click(within(remove).getByRole("button", { name: "Disconnect" }));
    expect(await within(remove).findByText("This Kobo connection changed after the page was shown. Review it and choose again.")).toBeTruthy();
    expect(within(remove).queryByRole("button", { name: "Disconnect" })).toBeNull();
    await user.click(within(remove).getByRole("button", { name: "Disconnect Kobo account" }));
    await user.click(within(remove).getByRole("button", { name: "Disconnect" }));
    expect(await screen.findByRole("heading", { name: "Kobo account disconnected", level: 1 })).toBeTruthy();
    expect(api.called("POST", /\/disconnect$/).map((request) => request.body)).toEqual([{ version: "v1" }, { version: "v2" }]);
  });

  test("someone else's account and a stopped share say so without detail", async () => {
    renderApp({ server: server(null), url: "/sub/preview/account/devices/kobo-accounts/5" });
    expect(await screen.findByRole("heading", { name: "This Kobo account is not connected to your account" })).toBeTruthy();
    cleanup();
    const api = server().on("GET", /\/kobo_catalogues\/6/, () => ({ status: 404, body: { error: "catalogue_not_found" } }));
    renderApp({ server: api, url: "/sub/preview/account/devices/kobo-shared/6" });
    expect(await screen.findByRole("heading", { name: "This Kobo catalogue is not shared with you" })).toBeTruthy();
  });

  test("a shared catalogue opens for its recipient, and its owner is sent to their own account page", async () => {
    const theirs = catalogue({ kobo_account: { id: "6", name: "Sam's books", owner: false, owner_name: "Sam Sharer", connected: false, last_synced_at: null }, more: false, count: 1, books: [catalogue().books[0]!] });
    const api = server().on("GET", /\/kobo_catalogues\/6/, () => ({ body: { account: ACCOUNT, catalogue: theirs } }));
    renderApp({ server: api, url: "/sub/preview/account/devices/kobo-shared/6" });
    expect(await screen.findByRole("heading", { name: "Sam's books", level: 1 })).toBeTruthy();
    expect(screen.getByText("Shared with you by Sam Sharer. They can stop sharing at any time.")).toBeTruthy();
    expect(screen.getByText(/needs to reconnect the Kobo account/)).toBeTruthy();
    expect(screen.getByRole("link", { name: "Can be sent" }).getAttribute("href")).toBe("/sub/preview/account/devices/kobo-shared/6?filter=sendable");
    cleanup();
    const { router } = renderApp({ server: server(), url: "/sub/preview/account/devices/kobo-shared/5?page=2" });
    await waitFor(() => expect(router.state.location.pathname).toBe("/account/devices/kobo-accounts/5"));
    expect(router.state.location.search).toEqual({ page: "2" });
  });

  test("a recipient prepares a private copy, waits for it without overlapping checks, and sends it with the copy it saw", async () => {
    let state: KoboBook = book();
    let reads = 0;
    const api = server()
      .on("GET", /\/kobo_books\/21$/, () => {
        reads += 1;
        return { body: { account: ACCOUNT, book: state } };
      })
      .on("POST", /\/kobo_books\/21\/prepare$/, () => {
        state = book({ copy: { ...book().copy!, preparing: true, explanation: null } });
        return { body: { account: ACCOUNT, book: state, notice: "Preparing a private copy. This usually takes under a minute." } };
      })
      .on("POST", /\/kobo_books\/21\/deliver$/, (request) =>
        (request.body as { copy: string }).copy === "c1"
          ? { status: 409, body: { account: ACCOUNT, error: "copy_changed", message: "This book's private copy changed after the page was shown. Review it and choose again.", book: book({ copy: { ...ready("c2") } }) } }
          : { body: { account: ACCOUNT, notice: "Queued for Clara. Sync that Kobo over Wi-Fi to download it.", book: book({ copy: ready("c2"), readers: [{ id: "3", name: "Clara", status: "Queued · waiting for the reader's next sync", older_copy: false, sent: true }] }) } },
      );
    renderApp({ server: api, url: "/sub/preview/account/devices/kobo-books/21" });
    expect(await screen.findByRole("heading", { name: "A Shared Purchase", level: 1 })).toBeTruthy();
    expect(screen.getByRole("link", { name: /Family purchases/ }).getAttribute("href")).toBe("/sub/preview/account/devices/kobo-shared/5");
    expect(screen.getByTestId("kobo-eligibility").textContent).toBe("DRM-free EPUB · can be sent");
    expect(screen.getByText("You can send it to these readers once the private copy is ready.")).toBeTruthy();
    expect(screen.queryByRole("button", { name: /Send/ })).toBeNull();

    jest.useFakeTimers();
    await act(async () => {
      screen.getByRole("button", { name: "Prepare copy" }).click();
    });
    await until(() => expect(screen.getByText("Preparing a private copy from Kobo… This page updates when it finishes.")).toBeTruthy());
    expect(api.called("POST", /\/prepare$/)[0]!.body).toEqual({ copy: null });
    const before = reads;
    state = book({ copy: ready("c1") });
    await tick(5000);
    await until(() => expect(screen.getByTestId("kobo-copy-status").textContent).toMatch(/^Ready · EPUB3 3\.0, 2 KB, prepared /));
    expect(reads).toBe(before + 1);
    await tick(30000);
    expect(reads).toBe(before + 1);
    await tick();
    jest.useRealTimers();

    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Send to Clara" }));
    expect(await screen.findByText("This book's private copy changed after the page was shown. Review it and choose again.")).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Send to Clara" }));
    expect(await screen.findByText("Queued for Clara. Sync that Kobo over Wi-Fi to download it.")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Send again to Clara" })).toBeTruthy();
    expect(api.called("POST", /\/deliver$/).map((request) => request.body)).toEqual([
      { reader_id: "3", copy: "c1" },
      { reader_id: "3", copy: "c2" },
    ]);
  });
});

function ready(version: string): NonNullable<KoboBook["copy"]> {
  return { version, preparing: false, failure: null, ready: { summary: "EPUB3 3.0, 2 KB", prepared_at: new Date().toISOString(), stale: false }, unavailable: null, explanation: null };
}
