import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { NotificationItem, NotificationList } from "../src/contract";
import { ACCOUNT, deferred, FakeServer, page, renderApp, session, summary, type Handler } from "./helpers";
import { libraryServer, renderGo, signedIn } from "./go-helpers";

afterEach(cleanup);

function item(overrides: Partial<NotificationItem> = {}): NotificationItem {
  return {
    id: "5",
    type: "request_completed",
    title: "Book Ready",
    message: "“The Dispossessed” is now available for download.",
    created_at: "2026-11-20T08:00:00.000Z",
    read_at: null,
    request: { state: "available", id: "7" },
    ...overrides,
  };
}

function inbox(items: NotificationItem[], overrides: Partial<NotificationList> = {}): NotificationList {
  const through = items.reduce<string | null>((highest, entry) => (highest === null || Number(entry.id) > Number(highest) ? entry.id : highest), null);
  return { account: ACCOUNT, unread: items.filter((entry) => entry.read_at === null).length, total: items.length, through, items, ...overrides };
}

const SAMPLE = [
  item(),
  item({ id: "4", type: "request_attention", title: "Attention Needed", message: "“Middlemarch” needs your attention.", request: { state: "unavailable" } }),
  item({ id: "3", type: "request_failed", title: "Request Failed", message: null, read_at: "2026-11-19T08:00:00.000Z", request: null }),
];

function railsServer(options: { list?: Handler; unread?: number } = {}): FakeServer {
  let unread = options.unread ?? 2;
  return new FakeServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session({ notifications: { url: "/sub/notifications", unread } }) }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", /\/api\/v1\/notifications$/, options.list ?? (() => ({ body: inbox(SAMPLE) })))
    .on("POST", /\/api\/v1\/notifications\/.+$/, () => {
      unread = 0;
      return { body: { account: ACCOUNT, unread: 0, total: SAMPLE.length, changed: 1 } };
    });
}

function cardFor(title: string): HTMLElement {
  return screen.getByRole("article", { name: new RegExp(`^${title}`) });
}

describe("notifications in the Rails preview", () => {
  test("the bell opens the inbox inside the shell, marks itself current and adds no navigation tab", async () => {
    const server = railsServer();
    const { router } = renderApp({ server });
    const user = userEvent.setup();
    const bell = await screen.findByRole("link", { name: "Notifications, 2 unread" });
    expect(bell.getAttribute("href")).toBe("/sub/preview/notifications");
    await user.click(bell);
    expect(await screen.findByRole("heading", { level: 1, name: "Notifications" })).toBeTruthy();
    expect(router.state.location.pathname).toBe("/notifications");
    expect(screen.getByRole("link", { name: "Notifications, 2 unread" }).getAttribute("aria-current")).toBe("page");
    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(within(nav).getAllByRole("link").map((link) => [link.textContent, link.getAttribute("aria-current")])).toEqual([
      ["Library", null],
      ["Find", null],
      ["Account", null],
    ]);
  });

  test("the inbox lists every alert type with its unread state, a request link only where one is open, and honest counts", async () => {
    const server = railsServer({ list: () => ({ body: inbox([...SAMPLE, item({ id: "2", type: "future_kind", title: "Something new", request: null })], { total: 25, unread: 9 }) }) });
    renderApp({ server, url: "/sub/preview/notifications" });
    const list = await screen.findByRole("list", { name: "Notifications, newest first" });
    expect(within(list).getAllByRole("heading", { level: 2 }).map((heading) => heading.textContent)).toEqual(["Book Ready Unread", "Attention Needed Unread", "Request Failed", "Something new Unread"]);
    expect(screen.getByText("9 unread · 25 notifications · Showing the 4 most recent of 25.")).toBeTruthy();

    const ready = cardFor("Book Ready");
    expect(ready.className).toContain("notification--ready");
    expect(within(ready).getByText("“The Dispossessed” is now available for download.")).toBeTruthy();
    expect(within(ready).getByRole("link", { name: "View request for Book Ready" }).getAttribute("href")).toBe("/sub/preview/requests/7");
    expect(within(ready).getByRole("button", { name: "Mark as read Book Ready" })).toBeTruthy();
    expect(within(ready).getByText("Unread").className).toContain("badge--unread");
    expect(within(ready).getByText(/ago$/).tagName).toBe("TIME");

    const attention = cardFor("Attention Needed");
    expect(attention.className).toContain("notification--attention");
    expect(within(attention).queryByRole("link")).toBeNull();
    expect(within(attention).getByText("This request is no longer available.")).toBeTruthy();

    const failed = cardFor("Request Failed");
    expect(failed.className).toContain("notification--failed");
    expect(failed.className).not.toContain("notification--unread");
    expect(within(failed).queryByRole("button")).toBeNull();
    expect(within(failed).queryByRole("link")).toBeNull();
    expect(within(failed).queryByText("This request is no longer available.")).toBeNull();

    expect(cardFor("Something new").className).toContain("notification--other");
  });

  test("an empty inbox says so and offers no actions", async () => {
    renderApp({ server: railsServer({ list: () => ({ body: inbox([]) }), unread: 0 }), url: "/sub/preview/notifications" });
    expect(await screen.findByRole("heading", { name: "No notifications" })).toBeTruthy();
    expect(screen.getByText("You’re all caught up!")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Mark all as read" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Clear all" })).toBeNull();
  });

  test("marking one as read sends the page's account and token, re-reads the inbox and the bell, and keeps focus on that notification", async () => {
    let read = false;
    const server = railsServer({ list: () => ({ body: inbox(read ? [{ ...SAMPLE[0]!, read_at: "2026-11-21T08:00:00.000Z" }, ...SAMPLE.slice(1)] : SAMPLE) }) });
    server.on("POST", /\/notifications\/5\/read$/, () => {
      read = true;
      return { body: { account: ACCOUNT, unread: 1, total: 3, changed: 1 } };
    });
    renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Mark as read Book Ready" }));
    expect(await screen.findByText("Marked “Book Ready” as read.")).toBeTruthy();
    const [sent] = server.called("POST", /\/notifications\/5\/read$/);
    expect(sent?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(sent?.headers["x-csrf-token"]).toBe("token-123");
    await waitFor(() => expect(within(cardFor("Book Ready")).queryByRole("button")).toBeNull());
    await waitFor(() => expect(document.activeElement?.id).toBe("notification-5"));
    expect(server.called("GET", /\/notifications$/).length).toBeGreaterThanOrEqual(2);
    await waitFor(() => expect(server.called("GET", /\/session$/).length).toBeGreaterThanOrEqual(2));
  });

  test("mark all as read covers only what the page showed and says when newer alerts stayed unread", async () => {
    const server = railsServer();
    server.on("POST", /\/notifications\/read$/, () => ({ body: { account: ACCOUNT, unread: 1, total: 4, changed: 2 } }));
    renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Mark all as read" }));
    expect(await screen.findByText("Marked 2 notifications as read. 1 newer notification arrived and stays unread.")).toBeTruthy();
    expect(server.called("POST", /\/notifications\/read$/).map((request) => request.body)).toEqual([{ through: "5" }]);
  });

  test("bulk actions send the boundary the server counted, not a row on screen", async () => {
    const server = railsServer({ list: () => ({ body: inbox([item({ id: "9" }), item({ id: "12", title: "Later id" }), item({ id: "10" })], { through: "15", total: 4 }) }) });
    server.on("POST", /\/notifications\/read$/, () => ({ body: { account: ACCOUNT, unread: 0, total: 4, changed: 4 } }));
    renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Mark all as read" }));
    expect(await screen.findByText("All notifications marked as read.")).toBeTruthy();
    expect(server.called("POST", /\/notifications\/read$/).map((request) => request.body)).toEqual([{ through: "15" }]);
  });

  test("a refresh while nothing in the toolbar has focus leaves focus where it was", async () => {
    let items = SAMPLE;
    const server = railsServer({ list: () => ({ body: inbox(items) }) });
    const { services } = renderApp({ server, url: "/sub/preview/notifications" });
    await screen.findByRole("heading", { name: /^Book Ready/ });
    (document.activeElement as HTMLElement | null)?.blur();
    items = [item({ id: "6", title: "Newer" }), ...SAMPLE];
    act(() => {
      void services.queryClient.invalidateQueries({ queryKey: services.keys.notifications });
    });
    expect(await screen.findByRole("heading", { name: /^Newer/ })).toBeTruthy();
    expect(document.activeElement).toBe(document.body);
  });

  test("a first session read still loading on a direct visit is kept, so the header never loses the account", async () => {
    const held = deferred<{ body: unknown }>();
    let sessions = 0;
    const server = railsServer({ list: () => ({ body: inbox([SAMPLE[0]!]) }) });
    server.on("GET", /\/api\/v1\/session$/, () => {
      sessions += 1;
      return sessions === 1 ? held.promise : { status: 503, body: { error: "server_busy" } };
    });
    renderApp({ server, url: "/sub/preview/notifications" });
    expect(await screen.findByText("1 unread · 1 notification")).toBeTruthy();
    const [first] = server.called("GET", /\/session$/);
    expect(first?.signal?.aborted).toBe(false);
    await act(async () => held.resolve({ body: session({ notifications: { url: "/sub/notifications", unread: 1 } }) }));
    expect(await screen.findByRole("link", { name: "Notifications, 1 unread" })).toBeTruthy();
    expect(screen.getByText(/Signed in as/)).toBeTruthy();
  });

  test("a session answer still in flight when the inbox answers is dropped, even after leaving the inbox", async () => {
    const held = deferred<{ body: unknown }>();
    let sessions = 0;
    const server = railsServer({ list: () => ({ body: inbox([SAMPLE[0]!]) }) });
    server.on("GET", /\/api\/v1\/session$/, () => {
      sessions += 1;
      if (sessions === 2) return held.promise;
      return { body: session({ notifications: { url: "/sub/notifications", unread: sessions === 1 ? 0 : 1 } }) };
    });
    const { router, services } = renderApp({ server, url: "/sub/preview/library" });
    expect(await screen.findByRole("link", { name: "Notifications" })).toBeTruthy();
    act(() => {
      void services.queryClient.invalidateQueries({ queryKey: services.keys.session, exact: true });
    });
    await waitFor(() => expect(sessions).toBe(2));
    await act(async () => router.navigate({ to: "/notifications" }));
    expect(await screen.findByText("1 unread · 1 notification")).toBeTruthy();
    expect(await screen.findByRole("link", { name: "Notifications, 1 unread" })).toBeTruthy();
    await act(async () => router.navigate({ to: "/library" }));
    await act(async () => held.resolve({ body: session({ notifications: { url: "/sub/notifications", unread: 0 } }) }));
    await waitFor(() => expect(sessions).toBe(3));
    expect(screen.getByRole("link", { name: "Notifications, 1 unread" })).toBeTruthy();
  });

  test("an older inbox answer never overwrites a newer bell", async () => {
    const held = deferred<{ body: unknown }>();
    let reads = 0;
    let unread = 1;
    let failing = false;
    const server = railsServer({
      list: () => {
        reads += 1;
        return reads === 2 ? held.promise : { body: inbox([SAMPLE[0]!]) };
      },
    });
    server.on("GET", /\/api\/v1\/session$/, () => (failing ? { status: 503, body: { error: "server_busy" } } : { body: session({ notifications: { url: "/sub/notifications", unread } }) }));
    const { services } = renderApp({ server, url: "/sub/preview/notifications" });
    expect(await screen.findByText("1 unread · 1 notification")).toBeTruthy();
    expect(await screen.findByRole("link", { name: "Notifications, 1 unread" })).toBeTruthy();
    act(() => {
      void services.queryClient.invalidateQueries({ queryKey: services.keys.notifications });
    });
    await waitFor(() => expect(reads).toBe(2));
    unread = 0;
    act(() => {
      void services.queryClient.invalidateQueries({ queryKey: services.keys.session, exact: true });
    });
    expect(await screen.findByRole("link", { name: "Notifications" })).toBeTruthy();
    failing = true;
    const before = server.called("GET", /\/session$/).length;
    await act(async () => held.resolve({ body: inbox([SAMPLE[0]!]) }));
    await waitFor(() => expect(server.called("GET", /\/session$/).length).toBeGreaterThan(before));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(screen.getByRole("link", { name: "Notifications" })).toBeTruthy();
  }, 15000);

  test("a confirmation emptied by another tab's clear hands focus to the heading", async () => {
    let items = [SAMPLE[0]!];
    const server = railsServer({ list: () => ({ body: inbox(items) }) });
    const { services } = renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Clear all" }));
    expect(document.activeElement?.textContent).toBe("Clear all");
    items = [];
    act(() => {
      void services.queryClient.invalidateQueries({ queryKey: services.keys.notifications });
    });
    expect(await screen.findByRole("heading", { name: "No notifications" })).toBeTruthy();
    await waitFor(() => expect(document.activeElement?.id).toBe("notifications-heading"));
    expect(server.called("POST", /clear$/)).toHaveLength(0);
  });

  test("clear all asks first, can be kept, deletes only what was shown and moves focus to the heading", async () => {
    let cleared = false;
    const server = railsServer({ list: () => ({ body: cleared ? inbox([]) : inbox(SAMPLE, { total: 30 }) }) });
    server.on("POST", /\/notifications\/clear$/, () => {
      cleared = true;
      return { body: { account: ACCOUNT, unread: 0, total: 0, changed: 30 } };
    });
    renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Clear all" }));
    const question = screen.getByRole("group", { name: "Delete all 30 notifications? This can’t be undone." });
    await user.click(within(question).getByRole("button", { name: "Keep it" }));
    expect(server.called("POST", /clear$/)).toHaveLength(0);
    expect(screen.getAllByRole("article")).toHaveLength(3);

    await user.click(screen.getByRole("button", { name: "Clear all" }));
    await user.click(within(screen.getByRole("group", { name: /^Delete all 30/ })).getByRole("button", { name: "Clear all" }));
    expect(await screen.findByText("All notifications cleared.")).toBeTruthy();
    expect(await screen.findByRole("heading", { name: "No notifications" })).toBeTruthy();
    expect(server.called("POST", /clear$/).map((request) => request.body)).toEqual([{ through: "5" }]);
    await waitFor(() => expect(document.activeElement?.id).toBe("notifications-heading"));
  });

  test("clear all reports newer alerts that arrived and were kept", async () => {
    const server = railsServer();
    server.on("POST", /\/notifications\/clear$/, () => ({ body: { account: ACCOUNT, unread: 1, total: 1, changed: 3 } }));
    renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Clear all" }));
    await user.click(within(screen.getByRole("group", { name: "Delete all 3 notifications? This can’t be undone." })).getByRole("button", { name: "Clear all" }));
    expect(await screen.findByText("Cleared 3 notifications. 1 newer notification arrived and was kept.")).toBeTruthy();
  });

  test("an open clear confirmation is withdrawn when a newer alert arrives, so it can never delete what was not asked about", async () => {
    let items = SAMPLE;
    const server = railsServer({ list: () => ({ body: inbox(items) }) });
    server.on("POST", /\/notifications\/clear$/, () => {
      items = [item({ id: "8", title: "Arrived later" })];
      return { body: { account: ACCOUNT, unread: 1, total: 1, changed: 3 } };
    });
    const { services } = renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Clear all" }));
    expect(screen.getByRole("group", { name: "Delete all 3 notifications? This can’t be undone." })).toBeTruthy();
    items = [item({ id: "6", title: "Newer" }), ...SAMPLE];
    act(() => {
      void services.queryClient.invalidateQueries({ queryKey: services.keys.notifications });
    });
    expect(await screen.findByRole("heading", { name: /^Newer/ })).toBeTruthy();
    await waitFor(() => expect(screen.queryByRole("group", { name: /^Delete/ })).toBeNull());
    expect(document.activeElement).toBe(screen.getByRole("button", { name: "Clear all" }));
    expect(server.called("POST", /clear$/)).toHaveLength(0);

    await user.click(screen.getByRole("button", { name: "Clear all" }));
    await user.click(within(screen.getByRole("group", { name: "Delete all 4 notifications? This can’t be undone." })).getByRole("button", { name: "Clear all" }));
    expect(await screen.findByText("Cleared 3 notifications. 1 newer notification arrived and was kept.")).toBeTruthy();
    expect(await screen.findByRole("heading", { name: /^Arrived later/ })).toBeTruthy();
    expect(screen.queryByRole("group", { name: /^Delete/ })).toBeNull();
    expect(server.called("POST", /clear$/).map((request) => request.body)).toEqual([{ through: "6" }]);
  });

  test("a notification already cleared elsewhere is reported and the inbox and session are read again", async () => {
    let gone = false;
    const server = railsServer({ list: () => ({ body: inbox(gone ? SAMPLE.slice(1) : SAMPLE) }) });
    server.on("POST", /\/notifications\/5\/read$/, () => {
      gone = true;
      return { status: 404, body: { error: "not_found" } };
    });
    renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    const sessions = () => server.called("GET", /\/session$/).length;
    await screen.findByRole("button", { name: "Mark as read Book Ready" });
    const before = sessions();
    await user.click(screen.getByRole("button", { name: "Mark as read Book Ready" }));
    expect(await screen.findByText("That notification is no longer here. The list now shows what is left.")).toBeTruthy();
    await waitFor(() => expect(screen.queryByRole("article", { name: /^Book Ready/ })).toBeNull());
    await waitFor(() => expect(sessions()).toBeGreaterThan(before));
  });

  test("a write the server never confirmed says so and re-reads the inbox", async () => {
    const server = railsServer();
    server.on("POST", /\/notifications\/read$/, () => ({ status: 503, body: { error: "server_busy" } }));
    renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Mark all as read" }));
    expect(await screen.findByText("The server did not confirm this. The page now shows the current state; try again only if nothing changed.")).toBeTruthy();
    expect(server.called("GET", /\/notifications$/).length).toBeGreaterThanOrEqual(2);
  });

  test("a failed read shows the error with a retry instead of an old list", async () => {
    let fail = true;
    renderApp({ server: railsServer({ list: () => (fail ? { status: 500, body: { error: "boom" } } : { body: inbox(SAMPLE) }) }), url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    expect(await screen.findByRole("heading", { name: "Your server had a problem" }, { timeout: 8000 })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Clear all" })).toBeNull();
    fail = false;
    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByRole("heading", { name: /^Book Ready/ })).toBeTruthy();
  }, 15000);

  test("each inbox answer has the session read again and the bell shows the session's count", async () => {
    const list = deferred<{ body: unknown }>();
    const server = railsServer({ list: () => list.promise });
    let sessions = 0;
    server.on("GET", /\/api\/v1\/session$/, () => {
      sessions += 1;
      return { body: session({ notifications: { url: "/sub/notifications", unread: sessions === 1 ? 7 : 2 } }) };
    });
    renderApp({ server, url: "/sub/preview/notifications" });
    expect(await screen.findByRole("link", { name: "Notifications, 7 unread" })).toBeTruthy();
    await act(async () => list.resolve({ body: inbox(SAMPLE) }));
    expect(await screen.findByRole("link", { name: "Notifications, 2 unread" })).toBeTruthy();
    expect(sessions).toBe(2);
    expect(server.called("GET", /\/notifications$/)).toHaveLength(1);
  });

  test("a write leads to one inbox read and one completed session read", async () => {
    const server = railsServer();
    renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    const button = await screen.findByRole("button", { name: "Mark all as read" });
    await new Promise((resolve) => setTimeout(resolve, 50));
    const completed = () => server.called("GET", /\/session$/).filter((request) => !request.signal?.aborted).length;
    const before = completed();
    const lists = server.called("GET", /\/notifications$/).length;
    await user.click(button);
    expect(await screen.findByText("All notifications marked as read.")).toBeTruthy();
    expect(await screen.findByRole("link", { name: "Notifications" })).toBeTruthy();
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(server.called("GET", /\/notifications$/)).toHaveLength(lists + 1);
    expect(completed()).toBe(before + 1);
  });

  test("a write re-reads the session itself, so the bell is right even when the inbox cannot be read again", async () => {
    let failing = false;
    const server = railsServer({ list: () => (failing ? { status: 500, body: { error: "boom" } } : { body: inbox(SAMPLE) }) });
    server.on("POST", /\/notifications\/read$/, () => {
      failing = true;
      return { body: { account: ACCOUNT, unread: 0, total: 3, changed: 2 } };
    });
    let unread = 2;
    server.on("GET", /\/api\/v1\/session$/, () => ({ body: session({ notifications: { url: "/sub/notifications", unread } }) }));
    renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    expect(await screen.findByRole("link", { name: "Notifications, 2 unread" })).toBeTruthy();
    unread = 0;
    await user.click(await screen.findByRole("button", { name: "Mark all as read" }));
    expect(await screen.findByText("All notifications marked as read.")).toBeTruthy();
    expect(await screen.findByRole("link", { name: "Notifications" })).toBeTruthy();
  }, 15000);

  test("a write that finishes after leaving the inbox still brings the bell up to date", async () => {
    const answer = deferred<{ body: unknown }>();
    const server = railsServer();
    let unread = 2;
    server.on("GET", /\/api\/v1\/session$/, () => ({ body: session({ notifications: { url: "/sub/notifications", unread } }) }));
    server.on("POST", /\/notifications\/read$/, () => answer.promise);
    const { router } = renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    expect(await screen.findByRole("link", { name: "Notifications, 2 unread" })).toBeTruthy();
    await user.click(await screen.findByRole("button", { name: "Mark all as read" }));
    await waitFor(() => expect(server.called("POST", /\/notifications\/read$/)).toHaveLength(1));
    await act(async () => router.navigate({ to: "/library" }));
    unread = 0;
    await act(async () => answer.resolve({ body: { account: ACCOUNT, unread: 0, total: 3, changed: 2 } }));
    expect(await screen.findByRole("link", { name: "Notifications" })).toBeTruthy();
  });

  test("a session read still in flight when the focus check confirms a newer count is replaced, not left to win", async () => {
    const held = deferred<{ body: unknown }>();
    let unread = 1;
    let sessions = 0;
    const server = railsServer({ list: () => ({ body: inbox([SAMPLE[0]!]) }) });
    server.on("GET", /\/api\/v1\/session$/, () => {
      sessions += 1;
      if (sessions === 3) return held.promise;
      return { body: session({ notifications: { url: "/sub/notifications", unread } }) };
    });
    const { services } = renderApp({ server, url: "/sub/preview/library" });
    expect(await screen.findByRole("link", { name: "Notifications, 1 unread" })).toBeTruthy();
    await waitFor(() => expect(sessions).toBeGreaterThanOrEqual(1));
    while (sessions < 2) {
      act(() => {
        void services.queryClient.invalidateQueries({ queryKey: services.keys.session, exact: true });
      });
      await waitFor(() => expect(sessions).toBeGreaterThanOrEqual(2));
    }
    act(() => {
      void services.queryClient.invalidateQueries({ queryKey: services.keys.session, exact: true });
    });
    await waitFor(() => expect(sessions).toBe(3));
    unread = 0;
    await act(async () => {
      services.revalidate();
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    expect(await screen.findByRole("link", { name: "Notifications" })).toBeTruthy();
    await act(async () => held.resolve({ body: session({ notifications: { url: "/sub/notifications", unread: 1 } }) }));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(screen.getByRole("link", { name: "Notifications" })).toBeTruthy();
  });

  test("an older read that answers after an action never replaces the newer inbox", async () => {
    let cleared = false;
    const late = deferred<{ body: unknown }>();
    let reads = 0;
    const server = railsServer({
      list: () => {
        reads += 1;
        if (reads === 2) return late.promise;
        return { body: cleared ? inbox([]) : inbox(SAMPLE) };
      },
    });
    server.on("POST", /\/notifications\/clear$/, () => {
      cleared = true;
      return { body: { account: ACCOUNT, unread: 0, total: 0, changed: 3 } };
    });
    const { services } = renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await screen.findByRole("heading", { name: /^Book Ready/ });
    act(() => {
      void services.queryClient.invalidateQueries({ queryKey: services.keys.notifications });
    });
    await waitFor(() => expect(reads).toBe(2));
    await user.click(screen.getByRole("button", { name: "Clear all" }));
    await user.click(within(screen.getByRole("group", { name: /^Delete all 3/ })).getByRole("button", { name: "Clear all" }));
    expect(await screen.findByRole("heading", { name: "No notifications" })).toBeTruthy();
    await act(async () => late.resolve({ body: inbox(SAMPLE) }));
    expect(screen.getByRole("heading", { name: "No notifications" })).toBeTruthy();
    expect(screen.queryByRole("article")).toBeNull();
  });

  test("an inbox answered for another account locks the page without showing it", async () => {
    const server = railsServer({ list: () => ({ body: { ...inbox(SAMPLE), account: "99" } }) });
    const { services } = renderApp({ server, url: "/sub/preview/notifications" });
    expect(await screen.findByRole("heading", { name: "The signed-in account changed" })).toBeTruthy();
    expect(screen.queryByText("Book Ready")).toBeNull();
    expect(services.guard.getState().status).toBe("account_changed");
  });

  test("an action still queued when the account changes is never applied or announced", async () => {
    const answer = deferred<{ body: unknown }>();
    const server = railsServer();
    server.on("POST", /\/notifications\/read$/, () => answer.promise);
    const { services } = renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Mark all as read" }));
    await waitFor(() => expect(server.called("POST", /\/notifications\/read$/)).toHaveLength(1));
    const reads = server.called("GET", /\/notifications$/).length;
    act(() => services.guard.lock("account_changed"));
    await act(async () => answer.resolve({ body: { account: ACCOUNT, unread: 0, total: 3, changed: 2 } }));
    expect(await screen.findByRole("heading", { name: "The signed-in account changed" })).toBeTruthy();
    expect(screen.queryByText("All notifications marked as read.")).toBeNull();
    expect(screen.queryByText("Book Ready")).toBeNull();
    expect(server.called("GET", /\/notifications$/)).toHaveLength(reads);
  });

  test("an action answered for another account locks the page", async () => {
    const server = railsServer();
    server.on("POST", /\/notifications\/clear$/, () => ({ body: { account: "99", unread: 0, total: 0, changed: 3 } }));
    const { services } = renderApp({ server, url: "/sub/preview/notifications" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Clear all" }));
    await user.click(within(screen.getByRole("group", { name: /^Delete all 3/ })).getByRole("button", { name: "Clear all" }));
    expect(await screen.findByRole("heading", { name: "The signed-in account changed" })).toBeTruthy();
    expect(services.guard.getState().status).toBe("account_changed");
  });
});

describe("notifications on the experimental Go server", () => {
  test("the Go shell shows no bell and does not offer the inbox", async () => {
    const server = libraryServer(() => signedIn());
    renderGo({ server, url: "/preview/notifications" });
    expect(await screen.findByRole("heading", { name: "That page is not part of this preview" })).toBeTruthy();
    expect(screen.queryByRole("link", { name: /^Notifications/ })).toBeNull();
    expect(server.called("GET", /\/notifications/)).toHaveLength(0);
  });
});
