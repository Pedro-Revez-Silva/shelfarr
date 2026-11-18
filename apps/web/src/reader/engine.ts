import type { EpubBook, Purifier } from "./shared";

export type ReaderEngine = {
  ePub: (input: undefined, options: { replacements: "blobUrl" }) => EpubBook;
  DOMPurify: Purifier;
};

export class EngineError extends Error {}

function isEngine(value: unknown): value is ReaderEngine {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Record<string, unknown>;
  return typeof candidate["ePub"] === "function" && typeof candidate["DOMPurify"] === "function" && typeof (candidate["DOMPurify"] as { sanitize?: unknown }).sanitize === "function";
}

export async function loadEngine(address: string, importer: (address: string) => Promise<unknown> = (target) => import(target)): Promise<ReaderEngine> {
  const url = new URL(address, window.location.href);
  if (url.origin !== window.location.origin) throw new EngineError("The reader engine must come from this server");
  let loaded: unknown;
  try {
    loaded = await importer(url.pathname);
  } catch {
    throw new EngineError("The reader could not be loaded. Check your connection, then reload the page.");
  }
  if (!isEngine(loaded)) throw new EngineError("The reader engine on this server is not the expected one.");
  return loaded;
}
