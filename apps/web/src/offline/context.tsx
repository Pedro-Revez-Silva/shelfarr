import { createContext, useContext } from "react";
import type { OfflineBoot } from "../contract";
import type { ConfirmedAccount, OfflineStore } from "./model";
import type { SyncRunner } from "./sync";

export type Offline = {
  boot: OfflineBoot;
  store: OfflineStore;
  confirmation: ConfirmedAccount | null;
  connected: boolean;
  confirm: () => Promise<ConfirmedAccount>;
  sync: SyncRunner | null;
};

const OfflineContext = createContext<Offline | null>(null);

export const OfflineProvider = OfflineContext.Provider;

export function useOffline(): Offline | null {
  return useContext(OfflineContext);
}

type Confirmable = { account: string; offline_expires_in?: number | undefined; offline_continuity?: string | undefined };

export function confirmationFrom({ account, offline_expires_in: expiresIn, offline_continuity: continuity }: Confirmable, now: number): ConfirmedAccount | null {
  if (expiresIn === undefined) return null;
  const confirmation: ConfirmedAccount = { account, confirmedAt: now, validForMs: expiresIn * 1000 };
  return continuity === undefined ? confirmation : { ...confirmation, continuity };
}

const CHANNEL = "shelfarr-go-preview-offline";
const listeners = new Set<() => void>();
let channel: BroadcastChannel | null = null;

function shared(): BroadcastChannel | null {
  if (typeof BroadcastChannel !== "function") return null;
  if (!channel) {
    channel = new BroadcastChannel(CHANNEL);
    channel.onmessage = () => {
      for (const listener of [...listeners]) listener();
    };
  }
  return channel;
}

export function announceChange(): void {
  shared()?.postMessage("changed");
}

export function onChange(listener: () => void): () => void {
  shared();
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
