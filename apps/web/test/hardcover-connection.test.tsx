import { afterEach, beforeEach, describe, expect, jest, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { AccountSettings, Profile } from "../src/contract";
import { hardcoverAuthorizationSchema, hardcoverEnvelopeSchema, hardcoverRefusalSchema, type HardcoverConnection, type HardcoverState } from "../src/connections/hardcover/contract";
import { external } from "../src/connections/hardcover/queries";
import { ACCOUNT, deferred, renderApp, standardServer, type FakeServer } from "./helpers";

const originalOpen = external.open;

let fakeTimers = false;

function useFakeTimers() {
  fakeTimers = true;
  jest.useFakeTimers();
}

afterEach(async () => {
  cleanup();
  if (fakeTimers) await tick(1_000);
  fakeTimers = false;
  jest.useRealTimers();
  external.open = originalOpen;
});

beforeEach(() => {
  window.scrollTo = () => undefined;
});

function settings(admin = false): AccountSettings {
  return {
    admin,
    member_since: "2026-01-02T10:00:00.000Z",
    requests: { total: 0, completed: 0, pending: 0 },
    two_factor: { enabled: false },
    oidc: { configured: false, provider: null, linked: false, link_page: null, password_required: true },
    api_tokens: [],
    token_scopes: [],
    links: { kobo_readers: "/sub/kobo_devices", kobo_accounts: "/sub/kobo_accounts", hardcover: "/sub/profile#hardcover", sign_out: "/sub/session", phone_app: "/sub/consumer/connect", reading_library: "/sub/read" },
    server: { release: "Shelfarr 1.0 beta", beta: true, series: "1.0" },
  };
}

const KEY_PAGE = "https://hardcover.app/account/api/keys/new?scope=read:me:content+read:library+read:lists+read:catalog";
const SOON = new Date(Date.now() + 14 * 60_000).toISOString();

function connection(overrides: Partial<HardcoverConnection> = {}): HardcoverConnection {
  return { version: "3-4242", username: "reader", profile_url: "https://hardcover.app/@reader", method: "sign_in", state: "active", problem: null, ...overrides };
}

function state(overrides: Partial<HardcoverState> = {}): HardcoverState {
  return {
    enabled: true,
    methods: { sign_in: true, code: true, api_key: true },
    connection: null,
    device: null,
    outcome: null,
    links: { following: "/sub/hardcover/subscriptions", api_key_page: KEY_PAGE },
    ...overrides,
  };
}

const DEVICE = { user_code: "ABCD-1234", verification_uri: "https://hardcover.app/link", verification_uri_complete: "https://hardcover.app/link?code=ABCD-1234", expires_at: SOON, interval: 5 };

type Live = { state: HardcoverState };

function server(live: Live, admin = false): FakeServer {
  const profile: Profile = { id: ACCOUNT, username: "rae", name: "Rae Reader", settings: settings(admin) };
  return standardServer()
    .on("GET", /\/api\/v1\/account$/, () => ({ body: { account: ACCOUNT, profile } }))
    .on("GET", /\/account\/hardcover$/, () => {
      const current = live.state;
      live.state = { ...current, outcome: null };
      return { body: { account: ACCOUNT, hardcover: current } };
    });
}

function change(live: Live, next: HardcoverState, extra: Record<string, unknown> = {}, status = 200) {
  live.state = next;
  return { status, body: { account: ACCOUNT, hardcover: next, ...extra } };
}

async function card(): Promise<HTMLElement> {
  return (await screen.findByRole("heading", { name: "Hardcover", level: 2 })).closest("section") as HTMLElement;
}

async function tick(ms = 0) {
  await act(async () => {
    jest.advanceTimersByTime(ms);
    for (let round = 0; round < 20; round += 1) await Promise.resolve();
  });
}

async function until<T>(check: () => T): Promise<T> {
  for (let round = 0; ; round += 1) {
    try {
      return check();
    } catch (error) {
      if (round >= 400) throw error;
      await tick();
    }
  }
}

async function press(element: HTMLElement | Promise<HTMLElement>) {
  const target = await element;
  await act(async () => {
    target.click();
  });
}

function cardNow(): HTMLElement {
  return screen.getByRole("heading", { name: "Hardcover", level: 2 }).closest("section") as HTMLElement;
}

describe("Hardcover in Account ▸ Connections", () => {
  test("the contract accepts only Hardcover pages for every outside address", () => {
    const evil = ["blob:https://hardcover.app/0b6e", "https://hardcover.app.evil.example/x", "http://hardcover.app/x", "https://user@hardcover.app/x", "https://evil.example/@reader", "javascript:alert(1)", "//hardcover.app/x"];
    expect(hardcoverEnvelopeSchema.safeParse({ account: ACCOUNT, hardcover: state({ connection: connection(), device: DEVICE }) }).success).toBe(true);
    expect(hardcoverAuthorizationSchema.safeParse({ account: ACCOUNT, authorization_url: "https://hardcover.app/oauth2/authorize?state=preview-x" }).success).toBe(true);
    expect(hardcoverAuthorizationSchema.safeParse({ account: ACCOUNT, authorization_url: "https://api.hardcover.app/oauth2/authorize?state=preview-x" }).success).toBe(true);
    for (const address of evil) {
      expect(hardcoverAuthorizationSchema.safeParse({ account: ACCOUNT, authorization_url: address }).success).toBe(false);
      expect(hardcoverEnvelopeSchema.safeParse({ account: ACCOUNT, hardcover: state({ connection: connection({ profile_url: address }) }) }).success).toBe(false);
      expect(hardcoverEnvelopeSchema.safeParse({ account: ACCOUNT, hardcover: state({ device: { ...DEVICE, verification_uri: address } }) }).success).toBe(false);
      expect(hardcoverEnvelopeSchema.safeParse({ account: ACCOUNT, hardcover: state({ links: { following: "/sub/hardcover/subscriptions", api_key_page: address } }) }).success).toBe(false);
    }
    for (const following of ["https://evil.example/follow", "//evil.example/follow", "/\\evil.example/follow", "/\t/evil.example/follow", "/\n/evil.example/follow", "hardcover/subscriptions"]) {
      expect(hardcoverEnvelopeSchema.safeParse({ account: ACCOUNT, hardcover: state({ links: { following } }) }).success).toBe(false);
    }
    expect(hardcoverRefusalSchema.safeParse({ account: ACCOUNT, error: "hardcover_changed", message: "Changed", hardcover: state() }).success).toBe(true);
  });

  test("connecting with an API key sends it once, never keeps it, and shows the connected account with its Following link", async () => {
    const live: Live = { state: state() };
    const api = server(live).on("POST", /\/account\/hardcover\/api_key$/, () =>
      change(live, state({ connection: connection({ version: "3-77", username: "pat_user", profile_url: "https://hardcover.app/@pat_user", method: "api_key" }) }), { notice: "Connected Hardcover account @pat_user." }),
    );
    const { services } = renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await card();
    await within(hardcover).findByRole("button", { name: "Sign in with Hardcover" });
    expect(within(hardcover).getByRole("button", { name: "Sign in with a code" })).toBeTruthy();
    expect(document.querySelector('a[href="/sub/profile#hardcover"]')).toBeNull();
    const keyLink = within(hardcover).getByRole("link", { name: /Create a Hardcover API key/ });
    expect([keyLink.getAttribute("href"), keyLink.getAttribute("target"), keyLink.getAttribute("rel")]).toEqual([KEY_PAGE, "_blank", "noopener noreferrer"]);

    const user = userEvent.setup();
    await user.click(within(hardcover).getByText("Connect with a personal API key"));
    const field = within(hardcover).getByLabelText("Hardcover API key") as HTMLInputElement;
    expect([field.type, field.autocomplete]).toEqual(["password", "off"]);
    await user.click(within(hardcover).getByRole("button", { name: "Connect" }));
    expect(within(hardcover).getByText("Paste a Hardcover API key to connect.")).toBeTruthy();
    expect(document.activeElement).toBe(field);
    expect(api.called("POST", /api_key$/)).toHaveLength(0);

    await user.type(field, "  hc_pat_synthetic  ");
    await user.click(within(hardcover).getByRole("button", { name: "Connect" }));
    expect(await within(hardcover).findByText("Connected Hardcover account @pat_user.")).toBeTruthy();
    const posted = api.called("POST", /api_key$/)[0]!;
    expect(posted.body).toEqual({ api_key: "hc_pat_synthetic", version: null });
    expect([posted.headers["x-shelfarr-account"], posted.headers["x-csrf-token"]]).toEqual([ACCOUNT, "token-123"]);
    const profileLink = within(hardcover).getByRole("link", { name: /@pat_user/ });
    expect([profileLink.getAttribute("href"), profileLink.getAttribute("rel")]).toEqual(["https://hardcover.app/@pat_user", "noopener noreferrer"]);
    expect(within(hardcover).getByText("Personal API key")).toBeTruthy();
    expect(within(hardcover).getByRole("link", { name: "Following and reading lists" }).getAttribute("href")).toBe("/sub/hardcover/subscriptions");
    expect(within(hardcover).queryByLabelText("Hardcover API key")).toBeNull();
    expect(JSON.stringify(services.queryClient.getQueryCache().getAll().map((query) => query.state.data))).not.toContain("hc_pat_synthetic");
    expect(JSON.stringify(services.queryClient.getMutationCache().getAll().map((mutation) => mutation.state))).not.toContain("hc_pat_synthetic");
  });

  test("a refused key says why and keeps the card on the server's state", async () => {
    const live: Live = { state: state() };
    const api = server(live).on("POST", /\/account\/hardcover\/api_key$/, () =>
      change(live, state(), { error: "hardcover_refused", message: "Hardcover rejected that key. Check that it is current and has not been revoked." }, 422),
    );
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await card();
    const user = userEvent.setup();
    await within(hardcover).findByRole("button", { name: "Sign in with Hardcover" });
    await user.click(within(hardcover).getByText("Connect with a personal API key"));
    const field = within(hardcover).getByLabelText("Hardcover API key") as HTMLInputElement;
    await user.type(field, "wrong");
    await user.click(within(hardcover).getByRole("button", { name: "Connect" }));
    expect(await within(hardcover).findByText("Hardcover rejected that key. Check that it is current and has not been revoked.")).toBeTruthy();
    expect(field.value).toBe("");
    expect(within(hardcover).getByText("No Hardcover account is connected.")).toBeTruthy();
  });

  test("a page that is out of date shows the connection made elsewhere instead of replacing it", async () => {
    const live: Live = { state: state() };
    const other = state({ connection: connection({ username: "elsewhere", profile_url: "https://hardcover.app/@elsewhere" }) });
    const api = server(live).on("POST", /\/account\/hardcover\/device$/, () =>
      change(live, other, { error: "hardcover_changed", message: "Your Hardcover connection changed after this page was shown. Review it and try again." }, 409),
    );
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await card();
    await userEvent.setup().click(await within(hardcover).findByRole("button", { name: "Sign in with a code" }));
    expect(await within(hardcover).findByText("Your Hardcover connection changed after this page was shown. Review it and try again.")).toBeTruthy();
    expect(within(hardcover).getByRole("link", { name: /@elsewhere/ })).toBeTruthy();
    expect(within(hardcover).queryByRole("button", { name: "Sign in with a code" })).toBeNull();
    expect(api.called("POST", /device$/)[0]!.body).toEqual({ version: null });
  });

  test("Hardcover sign-in opens only a Hardcover address and passes the connection the page showed", async () => {
    const opened: string[] = [];
    external.open = (url) => {
      opened.push(url);
      return true;
    };
    const live: Live = { state: state({ connection: connection({ state: "needs_reconnecting", problem: "Hardcover rejected the refresh token" }) }) };
    let address = "https://hardcover.app/oauth2/authorize?state=preview-abc&code_challenge=xyz";
    const api = server(live).on("POST", /\/account\/hardcover\/authorize$/, () => ({ body: { account: ACCOUNT, authorization_url: address } }));
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await card();
    expect(await within(hardcover).findByText("Hardcover rejected the refresh token")).toBeTruthy();
    expect(within(hardcover).getByText("Needs reconnecting")).toBeTruthy();
    const user = userEvent.setup();
    await user.click(within(hardcover).getByRole("button", { name: "Sign in with Hardcover" }));
    await waitFor(() => expect(opened).toEqual([address]));
    expect(api.called("POST", /authorize$/)[0]!.body).toEqual({ version: "3-4242" });
    expect(await within(hardcover).findByRole("button", { name: "Opening Hardcover…" })).toBeTruthy();
    act(() => {
      window.dispatchEvent(Object.assign(new Event("pageshow"), { persisted: true }));
    });
    expect(await within(hardcover).findByRole("button", { name: "Sign in with Hardcover" })).toBeTruthy();

    address = "https://evil.example/oauth2/authorize";
    await user.click(within(hardcover).getByRole("button", { name: "Sign in with Hardcover" }));
    expect(await within(hardcover).findByText("Shelfarr could not start Hardcover sign-in. Try again.")).toBeTruthy();
    expect(opened).toHaveLength(1);
  });

  test("a validated address is followed without a referrer", () => {
    const clicks: { href: string; rel: string; policy: string }[] = [];
    const click = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function (this: HTMLAnchorElement) {
      clicks.push({ href: this.href, rel: this.rel, policy: this.referrerPolicy });
    };
    try {
      expect(external.open("https://evil.example/x")).toBe(false);
      expect(external.open("https://hardcover.app/oauth2/authorize?state=preview-a")).toBe(true);
    } finally {
      HTMLAnchorElement.prototype.click = click;
    }
    expect(clicks).toEqual([{ href: "https://hardcover.app/oauth2/authorize?state=preview-a", rel: "noreferrer", policy: "no-referrer" }]);
  });

  test("coming back from Hardcover focuses the card and says what happened once", async () => {
    const live: Live = { state: state({ connection: connection(), outcome: { tone: "success", message: "Connected Hardcover account @reader." } }) };
    const api = server(live);
    const { services } = renderApp({ server: api, url: "/sub/preview/account/connections#hardcover" });
    const hardcover = await card();
    expect(await within(hardcover).findByText("Connected Hardcover account @reader.")).toBeTruthy();
    await waitFor(() => expect(document.activeElement).toBe(hardcover));
    await act(async () => {
      await services.queryClient.invalidateQueries();
    });
    await waitFor(() => expect(api.called("GET", /\/account\/hardcover$/).length).toBeGreaterThan(1));
    expect(within(hardcover).getByText("Connected Hardcover account @reader.")).toBeTruthy();
    expect(within(hardcover).getByRole("button", { name: "Disconnect Hardcover" })).toBeTruthy();
  });

  test("a sign-in code is shown, checked at Hardcover's interval one request at a time, and ends connected", async () => {
    useFakeTimers();
    const live: Live = { state: state() };
    const answer = deferred<{ body: unknown }>();
    let polls = 0;
    const api = server(live)
      .on("POST", /\/account\/hardcover\/device$/, () => change(live, state({ device: DEVICE })))
      .on("POST", /\/account\/hardcover\/device\/poll$/, () => {
        polls += 1;
        if (polls === 1) return { body: { account: ACCOUNT, status: "pending", hardcover: live.state } };
        return answer.promise;
      });
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await until(cardNow);
    await press(await until(() => within(hardcover).getByRole("button", { name: "Sign in with a code" })));
    expect(await until(() => within(hardcover).getByText("ABCD-1234"))).toBeTruthy();
    const link = within(hardcover).getByRole("link", { name: /hardcover\.app\/link/ });
    expect([link.getAttribute("href"), link.getAttribute("rel"), link.getAttribute("target")]).toEqual(["https://hardcover.app/link?code=ABCD-1234", "noopener noreferrer", "_blank"]);
    expect(within(hardcover).queryByRole("button", { name: "Sign in with Hardcover" })).toBeNull();
    expect(within(hardcover).getByText("Waiting for approval on Hardcover…")).toBeTruthy();

    await tick(4_900);
    expect(polls).toBe(0);
    await tick(200);
    expect(polls).toBe(1);
    await tick(5_100);
    expect(polls).toBe(2);
    await tick(20_000);
    expect(polls).toBe(2);
    const connected = state({ connection: connection() });
    live.state = connected;
    answer.resolve({ body: { account: ACCOUNT, status: "approved", message: "Connected Hardcover account @reader.", hardcover: connected } });
    await tick();
    expect(within(hardcover).getByText("Connected Hardcover account @reader.")).toBeTruthy();
    expect(within(hardcover).queryByText("ABCD-1234")).toBeNull();
    await tick(30_000);
    expect(polls).toBe(2);
  });

  test("a code that expires or is declined says so and offers the ways to connect again; Cancel ends it", async () => {
    useFakeTimers();
    const live: Live = { state: state({ device: DEVICE }) };
    const api = server(live)
      .on("POST", /\/account\/hardcover\/device\/poll$/, () => ({ body: { account: ACCOUNT, status: "failed", message: "The sign-in code expired. Start again.", hardcover: (live.state = state()) } }))
      .on("POST", /\/account\/hardcover\/device$/, () => change(live, state({ device: { ...DEVICE, user_code: "WXYZ-9876" } })))
      .on("POST", /\/account\/hardcover\/device\/cancel$/, () => change(live, state()));
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await until(cardNow);
    expect(await until(() => within(hardcover).getByText("ABCD-1234"))).toBeTruthy();
    await tick(5_100);
    expect(within(hardcover).getByText("The sign-in code expired. Start again.")).toBeTruthy();
    await press(within(hardcover).getByRole("button", { name: "Sign in with a code" }));
    expect(await until(() => within(hardcover).getByText("WXYZ-9876"))).toBeTruthy();
    await press(within(hardcover).getByRole("button", { name: "Cancel" }));
    expect(await until(() => within(hardcover).getByRole("button", { name: "Sign in with Hardcover" }))).toBeTruthy();
    expect(api.called("POST", /device\/cancel$/)).toHaveLength(1);
    await tick(30_000);
    expect(api.called("POST", /device\/poll$/)).toHaveLength(1);
  });

  test("a code check waits while another change to the connection is being saved", async () => {
    useFakeTimers();
    const live: Live = { state: state({ device: DEVICE }) };
    const cancelled = deferred<{ body: unknown }>();
    const api = server(live)
      .on("POST", /\/account\/hardcover\/device\/poll$/, () => ({ body: { account: ACCOUNT, status: "pending", hardcover: live.state } }))
      .on("POST", /\/account\/hardcover\/device\/cancel$/, () => cancelled.promise);
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await until(cardNow);
    await until(() => within(hardcover).getByText("ABCD-1234"));
    await press(within(hardcover).getByRole("button", { name: "Cancel" }));
    await tick(5_100);
    await tick(5_100);
    expect(api.called("POST", /device\/poll$/)).toHaveLength(0);
    live.state = state();
    cancelled.resolve({ body: { account: ACCOUNT, hardcover: live.state } });
    await until(() => {
      if (within(hardcover).queryByText("ABCD-1234")) throw new Error("The code is still shown");
    });
    await tick(30_000);
    expect(api.called("POST", /device\/poll$/)).toHaveLength(0);
  });

  test("while a code is being checked nothing else can change the connection, and the card waits as long as Hardcover asks", async () => {
    useFakeTimers();
    const live: Live = { state: state({ device: { ...DEVICE, interval: 10 } }) };
    const checked = deferred<{ body: unknown }>();
    const api = server(live)
      .on("POST", /\/account\/hardcover\/device\/poll$/, () => checked.promise)
      .on("POST", /\/account\/hardcover\/device\/cancel$/, () => change(live, state()));
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await until(cardNow);
    await until(() => within(hardcover).getByText("ABCD-1234"));
    await tick(9_900);
    expect(api.called("POST", /device\/poll$/)).toHaveLength(0);
    await tick(200);
    expect(api.called("POST", /device\/poll$/)).toHaveLength(1);
    const cancel = within(hardcover).getByRole("button", { name: "Cancel" });
    expect(cancel.getAttribute("aria-disabled")).toBe("true");
    await press(cancel);
    expect(api.called("POST", /device\/cancel$/)).toHaveLength(0);
    checked.resolve({ body: { account: ACCOUNT, status: "pending", hardcover: live.state } });
    await until(() => expect(within(hardcover).getByRole("button", { name: "Cancel" }).getAttribute("aria-disabled")).toBeNull());
    await press(within(hardcover).getByRole("button", { name: "Cancel" }));
    await until(() => within(hardcover).getByRole("button", { name: "Sign in with Hardcover" }));
    expect(api.called("POST", /device\/cancel$/)).toHaveLength(1);
  });

  test("Cancel pressed in the instant a code check starts sends nothing until the check ends", async () => {
    useFakeTimers();
    const live: Live = { state: state({ device: DEVICE }) };
    const checked = deferred<{ body: unknown }>();
    const api = server(live)
      .on("POST", /\/account\/hardcover\/device\/poll$/, () => checked.promise)
      .on("POST", /\/account\/hardcover\/device\/cancel$/, () => change(live, state()));
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await until(cardNow);
    await until(() => within(hardcover).getByText("ABCD-1234"));
    const cancel = within(hardcover).getByRole("button", { name: "Cancel" });
    jest.advanceTimersByTime(5_100);
    cancel.click();
    expect(cancel.getAttribute("aria-disabled")).toBeNull();
    await tick();
    expect(api.called("POST", /device\/poll$/)).toHaveLength(1);
    expect(api.called("POST", /device\/cancel$/)).toHaveLength(0);
    checked.resolve({ body: { account: ACCOUNT, status: "pending", hardcover: live.state } });
    await until(() => expect(within(hardcover).getByRole("button", { name: "Cancel" }).getAttribute("aria-disabled")).toBeNull());
  });

  test("disconnect asks first, sends the connection the page showed and keeps a newer one", async () => {
    const live: Live = { state: state({ connection: connection() }) };
    let refuse = true;
    const api = server(live).on("POST", /\/account\/hardcover\/disconnect$/, () => {
      if (refuse) {
        refuse = false;
        return change(live, state({ connection: connection({ version: "3-77", username: "second", profile_url: "https://hardcover.app/@second" }) }), { error: "hardcover_changed", message: "Your Hardcover connection changed after this page was shown. Review it and try again." }, 409);
      }
      return change(live, state(), { notice: "Hardcover account disconnected. Requests already created were kept." });
    });
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await card();
    const user = userEvent.setup();
    await user.click(await within(hardcover).findByRole("button", { name: "Disconnect Hardcover" }));
    expect(within(hardcover).getByText("Disconnect Hardcover? Want to Read automation stops. Requests already created are kept.")).toBeTruthy();
    await user.click(within(hardcover).getByRole("button", { name: "Disconnect" }));
    expect(await within(hardcover).findByText("Your Hardcover connection changed after this page was shown. Review it and try again.")).toBeTruthy();
    expect(within(hardcover).getByRole("link", { name: /@second/ })).toBeTruthy();
    expect(api.called("POST", /disconnect$/)[0]!.body).toEqual({ version: "3-4242" });

    await user.click(within(hardcover).getByRole("button", { name: "Disconnect Hardcover" }));
    await user.click(within(hardcover).getByRole("button", { name: "Disconnect" }));
    expect(await within(hardcover).findByText("Hardcover account disconnected. Requests already created were kept.")).toBeTruthy();
    expect(api.called("POST", /disconnect$/)[1]!.body).toEqual({ version: "3-77" });
    expect(within(hardcover).getByText("No Hardcover account is connected.")).toBeTruthy();
    expect(within(hardcover).getByRole("button", { name: "Sign in with Hardcover" })).toBeTruthy();
    await waitFor(() => expect(document.activeElement?.textContent).toBe("Hardcover"));
  });

  test("a server that turns Hardcover or connections off says so, with the settings link only for an administrator", async () => {
    const live: Live = { state: state({ enabled: false, methods: { sign_in: false, code: false, api_key: false }, links: { following: "/sub/hardcover/subscriptions" } }) };
    renderApp({ server: server(live), url: "/sub/preview/account/connections" });
    let hardcover = await card();
    expect(await within(hardcover).findByText("Hardcover is disabled on this Shelfarr instance.")).toBeTruthy();
    expect(within(hardcover).queryAllByRole("button")).toHaveLength(0);
    cleanup();

    live.state = state({ enabled: true, methods: { sign_in: false, code: false, api_key: false }, links: { following: "/sub/hardcover/subscriptions" } });
    renderApp({ server: server(live), url: "/sub/preview/account/connections" });
    hardcover = await card();
    expect(await within(hardcover).findByText("An administrator has not enabled Hardcover account connections yet.")).toBeTruthy();
    expect(within(hardcover).queryByRole("link", { name: /Server/ })).toBeNull();
    cleanup();

    renderApp({ server: server(live, true), url: "/sub/preview/account/connections" });
    hardcover = await card();
    const settingsLink = await within(hardcover).findByRole("link", { name: "Server ▸ Catalogues and sources" });
    expect(settingsLink.getAttribute("href")).toBe("/sub/preview/server/sources#hardcover_accounts");
    cleanup();

    live.state = state({ methods: { sign_in: false, code: false, api_key: true } });
    renderApp({ server: server(live), url: "/sub/preview/account/connections" });
    hardcover = await card();
    expect(await within(hardcover).findByLabelText("Hardcover API key")).toBeTruthy();
    expect((hardcover.querySelector("details") as HTMLDetailsElement).open).toBe(true);
    expect(within(hardcover).queryByRole("button", { name: "Sign in with Hardcover" })).toBeNull();
  });

  test("an answer for another account locks the page and changes nothing", async () => {
    const live: Live = { state: state() };
    const api = server(live).on("POST", /\/account\/hardcover\/device$/, () => ({ body: { account: "99", hardcover: state({ device: DEVICE }) } }));
    renderApp({ server: api, url: "/sub/preview/account/connections" });
    const hardcover = await card();
    await userEvent.setup().click(await within(hardcover).findByRole("button", { name: "Sign in with a code" }));
    await waitFor(() => expect(screen.queryByText("ABCD-1234")).toBeNull());
    expect(await screen.findByRole("heading", { name: "The signed-in account changed" })).toBeTruthy();
  });
});
