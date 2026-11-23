import {
  ACCOUNT_LIMIT_BYTES,
  bookKey,
  mergeSaved,
  usable,
  type AccountState,
  type Attempt,
  type CommitOutcome,
  type ConfirmedAccount,
  type FailureKind,
  type OfflineStore,
  type SavedBook,
  type UpdateOutcome,
} from "./model";

export const DATABASE_NAME = "shelfarr-go-preview-offline";
const DEFAULT_MOUNT = "/preview";
const DATABASE_VERSION = 1;
const ACCOUNT_KEY = "current";

type StoredFile = { key: string; account: string; assetId: string; blob: Blob };
type StoredAccount = { id: typeof ACCOUNT_KEY; record: ConfirmedAccount | null; clearedAt: number };
type StoreName = "account" | "books" | "files" | "attempts";
type Stores = Record<StoreName, IDBObjectStore>;

function completed<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

type Continuity = () => string | null;

async function readAccount(stores: Stores, continuity: Continuity | null): Promise<AccountState> {
  const stored = await completed<StoredAccount | undefined>(stores.account.get(ACCOUNT_KEY));
  const record = stored?.record ?? null;
  return { record: record && continuous(record, continuity) ? record : null, clearedAt: stored?.clearedAt ?? 0 };
}

export function continuous(record: ConfirmedAccount, continuity: Continuity | null): boolean {
  return continuity === null || (record.continuity ?? null) === continuity();
}

export function cookieValue(cookies: string, name: string): string | null {
  for (const pair of cookies.split(";")) {
    const separator = pair.indexOf("=");
    if (separator >= 0 && pair.slice(0, separator).trim() === name) return pair.slice(separator + 1).trim() || null;
  }
  return null;
}

function writeAccount(stores: Stores, state: AccountState): Promise<IDBValidKey> {
  return completed(stores.account.put({ id: ACCOUNT_KEY, record: state.record, clearedAt: state.clearedAt } satisfies StoredAccount));
}

export function confirmedState(current: AccountState, value: ConfirmedAccount): AccountState | null {
  if (value.confirmedAt <= current.clearedAt || (current.record !== null && current.record.confirmedAt > value.confirmedAt)) return null;
  return { record: { ...value, seenAt: Math.max(current.record?.seenAt ?? 0, value.seenAt ?? 0, value.confirmedAt) }, clearedAt: current.clearedAt };
}

export function releasedState(current: AccountState, askedAt: number): AccountState {
  const record = current.record !== null && current.record.confirmedAt <= askedAt ? null : current.record;
  return { record, clearedAt: Math.max(current.clearedAt, askedAt) };
}

export function databaseNameFor(mount: string): string {
  return mount === DEFAULT_MOUNT ? DATABASE_NAME : `${DATABASE_NAME}|${mount}`;
}

export class IndexedDbOfflineStore implements OfflineStore {
  private opened: Promise<IDBDatabase> | null = null;
  private readonly name: string;
  private readonly continuity: Continuity | null;

  constructor(name: string = DATABASE_NAME, continuity: Continuity | null = null) {
    this.name = name;
    this.continuity = continuity;
  }

  async exists(): Promise<boolean> {
    if (this.opened) return true;
    if (typeof indexedDB.databases !== "function") return true;
    return (await indexedDB.databases()).some((database) => database.name === this.name);
  }

  async prepare(): Promise<void> {
    await this.database();
  }

  async accountState(): Promise<AccountState> {
    if (!(await this.exists())) return { record: null, clearedAt: 0 };
    return this.run(["account"], "readonly", (stores) => readAccount(stores, this.continuity));
  }

  async confirm(value: ConfirmedAccount): Promise<boolean> {
    if (!continuous(value, this.continuity)) return false;
    return this.run(["account"], "readwrite", async (stores) => {
      const next = confirmedState(await readAccount(stores, this.continuity), value);
      if (!next || !continuous(value, this.continuity)) return false;
      await writeAccount(stores, next);
      return true;
    });
  }

  async release(askedAt: number): Promise<boolean> {
    if (!(await this.exists())) return true;
    return this.run(["account"], "readwrite", async (stores) => {
      const next = releasedState(await readAccount(stores, null), askedAt);
      await writeAccount(stores, next);
      return next.record === null;
    });
  }

  async forget(account?: string, at: number = Date.now()): Promise<void> {
    if (!(await this.exists())) return;
    await this.run(["account"], "readwrite", async (stores) => {
      const current = await readAccount(stores, this.continuity);
      if (account !== undefined && current.record?.account !== account) return;
      await writeAccount(stores, { record: null, clearedAt: Math.max(current.clearedAt, at, current.record?.confirmedAt ?? 0) });
    });
  }

  touch(account: string, now: number): Promise<boolean> {
    return this.run(["account"], "readwrite", async (stores) => {
      const current = await readAccount(stores, this.continuity);
      const record = current.record;
      const ownedSince = record?.account === account ? record.confirmedAt : null;
      if (!usable(record, account, now)) {
        if (ownedSince !== null) await writeAccount(stores, { record: null, clearedAt: Math.max(current.clearedAt, ownedSince) });
        return false;
      }
      if (now > (record.seenAt ?? 0)) await writeAccount(stores, { record: { ...record, seenAt: now }, clearedAt: current.clearedAt });
      return true;
    });
  }

  async books(account: string): Promise<SavedBook[]> {
    if (!(await this.exists())) return [];
    const books = await this.owned(account, ["books"], [], (stores) => completed<SavedBook[]>(stores.books.index("account").getAll(account)));
    return books.sort((left, right) => right.savedAt - left.savedAt);
  }

  async book(account: string, id: string): Promise<SavedBook | null> {
    if (!(await this.exists())) return null;
    return (await this.owned(account, ["books"], undefined, (stores) => completed<SavedBook | undefined>(stores.books.get(bookKey(account, id))))) ?? null;
  }

  async open(account: string, id: string): Promise<{ book: SavedBook; blob: Blob } | null> {
    if (!(await this.exists())) return null;
    return this.owned(account, ["books", "files"], null, async (stores) => {
      const key = bookKey(account, id);
      const book = await completed<SavedBook | undefined>(stores.books.get(key));
      const file = await completed<StoredFile | undefined>(stores.files.get(key));
      if (!book || !file || book.account !== account || file.account !== account || file.assetId !== book.asset.id || file.blob.size !== book.asset.size_bytes) return null;
      return { book, blob: file.blob };
    });
  }

  async attempts(account: string): Promise<Attempt[]> {
    if (!(await this.exists())) return [];
    return this.owned(account, ["attempts"], [], (stores) => completed<Attempt[]>(stores.attempts.index("account").getAll(account)));
  }

  begin(attempt: Attempt): Promise<void> {
    return this.run(["attempts"], "readwrite", async (stores) => {
      await completed(stores.attempts.put(attempt));
    });
  }

  fail(account: string, id: string, failure: FailureKind): Promise<void> {
    return this.run(["attempts"], "readwrite", async (stores) => {
      const current = await completed<Attempt | undefined>(stores.attempts.get(bookKey(account, id)));
      if (current) await completed(stores.attempts.put({ ...current, failure }));
    });
  }

  commit(book: SavedBook, blob: Blob, token: string, now: number): Promise<CommitOutcome> {
    return this.run(["account", "books", "files", "attempts"], "readwrite", async (stores): Promise<CommitOutcome> => {
      if (!usable((await readAccount(stores, this.continuity)).record, book.account, now)) return "account";
      const attempt = await completed<Attempt | undefined>(stores.attempts.get(book.key));
      if (!attempt || attempt.token !== token || attempt.assetId !== book.asset.id) return "removed";
      const saved = await completed<SavedBook[]>(stores.books.index("account").getAll(book.account));
      const others = saved.filter((other) => other.key !== book.key).reduce((sum, other) => sum + other.asset.size_bytes, 0);
      if (others + book.asset.size_bytes > ACCOUNT_LIMIT_BYTES) return "space";
      const current = await completed<SavedBook | undefined>(stores.books.get(book.key));
      await completed(stores.files.put({ key: book.key, account: book.account, assetId: book.asset.id, blob } satisfies StoredFile));
      await completed(stores.books.put(mergeSaved(current ?? null, book)));
      await completed(stores.attempts.delete(book.key));
      return "saved";
    });
  }

  updateBook(account: string, id: string, change: (book: SavedBook) => SavedBook | null, now: number): Promise<UpdateOutcome> {
    return this.run(["account", "books"], "readwrite", async (stores): Promise<UpdateOutcome> => {
      const book = await completed<SavedBook | undefined>(stores.books.get(bookKey(account, id)));
      if (!usable((await readAccount(stores, this.continuity)).record, account, now) || !book) return "refused";
      const next = change(book);
      if (!next || next === book) return "unchanged";
      await completed(stores.books.put(next));
      return "updated";
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

  private async owned<T>(account: string, names: StoreName[], hidden: T, read: (stores: Stores) => Promise<T>): Promise<T> {
    const continuity = this.continuity;
    if (continuity === null) return this.run(names, "readonly", read);
    const { value, record } = await this.run([...names, "account"], "readonly", async (stores) => {
      const found = await read(stores);
      const stored = await completed<StoredAccount | undefined>(stores.account.get(ACCOUNT_KEY));
      return { value: found, record: stored?.record ?? null };
    });
    return record?.account === account && continuous(record, continuity) ? value : hidden;
  }

  private database(): Promise<IDBDatabase> {
    this.opened ??= new Promise((resolve, reject) => {
      const request = indexedDB.open(this.name, DATABASE_VERSION);
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

  private async run<T>(names: StoreName[], mode: IDBTransactionMode, work: (stores: Stores) => Promise<T>): Promise<T> {
    const database = await this.database();
    return new Promise<T>((resolve, reject) => {
      const transaction = database.transaction(names, mode, { durability: "strict" });
      const stores = Object.fromEntries(names.map((name) => [name, transaction.objectStore(name)])) as Stores;
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

const stores = new Map<string, OfflineStore>();

export function offlineStoreFor(mount: string, continuityCookie?: string): OfflineStore {
  const name = databaseNameFor(mount);
  const known = stores.get(name);
  if (known) return known;
  const created = new IndexedDbOfflineStore(name, continuityCookie === undefined ? null : () => cookieValue(document.cookie, continuityCookie));
  stores.set(name, created);
  return created;
}
