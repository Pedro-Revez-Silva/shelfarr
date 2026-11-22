import type { ReaderAsset, ReaderPublication, StoredProgress } from "../src/contract";
import { confirmedState, releasedState } from "../src/offline/store";
import { ACCOUNT_LIMIT_BYTES, bookKey, mergeSaved, usable, type Attempt, type CommitOutcome, type ConfirmedAccount, type FailureKind, type OfflineStore, type SavedBook, type UpdateOutcome } from "../src/offline/model";

export const EPUB_ID = "e".repeat(64);
export const NEWER_ID = "f".repeat(64);
export const DAY = 86_400_000;

export class MemoryOfflineStore implements OfflineStore {
  record: ConfirmedAccount | null = null;
  clearedAt = 0;
  readonly saved = new Map<string, SavedBook>();
  readonly files = new Map<string, { assetId: string; blob: Blob }>();
  readonly attemptRecords = new Map<string, Attempt>();
  forgets: (string | undefined)[] = [];
  confirms: ConfirmedAccount[] = [];
  beforeCommit: (() => void) | null = null;
  failCommit: Error | null = null;
  failRemove: Error | null = null;

  async exists() {
    return true;
  }
  async prepare() {}
  async accountState() {
    return { record: this.record, clearedAt: this.clearedAt };
  }
  async confirm(value: ConfirmedAccount) {
    const next = confirmedState({ record: this.record, clearedAt: this.clearedAt }, value);
    if (!next) return false;
    this.confirms.push(value);
    this.record = next.record;
    return true;
  }
  async release(askedAt: number, account?: string) {
    const next = releasedState({ record: this.record, clearedAt: this.clearedAt }, askedAt, account);
    this.record = next.record;
    this.clearedAt = next.clearedAt;
    return this.record === null;
  }
  async forget(account?: string, at: number = Date.now()) {
    this.forgets.push(account);
    if (account !== undefined && this.record?.account !== account) return;
    this.clearedAt = Math.max(this.clearedAt, at, this.record?.confirmedAt ?? 0);
    this.record = null;
  }
  async touch(account: string, now: number) {
    const ownedSince = this.record?.account === account ? this.record.confirmedAt : null;
    if (!usable(this.record, account, now)) {
      if (ownedSince !== null) {
        this.record = null;
        this.clearedAt = Math.max(this.clearedAt, ownedSince);
      }
      return false;
    }
    if (now > (this.record.seenAt ?? 0)) this.record = { ...this.record, seenAt: now };
    return true;
  }
  async books(account: string) {
    return [...this.saved.values()].filter((book) => book.account === account);
  }
  async book(account: string, id: string) {
    return this.saved.get(bookKey(account, id)) ?? null;
  }
  opens = 0;
  async open(account: string, id: string) {
    this.opens += 1;
    const book = this.saved.get(bookKey(account, id));
    const file = this.files.get(bookKey(account, id));
    return book && file && file.assetId === book.asset.id ? { book, blob: file.blob } : null;
  }
  async attempts(account: string) {
    return [...this.attemptRecords.values()].filter((attempt) => attempt.account === account);
  }
  async begin(attempt: Attempt) {
    this.attemptRecords.set(attempt.key, attempt);
  }
  async fail(account: string, id: string, failure: FailureKind) {
    const current = this.attemptRecords.get(bookKey(account, id));
    if (current) this.attemptRecords.set(current.key, { ...current, failure });
  }
  async commit(book: SavedBook, blob: Blob, token: string, now: number): Promise<CommitOutcome> {
    this.beforeCommit?.();
    if (this.failCommit) throw this.failCommit;
    if (!usable(this.record, book.account, now)) return "account";
    const attempt = this.attemptRecords.get(book.key);
    if (!attempt || attempt.token !== token || attempt.assetId !== book.asset.id) return "removed";
    const others = [...this.saved.values()].filter((other) => other.account === book.account && other.key !== book.key).reduce((sum, other) => sum + other.asset.size_bytes, 0);
    if (others + book.asset.size_bytes > ACCOUNT_LIMIT_BYTES) return "space";
    this.files.set(book.key, { assetId: book.asset.id, blob });
    this.saved.set(book.key, mergeSaved(this.saved.get(book.key) ?? null, book));
    this.attemptRecords.delete(book.key);
    return "saved";
  }
  async updateBook(account: string, id: string, change: (book: SavedBook) => SavedBook | null, now: number): Promise<UpdateOutcome> {
    const book = this.saved.get(bookKey(account, id));
    if (!usable(this.record, account, now) || !book) return "refused";
    const next = change(book);
    if (!next || next === book) return "unchanged";
    this.saved.set(book.key, next);
    return "updated";
  }
  async remove(account: string, id: string) {
    if (this.failRemove) throw this.failRemove;
    const key = bookKey(account, id);
    this.saved.delete(key);
    this.files.delete(key);
    this.attemptRecords.delete(key);
  }
  async others(account: string) {
    const foreign = [...this.saved.values()].filter((book) => book.account !== account);
    return { books: foreign.length, bytes: foreign.reduce((sum, book) => sum + book.asset.size_bytes, 0) };
  }
  async removeOthers(account: string) {
    for (const key of [...this.saved.keys()]) if (!key.startsWith(`${account}|`)) await this.remove(key.split("|")[0] ?? "", key.split("|")[1] ?? "");
  }
}

export const SIZE = 256;

export function epubBytes(size: number = SIZE): Uint8Array<ArrayBuffer> {
  const name = new TextEncoder().encode("META-INF/container.xml");
  const bytes = new Uint8Array(size);
  const view = new DataView(bytes.buffer);
  const data = size - (30 + name.length) - (46 + name.length) - 22;
  view.setUint32(0, 0x04034b50, true);
  view.setUint32(18, data, true);
  view.setUint32(22, data, true);
  view.setUint16(26, name.length, true);
  bytes.set(name, 30);
  const central = 30 + name.length + data;
  view.setUint32(central, 0x02014b50, true);
  view.setUint32(central + 20, data, true);
  view.setUint32(central + 24, data, true);
  view.setUint16(central + 28, name.length, true);
  bytes.set(name, central + 46);
  const end = central + 46 + name.length;
  view.setUint32(end, 0x06054b50, true);
  view.setUint16(end + 8, 1, true);
  view.setUint16(end + 10, 1, true);
  view.setUint32(end + 12, end - central, true);
  view.setUint32(end + 16, central, true);
  return bytes;
}

export function asset(overrides: Partial<ReaderAsset> = {}): ReaderAsset {
  return { id: EPUB_ID, filename: "Book.epub", format: "epub", media_type: "application/epub+zip", size_bytes: SIZE, position: 0, url: `/preview/api/v1/accounts/5/library/7/assets/${EPUB_ID}`, ...overrides };
}

export function readerPublication(overrides: Partial<ReaderPublication> = {}): ReaderPublication {
  return { id: "7", title: "Saved Book", author: "A. Writer", book_type: "ebook", content_kind: "book", reading_status: "in_progress", assets: [asset()], other_formats: [], progress: null, ...overrides };
}

export function serverProgress(overrides: Partial<StoredProgress> = {}): StoredProgress {
  return {
    asset_id: EPUB_ID,
    locator: { href: "OEBPS/one.xhtml", type: "application/xhtml+xml", locations: { progression: 0.5, totalProgression: 0.25, cfi: "epubcfi(/6/2!/4/2/1:0)" } },
    position_seconds: null,
    version: 3,
    observed_at: "2026-11-15T11:00:00.000Z",
    updated_at: "2026-11-15T11:00:01.000Z",
    client_mutation_id: "server-3",
    ...overrides,
  };
}

export function savedBook(overrides: Partial<SavedBook> = {}): SavedBook {
  return {
    key: bookKey("5", "7"),
    account: "5",
    id: "7",
    title: "Saved Book",
    author: "A. Writer",
    asset: { id: EPUB_ID, filename: "Book.epub", media_type: "application/epub+zip", size_bytes: SIZE },
    savedAt: 1_000,
    accountPlace: null,
    devicePlace: null,
    ...overrides,
  };
}
