import type { AccountGuard } from "../api/account-guard";
import { isApiError } from "../api/errors";
import { errorEnvelopeSchema, type OfflineBoot, type ReaderPublication } from "../contract";
import {
  ACCOUNT_LIMIT_BYTES,
  BOOK_LIMIT_BYTES,
  RESERVE_BYTES,
  accountPlaceOf,
  bookKey,
  rememberAccountPlace,
  savedEpub,
  type ConfirmedAccount,
  type FailureKind,
  type OfflineStore,
  type SavedBook,
} from "./model";
import { WorkerFailure } from "./worker";

export class SaveFailure extends Error {
  readonly kind: FailureKind;

  constructor(kind: FailureKind) {
    super(kind);
    this.kind = kind;
  }
}

export type SaveInputs = {
  publication: ReaderPublication;
  confirmation: ConfirmedAccount;
  offline: OfflineBoot;
  store: OfflineStore;
  guard: AccountGuard;
  ensureWorker: (offline: OfflineBoot) => Promise<void>;
  estimate: () => Promise<{ quota?: number | undefined; usage?: number | undefined }>;
  locks: Pick<LockManager, "request"> | undefined;
  fetcher?: typeof fetch;
  now?: () => number;
  onProgress?: (received: number, total: number) => void;
};

const ZIP_SIGNATURE = [0x50, 0x4b, 0x03, 0x04];

export const saveLockName = (account: string, id: string): string => `shelfarr-go-preview-offline|${bookKey(account, id)}`;

function classify(error: unknown): FailureKind {
  if (error instanceof SaveFailure) return error.kind;
  if (error instanceof WorkerFailure) return "worker";
  if (isApiError(error)) return error.kind === "signed_out" || error.kind === "account_changed" ? "signed_out" : "network";
  if (error instanceof DOMException && error.name === "QuotaExceededError") return "space";
  if (error instanceof TypeError || (error instanceof DOMException && error.name === "AbortError")) return "network";
  return "storage";
}

async function refusal(response: Response, guard: AccountGuard): Promise<FailureKind> {
  const envelope = errorEnvelopeSchema.safeParse(await response.json().catch(() => null));
  const code = envelope.success ? envelope.data.error : null;
  if (code === "signed_out" || code === "account_changed") {
    guard.lock(code);
    return "signed_out";
  }
  if (response.status === 404) return "missing";
  if (response.status >= 500) return "network";
  return "changed";
}

async function download(url: string, assetId: string, size: number, inputs: SaveInputs): Promise<Blob> {
  const response = await (inputs.fetcher ?? fetch)(url, { credentials: "same-origin", cache: "no-store", redirect: "error", referrerPolicy: "no-referrer" });
  if (response.status !== 200) throw new SaveFailure(await refusal(response, inputs.guard));
  const length = response.headers.get("Content-Length");
  if (response.headers.get("ETag") !== `"${assetId}"` || (length !== null && Number(length) !== size) || !response.body) {
    await response.body?.cancel().catch(() => undefined);
    throw new SaveFailure("changed");
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array<ArrayBuffer>[] = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > size) {
      await reader.cancel().catch(() => undefined);
      throw new SaveFailure("changed");
    }
    chunks.push(value);
    inputs.onProgress?.(received, size);
  }
  const head = chunks[0];
  if (received !== size || !head || ZIP_SIGNATURE.some((byte, index) => head[index] !== byte)) throw new SaveFailure("changed");
  return new Blob(chunks, { type: "application/epub+zip" });
}

async function checkSpace(inputs: SaveInputs, account: string, id: string, size: number): Promise<void> {
  const others = (await inputs.store.books(account)).filter((book) => book.id !== id).reduce((sum, book) => sum + book.asset.size_bytes, 0);
  if (others + size > ACCOUNT_LIMIT_BYTES) throw new SaveFailure("space");
  const { quota, usage } = await inputs.estimate().catch(() => ({ quota: undefined, usage: undefined }));
  if (typeof quota === "number" && typeof usage === "number" && quota - usage < size + RESERVE_BYTES) throw new SaveFailure("space");
}

async function transfer(inputs: SaveInputs, account: string): Promise<void> {
  const { publication, store, guard } = inputs;
  const now = inputs.now ?? Date.now;
  const asset = savedEpub(publication);
  if (!asset) throw new SaveFailure("unsupported");
  const key = bookKey(account, publication.id);
  await store.begin({ key, account, id: publication.id, title: publication.title, assetId: asset.id, startedAt: now(), failure: null });
  try {
    const blob = await download(asset.url, asset.id, asset.size_bytes, inputs);
    guard.assertActive();
    const previous = await store.book(account, publication.id);
    const fresh: SavedBook = {
      key,
      account,
      id: publication.id,
      title: publication.title,
      author: publication.author,
      asset: { id: asset.id, filename: asset.filename, media_type: asset.media_type, size_bytes: asset.size_bytes },
      savedAt: now(),
      accountPlace: accountPlaceOf(publication.progress, now()),
      devicePlace: previous?.devicePlace ?? null,
    };
    const book = previous?.accountPlace ? rememberAccountPlace({ ...fresh, accountPlace: previous.accountPlace }, publication.progress, now()) : fresh;
    if (!(await store.commit(book, blob, now()))) throw new SaveFailure("signed_out");
  } catch (error) {
    const kind = classify(error);
    await store.fail(account, publication.id, kind).catch(() => undefined);
    throw new SaveFailure(kind);
  }
}

export async function saveCopy(inputs: SaveInputs): Promise<void> {
  const { publication, confirmation, guard } = inputs;
  const account = confirmation.account;
  try {
    const asset = savedEpub(publication);
    if (!asset) throw new SaveFailure("unsupported");
    if (asset.size_bytes > BOOK_LIMIT_BYTES) throw new SaveFailure("too_large");
    guard.assertActive();
    if (guard.account !== account) throw new SaveFailure("signed_out");
    await inputs.ensureWorker(inputs.offline);
    guard.assertActive();
    await inputs.store.confirm(confirmation);
    await checkSpace(inputs, account, publication.id, asset.size_bytes);
  } catch (error) {
    throw new SaveFailure(classify(error));
  }
  const work = () => transfer(inputs, account);
  if (!inputs.locks) return work();
  const ran = await inputs.locks.request(saveLockName(account, publication.id), { ifAvailable: true }, (lock) => (lock ? work().then(() => true) : false));
  if (!ran) throw new SaveFailure("busy");
}

export async function keepStorage(): Promise<void> {
  await navigator.storage?.persist?.().catch(() => false);
}
