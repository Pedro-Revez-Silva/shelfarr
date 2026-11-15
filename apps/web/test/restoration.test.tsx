import { describe, expect, test } from "bun:test";
import { screen, waitFor } from "@testing-library/react";
import { MAX_RESTORED_PAGES, readSavedList, writeSavedList } from "../src/restoration";
import { FakeServer, page, renderApp, standardServer, summary } from "./helpers";

function pagedServer(total: number) {
  const server: FakeServer = standardServer().on("GET", /\/api\/v1\/library(\?|$)/, (request) => {
    const cursor = new URL(request.path, "http://shelf.test").searchParams.get("cursor");
    const index = cursor ? Number(cursor) : 0;
    const items = [summary({ id: String(index * 2 + 2), title: `Book ${index * 2 + 2}` }), summary({ id: String(index * 2 + 1), title: `Book ${index * 2 + 1}` })];
    return { body: page(items, index + 1 < total ? String(index + 1) : null) };
  });
  return server;
}

describe("restoring a list after the page was left and reopened", () => {
  test("replays the pages that were loaded and scrolls back to where the reader was", async () => {
    writeSavedList({ pages: 3, scrollY: 420 });
    const scrolls: number[] = [];
    const original = window.scrollTo;
    window.scrollTo = ((_x: number, y: number) => {
      scrolls.push(y);
    }) as typeof window.scrollTo;
    try {
      const server = pagedServer(5);
      renderApp({ server });
      await screen.findByRole("link", { name: "Book 6" });
      await waitFor(() => expect(scrolls).toContain(420));
      expect(server.called("GET", /\/library/).map((request) => new URL(request.path, "http://shelf.test").searchParams.get("cursor"))).toEqual([null, "1", "2"]);
      expect(screen.getAllByRole("link", { name: /^Book \d+$/ })).toHaveLength(6);
      expect(screen.queryByRole("button", { name: "Load more books" })?.textContent).toBe("Load more books");
    } finally {
      window.scrollTo = original;
    }
  });

  test("stops replaying when the list ended sooner than before", async () => {
    writeSavedList({ pages: 8, scrollY: 100 });
    const server = pagedServer(2);
    renderApp({ server });
    await screen.findByText("That is everything on this shelf.");
    expect(server.called("GET", /\/library/)).toHaveLength(2);
  });

  test("remembers the loaded pages and scroll position in the history entry as the reader goes", async () => {
    const server = pagedServer(3);
    renderApp({ server });
    await screen.findByRole("link", { name: "Book 2" });
    await waitFor(() => expect(readSavedList()).toEqual({ pages: 1, scrollY: 0 }));
    Object.defineProperty(window, "scrollY", { value: 333, configurable: true });
    const user = (await import("@testing-library/user-event")).default.setup();
    await user.click(screen.getByRole("button", { name: "Load more books" }));
    await screen.findByRole("link", { name: "Book 4" });
    await waitFor(() => expect(readSavedList()).toEqual({ pages: 2, scrollY: 333 }));
    Object.defineProperty(window, "scrollY", { value: 0, configurable: true });
  });

  test("ignores damaged saved state", () => {
    for (const bad of [{ pages: 0, scrollY: 1 }, { pages: MAX_RESTORED_PAGES + 1, scrollY: 1 }, { pages: 2, scrollY: -5 }, { pages: "2", scrollY: 1 }, "x", null]) {
      window.history.replaceState({ shelfarrLibrary: bad }, "");
      expect(readSavedList()).toBeNull();
    }
  });
});
