import type { ProgressAnswer } from "../api/client";
import { isApiError } from "../api/errors";
import type { ProgressRequest, StoredProgress } from "../contract";
import { plausibleObservedAt, samePlace } from "../reader/shared";
import { rememberAccountPlace, unsentPlace, type OfflineStore, type SavedBook, type Upload } from "./model";

export const MAX_REBASES = 5;
export const RETRY_DELAYS_MS = [2_000, 5_000, 15_000, 30_000, 60_000] as const;

export type Verification = { kind: "verified"; csrf: string } | { kind: "retry" } | { kind: "stop" };
export type SyncResult = { kind: "idle" } | { kind: "settled" } | { kind: "retry" } | { kind: "stop" };

export type SyncDeps = {
  store: OfflineStore;
  account: string;
  verify: () => Promise<Verification>;
  write: (id: string, body: ProgressRequest, csrf: string) => Promise<ProgressAnswer>;
  now?: () => number;
  uuid?: () => string;
};

type Decision = { kind: "rebase" } | { kind: "settle"; upload: Upload };

export function reconcileOffline(request: ProgressRequest, remote: StoredProgress | null, assetId: string, rebases: number, now: number): Decision {
  if (remote && remote.client_mutation_id === request.client_mutation_id) return { kind: "settle", upload: { state: "synced", version: remote.version } };
  const localTime = plausibleObservedAt(request.observed_at, now);
  const remoteTime = remote ? plausibleObservedAt(remote.observed_at, now) : null;
  const mappable = !remote || remote.asset_id === assetId;
  if (rebases < MAX_REBASES && mappable && localTime !== null) {
    if (!remote || (remoteTime !== null && localTime > remoteTime)) return { kind: "rebase" };
    if (remote && samePlace(request, remote)) return { kind: "settle", upload: { state: "synced", version: remote.version } };
    if (remote && remoteTime !== null && remoteTime > localTime) return { kind: "settle", upload: { state: "superseded", version: remote.version } };
  }
  return { kind: "settle", upload: { state: "held", reason: "conflict", message: null } };
}

function isCurrent(book: SavedBook, mutation: string): boolean {
  const upload = book.devicePlace?.upload;
  return upload?.state === "pending" && upload.request?.client_mutation_id === mutation;
}

function newUuid(): string {
  return crypto.randomUUID();
}

export async function syncPlaces(deps: SyncDeps): Promise<SyncResult> {
  const { store, account } = deps;
  const now = deps.now ?? Date.now;
  const uuid = deps.uuid ?? newUuid;
  const waiting = (await store.books(account)).filter((book) => unsentPlace(book));
  if (waiting.length === 0) return { kind: "idle" };
  let transient = false;
  for (const listed of waiting) {
    const outcome = await syncBook(deps, listed.id, now, uuid);
    if (outcome === "stop") return { kind: "stop" };
    if (outcome === "retry") transient = true;
  }
  return transient ? { kind: "retry" } : { kind: "settled" };
}

async function prepare(deps: SyncDeps, id: string, now: () => number, uuid: () => string): Promise<{ request: ProgressRequest; rebases: number; assetId: string } | null> {
  const prepared: { value: { request: ProgressRequest; rebases: number; assetId: string } | null } = { value: null };
  await deps.store.updateBook(
    deps.account,
    id,
    (book) => {
      const device = unsentPlace(book);
      if (!device) return null;
      const known = book.accountPlace;
      if (!device.upload.request && known && known.asset_id === device.asset_id && samePlace({ asset_id: device.asset_id, locator: device.locator }, { asset_id: known.asset_id, locator: known.locator })) {
        return { ...book, devicePlace: { ...device, upload: { state: "synced", version: known.version } } };
      }
      const request: ProgressRequest = device.upload.request ?? {
        asset_id: device.asset_id,
        locator: device.locator,
        observed_at: device.observedAt,
        expected_version: known?.version ?? 0,
        client_mutation_id: uuid(),
      };
      prepared.value = { request, rebases: device.upload.rebases, assetId: device.asset_id };
      return device.upload.request ? null : { ...book, devicePlace: { ...device, upload: { state: "pending", request, rebases: device.upload.rebases } } };
    },
    now(),
  );
  return prepared.value;
}

async function settle(deps: SyncDeps, id: string, mutation: string, upload: Upload | null, learned: StoredProgress | null, now: number): Promise<void> {
  await deps.store.updateBook(
    deps.account,
    id,
    (book) => {
      const known = rememberAccountPlace(book, learned, now);
      if (!upload || !isCurrent(book, mutation) || !book.devicePlace) return known;
      return { ...known, devicePlace: { ...book.devicePlace, upload } };
    },
    now,
  );
}

async function rebase(deps: SyncDeps, id: string, request: ProgressRequest, remote: StoredProgress | null, rebases: number, uuid: () => string, now: number): Promise<void> {
  await deps.store.updateBook(
    deps.account,
    id,
    (book) => {
      const known = rememberAccountPlace(book, remote, now);
      if (!isCurrent(book, request.client_mutation_id) || !book.devicePlace) return known;
      const next: ProgressRequest = { ...request, expected_version: remote?.version ?? 0, client_mutation_id: uuid() };
      return { ...known, devicePlace: { ...book.devicePlace, upload: { state: "pending", request: next, rebases: rebases + 1 } } };
    },
    now,
  );
}

async function syncBook(deps: SyncDeps, id: string, now: () => number, uuid: () => string): Promise<"done" | "retry" | "stop"> {
  for (;;) {
    const prepared = await prepare(deps, id, now, uuid);
    if (!prepared) return "done";
    const { request, rebases, assetId } = prepared;
    const verified = await deps.verify();
    if (verified.kind !== "verified") return verified.kind;
    let answer: ProgressAnswer;
    try {
      answer = await deps.write(id, request, verified.csrf);
    } catch (error) {
      if (isApiError(error) && (error.kind === "signed_out" || error.kind === "account_changed")) return "stop";
      if (isApiError(error) && (error.kind === "invalid" || error.kind === "not_found")) {
        await settle(deps, id, request.client_mutation_id, { state: "held", reason: "rejected", message: error.message || null }, null, now());
        return "done";
      }
      return "retry";
    }
    if (answer.kind === "saved") {
      await settle(deps, id, request.client_mutation_id, { state: "synced", version: answer.progress.version }, answer.progress, now());
      continue;
    }
    const decision = reconcileOffline(request, answer.progress, assetId, rebases, now());
    if (decision.kind === "rebase") {
      await rebase(deps, id, request, answer.progress, rebases, uuid, now());
      continue;
    }
    await settle(deps, id, request.client_mutation_id, decision.upload, answer.progress, now());
  }
}

export type SyncRunner = { request: () => void; stop: () => void; subscribe: (listener: () => void) => () => void };

export function createSyncRunner(deps: SyncDeps, locks: Pick<LockManager, "request"> | undefined, delays: readonly number[] = RETRY_DELAYS_MS): SyncRunner {
  const listeners = new Set<() => void>();
  let running = false;
  let again = false;
  let stopped = false;
  let failures = 0;
  let timer: ReturnType<typeof setTimeout> | null = null;
  const notify = () => {
    for (const listener of [...listeners]) listener();
  };
  const once = async (): Promise<SyncResult> => {
    if (!locks) return syncPlaces(deps);
    const result = await locks.request(`shelfarr-go-preview-offline-sync|${deps.account}`, { ifAvailable: true }, (lock) => (lock ? syncPlaces(deps) : ({ kind: "retry" } as const)));
    return result as SyncResult;
  };
  const run = async (): Promise<void> => {
    if (stopped) return;
    if (running) {
      again = true;
      return;
    }
    running = true;
    if (timer) clearTimeout(timer);
    timer = null;
    let result: SyncResult;
    try {
      result = await once();
    } catch {
      result = { kind: "retry" };
    }
    running = false;
    notify();
    if (result.kind === "stop") {
      stopped = true;
      return;
    }
    if (result.kind === "retry") {
      const delay = delays[Math.min(failures, delays.length - 1)] ?? 60_000;
      failures += 1;
      if (!stopped) timer = setTimeout(() => void run(), delay);
    } else failures = 0;
    if (again) {
      again = false;
      void run();
    }
  };
  return {
    request: () => void run(),
    stop: () => {
      stopped = true;
      if (timer) clearTimeout(timer);
      timer = null;
    },
    subscribe: (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}
