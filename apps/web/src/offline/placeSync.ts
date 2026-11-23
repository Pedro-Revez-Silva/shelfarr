import type { AccountGuard } from "../api/account-guard";
import { ApiClient } from "../api/client";
import type { GoBoot } from "../contract";
import type { AuthClient } from "../go/auth";
import { confirmationFrom } from "./context";
import { definitiveRefusal } from "./reachability";
import { usable, type OfflineStore } from "./model";
import { createSyncRunner, type SyncRunner, type Verification } from "./sync";

type PlaceSyncInputs = {
  boot: Pick<GoBoot, "mount" | "api">;
  auth: AuthClient;
  store: OfflineStore;
  guard: AccountGuard;
  fetcher?: typeof fetch | undefined;
};

export function createPlaceSync({ boot, auth, store, guard, fetcher }: PlaceSyncInputs): SyncRunner {
  const account = guard.account;
  const verify = async (): Promise<Verification> => {
    if (!guard.isActive()) return { kind: "stop" };
    const askedAt = Date.now();
    let answer;
    try {
      answer = await auth.bootstrap();
    } catch (error) {
      if (!definitiveRefusal(error)) return { kind: "retry" };
      await store.release(askedAt);
      return { kind: "stop" };
    }
    if (!guard.isActive()) return { kind: "stop" };
    if (!answer.authenticated) {
      await store.release(askedAt);
      return { kind: "stop" };
    }
    const confirmation = confirmationFrom(answer, askedAt);
    if (!confirmation) {
      await store.release(askedAt);
      return { kind: "stop" };
    }
    await store.confirm(confirmation);
    if (answer.account !== account) return { kind: "stop" };
    if (!usable((await store.accountState()).record, account, Date.now())) return { kind: "stop" };
    return { kind: "verified", csrf: answer.csrf_token };
  };
  const send = fetcher ?? fetch;
  const background = ((input: RequestInfo | URL, init?: RequestInit) => send(input, { ...init, priority: "low" })) as typeof fetch;
  return createSyncRunner(
    {
      store,
      account,
      verify,
      write: (id, body, csrf) =>
        new ApiClient({ boot: { version: 1, account, mount: boot.mount, api: boot.api, classic_library: null, runtime: "go" }, guard, csrfToken: () => csrf, fetcher: background }).saveProgress(id, body),
    },
    typeof navigator !== "undefined" ? navigator.locks : undefined,
  );
}
