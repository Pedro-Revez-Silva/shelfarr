import { describe, expect, test } from "bun:test";
import { createMemoryHistory } from "@tanstack/react-router";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { App } from "../src/App";
import { checkQuery } from "../src/components/DiscoverPage";
import { resetFirstPage } from "../src/components/PageHeading";
import { discoverSchema, type DiscoverAnswer, type DiscoverItem } from "../src/contract";
import { createAppRouter } from "../src/router";
import { createServices } from "../src/services";
import { ACCOUNT, deferred, FakeServer, page, renderApp, session, summary, type RecordedRequest } from "./helpers";
import { error, libraryServer, renderGo, signedIn, signedOut } from "./go-helpers";

function item(overrides: Partial<DiscoverItem> = {}): DiscoverItem {
  return {
    id: "OL27448W",
    title: "The Lord of the Rings",
    author: "J.R.R. Tolkien",
    first_publish_year: 1954,
    edition_count: 256,
    cover_url: "https://covers.openlibrary.org/b/id/14625765-M.jpg",
    source_url: "https://openlibrary.org/works/OL27448W",
    library: [
      { book_type: "ebook", publication_id: "12" },
      { book_type: "audiobook", publication_id: "11" },
    ],
    ...overrides,
  };
}

function answer(query: string | null, items: DiscoverItem[] = [], overrides: Partial<DiscoverAnswer> = {}): DiscoverAnswer {
  return { account: ACCOUNT, provider: { name: "Open Library", url: "https://openlibrary.org" }, search: "available", query, items, ...overrides };
}

const second = item({ id: "OL82563W", title: "Harbor Panels", author: null, first_publish_year: null, edition_count: 1, cover_url: null, source_url: "https://openlibrary.org/works/OL82563W", library: [] });

function queryOf(request: RecordedRequest): string | null {
  return new URL(request.path, "http://shelf.test").searchParams.get("q");
}

function discoverServer(respond: (query: string | null, request: RecordedRequest) => ReturnType<Parameters<FakeServer["on"]>[2]> = (query) => ({ body: answer(query, query ? [item(), second] : []) })): FakeServer {
  return new FakeServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session() }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", /\/api\/v1\/library\/12$/, () => ({ body: { account: ACCOUNT, publication: { ...summary({ id: "12", title: "The Lord of the Rings" }), description: "", files: [] } } }))
    .on("GET", /\/api\/v1\/discover(\?|$)/, (request) => respond(queryOf(request), request));
}

function searches(server: FakeServer): RecordedRequest[] {
  return server.called("GET", /\/api\/v1\/discover(\?|$)/);
}

function renderDiscover(server: FakeServer, url = "/preview/discover") {
  resetFirstPage();
  const services = createServices({
    boot: { version: 1, account: ACCOUNT, mount: "/preview", api: "/preview/api/v1", classic_library: null, runtime: "go" },
    csrfToken: () => "session-token",
    fetcher: server.fetcher,
  });
  const history = createMemoryHistory({ initialEntries: [url] });
  const router = createAppRouter({ basepath: "/preview", history });
  const view = render(<App services={services} router={router} />);
  return { services, router, view, history };
}

const field = () => screen.getByRole("searchbox", { name: "Title or author" });

describe("the discover contract", () => {
  test("accepts only Open Library work links, Open Library cover images and the known states", () => {
    expect(discoverSchema.safeParse(answer("dune", [item()])).success).toBe(true);
    expect(discoverSchema.safeParse(answer("dune", [item({ cover_url: "https://evil.test/b/id/1-M.jpg" })])).success).toBe(false);
    expect(discoverSchema.safeParse(answer("dune", [item({ cover_url: "http://covers.openlibrary.org/b/id/1-M.jpg" })])).success).toBe(false);
    expect(discoverSchema.safeParse(answer("dune", [item({ source_url: "https://openlibrary.org/works/OL1W" })])).success).toBe(false);
    expect(discoverSchema.safeParse(answer("dune", [item({ source_url: "javascript:alert(1)" })])).success).toBe(false);
    expect(discoverSchema.safeParse(answer("dune", [item({ id: "/works/OL27448W" })])).success).toBe(false);
    expect(discoverSchema.safeParse(answer("dune", [item({ library: [{ book_type: "ebook", publication_id: "../12" }] as DiscoverItem["library"] })])).success).toBe(false);
    expect(discoverSchema.safeParse(answer("dune", [], { search: "requestable" as DiscoverAnswer["search"] })).success).toBe(false);
    expect(discoverSchema.safeParse(answer("dune", [], { provider: { name: "Hardcover", url: "https://openlibrary.org" } as unknown as DiscoverAnswer["provider"] })).success).toBe(false);
  });

  test("queries are trimmed, bounded to two hundred characters and plain text", () => {
    expect(checkQuery(undefined)).toEqual({ kind: "none" });
    expect(checkQuery("   ")).toEqual({ kind: "none" });
    expect(checkQuery("  dune ")).toEqual({ kind: "ready", query: "dune" });
    expect(checkQuery("📚".repeat(200))).toEqual({ kind: "ready", query: "📚".repeat(200) });
    expect(checkQuery("a".repeat(201))).toEqual({ kind: "too_long" });
    expect(checkQuery("tab\tinside")).toEqual({ kind: "invalid" });
  });
});

describe("the Go Discover page", () => {
  test("is in the Go navigation, checks availability without searching, and searches only when the form is submitted", async () => {
    const server = discoverServer();
    const { history } = renderDiscover(server, "/preview/library");
    const user = userEvent.setup();
    const nav = await screen.findByRole("navigation", { name: "Primary" });
    await user.click(within(nav).getByRole("link", { name: "Discover" }));
    const heading = await screen.findByRole("heading", { level: 1, name: "Discover" });
    await waitFor(() => expect(document.activeElement).toBe(heading));
    expect(document.title).toBe("Discover · Shelfarr");
    expect(within(nav).getByRole("link", { name: "Discover" }).getAttribute("aria-current")).toBe("page");
    await waitFor(() => expect(searches(server).map(queryOf)).toEqual([null]));
    const input = field();
    expect(input.closest("search")).toBeTruthy();
    expect(input.getAttribute("maxlength")).toBe("200");
    await user.type(input, "the lord & rings");
    await act(async () => Bun.sleep(30));
    expect(searches(server).map(queryOf)).toEqual([null]);
    await user.keyboard("{Enter}");
    expect(await screen.findByText("2 results from Open Library for “the lord & rings”.")).toBeTruthy();
    expect(searches(server).map(queryOf)).toEqual([null, "the lord & rings"]);
    expect(history.location.pathname).toBe("/preview/discover");
    expect(new URLSearchParams(history.location.search).get("q")).toBe("the lord & rings");
    expect(document.title).toBe("Discover: the lord & rings · Shelfarr");
    expect(server.requests.filter((request) => request.method !== "GET")).toEqual([]);
    expect(screen.getByRole("status").textContent).toBe("2 results from Open Library for “the lord & rings”.");
  });

  test("a signed-out direct load says it returns to the search, then shows the searched results after sign-in", async () => {
    let signed = false;
    const server = libraryServer(() => (signed ? signedIn() : signedOut()))
      .on("POST", /\/auth\/login$/, () => {
        signed = true;
        return { body: signedIn() };
      })
      .on("GET", /\/api\/v1\/discover(\?|$)/, (request) => ({ body: answer(queryOf(request), [item()]) }));
    renderGo({ server, view: "discover", url: "/preview/discover?q=dune" });
    expect(await screen.findByText("Sign in to find books. You will come straight back to your search.")).toBeTruthy();
    expect(searches(server)).toEqual([]);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Username"), "ada");
    await user.type(screen.getByLabelText("Password"), "Secret-Passw0rd");
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    expect(await screen.findByText("1 result from Open Library for “dune”.")).toBeTruthy();
    expect(searches(server).map(queryOf)).toEqual(["dune"]);
  });

  test("shows each result with its Open Library attribution and only the library copies the server named", async () => {
    const server = discoverServer();
    renderDiscover(server, "/preview/discover?q=rings");
    const results = await screen.findByRole("region", { name: "Results from Open Library" });
    const [first, other] = within(results).getAllByRole("article");
    if (!first || !other) throw new Error("two results expected");
    expect(within(first).getByRole("heading", { level: 3 }).textContent).toBe("The Lord of the Rings");
    expect(within(first).getByText("J.R.R. Tolkien")).toBeTruthy();
    expect(within(first).getByText("First published 1954 · 256 editions")).toBeTruthy();
    const copies = within(first).getByRole("list", { name: "In your library" });
    const links = within(copies).getAllByRole("link");
    expect(links.map((link) => [link.textContent, link.getAttribute("href")])).toEqual([
      ["Open the ebook of The Lord of the Rings in your library", "/preview/library/12"],
      ["Open the audiobook of The Lord of the Rings in your library", "/preview/library/11"],
    ]);
    const source = within(first).getByRole("link", { name: "View on Open Library for The Lord of the Rings (opens in a new tab)" });
    expect([source.getAttribute("href"), source.getAttribute("target"), source.getAttribute("rel")]).toEqual(["https://openlibrary.org/works/OL27448W", "_blank", "noopener noreferrer"]);
    const image = first.querySelector("img");
    expect([image?.getAttribute("src"), image?.getAttribute("referrerpolicy"), image?.getAttribute("loading"), image?.getAttribute("alt")]).toEqual(["https://covers.openlibrary.org/b/id/14625765-M.jpg", "no-referrer", "lazy", ""]);
    expect(within(other).getByText("Author not listed")).toBeTruthy();
    expect(within(other).getByText("1 edition")).toBeTruthy();
    expect(within(other).getByText("No copy to open in your library")).toBeTruthy();
    expect(within(other).queryByRole("list", { name: "In your library" })).toBeNull();
    expect(other.querySelector("img")).toBeNull();
    expect(within(results).getByText(/Requesting books is not part of this preview yet/)).toBeTruthy();
    expect(screen.queryByRole("button", { name: /request/i })).toBeNull();
    const user = userEvent.setup();
    await user.click(links[0] as HTMLElement);
    expect(await screen.findByRole("heading", { level: 1, name: "The Lord of the Rings" })).toBeTruthy();
  });

  test("a direct load with a query searches once, and Back and Forward reuse the answers instead of searching again", async () => {
    const server = discoverServer();
    const { router } = renderDiscover(server, "/preview/discover?q=dune");
    await screen.findByText("2 results from Open Library for “dune”.");
    expect(searches(server).map(queryOf)).toEqual(["dune"]);
    const user = userEvent.setup();
    const input = field() as HTMLInputElement;
    expect(input.value).toBe("dune");
    await user.clear(input);
    await user.type(input, "emma{Enter}");
    await screen.findByText("2 results from Open Library for “emma”.");
    act(() => router.history.back());
    await screen.findByText("2 results from Open Library for “dune”.");
    expect((field() as HTMLInputElement).value).toBe("dune");
    act(() => router.history.forward());
    await screen.findByText("2 results from Open Library for “emma”.");
    expect(searches(server).map(queryOf)).toEqual(["dune", "emma"]);
  });

  test("the field keeps focus through a keyboard search so the next search can be typed at once", async () => {
    const server = discoverServer();
    renderDiscover(server);
    const user = userEvent.setup();
    await waitFor(() => expect(searches(server).length).toBe(1));
    const input = field();
    await user.click(input);
    await user.keyboard("dune{Enter}");
    await screen.findByText("2 results from Open Library for “dune”.");
    expect(document.activeElement).toBe(input);
    expect(field()).toBe(input);
    await user.keyboard("{Control>}a{/Control}emma{Enter}");
    await screen.findByText("2 results from Open Library for “emma”.");
    expect(document.activeElement).toBe(input);
    expect(searches(server).map(queryOf)).toEqual([null, "dune", "emma"]);
  });

  test("a query repeated in the address searches the one the address is rewritten to", async () => {
    const server = discoverServer();
    const { router } = renderDiscover(server, "/preview/discover?q=dune&q=foundation");
    await screen.findByText("2 results from Open Library for “foundation”.");
    expect(router.history.location.search).toBe("?q=foundation");
    expect(searches(server).map(queryOf)).toEqual(["foundation"]);
  });

  test("an unavailable answer is checked again on request and on a later visit instead of being kept for minutes", async () => {
    let paused = true;
    const server = discoverServer((query) => ({ body: paused ? answer(query, [], { search: "provider_paused", retry_after: 1 }) : answer(query, query ? [item()] : []) }));
    const { router } = renderDiscover(server, "/preview/discover?q=dune");
    expect(await screen.findByRole("heading", { level: 2, name: "Open Library is paused for now" })).toBeTruthy();
    expect(screen.getByText(/Try again in about 1 second\./)).toBeTruthy();
    paused = false;
    act(() => {
      void router.navigate({ to: "/library" });
    });
    await screen.findByRole("heading", { level: 1, name: "Library" });
    act(() => router.history.back());
    expect(await screen.findByText("1 result from Open Library for “dune”.")).toBeTruthy();
    paused = true;
    const user = userEvent.setup();
    act(() => {
      void router.navigate({ to: "/discover" });
    });
    expect(await screen.findByRole("heading", { level: 2, name: "Open Library is paused for now" })).toBeTruthy();
    paused = false;
    await user.click(screen.getByRole("button", { name: "Check again" }));
    expect(await screen.findByRole("searchbox", { name: "Title or author" })).toBeTruthy();
    expect(searches(server).map(queryOf)).toEqual(["dune", "dune", null, null]);
  });

  test("a check that ends in a failure shows only the failure, with the form back", async () => {
    let calls = 0;
    const server = discoverServer((query) => {
      calls += 1;
      return calls === 1 ? { body: answer(query, [], { search: "provider_paused", retry_after: 5 }) } : error(502, "search_failed");
    });
    renderDiscover(server, "/preview/discover?q=dune");
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Check again" }));
    expect(await screen.findByRole("heading", { level: 2, name: "Open Library's answer could not be used" })).toBeTruthy();
    expect(screen.queryByRole("heading", { level: 2, name: "Open Library is paused for now" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Check again" })).toBeNull();
    expect(screen.getByRole("searchbox", { name: "Title or author" })).toBeTruthy();
  });

  test("a failed search is not sent again by leaving and coming back, only by Try again", async () => {
    const server = discoverServer(() => error(502, "search_failed"));
    const { router } = renderDiscover(server, "/preview/discover?q=dune");
    await screen.findByRole("heading", { level: 2, name: "Open Library's answer could not be used" });
    act(() => {
      void router.navigate({ to: "/library" });
    });
    await screen.findByRole("heading", { level: 1, name: "Library" });
    act(() => router.history.back());
    await screen.findByRole("heading", { level: 2, name: "Open Library's answer could not be used" });
    await act(async () => Bun.sleep(50));
    expect(searches(server).map(queryOf)).toEqual(["dune"]);
  });

  test("a failed check of a paused search is not sent again by leaving and coming back", async () => {
    let calls = 0;
    const server = discoverServer((query) => {
      calls += 1;
      return calls === 1 ? { body: answer(query, [], { search: "provider_paused", retry_after: 5 }) } : error(502, "search_failed");
    });
    const { router } = renderDiscover(server, "/preview/discover?q=dune");
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Check again" }));
    await screen.findByRole("heading", { level: 2, name: "Open Library's answer could not be used" });
    act(() => {
      void router.navigate({ to: "/library" });
    });
    await screen.findByRole("heading", { level: 1, name: "Library" });
    act(() => router.history.back());
    await screen.findByRole("heading", { level: 2, name: "Open Library's answer could not be used" });
    await act(async () => Bun.sleep(50));
    expect(searches(server).map(queryOf)).toEqual(["dune", "dune"]);
  });

  test("a failed search is not sent again by searching something else and going Back", async () => {
    const server = discoverServer((query) => (query === "dune" ? error(502, "search_failed") : { body: answer(query, [item()]) }));
    const { router } = renderDiscover(server, "/preview/discover?q=dune");
    await screen.findByRole("heading", { level: 2, name: "Open Library's answer could not be used" });
    const user = userEvent.setup();
    const input = field();
    await user.clear(input);
    await user.type(input, "emma{Enter}");
    await screen.findByText("1 result from Open Library for “emma”.");
    act(() => router.history.back());
    await screen.findByRole("heading", { level: 2, name: "Open Library's answer could not be used" });
    await act(async () => Bun.sleep(50));
    expect(searches(server).map(queryOf)).toEqual(["dune", "emma"]);
    await user.click(screen.getByRole("button", { name: "Try again" }));
    await waitFor(() => expect(searches(server).map(queryOf)).toEqual(["dune", "emma", "dune"]));
  });

  test("moving between two addresses for the same search puts the field back to that search", async () => {
    const server = discoverServer();
    const { router } = renderDiscover(server, "/preview/discover?q=+dune+");
    await screen.findByText("2 results from Open Library for “dune”.");
    act(() => {
      void router.navigate({ to: "/discover", search: { q: "dune" } });
    });
    const user = userEvent.setup();
    const input = field() as HTMLInputElement;
    await user.clear(input);
    await user.type(input, "emma");
    act(() => router.history.back());
    await waitFor(() => expect((field() as HTMLInputElement).value).toBe("dune"));
  });

  test("a server with search switched off offers no check, since only a restart changes it", async () => {
    const server = discoverServer((query) => ({ body: answer(query, [], { search: "server_off" }) }));
    renderDiscover(server);
    expect(await screen.findByRole("heading", { level: 2, name: "Search is switched off on this server" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Check again" })).toBeNull();
  });

  test("a blank search sends nothing and says why, and an over-long query in the address is never sent", async () => {
    const server = discoverServer();
    renderDiscover(server);
    const user = userEvent.setup();
    await waitFor(() => expect(searches(server).length).toBe(1));
    await user.type(field(), "   {Enter}");
    expect(await screen.findByText("Type a title or an author first.")).toBeTruthy();
    expect(field().getAttribute("aria-invalid")).toBe("true");
    expect(searches(server).map(queryOf)).toEqual([null]);

    const longServer = discoverServer();
    renderDiscover(longServer, `/preview/discover?q=${"a".repeat(201)}`);
    expect(await screen.findByText("Use 200 characters or fewer.")).toBeTruthy();
    await act(async () => Bun.sleep(30));
    expect(searches(longServer).map(queryOf)).toEqual([null]);
  });

  test("a newer search replaces an older one whose answer arrives late, and the older request is cancelled", async () => {
    const slow = deferred<{ body: unknown }>();
    const server = discoverServer((query) => (query === "dune" ? slow.promise : { body: answer(query, query ? [second] : []) }));
    renderDiscover(server, "/preview/discover?q=dune");
    expect(await screen.findByText("Searching Open Library for “dune”…")).toBeTruthy();
    const user = userEvent.setup();
    const input = field();
    await user.clear(input);
    await user.type(input, "emma{Enter}");
    await screen.findByText("1 result from Open Library for “emma”.");
    const first = searches(server)[0];
    expect(first?.signal?.aborted).toBe(true);
    await act(async () => slow.resolve({ body: answer("dune", [item()]) }));
    await act(async () => Bun.sleep(20));
    expect(screen.queryByText("The Lord of the Rings")).toBeNull();
    expect(screen.getAllByRole("heading", { level: 3 }).map((heading) => heading.textContent)).toEqual(["Harbor Panels"]);
  });

  test("submitting the same search again while it runs sends nothing more", async () => {
    const slow = deferred<{ body: unknown }>();
    const server = discoverServer((query) => (query === "dune" ? slow.promise : { body: answer(query) }));
    renderDiscover(server, "/preview/discover?q=dune");
    const user = userEvent.setup();
    await screen.findByText("Searching Open Library for “dune”…");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await user.type(field(), " {Enter}");
    await act(async () => Bun.sleep(30));
    expect(searches(server).map(queryOf)).toEqual(["dune"]);
    await act(async () => slow.resolve({ body: answer("dune", [item()]) }));
    expect(await screen.findByText("1 result from Open Library for “dune”.")).toBeTruthy();
  });

  for (const [state, title, extra] of [
    ["server_off", "Search is switched off on this server", "the person who runs this server has to switch it on"],
    ["provider_disabled", "Open Library is turned off in Shelfarr's settings", "cannot search other sources yet"],
    ["provider_not_selected", "Shelfarr is set to search a different source", "can only search Open Library so far"],
    ["provider_paused", "Open Library is paused for now", "Try again in about 3 minutes."],
  ] as const) {
    test(`says accurately why search is unavailable when the server reports ${state}, without a form`, async () => {
      const server = discoverServer((query) => ({ body: answer(query, [], { search: state, ...(state === "provider_paused" ? { retry_after: 170 } : {}) }) }));
      renderDiscover(server, "/preview/discover?q=dune");
      expect(await screen.findByRole("heading", { level: 2, name: title })).toBeTruthy();
      expect(screen.getByText(new RegExp(extra.replace(/[.]/g, "\\.")))).toBeTruthy();
      expect(screen.queryByRole("searchbox")).toBeNull();
      expect(screen.queryByRole("region", { name: "Results from Open Library" })).toBeNull();
    });
  }

  for (const [label, failure, title, detail] of [
    ["rate limited", error(429, "search_rate_limited", {}, { "retry-after": "30" }), "Too many searches right now", "Try again in about 30 seconds."],
    ["unreachable", error(503, "search_unavailable"), "Open Library could not be reached", "to search for “dune”"],
    ["unusable", error(502, "search_failed"), "Open Library's answer could not be used", "Try again later."],
    ["refused", error(422, "invalid_query"), "That search was not accepted", "up to 200 characters"],
    ["older server", error(404, "not_found"), "Discover is not available on this server", "Nothing was changed."],
  ] as const) {
    test(`names a ${label} search and never retries it by itself`, async () => {
      let calls = 0;
      const server = discoverServer(() => {
        calls += 1;
        return failure;
      });
      renderDiscover(server, "/preview/discover?q=dune");
      expect(await screen.findByRole("heading", { level: 2, name: title })).toBeTruthy();
      expect(screen.getByText(new RegExp(detail.replace(/[.]/g, "\\.")))).toBeTruthy();
      await act(async () => Bun.sleep(60));
      expect(calls).toBe(1);
      expect(screen.getByRole("status").textContent).toBe("The search for “dune” did not finish.");
    });
  }

  test("try again sends the same search once more", async () => {
    let calls = 0;
    const server = discoverServer((query) => {
      calls += 1;
      return calls === 1 ? error(503, "search_unavailable") : { body: answer(query, [item()]) };
    });
    renderDiscover(server, "/preview/discover?q=dune");
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Try again" }));
    expect(await screen.findByText("1 result from Open Library for “dune”.")).toBeTruthy();
    expect(searches(server).map(queryOf)).toEqual(["dune", "dune"]);
  });

  test("an answer for another account locks the page and shows none of its results", async () => {
    const server = discoverServer((query) => ({ body: { ...answer(query, [item()]), account: "99" } }));
    renderDiscover(server, "/preview/discover?q=dune");
    expect(await screen.findByRole("heading", { name: /account changed/i })).toBeTruthy();
    expect(screen.queryByText("The Lord of the Rings")).toBeNull();
  });

  test("a session check that reports another account locks the page and the results go away", async () => {
    let changed = false;
    const server = discoverServer().on("GET", /\/api\/v1\/session$/, () => (changed ? error(401, "account_changed") : { body: session() }));
    renderDiscover(server, "/preview/discover?q=dune");
    await screen.findByText("The Lord of the Rings");
    changed = true;
    act(() => {
      window.dispatchEvent(new Event("focus"));
    });
    expect(await screen.findByRole("heading", { name: /account changed/i })).toBeTruthy();
    expect(screen.queryByText("The Lord of the Rings")).toBeNull();
    expect(searches(server).map(queryOf)).toEqual(["dune"]);
  });

  test("is not part of the Rails-served preview, which keeps its classic Discover handoff", async () => {
    const server = discoverServer();
    renderApp({ server, url: "/sub/preview/discover?q=dune" });
    expect(await screen.findByRole("heading", { name: "That page is not part of this preview" })).toBeTruthy();
    const nav = await screen.findByRole("navigation", { name: "Primary" });
    await waitFor(() => expect(within(nav).getByRole("link", { name: /Discover/ }).getAttribute("href")).toBe("/sub/search"));
    expect(searches(server)).toEqual([]);
  });
});
