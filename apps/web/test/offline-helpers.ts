import type { ReaderAsset, ReaderPublication, StoredProgress } from "../src/contract";
import { bookKey, usable, type Attempt, type ConfirmedAccount, type FailureKind, type OfflineStore, type SavedBook } from "../src/offline/model";

export const EPUB_ID = "e".repeat(64);
export const NEWER_ID = "f".repeat(64);
export const DAY = 86_400_000;

export class MemoryOfflineStore implements OfflineStore {
  record: ConfirmedAccount | null = null;
  readonly saved = new Map<string, SavedBook>();
  readonly files = new Map<string, { assetId: string; blob: Blob }>();
  readonly attemptRecords = new Map<string, Attempt>();
  forgets: (string | undefined)[] = [];
  confirms: ConfirmedAccount[] = [];
  beforeCommit: (() => void) | null = null;
  failCommit: Error | null = null;

  async exists() {
    return true;
  }
  async account() {
    return this.record;
  }
  async confirm(value: ConfirmedAccount) {
    this.confirms.push(value);
    this.record = value;
  }
  async forget(account?: string) {
    this.forgets.push(account);
    if (this.record && (account === undefined || this.record.account === account)) this.record = null;
  }
  async books(account: string) {
    return [...this.saved.values()].filter((book) => book.account === account);
  }
  async book(account: string, id: string) {
    return this.saved.get(bookKey(account, id)) ?? null;
  }
  async file(account: string, id: string) {
    const book = this.saved.get(bookKey(account, id));
    const file = this.files.get(bookKey(account, id));
    return book && file && file.assetId === book.asset.id ? file.blob : null;
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
  async commit(book: SavedBook, blob: Blob, now: number) {
    this.beforeCommit?.();
    if (this.failCommit) throw this.failCommit;
    if (!usable(this.record, book.account, now)) return false;
    this.files.set(book.key, { assetId: book.asset.id, blob });
    this.saved.set(book.key, book);
    this.attemptRecords.delete(book.key);
    return true;
  }
  async updateBook(account: string, id: string, change: (book: SavedBook) => SavedBook, now: number) {
    const book = this.saved.get(bookKey(account, id));
    if (!usable(this.record, account, now) || !book) return false;
    this.saved.set(book.key, change(book));
    return true;
  }
  async remove(account: string, id: string) {
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

export function epubBytes(size: number): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(size);
  bytes.set([0x50, 0x4b, 0x03, 0x04]);
  return bytes;
}

export function asset(overrides: Partial<ReaderAsset> = {}): ReaderAsset {
  return { id: EPUB_ID, filename: "Book.epub", format: "epub", media_type: "application/epub+zip", size_bytes: 64, position: 0, url: `/preview/api/v1/accounts/5/library/7/assets/${EPUB_ID}`, ...overrides };
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
    asset: { id: EPUB_ID, filename: "Book.epub", media_type: "application/epub+zip", size_bytes: 64 },
    savedAt: 1_000,
    accountPlace: null,
    devicePlace: null,
    ...overrides,
  };
}
