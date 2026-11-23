import { useEffect, useState, type ReactNode } from "react";
import { AuthClient } from "../go/auth";
import type { Services } from "../services";
import { confirmationFrom, OfflineProvider, type Offline } from "./context";
import type { OfflineStore } from "./model";
import { createOnlineOffline, keepOfflineAccount, reconfirmOnMarkerChange, refreshOfflineAccount, runOfflineSync } from "./online";
import { definitiveRefusal } from "./reachability";
import { offlineStoreFor } from "./store";

type Props = { services: Services; store?: OfflineStore; fetcher?: typeof fetch; children: ReactNode };

export function RailsOffline({ services, store = offlineStoreFor(services.boot.mount, services.boot.offline?.continuity_cookie), fetcher, children }: Props) {
  const { boot, guard } = services;
  const [auth] = useState(() => new AuthClient(boot.api, fetcher));
  const [offline, setOffline] = useState<Offline | null>(null);
  const worker = boot.offline?.worker;
  const scope = boot.offline?.scope;
  const downloads = boot.offline?.downloads;

  useEffect(() => {
    if (!worker || !scope || !downloads) return;
    const target = { mount: boot.mount, api: boot.api, offline: { worker, scope, downloads } };
    let current = true;
    const stopRefusals = guard.subscribeRefusals((refusedAt) => void store.release(refusedAt).catch(() => undefined));
    const stopLocks = guard.subscribe(() => void refreshOfflineAccount(target.offline, auth, store).catch(() => undefined));
    const stopContinuity = reconfirmOnMarkerChange(target.offline, auth, store);
    const askedAt = Date.now();
    auth.bootstrap().then(
      async (answer) => {
        const confirmation = answer.authenticated ? confirmationFrom(answer, askedAt) : null;
        await keepOfflineAccount(target.offline, store, confirmation, askedAt);
        if (!current || !confirmation || confirmation.account !== guard.account || !guard.isActive()) return;
        setOffline(createOnlineOffline({ server: target, auth, store, guard, confirmation, fetcher }));
      },
      async (error: unknown) => {
        if (definitiveRefusal(error)) await store.release(askedAt);
      },
    ).catch(() => undefined);
    return () => {
      current = false;
      stopRefusals();
      stopLocks();
      stopContinuity();
    };
  }, [auth, boot.api, boot.mount, worker, scope, downloads, guard, store, fetcher]);

  useEffect(() => runOfflineSync(offline, guard), [offline, guard]);

  return <OfflineProvider value={offline}>{children}</OfflineProvider>;
}
