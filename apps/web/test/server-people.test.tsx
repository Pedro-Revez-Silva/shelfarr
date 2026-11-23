import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ServerSettings } from "../src/server/contract";
import { peopleSchema, personEnvelopeSchema, type PersonEnvelope, type PersonRecord, type PersonRow } from "../src/server/people/contract";
import { ACCOUNT, deferred, FakeServer, renderApp, session, standardServer } from "./helpers";

afterEach(cleanup);

const ADMIN = { admin: { url: "/sub/admin" }, capabilities: { administrator: true, can_upload: true, single_sign_on: false, hardcover_personal_access: false } };
const SECRET = "Fresh-Secret-42xyz";

function row(id: string, overrides: Partial<PersonRow> = {}): PersonRow {
  return { id, name: `Person ${id}`, username: `person_${id}`, role: "member", self: false, created_at: "2026-11-02T09:00:00.000Z", ...overrides };
}

function record(id: string, overrides: Partial<PersonRecord> = {}): PersonRecord {
  return { ...row(id), requests: 3, version: `v-${id}-1`, ...overrides };
}

function envelope(user: PersonRecord, administrators = 2): PersonEnvelope {
  return { account: ACCOUNT, user, administrators };
}

const SELF = record(ACCOUNT, { name: "Ada Reader", username: "ada", role: "administrator", self: true });
const ROWAN = record("5", { name: "Rowan Ash", username: "rowan" });

function settings(): ServerSettings {
  return {
    account: ACCOUNT,
    categories: [{ id: "people", title: "People and access", summary: "Who can sign in.", groups: [{ id: "sign_in", title: "Sign-in rules", summary: "Session length.", fields: [], advanced: [], probes: [], extras: [], notes: [] }] }],
    notes: { path_variables: "", hardcover_app: { create_url: "https://hardcover.app/new", scopes: "read:me", redirect_uri: "https://shelf.test/cb", redirect_uri_acceptable: true } },
    roles: [],
  };
}

function peopleServer(records: Record<string, PersonRecord> = { [SELF.id]: SELF, [ROWAN.id]: ROWAN }, sessionOverrides: object = ADMIN): FakeServer {
  return standardServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(sessionOverrides) }))
    .on("GET", /\/api\/v1\/admin\/settings$/, () => ({ body: settings() }))
    .on("GET", /\/api\/v1\/admin\/users$/, () => ({ body: { account: ACCOUNT, users: Object.values(records).map(({ requests: _r, version: _v, ...entry }) => entry) } }))
    .on("GET", /\/api\/v1\/admin\/users\/\d+$/, (request) => {
      const found = records[request.path.split("/").pop()!];
      return found ? { body: envelope(found) } : { status: 404, body: { error: "user_not_found" } };
    });
}

function card(name: string): HTMLElement {
  return screen.getByRole("heading", { name, level: 3 }).closest("section") as HTMLElement;
}

async function typeInto(container: HTMLElement, label: string, text: string) {
  const input = within(container).getByLabelText(label);
  await userEvent.clear(input);
  if (text) await userEvent.type(input, text);
}

describe("People in the Rails preview", () => {
  test("the fixtures match the people contract", () => {
    expect(peopleSchema.safeParse({ account: ACCOUNT, users: [row("5"), row(ACCOUNT, { self: true, role: "administrator" })] }).success).toBe(true);
    expect(personEnvelopeSchema.safeParse(envelope(ROWAN)).success).toBe(true);
  });

  test("a member is told people are for administrators and nothing is asked of the server", async () => {
    const server = standardServer();
    renderApp({ server, url: "/sub/preview/server/people/users/5" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(server.requests.filter((request) => request.path.includes("/admin/"))).toEqual([]);
  });

  test("an administrator whose role was taken away is refused and sees the same message", async () => {
    const server = peopleServer().on("GET", /\/admin\/users\/\d+$/, () => ({ status: 404, body: { error: "not_found" } }));
    renderApp({ server, url: "/sub/preview/server/people/users/5" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
  });

  test("People and access lists everyone with their role and links to each record and to adding someone", async () => {
    renderApp({ server: peopleServer(), url: "/sub/preview/server/people" });
    const people = await screen.findByRole("list", { name: "People" });
    const rows = within(people).getAllByRole("listitem");
    expect(rows.map((item) => item.textContent)).toEqual(["Rowan AshMemberrowanAdded Nov 2, 2026", "Ada ReaderYouAdministratoradaAdded Nov 2, 2026"]);
    expect(within(rows[0]!).getByRole("link", { name: "Rowan Ash" }).getAttribute("href")).toBe("/sub/preview/server/people/users/5");
    expect(screen.getByRole("link", { name: "Add a person" }).getAttribute("href")).toBe("/sub/preview/server/people/users/new");
    expect(screen.getByRole("heading", { name: "Sign-in rules", level: 3 })).toBeTruthy();
  });

  test("adding a person sends exactly what was entered and opens their record", async () => {
    const records: Record<string, PersonRecord> = { [SELF.id]: SELF };
    const server = peopleServer(records).on("POST", /\/admin\/users$/, (request) => {
      const body = request.body as { name: string; username: string; role: "member" | "administrator" };
      records["9"] = record("9", { name: body.name, username: body.username, role: body.role, requests: 0 });
      return { status: 201, body: envelope(records["9"]!) };
    });
    const { router } = renderApp({ server, url: "/sub/preview/server/people/users/new" });
    const form = (await screen.findByRole("heading", { name: "Their sign-in", level: 3 })).closest("section") as HTMLElement;

    await typeInto(form, "Name", "Sage Green");
    await typeInto(form, "Username", "sage");
    await typeInto(form, "Password", SECRET);
    await typeInto(form, "Confirm password", SECRET);
    await userEvent.click(within(form).getByRole("radio", { name: "Administrator" }));
    expect(within(form).getByText("Unsaved changes")).toBeTruthy();
    await userEvent.click(within(form).getByRole("button", { name: "Add person" }));

    expect(await screen.findByText("Sage Green was added as an administrator. They can sign in with the username sage and the password you chose.")).toBeTruthy();
    expect(router.state.location.pathname).toBe("/server/people/users/9");
    const post = server.called("POST", /\/admin\/users$/)[0]!;
    expect(post.body).toEqual({ name: "Sage Green", username: "sage", role: "administrator", password: SECRET, password_confirmation: SECRET });
    expect(post.headers["x-csrf-token"]).toBe("token-123");
    expect(post.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(document.body.textContent).not.toContain(SECRET);
  });

  test("an add with missing or mismatched fields is caught before sending, and the first field is focused", async () => {
    const server = peopleServer();
    renderApp({ server, url: "/sub/preview/server/people/users/new" });
    const form = (await screen.findByRole("heading", { name: "Their sign-in", level: 3 })).closest("section") as HTMLElement;
    await typeInto(form, "Username", "sage");
    await typeInto(form, "Password", SECRET);
    await typeInto(form, "Confirm password", "Other-Secret-42");
    await userEvent.click(within(form).getByRole("button", { name: "Add person" }));

    expect(within(form).getByText("Enter a display name.")).toBeTruthy();
    expect(within(form).getByText("This does not match the password.")).toBeTruthy();
    expect(document.activeElement).toBe(within(form).getByLabelText("Name"));
    expect(within(form).getByLabelText("Confirm password").getAttribute("aria-invalid")).toBe("true");
    expect(server.called("POST", /\/admin\/users$/)).toEqual([]);
  });

  test("an add the server refuses shows each field's message and stays on the form", async () => {
    const server = peopleServer().on("POST", /\/admin\/users$/, () => ({
      status: 422,
      body: { account: ACCOUNT, error: "invalid_user", errors: { username: ["has already been taken"], password: ["must include at least one lowercase letter, one uppercase letter, and one number"] } },
    }));
    const { router } = renderApp({ server, url: "/sub/preview/server/people/users/new" });
    const form = (await screen.findByRole("heading", { name: "Their sign-in", level: 3 })).closest("section") as HTMLElement;
    await typeInto(form, "Name", "Ada Two");
    await typeInto(form, "Username", "ada");
    await typeInto(form, "Password", "lowercaseonly1234");
    await typeInto(form, "Confirm password", "lowercaseonly1234");
    await userEvent.click(within(form).getByRole("button", { name: "Add person" }));

    expect(await within(form).findByText("Someone on this server already has this username. Choose another.")).toBeTruthy();
    expect(within(form).getByText("Include a lowercase letter (a–z), an uppercase letter (A–Z) and a number (0–9).")).toBeTruthy();
    expect(within(form).getByText("Nothing was saved. Check the marked fields.")).toBeTruthy();
    expect(document.activeElement).toBe(within(form).getByLabelText("Username"));
    expect(router.state.location.pathname).toBe("/server/people/users/new");
  });

  test("a record shows the classic details and saves name, username and role with the version it was read at", async () => {
    let current = ROWAN;
    const server = peopleServer().on("PUT", /\/admin\/users\/5$/, (request) => {
      const body = request.body as { name: string; username: string; role: "member" | "administrator" };
      current = { ...current, ...{ name: body.name, username: body.username, role: body.role }, version: "v-5-2" };
      return { body: envelope(current) };
    });
    renderApp({ server, url: "/sub/preview/server/people/users/5" });
    const details = (await screen.findByRole("heading", { name: "Details", level: 3 })).closest("section") as HTMLElement;
    expect(Array.from(details.querySelectorAll("dt, dd")).map((node) => node.textContent)).toEqual(["Username", "rowan", "Role", "Member", "Added", "Nov 2, 2026", "Requests", "3"]);
    expect(screen.getByRole("heading", { name: "Rowan Ash", level: 1 })).toBeTruthy();

    const profile = card("Name, username and role");
    await typeInto(profile, "Name", "Rowan Oak");
    await userEvent.click(within(profile).getByRole("radio", { name: "Administrator" }));
    await userEvent.click(within(profile).getByRole("button", { name: "Save changes" }));

    expect(await within(profile).findByText("Changes saved.")).toBeTruthy();
    expect(server.called("PUT", /\/admin\/users\/5$/).map((request) => request.body)).toEqual([{ name: "Rowan Oak", username: "rowan", role: "administrator", version: "v-5-1" }]);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Rowan Oak", level: 1 })).toBeTruthy());
    expect(within(profile).queryByText("Unsaved changes")).toBeNull();
  });

  test("a save against an older read shows the newer saved values with the edit on top and sends the new version next time", async () => {
    const changed = { ...ROWAN, username: "rowan_new", version: "v-5-2" };
    let attempts = 0;
    const server = peopleServer().on("PUT", /\/admin\/users\/5$/, (request) => {
      attempts += 1;
      if (attempts === 1) return { status: 409, body: { ...envelope(changed), error: "user_changed" } };
      return { body: envelope({ ...changed, name: (request.body as { name: string }).name, version: "v-5-3" }) };
    });
    renderApp({ server, url: "/sub/preview/server/people/users/5" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    const profile = card("Name, username and role");
    await typeInto(profile, "Name", "Rowan Oak");
    await userEvent.click(within(profile).getByRole("button", { name: "Save changes" }));

    expect(await within(profile).findByText("Someone else changed this person while you were editing. The form now shows what is saved, with your changes on top. Check it and save again.")).toBeTruthy();
    expect((within(profile).getByLabelText("Username") as HTMLInputElement).value).toBe("rowan_new");
    expect((within(profile).getByLabelText("Name") as HTMLInputElement).value).toBe("Rowan Oak");
    await userEvent.click(within(profile).getByRole("button", { name: "Save changes" }));
    expect(await within(profile).findByText("Changes saved.")).toBeTruthy();
    expect(server.called("PUT", /\/admin\/users\/5$/).map((request) => (request.body as { version: string }).version)).toEqual(["v-5-1", "v-5-2"]);
  });

  test("making yourself a member asks first, says when nobody else is an administrator, and is withdrawn when the form changes", async () => {
    let admin = true;
    const server = peopleServer()
      .on("GET", /\/api\/v1\/session$/, () => ({ body: session(admin ? ADMIN : {}) }))
      .on("GET", /\/admin\/users\/12$/, () => ({ body: envelope(SELF, 1) }))
      .on("PUT", /\/admin\/users\/12$/, () => {
        admin = false;
        return { body: envelope({ ...SELF, role: "member", version: "v-12-2" }, 0) };
      });
    const { services } = renderApp({ server, url: "/sub/preview/server/people/users/12" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    expect(screen.getByRole("heading", { name: "Ada Reader", level: 1 })).toBeTruthy();
    const profile = card("Name, username and role");

    await userEvent.click(within(profile).getByRole("radio", { name: "Member" }));
    await userEvent.click(within(profile).getByRole("button", { name: "Save changes" }));
    const question = within(profile).getByRole("group", { name: /Make yourself a member\?/ });
    expect(question.textContent).toContain("No one else is an administrator, so nobody will be able to change server settings or people in Shelfarr.");
    expect(document.activeElement).toBe(within(question).getByRole("button", { name: "Make me a member" }));
    expect(server.called("PUT", /\/admin\/users\/12$/)).toEqual([]);

    await typeInto(profile, "Name", "Ada R");
    expect(within(profile).queryByRole("group", { name: /Make yourself a member\?/ })).toBeNull();
    await userEvent.click(within(profile).getByRole("button", { name: "Save changes" }));
    await userEvent.click(within(profile).getByRole("button", { name: "Make me a member" }));

    await waitFor(() => expect(services.guard.getState().status).toBe("access_changed"));
    expect(server.called("PUT", /\/admin\/users\/12$/).map((request) => request.body)).toEqual([{ name: "Ada R", username: "ada", role: "member", version: "v-12-1" }]);
  }, 15000);

  test("your own record keeps password and removal with Account", async () => {
    renderApp({ server: peopleServer().on("GET", /\/admin\/users\/12$/, () => ({ body: envelope(SELF) })), url: "/sub/preview/server/people/users/12" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    expect(screen.getByRole("link", { name: "Open Sign-in and security" }).getAttribute("href")).toBe("/sub/preview/account/security");
    expect(screen.queryByLabelText("New password")).toBeNull();
    expect(screen.getByText("You cannot remove your own account. Another administrator can remove it.")).toBeTruthy();
    expect(screen.queryByRole("button", { name: /^Remove/ })).toBeNull();
  });

  test("setting a password sends both entries, clears them and never shows them", async () => {
    const server = peopleServer().on("PUT", /\/admin\/users\/5\/password$/, () => ({ body: envelope(ROWAN) }));
    renderApp({ server, url: "/sub/preview/server/people/users/5" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    const password = card("Set a new password");
    expect(within(password).getByLabelText("New password").getAttribute("autocomplete")).toBe("new-password");
    await typeInto(password, "New password", SECRET);
    await typeInto(password, "Confirm new password", SECRET);
    await userEvent.click(within(password).getByRole("button", { name: "Set password" }));

    expect(await within(password).findByText("New password set. Rowan Ash can sign in with it now. They stay signed in where they already are, and two-factor sign-in, if they use it, still asks for their code.")).toBeTruthy();
    expect(server.called("PUT", /\/password$/).map((request) => request.body)).toEqual([{ password: SECRET, password_confirmation: SECRET }]);
    expect((within(password).getByLabelText("New password") as HTMLInputElement).value).toBe("");
    expect(document.body.textContent).not.toContain(SECRET);
  });

  test("a refused or blank password is explained field by field and nothing else changes", async () => {
    const server = peopleServer().on("PUT", /\/password$/, () => ({ status: 422, body: { account: ACCOUNT, error: "invalid_user", errors: { password: ["is too short (minimum is 12 characters)"] } } }));
    renderApp({ server, url: "/sub/preview/server/people/users/5" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    const password = card("Set a new password");
    await userEvent.click(within(password).getByRole("button", { name: "Set password" }));
    expect(within(password).getByText("Enter a password.")).toBeTruthy();
    expect(server.called("PUT", /\/password$/)).toEqual([]);

    await typeInto(password, "New password", "Short1a");
    await typeInto(password, "Confirm new password", "Short1a");
    await userEvent.click(within(password).getByRole("button", { name: "Set password" }));
    expect(await within(password).findByText("Use at least 12 characters.")).toBeTruthy();
    expect(within(password).getByText("The password was not changed. Check the marked fields.")).toBeTruthy();
  });

  test("removing asks first, sends the version on screen and returns to the list without them", async () => {
    const records: Record<string, PersonRecord> = { [SELF.id]: SELF, [ROWAN.id]: ROWAN };
    const server = peopleServer(records).on("POST", /\/admin\/users\/5\/remove$/, () => {
      delete records["5"];
      return { body: { account: ACCOUNT, removed: "5" } };
    });
    const { router } = renderApp({ server, url: "/sub/preview/server/people/users/5" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    const remove = card("Remove");
    expect(within(remove).getByText(/Their requests and reading history stay on the server/)).toBeTruthy();
    await userEvent.click(within(remove).getByRole("button", { name: "Remove Rowan Ash" }));
    expect(within(remove).getByRole("group", { name: "Remove Rowan Ash (rowan) from this server?" })).toBeTruthy();
    await userEvent.click(within(remove).getByRole("button", { name: "Remove" }));

    expect(await screen.findByText("Rowan Ash was removed.")).toBeTruthy();
    expect(router.state.location.pathname).toBe("/server/people");
    expect(server.called("POST", /\/remove$/).map((request) => request.body)).toEqual([{ version: "v-5-1" }]);
    const people = await screen.findByRole("list", { name: "People" });
    await waitFor(() => expect(within(people).queryByText("Rowan Ash")).toBeNull());
  });

  test("an open removal question follows the record on screen and is withdrawn when it changes", async () => {
    let current = ROWAN;
    const server = peopleServer().on("GET", /\/admin\/users\/5$/, () => ({ body: envelope(current) }));
    const { services } = renderApp({ server, url: "/sub/preview/server/people/users/5" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    await userEvent.click(within(card("Remove")).getByRole("button", { name: "Remove Rowan Ash" }));
    expect(within(card("Remove")).getByRole("group", { name: "Remove Rowan Ash (rowan) from this server?" })).toBeTruthy();

    current = { ...ROWAN, name: "Rowan Oak", version: "v-5-2" };
    await act(async () => services.queryClient.invalidateQueries({ predicate: (query) => query.queryKey.includes("person") }));
    await waitFor(() => expect(within(card("Remove")).getByRole("button", { name: "Remove Rowan Oak" })).toBeTruthy());
    expect(within(card("Remove")).queryByRole("group")).toBeNull();
    expect(server.called("POST", /\/remove$/)).toEqual([]);
  });

  test("a removal refused because the record changed says so and keeps them", async () => {
    const server = peopleServer().on("POST", /\/remove$/, () => ({ status: 409, body: { ...envelope({ ...ROWAN, username: "rowan2", version: "v-5-2" }), error: "user_changed" } }));
    const { router } = renderApp({ server, url: "/sub/preview/server/people/users/5" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    await userEvent.click(within(card("Remove")).getByRole("button", { name: "Remove Rowan Ash" }));
    await userEvent.click(within(card("Remove")).getByRole("button", { name: "Remove" }));

    expect(await screen.findByText("Someone else changed this person since you opened the page. Nothing was removed. Check the details above and remove again if you still want to.")).toBeTruthy();
    expect(router.state.location.pathname).toBe("/server/people/users/5");
    expect(within(card("Details")).getByText("rowan2")).toBeTruthy();
  });

  test("a removed person's address says they are not on this server", async () => {
    renderApp({ server: peopleServer({ [SELF.id]: SELF }), url: "/sub/preview/server/people/users/5" });
    expect(await screen.findByRole("heading", { name: "This person is not on this server" })).toBeTruthy();
  });

  test("a write that lost administrator access says nothing changed and checks the account again", async () => {
    let admin = true;
    const server = peopleServer()
      .on("GET", /\/api\/v1\/session$/, () => ({ body: session(admin ? ADMIN : {}) }))
      .on("PUT", /\/admin\/users\/5$/, () => {
        admin = false;
        return { status: 404, body: { error: "not_found" } };
      });
    const { services } = renderApp({ server, url: "/sub/preview/server/people/users/5" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    const profile = card("Name, username and role");
    await typeInto(profile, "Name", "Rowan Oak");
    await userEvent.click(within(profile).getByRole("button", { name: "Save changes" }));
    await waitFor(() => expect(services.guard.getState().status).toBe("access_changed"));
  }, 15000);

  test("a write whose answer never arrives does not claim success or failure, and a second write waits", async () => {
    const held = deferred<{ status: number; body: unknown }>();
    const server = peopleServer().on("PUT", /\/admin\/users\/5$/, () => held.promise);
    renderApp({ server, url: "/sub/preview/server/people/users/5" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    const profile = card("Name, username and role");
    await typeInto(profile, "Name", "Rowan Oak");
    await userEvent.click(within(profile).getByRole("button", { name: "Save changes" }));
    expect((within(profile).getByRole("button", { name: "Saving…" }) as HTMLButtonElement).disabled).toBe(true);
    expect((within(card("Set a new password")).getByRole("button", { name: "Set password" }) as HTMLButtonElement).disabled).toBe(true);

    held.resolve({ status: 503, body: null });
    expect(await within(profile).findByText("Shelfarr could not confirm whether this was saved. Reload the page to see what the server has, and try again if needed.")).toBeTruthy();
    expect((within(profile).getByLabelText("Name") as HTMLInputElement).value).toBe("Rowan Oak");
  });

  test("leaving with an unsaved edit asks first", async () => {
    renderApp({ server: peopleServer(), url: "/sub/preview/server/people/users/5" });
    await screen.findByRole("heading", { name: "Details", level: 3 });
    await typeInto(card("Name, username and role"), "Name", "Rowan Oak");
    await userEvent.click(document.querySelector<HTMLAnchorElement>(".people-back a")!);
    expect(await screen.findByRole("dialog", { name: "Leave without saving?" })).toBeTruthy();
  });

  test("the overview links its Users count to People", async () => {
    const server = peopleServer().on("GET", /\/admin\/overview$/, () => ({
      body: {
        account: ACCOUNT,
        counts: { users: 2, books: 0, active_requests: 0, attention_requests: 0 },
        services: ["indexer", "download_client", "download_paths", "output_paths", "audiobookshelf", "hardcover"].map((service) => ({ service, status: null, checked_at: null })),
        pending: [],
      },
    }));
    renderApp({ server, url: "/sub/preview/server" });
    expect((await screen.findByRole("link", { name: "Manage people" })).getAttribute("href")).toBe("/sub/preview/server/people#users");
  });

  test("other runtimes do not offer the people pages", async () => {
    const server = new FakeServer().on("GET", /\/api\/v1\/session$/, () => ({ body: session(ADMIN) }));
    renderApp({ server, url: "/sub/preview/server/people/users/abc" });
    expect(await screen.findByRole("heading", { name: "That page is not part of this preview" })).toBeTruthy();
    expect(server.requests.filter((request) => request.path.includes("/admin/users"))).toEqual([]);
  });
});
