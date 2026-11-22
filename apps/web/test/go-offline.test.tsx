import { describe, expect, test } from "bun:test";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import { resetFirstPage } from "../src/components/PageHeading";
import type { GoView } from "../src/contract";
import { GoApp } from "../src/go/GoApp";
import userEvent from "@testing-library/user-event";
import { ACCOUNT, FakeServer, detail } from "./helpers";
import { API, error, goBoot, libraryServer, signedIn, signedOut } from "./go-helpers";
import { AccountGuard } from "../src/api/account-guard";
import { OfflineProvider } from "../src/offline/context";
import { SaveForOffline } from "../src/offline/SaveForOffline";
import { createServices, ServicesProvider } from "../src/services";
import { DAY, EPUB_ID, MemoryOfflineStore, NEWER_ID, SIZE, epubBytes, readerPublication, savedBook, serverProgress } from "./offline-helpers";

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

function renderOffline(server: FakeServer, store: MemoryOfflineStore, view: GoView = "downloads", url = "/preview/library/downloads", offline: typeof OFFLINE | null = OFFLINE) {
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
    renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: signedIn() })).on("GET", /\/api\/v1\/session$/, () => ({ body: { account: ACCOUNT, server: { name: "Shelf", version: "1" }, links: {} } })), store, "library", "/preview/library", null);
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

  test("reconnecting to a server whose offline option is off ends offline access and forgets the account", async () => {
    let answer: unknown = null;
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
      if (answer === null) throw new TypeError("Failed to fetch");
      return { body: answer };
    });
    const store = storeFor("5");
    renderOffline(server, store);
    await screen.findByRole("heading", { name: "Member's Saved Book" });
    answer = signedIn("5");
    await act(async () => {
      window.dispatchEvent(new Event("online"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    expect(await screen.findByRole("heading", { name: "Offline access ended" })).toBeTruthy();
    expect(store.record).toBeNull();
    expect(screen.queryByText(/Saved Book/)).toBeNull();
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
      <OfflineProvider value={{ boot: OFFLINE, store, confirmation: { account: "5", confirmedAt: Date.now(), validForMs: DAY }, connected: true, confirm: () => Promise.reject(new Error("unused")), sync: null }}>
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
    store.attemptRecords.set("5|7", { key: "5|7", account: "5", id: "7", title: "Member's Saved Book", assetId: NEWER_ID, token: "t", startedAt: 1, failure: null });
    renderControl(store, EPUB_ID);
    expect(await screen.findByText("The last save didn't finish, so nothing new was stored. Your earlier saved copy is unchanged.")).toBeTruthy();
  });
});

describe("saving from the Go details page", () => {
  const files = [{ id: EPUB_ID, filename: "Saved Book.epub", format: "epub", media_type: "application/epub+zip", size_bytes: 2048, position: 0, page_count: null }];

  function detailsServer(bootstrap: () => unknown) {
    return libraryServer(bootstrap).on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail({ files }) } }));
  }

  test("an EPUB's details offer saving, the navigation links Downloads and the note says what can be saved", async () => {
    const store = new MemoryOfflineStore();
    renderOffline(detailsServer(() => ({ ...signedIn(), offline_expires_in: 3600 })), store, "details", "/preview/library/7");
    const section = (await screen.findByRole("heading", { name: "Offline reading" })).closest("section") as HTMLElement;
    expect(within(section).getByRole("button", { name: "Save for offline reading" })).toBeTruthy();
    expect(screen.getByRole("link", { name: "Downloads" }).getAttribute("href")).toBe("/preview/library/downloads");
    expect(screen.getByRole("note").textContent).toContain("save EPUBs for offline reading in this browser");
  });

  test("without the option, or for a book without an EPUB, nothing offline is offered", async () => {
    const view = renderOffline(detailsServer(() => signedIn()), new MemoryOfflineStore(), "details", "/preview/library/7", null);
    await screen.findByRole("heading", { name: detail().title });
    expect(screen.queryByRole("heading", { name: "Offline reading" })).toBeNull();
    expect(screen.queryByRole("link", { name: "Downloads" })).toBeNull();
    expect(screen.getByRole("note").textContent).toContain("downloads and offline reading are not available here yet");
    view.unmount();
    renderOffline(
      libraryServer(() => ({ ...signedIn(), offline_expires_in: 3600 })).on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail({ files: [{ ...files[0]!, format: "pdf" }] }) } })),
      new MemoryOfflineStore(),
      "details",
      "/preview/library/7",
    );
    await screen.findByRole("heading", { name: detail().title });
    expect(screen.queryByRole("heading", { name: "Offline reading" })).toBeNull();
  });

  test("signing in names the offline window, so the details page can offer saving straight away", async () => {
    const server = detailsServer(() => signedOut("login-token")).on("POST", /\/auth\/login$/, () => ({ body: { ...signedIn(), offline_expires_in: 3600 } }));
    renderOffline(server, new MemoryOfflineStore(), "details", "/preview/library/7");
    const user = userEvent.setup();
    await user.type(await screen.findByLabelText("Username"), "reader");
    await user.type(screen.getByLabelText("Password"), "synthetic-password");
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    expect(await screen.findByRole("button", { name: "Save for offline reading" })).toBeTruthy();
  });
});

function asOfflineBrowser(download: () => Response) {
  const saved = { secure: Object.getOwnPropertyDescriptor(window, "isSecureContext"), fetch: globalThis.fetch };
  const fetched: string[] = [];
  Object.defineProperty(window, "isSecureContext", { value: true, configurable: true });
  Object.defineProperty(navigator, "serviceWorker", { value: { register: async () => ({ active: {} }), getRegistration: async () => undefined }, configurable: true });
  Object.defineProperty(globalThis, "caches", { value: { keys: async () => [] }, configurable: true });
  Object.defineProperty(globalThis, "indexedDB", { value: {}, configurable: true });
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    fetched.push(String(input));
    return download();
  }) as typeof fetch;
  return {
    fetched,
    restore: () => {
      globalThis.fetch = saved.fetch;
      if (saved.secure) Object.defineProperty(window, "isSecureContext", saved.secure);
      else Reflect.deleteProperty(window, "isSecureContext");
      for (const target of [navigator, globalThis]) for (const name of ["serviceWorker", "caches", "indexedDB"]) if (Object.getOwnPropertyDescriptor(target, name)?.configurable) Reflect.deleteProperty(target, name);
    },
  };
}

const readerFor = (account: string) => ({ body: { account, publication: readerPublication() } });
const epub = () => new Response(epubBytes(), { headers: { ETag: `"${EPUB_ID}"`, "Content-Length": String(SIZE) } });

describe("account checks around a save", () => {
  test("a save confirms the account with the server first and then stores the copy", async () => {
    const browser = asOfflineBrowser(epub);
    try {
      const store = new MemoryOfflineStore();
      const server = libraryServer(() => ({ ...signedIn(), offline_expires_in: 3600 }))
        .on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail({ files: [{ id: EPUB_ID, filename: "Saved Book.epub", format: "epub", media_type: "application/epub+zip", size_bytes: SIZE, position: 0, page_count: null }] }) } }))
        .on("GET", /\/api\/v1\/library\/7\/reader$/, () => readerFor(ACCOUNT));
      renderOffline(server, store, "details", "/preview/library/7");
      const save = await screen.findByRole("button", { name: "Save for offline reading" });
      await act(async () => save.click());
      expect(await screen.findByText(/Saved on this device on/)).toBeTruthy();
      expect(server.called("GET", /\/auth\/bootstrap$/)).toHaveLength(2);
      expect(store.record?.account).toBe(ACCOUNT);
      expect(browser.fetched).toEqual([`/preview/api/v1/accounts/5/library/7/assets/${EPUB_ID}`]);
      expect(store.saved.has(`${ACCOUNT}|7`)).toBe(true);
    } finally {
      browser.restore();
    }
  });

  test("a sign-out in another tab while the save checks the account is never undone by the save", async () => {
    const browser = asOfflineBrowser(epub);
    try {
      const store = new MemoryOfflineStore();
      let loads = 0;
      const server = libraryServer(() => {
        loads += 1;
        if (loads > 1) void store.forget();
        return { ...signedIn(), offline_expires_in: 3600 };
      })
        .on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail({ files: [{ id: EPUB_ID, filename: "Saved Book.epub", format: "epub", media_type: "application/epub+zip", size_bytes: SIZE, position: 0, page_count: null }] }) } }))
        .on("GET", /\/api\/v1\/library\/7\/reader$/, () => readerFor(ACCOUNT));
      renderOffline(server, store, "details", "/preview/library/7");
      const save = await screen.findByRole("button", { name: "Save for offline reading" });
      await act(async () => save.click());
      expect(await screen.findByText(/Your session or the signed-in account changed/)).toBeTruthy();
      expect(store.record).toBeNull();
      expect(browser.fetched).toEqual([]);
      expect(store.saved.size).toBe(0);
    } finally {
      browser.restore();
    }
  });
});

describe("offline lifecycle regressions", () => {
  test("a server that switched offline off is honoured even when it cannot be reached", async () => {
    const store = storeFor("5");
    renderOffline(unreachable(), store, "downloads", "/preview/library/downloads", null);
    await screen.findByRole("heading", { name: "Shelfarr is unavailable here" });
    await waitFor(() => expect(store.record).toBeNull());
    expect(screen.queryByText(/Saved Book/)).toBeNull();
  });

  test("any definitive refusal of the account forgets it, so a later outage cannot reopen saved books", async () => {
    for (const status of [401, 403, 404, 422]) {
      const store = storeFor("5");
      const view = renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => error(status, "refused")), store);
      await waitFor(() => expect(store.record).toBeNull());
      view.unmount();
    }
    const kept = storeFor("5");
    const view = renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => error(500, "internal_error")), kept);
    await screen.findByRole("heading", { name: "Shelfarr is unavailable here" });
    expect(kept.record?.account).toBe("5");
    view.unmount();
  });

  test("a slow reconnection answer for the old account cannot restore it after a newer answer signed out", async () => {
    let release: (value: unknown) => void = () => undefined;
    const answers: (() => unknown)[] = [
      () => {
        throw new TypeError("Failed to fetch");
      },
      () => new Promise((resolve) => (release = resolve)),
      () => ({ body: signedOut() }),
    ];
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => (answers.shift() ?? (() => ({ body: signedOut() })))() as { body: unknown });
    const store = storeFor("5");
    renderOffline(server, store);
    await screen.findByRole("heading", { name: "Member's Saved Book" });
    await act(async () => {
      window.dispatchEvent(new Event("online"));
      await new Promise((resolve) => setTimeout(resolve, 10));
      window.dispatchEvent(new Event("online"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    expect(store.record).toBeNull();
    await act(async () => {
      release({ body: { ...signedIn("5"), offline_expires_in: 3600 } });
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    expect(store.record).toBeNull();
    expect(screen.queryByText(/Saved Book/)).toBeNull();
  });

  test("offline access ends at the confirmed boundary while the page stays open, and the record is removed", async () => {
    const store = storeFor("5", Date.now() - 30 * DAY + 80);
    renderOffline(unreachable(), store);
    await screen.findByRole("heading", { name: "Member's Saved Book" });
    expect(await screen.findByRole("heading", { name: "Offline access ended" }, { timeout: 2000 })).toBeTruthy();
    expect(screen.queryByText(/Saved Book/)).toBeNull();
    expect(store.record).toBeNull();
  });

  test("a failed removal says so instead of claiming success", async () => {
    const store = storeFor("5");
    store.failRemove = new DOMException("disk", "UnknownError");
    renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: { ...signedIn("5"), offline_expires_in: 3600 } })), store);
    const item = (await screen.findByRole("heading", { name: "Member's Saved Book" })).closest("li") as HTMLElement;
    await act(async () => within(item).getByRole("button", { name: "Remove Member's Saved Book" }).click());
    await act(async () => within(item).getByRole("button", { name: "Remove" }).click());
    expect(await screen.findByText("This browser couldn't remove “Member's Saved Book”. Reload the page and try again.")).toBeTruthy();
    expect(screen.queryByText(/^Removed/)).toBeNull();
    expect(store.saved.has("5|7")).toBe(true);
  });
});

describe("the online reader with a saved copy", () => {
  test("shows the saved copy's state in its header and remembers the account's newer place for offline opening", async () => {
    const store = storeFor("5");
    const server = new FakeServer()
      .on("GET", /\/auth\/bootstrap$/, () => ({ body: { ...signedIn("5"), offline_expires_in: 3600 } }))
      .on("GET", /\/api\/v1\/session$/, () => ({ body: { account: ACCOUNT } }))
      .on("GET", /\/api\/v1\/library\/7\/reader$/, () => ({ body: { account: "5", publication: readerPublication({ progress: serverProgress({ version: 4 }) }) } }));
    const network = globalThis.fetch;
    globalThis.fetch = (async () => {
      throw new TypeError("no network in unit tests");
    }) as unknown as typeof fetch;
    try {
      resetFirstPage();
      window.history.replaceState(null, "", "/preview/library/7/read");
      render(<GoApp boot={{ ...goBoot("reader"), reader_engine: "/preview/assets/reader-engine.0123456789abcdef.js", offline: OFFLINE }} fetcher={server.fetcher} store={store} />);
      const header = (await screen.findByRole("heading", { level: 1, name: "Saved Book" })).closest("header") as HTMLElement;
      expect(await within(header).findByText(/Saved on this device on/)).toBeTruthy();
      expect(within(header).getByRole("button", { name: "Remove saved copy" })).toBeTruthy();
      await waitFor(() => expect(store.saved.get("5|7")?.accountPlace?.version).toBe(4));
      expect(store.saved.get("5|7")?.accountPlace?.observedAt).toBe(serverProgress().observed_at);
    } finally {
      globalThis.fetch = network;
    }
  });
});

function withRegisteredWorker(caches: object = { keys: async () => [] }) {
  const targets: [object, string][] = [[window, "isSecureContext"], [navigator, "serviceWorker"], [globalThis, "caches"], [globalThis, "indexedDB"]];
  const saved = targets.map(([target, key]) => Object.getOwnPropertyDescriptor(target, key));
  const scope = new URL(OFFLINE.scope, window.location.href).href;
  const registration = { scope, active: { scriptURL: new URL(OFFLINE.worker, window.location.href).href }, unregister: async () => true };
  const values = [true, { getRegistration: async () => registration, register: async () => registration }, caches, {}];
  targets.forEach(([target, key], index) => Object.defineProperty(target, key, { value: values[index], configurable: true }));
  return () =>
    targets.forEach(([target, key], index) => {
      const previous = saved[index];
      if (previous) Object.defineProperty(target, key, previous);
      else Reflect.deleteProperty(target, key);
    });
}

function later<T>() {
  let resolve: (value: T) => void = () => undefined;
  const promise = new Promise<T>((done) => (resolve = done));
  return { promise, resolve };
}

describe("second review regressions", () => {
  test("two pages loading at once for different accounts never leave either account usable offline", async () => {
    const restore = withRegisteredWorker();
    try {
      const store = storeFor("5");
      const first = later<unknown>();
      const second = later<unknown>();
      const oldTab = renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => first.promise as never), store);
      const newTab = renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => second.promise as never), store);
      await act(async () => {
        first.resolve({ body: { ...signedIn("5"), offline_expires_in: 3600 } });
        await new Promise((resolve) => setTimeout(resolve, 20));
      });
      await act(async () => {
        second.resolve({ body: { ...signedIn("4"), offline_expires_in: 3600 } });
        await new Promise((resolve) => setTimeout(resolve, 20));
      });
      expect(store.record?.account ?? null).not.toBe("5");
      oldTab.unmount();
      newTab.unmount();
    } finally {
      restore();
    }
  });

  test("a slow signed-out answer cannot erase an account another tab confirmed meanwhile", async () => {
    const answer = later<unknown>();
    let calls = 0;
    const store = storeFor("5");
    renderOffline(
      new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
        calls += 1;
        if (calls === 1) throw new TypeError("Failed to fetch");
        return answer.promise as never;
      }),
      store,
    );
    await screen.findByRole("heading", { name: "Member's Saved Book" });
    await act(async () => {
      window.dispatchEvent(new Event("online"));
      await new Promise((resolve) => setTimeout(resolve, 10));
    });
    expect(await store.confirm({ account: "4", confirmedAt: Date.now(), validForMs: DAY })).toBe(true);
    await act(async () => {
      answer.resolve({ body: signedOut() });
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    expect(store.record?.account).toBe("4");
    expect(await screen.findByRole("heading", { name: "The signed-in account changed" })).toBeTruthy();
  });

  test("a slow answer is dated from when it was asked, so its window never outlives the server's", async () => {
    const answer = later<unknown>();
    let calls = 0;
    const store = storeFor("5", Date.now() - DAY);
    renderOffline(
      new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
        calls += 1;
        if (calls === 1) throw new TypeError("Failed to fetch");
        return answer.promise as never;
      }),
      store,
    );
    await screen.findByRole("heading", { name: "Member's Saved Book" });
    const asked = Date.now();
    await act(async () => {
      window.dispatchEvent(new Event("online"));
      await new Promise((resolve) => setTimeout(resolve, 60));
    });
    await act(async () => {
      answer.resolve({ body: { ...signedIn("5"), offline_expires_in: 5 } });
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    await screen.findByRole("button", { name: "Continue online" });
    expect(store.record!.confirmedAt).toBeLessThan(asked + 60);
    expect(store.record!.confirmedAt + store.record!.validForMs).toBeLessThan(asked + 60 + 5000);
  });

  test("a refusal answered after another tab's renewal still ends offline access when it was asked later", async () => {
    const refusal = later<unknown>();
    const store = storeFor("5", Date.now() - DAY);
    renderOffline(new FakeServer().on("GET", /\/auth\/bootstrap$/, () => refusal.promise as never), store);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(await store.confirm({ account: "5", confirmedAt: Date.now() - 1_000, validForMs: DAY })).toBe(true);
    await act(async () => {
      refusal.resolve(error(403, "forbidden"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    expect(store.record).toBeNull();
    expect(screen.queryByText(/Saved Book/)).toBeNull();
  });

  test("a failure while removing the old worker's caches still forgets the account", async () => {
    const restore = withRegisteredWorker({
      keys: async () => {
        throw new DOMException("cache storage failed", "UnknownError");
      },
    });
    try {
      const store = storeFor("5");
      renderOffline(unreachable(), store, "downloads", "/preview/library/downloads", null);
      await screen.findByRole("heading", { name: "Shelfarr is unavailable here" });
      await waitFor(() => expect(store.record).toBeNull());
    } finally {
      restore();
    }
  });

  test("reconnecting does not reopen the saved copy a reader is showing", async () => {
    const network = globalThis.fetch;
    globalThis.fetch = (async () => {
      throw new TypeError("no network in unit tests");
    }) as unknown as typeof fetch;
    let connected = false;
    const store = storeFor("5");
    store.files.set("5|7", { assetId: EPUB_ID, blob: new Blob([epubBytes()]) });
    try {
      resetFirstPage();
      window.history.replaceState(null, "", "/preview/library/7/read");
      render(
        <GoApp
          boot={{ ...goBoot("reader"), reader_engine: "/preview/assets/reader-engine.0123456789abcdef.js", offline: OFFLINE }}
          fetcher={
            new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
              if (!connected) throw new TypeError("Failed to fetch");
              return { body: { ...signedIn("5"), offline_expires_in: 3600 } };
            }).fetcher
          }
          store={store}
        />,
      );
      await screen.findByRole("heading", { level: 1, name: "Member's Saved Book" });
      const opened = store.opens;
      connected = true;
      await act(async () => {
        window.dispatchEvent(new Event("online"));
        await new Promise((resolve) => setTimeout(resolve, 30));
      });
      await screen.findByRole("button", { name: "Continue online" });
      expect(store.opens).toBe(opened);
    } finally {
      globalThis.fetch = network;
    }
  });
});

describe("sending offline places automatically", () => {
  const OFFLINE_AT = "2026-11-20T11:00:00.000Z";
  const place = { href: "OEBPS/two.xhtml", type: "application/xhtml+xml", locations: { cfi: "epubcfi(/6/4!/4/2/1:0)", progression: 0.5, totalProgression: 0.75 } };

  function pendingStore(account = "5") {
    const store = storeFor(account);
    const book = store.saved.get("5|7")!;
    store.saved.set("5|7", { ...book, devicePlace: { asset_id: EPUB_ID, locator: place, observedAt: OFFLINE_AT, recordedAt: Date.now() - 1000, upload: { state: "pending", request: null, rebases: 0 } } });
    return store;
  }

  function progressServer(bootstrap: () => unknown) {
    return new FakeServer()
      .on("GET", /\/auth\/bootstrap$/, bootstrap as never)
      .on("GET", /\/api\/v1\/session$/, () => ({ body: { account: ACCOUNT } }))
      .on("PUT", /\/api\/v1\/library\/7\/progress$/, (request) => ({
        body: { account: "5", progress: { ...(request.body as object), position_seconds: null, version: 1, updated_at: "2026-11-20T12:00:00.000Z" } },
      }));
  }

  test("a place reached offline is sent as soon as the server answers again, with no click and its own activity time", async () => {
    let reachable = false;
    const server = progressServer(() => {
      if (!reachable) throw new TypeError("Failed to fetch");
      return { body: { ...signedIn("5", "fresh-token"), offline_expires_in: 3600 } };
    });
    const store = pendingStore();
    renderOffline(server, store);
    await screen.findByRole("heading", { name: "Member's Saved Book" });
    expect(server.called("PUT", /progress$/)).toEqual([]);
    reachable = true;
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    await waitFor(() => expect(server.called("PUT", /progress$/)).toHaveLength(1));
    const sent = server.called("PUT", /progress$/)[0]!;
    expect(sent.body).toEqual({ asset_id: EPUB_ID, locator: place, observed_at: OFFLINE_AT, expected_version: 0, client_mutation_id: expect.any(String) });
    expect(sent.headers["x-csrf-token"]).toBe("fresh-token");
    expect(sent.headers["x-shelfarr-account"]).toBe("5");
    await waitFor(() => expect(store.saved.get("5|7")?.devicePlace?.upload).toEqual({ state: "synced", version: 1 }));
  });

  test("a place left waiting is sent when the app next opens online, and nothing is sent when nothing waits", async () => {
    const store = pendingStore();
    const server = progressServer(() => ({ body: { ...signedIn("5"), offline_expires_in: 3600 } }));
    const restore = withRegisteredWorker();
    try {
      const view = renderOffline(server, store, "library", "/preview/library");
      await waitFor(() => expect(server.called("PUT", /progress$/)).toHaveLength(1));
      expect((server.called("PUT", /progress$/)[0]!.body as { observed_at: string }).observed_at).toBe(OFFLINE_AT);
      view.unmount();
      const quiet = progressServer(() => ({ body: { ...signedIn("5"), offline_expires_in: 3600 } }));
      renderOffline(quiet, store, "library", "/preview/library");
      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(quiet.called("PUT", /progress$/)).toEqual([]);
      expect(quiet.called("GET", /\/auth\/bootstrap$/)).toHaveLength(1);
    } finally {
      restore();
    }
  });

  test("nothing is sent when the server now answers for another account or signed out", async () => {
    for (const answer of [{ ...signedIn("4"), offline_expires_in: 3600 }, signedOut()]) {
      let reachable = false;
      const server = progressServer(() => {
        if (!reachable) throw new TypeError("Failed to fetch");
        return { body: answer };
      });
      const store = pendingStore();
      const view = renderOffline(server, store);
      await screen.findByRole("heading", { name: "Member's Saved Book" });
      reachable = true;
      await act(async () => {
        window.dispatchEvent(new Event("online"));
        await new Promise((resolve) => setTimeout(resolve, 50));
      });
      expect(server.called("PUT", /progress$/)).toEqual([]);
      expect(store.saved.get("5|7")?.devicePlace?.upload?.state).toBe("pending");
      view.unmount();
    }
  });
});
