import { describe, expect, test } from "bun:test";
import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { bootstrapSchema, goBootSchema } from "../src/contract";
import { readStartup, BootError } from "../src/boot";
import { ACCOUNT, deferred, detail, session, summary } from "./helpers";
import { error, goBoot, libraryServer, renderGo, signedIn, signedOut } from "./go-helpers";

async function fill(user: ReturnType<typeof userEvent.setup>, username: string, password: string) {
  await user.type(await screen.findByLabelText("Username"), username);
  await user.type(screen.getByLabelText("Password"), password);
}

describe("the Go browser contract", () => {
  test("reads the Go boot block and still reads the Rails one", () => {
    document.body.innerHTML = `<script type="application/json" id="shelfarr-boot">${JSON.stringify(goBoot("connect"))}</script>`;
    expect(readStartup(document)).toEqual({ kind: "go", boot: goBoot("connect") });
    document.body.innerHTML = `<script type="application/json" id="shelfarr-boot">${JSON.stringify({ version: 1, account: "5", mount: "/preview", api: "/preview/api/v1", classic_library: "/read" })}</script>`;
    expect(readStartup(document).kind).toBe("rails");
    document.body.innerHTML = `<script type="application/json" id="shelfarr-boot">${JSON.stringify({ ...goBoot(), view: "settings" })}</script>`;
    expect(() => readStartup(document)).toThrow(BootError);
    expect(goBootSchema.safeParse({ ...goBoot(), api: "https://evil.test" }).success).toBe(false);
  });

  test("the Go boot block never names an account, so a missing account cannot become a trusted one", () => {
    expect("account" in goBoot()).toBe(false);
    expect(goBootSchema.parse({ ...goBoot(), account: "12" })).not.toHaveProperty("account");
  });

  test("bootstrap answers are one of exactly two shapes", () => {
    expect(bootstrapSchema.safeParse(signedOut()).success).toBe(true);
    expect(bootstrapSchema.safeParse(signedIn()).success).toBe(true);
    expect(bootstrapSchema.safeParse({ authenticated: true, csrf_token: "x", expires_in: 1 }).success).toBe(false);
    expect(bootstrapSchema.safeParse({ authenticated: false, csrf_token: "x", expires_in: 1 }).success).toBe(false);
    expect(bootstrapSchema.safeParse({ ...signedIn(), account: "abc" }).success).toBe(false);
  });
});

describe("signing in on the Go runtime", () => {
  test("shows a native, labelled, autofill-ready sign-in form with a meaningful title", async () => {
    const server = libraryServer(() => signedOut());
    renderGo({ server });
    const username = await screen.findByLabelText("Username");
    const password = screen.getByLabelText("Password");
    expect(document.title).toBe("Sign in · Shelfarr");
    expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
    expect(username.getAttribute("autocomplete")).toBe("username");
    expect(username.getAttribute("name")).toBe("username");
    expect(username.hasAttribute("required")).toBe(true);
    expect(username.getAttribute("spellcheck")).toBe("false");
    expect(username.getAttribute("autocapitalize")).toBe("none");
    expect(username.hasAttribute("maxlength")).toBe(false);
    expect(password.getAttribute("autocomplete")).toBe("current-password");
    expect(password.getAttribute("type")).toBe("password");
    expect(password.hasAttribute("maxlength")).toBe(false);
    expect(username.getAttribute("aria-invalid")).toBe("false");
    const form = username.closest("form");
    expect(form?.getAttribute("method")).toBe("post");
    expect(form?.querySelector('button[type="submit"]')?.textContent).toBe("Sign in");
    expect(screen.getByRole("button", { name: "Show password" }).getAttribute("type")).toBe("button");
  });

  test("the show-password toggle is a pressed-state button and paste stays possible", async () => {
    renderGo({ server: libraryServer(() => signedOut()) });
    const password = await screen.findByLabelText("Password");
    const user = userEvent.setup();
    const toggle = screen.getByRole("button", { name: "Show password" });
    expect(toggle.getAttribute("aria-pressed")).toBe("false");
    await user.click(toggle);
    expect(toggle.getAttribute("aria-pressed")).toBe("true");
    expect(password.getAttribute("type")).toBe("text");
    await user.click(toggle);
    expect(password.getAttribute("type")).toBe("password");
    await user.click(password);
    await user.paste("pasted-secret");
    expect((password as HTMLInputElement).value).toBe("pasted-secret");
  });

  test("a successful sign-in sends the login token, never puts credentials in a URL or storage, and opens the library for that account", async () => {
    const server = libraryServer(() => signedOut("login-token")).on("POST", /\/auth\/login$/, () => ({ body: signedIn(ACCOUNT, "session-token") }));
    renderGo({ server });
    const user = userEvent.setup();
    await fill(user, "ada_reader", "correct horse battery staple, long and unbounded ".repeat(3));
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    expect(await screen.findByRole("link", { name: "The Quiet Library" })).toBeTruthy();
    const logins = server.called("POST", /\/auth\/login$/);
    expect(logins).toHaveLength(1);
    expect(logins[0]?.headers["x-csrf-token"]).toBe("login-token");
    expect(logins[0]?.body).toEqual({ username: "ada_reader", password: "correct horse battery staple, long and unbounded ".repeat(3) });
    expect(server.requests.every((request) => !request.path.includes("ada_reader") && !request.path.includes("correct"))).toBe(true);
    expect(window.location.href).not.toContain("ada_reader");
    expect(window.sessionStorage.length).toBe(0);
    expect(window.localStorage.length).toBe(0);
    expect(document.title).toBe("Library · Shelfarr");
    expect(document.activeElement).toBe(screen.getByRole("heading", { level: 1 }));
    const requests = server.called("GET", /\/api\/v1\/(library|continue|session)/);
    expect(requests.length).toBeGreaterThan(0);
    for (const request of requests) expect(request.headers["x-shelfarr-account"]).toBe(ACCOUNT);
  });

  test("rejected credentials keep the form, link the error, mark the fields and move focus to the error", async () => {
    const server = libraryServer(() => signedOut()).on("POST", /\/auth\/login$/, () => error(401, "invalid_credentials"));
    renderGo({ server });
    const user = userEvent.setup();
    await fill(user, "ada", "wrong");
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    const alert = await screen.findByRole("alert");
    expect(alert.textContent).toContain("were not accepted");
    expect(document.activeElement).toBe(alert);
    const username = screen.getByLabelText("Username");
    expect(username.getAttribute("aria-invalid")).toBe("true");
    expect(username.getAttribute("aria-describedby")).toBe(alert.id);
    expect((screen.getByLabelText("Password") as HTMLInputElement).value).toBe("wrong");
    expect(screen.getByRole("button", { name: "Sign in" }).hasAttribute("disabled")).toBe(false);
  });

  test("Enter in the password field submits once even if pressed repeatedly", async () => {
    const gate = deferred<void>();
    const server = libraryServer(() => signedOut()).on("POST", /\/auth\/login$/, async () => {
      await gate.promise;
      return { body: signedIn() };
    });
    renderGo({ server });
    const user = userEvent.setup();
    await fill(user, "ada", "secret");
    await user.type(screen.getByLabelText("Password"), "{Enter}{Enter}{Enter}");
    await waitFor(() => expect(server.called("POST", /\/auth\/login$/)).toHaveLength(1));
    gate.resolve();
    await screen.findByRole("link", { name: "The Quiet Library" });
    expect(server.called("POST", /\/auth\/login$/)).toHaveLength(1);
  });

  test("two submit events in one tick still send one login request", async () => {
    const gate = deferred<void>();
    const server = libraryServer(() => signedOut()).on("POST", /\/auth\/login$/, async () => {
      await gate.promise;
      return { body: signedIn() };
    });
    renderGo({ server });
    const user = userEvent.setup();
    await fill(user, "ada", "secret");
    const form = screen.getByLabelText("Username").closest("form");
    act(() => {
      form?.requestSubmit();
      form?.requestSubmit();
    });
    await waitFor(() => expect(server.called("POST", /\/auth\/login$/)).toHaveLength(1));
    gate.resolve();
    await screen.findByRole("link", { name: "The Quiet Library" });
    expect(server.called("POST", /\/auth\/login$/)).toHaveLength(1);
  });

  test("an expired login token is refreshed first, with one login request", async () => {
    let issued = 0;
    const server = libraryServer(() => signedOut(`token-${++issued}`, { expires_in: issued === 1 ? 1 : 600 })).on("POST", /\/auth\/login$/, () => ({ body: signedIn() }));
    renderGo({ server });
    const user = userEvent.setup();
    await fill(user, "ada", "secret");
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    await screen.findByRole("link", { name: "The Quiet Library" });
    expect(server.called("GET", /\/auth\/bootstrap$/)).toHaveLength(2);
    expect(server.called("POST", /\/auth\/login$/)[0]?.headers["x-csrf-token"]).toBe("token-2");
  });

  test("a rejected token refreshes the page but does not resubmit the password", async () => {
    let tokens = 0;
    const server = libraryServer(() => signedOut(`token-${++tokens}`)).on("POST", /\/auth\/login$/, () => error(422, "invalid_csrf"));
    renderGo({ server });
    const user = userEvent.setup();
    await fill(user, "ada", "secret");
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    const alert = await screen.findByRole("alert");
    expect(alert.textContent).toContain("sign in again");
    expect(server.called("POST", /\/auth\/login$/)).toHaveLength(1);
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    await waitFor(() => expect(server.called("POST", /\/auth\/login$/)).toHaveLength(2));
    expect(server.called("POST", /\/auth\/login$/)[1]?.headers["x-csrf-token"]).toBe("token-2");
  });

  const refusals: [string, ReturnType<typeof error>, RegExp][] = [
    ["rate limiting", error(429, "rate_limited", {}, { "retry-after": "42" }), /42 seconds/],
    ["a busy server", error(503, "server_busy"), /busy/],
    ["two-step verification", error(501, "mfa_not_supported"), /two-step verification/],
    ["single sign-on", error(501, "oidc_account_not_supported"), /single sign-on/],
    ["a server without passwords", error(501, "sign_in_unsupported", { reason: "auth_disabled" }), /without sign-in/],
    ["a server error", error(500, "internal_error"), /had a problem/],
  ];
  for (const [name, answer, text] of refusals) {
    test(`says plainly what happened on ${name} and offers no bypass`, async () => {
      const server = libraryServer(() => signedOut()).on("POST", /\/auth\/login$/, () => answer);
      renderGo({ server });
      const user = userEvent.setup();
      await fill(user, "ada", "secret");
      await user.click(screen.getByRole("button", { name: "Sign in" }));
      expect((await screen.findByRole("alert")).textContent).toMatch(text);
      expect(screen.queryByRole("link")).toBeNull();
      expect(screen.getByLabelText("Username").getAttribute("aria-invalid")).toBe("false");
    });
  }

  test("a network failure keeps what was typed and does not retry by itself", async () => {
    const server = libraryServer(() => signedOut());
    const original = server.fetcher;
    const failing = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith("/auth/login")) throw new TypeError("offline");
      return original(input, init);
    }) as typeof fetch;
    const { GoApp } = await import("../src/go/GoApp");
    const { render } = await import("@testing-library/react");
    window.history.replaceState(null, "", "/preview/library");
    render(<GoApp boot={goBoot()} fetcher={failing} />);
    const user = userEvent.setup();
    await fill(user, "ada", "secret");
    await user.click(await screen.findByRole("button", { name: "Sign in" }));
    expect((await screen.findByRole("alert")).textContent).toContain("Could not reach the server");
    expect((screen.getByLabelText("Password") as HTMLInputElement).value).toBe("secret");
  });

  test("a sign-in that the server does not offer shows why and no form", async () => {
    const server = libraryServer(() => signedOut("t", { sign_in: { available: false, reason: "browser_origin_not_configured" } }));
    renderGo({ server });
    expect((await screen.findByRole("alert")).textContent).toContain("browser address");
    expect(screen.queryByLabelText("Password")).toBeNull();
  });

  test("an off or unreachable preview says so instead of showing an empty page", async () => {
    const off = libraryServer(() => ({})).on("GET", /\/auth\/bootstrap$/, () => error(404, "not_found"));
    renderGo({ server: off });
    expect((await screen.findByRole("alert")).textContent).toContain("not switched on");
    expect(screen.queryByRole("button", { name: "Try again" })).toBeNull();
  });

  test("an already signed-in browser skips the form and shows its library", async () => {
    const server = libraryServer(() => signedIn());
    renderGo({ server });
    expect(await screen.findByRole("link", { name: "The Quiet Library" })).toBeTruthy();
    expect(screen.queryByLabelText("Password")).toBeNull();
    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(within(nav).getAllByRole("link").map((link) => [link.textContent, link.getAttribute("href")])).toEqual([
      ["Library", "/preview/library"],
      ["Discover", "/preview/discover"],
      ["Requests", "/preview/requests"],
      ["Account", "/preview/account"],
    ]);
    expect(document.querySelector('a[href^="/read"], a[href="/search"], a[href="/requests"], a[href="/profile"], a[href="/admin"]')).toBeNull();
    expect(screen.getByRole("button", { name: "Sign out" })).toBeTruthy();
  });
});

describe("account safety on the Go runtime", () => {
  test("signing out posts the session token for the exact account and shows the sign-in form with no old data", async () => {
    let authenticated = true;
    const server = libraryServer(() => (authenticated ? signedIn(ACCOUNT, "session-token") : signedOut())).on("POST", /\/auth\/logout$/, () => {
      authenticated = false;
      return { body: { authenticated: false } };
    });
    renderGo({ server });
    await screen.findByRole("link", { name: "The Quiet Library" });
    await userEvent.setup().click(screen.getByRole("button", { name: "Sign out" }));
    expect(await screen.findByLabelText("Username")).toBeTruthy();
    const logouts = server.called("POST", /\/auth\/logout$/);
    expect(logouts).toHaveLength(1);
    expect(logouts[0]?.headers["x-csrf-token"]).toBe("session-token");
    expect(logouts[0]?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(screen.queryByText("The Quiet Library")).toBeNull();
    expect(screen.getByRole("status").textContent).toContain("signed out");
  });

  test("a failed sign-out keeps the library and says it failed", async () => {
    const server = libraryServer(() => signedIn()).on("POST", /\/auth\/logout$/, () => error(503, "database_busy"));
    renderGo({ server });
    await screen.findByRole("link", { name: "The Quiet Library" });
    await userEvent.setup().click(screen.getByRole("button", { name: "Sign out" }));
    expect((await screen.findByText("Could not sign out. Try again.")).getAttribute("role")).toBe("alert");
    expect(screen.getByRole("link", { name: "The Quiet Library" })).toBeTruthy();
  });

  test("a sign-out whose token was replaced elsewhere refreshes the token and succeeds on the next explicit attempt, never by itself", async () => {
    let current = "session-token-1";
    let issued = 1;
    const server = libraryServer(() => signedIn(ACCOUNT, current))
      .on("POST", /\/auth\/logout$/, (request) => (request.headers["x-csrf-token"] === current ? { body: { authenticated: false } } : error(422, "invalid_csrf")));
    renderGo({ server });
    await screen.findByRole("link", { name: "The Quiet Library" });
    issued += 1;
    current = `session-token-${issued}`;
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Sign out" }));
    await screen.findByText("Could not sign out. Try again.");
    expect(server.called("POST", /\/auth\/logout$/)).toHaveLength(1);
    await waitFor(() => expect(server.called("GET", /\/auth\/bootstrap$/).length).toBeGreaterThanOrEqual(2));
    await user.click(screen.getByRole("button", { name: "Sign out" }));
    await waitFor(() => expect(server.called("POST", /\/auth\/logout$/)).toHaveLength(2));
    expect(server.called("POST", /\/auth\/logout$/)[1]?.headers["x-csrf-token"]).toBe(current);
  });

  test("another tab signing in as someone else stops this page and recovery builds a fresh one for the new account", async () => {
    let account = ACCOUNT;
    const server = libraryServer(() => signedIn(account))
      .on("GET", /\/api\/v1\/library(\?|$)/, (request) => (request.headers["x-shelfarr-account"] === account ? { body: { account, items: [summary({ title: `Books of ${account}` })], next_cursor: null } } : error(401, "account_changed")))
      .on("GET", /\/api\/v1\/session$/, (request) => (request.headers["x-shelfarr-account"] === account ? { body: session({ account: { id: account, name: "Someone" } }) } : error(401, "account_changed")));
    renderGo({ server });
    await screen.findByRole("link", { name: "Books of 12" });
    account = "99";
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    expect(screen.queryByText("Books of 12")).toBeNull();
    await userEvent.setup().click(screen.getByRole("button", { name: "Continue as the current account" }));
    expect(await screen.findByRole("link", { name: "Books of 99" })).toBeTruthy();
    for (const request of server.called("GET", /\/api\/v1\/library(\?|$)/).slice(-1)) expect(request.headers["x-shelfarr-account"]).toBe("99");
  });

  test("a session that ended elsewhere offers a sign-in, not a stale library", async () => {
    let signed = true;
    const server = libraryServer(() => (signed ? signedIn() : signedOut()))
      .on("GET", /\/api\/v1\/library(\?|$)/, () => (signed ? { body: { account: ACCOUNT, items: [summary()], next_cursor: null } } : error(401, "signed_out")))
      .on("GET", /\/api\/v1\/session$/, () => (signed ? { body: session() } : error(401, "signed_out")));
    renderGo({ server });
    await screen.findByRole("link", { name: "The Quiet Library" });
    signed = false;
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    await screen.findByRole("heading", { name: "Your session ended" });
    await userEvent.setup().click(screen.getByRole("button", { name: "Sign in again" }));
    expect(await screen.findByLabelText("Username")).toBeTruthy();
    expect(screen.getByRole("status").textContent).toContain("session ended");
    expect(screen.queryByText("The Quiet Library")).toBeNull();
  });

  test("a response that arrives after sign-out is never rendered", async () => {
    const gate = deferred<void>();
    let authenticated = true;
    const server = libraryServer(() => (authenticated ? signedIn() : signedOut()))
      .on("GET", /\/api\/v1\/library\/7$/, async () => {
        await gate.promise;
        return { body: { account: ACCOUNT, publication: detail({ title: "Late Secret Book" }) } };
      })
      .on("POST", /\/auth\/logout$/, () => {
        authenticated = false;
        return { body: { authenticated: false } };
      });
    renderGo({ server, view: "details", url: "/preview/library/7" });
    await waitFor(() => expect(server.called("GET", /\/library\/7$/)).toHaveLength(1));
    await userEvent.setup().click(await screen.findByRole("button", { name: "Sign out" }));
    await screen.findByLabelText("Username");
    gate.resolve();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(screen.queryByText("Late Secret Book")).toBeNull();
  });
});

describe("the Library on the Go runtime", () => {
  test("opens an EPUB in the Go reader and never offers the Rails reader link that would 404", async () => {
    const server = libraryServer(() => signedIn()).on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail({ reader_url: "/read/7" }) } }));
    renderGo({ server, view: "details", url: "/preview/library/7" });
    await screen.findByRole("heading", { level: 1, name: "The Quiet Library" });
    expect(document.querySelector('a[href="/read/7"]')).toBeNull();
    expect(screen.getByRole("link", { name: "Start reading The Quiet Library in the reader" }).getAttribute("href")).toBe("/preview/library/7/read");
    expect(document.title).toBe("The Quiet Library · Shelfarr");
  });

  test("says honestly that a PDF cannot be opened in the browser and offers no reader link", async () => {
    const pdf = detail({ reader_url: "/read/7", format_label: "PDF", files: [{ id: "b".repeat(64), filename: "A Book.pdf", format: "pdf", media_type: "application/pdf", size_bytes: 4096, position: 0, page_count: null }] });
    const server = libraryServer(() => signedIn()).on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: pdf } }));
    renderGo({ server, view: "details", url: "/preview/library/7" });
    await screen.findByRole("heading", { level: 1, name: "The Quiet Library" });
    expect(document.querySelector('a[href="/read/7"], a[href="/preview/library/7/read"]')).toBeNull();
    expect(screen.getAllByRole("note").some((note) => note.textContent?.includes("Opening this PDF is not available in this experimental reader yet"))).toBe(true);
  });

  test("changing reading status uses a fresh session token and is not retried on a rejected token", async () => {
    let tokens = 0;
    const server = libraryServer(() => signedIn(ACCOUNT, `session-token-${++tokens}`))
      .on("PUT", /\/reading_status$/, () => error(422, "invalid_csrf"));
    renderGo({ server, view: "details", url: "/preview/library/7" });
    const user = userEvent.setup();
    await user.selectOptions(await screen.findByLabelText("Reading status"), "finished");
    await user.click(screen.getByRole("button", { name: "Save status" }));
    expect((await screen.findByText(/out of date/)).getAttribute("role")).toBe("alert");
    expect(server.called("PUT", /\/reading_status$/)).toHaveLength(1);
    await waitFor(() => expect(server.called("GET", /\/auth\/bootstrap$/).length).toBeGreaterThanOrEqual(2));
    expect(server.called("PUT", /\/reading_status$/)[0]?.headers["x-csrf-token"]).toBe("session-token-1");
    expect(server.called("PUT", /\/reading_status$/)[0]?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
  });

  test("a refused format is explained, not shown as an empty library", async () => {
    const server = libraryServer(() => signedIn()).on("GET", /\/api\/v1\/library(\?|$)/, () => error(501, "unsupported_asset_format"));
    renderGo({ server });
    const alert = await screen.findByRole("alert");
    expect(alert.textContent).toContain("PDF or a comic-book (CBZ)");
    expect(screen.queryByText("Nothing on this server yet")).toBeNull();
  });
});
