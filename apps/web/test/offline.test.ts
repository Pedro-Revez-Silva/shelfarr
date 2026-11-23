import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { IDBFactory } from "fake-indexeddb";
import { Blob as NativeBlob } from "node:buffer";
import { AccountGuard } from "../src/api/account-guard";
import { DevicePlaces } from "../src/offline/devicePlaces";
import {
  ACCOUNT_LIMIT_BYTES,
  BOOK_LIMIT_BYTES,
  CLOCK_TOLERANCE_MS,
  bookKey,
  openingLocator,
  rememberAccountPlace,
  savedEpub,
  usable,
  type ConfirmedAccount,
  type SavedBook,
} from "../src/offline/model";
import { offeredDevicePlace } from "../src/offline/remembered";
import { completeZip, saveCopy, SaveFailure, saveLockName, type SaveInputs } from "../src/offline/save";
import { DATABASE_NAME, IndexedDbOfflineStore, RAILS_DATABASE_NAME, databaseNameFor } from "../src/offline/store";
import { previewDatabaseName, releasePreviewAccount } from "../../../app/javascript/web_preview_offline_release.js";
import { WorkerFailure } from "../src/offline/worker";
import { DAY, EPUB_ID, NEWER_ID, SIZE, asset, epubBytes, readerPublication, savedBook, serverProgress } from "./offline-helpers";

const NOW = Date.parse("2026-11-20T12:00:00.000Z");
const OFFLINE = { worker: "/preview/offline-worker.js", scope: "/preview/library/", downloads: "/preview/library/downloads" };
const confirmation = (overrides: Partial<ConfirmedAccount> = {}): ConfirmedAccount => ({ account: "5", confirmedAt: NOW, validForMs: 30 * DAY, ...overrides });
const locator = (cfi: string) => ({ href: "OEBPS/one.xhtml", locations: { cfi } });

let previousFactory: IDBFactory | undefined;
let previousBlob: typeof Blob;
beforeEach(() => {
  previousFactory = globalThis.indexedDB as IDBFactory | undefined;
  previousBlob = globalThis.Blob;
  globalThis.indexedDB = new IDBFactory();
  globalThis.Blob = NativeBlob as unknown as typeof Blob;
});
afterEach(() => {
  globalThis.Blob = previousBlob;
  if (previousFactory) globalThis.indexedDB = previousFactory;
  else Reflect.deleteProperty(globalThis, "indexedDB");
});

async function confirmed(store: IndexedDbOfflineStore, value: ConfirmedAccount = confirmation()): Promise<void> {
  await store.prepare();
  expect(await store.confirm(value)).toBe(true);
}

async function seed(store: IndexedDbOfflineStore, book: SavedBook, bytes = epubBytes(book.asset.size_bytes)): Promise<void> {
  await store.begin({ key: book.key, account: book.account, id: book.id, title: book.title, assetId: book.asset.id, token: "seed", startedAt: 1, failure: null });
  expect(await store.commit(book, new Blob([bytes]), "seed", NOW)).toBe("saved");
}

function respond(body: Uint8Array<ArrayBuffer> | null, init: { status?: number; headers?: Record<string, string> } = {}): Response {
  return new Response(body, { status: init.status ?? 200, headers: init.headers ?? { ETag: `"${EPUB_ID}"`, "Content-Length": String(body?.byteLength ?? 0) } });
}

function chunked(bytes: Uint8Array<ArrayBuffer>, at: number): Response {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(bytes.slice(0, at));
      controller.enqueue(bytes.slice(at));
      controller.close();
    },
  });
  return new Response(stream, { headers: { ETag: `"${EPUB_ID}"`, "Content-Length": String(bytes.byteLength) } });
}

type Answer = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

function inputs(store: IndexedDbOfflineStore, fetcher: Answer, overrides: Partial<SaveInputs> = {}) {
  const fetched: string[] = [];
  const progress: number[] = [];
  const guard = new AccountGuard("5");
  const base: SaveInputs = {
    publication: readerPublication(),
    account: "5",
    confirm: async () => {
      await confirmed(store);
      return confirmation();
    },
    offline: OFFLINE,
    store,
    guard,
    ensureWorker: async () => undefined,
    estimate: async () => ({ quota: 10 * 1024 ** 3, usage: 0 }),
    locks: undefined,
    fetcher: (async (input: RequestInfo | URL, init?: RequestInit) => {
      fetched.push(String(input));
      return fetcher(input, init);
    }) as typeof fetch,
    now: () => NOW,
    onProgress: (received) => progress.push(received),
    ...overrides,
  };
  return { base, fetched, progress, guard };
}

async function failure(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    if (error instanceof SaveFailure) return error.kind;
    throw error;
  }
  throw new Error("the save did not fail");
}

describe("the confirmed account", () => {
  test("is usable only for its own account, inside its window, within the clock tolerance and never before a later moment already seen", () => {
    const record = confirmation();
    expect(usable(record, "5", NOW)).toBe(true);
    expect(usable(record, null, NOW)).toBe(true);
    expect(usable(record, "4", NOW)).toBe(false);
    expect(usable(null, "5", NOW)).toBe(false);
    expect(usable(record, "5", NOW + 30 * DAY - 1)).toBe(true);
    expect(usable(record, "5", NOW + 30 * DAY)).toBe(false);
    expect(usable(record, "5", NOW - CLOCK_TOLERANCE_MS)).toBe(true);
    expect(usable(record, "5", NOW - CLOCK_TOLERANCE_MS - 1)).toBe(false);
    expect(usable(confirmation({ validForMs: 0 }), "5", NOW)).toBe(false);
    const seen = confirmation({ seenAt: NOW + 10 * DAY });
    expect(usable(seen, "5", NOW + DAY)).toBe(false);
    expect(usable(seen, "5", NOW + 10 * DAY)).toBe(true);
  });

  test("an answer clears or replaces only what earlier questions recorded", async () => {
    const store = new IndexedDbOfflineStore();
    await store.prepare();
    expect(await store.confirm(confirmation({ confirmedAt: 100 }))).toBe(true);
    expect(await store.release(150)).toBe(true);
    expect(await store.confirm(confirmation({ confirmedAt: 120 }))).toBe(false);
    expect(await store.confirm(confirmation({ confirmedAt: 200 }))).toBe(true);
    expect(await store.release(150)).toBe(false);
    expect((await store.accountState()).record?.confirmedAt).toBe(200);
    expect(await store.confirm(confirmation({ account: "4", confirmedAt: 180 }))).toBe(false);
    expect(await store.confirm(confirmation({ account: "4", confirmedAt: 220 }))).toBe(true);
    expect((await store.accountState()).record?.account).toBe("4");
  });

  test("forgetting an account clears it against every earlier question, and leaves another account alone", async () => {
    const store = new IndexedDbOfflineStore();
    await confirmed(store, confirmation({ account: "4", confirmedAt: 100 }));
    await store.forget("5", 300);
    expect((await store.accountState()).record?.account).toBe("4");
    await store.forget(undefined, 300);
    expect(await store.accountState()).toEqual({ record: null, clearedAt: 300 });
    expect(await store.confirm(confirmation({ confirmedAt: 250 }))).toBe(false);
    expect(await store.confirm(confirmation({ confirmedAt: 350 }))).toBe(true);
  });

  test("touching renews the latest moment seen, and an expired or clock-rewound record is removed for good", async () => {
    const store = new IndexedDbOfflineStore();
    await confirmed(store);
    expect(await store.touch("5", NOW + 10 * DAY)).toBe(true);
    expect(await store.touch("5", NOW + DAY)).toBe(false);
    expect((await store.accountState()).record).toBeNull();
    expect(await store.confirm(confirmation())).toBe(false);
    await confirmed(store, confirmation({ confirmedAt: NOW + 1 }));
    expect(await store.touch("5", NOW + 1 + 30 * DAY)).toBe(false);
    expect((await store.accountState()).record).toBeNull();
    expect(await store.confirm(confirmation({ confirmedAt: NOW + 1 }))).toBe(false);
  });

  test("reading the account of a browser that never saved creates nothing", async () => {
    const store = new IndexedDbOfflineStore();
    expect(await store.accountState()).toEqual({ record: null, clearedAt: 0 });
    await store.forget();
    expect((await indexedDB.databases()).map((database) => database.name)).toEqual([]);
    await store.prepare();
    expect((await indexedDB.databases()).map((database) => database.name)).toEqual([DATABASE_NAME]);
  });
});

describe("where a saved copy opens", () => {
  const device = { asset_id: EPUB_ID, locator: locator("device"), observedAt: "2026-11-20T11:00:00.000Z", recordedAt: 5_000 };
  const account = { asset_id: EPUB_ID, locator: locator("account"), version: 3, observedAt: "2026-11-20T10:00:00.000Z", learnedAt: 9_000 };

  test("the place with the later activity wins, whenever this browser learned of it", () => {
    expect(openingLocator(savedBook({ devicePlace: device, accountPlace: account }))).toEqual(device.locator);
    const later = { ...account, observedAt: "2026-11-20T11:30:00.000Z", learnedAt: 1_000 };
    const book = savedBook({ devicePlace: device, accountPlace: later });
    expect(openingLocator(book)).toEqual(later.locator);
    expect(book.devicePlace).toEqual(device);
  });

  test("an undated account place falls back to when each place reached this browser", () => {
    expect(openingLocator(savedBook({ devicePlace: device, accountPlace: { ...account, observedAt: null, learnedAt: 4_000 } }))).toEqual(device.locator);
    expect(openingLocator(savedBook({ devicePlace: device, accountPlace: { ...account, observedAt: null, learnedAt: 6_000 } }))).toEqual(account.locator);
  });

  test("a place in another edition is never opened", () => {
    expect(openingLocator(savedBook({ devicePlace: { ...device, asset_id: NEWER_ID }, accountPlace: { ...account, asset_id: NEWER_ID } }))).toBeNull();
    expect(openingLocator(savedBook({ devicePlace: { ...device, asset_id: NEWER_ID }, accountPlace: account }))).toEqual(account.locator);
  });

  test("the account place is replaced only by a newer version and keeps its activity time", () => {
    const book = savedBook({ accountPlace: account });
    expect(rememberAccountPlace(book, serverProgress({ version: 3 }), 9_000)).toBe(book);
    expect(rememberAccountPlace(book, serverProgress({ version: 2 }), 9_000)).toBe(book);
    expect(rememberAccountPlace(book, serverProgress({ version: 4 }), 9_500).accountPlace).toEqual({
      asset_id: EPUB_ID,
      locator: serverProgress().locator!,
      version: 4,
      observedAt: serverProgress().observed_at,
      learnedAt: 9_500,
    });
    expect(rememberAccountPlace(book, serverProgress({ version: 9, locator: null, position_seconds: 3 }), 9_000)).toBe(book);
  });

  test("online, the device place is offered only while its activity is later than the account's and it is a different place", () => {
    const book = savedBook({ devicePlace: device });
    expect(offeredDevicePlace(book, serverProgress({ observed_at: "2026-11-20T10:00:00.000Z" }), NOW)).toEqual(device);
    expect(offeredDevicePlace(book, serverProgress({ observed_at: "2026-11-20T11:30:00.000Z" }), NOW)).toBeNull();
    expect(offeredDevicePlace(book, null, NOW)).toEqual(device);
    expect(offeredDevicePlace(book, serverProgress({ observed_at: "2026-11-20T10:00:00.000Z", locator: device.locator }), NOW)).toBeNull();
    expect(offeredDevicePlace(savedBook({ devicePlace: { ...device, asset_id: NEWER_ID } }), null, NOW)).toBeNull();
  });

  test("the saved EPUB is the one the account's place is in, else the first EPUB", () => {
    const other = asset({ id: NEWER_ID });
    expect(savedEpub(readerPublication({ assets: [asset(), other], progress: serverProgress({ asset_id: NEWER_ID }) }))?.id).toBe(NEWER_ID);
    expect(savedEpub(readerPublication({ assets: [asset(), other] }))?.id).toBe(EPUB_ID);
    expect(savedEpub(readerPublication({ assets: [asset({ format: "pdf" })] }))).toBeNull();
  });
});

describe("the archive check", () => {
  test("accepts a complete ZIP and refuses a header without a matching central directory", async () => {
    expect(await completeZip(new Blob([epubBytes()]))).toBe(true);
    const signatureOnly = new Uint8Array(SIZE);
    signatureOnly.set([0x50, 0x4b, 0x03, 0x04]);
    expect(await completeZip(new Blob([signatureOnly]))).toBe(false);
    const truncated = epubBytes().slice(0, SIZE - 10);
    expect(await completeZip(new Blob([truncated]))).toBe(false);
    const moved = epubBytes();
    new DataView(moved.buffer).setUint32(SIZE - 6, 3, true);
    expect(await completeZip(new Blob([moved]))).toBe(false);
    const forged = new Uint8Array(SIZE);
    const view = new DataView(forged.buffer);
    const end = SIZE - 22;
    view.setUint32(0, 0x04034b50, true);
    view.setUint32(end - 4, 0x02014b50, true);
    view.setUint32(end, 0x06054b50, true);
    view.setUint16(end + 8, 1, true);
    view.setUint16(end + 10, 1, true);
    view.setUint32(end + 12, 4, true);
    view.setUint32(end + 16, end - 4, true);
    expect(await completeZip(new Blob([forged]))).toBe(false);
    const overlong = epubBytes();
    new DataView(overlong.buffer).setUint16(26, 65535, true);
    expect(await completeZip(new Blob([overlong]))).toBe(false);
    const renamed = epubBytes();
    renamed.set(new TextEncoder().encode("OTHER-IN/container.xml"), 30);
    expect(await completeZip(new Blob([renamed]))).toBe(false);
    const notEpub = epubBytes();
    notEpub.set(new TextEncoder().encode("OTHER-IN/container.xml"), SIZE - 22 - 22);
    expect(await completeZip(new Blob([notEpub]))).toBe(false);
  });
});

describe("saving a copy", () => {
  test("stores the verified EPUB and the account's place in one commit and clears the attempt", async () => {
    const store = new IndexedDbOfflineStore();
    const bytes = epubBytes();
    const { base, fetched, progress } = inputs(store, async () => chunked(bytes, 2), { publication: readerPublication({ progress: serverProgress() }) });
    await saveCopy(base);
    expect(fetched).toEqual([asset().url]);
    expect(await store.attempts("5")).toEqual([]);
    const opened = await store.open("5", "7");
    expect(opened?.book).toEqual(
      savedBook({ savedAt: NOW, accountPlace: { asset_id: EPUB_ID, locator: serverProgress().locator!, version: 3, observedAt: serverProgress().observed_at, learnedAt: NOW } }),
    );
    expect(new Uint8Array(await opened!.blob.arrayBuffer())).toEqual(bytes);
    expect(progress.at(-1)).toBe(SIZE);
  });

  test("refuses a book over the reader's limit before anything is fetched, confirmed or recorded", async () => {
    const store = new IndexedDbOfflineStore();
    let confirmations = 0;
    const { base, fetched } = inputs(store, async () => respond(epubBytes()), {
      publication: readerPublication({ assets: [asset({ size_bytes: BOOK_LIMIT_BYTES + 1 })] }),
      confirm: async () => {
        confirmations += 1;
        return confirmation();
      },
    });
    expect(await failure(saveCopy(base))).toBe("too_large");
    expect([fetched, confirmations]).toEqual([[], 0]);
  });

  test("refuses when the account's saved books or the browser's free space would not fit it, and keeps the cap when two saves race", async () => {
    const full = new IndexedDbOfflineStore();
    await confirmed(full);
    await seed(full, savedBook({ key: bookKey("5", "9"), id: "9", asset: { ...savedBook().asset, size_bytes: ACCOUNT_LIMIT_BYTES - 32 } }), epubBytes(SIZE));
    const limited = inputs(full, async () => respond(epubBytes()));
    expect(await failure(saveCopy(limited.base))).toBe("space");
    expect(limited.fetched).toEqual([]);

    const cramped = new IndexedDbOfflineStore();
    const quota = inputs(cramped, async () => respond(epubBytes()), { estimate: async () => ({ quota: 40 * 1024 * 1024, usage: 8 * 1024 * 1024 }) });
    expect(await failure(saveCopy(quota.base))).toBe("space");
    expect(quota.fetched).toEqual([]);

    const racing = new IndexedDbOfflineStore();
    await confirmed(racing);
    await seed(racing, savedBook({ key: bookKey("5", "9"), id: "9", asset: { ...savedBook().asset, size_bytes: ACCOUNT_LIMIT_BYTES - SIZE - 100 } }), epubBytes(SIZE));
    const first = savedBook({ key: bookKey("5", "10"), id: "10" });
    const second = savedBook({ key: bookKey("5", "11"), id: "11" });
    for (const book of [first, second]) await racing.begin({ key: book.key, account: "5", id: book.id, title: book.title, assetId: EPUB_ID, token: "race", startedAt: 7, failure: null });
    expect(await racing.commit(first, new Blob([epubBytes()]), "race", NOW)).toBe("saved");
    expect(await racing.commit(second, new Blob([epubBytes()]), "race", NOW)).toBe("space");
    expect(await racing.open("5", "11")).toBeNull();
  });

  test("keeps the earlier copy and records why when the new edition does not arrive whole and verified", async () => {
    const signatureOnly = new Uint8Array(SIZE);
    signatureOnly.set([0x50, 0x4b, 0x03, 0x04]);
    const cases: [string, () => Promise<Response>][] = [
      ["changed", async () => respond(epubBytes(), { headers: { ETag: `"${NEWER_ID}"`, "Content-Length": String(SIZE) } })],
      ["changed", async () => respond(epubBytes(SIZE - 1), { headers: { ETag: `"${EPUB_ID}"` } })],
      ["changed", async () => respond(epubBytes(SIZE + 1), { headers: { ETag: `"${EPUB_ID}"` } })],
      ["changed", async () => respond(signatureOnly)],
      ["changed", async () => respond(epubBytes(), { headers: { ETag: `"${EPUB_ID}"`, "Content-Length": "60" } })],
      ["missing", async () => respond(null, { status: 404, headers: {} })],
      ["changed", async () => respond(null, { status: 410, headers: {} })],
      ["network", async () => respond(null, { status: 503, headers: {} })],
      ["network", async () => Promise.reject(new TypeError("Failed to fetch"))],
    ];
    for (const [expected, answer] of cases) {
      const store = new IndexedDbOfflineStore();
      await confirmed(store);
      const earlier = savedBook({ asset: { ...savedBook().asset, id: NEWER_ID } });
      await seed(store, earlier);
      const { base } = inputs(store, answer);
      expect(await failure(saveCopy(base))).toBe(expected);
      const opened = await store.open("5", "7");
      expect(opened?.book).toEqual(earlier);
      expect((await store.attempts("5"))[0]?.failure).toBe(expected as never);
      globalThis.indexedDB = new IDBFactory();
    }
  });

  test("a refusal for the session locks the page and stores nothing", async () => {
    for (const code of ["signed_out", "account_changed"] as const) {
      const store = new IndexedDbOfflineStore();
      const { base, guard } = inputs(store, async () => new Response(JSON.stringify({ error: code }), { status: 401, headers: { "content-type": "application/json" } }));
      expect(await failure(saveCopy(base))).toBe("signed_out");
      expect(guard.getState().status).toBe(code);
      expect(await store.open("5", "7")).toBeNull();
      globalThis.indexedDB = new IDBFactory();
    }
  });

  test("a save started in the same millisecond after a removal never revives the removed one", async () => {
    const store = new IndexedDbOfflineStore();
    let releaseFirst: (response: Response) => void = () => undefined;
    const firstRun = inputs(store, () => new Promise((resolve) => (releaseFirst = resolve)));
    const first = saveCopy(firstRun.base).then(() => "saved", (error: unknown) => (error instanceof SaveFailure ? error.kind : "other"));
    while ((await store.attempts("5")).length === 0) await new Promise((resolve) => setTimeout(resolve, 1));
    await store.remove("5", "7");
    const second = inputs(store, async () => respond(null, { status: 503, headers: {} }));
    expect(await failure(saveCopy(second.base))).toBe("network");
    releaseFirst(respond(epubBytes()));
    expect(await first).toBe("removed");
    expect(await store.open("5", "7")).toBeNull();
  });

  test("nothing is committed when the account changed or the copy was removed while the book downloaded", async () => {
    const switched = new IndexedDbOfflineStore();
    const switchedRun = inputs(switched, async () => {
      await switched.forget();
      return respond(epubBytes());
    });
    expect(await failure(saveCopy(switchedRun.base))).toBe("signed_out");
    expect(await switched.open("5", "7")).toBeNull();

    globalThis.indexedDB = new IDBFactory();
    const removed = new IndexedDbOfflineStore();
    const removedRun = inputs(removed, async () => {
      await removed.remove("5", "7");
      return respond(epubBytes());
    });
    expect(await failure(saveCopy(removedRun.base))).toBe("removed");
    expect(await removed.open("5", "7")).toBeNull();

    globalThis.indexedDB = new IDBFactory();
    const locked = new IndexedDbOfflineStore();
    const lockedRun = inputs(locked, async () => {
      lockedRun.guard.lock("account_changed");
      return respond(epubBytes());
    });
    expect(await failure(saveCopy(lockedRun.base))).toBe("signed_out");
    expect(await locked.open("5", "7")).toBeNull();
  });

  test("a confirmation that cannot be renewed, a failed worker, a full disk at commit and a save in another tab store nothing", async () => {
    const stale = new IndexedDbOfflineStore();
    const staleRun = inputs(stale, async () => respond(epubBytes()), {
      confirm: async () => {
        throw new SaveFailure("signed_out");
      },
    });
    expect(await failure(saveCopy(staleRun.base))).toBe("signed_out");
    expect(staleRun.fetched).toEqual([]);

    const other = new IndexedDbOfflineStore();
    const otherRun = inputs(other, async () => respond(epubBytes()), { confirm: async () => confirmation({ account: "4" }) });
    expect(await failure(saveCopy(otherRun.base))).toBe("signed_out");
    expect(otherRun.fetched).toEqual([]);

    const broken = new IndexedDbOfflineStore();
    let confirmations = 0;
    const workerRun = inputs(broken, async () => respond(epubBytes()), {
      ensureWorker: async () => Promise.reject(new WorkerFailure("no")),
      confirm: async () => {
        confirmations += 1;
        return confirmation();
      },
    });
    expect(await failure(saveCopy(workerRun.base))).toBe("worker");
    expect([workerRun.fetched, confirmations]).toEqual([[], 0]);

    const full = new IndexedDbOfflineStore();
    const fullRun = inputs(full, async () => respond(epubBytes()));
    full.commit = async () => {
      throw new DOMException("full", "QuotaExceededError");
    };
    expect(await failure(saveCopy(fullRun.base))).toBe("space");
    expect(await full.book("5", "7")).toBeNull();

    const busy = new IndexedDbOfflineStore();
    const busyRun = inputs(busy, async () => respond(epubBytes()), { locks: { request: (async () => false) as unknown as LockManager["request"] } });
    expect(await failure(saveCopy(busyRun.base))).toBe("busy");
    expect(busyRun.fetched).toEqual([]);
  });

  test("a book and its file are read together, so a replaced edition is never shown under the old one's details", async () => {
    const store = new IndexedDbOfflineStore();
    await confirmed(store);
    await seed(store, savedBook());
    const replacement = savedBook({ asset: { ...savedBook().asset, id: NEWER_ID, size_bytes: SIZE + 22 } });
    await store.begin({ key: replacement.key, account: "5", id: "7", title: replacement.title, assetId: NEWER_ID, token: "replace", startedAt: 9, failure: null });
    const pair = (opened: { book: SavedBook; blob: Blob } | null) => (opened ? `${opened.book.asset.id.slice(0, 1)}:${opened.blob.size}` : "none");
    const [first, committed, second] = await Promise.all([store.open("5", "7"), store.commit(replacement, new Blob([epubBytes(SIZE + 22)]), "replace", NOW), store.open("5", "7")]);
    expect(committed).toBe("saved");
    for (const seen of [first, second]) expect([`e:${SIZE}`, `f:${SIZE + 22}`]).toContain(pair(seen));
    expect(pair(await store.open("5", "7"))).toBe(`f:${SIZE + 22}`);
  });

  test("another account's books stay out of every listing and can be removed without touching this account's", async () => {
    const store = new IndexedDbOfflineStore();
    await confirmed(store, confirmation({ account: "4" }));
    await seed(store, savedBook({ key: bookKey("4", "8"), account: "4", id: "8" }));
    await confirmed(store);
    await seed(store, savedBook());
    expect((await store.books("5")).map((book) => book.key)).toEqual(["5|7"]);
    expect(await store.open("5", "8")).toBeNull();
    expect(await store.others("5")).toEqual({ books: 1, bytes: SIZE });
    await store.removeOthers("5");
    expect(await store.others("5")).toEqual({ books: 0, bytes: 0 });
    expect(await store.open("5", "7")).not.toBeNull();
  });
});

describe("places kept on this device", () => {
  async function opened(record = confirmation()) {
    const store = new IndexedDbOfflineStore();
    await confirmed(store, confirmation());
    await seed(store, savedBook());
    if (record.account !== "5") await confirmed(store, record);
    return store;
  }

  test("only the last of quick turns is written, dated by its turn, and later turns are never dated earlier", async () => {
    const store = await opened();
    let clock = NOW;
    const places = new DevicePlaces(store, "5", "7", () => undefined, () => clock);
    places.record({ asset_id: EPUB_ID, locator: locator("a") }, NOW - 50);
    places.record({ asset_id: EPUB_ID, locator: locator("b") }, NOW - 40);
    await places.flush();
    expect((await store.book("5", "7"))?.devicePlace).toEqual({
      asset_id: EPUB_ID,
      locator: locator("b"),
      observedAt: new Date(NOW - 40).toISOString(),
      recordedAt: NOW,
      basedOn: 0,
      upload: { state: "pending", request: null, rebases: 0 },
    });
    clock += 1_000;
    places.record({ asset_id: EPUB_ID, locator: locator("c") }, NOW - 100);
    await places.flush();
    expect((await store.book("5", "7"))?.devicePlace?.observedAt).toBe(new Date(NOW - 39).toISOString());
    expect(places.getState()).toEqual({ kind: "kept" });
  });

  test("a place is refused and recording stops once the account is no longer confirmed", async () => {
    const store = await opened(confirmation({ account: "4" }));
    let refused = 0;
    const places = new DevicePlaces(store, "5", "7", () => (refused += 1), () => NOW);
    places.record({ asset_id: EPUB_ID, locator: locator("a") });
    await places.flush();
    places.record({ asset_id: EPUB_ID, locator: locator("b") });
    await places.flush();
    expect((await store.book("5", "7"))?.devicePlace).toBeNull();
    expect(refused).toBe(1);
    expect(places.getState()).toEqual({ kind: "stopped" });
  });

  test("a page left open on an edition that another tab replaced never overwrites the new edition's place", async () => {
    const store = await opened();
    const replacement = savedBook({ asset: { ...savedBook().asset, id: NEWER_ID }, devicePlace: { asset_id: NEWER_ID, locator: locator("new"), observedAt: "2026-11-20T11:00:00.000Z", recordedAt: 3 } });
    await store.begin({ key: replacement.key, account: "5", id: "7", title: replacement.title, assetId: NEWER_ID, token: "replace", startedAt: 9, failure: null });
    expect(await store.commit(replacement, new Blob([epubBytes()]), "replace", NOW)).toBe("saved");
    const places = new DevicePlaces(store, "5", "7", () => undefined, () => NOW);
    places.record({ asset_id: EPUB_ID, locator: locator("old") });
    await places.flush();
    expect((await store.book("5", "7"))?.devicePlace).toEqual(replacement.devicePlace);
    expect(places.getState()).toEqual({ kind: "replaced" });
  });
});

describe("a refused save download", () => {
  test("locks the page from the moment the download was asked for", async () => {
    const store = new IndexedDbOfflineStore();
    const sent: number[] = [];
    const { base, guard } = inputs(store, async () => {
      sent.push(Date.now());
      await new Promise((resolve) => setTimeout(resolve, 30));
      return new Response(JSON.stringify({ error: "signed_out" }), { status: 401, headers: { "content-type": "application/json" } });
    });
    expect(await failure(saveCopy(base))).toBe("signed_out");
    expect(guard.isActive()).toBe(false);
    expect(sent).toHaveLength(1);
    expect(guard.lockAskedAt!).toBeLessThanOrEqual(sent[0]!);
  });
});

describe("one origin, several deployments", () => {
  test("each mount keeps its own saved books and account, and the default mount keeps the Go database", async () => {
    expect([databaseNameFor("/preview"), databaseNameFor("/shelf/preview")]).toEqual([DATABASE_NAME, `${DATABASE_NAME}|/shelf/preview`]);
    const root = new IndexedDbOfflineStore(databaseNameFor("/preview"));
    const shelf = new IndexedDbOfflineStore(databaseNameFor("/shelf/preview"));
    await root.prepare();
    expect(await root.confirm(confirmation())).toBe(true);
    expect((await shelf.accountState()).record).toBeNull();
    expect((await root.accountState()).record?.account).toBe("5");
  });

  test("the Rails preview keeps its saved books, files and account apart from the experimental Go runtime on the same mount", async () => {
    expect([databaseNameFor("/preview", "rails"), databaseNameFor("/shelf/preview", "rails")]).toEqual([RAILS_DATABASE_NAME, `${RAILS_DATABASE_NAME}|/shelf/preview`]);
    expect(databaseNameFor("/preview", "go")).toBe(DATABASE_NAME);
    const rails = new IndexedDbOfflineStore(databaseNameFor("/preview", "rails"));
    const go = new IndexedDbOfflineStore(databaseNameFor("/preview", "go"));
    await confirmed(rails);
    await seed(rails, savedBook());
    expect((await rails.open("5", "7"))?.book.title).toBe(savedBook().title);
    await go.prepare();
    expect(await go.confirm(confirmation())).toBe(true);
    expect([await go.books("5"), await go.open("5", "7"), await go.book("5", "7"), await go.others("4")]).toEqual([[], null, null, { books: 0, bytes: 0 }]);
    await go.removeOthers("4");
    expect((await rails.books("5")).map((book) => book.key)).toEqual([savedBook().key]);
  });

  test("a save in progress in one runtime or deployment never makes another one's save of the same book busy", async () => {
    const go = new IndexedDbOfflineStore(databaseNameFor("/preview", "go"));
    const rails = new IndexedDbOfflineStore(databaseNameFor("/preview", "rails"));
    const shelf = new IndexedDbOfflineStore(databaseNameFor("/shelf/preview", "rails"));
    expect([saveLockName(go, "5", "7"), saveLockName(rails, "5", "7"), saveLockName(shelf, "5", "7")]).toEqual([
      "shelfarr-go-preview-offline|5|7",
      "shelfarr-rails-preview-offline|5|7",
      "shelfarr-rails-preview-offline|/shelf/preview|5|7",
    ]);
    const held = new Set([saveLockName(go, "5", "7")]);
    const locks = { request: (async (name: string, _options: LockOptions, work: (lock: Lock | null) => unknown) => work(held.has(name) ? null : ({ name, mode: "exclusive" } as Lock))) as unknown as LockManager["request"] };
    expect(await failure(saveCopy(inputs(go, async () => respond(epubBytes()), { locks }).base))).toBe("busy");
    for (const store of [rails, shelf]) {
      await saveCopy(inputs(store, async () => respond(epubBytes()), { locks }).base);
      expect((await store.open("5", "7"))?.blob.size).toBe(SIZE);
    }
    expect(await go.open("5", "7")).toBeNull();
  });

  test("the Rails sign-in page releases only this deployment's confirmed account, in the format the reader reads, and creates nothing", async () => {
    expect([previewDatabaseName(""), previewDatabaseName("/shelf")]).toEqual([RAILS_DATABASE_NAME, `${RAILS_DATABASE_NAME}|/shelf/preview`]);
    expect(await releasePreviewAccount("", NOW)).toBe(false);
    expect((await indexedDB.databases()).map((database) => database.name)).toEqual([]);
    const root = new IndexedDbOfflineStore(databaseNameFor("/preview", "rails"));
    const shelf = new IndexedDbOfflineStore(databaseNameFor("/shelf/preview", "rails"));
    const go = new IndexedDbOfflineStore(databaseNameFor("/preview", "go"));
    await root.prepare();
    await shelf.prepare();
    await go.prepare();
    await root.confirm(confirmation());
    await shelf.confirm(confirmation());
    await go.confirm(confirmation());
    expect(await releasePreviewAccount("", NOW + 1)).toBe(true);
    expect(await root.accountState()).toEqual({ record: null, clearedAt: NOW + 1 });
    expect((await shelf.accountState()).record?.account).toBe("5");
    expect(await go.accountState()).toEqual({ record: { ...confirmation(), seenAt: NOW }, clearedAt: 0 });
    expect(await root.confirm(confirmation())).toBe(false);
    expect(await root.confirm(confirmation({ confirmedAt: NOW + 2 }))).toBe(true);
    expect(await releasePreviewAccount("", NOW + 1)).toBe(false);
    expect((await root.accountState()).record?.confirmedAt).toBe(NOW + 2);
  });

  test("a browser that cannot list its databases still has this deployment's account released, and nothing is created", async () => {
    const factory = indexedDB as IDBFactory & { databases?: unknown };
    const listing = factory.databases;
    Object.defineProperty(factory, "databases", { value: undefined, configurable: true });
    try {
      expect(await releasePreviewAccount("", NOW)).toBe(false);
      Object.defineProperty(factory, "databases", { value: listing, configurable: true });
      expect((await indexedDB.databases()).map((database) => database.name)).toEqual([]);
      const root = new IndexedDbOfflineStore(databaseNameFor("/preview", "rails"));
      await root.prepare();
      await root.confirm(confirmation());
      Object.defineProperty(factory, "databases", { value: undefined, configurable: true });
      expect(await releasePreviewAccount("", NOW + 1)).toBe(true);
      expect((await root.accountState()).record).toBeNull();
    } finally {
      Object.defineProperty(factory, "databases", { value: listing, configurable: true });
    }
  });
});
