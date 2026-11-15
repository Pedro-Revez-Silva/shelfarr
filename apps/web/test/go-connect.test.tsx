import { describe, expect, test } from "bun:test";
import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { readUserCode } from "../src/go/ConnectPage";
import { ACCOUNT, deferred, FakeServer } from "./helpers";
import { error, libraryServer, renderGo, signedIn, signedOut } from "./go-helpers";

const BASE = ["library:read", "progress:write"];
const REQUESTING = [...BASE, "search:read", "requests:read", "requests:write"];

function grant(overrides: Record<string, unknown> = {}) {
  return { pending: true, decidable: true, client_name: "Ada's Pixel", upgrade: false, requesting: false, scopes: BASE, expires_at: "2026-11-15T12:10:00.000Z", ...overrides };
}

function inspected(value: unknown) {
  return { body: { account: ACCOUNT, account_name: "Ada Reader", grant: value } };
}

function connectServer(initial: unknown = grant()): FakeServer {
  return libraryServer(() => signedIn(ACCOUNT, "session-token")).on("GET", /\/api\/v1\/connect\?/, () => inspected(initial));
}

function open(server: FakeServer, code = "abcd-efgh") {
  return renderGo({ server, view: "connect", url: `/consumer/connect?user_code=${code}` });
}

describe("reading the code from the address", () => {
  test("takes the last value, trims it and bounds it", () => {
    expect(readUserCode("")).toBeNull();
    expect(readUserCode("?user_code=")).toBeNull();
    expect(readUserCode("?user_code=%20%20")).toBeNull();
    expect(readUserCode("?user_code=ABCD&user_code=WXYZ-1234")).toBe("WXYZ-1234");
    expect(readUserCode(`?user_code=${"A".repeat(80)}`)).toBe("A".repeat(32));
  });
});

describe("the native connection consent page", () => {
  test("shows who is connecting, the account, the displayed code and exactly the base permissions, and approves nothing by loading", async () => {
    const server = connectServer();
    open(server);
    const heading = await screen.findByRole("heading", { level: 1, name: "Connect your Shelfarr app" });
    expect(heading).toBeTruthy();
    expect(document.title).toBe("Connect your Shelfarr app · Shelfarr");
    expect(screen.getByText("Ada's Pixel").tagName).toBe("STRONG");
    expect(screen.getByText("Ada Reader")).toBeTruthy();
    expect(screen.getByText("ABCD-EFGH")).toBeTruthy();
    const items = screen.getAllByRole("listitem").map((item) => item.textContent);
    expect(items).toEqual(["Browse and download your library.", "Save your reading and listening progress."]);
    expect(screen.getByRole("button", { name: "Connect app" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Deny" })).toBeTruthy();
    expect(screen.getByText(/Only approve a connection you started yourself/)).toBeTruthy();
    expect(server.called("GET", /\/connect\?user_code=abcd-efgh$/)).toHaveLength(1);
    expect(server.requests.filter((request) => request.method !== "GET")).toHaveLength(0);
    expect(server.called("GET", /\/connect/)[0]?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
  });

  test("a fresh connection that also asks to request books says so and lists every offered permission", async () => {
    open(connectServer(grant({ requesting: true, scopes: REQUESTING })));
    await screen.findByRole("heading", { name: "Connect your Shelfarr app" });
    const items = screen.getAllByRole("listitem").map((item) => item.textContent ?? "");
    expect(items).toHaveLength(5);
    expect(items.some((text) => text.startsWith("Request ebooks and audiobooks for you."))).toBe(true);
    expect(screen.getByRole("button", { name: "Connect and allow requesting" })).toBeTruthy();
    expect(screen.getByText(/cannot see other people's requests/)).toBeTruthy();
  });

  test("an upgrade of an existing connection has its own wording and a Not now that keeps access", async () => {
    open(connectServer(grant({ upgrade: true, requesting: true, scopes: REQUESTING })));
    await screen.findByRole("heading", { name: "Allow requesting from your app" });
    expect(screen.getByText(/already connected as/)).toBeTruthy();
    expect(screen.getByRole("button", { name: "Allow requesting" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Not now" })).toBeTruthy();
    expect(screen.getByText(/keeps its current read-and-listen access/)).toBeTruthy();
  });

  test("an unknown scope is shown by its name instead of being hidden", async () => {
    open(connectServer(grant({ scopes: [...BASE, "reports:read"] })));
    await screen.findByRole("heading", { name: "Connect your Shelfarr app" });
    expect(screen.getAllByRole("listitem").map((item) => item.textContent)).toContain("Use the “reports:read” permission.");
  });

  test("Allow sends one decision for any number of clicks and Enter presses, then shows a terminal state without the code", async () => {
    const gate = deferred<void>();
    const server = connectServer().on("POST", /\/api\/v1\/connect$/, async () => {
      await gate.promise;
      return { body: { account: ACCOUNT, decision: "allowed", upgrade: false, requesting: false } };
    });
    open(server);
    const allow = await screen.findByRole("button", { name: "Connect app" });
    const user = userEvent.setup();
    await user.dblClick(allow);
    await user.keyboard("{Enter}");
    await waitFor(() => expect(server.called("POST", /\/connect$/)).toHaveLength(1));
    expect(allow.hasAttribute("disabled")).toBe(true);
    gate.resolve();
    await screen.findByRole("heading", { name: "App connected" });
    expect(server.called("POST", /\/connect$/)).toHaveLength(1);
    const post = server.called("POST", /\/connect$/)[0];
    expect(post?.body).toEqual({ user_code: "abcd-efgh", decision: "allow" });
    expect(post?.headers["x-csrf-token"]).toBe("session-token");
    expect(post?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(screen.getByText("Return to the Shelfarr app to open your library.")).toBeTruthy();
    expect(screen.queryByRole("button")).toBeNull();
    expect(window.location.search).toBe("");
  });

  test("two decision events in one tick still send one request", async () => {
    const gate = deferred<void>();
    const server = connectServer().on("POST", /\/api\/v1\/connect$/, async () => {
      await gate.promise;
      return { body: { account: ACCOUNT, decision: "allowed", upgrade: false, requesting: false } };
    });
    open(server);
    const allow = await screen.findByRole("button", { name: "Connect app" });
    const deny = screen.getByRole("button", { name: "Deny" });
    act(() => {
      allow.click();
      allow.click();
      deny.click();
    });
    await waitFor(() => expect(server.called("POST", /\/connect$/)).toHaveLength(1));
    gate.resolve();
    await screen.findByRole("heading", { name: "App connected" });
    expect(server.called("POST", /\/connect$/)).toHaveLength(1);
    expect(server.called("POST", /\/connect$/)[0]?.body).toEqual({ user_code: "abcd-efgh", decision: "allow" });
  });

  test("a malformed answer that names the app of another account's code is still not decidable", async () => {
    open(connectServer({ pending: true, decidable: false, client_name: "Leaked App", scopes: BASE }));
    await screen.findByRole("heading", { name: "Different account" });
    expect(screen.queryByText("Leaked App")).toBeNull();
    expect(screen.queryByRole("button", { name: /Connect|Allow|Deny/ })).toBeNull();
  });

  test("a decision that completes after the page moved on to another code never changes that code's screen", async () => {
    const gate = deferred<void>();
    const server = libraryServer(() => signedIn(ACCOUNT, "session-token"))
      .on("GET", /\/api\/v1\/connect\?user_code=aaaa-aaaa$/, () => inspected(grant({ client_name: "App A" })))
      .on("GET", /\/api\/v1\/connect\?user_code=bbbb-bbbb$/, () => inspected(grant({ client_name: "App B" })))
      .on("POST", /\/api\/v1\/connect$/, async () => {
        await gate.promise;
        return { body: { account: ACCOUNT, decision: "allowed", upgrade: false, requesting: false } };
      });
    open(server, "aaaa-aaaa");
    await userEvent.setup().click(await screen.findByRole("button", { name: "Connect app" }));
    await waitFor(() => expect(server.called("POST", /\/connect$/)).toHaveLength(1));
    act(() => {
      window.history.pushState(null, "", "/consumer/connect?user_code=bbbb-bbbb");
      window.dispatchEvent(new PopStateEvent("popstate"));
    });
    await screen.findByText("App B");
    gate.resolve();
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(screen.getByText("App B")).toBeTruthy();
    expect(screen.queryByRole("heading", { name: "App connected" })).toBeNull();
    expect(window.location.search).toBe("?user_code=bbbb-bbbb");
    expect(screen.getByRole("button", { name: "Connect app" }).hasAttribute("disabled")).toBe(false);
    expect(server.called("POST", /\/connect$/)).toHaveLength(1);
  });

  test("Not now is a deliberate, separate decision", async () => {
    const server = connectServer(grant({ upgrade: true, requesting: true, scopes: REQUESTING })).on("POST", /\/api\/v1\/connect$/, () => ({ body: { account: ACCOUNT, decision: "denied", upgrade: true, requesting: true } }));
    open(server);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Not now" }));
    await screen.findByRole("heading", { name: "Requesting not allowed" });
    expect(server.called("POST", /\/connect$/)[0]?.body).toEqual({ user_code: "abcd-efgh", decision: "deny" });
  });

  test("an unknown, used or expired code is a clear dead end with a way to try another", async () => {
    open(connectServer(null));
    await screen.findByRole("heading", { name: "This code cannot be used" });
    expect(screen.getByText(/expired or has already been used/)).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Connect app" })).toBeNull();
    expect(screen.getByLabelText("Connection code")).toBeTruthy();
  });

  test("a code that belongs to another account reveals nothing about the app and changes nothing", async () => {
    const server = connectServer({ pending: true, decidable: false });
    open(server);
    await screen.findByRole("heading", { name: "Different account" });
    expect(screen.getByText(/can't approve it/)).toBeTruthy();
    expect(screen.queryByRole("button", { name: /Connect|Allow|Deny|Not now/ })).toBeNull();
    expect(screen.queryByText("Ada's Pixel")).toBeNull();
    expect(server.requests.filter((request) => request.method !== "GET")).toHaveLength(0);
  });

  test("switching account signs out, signs in as the owner and checks the same code again", async () => {
    let authenticated = true;
    let who = ACCOUNT;
    const server = new FakeServer()
      .on("GET", /\/auth\/bootstrap$/, () => ({ body: authenticated ? signedIn(who) : signedOut() }))
      .on("GET", /\/api\/v1\/session$/, () => ({ body: { account: { id: who, name: "N" }, server: { name: "s", version: "1" }, links: { legacy_library: "/read", discover: "/search", requests: "/requests", account: "/profile" } } }))
      .on("GET", /\/api\/v1\/connect\?/, () => ({ body: { account: who, account_name: who === ACCOUNT ? "Ada Reader" : "Grace Owner", grant: who === ACCOUNT ? { pending: true, decidable: false } : grant() } }))
      .on("POST", /\/auth\/logout$/, () => {
        authenticated = false;
        return { body: { authenticated: false } };
      })
      .on("POST", /\/auth\/login$/, () => {
        authenticated = true;
        who = "77";
        return { body: signedIn("77", "owner-token") };
      });
    open(server);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Sign out and switch account" }));
    expect(screen.queryByText("Ada Reader")).toBeNull();
    await user.type(await screen.findByLabelText("Username"), "grace");
    await user.type(screen.getByLabelText("Password"), "pw");
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    expect(await screen.findByText("Grace Owner")).toBeTruthy();
    expect(screen.getByText("Ada's Pixel")).toBeTruthy();
    expect(window.location.search).toBe("?user_code=abcd-efgh");
    expect(server.requests.filter((request) => request.method === "POST").map((request) => request.path)).toEqual(["/preview/api/v1/auth/logout", "/preview/api/v1/auth/login"]);
  });

  test("a different-account answer to Allow ends in the same safe state", async () => {
    const server = connectServer().on("POST", /\/api\/v1\/connect$/, () => error(403, "different_account"));
    open(server);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Connect app" }));
    await screen.findByRole("heading", { name: "Different account" });
  });

  test("a code used meanwhile is reported as used, not as success", async () => {
    const server = connectServer().on("POST", /\/api\/v1\/connect$/, () => error(422, "invalid_grant"));
    open(server);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Connect app" }));
    await screen.findByRole("heading", { name: "This code cannot be used" });
  });

  test("an uncertain answer never resends; the account can only check the status", async () => {
    const server = connectServer().on("POST", /\/api\/v1\/connect$/, () => error(500, "internal_error"));
    open(server);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Connect app" }));
    const alert = await screen.findByText(/could not confirm whether your choice reached the server/);
    expect(alert.closest("[role=alert]")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Connect app" })).toBeNull();
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(server.called("POST", /\/connect$/)).toHaveLength(1);
    await user.click(screen.getByRole("button", { name: "Check the code's status" }));
    await screen.findByRole("button", { name: "Connect app" });
    expect(server.called("POST", /\/connect$/)).toHaveLength(1);
    expect(server.called("GET", /\/connect\?/)).toHaveLength(2);
  });

  test("a rejected page token refreshes and rechecks the code, and does not resend the decision", async () => {
    let tokens = 0;
    const server = connectServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: signedIn(ACCOUNT, `t${++tokens}`) })).on("POST", /\/api\/v1\/connect$/, () => error(422, "invalid_csrf"));
    open(server);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Connect app" }));
    await screen.findByText(/out of date and has been refreshed/);
    expect(server.called("POST", /\/connect$/)).toHaveLength(1);
    expect(screen.getByRole("button", { name: "Connect app" })).toBeTruthy();
  });

  test("without a code it asks for one and opens it through the address, never through a form post", async () => {
    const server = connectServer();
    renderGo({ server, view: "connect", url: "/consumer/connect" });
    const field = await screen.findByLabelText("Connection code");
    expect(field.getAttribute("autocomplete")).toBe("off");
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Check code" }));
    expect(server.called("GET", /\/connect\?/)).toHaveLength(0);
    await user.type(field, "wxyz-1234{Enter}");
    await screen.findByRole("heading", { name: "Connect your Shelfarr app" });
    expect(window.location.search).toBe("?user_code=wxyz-1234");
    expect(server.called("GET", /\/connect\?user_code=wxyz-1234$/)).toHaveLength(1);
    expect(within(screen.getByRole("main")).queryAllByRole("link")).toHaveLength(0);
  });

  test("a check that cannot reach the server offers a retry that only reads", async () => {
    const server = connectServer().on("GET", /\/api\/v1\/connect\?/, () => error(503, "database_busy"));
    open(server);
    await screen.findByRole("heading", { name: "Could not check the code" });
    await userEvent.setup().click(screen.getByRole("button", { name: "Try again" }));
    await waitFor(() => expect(server.called("GET", /\/connect\?/)).toHaveLength(2));
    expect(server.requests.filter((request) => request.method === "POST")).toHaveLength(0);
  });
});
