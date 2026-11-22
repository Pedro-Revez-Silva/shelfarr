import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { IDBFactory } from "fake-indexeddb";
import { Blob as NativeBlob } from "node:buffer";
import type { ProgressAnswer } from "../src/api/client";
import { ApiError } from "../src/api/errors";
import type { ProgressRequest, StoredProgress } from "../src/contract";
import { DevicePlaces } from "../src/offline/devicePlaces";
import { openingLocator, rememberAccountPlace, type ConfirmedAccount, type SavedBook } from "../src/offline/model";
import { offeredDevicePlace } from "../src/offline/remembered";
import { IndexedDbOfflineStore } from "../src/offline/store";
import { createSyncRunner, reconcileOffline, syncPlaces, type SyncDeps, type Verification } from "../src/offline/sync";
import { DAY, EPUB_ID, NEWER_ID, epubBytes, savedBook, serverProgress } from "./offline-helpers";

const NOW = Date.parse("2026-11-20T12:00:00.000Z");
const OFFLINE_AT = "2026-11-20T11:00:00.000Z";
const locator = (cfi: string) => ({ href: "OEBPS/one.xhtml", type: "application/xhtml+xml", locations: { cfi, progression: 0.5, totalProgression: 0.4 } });

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

async function storeWith(book: SavedBook, record: ConfirmedAccount = { account: "5", confirmedAt: NOW - DAY, validForMs: 30 * DAY }) {
  const store = new IndexedDbOfflineStore();
  await store.prepare();
  await store.confirm(record);
  await store.begin({ key: book.key, account: "5", id: book.id, title: book.title, assetId: book.asset.id, token: "seed", startedAt: 1, failure: null });
  expect(await store.commit(book, new Blob([epubBytes()]), "seed", NOW)).toBe("saved");
  return store;
}

const offlineBook = (overrides: Partial<SavedBook> = {}) =>
  savedBook({
    accountPlace: { asset_id: EPUB_ID, locator: locator("account"), version: 3, observedAt: "2026-11-20T10:00:00.000Z", learnedAt: NOW - 2 * DAY },
    devicePlace: { asset_id: EPUB_ID, locator: locator("device"), observedAt: OFFLINE_AT, recordedAt: NOW - 1000, basedOn: 3, upload: { state: "pending", request: null, rebases: 0 } },
    ...overrides,
  });

function stored(request: ProgressRequest, version: number): StoredProgress {
  return { asset_id: request.asset_id, locator: request.locator ?? null, position_seconds: null, version, observed_at: request.observed_at, updated_at: "2026-11-20T12:00:01.000Z", client_mutation_id: request.client_mutation_id };
}

type Writer = (request: ProgressRequest) => Promise<ProgressAnswer>;

function harness(store: IndexedDbOfflineStore, answers: Writer[], verification: Verification = { kind: "verified", csrf: "token" }) {
  const writes: { id: string; body: ProgressRequest; csrf: string }[] = [];
  let verifications = 0;
  let id = 0;
  const deps: SyncDeps = {
    store,
    account: "5",
    verify: async () => {
      verifications += 1;
      return verification;
    },
    write: async (book, body, csrf) => {
      writes.push({ id: book, body, csrf });
      const next = answers.shift();
      if (!next) throw new Error("unexpected write");
      return next(body);
    },
    now: () => NOW,
    uuid: () => `mutation-${++id}`,
  };
  return { deps, writes, verifications: () => verifications };
}

const saved =
  (version: number): Writer =>
  async (body) => ({ kind: "saved", progress: stored(body, version) });
const conflict =
  (remote: StoredProgress | null): Writer =>
  async () => ({ kind: "conflict", progress: remote });
const failing =
  (error: Error): Writer =>
  async () => {
    throw error;
  };

describe("sending places reached offline", () => {
  test("the last offline place is sent once with its own activity time and the known version, and the account place follows it", async () => {
    const store = await storeWith(offlineBook());
    const run = harness(store, [saved(4)]);
    expect(await syncPlaces(run.deps)).toEqual({ kind: "settled" });
    expect(run.writes).toEqual([
      { id: "7", csrf: "token", body: { asset_id: EPUB_ID, locator: locator("device"), observed_at: OFFLINE_AT, expected_version: 3, client_mutation_id: "mutation-1" } },
    ]);
    const book = await store.book("5", "7");
    expect(book?.devicePlace?.upload).toEqual({ state: "synced", version: 4 });
    expect(book?.accountPlace).toEqual({ asset_id: EPUB_ID, locator: locator("device"), version: 4, observedAt: OFFLINE_AT, learnedAt: NOW });
    expect(await syncPlaces(run.deps)).toEqual({ kind: "idle" });
    expect(run.writes).toHaveLength(1);
  });

  test("nothing is asked of the network when no place is waiting", async () => {
    const store = await storeWith(offlineBook({ devicePlace: null }));
    const run = harness(store, []);
    expect(await syncPlaces(run.deps)).toEqual({ kind: "idle" });
    expect(run.verifications()).toBe(0);
    const synced = await storeWith(offlineBook({ devicePlace: { ...offlineBook().devicePlace!, upload: { state: "synced", version: 4 } } }));
    expect(await syncPlaces(harness(synced, []).deps)).toEqual({ kind: "idle" });
  });

  test("a place reached before this version existed is still sent, and an older one is not", async () => {
    const legacy = offlineBook({ devicePlace: { asset_id: EPUB_ID, locator: locator("device"), observedAt: OFFLINE_AT, recordedAt: NOW - 1000 } });
    const store = await storeWith(legacy);
    const run = harness(store, [saved(4)]);
    await syncPlaces(run.deps);
    expect(run.writes.map((write) => write.body.observed_at)).toEqual([OFFLINE_AT]);
    globalThis.indexedDB = new IDBFactory();
    const older = await storeWith(offlineBook({ devicePlace: { asset_id: EPUB_ID, locator: locator("device"), observedAt: "2026-11-20T09:00:00.000Z", recordedAt: NOW - 1000 } }));
    const none = harness(older, []);
    expect(await syncPlaces(none.deps)).toEqual({ kind: "idle" });
    expect(none.verifications()).toBe(0);
  });

  test("a move made offline is offered to the server even when the account place it knew is dated later", async () => {
    const store = await storeWith(offlineBook({ devicePlace: null, accountPlace: { asset_id: EPUB_ID, locator: locator("account"), version: 3, observedAt: "2026-11-20T11:30:00.000Z", learnedAt: NOW - DAY } }));
    const places = new DevicePlaces(store, "5", "7", () => undefined, () => NOW);
    places.record({ asset_id: EPUB_ID, locator: locator("moved") }, Date.parse(OFFLINE_AT));
    await places.flush();
    const run = harness(store, [conflict(serverProgress({ version: 3, observed_at: "2026-11-20T11:30:00.000Z", client_mutation_id: "other" }))]);
    await syncPlaces(run.deps);
    expect(run.writes.map((write) => write.body.locator)).toEqual([locator("moved")]);
    expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "superseded", version: 3 });
  });

  test("a deliberate return to the account's last known place is still sent, so the server decides", async () => {
    const store = await storeWith(offlineBook({ devicePlace: { ...offlineBook().devicePlace!, locator: locator("account") } }));
    const elsewhere = serverProgress({ version: 4, locator: locator("elsewhere"), observed_at: "2026-11-20T10:30:00.000Z", client_mutation_id: "other-device" });
    const run = harness(store, [conflict(elsewhere), saved(5)]);
    expect(await syncPlaces(run.deps)).toEqual({ kind: "settled" });
    expect(run.writes.map((write) => [write.body.expected_version, write.body.locator, write.body.observed_at])).toEqual([
      [3, locator("account"), OFFLINE_AT],
      [4, locator("account"), OFFLINE_AT],
    ]);
    expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "synced", version: 5 });
  });

  test("a later offline place wins over an earlier server place by rebasing with the same activity time", async () => {
    const store = await storeWith(offlineBook());
    const earlier = { ...serverProgress({ version: 6, observed_at: "2026-11-20T10:30:00.000Z", client_mutation_id: "other-device" }) };
    const run = harness(store, [conflict(earlier), saved(7)]);
    await syncPlaces(run.deps);
    expect(run.writes.map((write) => [write.body.expected_version, write.body.client_mutation_id, write.body.observed_at])).toEqual([
      [3, "mutation-1", OFFLINE_AT],
      [6, "mutation-2", OFFLINE_AT],
    ]);
    expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "synced", version: 7 });
  });

  test("a later server place is kept: the offline place is not sent again and stays on this device", async () => {
    const store = await storeWith(offlineBook());
    const later = serverProgress({ version: 6, observed_at: "2026-11-20T11:30:00.000Z", client_mutation_id: "other-device" });
    const run = harness(store, [conflict(later)]);
    await syncPlaces(run.deps);
    const book = await store.book("5", "7");
    expect(book?.devicePlace?.upload).toEqual({ state: "superseded", version: 6 });
    expect(book?.devicePlace?.locator).toEqual(locator("device"));
    expect(book?.accountPlace?.version).toBe(6);
    expect(await syncPlaces(run.deps)).toEqual({ kind: "idle" });
    expect(run.writes).toHaveLength(1);
  });

  test("an undated, implausible or other-file server place is never overwritten and waits for a choice", async () => {
    for (const remote of [
      serverProgress({ version: 6, observed_at: null, client_mutation_id: "x" }),
      serverProgress({ version: 6, observed_at: "2030-01-01T00:00:00.000Z", client_mutation_id: "x" }),
      serverProgress({ version: 6, asset_id: NEWER_ID, observed_at: "2026-11-20T10:30:00.000Z", client_mutation_id: "x" }),
    ]) {
      globalThis.indexedDB = new IDBFactory();
      const store = await storeWith(offlineBook());
      const run = harness(store, [conflict(remote)]);
      await syncPlaces(run.deps);
      expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "held", reason: "conflict", message: null });
      expect(run.writes).toHaveLength(1);
    }
  });

  test("a conflict that answers with this device's own write counts as sent", () => {
    const request: ProgressRequest = { asset_id: EPUB_ID, locator: locator("device"), observed_at: OFFLINE_AT, expected_version: 3, client_mutation_id: "mutation-1" };
    expect(reconcileOffline(request, stored(request, 4), EPUB_ID, 0, NOW)).toEqual({ kind: "settle", upload: { state: "synced", version: 4 } });
    expect(reconcileOffline(request, serverProgress({ observed_at: "2026-11-20T10:00:00.000Z", client_mutation_id: "x" }), EPUB_ID, 5, NOW)).toEqual({
      kind: "settle",
      upload: { state: "held", reason: "conflict", message: null },
    });
  });

  test("an uncertain answer keeps the exact request, which is resent unchanged later", async () => {
    const store = await storeWith(offlineBook());
    const run = harness(store, [failing(new ApiError("network", "lost")), failing(new ApiError("server", "busy", 503)), saved(4)]);
    expect(await syncPlaces(run.deps)).toEqual({ kind: "retry" });
    expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({
      state: "pending",
      request: { asset_id: EPUB_ID, locator: locator("device"), observed_at: OFFLINE_AT, expected_version: 3, client_mutation_id: "mutation-1" },
      rebases: 0,
    });
    expect(await syncPlaces(run.deps)).toEqual({ kind: "retry" });
    expect(await syncPlaces(run.deps)).toEqual({ kind: "settled" });
    expect(new Set(run.writes.map((write) => JSON.stringify(write.body))).size).toBe(1);
  });

  test("a refused place is kept here and not sent again; a refused session stops without losing it", async () => {
    const rejected = await storeWith(offlineBook());
    const run = harness(rejected, [failing(new ApiError("invalid", "This place is not in the book", 422))]);
    expect(await syncPlaces(run.deps)).toEqual({ kind: "settled" });
    expect((await rejected.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "held", reason: "rejected", message: "This place is not in the book" });
    expect(await syncPlaces(run.deps)).toEqual({ kind: "idle" });

    globalThis.indexedDB = new IDBFactory();
    const signedOut = await storeWith(offlineBook());
    const ended = harness(signedOut, [failing(new ApiError("signed_out", "gone", 401))]);
    expect(await syncPlaces(ended.deps)).toEqual({ kind: "stop" });
    expect((await signedOut.book("5", "7"))?.devicePlace?.upload?.state).toBe("pending");
  });

  test("nothing is written unless the account is confirmed again first", async () => {
    for (const verification of [{ kind: "stop" }, { kind: "retry" }] as const) {
      globalThis.indexedDB = new IDBFactory();
      const store = await storeWith(offlineBook());
      const run = harness(store, [], verification);
      expect(await syncPlaces(run.deps)).toEqual(verification);
      expect(run.writes).toEqual([]);
    }
    globalThis.indexedDB = new IDBFactory();
    const switched = await storeWith(offlineBook());
    await switched.confirm({ account: "4", confirmedAt: NOW, validForMs: DAY });
    const other = harness(switched, []);
    expect(await syncPlaces(other.deps)).toEqual({ kind: "settled" });
    expect(other.writes).toEqual([]);
  });

  test("a late answer for an earlier place never clears a newer offline turn", async () => {
    const store = await storeWith(offlineBook());
    let release: () => void = () => undefined;
    const places = new DevicePlaces(store, "5", "7", () => undefined, () => NOW);
    const run = harness(store, [
      async (body) => {
        await new Promise<void>((resolve) => (release = resolve));
        return { kind: "saved", progress: stored(body, 4) };
      },
      saved(5),
    ]);
    const first = syncPlaces(run.deps);
    while (run.writes.length === 0) await new Promise((resolve) => setTimeout(resolve, 1));
    places.record({ asset_id: EPUB_ID, locator: locator("newer") }, Date.parse("2026-11-20T11:10:00.000Z"));
    await places.flush();
    release();
    expect(await first).toEqual({ kind: "settled" });
    expect(run.writes.map((write) => [write.body.locator, write.body.expected_version, write.body.observed_at])).toEqual([
      [locator("device"), 3, OFFLINE_AT],
      [locator("newer"), 3, "2026-11-20T11:10:00.000Z"],
    ]);
    expect((await store.book("5", "7"))?.devicePlace).toMatchObject({ locator: locator("newer"), upload: { state: "synced", version: 5 } });
  });

  test("two tabs sending at once send the same request, and the server's replay settles it once", async () => {
    const store = await storeWith(offlineBook());
    let held: () => void = () => undefined;
    const gate = new Promise<void>((resolve) => (held = resolve));
    const first = harness(store, [async (body) => (await gate, { kind: "saved", progress: stored(body, 4) })]);
    const second = harness(store, [async (body) => (await gate, { kind: "saved", progress: stored(body, 4) })]);
    second.deps.uuid = () => "never-used";
    const runs = [syncPlaces(first.deps)];
    while (first.writes.length === 0) await new Promise((resolve) => setTimeout(resolve, 1));
    runs.push(syncPlaces(second.deps));
    while (second.writes.length === 0) await new Promise((resolve) => setTimeout(resolve, 1));
    held();
    await Promise.all(runs);
    expect(second.writes[0]?.body).toEqual(first.writes[0]?.body);
    expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "synced", version: 4 });
  });
});

describe("the sync runner", () => {
  test("runs one sync at a time, retries with backoff after an uncertain answer and stops for good when told", async () => {
    const store = await storeWith(offlineBook());
    let calls = 0;
    const run = harness(store, [failing(new ApiError("network", "lost")), saved(4)]);
    const verify = run.deps.verify;
    run.deps.verify = async () => {
      calls += 1;
      return verify();
    };
    const runner = createSyncRunner(run.deps, undefined, [20]);
    let notified = 0;
    runner.subscribe(() => (notified += 1));
    runner.request();
    runner.request();
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(run.writes).toHaveLength(2);
    expect(calls).toBe(2);
    expect(notified).toBeGreaterThanOrEqual(2);
    expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "synced", version: 4 });
    runner.stop();
    runner.request();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(calls).toBe(2);
  });

  test("another tab holding the sync lock means this tab does not send", async () => {
    const store = await storeWith(offlineBook());
    const run = harness(store, [saved(4)]);
    const busy = { request: (async (_name: string, _options: LockOptions, work: (lock: Lock | null) => unknown) => work(null)) as unknown as LockManager["request"] };
    const runner = createSyncRunner(run.deps, busy, [10_000]);
    runner.request();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(run.writes).toEqual([]);
    runner.stop();
  });
});

describe("third review regressions", () => {
  test("the account is confirmed again before every write, and a refusal between writes stops the next one", async () => {
    const store = await storeWith(offlineBook());
    const earlier = serverProgress({ version: 6, observed_at: "2026-11-20T10:30:00.000Z", client_mutation_id: "other-device" });
    const run = harness(store, [conflict(earlier), saved(7)]);
    const answers: Verification[] = [
      { kind: "verified", csrf: "first" },
      { kind: "verified", csrf: "second" },
    ];
    run.deps.verify = async () => answers.shift() ?? { kind: "stop" };
    await syncPlaces(run.deps);
    expect(run.writes.map((write) => write.csrf)).toEqual(["first", "second"]);

    globalThis.indexedDB = new IDBFactory();
    const stopped = await storeWith(offlineBook());
    const second = harness(stopped, [conflict(earlier)]);
    const once: Verification[] = [{ kind: "verified", csrf: "first" }];
    second.deps.verify = async () => once.shift() ?? { kind: "stop" };
    expect(await syncPlaces(second.deps)).toEqual({ kind: "stop" });
    expect(second.writes).toHaveLength(1);
  });

  test("an older turn saved late by another tab never replaces a newer pending place", async () => {
    const store = await storeWith(offlineBook({ devicePlace: null }));
    const newer = new DevicePlaces(store, "5", "7", () => undefined, () => NOW);
    const older = new DevicePlaces(store, "5", "7", () => undefined, () => NOW);
    newer.record({ asset_id: EPUB_ID, locator: locator("newer") }, Date.parse("2026-11-20T11:20:00.000Z"));
    await newer.flush();
    older.record({ asset_id: EPUB_ID, locator: locator("older") }, Date.parse("2026-11-20T11:10:00.000Z"));
    await older.flush();
    expect((await store.book("5", "7"))?.devicePlace?.locator).toEqual(locator("newer"));
    expect(older.getState()).toEqual({ kind: "kept" });
    const run = harness(store, [saved(4)]);
    await syncPlaces(run.deps);
    expect(run.writes.map((write) => write.body.locator)).toEqual([locator("newer")]);
  });

  test("saving a copy again keeps the newer account place and the pending place learned meanwhile", async () => {
    const store = await storeWith(offlineBook());
    await store.begin({ key: "5|7", account: "5", id: "7", title: "Saved Book", assetId: NEWER_ID, token: "update", startedAt: 2, failure: null });
    const stale = savedBook({ asset: { ...savedBook().asset, id: NEWER_ID }, accountPlace: { asset_id: NEWER_ID, locator: locator("old"), version: 2, observedAt: null, learnedAt: 1 }, devicePlace: null });
    expect(await store.commit(stale, new Blob([epubBytes()]), "update", NOW)).toBe("saved");
    const book = await store.book("5", "7");
    expect(book?.asset.id).toBe(NEWER_ID);
    expect(book?.accountPlace?.version).toBe(3);
    expect(book?.devicePlace?.locator).toEqual(locator("device"));
  });

  test("an expired record is never revived by its own or an older answer, while a later genuine answer is accepted after the clock is corrected", async () => {
    const store = await storeWith(offlineBook(), { account: "5", confirmedAt: NOW - 30 * DAY, validForMs: 30 * DAY + 5 });
    expect(await store.touch("5", NOW + 40 * DAY)).toBe(false);
    expect(await store.confirm({ account: "5", confirmedAt: NOW - 30 * DAY, validForMs: 60 * DAY })).toBe(false);
    expect(await store.confirm({ account: "5", confirmedAt: NOW, validForMs: DAY })).toBe(true);
  });

  test("an offline move carries the account version it was based on, so a place learned later turns into a conflict instead of an overwrite", async () => {
    const store = await storeWith(offlineBook({ devicePlace: null }));
    const places = new DevicePlaces(store, "5", "7", () => undefined, () => NOW);
    places.record({ asset_id: EPUB_ID, locator: locator("moved") }, Date.parse(OFFLINE_AT));
    await places.flush();
    await store.updateBook("5", "7", (book) => ({ ...book, accountPlace: { asset_id: EPUB_ID, locator: locator("undated"), version: 4, observedAt: null, learnedAt: NOW } }), NOW);
    const run = harness(store, [conflict(serverProgress({ version: 4, observed_at: null, locator: locator("undated"), client_mutation_id: "other" }))]);
    await syncPlaces(run.deps);
    expect(run.writes.map((write) => write.body.expected_version)).toEqual([3]);
    expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "held", reason: "conflict", message: null });
  });

  test("a superseded device place never becomes where the saved copy opens", () => {
    const book = offlineBook({
      accountPlace: { asset_id: NEWER_ID, locator: locator("other-file"), version: 6, observedAt: "2026-11-20T11:30:00.000Z", learnedAt: NOW },
      devicePlace: { ...offlineBook().devicePlace!, upload: { state: "superseded", version: 5 } },
    });
    expect(openingLocator(book)).toBeNull();
  });

  test("a place pending in an edition that was since replaced is never sent", async () => {
    const store = await storeWith(offlineBook());
    await store.begin({ key: "5|7", account: "5", id: "7", title: "Saved Book", assetId: NEWER_ID, token: "update", startedAt: 2, failure: null });
    expect(await store.commit(savedBook({ asset: { ...savedBook().asset, id: NEWER_ID } }), new Blob([epubBytes()]), "update", NOW)).toBe("saved");
    const run = harness(store, []);
    expect(await syncPlaces(run.deps)).toEqual({ kind: "idle" });
    expect(run.verifications()).toBe(0);
  });

  test("the request is built only after the account is confirmed, so a removal or newer move during the check is respected", async () => {
    const removed = await storeWith(offlineBook());
    const first = harness(removed, []);
    first.deps.verify = async () => {
      await removed.remove("5", "7");
      return { kind: "verified", csrf: "token" };
    };
    await syncPlaces(first.deps);
    expect(first.writes).toEqual([]);

    globalThis.indexedDB = new IDBFactory();
    const moved = await storeWith(offlineBook());
    const places = new DevicePlaces(moved, "5", "7", () => undefined, () => NOW);
    const second = harness(moved, [saved(4)]);
    second.deps.verify = async () => {
      places.record({ asset_id: EPUB_ID, locator: locator("newer") }, Date.parse("2026-11-20T11:20:00.000Z"));
      await places.flush();
      return { kind: "verified", csrf: "token" };
    };
    await syncPlaces(second.deps);
    expect(second.writes.map((write) => write.body.locator)).toEqual([locator("newer")]);
  });

  test("a place held for a choice is offered online and opens offline even after the account place is learned", async () => {
    const held = offlineBook({
      accountPlace: { asset_id: EPUB_ID, locator: locator("account"), version: 6, observedAt: null, learnedAt: NOW },
      devicePlace: { ...offlineBook().devicePlace!, upload: { state: "held", reason: "conflict", message: null } },
    });
    expect(openingLocator(held)).toEqual(locator("device"));
    expect(offeredDevicePlace(held, serverProgress({ version: 6, observed_at: null, locator: locator("account") }), NOW)?.locator).toEqual(locator("device"));
    const superseded = offlineBook({ devicePlace: { ...offlineBook().devicePlace!, upload: { state: "superseded", version: 6 } } });
    expect(openingLocator(superseded)).toEqual(locator("account"));
  });
});

describe("fifth review regressions", () => {
  test("a move is based only on the account place known before it, so a checkpoint learned afterwards is never overwritten", async () => {
    const store = await storeWith(offlineBook({ devicePlace: null }));
    let clock = NOW;
    const places = new DevicePlaces(store, "5", "7", () => undefined, () => clock);
    places.record({ asset_id: EPUB_ID, locator: locator("device") }, NOW);
    clock = NOW + 100;
    const checkpoint = serverProgress({ version: 4, locator: locator("checkpoint"), observed_at: null, client_mutation_id: "other-device" });
    await store.updateBook("5", "7", (book) => rememberAccountPlace(book, checkpoint, clock), clock);
    await places.flush();
    expect((await store.book("5", "7"))?.devicePlace?.basedOn).toBe(0);
    const run = harness(store, [conflict(checkpoint)]);
    await syncPlaces(run.deps);
    expect(run.writes.map((write) => write.body.expected_version)).toEqual([0]);
    expect((await store.book("5", "7"))?.devicePlace?.upload).toEqual({ state: "held", reason: "conflict", message: null });
  });

  test("a move made after the account place was learned is based on it", async () => {
    const store = await storeWith(offlineBook({ devicePlace: null }));
    const places = new DevicePlaces(store, "5", "7", () => undefined, () => NOW);
    places.record({ asset_id: EPUB_ID, locator: locator("device") }, NOW);
    await places.flush();
    expect((await store.book("5", "7"))?.devicePlace?.basedOn).toBe(3);
  });

  test("a request stored without the version it was based on is sent on version 0 with its own identity and time", async () => {
    const request: ProgressRequest = { asset_id: EPUB_ID, locator: locator("device"), observed_at: OFFLINE_AT, expected_version: 4, client_mutation_id: "stored-earlier" };
    const store = await storeWith(offlineBook({ devicePlace: { asset_id: EPUB_ID, locator: locator("device"), observedAt: OFFLINE_AT, recordedAt: NOW - 1000, upload: { state: "pending", request, rebases: 0 } } }));
    const run = harness(store, [saved(5)]);
    await syncPlaces(run.deps);
    expect(run.writes.map((write) => [write.body.expected_version, write.body.client_mutation_id, write.body.observed_at])).toEqual([[0, "stored-earlier", OFFLINE_AT]]);
  });

  test("an answer that rules out only one account releases only that account's record, and only up to when it was asked", async () => {
    const store = await storeWith(offlineBook());
    expect(await store.release(NOW, "4")).toBe(false);
    expect((await store.accountState()).record?.account).toBe("5");
    expect(await store.release(NOW - 2 * DAY, "5")).toBe(false);
    expect(await store.release(NOW, "5")).toBe(true);
  });
});
