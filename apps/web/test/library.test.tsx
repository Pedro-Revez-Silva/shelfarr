import { describe, expect, test } from "bun:test";
import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { createServices } from "../src/services";
import { ACCOUNT, boot, deferred, FakeServer, page, renderApp, session, standardServer, summary } from "./helpers";

function libraryServer(pages: Record<string, ReturnType<typeof page>>) {
  return standardServer().on("GET", /\/api\/v1\/library(\?|$)/, (request) => {
    const cursor = new URL(request.path, "http://shelf.test").searchParams.get("cursor") ?? "";
    return { body: pages[cursor] ?? page([]) };
  });
}

describe("the library page", () => {
  test("shows the account's books as cards linking to details, with context and a single h1", async () => {
    const server = libraryServer({ "": page([summary({ id: "7", title: "The Quiet Library", author: "A. Reader" }), summary({ id: "8", title: "A Listening Life", book_type: "audiobook", action: "listen", format_label: "Audiobook", progress_label: "Resume at 0:17", reading_status: "in_progress" })]) });
    renderApp({ server });
    const link = await screen.findByRole("link", { name: "The Quiet Library" });
    expect(link.getAttribute("href")).toBe("/sub/preview/library/7");
    expect(screen.getByRole("link", { name: "A Listening Life" }).getAttribute("href")).toBe("/sub/preview/library/8");
    expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
    expect(screen.getByRole("heading", { level: 1 }).textContent).toBe("Library");
    expect(screen.getByText("Resume at 0:17")).toBeTruthy();
    await screen.findByText("Ada Reader");
    expect(screen.getByText("shelf.test", { selector: ".account-server" })).toBeTruthy();
    expect(screen.getByRole("status", { name: "" }).textContent).toContain("Showing 2 books");
  });

  test("one navigation tells in-app Library apart from classic-app handoffs and hides Admin from non-admins", async () => {
    renderApp({ server: libraryServer({ "": page([summary()]) }) });
    await screen.findByText("Ada Reader");
    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(screen.getAllByRole("navigation")).toHaveLength(1);
    const library = within(nav).getByRole("link", { name: "Library" });
    expect(library.getAttribute("aria-current")).toBe("page");
    expect(library.getAttribute("href")).toBe("/sub/preview/library");
    for (const [name, href] of [["Discover", "/sub/search"], ["Requests", "/sub/requests"], ["Account", "/sub/profile"]] as const) {
      const link = within(nav).getByRole("link", { name: `${name} (opens the classic Shelfarr app)` });
      expect(link.getAttribute("href")).toBe(href);
      expect(link.getAttribute("aria-current")).toBeNull();
    }
    expect(within(nav).queryByRole("link", { name: /Admin/ })).toBeNull();
  });

  test("an admin gets the Admin handoff", async () => {
    const server = libraryServer({ "": page([summary()]) }).on("GET", /session$/, () => ({ body: session({ admin: { url: "/sub/admin" } }) }));
    renderApp({ server });
    const link = await screen.findByRole("link", { name: "Admin (opens the classic Shelfarr app)" });
    expect(link.getAttribute("href")).toBe("/sub/admin");
  });

  test("filters live in the address and drive the request", async () => {
    const server = libraryServer({ "": page([summary()]) });
    const { router } = renderApp({ server });
    await screen.findByRole("link", { name: "The Quiet Library" });
    const user = userEvent.setup();

    await user.click(screen.getByRole("radio", { name: "Audiobooks" }));
    await waitFor(() => expect(router.state.location.search).toEqual({ type: "audiobook" }));
    await waitFor(() => expect(server.called("GET", /type=audiobook/).length).toBeGreaterThan(0));

    await user.selectOptions(screen.getByLabelText("Reading status"), "finished");
    await user.selectOptions(screen.getByLabelText("Sort by"), "title");
    await waitFor(() => expect(router.state.location.search).toEqual({ type: "audiobook", status: "finished", sort: "title" }));
    await waitFor(() => expect(server.called("GET", /type=audiobook&status=finished&sort=title/).length).toBeGreaterThan(0));

    await user.type(screen.getByRole("searchbox", { name: "Search your library" }), "dune");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await waitFor(() => expect(router.state.location.search).toEqual({ q: "dune", type: "audiobook", status: "finished", sort: "title" }));
    expect(router.history.location.href).toBe("/sub/preview/library?q=dune&type=audiobook&status=finished&sort=title");

    await user.click(screen.getByRole("button", { name: "Clear search" }));
    await waitFor(() => expect(router.state.location.search).toEqual({ type: "audiobook", status: "finished", sort: "title" }));
  });

  test("a pasted address selects its filters and survives garbage values", async () => {
    const server = libraryServer({ "": page([summary()]) });
    renderApp({ server, url: "/sub/preview/library?q=dune&type=audiobook&status=bogus&sort=random" });
    await waitFor(() => expect(server.called("GET", /\/library\?/).length).toBeGreaterThan(0));
    expect(server.called("GET", /\/library\?/)[0]?.path).toBe("/sub/preview/api/v1/library?q=dune&type=audiobook");
    expect((screen.getByRole("radio", { name: "Audiobooks" }) as HTMLInputElement).checked).toBe(true);
    expect((screen.getByRole("searchbox") as HTMLInputElement).value).toBe("dune");
    expect((screen.getByLabelText("Reading status") as HTMLSelectElement).value).toBe("");
  });

  test("load more follows the cursor, appends without repeats and stops at the end", async () => {
    const server = libraryServer({
      "": page([summary({ id: "3", title: "Third" }), summary({ id: "2", title: "Second" })], "next-1"),
      "next-1": page([summary({ id: "2", title: "Second" }), summary({ id: "1", title: "First" })], null),
    });
    renderApp({ server });
    await screen.findByRole("link", { name: "Third" });
    expect(screen.getByRole("status", { name: "" }).textContent).toContain("Showing 2 books so far");
    await userEvent.setup().click(screen.getByRole("button", { name: "Load more books" }));
    await screen.findByRole("link", { name: "First" });
    expect(screen.getAllByRole("link", { name: /^(Third|Second|First)$/ }).map((link) => link.textContent)).toEqual(["Third", "Second", "First"]);
    expect(server.called("GET", /cursor=next-1/)).toHaveLength(1);
    expect(screen.queryByRole("button", { name: "Load more books" })).toBeNull();
    expect(screen.getByText("That is everything on this shelf.")).toBeTruthy();
  });

  test("a failed load more keeps the books and offers a retry that works", async () => {
    let attempts = 0;
    const server = libraryServer({ "": page([summary({ id: "3", title: "Third" })], "next-1") }).on("GET", /cursor=next-1/, () => {
      attempts += 1;
      return attempts <= 3 ? { status: 500, body: { error: "internal" } } : { body: page([summary({ id: "2", title: "Second" })], null) };
    });
    renderApp({ server });
    await screen.findByRole("link", { name: "Third" });
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Load more books" }));
    const alert = await screen.findByText("More books could not be loaded.", {}, { timeout: 5000 });
    expect(alert).toBeTruthy();
    expect(screen.getByRole("link", { name: "Third" })).toBeTruthy();
    await user.click(within(alert.closest("[role=alert]") as HTMLElement).getByRole("button", { name: "Try again" }));
    await screen.findByRole("link", { name: "Second" });
  }, 15000);

  test("an empty library and an empty search say different true things", async () => {
    const empty = libraryServer({ "": page([]) });
    const { view } = renderApp({ server: empty });
    await screen.findByText("Nothing on this server yet");
    expect(screen.getByRole("link", { name: /Discover books/ }).getAttribute("href")).toBe("/sub/search");
    view.unmount();
    renderApp({ server: empty, url: "/sub/preview/library?q=zzz" });
    await screen.findByText("No books match these filters");
    expect(screen.getByRole("button", { name: "Clear filters" })).toBeTruthy();
  });

  test("a failing server shows a retryable error without losing the page", async () => {
    let fail = true;
    const server = standardServer().on("GET", /\/api\/v1\/library(\?|$)/, () => (fail ? { status: 500, body: { error: "internal" } } : { body: page([summary()]) }));
    renderApp({ server });
    expect((await screen.findByText("Your server had a problem", {}, { timeout: 8000 })).closest("[role=alert]")).toBeTruthy();
    fail = false;
    await userEvent.setup().click(screen.getByRole("button", { name: "Try again" }));
    await screen.findByRole("link", { name: "The Quiet Library" });
  }, 15000);

  test("a network failure is explained and recoverable", async () => {
    let up = false;
    const base = standardServer();
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (!up && String(input).includes("/library")) throw new TypeError("Failed to fetch");
      return base.fetcher(input, init);
    }) as typeof fetch;
    class FlakyServer extends FakeServer {
      override get fetcher() {
        return fetcher;
      }
    }
    renderApp({ server: new FlakyServer() });
    await screen.findByText("Can't reach your server", {}, { timeout: 8000 });
    up = true;
    await userEvent.setup().click(screen.getByRole("button", { name: "Try again" }));
    await screen.findByRole("link", { name: "The Quiet Library" });
  }, 15000);

  test("continue reading offers a real resume link into the existing reader", async () => {
    const resume = summary({ id: "8", title: "A Listening Life", action: "listen", book_type: "audiobook", format_label: "Audiobook", progress_label: "Resume at 0:17", reading_status: "in_progress", reader_url: "/sub/read/8" });
    const server = libraryServer({ "": page([summary()]) }).on("GET", /continue/, () => ({ body: { account: ACCOUNT, items: [resume] } }));
    renderApp({ server });
    const heading = await screen.findByRole("heading", { name: "Keep going" });
    const shelf = heading.closest("section") as HTMLElement;
    const link = within(shelf).getByRole("link", { name: /Resume at 0:17/ });
    expect(link.getAttribute("href")).toBe("/sub/read/8");
    expect(within(shelf).getByRole("link", { name: "A Listening Life" }).getAttribute("href")).toBe("/sub/preview/library/8");
  });

  test("a search or status filter hides the continue shelf and does not request it", async () => {
    const server = libraryServer({ "": page([summary()]) });
    renderApp({ server, url: "/sub/preview/library?q=quiet" });
    await screen.findByRole("link", { name: "The Quiet Library" });
    expect(server.called("GET", /continue/)).toHaveLength(0);
    expect(screen.queryByRole("heading", { name: "Keep going" })).toBeNull();
  });

  test("a cover that fails to load falls back to the generated cover", async () => {
    const server = libraryServer({ "": page([summary({ cover: { url: "https://covers.test/a.jpg", style: "plum" } })]) });
    const { view } = renderApp({ server });
    await screen.findByRole("link", { name: "The Quiet Library" });
    const image = view.container.querySelector("img") as HTMLImageElement;
    expect(image.getAttribute("src")).toBe("https://covers.test/a.jpg");
    expect(image.getAttribute("referrerpolicy")).toBe("no-referrer");
    image.dispatchEvent(new Event("error"));
    await waitFor(() => expect(view.container.querySelector("img")).toBeNull());
    expect(view.container.querySelector(".cover--plum .cover-title")?.textContent).toBe("The Quiet Library");
  });

  test("external metadata is text, never markup", async () => {
    const hostile = "<img src=x onerror=alert(1)><script>alert(2)</script>";
    const server = libraryServer({ "": page([summary({ title: hostile, author: hostile })]) });
    const { view } = renderApp({ server });
    await screen.findAllByText(hostile, { exact: true, selector: "a" });
    expect(view.container.querySelector("script")).toBeNull();
    expect(view.container.querySelector("img[src='x']")).toBeNull();
  });

  test("books without files are flagged and still open their details", async () => {
    const server = libraryServer({ "": page([summary({ availability: "unavailable", progress_label: "Files unavailable" })]) });
    renderApp({ server });
    expect((await screen.findByText("Files unavailable")).className).toContain("book-state--warning");
    expect(screen.getByRole("link", { name: "The Quiet Library" })).toBeTruthy();
  });

  test("a response from the previous account is never shown after the account changes", async () => {
    const gate = deferred<void>();
    const server = standardServer().on("GET", /\/api\/v1\/library(\?|$)/, async () => {
      await gate.promise;
      return { body: page([summary({ title: "Previous account's private book" })]) };
    });
    const { services } = renderApp({ server });
    await screen.findByText("Ada Reader");
    services.guard.lock("account_changed");
    gate.resolve();
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(screen.queryByText(/Previous account's private book/)).toBeNull();
    expect(screen.queryByRole("navigation")).toBeNull();
    expect(services.queryClient.getQueryCache().getAll()).toHaveLength(0);
    expect(screen.getByRole("link", { name: "Reload as the current account" })).toBeTruthy();
  });

  test("another tab switching accounts is noticed by the next request and clears everything", async () => {
    const server = libraryServer({ "": page([summary({ title: "Ada's private book" })]) });
    const { services } = renderApp({ server });
    await screen.findByRole("link", { name: "Ada's private book" });
    server.on("GET", /\/api\/v1\/session$/, () => ({ status: 401, body: { error: "account_changed" } }));
    await services.queryClient.refetchQueries({ queryKey: services.keys.session }).catch(() => undefined);
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    expect(screen.queryByText("Ada's private book")).toBeNull();
    expect(services.queryClient.getQueryCache().getAll()).toHaveLength(0);
  });

  test("losing the session stops showing the library and offers sign-in", async () => {
    const server = libraryServer({ "": page([summary({ title: "Ada's private book" })]) });
    const { services } = renderApp({ server });
    await screen.findByRole("link", { name: "Ada's private book" });
    server.on("GET", /\/api\/v1\/session$/, () => ({ status: 401, body: { error: "signed_out" } }));
    await services.queryClient.refetchQueries({ queryKey: services.keys.session }).catch(() => undefined);
    await screen.findByRole("heading", { name: "Your session ended" });
    expect(screen.queryByText("Ada's private book")).toBeNull();
    expect(screen.getByRole("link", { name: "Sign in again" }).getAttribute("href")).toBe(window.location.href);
  });

  test("unknown paths under the mount say so inside the shell", async () => {
    renderApp({ server: standardServer(), url: "/sub/preview/nowhere" });
    await screen.findByText("That page is not part of this preview");
  });
});

describe("account revalidation", () => {
  test("returning focus to a visible window checks the account and locks a switched tab", async () => {
    const server = libraryServer({ "": page([summary({ title: "Ada's private book" })]) });
    renderApp({ server });
    await screen.findByRole("link", { name: "Ada's private book" });
    const checks = server.called("GET", /\/api\/v1\/session$/).length;
    server.on("GET", /\/api\/v1\/session$/, () => ({ status: 401, body: { error: "account_changed" } }));
    window.dispatchEvent(new Event("blur"));
    window.dispatchEvent(new Event("focus"));
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    expect(server.called("GET", /\/api\/v1\/session$/).length).toBe(checks + 1);
    expect(screen.queryByText("Ada's private book")).toBeNull();
  });

  test("a page restored from the back-forward cache checks the account too", async () => {
    const server = libraryServer({ "": page([summary()]) });
    renderApp({ server });
    await screen.findByRole("link", { name: "The Quiet Library" });
    const checks = server.called("GET", /\/api\/v1\/session$/).length;
    window.dispatchEvent(new Event("pageshow"));
    await waitFor(() => expect(server.called("GET", /\/api\/v1\/session$/).length).toBe(checks + 1));
  });

  test("simultaneous focus events share one check", async () => {
    const gate = deferred<void>();
    const server = libraryServer({ "": page([summary()]) });
    renderApp({ server });
    await screen.findByRole("link", { name: "The Quiet Library" });
    const checks = server.called("GET", /\/api\/v1\/session$/).length;
    server.on("GET", /\/api\/v1\/session$/, async () => {
      await gate.promise;
      return { body: session() };
    });
    window.dispatchEvent(new Event("focus"));
    window.dispatchEvent(new Event("pageshow"));
    document.dispatchEvent(new Event("visibilitychange"));
    await waitFor(() => expect(server.called("GET", /\/api\/v1\/session$/).length).toBe(checks + 1));
    gate.resolve();
  });

  test("a response for the previous account that arrives while the check is pending is held and never shown", async () => {
    const libraryGate = deferred<void>();
    const sessionGate = deferred<void>();
    const server = standardServer();
    const { services } = renderApp({ server });
    await screen.findByText("Ada Reader");
    server.on("GET", /\/api\/v1\/library(\?|$)/, async () => {
      await libraryGate.promise;
      return { body: page([summary({ title: "A private book after the switch" })]) };
    });
    server.on("GET", /\/api\/v1\/session$/, async () => {
      await sessionGate.promise;
      return { status: 401, body: { error: "account_changed" } };
    });
    const user = userEvent.setup();
    await user.click(screen.getByRole("radio", { name: "Audiobooks" }));
    await waitFor(() => expect(server.called("GET", /type=audiobook/).length).toBeGreaterThan(0));
    window.dispatchEvent(new Event("focus"));
    await waitFor(() => expect(services.guard.trust).toBe("checking"));
    libraryGate.resolve();
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(screen.queryByText("A private book after the switch")).toBeNull();
    sessionGate.resolve();
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    expect(screen.queryByText("A private book after the switch")).toBeNull();
    expect(services.queryClient.getQueryCache().getAll()).toHaveLength(0);
  });

  test("a held response is delivered once the check confirms the account", async () => {
    const libraryGate = deferred<void>();
    const sessionGate = deferred<void>();
    const server = standardServer();
    const { services } = renderApp({ server });
    await screen.findByText("Ada Reader");
    server.on("GET", /\/api\/v1\/library(\?|$)/, async () => {
      await libraryGate.promise;
      return { body: page([summary({ title: "Still Ada's book" })]) };
    });
    server.on("GET", /\/api\/v1\/session$/, async () => {
      await sessionGate.promise;
      return { body: session() };
    });
    await userEvent.setup().click(screen.getByRole("radio", { name: "Audiobooks" }));
    window.dispatchEvent(new Event("focus"));
    await waitFor(() => expect(services.guard.trust).toBe("checking"));
    libraryGate.resolve();
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(screen.queryByText("Still Ada's book")).toBeNull();
    sessionGate.resolve();
    await screen.findByRole("link", { name: "Still Ada's book" });
  });

  test("a check that fails to settle never releases a held response and the retry meets the new account", async () => {
    const libraryGate = deferred<void>();
    const sessionGate = deferred<void>();
    const server = standardServer();
    const { services } = renderApp({ server });
    await screen.findByText("Ada Reader");
    let libraryCalls = 0;
    server.on("GET", /\/api\/v1\/library(\?|$)/, async () => {
      libraryCalls += 1;
      if (libraryCalls > 1) return { status: 401, body: { error: "account_changed" } };
      await libraryGate.promise;
      return { body: page([summary({ title: "A private book after the switch" })]) };
    });
    server.on("GET", /\/api\/v1\/session$/, async () => {
      await sessionGate.promise;
      return { status: 500, body: { error: "internal" } };
    });
    await userEvent.setup().click(screen.getByRole("radio", { name: "Audiobooks" }));
    window.dispatchEvent(new Event("focus"));
    await waitFor(() => expect(services.guard.trust).toBe("checking"));
    libraryGate.resolve();
    sessionGate.resolve();
    await screen.findByRole("heading", { name: "The signed-in account changed" }, { timeout: 8000 });
    expect(screen.queryByText("A private book after the switch")).toBeNull();
    expect(libraryCalls).toBe(2);
  }, 15000);

  test("a stalled check does not delay an authoritative account_changed answer", async () => {
    const sessionGate = deferred<void>();
    const server = standardServer();
    renderApp({ server });
    await screen.findByText("Ada Reader");
    server.on("GET", /\/api\/v1\/session$/, async () => {
      await sessionGate.promise;
      return { body: session() };
    });
    server.on("GET", /\/api\/v1\/library(\?|$)/, () => ({ status: 401, body: { error: "account_changed" } }));
    window.dispatchEvent(new Event("focus"));
    await userEvent.setup().click(screen.getByRole("radio", { name: "Audiobooks" }));
    await screen.findByRole("heading", { name: "The signed-in account changed" }, { timeout: 2000 });
    sessionGate.resolve();
  });

  test("an unanswered check times out so the held request can fail and be retried", async () => {
    const server = standardServer();
    const services = createServices({ boot, csrfToken: () => null, fetcher: server.fetcher, validationTimeoutMs: 50 });
    server.on("GET", /\/api\/v1\/session$/, (request) => new Promise(() => {
      void request;
    }));
    server.on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }));
    services.revalidate();
    const outcome = await Promise.race([
      services.api.library({}, undefined).catch((error: unknown) => error),
      new Promise((resolve) => setTimeout(() => resolve("still held"), 1500)),
    ]);
    expect(outcome).toMatchObject({ kind: "network" });
    expect(services.guard.trust).not.toBe("trusted");
    expect(services.guard.isActive()).toBe(true);
  });

  test("a held request can still be aborted", async () => {
    const server = standardServer();
    const services = createServices({ boot, csrfToken: () => null, fetcher: server.fetcher, validationTimeoutMs: 5000 });
    server.on("GET", /\/api\/v1\/session$/, () => new Promise(() => undefined));
    void services.revalidate();
    const controller = new AbortController();
    const held = services.api.library({}, undefined, controller.signal).catch((error: unknown) => error);
    setTimeout(() => controller.abort(), 20);
    expect(await held).toMatchObject({ name: "AbortError" });
  });

  test("the focus check is a fresh request, not the answer to an older session request", async () => {
    const oldSession = deferred<void>();
    let sessionCalls = 0;
    const server = standardServer().on("GET", /\/api\/v1\/session$/, async () => {
      sessionCalls += 1;
      if (sessionCalls === 1) {
        await oldSession.promise;
        return { body: session() };
      }
      return { status: 401, body: { error: "account_changed" } };
    });
    renderApp({ server });
    await screen.findByRole("link", { name: "The Quiet Library" });
    window.dispatchEvent(new Event("focus"));
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    expect(sessionCalls).toBe(2);
    oldSession.resolve();
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(screen.queryByRole("link", { name: "The Quiet Library" })).toBeNull();
  });

  test("an inconclusive check stays unverified: a response that arrives after it failed is not released", async () => {
    const libraryGate = deferred<void>();
    const server = standardServer();
    const { services } = renderApp({ server });
    await screen.findByText("Ada Reader");
    let libraryCalls = 0;
    server.on("GET", /\/api\/v1\/library(\?|$)/, async () => {
      libraryCalls += 1;
      if (libraryCalls > 1) return { status: 401, body: { error: "account_changed" } };
      await libraryGate.promise;
      return { body: page([summary({ title: "Late private A book" })]) };
    });
    server.on("GET", /\/api\/v1\/session$/, () => ({ status: 500, body: { error: "internal" } }));
    await userEvent.setup().click(screen.getByRole("radio", { name: "Audiobooks" }));
    await waitFor(() => expect(libraryCalls).toBe(1));
    window.dispatchEvent(new Event("focus"));
    await waitFor(() => expect(services.guard.trust).toBe("unverified"), { timeout: 8000 });
    libraryGate.resolve();
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(screen.queryByText("Late private A book")).toBeNull();
    await screen.findByRole("heading", { name: "The signed-in account changed" }, { timeout: 10000 });
    expect(screen.queryByText("Late private A book")).toBeNull();
  }, 20000);

  test("a newer focus event supersedes a check that is still pending, whatever that older check answers", async () => {
    const firstCheck = deferred<void>();
    const secondCheck = deferred<void>();
    const libraryGate = deferred<void>();
    const server = standardServer();
    const { services } = renderApp({ server });
    await screen.findByText("Ada Reader");
    let sessionCalls = 0;
    server.on("GET", /\/api\/v1\/session$/, async () => {
      sessionCalls += 1;
      if (sessionCalls === 1) {
        await firstCheck.promise;
        return { body: session() };
      }
      await secondCheck.promise;
      return { status: 401, body: { error: "account_changed" } };
    });
    server.on("GET", /\/api\/v1\/library(\?|$)/, async () => {
      await libraryGate.promise;
      return { body: page([summary({ title: "Coalesced private A book" })]) };
    });
    await userEvent.setup().click(screen.getByRole("radio", { name: "Audiobooks" }));
    window.dispatchEvent(new Event("focus"));
    await waitFor(() => expect(sessionCalls).toBe(1));
    window.dispatchEvent(new Event("pageshow"));
    await waitFor(() => expect(sessionCalls).toBe(2));
    libraryGate.resolve();
    firstCheck.resolve();
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(services.guard.trust).toBe("checking");
    expect(screen.queryByText("Coalesced private A book")).toBeNull();
    secondCheck.resolve();
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    expect(screen.queryByText("Coalesced private A book")).toBeNull();
    expect(services.queryClient.getQueryCache().getAll()).toHaveLength(0);
  });

  test("events fired together share one check", async () => {
    const server = standardServer();
    renderApp({ server });
    await screen.findByText("Ada Reader");
    const before = server.called("GET", /\/api\/v1\/session$/).length;
    window.dispatchEvent(new Event("focus"));
    window.dispatchEvent(new Event("pageshow"));
    document.dispatchEvent(new Event("visibilitychange"));
    await waitFor(() => expect(server.called("GET", /\/api\/v1\/session$/).length).toBe(before + 1));
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(server.called("GET", /\/api\/v1\/session$/).length).toBe(before + 1);
  });
});
