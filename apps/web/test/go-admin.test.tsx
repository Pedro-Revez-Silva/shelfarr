import { describe, expect, test } from "bun:test";
import { createMemoryHistory } from "@tanstack/react-router";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { App } from "../src/App";
import { resetFirstPage } from "../src/components/PageHeading";
import { serverOverviewSchema, type ServerOverview } from "../src/contract";
import { createAppRouter } from "../src/router";
import { createServices } from "../src/services";
import { ACCOUNT, FakeServer, page, renderApp, session, summary } from "./helpers";
import { error, renderGo, signedOut } from "./go-helpers";

const OVERVIEW = /\/api\/v1\/admin\/overview$/;
const SESSION = /\/api\/v1\/session$/;

function overview(overrides: Partial<ServerOverview> = {}): ServerOverview {
  return {
    account: ACCOUNT,
    counts: { users: 3, books: 1234, active_requests: 4, attention_requests: 3 },
    services: [
      { service: "indexer", status: "down", checked_at: "2026-11-15T11:55:00.123Z" },
      { service: "download_client", status: "degraded", checked_at: "2026-11-12T08:00:00.000Z" },
      { service: "download_paths", status: null, checked_at: null },
      { service: "output_paths", status: "healthy", checked_at: "2026-10-01T07:30:00.000Z" },
      { service: "audiobookshelf", status: "not_configured", checked_at: null },
      { service: "hardcover", status: "unknown", checked_at: "2026-11-15T11:00:00.000Z" },
    ],
    ...overrides,
  };
}

const calm: ServerOverview = overview({
  counts: { users: 1, books: 0, active_requests: 0, attention_requests: 0 },
  services: overview().services.map((entry) => ({ ...entry, status: entry.status === "down" || entry.status === "degraded" ? "healthy" : entry.status })),
});

function adminServer(options: { admin?: () => boolean; answer?: () => ReturnType<Parameters<FakeServer["on"]>[2]> } = {}): FakeServer {
  const admin = options.admin ?? (() => true);
  return new FakeServer()
    .on("GET", SESSION, () => ({ body: session(admin() ? { admin: { url: "/admin" } } : {}) }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", /\/api\/v1\/requests(\?|$)/, () => ({
      body: { account: ACCOUNT, scope: admin() ? "all" : "own", filter: { status: null, attention: true, q: null }, counts: { attention: 0, active: 0 }, page: 1, per_page: 25, total: 0, total_pages: 1, items: [] },
    }))
    .on("GET", OVERVIEW, options.answer ?? (() => ({ body: overview() })));
}

function renderAdmin(server: FakeServer, url = "/preview/admin") {
  resetFirstPage();
  const services = createServices({
    boot: { version: 1, account: ACCOUNT, mount: "/preview", api: "/preview/api/v1", classic_library: null, runtime: "go" },
    csrfToken: () => "session-token",
    fetcher: server.fetcher,
  });
  const history = createMemoryHistory({ initialEntries: [url] });
  const router = createAppRouter({ basepath: "/preview", history });
  const view = render(<App services={services} router={router} />);
  return { services, history, view };
}

function healthRows() {
  const list = screen.getByRole("heading", { name: "System health", level: 2 }).closest("section")!.querySelector("ul")!;
  return within(list)
    .getAllByRole("listitem")
    .map((item) => item.textContent);
}

describe("the server overview contract", () => {
  test("accepts the six services in order with saved, missing and unknown results, and refuses anything else", () => {
    expect(serverOverviewSchema.safeParse(overview()).success).toBe(true);
    expect(serverOverviewSchema.safeParse(overview({ services: overview().services.slice(1) })).success).toBe(false);
    expect(serverOverviewSchema.safeParse(overview({ services: [...overview().services].reverse() })).success).toBe(false);
    expect(serverOverviewSchema.safeParse(overview({ services: [...overview().services, overview().services[0]!] })).success).toBe(false);
    expect(serverOverviewSchema.safeParse({ ...overview(), services: overview().services.map((entry) => ({ ...entry, status: "offline" })) }).success).toBe(false);
    expect(serverOverviewSchema.safeParse(overview({ counts: { users: -1, books: 0, active_requests: 0, attention_requests: 0 } })).success).toBe(false);
    expect(serverOverviewSchema.safeParse({ ...overview(), services: overview().services.map((entry) => ({ ...entry, message: "secret" })) }).success).toBe(true);
  });
});

describe("the server overview", () => {
  test("an admin finds Admin beside Account and sees the build, the Rails counts and every saved health result", async () => {
    const server = adminServer();
    renderAdmin(server);
    expect(await screen.findByRole("heading", { name: "Needs attention", level: 2 })).toBeTruthy();
    expect(screen.getByRole("heading", { name: "Server overview", level: 1 })).toBeTruthy();
    expect(document.title).toBe("Server overview · Shelfarr");
    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(within(nav).getAllByRole("link").map((link) => link.textContent)).toEqual(["Library", "Discover", "Requests", "Account", "Admin"]);
    expect(within(nav).getByRole("link", { name: "Admin" }).getAttribute("href")).toBe("/preview/admin");
    expect(within(nav).getByRole("link", { name: "Admin" }).getAttribute("aria-current")).toBe("page");
    const build = screen.getByText("Build").closest("dl")!;
    expect(build.textContent).toBe("Build1.0.0");
    const tallies = [...document.querySelectorAll(".overview-counts > div")].map((tally) => [tally.querySelector("dt")!.textContent, tally.querySelector("dd")!.textContent]);
    expect(tallies).toEqual([
      ["Users", "3"],
      ["Books", "1,234"],
      ["Requests in progress", "4"],
      ["Need attention", "3"],
    ]);
    const attention = screen.getByRole("heading", { name: "Needs attention", level: 2 }).closest("section")!;
    expect(within(attention).getAllByRole("listitem").map((item) => item.textContent)).toEqual(["⚠ Indexer is down", "⚠ Download client is degraded", "⚠ 3 requests need attentionReview requests"]);
    expect(within(attention).getByRole("link", { name: "Review requests" }).getAttribute("href")).toBe("/preview/requests?attention=true");
    expect(screen.getByText("Saved results from the last health check. Opening this page does not run a check.")).toBeTruthy();
    const rows = healthRows();
    expect(rows.map((row) => row?.replace(/Checked .*/, "Checked <time>"))).toEqual([
      "Indexer⚠DownChecked <time>",
      "Download client⚠DegradedChecked <time>",
      "Download pathsNever checked",
      "Output pathsHealthyChecked <time>",
      "Library platformNot configuredNot checked yet",
      "HardcoverUnknown statusChecked <time>",
    ]);
    expect([...document.querySelectorAll(".health-list time")].map((time) => time.getAttribute("datetime"))).toEqual(["2026-11-15T11:55:00.123Z", "2026-11-12T08:00:00.000Z", "2026-10-01T07:30:00.000Z", "2026-11-15T11:00:00.000Z"]);
    expect(screen.queryByRole("button", { name: /check|update|run/i })).toBeNull();
    expect(server.called("GET", OVERVIEW).length).toBe(1);
    expect(server.requests.filter((request) => request.method !== "GET")).toEqual([]);
    expect(server.called("GET", OVERVIEW)[0]!.headers["x-shelfarr-account"]).toBe(ACCOUNT);
  });

  test("nothing to attend to says so without a link, and a single request reads in the singular", async () => {
    const server = adminServer({ answer: () => ({ body: calm }) });
    const { view } = renderAdmin(server);
    const attention = (await screen.findByRole("heading", { name: "Needs attention", level: 2 })).closest("section")!;
    expect(attention.textContent).toBe("Needs attentionNothing needs attention in the saved results.");
    expect(within(attention).queryByRole("link")).toBeNull();
    view.unmount();
    renderAdmin(adminServer({ answer: () => ({ body: { ...calm, counts: { ...calm.counts, attention_requests: 1 } } }) }));
    const single = (await screen.findByRole("heading", { name: "Needs attention", level: 2 })).closest("section")!;
    expect(within(single).getAllByRole("listitem").map((item) => item.textContent)).toEqual(["⚠ 1 request needs attentionReview requests"]);
  });

  test("Review requests opens the Requests page on its attention filter, and Back returns to the overview", async () => {
    const server = adminServer();
    const { history } = renderAdmin(server);
    await userEvent.click(await screen.findByRole("link", { name: "Review requests" }));
    await waitFor(() => expect(`${history.location.pathname}${history.location.search}`).toBe("/preview/requests?attention=true"));
    await waitFor(() => expect(server.called("GET", /\/api\/v1\/requests\?attention=true$/).length).toBe(1));
    act(() => history.back());
    expect(await screen.findByRole("heading", { name: "Server overview", level: 1 })).toBeTruthy();
    expect(await screen.findByRole("heading", { name: "Needs attention", level: 2 })).toBeTruthy();
  });

  test("a member sees no Admin link, and opening the page directly asks for no server data", async () => {
    const server = adminServer({ admin: () => false });
    renderAdmin(server);
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page", level: 2 })).toBeTruthy();
    expect(within(screen.getByRole("navigation", { name: "Primary" })).queryByRole("link", { name: "Admin" })).toBeNull();
    expect(screen.queryByText("Build")).toBeNull();
    expect(server.called("GET", OVERVIEW).length).toBe(0);
  });

  test("a role removed while the page is open locks it on the next session check and drops what it showed", async () => {
    let admin = true;
    const server = adminServer({ admin: () => admin });
    const { services } = renderAdmin(server);
    expect(await screen.findByText("1,234")).toBeTruthy();
    admin = false;
    await act(async () => services.revalidate());
    expect(await screen.findByRole("heading", { name: "This account's access changed", level: 1 })).toBeTruthy();
    expect(screen.queryByText("1,234")).toBeNull();
    expect(screen.queryByText("Indexer")).toBeNull();
    expect(services.queryClient.getQueryCache().getAll().length).toBe(0);
  });

  test("an overview the server no longer gives has the session checked, and the lost role locks the page", async () => {
    let admin = true;
    const server = adminServer({ admin: () => admin, answer: () => (admin ? { body: overview() } : error(404, "not_found")) });
    const { services } = renderAdmin(server);
    expect(await screen.findByText("1,234")).toBeTruthy();
    const checks = server.called("GET", SESSION).length;
    admin = false;
    await act(async () => {
      await services.queryClient.refetchQueries({ queryKey: services.keys.serverOverview }).catch(() => undefined);
    });
    expect(await screen.findByRole("heading", { name: "This account's access changed", level: 1 })).toBeTruthy();
    expect(server.called("GET", SESSION).length).toBeGreaterThan(checks);
    expect(services.queryClient.getQueryCache().getAll().length).toBe(0);
  });

  test("a session check that cannot confirm the account drops the cached overview instead of keeping it on screen", async () => {
    let failing = false;
    const server = new FakeServer()
      .on("GET", SESSION, () => (failing ? error(503, "database_busy") : { body: session({ admin: { url: "/admin" } }) }))
      .on("GET", OVERVIEW, () => (failing ? error(503, "database_busy") : { body: overview() }));
    const { services } = renderAdmin(server);
    expect(await screen.findByText("1,234")).toBeTruthy();
    failing = true;
    await act(async () => services.revalidate());
    await waitFor(() => expect(screen.queryByText("1,234")).toBeNull(), { timeout: 4000 });
    expect(services.queryClient.getQueriesData({ queryKey: services.keys.serverOverview }).filter(([, data]) => data !== undefined)).toEqual([]);
    expect(screen.getByRole("heading", { level: 1 }).textContent).toBe("Server overview");
    failing = false;
    await act(async () => services.revalidate());
    expect(await screen.findByText("1,234", {}, { timeout: 8000 })).toBeTruthy();
  }, 20_000);

  test("an overview refused while the session cannot be confirmed says it is for administrators, not that something is missing", async () => {
    let refused = false;
    const server = new FakeServer()
      .on("GET", SESSION, () => (refused ? error(503, "database_busy") : { body: session({ admin: { url: "/admin" } }) }))
      .on("GET", OVERVIEW, () => (refused ? error(404, "not_found") : { body: overview() }));
    const { services } = renderAdmin(server);
    expect(await screen.findByText("1,234")).toBeTruthy();
    refused = true;
    await act(async () => {
      await services.queryClient.refetchQueries({ queryKey: services.keys.serverOverview }).catch(() => undefined);
    });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page", level: 2 }, { timeout: 8000 })).toBeTruthy();
    expect(screen.queryByText("1,234")).toBeNull();
    expect(screen.queryByText(/not in your library/)).toBeNull();
  }, 20_000);

  test("an overview for another account locks the page and is never shown", async () => {
    const server = adminServer({ answer: () => ({ body: overview({ account: "99" }) }) });
    const { services } = renderAdmin(server);
    expect(await screen.findByRole("heading", { name: "The signed-in account changed", level: 1 })).toBeTruthy();
    expect(screen.queryByText("1,234")).toBeNull();
    expect(services.queryClient.getQueryCache().getAll().length).toBe(0);
  });

  test("a server failure keeps the page and offers to try again", async () => {
    let failing = true;
    const server = adminServer({ answer: () => (failing ? error(503, "database_unavailable") : { body: overview() }) });
    renderAdmin(server);
    const retry = await screen.findByRole("button", { name: "Try again" }, { timeout: 8000 });
    expect(screen.getByRole("alert").textContent).toContain("Your server had a problem");
    failing = false;
    await userEvent.click(retry);
    expect(await screen.findByText("1,234")).toBeTruthy();
  }, 15_000);

  test("the classic preview does not offer this page and keeps its Admin handoff", async () => {
    const server = adminServer();
    renderApp({ server, url: "/sub/preview/admin" });
    expect(await screen.findByRole("heading", { name: "That page is not part of this preview", level: 2 })).toBeTruthy();
    expect(await screen.findByRole("link", { name: "Admin (opens the classic Shelfarr app)" })).toBeTruthy();
    expect(server.called("GET", OVERVIEW).length).toBe(0);
  });

  test("signing in from the overview's address explains where it returns", async () => {
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: signedOut() }));
    renderGo({ server, view: "admin", url: "/preview/admin" });
    expect(await screen.findByText("Sign in to see the server overview. You will come straight back to it.")).toBeTruthy();
  });
});
