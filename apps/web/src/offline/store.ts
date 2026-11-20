import { bookKey, usable, type Attempt, type ConfirmedAccount, type FailureKind, type OfflineStore, type SavedBook } from "./model";

export const DATABASE_NAME = "shelfarr-go-preview-offline";
const DATABASE_VERSION = 1;
const ACCOUNT_KEY = "current";

type StoredFile = { key: string; account: string; assetId: string; blob: Blob };
type StoredAccount = ConfirmedAccount & { id: typeof ACCOUNT_KEY };
type StoreName = "account" | "books" | "files" | "attempts";

function completed<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export class IndexedDbOfflineStore implements OfflineStore {
  private opened: Promise<IDBDatabase> | null = null;

  async exists(): Promise<boolean> {
    if (this.opened) return true;
    if (typeof indexedDB.databases !== "function") return true;
    return (await indexedDB.databases()).some((database) => database.name === DATABASE_NAME);
  }

  async account(): Promise<ConfirmedAccount | null> {
    if (!(await this.exists())) return null;
    const stored = await this.run(["account"], "readonly", (stores) => completed<StoredAccount | undefined>(stores.account.get(ACCOUNT_KEY)));
    return stored ? { account: stored.account, confirmedAt: stored.confirmedAt, validForMs: stored.validForMs } : null;
  }

  confirm(value: ConfirmedAccount): Promise<void> {
    return this.run(["account"], "readwrite", async (stores) => {
      await completed(stores.account.put({ id: ACCOUNT_KEY, ...value }));
    });
  }

  async forget(account?: string): Promise<void> {
    if (!(await this.exists())) return;
    await this.run(["account"], "readwrite", async (stores) => {
      const stored = await completed<StoredAccount | undefined>(stores.account.get(ACCOUNT_KEY));
      if (stored && (account === undefined || stored.account === account)) await completed(stores.account.delete(ACCOUNT_KEY));
    });
  }

  async books(account: string): Promise<SavedBook[]> {
    if (!(await this.exists())) return [];
    const books = await this.run(["books"], "readonly", (stores) => completed<SavedBook[]>(stores.books.index("account").getAll(account)));
    return books.sort((left, right) => right.savedAt - left.savedAt);
  }

  async book(account: string, id: string): Promise<SavedBook | null> {
    if (!(await this.exists())) return null;
    return (await this.run(["books"], "readonly", (stores) => completed<SavedBook | undefined>(stores.books.get(bookKey(account, id))))) ?? null;
  }

  async file(account: string, id: string): Promise<Blob | null> {
    if (!(await this.exists())) return null;
    return this.run(["books", "files"], "readonly", async (stores) => {
      const key = bookKey(account, id);
      const book = await completed<SavedBook | undefined>(stores.books.get(key));
      const file = await completed<StoredFile | undefined>(stores.files.get(key));
      if (!book || !file || file.account !== account || file.assetId !== book.asset.id || file.blob.size !== book.asset.size_bytes) return null;
      return file.blob;
    });
  }

  async attempts(account: string): Promise<Attempt[]> {
    if (!(await this.exists())) return [];
    return this.run(["attempts"], "readonly", (stores) => completed<Attempt[]>(stores.attempts.index("account").getAll(account)));
  }

  begin(attempt: Attempt): Promise<void> {
    return this.run(["attempts"], "readwrite", async (stores) => {
      await completed(stores.attempts.put(attempt));
    });
  }

  fail(account: string, id: string, failure: FailureKind): Promise<void> {
    return this.run(["attempts"], "readwrite", async (stores) => {
      const key = bookKey(account, id);
      const current = await completed<Attempt | undefined>(stores.attempts.get(key));
      if (current) await completed(stores.attempts.put({ ...current, failure }));
    });
  }

  commit(book: SavedBook, blob: Blob, now: number): Promise<boolean> {
    return this.run(["account", "books", "files", "attempts"], "readwrite", async (stores) => {
      const current = await completed<StoredAccount | undefined>(stores.account.get(ACCOUNT_KEY));
      if (!usable(current ?? null, book.account, now)) return false;
      await completed(stores.files.put({ key: book.key, account: book.account, assetId: book.asset.id, blob } satisfies StoredFile));
      await completed(stores.books.put(book));
      await completed(stores.attempts.delete(book.key));
      return true;
    });
  }

  updateBook(account: string, id: string, change: (book: SavedBook) => SavedBook, now: number): Promise<boolean> {
    return this.run(["account", "books"], "readwrite", async (stores) => {
      const current = await completed<StoredAccount | undefined>(stores.account.get(ACCOUNT_KEY));
      const book = await completed<SavedBook | undefined>(stores.books.get(bookKey(account, id)));
      if (!usable(current ?? null, account, now) || !book) return false;
      await completed(stores.books.put(change(book)));
      return true;
    });
  }

  remove(account: string, id: string): Promise<void> {
    return this.run(["books", "files", "attempts"], "readwrite", async (stores) => {
      const key = bookKey(account, id);
      await completed(stores.files.delete(key));
      await completed(stores.books.delete(key));
      await completed(stores.attempts.delete(key));
    });
  }

  async others(account: string): Promise<{ books: number; bytes: number }> {
    if (!(await this.exists())) return { books: 0, bytes: 0 };
    const books = await this.run(["books"], "readonly", (stores) => completed<SavedBook[]>(stores.books.getAll()));
    const foreign = books.filter((book) => book.account !== account);
    return { books: foreign.length, bytes: foreign.reduce((sum, book) => sum + book.asset.size_bytes, 0) };
  }

  removeOthers(account: string): Promise<void> {
    return this.run(["books", "files", "attempts"], "readwrite", async (stores) => {
      for (const name of ["books", "files", "attempts"] as const) {
        const keys = await completed(stores[name].getAllKeys());
        for (const key of keys) if (typeof key === "string" && !key.startsWith(`${account}|`)) await completed(stores[name].delete(key));
      }
    });
  }

  private database(): Promise<IDBDatabase> {
    this.opened ??= new Promise((resolve, reject) => {
      const request = indexedDB.open(DATABASE_NAME, DATABASE_VERSION);
      request.onupgradeneeded = () => {
        const database = request.result;
        database.createObjectStore("account", { keyPath: "id" });
        database.createObjectStore("books", { keyPath: "key" }).createIndex("account", "account");
        database.createObjectStore("files", { keyPath: "key" });
        database.createObjectStore("attempts", { keyPath: "key" }).createIndex("account", "account");
      };
      request.onsuccess = () => {
        const database = request.result;
        database.onversionchange = () => {
          database.close();
          this.opened = null;
        };
        resolve(database);
      };
      request.onerror = () => {
        this.opened = null;
        reject(request.error);
      };
      request.onblocked = () => {
        this.opened = null;
        reject(new DOMException("The saved books are open in an older tab", "InvalidStateError"));
      };
    });
    return this.opened;
  }

  private async run<T>(names: StoreName[], mode: IDBTransactionMode, work: (stores: Record<StoreName, IDBObjectStore>) => Promise<T>): Promise<T> {
    const database = await this.database();
    return new Promise<T>((resolve, reject) => {
      const transaction = database.transaction(names, mode, { durability: "strict" });
      const stores = Object.fromEntries(names.map((name) => [name, transaction.objectStore(name)])) as Record<StoreName, IDBObjectStore>;
      let result: T;
      work(stores).then(
        (value) => {
          result = value;
        },
        (error: unknown) => {
          try {
            transaction.abort();
          } catch {
            reject(error);
          }
          reject(error);
        },
      );
      transaction.oncomplete = () => resolve(result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error ?? new DOMException("The saved books could not be changed", "AbortError"));
    });
  }
}

export const offlineStore: OfflineStore = new IndexedDbOfflineStore();
