import type { Locator, ReaderAsset, ReaderPublication, StoredProgress } from "../contract";

export const BOOK_LIMIT_BYTES = 32 * 1024 * 1024;
export const ACCOUNT_LIMIT_BYTES = 256 * 1024 * 1024;
export const RESERVE_BYTES = 32 * 1024 * 1024;
export const CLOCK_TOLERANCE_MS = 5 * 60_000;

export type ConfirmedAccount = { account: string; confirmedAt: number; validForMs: number; seenAt?: number };
export type AccountState = { record: ConfirmedAccount | null; generation: number };

export type SavedAsset = { id: string; filename: string; media_type: string; size_bytes: number };
export type AccountPlace = { asset_id: string; locator: Locator; version: number; observedAt: string | null; learnedAt: number };
export type DevicePlace = { asset_id: string; locator: Locator; observedAt: string; recordedAt: number };

export type SavedBook = {
  key: string;
  account: string;
  id: string;
  title: string;
  author: string | null;
  asset: SavedAsset;
  savedAt: number;
  accountPlace: AccountPlace | null;
  devicePlace: DevicePlace | null;
};

export type FailureKind = "network" | "signed_out" | "changed" | "missing" | "space" | "too_large" | "storage" | "worker" | "busy" | "unsupported" | "removed";

export type Attempt = { key: string; account: string; id: string; title: string; assetId: string; token: string; startedAt: number; failure: FailureKind | null };

export type CommitOutcome = "saved" | "account" | "removed" | "space";
export type UpdateOutcome = "updated" | "unchanged" | "refused";

export type OfflineStore = {
  exists(): Promise<boolean>;
  prepare(): Promise<void>;
  accountState(): Promise<AccountState>;
  confirm(value: ConfirmedAccount, generation: number): Promise<boolean>;
  release(generation: number): Promise<boolean>;
  forget(account?: string): Promise<void>;
  touch(account: string, now: number): Promise<boolean>;
  books(account: string): Promise<SavedBook[]>;
  book(account: string, id: string): Promise<SavedBook | null>;
  open(account: string, id: string): Promise<{ book: SavedBook; blob: Blob } | null>;
  attempts(account: string): Promise<Attempt[]>;
  begin(attempt: Attempt): Promise<void>;
  fail(account: string, id: string, failure: FailureKind): Promise<void>;
  commit(book: SavedBook, blob: Blob, token: string, now: number): Promise<CommitOutcome>;
  updateBook(account: string, id: string, change: (book: SavedBook) => SavedBook | null, now: number): Promise<UpdateOutcome>;
  remove(account: string, id: string): Promise<void>;
  others(account: string): Promise<{ books: number; bytes: number }>;
  removeOthers(account: string): Promise<void>;
};

export const bookKey = (account: string, id: string): string => `${account}|${id}`;

export function usable(record: ConfirmedAccount | null, account: string | null, now: number): record is ConfirmedAccount {
  if (!record || (account !== null && record.account !== account)) return false;
  const latestSeen = Math.max(record.confirmedAt, record.seenAt ?? record.confirmedAt);
  return now >= latestSeen - CLOCK_TOLERANCE_MS && now < record.confirmedAt + record.validForMs;
}

export function offlineUntil(record: ConfirmedAccount): number {
  return record.confirmedAt + record.validForMs;
}

export function savedEpub(publication: ReaderPublication): ReaderAsset | null {
  const epubs = publication.assets.filter((asset) => asset.format === "epub");
  return epubs.find((asset) => asset.id === publication.progress?.asset_id) ?? epubs[0] ?? null;
}

export function accountPlaceOf(progress: StoredProgress | null, learnedAt: number): AccountPlace | null {
  if (!progress?.locator) return null;
  return { asset_id: progress.asset_id, locator: progress.locator, version: progress.version, observedAt: progress.observed_at, learnedAt };
}

export function rememberAccountPlace(book: SavedBook, progress: StoredProgress | null, now: number): SavedBook {
  const place = accountPlaceOf(progress, now);
  if (!place || (book.accountPlace && book.accountPlace.version >= place.version)) return book;
  return { ...book, accountPlace: place };
}

export function deviceIsLater(device: DevicePlace, account: Pick<AccountPlace, "observedAt" | "learnedAt"> | null): boolean {
  if (!account) return true;
  const theirs = account.observedAt === null ? Number.NaN : Date.parse(account.observedAt);
  return Number.isFinite(theirs) ? Date.parse(device.observedAt) > theirs : device.recordedAt > account.learnedAt;
}

export function laterDevicePlace(book: SavedBook): DevicePlace | null {
  const device = book.devicePlace;
  if (!device || device.asset_id !== book.asset.id) return null;
  return deviceIsLater(device, book.accountPlace) ? device : null;
}

export function openingLocator(book: SavedBook): Locator | null {
  const device = laterDevicePlace(book);
  if (device) return device.locator;
  const account = book.accountPlace;
  if (account?.asset_id === book.asset.id) return account.locator;
  return book.devicePlace?.asset_id === book.asset.id ? book.devicePlace.locator : null;
}

export function describeLocator(locator: Locator | null): string {
  const total = locator?.locations?.totalProgression;
  return typeof total === "number" && Number.isFinite(total) ? `${Math.round(Math.min(1, Math.max(0, total)) * 100)}% through` : "a saved place";
}
