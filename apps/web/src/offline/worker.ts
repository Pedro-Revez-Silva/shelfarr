import type { OfflineBoot } from "../contract";

export const WORKER_CACHE_PREFIX = "shelfarr-go-preview-offline.v1|";
const ACTIVATION_TIMEOUT_MS = 30_000;

export class WorkerFailure extends Error {}

export function offlineSupported(scope: typeof globalThis = globalThis): boolean {
  return scope.isSecureContext && "serviceWorker" in scope.navigator && "caches" in scope && "indexedDB" in scope;
}

function sameScope(registration: ServiceWorkerRegistration, scope: string): boolean {
  return new URL(registration.scope).pathname === scope;
}

export async function hasWorker(offline: Pick<OfflineBoot, "scope">): Promise<boolean> {
  if (!offlineSupported()) return false;
  const registration = await navigator.serviceWorker.getRegistration(offline.scope).catch(() => undefined);
  return registration !== undefined && sameScope(registration, offline.scope);
}

function activated(worker: ServiceWorker): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new WorkerFailure("Offline support didn't start in time")), ACTIVATION_TIMEOUT_MS);
    const settle = () => {
      if (worker.state === "activated") {
        clearTimeout(timer);
        resolve();
      } else if (worker.state === "redundant") {
        clearTimeout(timer);
        reject(new WorkerFailure("Offline support couldn't store this app's files"));
      }
    };
    worker.addEventListener("statechange", settle);
    settle();
  });
}

export async function ensureWorker(offline: OfflineBoot): Promise<void> {
  if (!offlineSupported()) throw new WorkerFailure("This browser can't keep books for offline reading");
  let registration: ServiceWorkerRegistration;
  try {
    registration = await navigator.serviceWorker.register(offline.worker, { scope: offline.scope, updateViaCache: "none" });
  } catch {
    throw new WorkerFailure("Offline support couldn't start in this browser");
  }
  const worker = registration.installing ?? registration.waiting ?? registration.active;
  if (!worker) throw new WorkerFailure("Offline support couldn't start in this browser");
  await activated(worker);
}

export async function retireWorker(offline: Pick<OfflineBoot, "scope">): Promise<void> {
  if (!offlineSupported()) return;
  const registration = await navigator.serviceWorker.getRegistration(offline.scope).catch(() => undefined);
  if (registration && sameScope(registration, offline.scope)) await registration.unregister().catch(() => false);
  for (const name of await caches.keys()) if (name.startsWith(WORKER_CACHE_PREFIX)) await caches.delete(name);
}
