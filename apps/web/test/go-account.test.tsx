import { describe, expect, test } from "bun:test";
import { createMemoryHistory } from "@tanstack/react-router";
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { App } from "../src/App";
import { resetFirstPage } from "../src/components/PageHeading";
import { accountEnvelopeSchema, accountRejectionSchema } from "../src/contract";
import { createAppRouter } from "../src/router";
import { createServices } from "../src/services";
import { ACCOUNT, deferred, FakeServer, page, renderApp, session, standardServer, summary } from "./helpers";
import { error, libraryServer, renderGo, signedIn, signedOut } from "./go-helpers";

const CURRENT = "Current-Passw0rd-Sentinel";
const NEXT = "Changed-Passw0rd-Sentinel";

function profile(name = "Ada Reader") {
  return { id: ACCOUNT, username: "ada", name };
}

function accountServer(state = { name: "Ada Reader" }): FakeServer {
  return new FakeServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session({ account: { id: ACCOUNT, name: state.name } }) }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", /\/api\/v1\/account$/, () => ({ body: { account: ACCOUNT, profile: profile(state.name) } }))
    .on("PUT", /\/api\/v1\/account\/profile$/, (request) => {
      state.name = (request.body as { name: string }).name;
      return { body: { account: ACCOUNT, profile: profile(state.name) } };
    })
    .on("POST", /\/api\/v1\/account\/password$/, () => ({ body: { account: ACCOUNT, profile: profile(state.name) } }));
}

function renderAccount(server: FakeServer, url = "/preview/account") {
  resetFirstPage();
  const services = createServices({
    boot: { version: 1, account: ACCOUNT, mount: "/preview", api: "/preview/api/v1", classic_library: null, runtime: "go" },
    csrfToken: () => "session-token",
    fetcher: server.fetcher,
  });
  const history = createMemoryHistory({ initialEntries: [url] });
  const router = createAppRouter({ basepath: "/preview", history });
  const view = render(<App services={services} router={router} />);
  return { services, router, view };
}

function writes(server: FakeServer) {
  return server.requests.filter((request) => request.method !== "GET");
}

async function fillPassword(user: ReturnType<typeof userEvent.setup>, current: string, next: string, confirmation = next) {
  if (current) await user.type(screen.getByLabelText("Current password"), current);
  if (next) await user.type(screen.getByLabelText("New password"), next);
  if (confirmation) await user.type(screen.getByLabelText("Confirm new password"), confirmation);
}

describe("the account contract", () => {
  test("accepts exactly the profile envelope and the field rejection", () => {
    expect(accountEnvelopeSchema.safeParse({ account: ACCOUNT, profile: profile() }).success).toBe(true);
    expect(accountEnvelopeSchema.safeParse({ account: ACCOUNT, profile: { ...profile(), id: "ada" } }).success).toBe(false);
    expect(accountEnvelopeSchema.safeParse({ account: ACCOUNT, profile: { ...profile(), id: "99" } }).success).toBe(false);
    expect(accountRejectionSchema.safeParse({ account: ACCOUNT, error: "invalid_password", errors: { password: ["is too long"] } }).success).toBe(true);
    expect(accountRejectionSchema.safeParse({ account: ACCOUNT, error: "invalid_csrf", errors: {} }).success).toBe(false);
    expect(accountRejectionSchema.safeParse({ error: "invalid_profile", errors: {} }).success).toBe(false);
  });
});

describe("the Go Account page", () => {
  test("is in the Go navigation and shows the display name and username without writing anything", async () => {
    const server = accountServer();
    renderAccount(server, "/preview/library");
    const user = userEvent.setup();
    const nav = await screen.findByRole("navigation", { name: "Primary" });
    await user.click(within(nav).getByRole("link", { name: "Account" }));
    const heading = await screen.findByRole("heading", { level: 1, name: "Account" });
    await waitFor(() => expect(document.activeElement).toBe(heading));
    expect(document.title).toBe("Account · Shelfarr");
    const identity = await screen.findByRole("region", { name: "Signed in as" });
    expect(within(identity).getByText("Ada Reader")).toBeTruthy();
    expect(within(identity).getByText("@ada")).toBeTruthy();
    expect(within(nav).getByRole("link", { name: "Account" }).getAttribute("aria-current")).toBe("page");
    expect(server.called("GET", /\/api\/v1\/account$/)[0]?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(writes(server)).toHaveLength(0);
    expect(screen.queryByRole("link", { name: /two-step|single sign-on|token|kobo/i })).toBeNull();
  });

  test("opens on a direct load after sign-in with an account-specific prompt", async () => {
    let signed = false;
    const server = libraryServer(() => (signed ? signedIn() : signedOut()))
      .on("POST", /\/auth\/login$/, () => {
        signed = true;
        return { body: signedIn() };
      })
      .on("GET", /\/api\/v1\/account$/, () => ({ body: { account: ACCOUNT, profile: profile() } }));
    renderGo({ server, view: "account", url: "/preview/account" });
    expect(await screen.findByText("Sign in to manage your account. You will come straight back to it.")).toBeTruthy();
    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Username"), "ada");
    await user.type(screen.getByLabelText("Password"), CURRENT);
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    expect(await screen.findByRole("heading", { level: 1, name: "Account" })).toBeTruthy();
    expect(await screen.findByText("@ada")).toBeTruthy();
  });

  test("a server without account settings says so and changes nothing", async () => {
    const server = standardServer().on("GET", /\/api\/v1\/session$/, () => ({ body: session() }));
    renderAccount(server);
    expect(await screen.findByText("Account settings are not available here")).toBeTruthy();
    expect(screen.queryByRole("textbox", { name: "Display name" })).toBeNull();
    expect(writes(server)).toHaveLength(0);
  });

  test("the classic preview neither links to nor serves this page", async () => {
    const server = standardServer();
    renderApp({ server, url: "/sub/preview/account" });
    expect(await screen.findByText("That page is not part of this preview")).toBeTruthy();
    const nav = screen.getByRole("navigation", { name: "Primary" });
    await waitFor(() => expect(within(nav).getByRole("link", { name: /Account/ }).getAttribute("href")).toBe("/sub/profile"));
    expect(server.called("GET", /\/account$/)).toHaveLength(0);
  });
});

describe("changing the display name", () => {
  test("saves once with the session token, then shows the new name in the header and the page", async () => {
    const pending = deferred<{ body: unknown }>();
    const state = { name: "Ada Reader" };
    const server = accountServer(state).on("PUT", /\/api\/v1\/account\/profile$/, () => pending.promise);
    renderAccount(server);
    const user = userEvent.setup();
    const input = await screen.findByRole("textbox", { name: "Display name" });
    expect(input.getAttribute("autocomplete")).toBe("nickname");
    expect(await screen.findByText("Ada Reader", { selector: "strong" })).toBeTruthy();
    await user.clear(input);
    await user.type(input, "  Zoë 📚  ");
    await user.click(screen.getByRole("button", { name: "Save name" }));
    expect(screen.getByRole("button", { name: "Saving…" }).hasAttribute("disabled")).toBe(true);
    await user.keyboard("{Enter}");
    expect(server.called("PUT", /\/account\/profile$/)).toHaveLength(1);
    const sent = server.called("PUT", /\/account\/profile$/)[0];
    expect(sent?.body).toEqual({ name: "  Zoë 📚  " });
    expect(sent?.headers["x-csrf-token"]).toBe("session-token");
    expect(sent?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    state.name = "  Zoë 📚  ";
    await act(async () => pending.resolve({ body: { account: ACCOUNT, profile: profile(state.name) } }));
    expect(await screen.findByText("Display name saved.")).toBeTruthy();
    expect(screen.getByText("Zoë 📚", { selector: "strong", normalizer: (text) => text.trim() })).toBeTruthy();
    expect(within(screen.getByRole("region", { name: "Signed in as" })).getByText("Zoë 📚", { normalizer: (text) => text.trim() })).toBeTruthy();
  });

  test("two submits in the same moment send one save", async () => {
    const pending = deferred<{ body: unknown }>();
    const server = accountServer().on("PUT", /\/account\/profile$/, () => pending.promise);
    renderAccount(server);
    const input = await screen.findByRole("textbox", { name: "Display name" });
    fireEvent.change(input, { target: { value: "Once Only" } });
    const form = input.closest("form") as HTMLFormElement;
    act(() => {
      fireEvent.submit(form);
      fireEvent.submit(form);
    });
    await waitFor(() => expect(server.called("PUT", /\/account\/profile$/)).toHaveLength(1));
    await act(async () => pending.resolve({ body: { account: ACCOUNT, profile: profile("Once Only") } }));
    expect(await screen.findByText("Display name saved.")).toBeTruthy();
    expect(server.called("PUT", /\/account\/profile$/)).toHaveLength(1);
  });

  test("a blank name is explained on the field and never sent", async () => {
    const server = accountServer();
    renderAccount(server);
    const user = userEvent.setup();
    const input = await screen.findByRole("textbox", { name: "Display name" });
    await user.clear(input);
    await user.type(input, "　 ");
    await user.click(screen.getByRole("button", { name: "Save name" }));
    expect(document.activeElement).toBe(input);
    expect(input.getAttribute("aria-invalid")).toBe("true");
    const described = input.getAttribute("aria-describedby") ?? "";
    expect(document.getElementById(described)?.textContent).toContain("Enter a display name.");
    expect(writes(server)).toHaveLength(0);
    await user.type(input, "A");
    expect(input.getAttribute("aria-invalid")).toBe("false");
    expect(input.hasAttribute("aria-describedby")).toBe(false);
  });

  test("a stored record Rails would refuse is reported without claiming a save", async () => {
    const server = accountServer().on("PUT", /\/account\/profile$/, () => error(422, "invalid_profile", { account: ACCOUNT, errors: { username: ["only allows lowercase letters, numbers, and underscores"] } }));
    renderAccount(server);
    const user = userEvent.setup();
    const input = await screen.findByRole("textbox", { name: "Display name" });
    await user.type(input, "!");
    await user.click(screen.getByRole("button", { name: "Save name" }));
    expect(await screen.findByText(/Username only allows lowercase letters, numbers, and underscores/)).toBeTruthy();
    expect(screen.queryByText("Display name saved.")).toBeNull();
    expect((input as HTMLInputElement).value).toBe("Ada Reader!");
  });

  test("an uncertain answer says so and reloads what the server has", async () => {
    const server = accountServer().on("PUT", /\/account\/profile$/, () => error(500, "internal_error"));
    renderAccount(server);
    const user = userEvent.setup();
    await user.type(await screen.findByRole("textbox", { name: "Display name" }), "!");
    await user.click(screen.getByRole("button", { name: "Save name" }));
    expect(await screen.findByText(/could not confirm whether the name was saved/)).toBeTruthy();
    await waitFor(() => expect(server.called("GET", /\/api\/v1\/account$/).length).toBeGreaterThanOrEqual(2));
  });

  test("a late answer for another account is never shown and locks the page", async () => {
    const pending = deferred<{ body: unknown }>();
    const server = accountServer().on("PUT", /\/account\/profile$/, () => pending.promise);
    renderAccount(server);
    const user = userEvent.setup();
    await user.type(await screen.findByRole("textbox", { name: "Display name" }), "!");
    await user.click(screen.getByRole("button", { name: "Save name" }));
    await act(async () => pending.resolve({ body: { account: "99", profile: { id: "99", username: "mallory", name: "Mallory" } } }));
    expect(await screen.findByRole("heading", { name: /account changed/i })).toBeTruthy();
    expect(screen.queryByText("Mallory")).toBeNull();
  });

  test("a save that finishes after leaving the page still refreshes the header", async () => {
    const pending = deferred<{ body: unknown }>();
    const state = { name: "Ada Reader" };
    const server = accountServer(state).on("PUT", /\/account\/profile$/, () => pending.promise);
    renderAccount(server);
    const user = userEvent.setup();
    const input = await screen.findByRole("textbox", { name: "Display name" });
    await user.clear(input);
    await user.type(input, "Ada Lovelace");
    await user.click(screen.getByRole("button", { name: "Save name" }));
    await user.click(within(screen.getByRole("navigation", { name: "Primary" })).getByRole("link", { name: "Library" }));
    await screen.findByRole("heading", { level: 1, name: "Library" });
    state.name = "Ada Lovelace";
    await act(async () => pending.resolve({ body: { account: ACCOUNT, profile: profile(state.name) } }));
    expect(await screen.findByText("Ada Lovelace", { selector: "strong" })).toBeTruthy();
  });
});

describe("review regressions", () => {
  test("a session check that finds this browser no longer allowed locks the page and drops a typed password", async () => {
    let allowed = true;
    const server = accountServer().on("GET", /\/api\/v1\/session$/, () => (allowed ? { body: session() } : error(404, "not_found")));
    renderAccount(server);
    const user = userEvent.setup();
    await user.type(await screen.findByLabelText("Current password"), CURRENT);
    allowed = false;
    act(() => {
      window.dispatchEvent(new Event("focus"));
    });
    expect(await screen.findByRole("heading", { name: /account changed/i })).toBeTruthy();
    expect(screen.queryByLabelText("Current password")).toBeNull();
    expect(document.body.innerHTML).not.toContain(CURRENT);
  });

  test("a password answer that arrives after a newer name is saved does not bring the old name back", async () => {
    const pendingPassword = deferred<{ body: unknown }>();
    const state = { name: "Ada Reader" };
    const server = accountServer(state).on("POST", /\/account\/password$/, () => pendingPassword.promise);
    renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, CURRENT, NEXT);
    await user.click(screen.getByRole("button", { name: "Change password" }));
    const input = screen.getByRole("textbox", { name: "Display name" });
    await user.clear(input);
    await user.type(input, "Saved New Name");
    await user.click(screen.getByRole("button", { name: "Save name" }));
    await screen.findByText("Display name saved.");
    await act(async () => pendingPassword.resolve({ body: { account: ACCOUNT, profile: profile("Ada Reader") } }));
    await screen.findByText(/Password changed/);
    await act(async () => Bun.sleep(20));
    expect((screen.getByRole("textbox", { name: "Display name" }) as HTMLInputElement).value).toBe("Saved New Name");
    expect(within(screen.getByRole("region", { name: "Signed in as" })).getByText("Saved New Name")).toBeTruthy();
  });

  test("typing while a name is being saved keeps the newer text", async () => {
    const pending = deferred<{ body: unknown }>();
    const state = { name: "Ada Reader" };
    const server = accountServer(state).on("PUT", /\/account\/profile$/, () => pending.promise);
    renderAccount(server);
    const user = userEvent.setup();
    const input = await screen.findByRole("textbox", { name: "Display name" });
    await user.clear(input);
    await user.type(input, "Submitted Name");
    await user.click(screen.getByRole("button", { name: "Save name" }));
    await user.type(input, " and more");
    state.name = "Submitted Name";
    await act(async () => pending.resolve({ body: { account: ACCOUNT, profile: profile("Submitted Name") } }));
    expect(await screen.findByText("The earlier name was saved. Your newer change is not saved yet.")).toBeTruthy();
    expect((input as HTMLInputElement).value).toBe("Submitted Name and more");
  });

  test("a success answer that cannot be read is reported as uncertain, never as nothing changed", async () => {
    const server = accountServer().on("POST", /\/account\/password$/, () => ({ status: 200, body: undefined, headers: { "content-type": "text/plain" } }));
    renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, CURRENT, NEXT);
    await user.click(screen.getByRole("button", { name: "Change password" }));
    expect(await screen.findByText(/could not confirm whether your password changed/)).toBeTruthy();
    expect(screen.queryByText(/Nothing was changed/)).toBeNull();
  });

  test("focus reaches a refused field only once its error describes it, and the refusal is announced", async () => {
    const server = accountServer().on("POST", /\/account\/password$/, () => error(422, "invalid_password", { account: ACCOUNT, errors: { current_password: ["is incorrect"] } }));
    renderAccount(server);
    const user = userEvent.setup();
    const current = await screen.findByLabelText("Current password");
    const described: (string | null)[] = [];
    current.addEventListener("focus", () => described.push(current.getAttribute("aria-describedby")));
    await fillPassword(user, "Wrong-Passw0rd-1", NEXT);
    await user.click(screen.getByRole("button", { name: "Change password" }));
    await waitFor(() => expect(document.activeElement).toBe(current));
    const last = described[described.length - 1] ?? "";
    expect(document.getElementById(last)?.textContent).toContain("That is not your current password.");
    expect(within(current.closest("form") as HTMLElement).getByRole("status").textContent).toBe("The password was not changed. Check the marked fields.");
  });
});

describe("changing the password", () => {
  test("is a labelled form a password manager can fill and update", async () => {
    renderAccount(accountServer());
    const current = await screen.findByLabelText("Current password");
    const next = screen.getByLabelText("New password");
    const confirmation = screen.getByLabelText("Confirm new password");
    expect(current.getAttribute("autocomplete")).toBe("current-password");
    expect(next.getAttribute("autocomplete")).toBe("new-password");
    expect(confirmation.getAttribute("autocomplete")).toBe("new-password");
    for (const field of [current, next, confirmation]) expect(field.getAttribute("type")).toBe("password");
    const form = current.closest("form");
    const username = form?.querySelector('input[autocomplete="username"]') as HTMLInputElement | null;
    expect(username?.value).toBe("ada");
    expect(username?.hidden).toBe(true);
    expect(form?.getAttribute("method")).toBe("post");
    expect(next.getAttribute("aria-describedby")).toBeTruthy();
    expect(document.getElementById(next.getAttribute("aria-describedby") ?? "")?.textContent).toBe("At least 12 characters, with a lowercase letter, an uppercase letter and a number.");
  });

  test("a mismatched confirmation is caught before sending", async () => {
    const server = accountServer();
    renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, CURRENT, NEXT, `${NEXT}x`);
    await user.click(screen.getByRole("button", { name: "Change password" }));
    const confirmation = screen.getByLabelText("Confirm new password");
    expect(document.activeElement).toBe(confirmation);
    expect(screen.getByText("This does not match the new password.")).toBeTruthy();
    expect(writes(server)).toHaveLength(0);
  });

  test("sends one change, clears every field, keeps the page signed in and stores nothing", async () => {
    const pending = deferred<{ body: unknown }>();
    const server = accountServer().on("POST", /\/account\/password$/, () => pending.promise);
    const { services } = renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, CURRENT, NEXT);
    await user.click(screen.getByRole("button", { name: "Change password" }));
    await user.click(screen.getByRole("button", { name: "Changing password…" }));
    expect(server.called("POST", /\/account\/password$/)).toHaveLength(1);
    const sent = server.called("POST", /\/account\/password$/)[0];
    expect(sent?.body).toEqual({ current_password: CURRENT, password: NEXT, password_confirmation: NEXT });
    expect(sent?.headers["x-csrf-token"]).toBe("session-token");
    await act(async () => pending.resolve({ body: { account: ACCOUNT, profile: profile() } }));
    expect(await screen.findByText(/Password changed. You are still signed in here/)).toBeTruthy();
    for (const label of ["Current password", "New password", "Confirm new password"]) expect((screen.getByLabelText(label) as HTMLInputElement).value).toBe("");
    const cached = JSON.stringify(services.queryClient.getQueryCache().getAll().map((query) => query.state.data));
    const mutations = JSON.stringify(services.queryClient.getMutationCache().getAll().map((mutation) => mutation.state.variables));
    for (const secret of [CURRENT, NEXT]) {
      expect(cached).not.toContain(secret);
      expect(mutations).not.toContain(secret);
      expect(window.location.href).not.toContain(secret);
      expect(JSON.stringify({ ...window.sessionStorage })).not.toContain(secret);
      expect(JSON.stringify({ ...window.localStorage })).not.toContain(secret);
    }
  });

  test("two submits in the same moment send one password change", async () => {
    const pending = deferred<{ body: unknown }>();
    const server = accountServer().on("POST", /\/account\/password$/, () => pending.promise);
    renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, CURRENT, NEXT);
    const form = screen.getByLabelText("Current password").closest("form") as HTMLFormElement;
    act(() => {
      fireEvent.submit(form);
      fireEvent.submit(form);
    });
    await waitFor(() => expect(server.called("POST", /\/account\/password$/)).toHaveLength(1));
    await act(async () => pending.resolve({ body: { account: ACCOUNT, profile: profile() } }));
    await screen.findByText(/Password changed/);
    expect(server.called("POST", /\/account\/password$/)).toHaveLength(1);
  });

  test("a wrong current password is shown on that field and focused", async () => {
    const server = accountServer().on("POST", /\/account\/password$/, () => error(422, "invalid_password", { account: ACCOUNT, errors: { current_password: ["is incorrect"] } }));
    renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, "Wrong-Passw0rd-1", NEXT);
    await user.click(screen.getByRole("button", { name: "Change password" }));
    const current = screen.getByLabelText("Current password");
    await waitFor(() => expect(document.activeElement).toBe(current));
    expect(current.getAttribute("aria-invalid")).toBe("true");
    expect(document.getElementById(current.getAttribute("aria-describedby") ?? "")?.textContent).toContain("That is not your current password.");
    expect((screen.getByLabelText("New password") as HTMLInputElement).value).toBe(NEXT);
  });

  test("the server's password rules are shown in plain words on the new password", async () => {
    const server = accountServer().on("POST", /\/account\/password$/, () =>
      error(422, "invalid_password", { account: ACCOUNT, errors: { password: ["is too short (minimum is 12 characters)", "must include at least one lowercase letter, one uppercase letter, and one number"] } }),
    );
    renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, CURRENT, "short");
    await user.click(screen.getByRole("button", { name: "Change password" }));
    const next = screen.getByLabelText("New password");
    await waitFor(() => expect(document.activeElement).toBe(next));
    const described = (next.getAttribute("aria-describedby") ?? "").split(" ").map((id) => document.getElementById(id)?.textContent ?? "");
    expect(described[1]).toContain("Use at least 12 characters. Include a lowercase letter (a–z), an uppercase letter (A–Z) and a number (0–9).");
  });

  test("an uncertain answer keeps the fields and explains how to tell whether it changed", async () => {
    const server = accountServer().on("POST", /\/account\/password$/, () => {
      throw new TypeError("connection reset");
    });
    renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, CURRENT, NEXT);
    await user.click(screen.getByRole("button", { name: "Change password" }));
    expect(await screen.findByText(/could not confirm whether your password changed/)).toBeTruthy();
    expect((screen.getByLabelText("New password") as HTMLInputElement).value).toBe(NEXT);
    expect(server.called("POST", /\/account\/password$/)).toHaveLength(1);
  });

  test("a change made elsewhere meanwhile asks for the current password again", async () => {
    const server = accountServer().on("POST", /\/account\/password$/, () => error(409, "account_conflict"));
    renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, CURRENT, NEXT);
    await user.click(screen.getByRole("button", { name: "Change password" }));
    expect(await screen.findByText(/changed somewhere else while this was saving/)).toBeTruthy();
    const current = screen.getByLabelText("Current password") as HTMLInputElement;
    expect(current.value).toBe("");
    expect(document.activeElement).toBe(current);
  });

  test("an ended session locks the page instead of reporting a change", async () => {
    const server = accountServer().on("POST", /\/account\/password$/, () => error(401, "signed_out"));
    renderAccount(server);
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await fillPassword(user, CURRENT, NEXT);
    await user.click(screen.getByRole("button", { name: "Change password" }));
    expect(await screen.findByRole("heading", { name: /session ended/i })).toBeTruthy();
    expect(screen.queryByLabelText("Current password")).toBeNull();
  });

  test("saving the name keeps a half-typed password", async () => {
    renderAccount(accountServer());
    const user = userEvent.setup();
    await screen.findByLabelText("Current password");
    await user.type(screen.getByLabelText("Current password"), CURRENT);
    await user.type(screen.getByRole("textbox", { name: "Display name" }), "!");
    await user.click(screen.getByRole("button", { name: "Save name" }));
    expect(await screen.findByText("Display name saved.")).toBeTruthy();
    expect((screen.getByLabelText("Current password") as HTMLInputElement).value).toBe(CURRENT);
  });
});
