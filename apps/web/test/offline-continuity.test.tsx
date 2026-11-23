import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act, render, screen, waitFor } from "@testing-library/react";
import { IDBFactory } from "fake-indexeddb";
import { Blob as NativeBlob } from "node:buffer";
import { resetFirstPage } from "../src/components/PageHeading";
import { bootstrapSchema, goBootSchema, type GoBoot } from "../src/contract";
import { GoApp } from "../src/go/GoApp";
import { confirmationFrom } from "../src/offline/context";
import type { ConfirmedAccount, SavedBook } from "../src/offline/model";
import { reconfirmOnMarkerChange } from "../src/offline/online";
import { cookieValue, IndexedDbOfflineStore, offlineStoreFor } from "../src/offline/store";
import { AuthClient } from "../src/go/auth";
import { FakeServer } from "./helpers";
import { signedIn, signedOut } from "./go-helpers";
import { DAY, EPUB_ID, epubBytes, savedBook } from "./offline-helpers";

const NAME = "shelfarr_offline_0123456789abcdef";
const MOUNT = "/preview";
const API = `${MOUNT}/api/v1`;
const OFFLINE = { worker: `${MOUNT}/offline-worker.js`, scope: `${MOUNT}/library/`, downloads: `${MOUNT}/library/downloads`, continuity_cookie: NAME };
const PLACE = { href: "OEBPS/two.xhtml", type: "application/xhtml+xml", locations: { cfi: "epubcfi(/6/4!/4/2/1:0)", progression: 0.5, totalProgression: 0.75 } };
const OFFLINE_AT = "2026-11-20T11:00:00.000Z";

function setMarker(value: string | null) {
  document.cookie = value === null ? `${NAME}=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT` : `${NAME}=${value}; path=/`;
}
let previousFactory: IDBFactory | undefined;
let previousBlob: typeof Blob;
const restores: (() => void)[] = [];

beforeEach(() => {
  setMarker(null);
  previousFactory = globalThis.indexedDB as IDBFactory | undefined;
  previousBlob = globalThis.Blob;
  globalThis.indexedDB = new IDBFactory();
  globalThis.Blob = NativeBlob as unknown as typeof Blob;
});

afterEach(() => {
  for (const restore of restores.splice(0)) restore();
  globalThis.Blob = previousBlob;
  if (previousFactory) globalThis.indexedDB = previousFactory;
  else Reflect.deleteProperty(globalThis, "indexedDB");
});

const continuity = () => cookieValue(document.cookie, NAME);

function confirmed(account: string, continuityValue: string | undefined, confirmedAt = Date.now() - 1000): ConfirmedAccount {
  return { account, confirmedAt, validForMs: 30 * DAY, ...(continuityValue === undefined ? {} : { continuity: continuityValue }) };
}

async function seed(store: IndexedDbOfflineStore, book: SavedBook, record: ConfirmedAccount) {
  await store.prepare();
  expect(await store.confirm(record)).toBe(true);
  await store.begin({ key: book.key, account: book.account, id: book.id, title: book.title, assetId: book.asset.id, token: "seed", startedAt: 1, failure: null });
  expect(await store.commit(book, new Blob([epubBytes()]), "seed", Date.now())).toBe("saved");
}

function withRegisteredWorker() {
  const targets: [object, string][] = [[window, "isSecureContext"], [globalThis, "isSecureContext"], [navigator, "serviceWorker"], [globalThis, "caches"]];
  const saved = targets.map(([target, key]) => Object.getOwnPropertyDescriptor(target, key));
  const registration = { scope: new URL(OFFLINE.scope, window.location.href).href, active: { scriptURL: new URL(OFFLINE.worker, window.location.href).href }, unregister: async () => true };
  const values = [true, true, { getRegistration: async () => registration, register: async () => registration }, { keys: async () => [] }];
  targets.forEach(([target, key], index) => Object.defineProperty(target, key, { value: values[index], configurable: true }));
  restores.push(() =>
    targets.forEach(([target, key], index) => {
      const previous = saved[index];
      if (previous) Object.defineProperty(target, key, previous);
      else Reflect.deleteProperty(target, key);
    }),
  );
}

function railsBoot(view: GoBoot["view"]): GoBoot {
  return { version: 1, runtime: "rails", view, mount: MOUNT, api: API, reader_formats: ["cbz", "epub", "pdf"], offline: OFFLINE, classic_downloads: "/read/downloads", reader_engine: "/assets/consumer_reader_engine-0123abcd.js" };
}

function unreachable(): FakeServer {
  return new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
    throw new TypeError("Failed to fetch");
  });
}

function renderApp(server: FakeServer, store: IndexedDbOfflineStore, view: GoBoot["view"] = "downloads", url = `${MOUNT}/library/downloads`) {
  resetFirstPage();
  window.history.replaceState(null, "", url);
  return render(<GoApp boot={railsBoot(view)} fetcher={server.fetcher} store={store} />);
}

function countingOpens(store: IndexedDbOfflineStore): { opens: number } {
  const counter = { opens: 0 };
  const open = store.open.bind(store);
  store.open = (account, id) => {
    counter.opens += 1;
    return open(account, id);
  };
  return counter;
}

describe("the Rails session's offline marker", () => {
  test("is read by exact name from the page's cookies", () => {
    expect(cookieValue(`other=1; ${NAME}=abc; ${NAME}x=nope`, NAME)).toBe("abc");
    expect(cookieValue(`${NAME}x=nope; x${NAME}=nope`, NAME)).toBeNull();
    expect(cookieValue(`${NAME}=`, NAME)).toBeNull();
    expect(cookieValue("", NAME)).toBeNull();
  });

  test("the contract carries the marker's cookie name in the boot and the session's marker in the bootstrap", () => {
    expect(goBootSchema.parse(railsBoot("downloads")).offline?.continuity_cookie).toBe(NAME);
    expect(goBootSchema.safeParse({ ...railsBoot("downloads"), offline: { ...OFFLINE, continuity_cookie: "bad name;" } }).success).toBe(false);
    const answer = bootstrapSchema.parse({ ...signedIn("5"), offline_expires_in: 60, offline_continuity: "m1" });
    expect(answer.authenticated && confirmationFrom(answer, 10)).toEqual({ account: "5", confirmedAt: 10, validForMs: 60_000, continuity: "m1" });
    expect(confirmationFrom({ account: "5", offline_expires_in: 60 }, 10)).toEqual({ account: "5", confirmedAt: 10, validForMs: 60_000 });
  });

  test("a confirmation stays usable only while the browser keeps the marker it was confirmed under", async () => {
    setMarker("mA");
    const store = new IndexedDbOfflineStore("continuity-a", continuity);
    await seed(store, savedBook({ title: "Account A's Book" }), confirmed("5", "mA"));
    expect((await store.accountState()).record?.account).toBe("5");
    expect(await store.touch("5", Date.now())).toBe(true);

    setMarker("signedOut");
    expect((await store.accountState()).record).toBeNull();
    expect(await store.touch("5", Date.now())).toBe(false);
    expect(await store.updateBook("5", "7", (book) => ({ ...book, title: "Changed" }), Date.now())).toBe("refused");
    await store.begin({ key: "5|7", account: "5", id: "7", title: "Again", assetId: EPUB_ID, token: "again", startedAt: 2, failure: null });
    expect(await store.commit(savedBook(), new Blob([epubBytes()]), "again", Date.now())).toBe("account");
    expect(await store.books("5")).toEqual([]);
    expect((await new IndexedDbOfflineStore("continuity-a").books("5")).map((book) => book.title)).toEqual(["Account A's Book"]);

    setMarker("mA2");
    expect(await store.confirm(confirmed("5", "mA2", Date.now()))).toBe(true);
    expect((await store.accountState()).record?.continuity).toBe("mA2");
    expect((await store.open("5", "7"))?.book.title).toBe("Account A's Book");
  });

  test("an answer that carries an earlier marker is refused and changes nothing, even if it arrives last", async () => {
    setMarker("mB");
    const store = new IndexedDbOfflineStore("continuity-stale", continuity);
    await store.prepare();
    expect(await store.confirm(confirmed("4", "mB", Date.now() - 500))).toBe(true);
    expect(await store.confirm(confirmed("5", "mA", Date.now()))).toBe(false);
    expect((await store.accountState()).record).toMatchObject({ account: "4", continuity: "mB" });
  });

  test("the marker is compared when storage answers, so a sign-out that lands while storage is slow still hides the books", async () => {
    setMarker("mA");
    const store = new IndexedDbOfflineStore("continuity-slow", continuity);
    await seed(store, savedBook(), confirmed("5", "mA"));
    const reading = store.accountState();
    setMarker("signedOut");
    expect((await reading).record).toBeNull();
  });

  test("an answer that carries no marker is refused once the browser has one, so a slow first answer for A cannot outlast B's sign-in", async () => {
    const store = new IndexedDbOfflineStore("continuity-markerless", continuity);
    await seed(store, savedBook({ title: "Account A's Book" }), confirmed("5", undefined));
    setMarker("mB");
    expect(await store.confirm(confirmed("5", undefined, Date.now()))).toBe(false);
    expect((await store.accountState()).record).toBeNull();
    expect(await store.books("5")).toEqual([]);
  });

  test("saved books, files and unfinished saves already being read when the marker changes are never handed back", async () => {
    setMarker("mA");
    const store = new IndexedDbOfflineStore("continuity-reads", continuity);
    await seed(store, savedBook({ title: "Account A's Book" }), confirmed("5", "mA"));
    await store.begin({ key: "5|8", account: "5", id: "8", title: "Unfinished", assetId: EPUB_ID, token: "t", startedAt: 1, failure: null });
    expect((await store.books("5")).map((book) => book.title)).toEqual(["Account A's Book"]);

    const reads = [store.books("5"), store.book("5", "7"), store.open("5", "7"), store.attempts("5")] as const;
    setMarker("signedOut");
    expect(await Promise.all(reads)).toEqual([[], null, null, []]);

    setMarker("mA");
    expect((await store.open("5", "7"))?.book.title).toBe("Account A's Book");
    expect(await store.books("4")).toEqual([]);
  });

  test("a refusal asked before a newer confirmation never discards it, even when a late answer changed the marker", async () => {
    setMarker("mB");
    const store = new IndexedDbOfflineStore("continuity-late-refusal", continuity);
    await seed(store, savedBook({ key: "4|7", account: "4", title: "Account B's Book" }), confirmed("4", "mB", Date.now()));
    setMarker("fromALateRefusal");
    expect(await store.release(Date.now() - 60_000)).toBe(false);
    expect((await new IndexedDbOfflineStore("continuity-late-refusal").accountState()).record).toMatchObject({ account: "4", continuity: "mB" });
    setMarker("mB");
    expect((await store.books("4")).map((book) => book.title)).toEqual(["Account B's Book"]);
  });

  test("a copy confirmed before the marker existed stays readable only while the browser has no marker", async () => {
    const store = new IndexedDbOfflineStore("continuity-legacy", continuity);
    await seed(store, savedBook(), confirmed("5", undefined));
    expect((await store.accountState()).record?.account).toBe("5");
    setMarker("signedOut");
    expect((await store.accountState()).record).toBeNull();
  });

  test("without a marker name, as on the Go runtime, markers are ignored", async () => {
    setMarker("anything");
    const store = new IndexedDbOfflineStore("continuity-go");
    await seed(store, savedBook(), confirmed("5", "other"));
    expect((await store.accountState()).record?.account).toBe("5");
  });

  test("the store a page opens reads the marker from document.cookie", async () => {
    const name = "shelfarr_offline_feedfacefeedface";
    const store = offlineStoreFor("/continuity-cookie/preview", name);
    document.cookie = `${name}=cookieA; path=/`;
    expect(await store.confirm(confirmed("5", "cookieA"))).toBe(true);
    expect((await store.accountState()).record?.account).toBe("5");
    document.cookie = `${name}=cookieB; path=/`;
    expect((await store.accountState()).record).toBeNull();
    document.cookie = `${name}=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT`;
  });
});

describe("online pages when the marker changes", () => {
  function withCookieStore(): EventTarget {
    const cookies = new EventTarget();
    Object.defineProperty(globalThis, "cookieStore", { value: cookies, configurable: true });
    restores.push(() => Reflect.deleteProperty(globalThis, "cookieStore"));
    return cookies;
  }

  function announce(cookies: EventTarget, value: string) {
    setMarker(value);
    cookies.dispatchEvent(Object.assign(new Event("change"), { changed: [{ name: NAME, value }], deleted: [] }));
  }

  test("a page still signed in confirms its account again under the new marker", async () => {
    const cookies = withCookieStore();
    withRegisteredWorker();
    setMarker("mA");
    const store = new IndexedDbOfflineStore("continuity-reconfirm", continuity);
    await seed(store, savedBook({ title: "Account A's Book" }), confirmed("5", "mA"));
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: { ...signedIn("5"), offline_expires_in: 3600, offline_continuity: "fromALateRefusal" } }));
    const stop = reconfirmOnMarkerChange(OFFLINE, new AuthClient(API, server.fetcher), store);
    restores.push(stop);
    announce(cookies, "fromALateRefusal");
    await waitFor(async () => expect((await store.accountState()).record).toMatchObject({ account: "5", continuity: "fromALateRefusal" }));
    expect((await store.books("5")).map((book) => book.title)).toEqual(["Account A's Book"]);
    expect(server.called("GET", /\/auth\/bootstrap$/)).toHaveLength(1);
  });

  test("a signed-out answer, which replaces the marker itself, ends the listening instead of asking again", async () => {
    const cookies = withCookieStore();
    setMarker("mA");
    const store = new IndexedDbOfflineStore("continuity-no-loop", continuity);
    await seed(store, savedBook(), confirmed("5", "mA"));
    let rotations = 0;
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
      rotations += 1;
      const value = `rotated${rotations}`;
      setTimeout(() => announce(cookies, value), 10);
      return { body: signedOut() };
    });
    restores.push(reconfirmOnMarkerChange(OFFLINE, new AuthClient(API, server.fetcher), store));
    announce(cookies, "mAfterSignOut");
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(server.called("GET", /\/auth\/bootstrap$/)).toHaveLength(1);
    expect((await new IndexedDbOfflineStore("continuity-no-loop").accountState()).record).toBeNull();
  });
});

describe("going offline straight after the Rails session changed", () => {
  async function accountAWithSavedBook() {
    setMarker("mA");
    const store = new IndexedDbOfflineStore("continuity-flow", continuity);
    const book = savedBook({ title: "Account A's Private Book", devicePlace: { asset_id: EPUB_ID, locator: PLACE, observedAt: OFFLINE_AT, recordedAt: Date.now() - 1000, upload: { state: "pending", request: null, rebases: 0 } } });
    await seed(store, book, confirmed("5", "mA"));
    return store;
  }

  test("with no page script having run after sign-out or after signing in as B, neither Downloads nor the reader shows A's books", async () => {
    const store = await accountAWithSavedBook();
    const counter = countingOpens(store);
    setMarker("mAfterSignOut");
    const signedOutView = renderApp(unreachable(), store);
    expect(await screen.findByRole("heading", { name: "Shelfarr can't be reached" })).toBeTruthy();
    expect(screen.queryByText(/Account A's Private Book/)).toBeNull();
    signedOutView.unmount();

    setMarker("mB");
    const readerView = renderApp(unreachable(), store, "reader", `${MOUNT}/library/7/read`);
    expect(await screen.findByRole("heading", { name: "Shelfarr can't be reached" })).toBeTruthy();
    expect(screen.queryByText(/Account A's Private Book/)).toBeNull();
    readerView.unmount();
    expect(counter.opens).toBe(0);
    expect((await new IndexedDbOfflineStore("continuity-flow").books("5")).map((book) => book.title)).toEqual(["Account A's Private Book"]);
  });

  test("a Downloads listing still being gathered when the marker changes never shows A's books", async () => {
    const store = await accountAWithSavedBook();
    let persisted: (value: boolean) => void = () => undefined;
    const storage = Object.getOwnPropertyDescriptor(navigator, "storage");
    let asked = 0;
    const held = new Promise<boolean>((resolve) => (persisted = resolve));
    Object.defineProperty(navigator, "storage", { value: { persisted: () => (asked++ === 0 ? held : Promise.resolve(true)) }, configurable: true });
    restores.push(() => (storage ? Object.defineProperty(navigator, "storage", storage) : Reflect.deleteProperty(navigator, "storage")));
    const reading = store.books.bind(store);
    let firstRead: () => void = () => undefined;
    const readOnce = new Promise<void>((resolve) => (firstRead = resolve));
    store.books = async (account) => {
      const books = await reading(account);
      firstRead();
      return books;
    };
    renderApp(unreachable(), store);
    await readOnce;
    setMarker("mAfterSignOut");
    await act(async () => {
      persisted(true);
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(screen.queryByText(/Account A's Private Book/)).toBeNull();
  });

  test("an open offline page hides A's books as soon as the browser reports the marker changed", async () => {
    const store = await accountAWithSavedBook();
    const cookies = new EventTarget();
    Object.defineProperty(globalThis, "cookieStore", { value: cookies, configurable: true });
    restores.push(() => Reflect.deleteProperty(globalThis, "cookieStore"));
    renderApp(unreachable(), store);
    expect(await screen.findByRole("heading", { name: "Account A's Private Book" })).toBeTruthy();
    setMarker("mB");
    await act(async () => {
      cookies.dispatchEvent(Object.assign(new Event("change"), { changed: [{ name: NAME, value: "mB" }], deleted: [] }));
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(await screen.findByRole("heading", { name: "Offline access ended" })).toBeTruthy();
    expect(screen.queryByText(/Account A's Private Book/)).toBeNull();
  });

  test("while the marker is unchanged, the same account still reads its saved books offline", async () => {
    const store = await accountAWithSavedBook();
    renderApp(unreachable(), store);
    expect(await screen.findByRole("heading", { name: "Account A's Private Book" })).toBeTruthy();
    expect(screen.getByText(/You're offline\./)).toBeTruthy();
  });

  test("when A signs in again and reconnects, A's copies come back and the waiting place is sent exactly once", async () => {
    const store = await accountAWithSavedBook();
    withRegisteredWorker();
    setMarker("mA2");
    const server = new FakeServer()
      .on("GET", /\/auth\/bootstrap$/, () => ({ body: { ...signedIn("5", "fresh-token"), offline_expires_in: 3600, offline_continuity: "mA2" } }))
      .on("GET", /\/api\/v1\/session$/, () => ({ body: { account: "5" } }))
      .on("PUT", /\/api\/v1\/library\/7\/progress$/, (request) => ({
        body: { account: "5", progress: { ...(request.body as object), position_seconds: null, version: 1, updated_at: "2026-11-20T12:00:00.000Z" } },
      }));
    const view = renderApp(server, store);
    expect(await screen.findByRole("heading", { name: "Account A's Private Book" })).toBeTruthy();
    await waitFor(() => expect(server.called("PUT", /progress$/)).toHaveLength(1));
    expect(server.called("PUT", /progress$/)[0]!.body).toMatchObject({ asset_id: EPUB_ID, locator: PLACE, observed_at: OFFLINE_AT, expected_version: 0 });
    await waitFor(async () => expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "synced", version: 1 }));
    expect((await store.accountState()).record).toMatchObject({ account: "5", continuity: "mA2" });
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(server.called("PUT", /progress$/)).toHaveLength(1);
    view.unmount();

    const offlineAgain = renderApp(unreachable(), store);
    expect(await screen.findByRole("heading", { name: "Account A's Private Book" })).toBeTruthy();
    offlineAgain.unmount();
  });

  test("a bootstrap that was asked before the sign-out and answers after it cannot make A's books readable", async () => {
    const store = await accountAWithSavedBook();
    withRegisteredWorker();
    let answer: (value: unknown) => void = () => undefined;
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => new Promise((resolve) => (answer = resolve)) as never);
    const view = renderApp(server, store);
    await waitFor(() => expect(server.called("GET", /\/auth\/bootstrap$/)).toHaveLength(1));
    setMarker("mAfterSignOut");
    await act(async () => {
      answer({ body: { ...signedIn("5"), offline_expires_in: 3600, offline_continuity: "mA" } });
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    view.unmount();
    expect((await store.accountState()).record).toBeNull();
    renderApp(unreachable(), store);
    expect(await screen.findByRole("heading", { name: "Shelfarr can't be reached" })).toBeTruthy();
    expect(screen.queryByText(/Account A's Private Book/)).toBeNull();
  });
});
