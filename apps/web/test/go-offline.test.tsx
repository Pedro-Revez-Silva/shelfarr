import { describe, expect, test } from "bun:test";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import { resetFirstPage } from "../src/components/PageHeading";
import type { GoView } from "../src/contract";
import { GoApp } from "../src/go/GoApp";
import { ACCOUNT, FakeServer } from "./helpers";
import { API, error, goBoot, signedIn, signedOut } from "./go-helpers";
import { AccountGuard } from "../src/api/account-guard";
import { OfflineProvider } from "../src/offline/context";
import { SaveForOffline } from "../src/offline/SaveForOffline";
import { createServices, ServicesProvider } from "../src/services";
import { DAY, EPUB_ID, MemoryOfflineStore, NEWER_ID, readerPublication, savedBook } from "./offline-helpers";

const OFFLINE = { worker: "/preview/offline-worker.js", scope: "/preview/library/", downloads: "/preview/library/downloads" };

function unreachable(): FakeServer {
  return new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
    throw new TypeError("Failed to fetch");
  });
}

function storeFor(account: string, confirmedAt = Date.now()): MemoryOfflineStore {
  const store = new MemoryOfflineStore();
  store.record = { account, confirmedAt, validForMs: 30 * DAY };
  store.saved.set("5|7", savedBook({ title: "Member's Saved Book" }));
  store.saved.set("4|8", savedBook({ key: "4|8", account: "4", id: "8", title: "Admin's Saved Book" }));
  return store;
}

function renderOffline(server: FakeServer, store: MemoryOfflineStore, view: GoView = "downloads", url = "/preview/library/downloads", offline: typeof OFFLINE | undefined = OFFLINE) {
  resetFirstPage();
  window.history.replaceState(null, "", url);
  return render(<GoApp boot={{ ...goBoot(view), ...(offline ? { offline } : {}) }} fetcher={server.fetcher} store={store} />);
}

describe("offline reading in the Go preview", () => {
  test("when the server cannot be reached, Downloads lists only the books saved for the confirmed account", async () => {
    renderOffline(unreachable(), storeFor("5"));
    expect(await screen.findByRole("heading", { name: "Member's Saved Book" })).toBeTruthy();
    expect(screen.getByText(/You're offline\./)).toBeTruthy();
    expect(screen.queryByText("Admin's Saved Book")).toBeNull();
    expect(screen.getByText(/also keeps 1 saved book/)).toBeTruthy();
    expect(screen.getByRole("link", { name: "Read Member's Saved Book" }).getAttribute("href")).toBe("/preview/library/7/read");
  });

  test("an expired, future-dated or missing confirmation shows no saved book", async () => {
    for (const store of [storeFor("5", Date.now() - 31 * DAY), storeFor("5", Date.now() + 60 * 60_000), (() => {
      const empty = storeFor("5");
      empty.record = null;
      return empty;
    })()]) {
      const view = renderOffline(unreachable(), store);
      expect(await screen.findByRole("heading", { name: "Shelfarr can't be reached" })).toBeTruthy();
      expect(screen.queryByText(/Saved Book/)).toBeNull();
      view.unmount();
    }
  });

  test("an answer from the server is never replaced by saved books, and a definitive refusal forgets the account", async () => {
    const answers: [() => unknown, string][] = [
      [() => error(404, "not_found"), "Shelfarr is unavailable here"],
      [() => error(500, "internal_error"), "Shelfarr is unavailable here"],
    ];
    for (const [answer, heading] of answers) {
      const store = storeFor("5");
      const view = renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, answer as never), store);
      expect(await screen.findByRole("heading", { name: heading })).toBeTruthy();
      expect(screen.queryByText(/Saved Book/)).toBeNull();
      view.unmount();
    }
    const refused = storeFor("5");
    const view = renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => error(404, "not_found")), refused);
    await screen.findByRole("heading", { name: "Shelfarr is unavailable here" });
    await waitFor(() => expect(refused.record).toBeNull());
    view.unmount();
  });

  test("other screens never fall back to saved books", async () => {
    renderOffline(unreachable(), storeFor("5"), "library", "/preview/library");
    expect(await screen.findByRole("heading", { name: "Shelfarr is unavailable here" })).toBeTruthy();
    expect(screen.queryByText(/Saved Book/)).toBeNull();
  });

  test("a signed-out answer forgets the confirmed account, and signing in records nothing without a saved copy", async () => {
    const store = storeFor("5");
    const view = renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: signedOut() })), store);
    await screen.findByRole("heading", { name: "Sign in" });
    await waitFor(() => expect(store.record).toBeNull());
    view.unmount();

    const fresh = new MemoryOfflineStore();
    renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: { ...signedIn(), offline_expires_in: 3600 } })), fresh);
    await screen.findByRole("heading", { name: "Downloads" });
    await act(() => new Promise((resolve) => setTimeout(resolve, 20)));
    expect(fresh.confirms).toEqual([]);
  });

  test("without the offline option, the account recorded for offline reading is forgotten", async () => {
    const store = storeFor("5");
    renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: signedIn() })).on("GET", /\/api\/v1\/session$/, () => ({ body: { account: ACCOUNT, server: { name: "Shelf", version: "1" }, links: {} } })), store, "library", "/preview/library", undefined);
    await waitFor(() => expect(store.record).toBeNull());
  });

  test("reconnecting as another account hides the saved books, and reconnecting signed out forgets the account", async () => {
    let answer: unknown = signedIn("4");
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
      if (answer === null) throw new TypeError("Failed to fetch");
      return { body: answer };
    });
    answer = null;
    const store = storeFor("5");
    renderOffline(server, store);
    await screen.findByRole("heading", { name: "Member's Saved Book" });
    answer = { ...signedIn("4"), offline_expires_in: 3600 };
    await act(async () => {
      window.dispatchEvent(new Event("online"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    expect(await screen.findByRole("heading", { name: "The signed-in account changed" })).toBeTruthy();
    expect(screen.queryByText(/Saved Book/)).toBeNull();
    expect(store.record?.account).toBe("4");
  });

  test("reconnecting signed out stops offline reading and forgets the account", async () => {
    let answer: unknown = null;
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
      if (answer === null) throw new TypeError("Failed to fetch");
      return { body: answer };
    });
    const store = storeFor("5");
    renderOffline(server, store);
    await screen.findByRole("heading", { name: "Member's Saved Book" });
    answer = signedOut();
    await act(async () => {
      window.dispatchEvent(new Event("online"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    expect(await screen.findByRole("heading", { name: "Offline access ended" })).toBeTruthy();
    expect(store.record).toBeNull();
  });

  test("reconnecting as the same account renews the confirmation and keeps reading", async () => {
    let answer: unknown = null;
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
      if (answer === null) throw new TypeError("Failed to fetch");
      return { body: answer };
    });
    const store = storeFor("5", Date.now() - 10 * DAY);
    renderOffline(server, store);
    await screen.findByRole("heading", { name: "Member's Saved Book" });
    answer = { ...signedIn("5"), offline_expires_in: 3600 };
    await act(async () => {
      window.dispatchEvent(new Event("online"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    const banner = await screen.findByText(/You're connected again/);
    expect(within(banner).getByRole("button", { name: "Continue online" })).toBeTruthy();
    expect(store.record?.validForMs).toBe(3_600_000);
    expect(screen.getByRole("heading", { name: "Member's Saved Book" })).toBeTruthy();
  });

  test("Downloads online lists the signed-in account's books and removes one on request", async () => {
    const store = storeFor("5");
    renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: { ...signedIn("5"), offline_expires_in: 3600 } })), store);
    const item = (await screen.findByRole("heading", { name: "Member's Saved Book" })).closest("li") as HTMLElement;
    expect(screen.queryByText(/You're offline/)).toBeNull();
    await act(async () => within(item).getByRole("button", { name: "Remove Member's Saved Book" }).click());
    await act(async () => within(item).getByRole("button", { name: "Remove" }).click());
    await waitFor(() => expect(screen.queryByRole("heading", { name: "Member's Saved Book" })).toBeNull());
    expect([...store.saved.keys()]).toEqual(["4|8"]);
    expect(store.files.size).toBe(0);
    expect(document.activeElement?.id).toBe("downloads-heading");
    expect(screen.getByText(`Removed “Member's Saved Book” from this browser.`)).toBeTruthy();
  });
});

function renderControl(store: MemoryOfflineStore, currentAsset: string | null) {
  const guard = new AccountGuard("5");
  const services = createServices({ boot: { version: 1, account: "5", mount: "/preview", api: API, classic_library: null, runtime: "go" }, guard, csrfToken: () => null });
  const loads: string[] = [];
  render(
    <ServicesProvider services={services}>
      <OfflineProvider value={{ boot: OFFLINE, store, confirmation: { account: "5", confirmedAt: Date.now(), validForMs: DAY }, connected: true }}>
        <SaveForOffline id="7" title="Member's Saved Book" currentAsset={currentAsset} load={async () => {
          loads.push("7");
          return readerPublication();
        }} />
      </OfflineProvider>
    </ServicesProvider>,
  );
  return { loads };
}

describe("the save control", () => {
  test("a refused save says why, keeps focus in the control and stores nothing", async () => {
    const store = new MemoryOfflineStore();
    renderControl(store, EPUB_ID);
    const button = await screen.findByRole("button", { name: "Save for offline reading" });
    button.focus();
    await act(async () => button.click());
    expect(await screen.findByText("Offline reading couldn't start in this browser, so nothing was saved. Reload the page and try again.")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Try again" })).toBeTruthy();
    await waitFor(() => expect(document.activeElement?.getAttribute("role")).toBe("status"));
    expect(store.saved.size + store.confirms.length).toBe(0);
  });

  test("a saved copy of another edition offers an update and removal asks first", async () => {
    const store = storeFor("5");
    renderControl(store, NEWER_ID);
    expect(await screen.findByText(/The server now has a different edition/)).toBeTruthy();
    expect(screen.getByRole("button", { name: "Update saved copy" })).toBeTruthy();
    await act(async () => screen.getByRole("button", { name: "Remove saved copy" }).click());
    expect(store.saved.has("5|7")).toBe(true);
    await act(async () => screen.getByRole("button", { name: "Remove" }).click());
    expect(await screen.findByRole("button", { name: "Save for offline reading" })).toBeTruthy();
    expect(store.saved.has("5|7")).toBe(false);
    expect(store.saved.has("4|8")).toBe(true);
  });

  test("an unfinished or failed save is shown with the earlier copy still kept", async () => {
    const store = storeFor("5");
    store.attemptRecords.set("5|7", { key: "5|7", account: "5", id: "7", title: "Member's Saved Book", assetId: NEWER_ID, startedAt: 1, failure: null });
    renderControl(store, EPUB_ID);
    expect(await screen.findByText("The last save didn't finish, so nothing new was stored. Your earlier saved copy is unchanged.")).toBeTruthy();
  });
});
