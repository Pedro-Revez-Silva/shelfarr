import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { activityLogSchema, type ActivityEntry, type ActivityLog } from "../src/server/activity/contract";
import type { ServerSettings } from "../src/server/contract";
import { libraryServer, renderGo, signedIn } from "./go-helpers";
import { ACCOUNT, deferred, renderApp, session, standardServer, type FakeServer, type RecordedRequest } from "./helpers";

afterEach(cleanup);

const ADMIN = { admin: { url: "/sub/admin" }, capabilities: { administrator: true, can_upload: true, single_sign_on: false, hardcover_personal_access: false } };
const ROWAN = { id: "5", name: "Rowan Ash", removed: false };
const GONE = { id: "6", name: "Gone Reader", removed: true };

function entry(id: string, overrides: Partial<ActivityEntry> = {}): ActivityEntry {
  return { id, at: "2026-11-22T09:30:00.000Z", action: "user.login", actor: ROWAN, subject: null, details: {}, ...overrides };
}

const ENTRIES: ActivityEntry[] = [
  entry("9", { action: "request.completed", actor: null }),
  entry("8", { action: "request.created", subject: { kind: "request", id: "41", title: "The Dispossessed" }, details: { via: "telegram" } }),
  entry("7", { action: "admin.user_updated", subject: { kind: "person", ...GONE } }),
  entry("6", { action: "upload.manually_matched", subject: { kind: "book", id: "17", title: "Kindred", in_library: true }, details: { match: "existing" } }),
  entry("5", { action: "book.deleted", actor: GONE, subject: { kind: "book", id: "18", title: "Gone Book", in_library: false } }),
  entry("4", { action: "user.api_token_created", details: { scopes: ["search:read", "requests:write"] } }),
];

function log(overrides: Partial<ActivityLog> = {}): ActivityLog {
  return { account: ACCOUNT, limit: 100, more: false, entries: ENTRIES, people: [{ id: ACCOUNT, name: "Ada Reader", removed: false }, GONE, ROWAN], actions: ["admin.user_updated", "request.created", "user.login"], ...overrides };
}

function settings(): ServerSettings {
  return {
    account: ACCOUNT,
    categories: [{ id: "system", title: "System", summary: "Health checks and updates.", groups: [{ id: "queue", title: "Queue", summary: "Health check interval.", fields: [], advanced: [], probes: [], extras: [], notes: [] }] }],
    notes: { path_variables: "", hardcover_app: { create_url: "https://hardcover.app/new", scopes: "read:me", redirect_uri: "https://shelf.test/cb", redirect_uri_acceptable: true } },
    roles: [],
  };
}

type Answer = { status?: number; body?: unknown };

function activityServer(answer: (request: RecordedRequest) => Answer | Promise<Answer> = () => ({ body: log() }), sessionOverrides: object = ADMIN): FakeServer {
  return standardServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(sessionOverrides) }))
    .on("GET", /\/api\/v1\/admin\/settings$/, () => ({ body: settings() }))
    .on("GET", /\/api\/v1\/admin\/setup$/, () => ({ body: { account: ACCOUNT } }))
    .on("GET", /\/api\/v1\/admin\/activity(\?|$)/, answer);
}

function reads(server: FakeServer): string[] {
  return server.called("GET", /\/api\/v1\/admin\/activity(\?|$)/).map((request) => request.path);
}

function count(): string | null | undefined {
  return document.querySelector(".activity-count")?.textContent;
}

function rows(): HTMLElement[] {
  return within(screen.getByRole("region", { name: "Activity, newest first" })).getAllByRole("row").slice(1);
}

describe("Activity log in the Rails preview", () => {
  test("the fixtures match the activity contract", () => {
    expect(activityLogSchema.safeParse(log()).success).toBe(true);
    expect(activityLogSchema.safeParse(log({ entries: [entry("1", { details: { via: "carrier pigeon" } as never })] })).success).toBe(false);
  });

  test("an administrator reads every entry with who did it, the action, what it was about and links only where they can go", async () => {
    const server = activityServer();
    renderApp({ server, url: "/sub/preview/server/system/activity" });
    expect(await screen.findByRole("heading", { level: 1, name: "Activity log" })).toBeTruthy();
    await screen.findByRole("region", { name: "Activity, newest first" });
    expect(reads(server)).toEqual(["/sub/preview/api/v1/admin/activity"]);
    expect(server.called("GET", /\/admin\/activity/)[0]?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(count()).toBe("6 entries");
    expect(document.title).toStartWith("Activity log · Server");
    expect(within(screen.getByRole("navigation", { name: "Server" })).getByRole("link", { name: "System" }).getAttribute("aria-current")).toBe("page");
    expect(document.querySelector(".activity-back a")?.getAttribute("href")).toBe("/sub/preview/server/system");

    const text = rows().map((row) => [...row.querySelectorAll("th, td")].map((cell) => cell.textContent));
    const when = new Intl.DateTimeFormat("en", { dateStyle: "long", timeStyle: "short" }).format(new Date("2026-11-22T09:30:00.000Z"));
    expect(text).toEqual([
      [when, "System", "request.completed", ""],
      [when, "Rowan Ash", "request.created", "The DispossessedRequested from Telegram"],
      [when, "Rowan Ash", "admin.user_updated", "Gone Reader (removed)"],
      [when, "Rowan Ash", "upload.manually_matched", "KindredMatched to a book already on the server"],
      [when, "Gone Reader (removed)", "book.deleted", "Gone Book"],
      [when, "Rowan Ash", "user.api_token_created", "Scopes: search:read, requests:write"],
    ]);
    const links = rows().map((row) => within(row).queryAllByRole("link").map((link) => [link.textContent, link.getAttribute("href")]));
    expect(links).toEqual([
      [],
      [["Rowan Ash", "/sub/preview/server/people/users/5"], ["The Dispossessed", "/sub/preview/requests/41"]],
      [["Rowan Ash", "/sub/preview/server/people/users/5"]],
      [["Rowan Ash", "/sub/preview/server/people/users/5"], ["Kindred", "/sub/preview/library/17"]],
      [],
      [["Rowan Ash", "/sub/preview/server/people/users/5"]],
    ]);
    expect(rows()[0]?.querySelector(".badge")?.className).toBe("badge activity-action badge--completed");
    expect(rows()[4]?.querySelector(".badge")?.className).toBe("badge activity-action badge--failed");
    expect(rows()[2]?.querySelector(".badge")?.className).toBe("badge activity-action");
  });

  test("filters in the address are sent with the classic names and shown in the form", async () => {
    const server = activityServer();
    renderApp({ server, url: "/sub/preview/server/system/activity?user=5&action=user.login&from=2026-11-21" });
    await screen.findByRole("region", { name: "Activity, newest first" });
    expect(reads(server)).toEqual(["/sub/preview/api/v1/admin/activity?user_id=5&action_filter=user.login&from=2026-11-21"]);
    expect((screen.getByLabelText("Person") as HTMLSelectElement).value).toBe("5");
    expect((screen.getByLabelText("Action") as HTMLSelectElement).value).toBe("user.login");
    expect((screen.getByLabelText("From") as HTMLInputElement).value).toBe("2026-11-21");
    expect(within(screen.getByLabelText("Person")).getAllByRole("option").map((option) => option.textContent)).toEqual(["Everyone", "Ada Reader", "Gone Reader (removed)", "Rowan Ash"]);
    expect(screen.getByRole("link", { name: "Clear filters" }).getAttribute("href")).toBe("/sub/preview/server/system/activity");
  });

  test("filters the server could not use are left out of the address instead of being sent", async () => {
    const server = activityServer();
    renderApp({ server, url: "/sub/preview/server/system/activity?user=abc&from=2026-02-30&action=" });
    await screen.findByRole("region", { name: "Activity, newest first" });
    expect(reads(server)).toEqual(["/sub/preview/api/v1/admin/activity"]);
    expect(screen.queryByRole("link", { name: "Clear filters" })).toBeNull();
  });

  test("choosing filters and pressing Filter reads the matching entries, keeping the form while they load", async () => {
    const later = deferred<Answer>();
    const server = activityServer((request) => (request.path.includes("?") ? later.promise : { body: log() }));
    const { router } = renderApp({ server, url: "/sub/preview/server/system/activity" });
    await screen.findByRole("region", { name: "Activity, newest first" });
    const user = userEvent.setup();
    await user.selectOptions(screen.getByLabelText("Person"), "5");
    await user.selectOptions(screen.getByLabelText("Action"), "request.created");
    expect(reads(server)).toHaveLength(1);
    await user.click(screen.getByRole("button", { name: "Filter" }));
    await waitFor(() => expect(reads(server)).toEqual(["/sub/preview/api/v1/admin/activity", "/sub/preview/api/v1/admin/activity?user_id=5&action_filter=request.created"]));
    expect(router.state.location.search).toEqual({ user: "5", action: "request.created" });
    expect(count()).toBe("");
    expect(screen.getByText("Loading the activity log…")).toBeTruthy();
    expect(screen.queryByRole("region", { name: "Activity, newest first" })).toBeNull();
    expect((screen.getByLabelText("Person") as HTMLSelectElement).value).toBe("5");
    await act(async () => later.resolve({ body: log({ entries: [ENTRIES[1]!] }) }));
    expect(await screen.findByText("1 entry")).toBeTruthy();
    expect(rows()).toHaveLength(1);
  });

  test("an empty log and an empty filtered result are told apart", async () => {
    const server = activityServer(() => ({ body: log({ entries: [] }) }));
    renderApp({ server, url: "/sub/preview/server/system/activity" });
    expect(await screen.findByRole("heading", { name: "No activity yet" })).toBeTruthy();
    cleanup();
    renderApp({ server, url: "/sub/preview/server/system/activity?action=user.logout" });
    expect(await screen.findByRole("heading", { name: "No activity matches these filters" })).toBeTruthy();
    expect(screen.getByRole("link", { name: "Show all activity" }).getAttribute("href")).toBe("/sub/preview/server/system/activity");
    expect(within(screen.getByLabelText("Action")).getAllByRole("option").map((option) => option.textContent)).toEqual(["All actions", "admin.user_updated", "request.created", "user.login", "user.logout"]);
  });

  test("a person filter for someone no longer listed keeps its choice and says so", async () => {
    const server = activityServer(() => ({ body: log({ entries: [] }) }));
    renderApp({ server, url: "/sub/preview/server/system/activity?user=77" });
    await screen.findByRole("heading", { name: "No activity matches these filters" });
    const select = screen.getByLabelText("Person") as HTMLSelectElement;
    expect(select.value).toBe("77");
    expect(select.selectedOptions[0]?.textContent).toBe("Someone no longer on this server");
  });

  test("a full page says only the most recent entries are shown", async () => {
    const many = Array.from({ length: 100 }, (_, index) => entry(String(200 - index)));
    renderApp({ server: activityServer(() => ({ body: log({ entries: many, more: true }) })), url: "/sub/preview/server/system/activity" });
    expect(await screen.findByText("Showing the 100 most recent entries. Narrow the filters to see older ones.")).toBeTruthy();
    expect(rows()).toHaveLength(100);
  });

  test("a slow first read shows that it is loading, and a failure can be tried again", async () => {
    const first = deferred<Answer>();
    let failing = true;
    const server = activityServer(() => (failing ? first.promise : { body: log() }));
    renderApp({ server, url: "/sub/preview/server/system/activity" });
    expect(await screen.findByText("Loading the activity log…")).toBeTruthy();
    await act(async () => first.resolve({ status: 500, body: { error: "server_error" } }));
    const alert = await screen.findByRole("alert", {}, { timeout: 6000 });
    expect(within(alert).getByRole("heading", { name: "Your server had a problem" })).toBeTruthy();
    expect(reads(server)).toHaveLength(3);
    failing = false;
    await userEvent.setup().click(within(alert).getByRole("button", { name: "Try again" }));
    expect(await screen.findByText("6 entries")).toBeTruthy();
  }, 10_000);

  test("a filtered read that fails keeps the form and offers to try again", async () => {
    let failing = true;
    const server = activityServer((request) => (request.path.includes("?") && failing ? { status: 500, body: { error: "server_error" } } : { body: log() }));
    renderApp({ server, url: "/sub/preview/server/system/activity" });
    await screen.findByRole("region", { name: "Activity, newest first" });
    const user = userEvent.setup();
    await user.selectOptions(screen.getByLabelText("Action"), "user.login");
    await user.click(screen.getByRole("button", { name: "Filter" }));
    expect(await screen.findByText("The activity log could not be loaded.", {}, { timeout: 6000 })).toBeTruthy();
    expect(screen.queryByRole("region", { name: "Activity, newest first" })).toBeNull();
    expect((screen.getByLabelText("Action") as HTMLSelectElement).value).toBe("user.login");
    failing = false;
    await user.click(within(screen.getByRole("alert")).getByRole("button", { name: "Try again" }));
    expect(await screen.findByText("6 entries")).toBeTruthy();
  }, 10_000);

  test("a member is told the log is for administrators and nothing is asked of the server", async () => {
    const server = standardServer();
    renderApp({ server, url: "/sub/preview/server/system/activity" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(screen.queryByRole("navigation", { name: "Server" })).toBeNull();
    expect(server.requests.filter((request) => request.path.includes("/admin/"))).toEqual([]);
  });

  test("an administrator whose role was taken away sees the same refusal and no entries", async () => {
    renderApp({ server: activityServer(() => ({ status: 404, body: { error: "not_found" } })), url: "/sub/preview/server/system/activity" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(screen.queryByText("Rowan Ash")).toBeNull();
  });

  test("an answer for another account locks the page and shows none of its entries", async () => {
    const { services } = renderApp({ server: activityServer(() => ({ body: log({ account: "99" }) })), url: "/sub/preview/server/system/activity" });
    expect(await screen.findByRole("heading", { name: "The signed-in account changed" })).toBeTruthy();
    expect(services.guard.getState().status).toBe("account_changed");
    expect(screen.queryByText("Rowan Ash")).toBeNull();
  });

  test("a read still on its way when the account changes is never shown", async () => {
    const answer = deferred<Answer>();
    const { services } = renderApp({ server: activityServer(() => answer.promise), url: "/sub/preview/server/system/activity" });
    await screen.findByText("Loading the activity log…");
    act(() => services.guard.lock("account_changed"));
    await act(async () => answer.resolve({ body: log() }));
    expect(await screen.findByRole("heading", { name: "The signed-in account changed" })).toBeTruthy();
    expect(screen.queryByText("Rowan Ash")).toBeNull();
  });

  test("System opens the activity log from its own card", async () => {
    const server = activityServer();
    renderApp({ server, url: "/sub/preview/server/system" });
    const card = (await screen.findByRole("heading", { level: 3, name: "Activity log" })).closest("section") as HTMLElement;
    expect(within(screen.getByRole("navigation", { name: "System cards" })).getByRole("link", { name: "Activity log" }).getAttribute("href")).toBe("#activity");
    await userEvent.setup().click(within(card).getByRole("link", { name: "Open the activity log" }));
    expect(await screen.findByRole("heading", { level: 1, name: "Activity log" })).toBeTruthy();
    expect(await screen.findByText("6 entries")).toBeTruthy();
  });

  test("a root deployment reads and links from the root preview path", async () => {
    const server = activityServer();
    renderApp({ server, url: "/preview/server/system/activity?action=request.created", mount: "/preview", boot: { version: 1, account: ACCOUNT, mount: "/preview", api: "/preview/api/v1", classic_library: "/read" } });
    await screen.findByRole("region", { name: "Activity, newest first" });
    expect(reads(server)).toEqual(["/preview/api/v1/admin/activity?action_filter=request.created"]);
    expect(within(rows()[1]!).getByRole("link", { name: "The Dispossessed" }).getAttribute("href")).toBe("/preview/requests/41");
    expect(screen.getByRole("link", { name: "Clear filters" }).getAttribute("href")).toBe("/preview/server/system/activity");
  });

  test("the experimental Go server does not offer the activity log", async () => {
    const server = libraryServer(() => signedIn());
    renderGo({ server, url: "/preview/server/system/activity" });
    expect(await screen.findByRole("heading", { name: "That page is not part of this preview" })).toBeTruthy();
    expect(server.requests.filter((request) => request.path.includes("/admin/activity"))).toEqual([]);
  });
});
