import type { AccountGuard } from "../api/account-guard";
import type { Bootstrap, OfflineBoot } from "../contract";
import type { AuthClient } from "../go/auth";
import { confirmationFrom, type Offline } from "./context";
import type { ConfirmedAccount, OfflineStore } from "./model";
import { createPlaceSync } from "./placeSync";
import { definitiveRefusal } from "./reachability";
import { SaveFailure } from "./save";
import { hasWorker } from "./worker";

type Server = { mount: string; api: string; offline: OfflineBoot };

export async function keepOfflineAccount(offline: OfflineBoot | undefined, store: OfflineStore, confirmation: ConfirmedAccount | null, askedAt: number): Promise<void> {
  if (!offline) return;
  if (!confirmation) {
    await store.release(askedAt);
    return;
  }
  if ((await hasWorker(offline)) || (await store.accountState()).record) await store.confirm(confirmation);
}

export async function refreshOfflineAccount(offline: OfflineBoot | undefined, auth: AuthClient, store: OfflineStore): Promise<void> {
  if (!offline) return;
  const askedAt = Date.now();
  let answer: Bootstrap;
  try {
    answer = await auth.bootstrap();
  } catch (error) {
    if (definitiveRefusal(error)) await store.release(askedAt);
    return;
  }
  await keepOfflineAccount(offline, store, answer.authenticated ? confirmationFrom(answer, askedAt) : null, askedAt);
}

type OnlineInputs = { server: Server; auth: AuthClient; store: OfflineStore; guard: AccountGuard; confirmation: ConfirmedAccount | null; fetcher?: typeof fetch | undefined };

export function createOnlineOffline({ server, auth, store, guard, confirmation, fetcher }: OnlineInputs): Offline {
  const account = guard.account;
  return {
    boot: server.offline,
    store,
    confirmation,
    connected: true,
    confirm: async () => {
      await store.prepare();
      const sentAt = Date.now();
      let answer: Bootstrap;
      try {
        answer = await auth.bootstrap();
      } catch (error) {
        if (definitiveRefusal(error)) {
          await store.release(sentAt);
          throw new SaveFailure("signed_out");
        }
        throw new SaveFailure("network");
      }
      if (!answer.authenticated) {
        await store.release(sentAt);
        guard.lock("signed_out", sentAt);
        throw new SaveFailure("signed_out");
      }
      if (answer.account !== account) {
        guard.lock("account_changed", sentAt);
        throw new SaveFailure("signed_out");
      }
      const fresh = confirmationFrom(answer, sentAt);
      if (!fresh) throw new SaveFailure("unsupported");
      if (!(await store.confirm(fresh))) throw new SaveFailure("signed_out");
      return fresh;
    },
    sync: createPlaceSync({ boot: server, auth, store, guard, fetcher }),
  };
}

export function runOfflineSync(offline: Offline | null, guard: AccountGuard): () => void {
  const sync = offline?.sync;
  if (!sync) return () => undefined;
  const request = () => sync.request();
  const visible = () => document.visibilityState === "visible" && request();
  const stop = guard.subscribe(() => sync.stop());
  request();
  window.addEventListener("focus", request);
  window.addEventListener("online", request);
  document.addEventListener("visibilitychange", visible);
  return () => {
    stop();
    sync.stop();
    window.removeEventListener("focus", request);
    window.removeEventListener("online", request);
    document.removeEventListener("visibilitychange", visible);
  };
}
