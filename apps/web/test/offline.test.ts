import { describe, expect, test } from "bun:test";
import { AccountGuard } from "../src/api/account-guard";
import { DevicePlaces } from "../src/offline/devicePlaces";
import { ACCOUNT_LIMIT_BYTES, BOOK_LIMIT_BYTES, CLOCK_TOLERANCE_MS, openingLocator, rememberAccountPlace, savedEpub, usable, type ConfirmedAccount } from "../src/offline/model";
import { saveCopy, SaveFailure, type SaveInputs } from "../src/offline/save";
import { WorkerFailure } from "../src/offline/worker";
import { DAY, EPUB_ID, MemoryOfflineStore, NEWER_ID, asset, epubBytes, readerPublication, savedBook, serverProgress } from "./offline-helpers";

const NOW = Date.parse("2026-11-20T12:00:00.000Z");
const OFFLINE = { worker: "/preview/offline-worker.js", scope: "/preview/library/", downloads: "/preview/library/downloads" };
const confirmation = (overrides: Partial<ConfirmedAccount> = {}): ConfirmedAccount => ({ account: "5", confirmedAt: NOW, validForMs: 30 * DAY, ...overrides });

function respond(body: Uint8Array<ArrayBuffer> | null, init: { status?: number; headers?: Record<string, string> } = {}): Response {
  return new Response(body, { status: init.status ?? 200, headers: init.headers ?? { ETag: `"${EPUB_ID}"`, "Content-Length": String(body?.byteLength ?? 0) } });
}

type Answer = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

function inputs(store: MemoryOfflineStore, fetcher: Answer, overrides: Partial<SaveInputs> = {}) {
  const fetched: string[] = [];
  const progress: number[] = [];
  const guard = new AccountGuard("5");
  const base: SaveInputs = {
    publication: readerPublication(),
    confirmation: confirmation(),
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
  test("is usable only for its own account, inside its window and within the clock tolerance", () => {
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
  });
});

describe("where a saved copy opens", () => {
  const device = { asset_id: EPUB_ID, locator: { href: "OEBPS/two.xhtml", locations: { cfi: "epubcfi(/6/4!/4/2/1:0)" } }, observedAt: "2026-11-20T11:00:00.000Z", recordedAt: 5_000 };
  const account = { asset_id: EPUB_ID, locator: { href: "OEBPS/one.xhtml", locations: { cfi: "epubcfi(/6/2!/4/2/1:0)" } }, version: 3, learnedAt: 4_000 };

  test("a place reached on this device after the account place was learned wins", () => {
    expect(openingLocator(savedBook({ devicePlace: device, accountPlace: account }))).toEqual(device.locator);
  });

  test("an account place learned after the device place wins, and the device place is kept", () => {
    const book = savedBook({ devicePlace: device, accountPlace: { ...account, learnedAt: 6_000 } });
    expect(openingLocator(book)).toEqual(account.locator);
    expect(book.devicePlace).toEqual(device);
  });

  test("a place in another edition is never opened", () => {
    expect(openingLocator(savedBook({ devicePlace: { ...device, asset_id: NEWER_ID }, accountPlace: { ...account, asset_id: NEWER_ID } }))).toBeNull();
    expect(openingLocator(savedBook({ devicePlace: { ...device, asset_id: NEWER_ID }, accountPlace: account }))).toEqual(account.locator);
  });

  test("the account place is replaced only by a newer version", () => {
    const book = savedBook({ accountPlace: account });
    expect(rememberAccountPlace(book, serverProgress({ version: 3 }), 9_000)).toBe(book);
    expect(rememberAccountPlace(book, serverProgress({ version: 2 }), 9_000)).toBe(book);
    expect(rememberAccountPlace(book, serverProgress({ version: 4 }), 9_000).accountPlace).toEqual({ asset_id: EPUB_ID, locator: serverProgress().locator!, version: 4, learnedAt: 9_000 });
    expect(rememberAccountPlace(book, serverProgress({ version: 9, locator: null, position_seconds: 3 }), 9_000)).toBe(book);
  });

  test("the saved EPUB is the one the account's place is in, else the first EPUB", () => {
    const other = asset({ id: NEWER_ID });
    expect(savedEpub(readerPublication({ assets: [asset(), other], progress: serverProgress({ asset_id: NEWER_ID }) }))?.id).toBe(NEWER_ID);
    expect(savedEpub(readerPublication({ assets: [asset(), other] }))?.id).toBe(EPUB_ID);
    expect(savedEpub(readerPublication({ assets: [asset({ format: "pdf" })] }))).toBeNull();
  });
});

describe("saving a copy", () => {
  test("stores the verified EPUB and the account's place in one commit and clears the attempt", async () => {
    const store = new MemoryOfflineStore();
    const bytes = epubBytes(64);
    const { base, fetched, progress } = inputs(store, async () => respond(bytes), { publication: readerPublication({ progress: serverProgress() }) });
    await saveCopy(base);
    expect(fetched).toEqual([asset().url]);
    expect(store.confirms).toEqual([confirmation()]);
    expect(store.attemptRecords.size).toBe(0);
    const book = await store.book("5", "7");
    expect(book).toEqual(savedBook({ savedAt: NOW, accountPlace: { asset_id: EPUB_ID, locator: serverProgress().locator!, version: 3, learnedAt: NOW } }));
    expect(new Uint8Array(await (await store.file("5", "7"))!.arrayBuffer())).toEqual(bytes);
    expect(progress.at(-1)).toBe(64);
  });

  test("refuses a book over the reader's limit before anything is fetched or recorded", async () => {
    const store = new MemoryOfflineStore();
    const { base, fetched } = inputs(store, async () => respond(epubBytes(64)), { publication: readerPublication({ assets: [asset({ size_bytes: BOOK_LIMIT_BYTES + 1 })] }) });
    expect(await failure(saveCopy(base))).toBe("too_large");
    expect(fetched).toEqual([]);
    expect(store.attemptRecords.size + store.saved.size + store.confirms.length).toBe(0);
  });

  test("refuses when the account's saved books or the browser's free space would not fit it", async () => {
    const full = new MemoryOfflineStore();
    full.saved.set("5|9", savedBook({ key: "5|9", id: "9", asset: { ...savedBook().asset, size_bytes: ACCOUNT_LIMIT_BYTES - 32 } }));
    const limited = inputs(full, async () => respond(epubBytes(64)));
    expect(await failure(saveCopy(limited.base))).toBe("space");
    expect(limited.fetched).toEqual([]);

    const cramped = new MemoryOfflineStore();
    const quota = inputs(cramped, async () => respond(epubBytes(64)), { estimate: async () => ({ quota: 40 * 1024 * 1024, usage: 8 * 1024 * 1024 }) });
    expect(await failure(saveCopy(quota.base))).toBe("space");
    expect(quota.fetched).toEqual([]);
    expect(cramped.saved.size).toBe(0);

    const replacing = new MemoryOfflineStore();
    replacing.saved.set("5|7", savedBook({ asset: { ...savedBook().asset, size_bytes: ACCOUNT_LIMIT_BYTES - 32 } }));
    await saveCopy(inputs(replacing, async () => respond(epubBytes(64))).base);
    expect((await replacing.book("5", "7"))?.asset.size_bytes).toBe(64);
  });

  test("keeps the earlier copy and records why when the new edition does not arrive whole and verified", async () => {
    const cases: [string, () => Promise<Response>][] = [
      ["changed", async () => respond(epubBytes(64), { headers: { ETag: `"${NEWER_ID}"`, "Content-Length": "64" } })],
      ["changed", async () => respond(epubBytes(63), { headers: { ETag: `"${EPUB_ID}"` } })],
      ["changed", async () => respond(epubBytes(65), { headers: { ETag: `"${EPUB_ID}"` } })],
      ["changed", async () => respond(new Uint8Array(64))],
      ["changed", async () => respond(epubBytes(64), { headers: { ETag: `"${EPUB_ID}"`, "Content-Length": "60" } })],
      ["missing", async () => respond(null, { status: 404, headers: {} })],
      ["changed", async () => respond(null, { status: 410, headers: {} })],
      ["network", async () => respond(null, { status: 503, headers: {} })],
      ["network", async () => Promise.reject(new TypeError("Failed to fetch"))],
    ];
    for (const [expected, answer] of cases) {
      const store = new MemoryOfflineStore();
      const earlier = savedBook({ asset: { ...savedBook().asset, id: NEWER_ID } });
      store.saved.set(earlier.key, earlier);
      store.files.set(earlier.key, { assetId: NEWER_ID, blob: new Blob([epubBytes(64)]) });
      const { base } = inputs(store, answer);
      expect(await failure(saveCopy(base))).toBe(expected);
      expect(await store.book("5", "7")).toEqual(earlier);
      expect(store.files.get(earlier.key)?.assetId).toBe(NEWER_ID);
      expect(store.attemptRecords.get("5|7")?.failure).toBe(expected as never);
    }
  });

  test("a refusal for the session locks the page and stores nothing", async () => {
    for (const code of ["signed_out", "account_changed"] as const) {
      const store = new MemoryOfflineStore();
      const { base, guard } = inputs(store, async () => new Response(JSON.stringify({ error: code }), { status: 401, headers: { "content-type": "application/json" } }));
      expect(await failure(saveCopy(base))).toBe("signed_out");
      expect(guard.getState().status).toBe(code);
      expect(store.saved.size).toBe(0);
    }
  });

  test("nothing is committed when the account changed while the book downloaded", async () => {
    const store = new MemoryOfflineStore();
    store.beforeCommit = () => {
      store.record = confirmation({ account: "4" });
    };
    expect(await failure(saveCopy(inputs(store, async () => respond(epubBytes(64))).base))).toBe("signed_out");
    expect(store.saved.size + store.files.size).toBe(0);

    const locked = new MemoryOfflineStore();
    const run = inputs(locked, async () => {
      run.guard.lock("account_changed");
      return respond(epubBytes(64));
    });
    expect(await failure(saveCopy(run.base))).toBe("signed_out");
    expect(locked.saved.size).toBe(0);
  });

  test("a page for another account, a failed worker, a full disk at commit and a save in another tab store nothing", async () => {
    const other = new MemoryOfflineStore();
    const otherRun = inputs(other, async () => respond(epubBytes(64)), { confirmation: confirmation({ account: "4" }) });
    expect(await failure(saveCopy(otherRun.base))).toBe("signed_out");
    expect(otherRun.fetched).toEqual([]);

    const broken = new MemoryOfflineStore();
    const workerRun = inputs(broken, async () => respond(epubBytes(64)), { ensureWorker: async () => Promise.reject(new WorkerFailure("no")) });
    expect(await failure(saveCopy(workerRun.base))).toBe("worker");
    expect(workerRun.fetched).toEqual([]);
    expect(broken.confirms).toEqual([]);

    const full = new MemoryOfflineStore();
    full.failCommit = new DOMException("full", "QuotaExceededError");
    expect(await failure(saveCopy(inputs(full, async () => respond(epubBytes(64))).base))).toBe("space");
    expect(full.saved.size).toBe(0);

    const busy = new MemoryOfflineStore();
    const busyRun = inputs(busy, async () => respond(epubBytes(64)), { locks: { request: (async () => false) as unknown as LockManager["request"] } });
    expect(await failure(saveCopy(busyRun.base))).toBe("busy");
    expect(busyRun.fetched).toEqual([]);
  });
});

describe("places kept on this device", () => {
  const locator = (cfi: string) => ({ href: "OEBPS/one.xhtml", locations: { cfi } });

  test("only the last of quick turns is written, dated by its turn, and later turns are never dated earlier", async () => {
    const store = new MemoryOfflineStore();
    store.record = confirmation();
    store.saved.set("5|7", savedBook());
    let clock = NOW;
    const places = new DevicePlaces(store, "5", "7", () => undefined, () => clock);
    places.record({ asset_id: EPUB_ID, locator: locator("a") }, NOW - 50);
    places.record({ asset_id: EPUB_ID, locator: locator("b") }, NOW - 40);
    await places.flush();
    expect(store.saved.get("5|7")?.devicePlace).toEqual({ asset_id: EPUB_ID, locator: locator("b"), observedAt: new Date(NOW - 40).toISOString(), recordedAt: NOW });
    clock += 1_000;
    places.record({ asset_id: EPUB_ID, locator: locator("c") }, NOW - 100);
    await places.flush();
    expect(store.saved.get("5|7")?.devicePlace?.observedAt).toBe(new Date(NOW - 39).toISOString());
    expect(places.getState()).toEqual({ kind: "kept" });
  });

  test("a place is refused and recording stops once the account is no longer confirmed", async () => {
    const store = new MemoryOfflineStore();
    store.record = confirmation({ account: "4" });
    store.saved.set("5|7", savedBook());
    let refused = 0;
    const places = new DevicePlaces(store, "5", "7", () => (refused += 1), () => NOW);
    places.record({ asset_id: EPUB_ID, locator: locator("a") });
    await places.flush();
    places.record({ asset_id: EPUB_ID, locator: locator("b") });
    await places.flush();
    expect(store.saved.get("5|7")?.devicePlace).toBeNull();
    expect(refused).toBe(1);
    expect(places.getState()).toEqual({ kind: "stopped" });
  });
});
